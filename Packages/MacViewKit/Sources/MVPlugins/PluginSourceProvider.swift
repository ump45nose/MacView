import Foundation
import MVFoundation
import MVIO
import Synchronization
import zlib

/// 将插件声明的数据来源接入 `SourceRegistry`，处理 `.plugin(id: "source/<UUID>")` 下的单层非压缩包位置。
public final class PluginSourceProvider: ContainerProvider, Sendable {
    private static let rootPrefix = "source/"

    private struct DirectoryKey: Hashable, Sendable {
        var sourceID: UUID
        var path: [String]
    }

    private struct CachedItem: Sendable {
        var entry: Entry
        var url: URL?
        var headers: [String: String]
    }

    private struct State {
        var directories: [DirectoryKey: [String: CachedItem]] = [:]
        var limiters: [UUID: HTTPConcurrencyLimiter] = [:]
    }

    private let host: PluginHost
    private let extracts: ExtractStore
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let state = Mutex(State())

    public init(host: PluginHost, extracts: ExtractStore, requestTimeout: TimeInterval = 15) {
        self.host = host
        self.extracts = extracts
        self.requestTimeout = requestTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(requestTimeout * 3, 60)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public static func root(for source: UUID) -> Location.Root {
        .plugin(id: rootPrefix + source.uuidString)
    }

    public static func sourceID(of root: Location.Root) -> UUID? {
        guard case let .plugin(id) = root, id.hasPrefix(rootPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(rootPrefix.count)))
    }

    /// 仅认领单层且非压缩包名的来源位置；压缩包与嵌套层交给先注册的 `ArchiveProvider`。
    public func canHandle(_ location: Location) -> Bool {
        guard Self.sourceID(of: location.root) != nil, location.layers.count == 1 else { return false }
        if case .archive = EntryKind(fileName: location.name) { return false }
        return true
    }

    public func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let sourceID = Self.sourceID(of: container.root), container.layers.count == 1 else {
                        throw IOError.unsupported(container)
                    }
                    let path = container.layers[0]
                    let items = try await listDirectory(sourceID: sourceID, container: container, path: path)
                    if !items.isEmpty {
                        continuation.yield(items.map(\.entry))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func entry(at location: Location) async throws -> Entry {
        guard let sourceID = Self.sourceID(of: location.root), location.layers.count == 1 else {
            throw IOError.unsupported(location)
        }
        let (_, _) = try resolveAvailableSource(sourceID: sourceID, root: location.root)
        let path = location.layers[0]
        if path.isEmpty {
            let name = host.sourceInstance(id: sourceID)?.name ?? sourceID.uuidString
            return Entry(
                identity: ContentIdentity(location: location, size: 0, modificationNanos: 0),
                name: name,
                kind: .directory
            )
        }
        return try await resolveItem(sourceID: sourceID, location: location).entry
    }

    public func open(_ location: Location) async throws -> any ByteSource {
        guard let sourceID = Self.sourceID(of: location.root), location.layers.count == 1 else {
            throw IOError.unsupported(location)
        }
        let item = try await resolveItem(sourceID: sourceID, location: location)
        guard item.entry.kind != .directory else {
            throw IOError.unsupported(location)
        }
        if let url = item.url {
            return HTTPByteSource(
                identity: item.entry.identity,
                url: url,
                headers: item.headers,
                limiter: limiter(for: sourceID),
                extracts: extracts,
                session: session,
                timeout: requestTimeout
            )
        }
        return PluginRPCByteSource(
            identity: item.entry.identity,
            host: host,
            sourceID: sourceID,
            path: location.layers[0]
        )
    }

    public func fileLease(for location: Location) async throws -> FileLease {
        let source = try await open(location)
        let key = source.identity.cacheKey + "-plugin-file"
        if let cached = extracts.acquire(key) {
            return FileLease(url: cached.url, holder: cached)
        }
        let temporary = extracts.temporaryURL()
        do {
            let output = try await ExtractOutput.create(temporary)
            defer { output.close() }
            var offset: Int64 = 0
            let chunkSize: Int64 = 4 << 20
            let knownSize = source.identity.size
            if knownSize > 0 {
                while offset < knownSize {
                    if Task.isCancelled { throw IOError.cancelled }
                    let upper = min(offset + chunkSize, knownSize)
                    let chunk = try await source.read(offset..<upper, priority: .visible, group: nil)
                    if chunk.isEmpty { break }
                    try await output.write(chunk)
                    offset += Int64(chunk.count)
                }
            } else {
                while true {
                    if Task.isCancelled { throw IOError.cancelled }
                    let chunk = try await source.read(offset..<(offset + chunkSize), priority: .visible, group: nil)
                    if chunk.isEmpty { break }
                    try await output.write(chunk)
                    offset += Int64(chunk.count)
                    if Int64(chunk.count) < chunkSize { break }
                }
            }
            if Task.isCancelled { throw IOError.cancelled }
            try await output.synchronize()
            let ext = (location.name as NSString).pathExtension
            let lease = try await extracts.install(temporary, key: key, size: offset, pathExtension: ext)
            return FileLease(url: lease.url, holder: lease)
        } catch {
            ExtractIO.remove([temporary])
            throw error
        }
    }

    // MARK: - 内部方法

    private func limiter(for sourceID: UUID) -> HTTPConcurrencyLimiter {
        state.withLock { state in
            if let existing = state.limiters[sourceID] { return existing }
            let created = HTTPConcurrencyLimiter(limit: 4)
            state.limiters[sourceID] = created
            return created
        }
    }

    private func resolveAvailableSource(sourceID: UUID, root: Location.Root) throws -> (pluginID: String, payload: JSONValue) {
        do {
            return try host.resolvedSourcePayload(for: sourceID)
        } catch {
            throw IOError.volumeUnavailable(root)
        }
    }

    private func resolveItem(sourceID: UUID, location: Location) async throws -> CachedItem {
        _ = try resolveAvailableSource(sourceID: sourceID, root: location.root)
        let path = location.layers[0]
        guard let name = path.last, let parent = location.parent else {
            throw IOError.notFound(location)
        }
        let parentPath = Array(path.dropLast())
        let key = DirectoryKey(sourceID: sourceID, path: parentPath)
        if let cached = state.withLock({ $0.directories[key]?[name] }) {
            return cached
        }
        // 冷启动直接打开某页（书签、历史）而内存表为空时，先对父目录调用一次 source.list 回填。
        let items = try await listDirectory(sourceID: sourceID, container: parent, path: parentPath)
        if let found = items.first(where: { $0.entry.name == name }) {
            return found
        }
        throw IOError.notFound(location)
    }

    private func listDirectory(sourceID: UUID, container: Location, path: [String]) async throws -> [CachedItem] {
        let (pluginID, sourcePayload) = try resolveAvailableSource(sourceID: sourceID, root: container.root)
        let params: JSONValue = .object([
            "source": sourcePayload,
            "path": .array(path.map(JSONValue.string)),
        ])
        let result: JSONValue
        do {
            result = try await host.sendRequest(plugin: pluginID, method: "source.list", params: params)
        } catch let error as PluginError {
            throw mapPluginError(error, root: container.root)
        } catch is CancellationError {
            throw IOError.cancelled
        } catch {
            throw IOError.underlying(error.localizedDescription)
        }

        let rawEntries: [JSONValue]
        if case let .object(dict) = result, case let .array(arr)? = dict["entries"] {
            rawEntries = arr
        } else if case let .array(arr) = result {
            rawEntries = arr
        } else {
            rawEntries = []
        }

        var items: [CachedItem] = []
        var byName: [String: CachedItem] = [:]
        items.reserveCapacity(rawEntries.count)

        for raw in rawEntries {
            guard case let .object(obj) = raw,
                  case let .string(name)? = obj["name"],
                  !name.isEmpty, !name.contains("/") else { continue }
            let rawKind: String
            if case let .string(k)? = obj["kind"] { rawKind = k } else { rawKind = "file" }
            let kind: EntryKind = (rawKind == "directory") ? .directory : EntryKind(fileName: name)
            let size: Int64
            if case let .number(n)? = obj["size"], n.isFinite, n >= 0 { size = Int64(n) } else { size = 0 }
            let modNanos = parseModificationNanos(obj["modified"])
            let checksum: UInt32?
            if case let .string(etag)? = obj["etag"], !etag.isEmpty {
                checksum = crc32Checksum(etag)
            } else {
                checksum = nil
            }
            let directURL: URL?
            if case let .string(urlStr)? = obj["url"], !urlStr.isEmpty {
                directURL = URL(string: urlStr)
            } else {
                directURL = nil
            }
            var headers: [String: String] = [:]
            if case let .object(h)? = obj["headers"] {
                for (hk, hv) in h {
                    if case let .string(hs) = hv { headers[hk] = hs }
                }
            }
            let entryLocation = container.appending(name)
            let identity = ContentIdentity(location: entryLocation, size: size, modificationNanos: modNanos, checksum: checksum)
            let entry = Entry(identity: identity, name: name, kind: kind)
            let item = CachedItem(entry: entry, url: directURL, headers: headers)
            items.append(item)
            byName[name] = item
        }

        state.withLock { $0.directories[DirectoryKey(sourceID: sourceID, path: path)] = byName }
        return items
    }

    private func parseModificationNanos(_ value: JSONValue?) -> Int64 {
        guard let value else { return 0 }
        switch value {
        case .number(let seconds) where seconds.isFinite:
            return Int64(seconds * 1_000_000_000)
        case .string(let text):
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
                return Int64(date.timeIntervalSince1970 * 1_000_000_000)
            }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text) {
                return Int64(date.timeIntervalSince1970 * 1_000_000_000)
            }
            return 0
        default:
            return 0
        }
    }

    private func crc32Checksum(_ string: String) -> UInt32 {
        let bytes = Array(string.utf8)
        return bytes.withUnsafeBufferPointer { ptr in
            UInt32(zlib.crc32(0, ptr.baseAddress, uInt(ptr.count)))
        }
    }

    private func mapPluginError(_ error: PluginError, root: Location.Root) -> IOError {
        switch error {
        case .disabled, .needsConsent, .notFound, .invalid:
            return .volumeUnavailable(root)
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        default:
            return .underlying(error.localizedDescription)
        }
    }
}

/// 当来源条目未提供直链时，经插件的 `source.read` 分块读取字节。
private final class PluginRPCByteSource: ByteSource, Sendable {
    let identity: ContentIdentity
    private let host: PluginHost
    private let sourceID: UUID
    private let path: [String]

    init(identity: ContentIdentity, host: PluginHost, sourceID: UUID, path: [String]) {
        self.identity = identity
        self.host = host
        self.sourceID = sourceID
        self.path = path
    }

    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        if Task.isCancelled { throw IOError.cancelled }
        let lower = max(0, range.lowerBound)
        let upper = identity.size > 0 ? min(range.upperBound, identity.size) : range.upperBound
        guard lower < upper else { return Data() }

        let (pluginID, sourcePayload): (String, JSONValue)
        do {
            (pluginID, sourcePayload) = try host.resolvedSourcePayload(for: sourceID)
        } catch {
            throw IOError.volumeUnavailable(identity.location.root)
        }

        let params: JSONValue = .object([
            "source": sourcePayload,
            "path": .array(path.map(JSONValue.string)),
            "offset": .number(Double(lower)),
            "length": .number(Double(upper - lower)),
        ])
        let result: JSONValue
        do {
            result = try await host.sendRequest(plugin: pluginID, method: "source.read", params: params)
        } catch let error as PluginError {
            switch error {
            case .disabled, .needsConsent, .notFound, .invalid:
                throw IOError.volumeUnavailable(identity.location.root)
            case .timeout:
                throw IOError.timeout
            case .cancelled:
                throw IOError.cancelled
            default:
                throw IOError.underlying(error.localizedDescription)
            }
        } catch is CancellationError {
            throw IOError.cancelled
        } catch {
            throw IOError.underlying(error.localizedDescription)
        }

        let base64: String
        if case let .object(dict) = result, case let .string(b)? = dict["data"] {
            base64 = b
        } else if case let .string(b) = result {
            base64 = b
        } else {
            throw IOError.underlying("插件 source.read 返回格式无效")
        }
        guard let data = Data(base64Encoded: base64) else {
            throw IOError.underlying("插件 source.read 返回的 base64 无效")
        }
        return data
    }
}
