import Foundation
import MVFoundation
import MVIO
import Synchronization

/// 压缩包通过注入的非压缩包来源解析单层位置，嵌套时通过自身递归取得外层字节。
public final class ArchiveProvider: ContainerProvider {
    private let fileSystem: FileSystemProvider
    private let outerProvider: @Sendable (Location) throws -> any ContainerProvider
    private let extracts: ExtractStore
    private struct State {
        var indexes: [ContentIdentity: ArchiveIndex] = [:]
        var recent: [ContentIdentity] = []
    }
    private let state = Mutex(State())

    public convenience init(fileSystem: FileSystemProvider, extractDirectory: URL, extractBudget: Int64 = 10 << 30) throws {
        let extracts = try ExtractStore(directory: extractDirectory, budget: extractBudget)
        self.init(fileSystem: fileSystem, extracts: extracts, outerProvider: { _ in fileSystem })
    }

    public init(
        fileSystem: FileSystemProvider,
        extracts: ExtractStore,
        outerProvider: @escaping @Sendable (Location) throws -> any ContainerProvider
    ) {
        self.fileSystem = fileSystem
        self.extracts = extracts
        self.outerProvider = outerProvider
    }

    public func canHandle(_ location: Location) -> Bool {
        if location.layers.count > 1 { return true }
        if case .archive = EntryKind(fileName: location.name) { return true }
        return false
    }

    public func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (archive, path) = try containerParts(container)
                    let index = try await index(of: archive, priority: priority)
                    if !path.isEmpty {
                        guard let record = index.records[path] else { throw IOError.notFound(container) }
                        guard record.kind == .directory else { throw IOError.unsupported(container) }
                    }
                    let entries = index.children(in: archive, path: path)
                    for start in stride(from: 0, to: entries.count, by: 256) {
                        try archiveCheckCancellation()
                        if case .terminated = continuation.yield(Array(entries[start..<min(start + 256, entries.count)])) { return }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func entry(at location: Location) async throws -> Entry {
        if location.layers.count == 1 { return try await outerProvider(location).entry(at: location) }
        let (archive, path) = try itemParts(location)
        let index = try await index(of: archive, priority: .visible)
        guard let record = index.records[path] else { throw IOError.notFound(location) }
        return record.entry(in: archive)
    }

    public func open(_ location: Location) async throws -> any ByteSource {
        try await itemSource(location, priority: .visible, materializeArchive: false)
    }

    public func fileLease(for location: Location) async throws -> FileLease {
        if location.layers.count == 1 { return try await outerProvider(location).fileLease(for: location) }
        let source = try await open(location)
        let lease = try await materialize(source, key: source.identity.cacheKey + "-file", priority: .visible)
        return FileLease(url: lease.url, holder: lease)
    }

    private func containerParts(_ location: Location) throws -> (Location, [String]) {
        if case .archive = EntryKind(fileName: location.name) { return (location, []) }
        return try itemParts(location)
    }

    private func itemParts(_ location: Location) throws -> (Location, [String]) {
        guard location.layers.count > 1, let path = location.layers.last else { throw IOError.unsupported(location) }
        return (Location(root: location.root, layers: Array(location.layers.dropLast())), path)
    }

    private func index(of archive: Location, priority: IOPriority) async throws -> ArchiveIndex {
        let identity = try await entry(at: archive).identity
        if let cached = state.withLock({ state -> ArchiveIndex? in
            guard let index = state.indexes[identity] else { return nil }
            state.recent.removeAll { $0 == identity }
            state.recent.append(identity)
            return index
        }) { return cached }
        let source = try await containerSource(archive, priority: priority)
        let index: ArchiveIndex
        switch EntryKind(fileName: archive.name) {
        case .archive(.zip): index = try await ZipIndex.read(source, priority: priority)
        case .archive(.tar): index = try await TarIndex.read(source, priority: priority)
        case .archive(.gzip), .archive(.tarGzip):
            let header = try await archiveRead(source, 0..<min(512, source.identity.size), priority: priority)
            if TarIndex.isHeader(header) || EntryKind(fileName: archive.name) == .archive(.tarGzip) {
                index = try await TarIndex.read(source, priority: priority)
            } else {
                let raw = try await itemSource(archive, priority: priority, materializeArchive: true)
                let info = try await GzipHeader.read(raw, priority: priority)
                let name = info.name ?? String(archive.name.dropLast(3))
                let path = try archivePath(name, at: archive)
                var single = ArchiveIndex()
                single.append(ArchiveRecord(path: path, size: source.identity.size,
                                            modificationNanos: info.modificationNanos ?? identity.modificationNanos,
                                            kind: EntryKind(fileName: name), offset: 0, compressedSize: source.identity.size))
                index = single
            }
        default: throw IOError.unsupported(archive)
        }
        state.withLock { state in
            state.indexes[identity] = index
            state.recent.removeAll { $0 == identity }
            state.recent.append(identity)
            while state.recent.count > 16 { state.indexes[state.recent.removeFirst()] = nil }
        }
        return index
    }

    private func containerSource(_ archive: Location, priority: IOPriority) async throws -> any ByteSource {
        let source = try await itemSource(archive, priority: priority, materializeArchive: true)
        switch EntryKind(fileName: archive.name) {
        case .archive(.gzip), .archive(.tarGzip):
            let key = source.identity.cacheKey + "-gzip"
            let lease: ExtractLease
            if let cached = extracts.acquire(key) { lease = cached }
            else {
                let temporary = extracts.temporaryURL()
                do {
                    let result = try await GzipDecoder.extract(source, to: temporary, priority: priority)
                    try archiveCheckCancellation()
                    lease = try await extracts.install(temporary, key: key, size: result)
                } catch {
                    try? await ExtractIO.run { try FileManager.default.removeItem(at: temporary) }
                    throw error
                }
            }
            var identity = source.identity
            identity.size = lease.size
            return try await extractedSource(lease, identity: identity)
        default: return source
        }
    }

    private func itemSource(_ location: Location, priority: IOPriority, materializeArchive: Bool) async throws -> any ByteSource {
        if location.layers.count == 1 { return try await outerProvider(location).open(location) }
        let (archive, path) = try itemParts(location)
        let index = try await index(of: archive, priority: priority)
        guard let record = index.records[path] else { throw IOError.notFound(location) }
        guard record.kind != .directory else { throw IOError.unsupported(location) }
        let outer = try await containerSource(archive, priority: priority)
        var offset = record.offset
        if record.localHeader {
            let header = try await archiveRead(outer, offset..<offset + 30, priority: priority)
            guard header.archiveInteger(UInt32.self, at: 0) == 0x0403_4B50,
                  header.archiveInteger(UInt16.self, at: 8) == record.method,
                  header.archiveInteger(UInt16.self, at: 6) & 1 == 0 else {
                throw IOError.corrupted(location, String(localized: "zip 本地头与中央目录不一致", bundle: .main))
            }
            offset += 30 + Int64(header.archiveInteger(UInt16.self, at: 26)) + Int64(header.archiveInteger(UInt16.self, at: 28))
        }
        guard offset >= 0, record.compressedSize <= outer.identity.size - offset else {
            throw IOError.corrupted(location, String(localized: "条目数据超出归档范围", bundle: .main))
        }
        let identity = record.entry(in: archive).identity
        if record.method == 0 {
            guard record.size == record.compressedSize else { throw IOError.corrupted(location, String(localized: "stored 大小不一致", bundle: .main)) }
            return RangeByteSource(identity: identity, outer: outer, offset: offset)
        }
        let source = DeflateByteSource(identity: identity, outer: outer, range: offset..<offset + record.compressedSize)
        if materializeArchive {
            let lease = try await materialize(source, key: identity.cacheKey + "-nested", priority: priority)
            return try await extractedSource(lease, identity: identity)
        }
        return source
    }

    private func materialize(_ source: any ByteSource, key: String, priority: IOPriority) async throws -> ExtractLease {
        if let cached = extracts.acquire(key) { return cached }
        let temporary = extracts.temporaryURL()
        do {
            let output = try await ExtractOutput.create(temporary)
            defer { output.close() }
            if let deflate = source as? DeflateByteSource {
                try await deflate.extract(to: output, priority: priority)
            } else {
                var offset: Int64 = 0
                while offset < source.identity.size {
                    let upper = min(offset + (4 << 20), source.identity.size)
                    let chunk = try await archiveRead(source, offset..<upper, priority: priority)
                    try await output.write(chunk)
                    offset = upper
                }
            }
            try archiveCheckCancellation()
            try await output.synchronize()
            return try await extracts.install(temporary, key: key, size: source.identity.size, fileName: source.identity.location.name)
        } catch {
            try? await ExtractIO.run { try FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }

    private func extractedSource(_ lease: ExtractLease, identity: ContentIdentity) async throws -> any ByteSource {
        let location = Location(root: .local, layers: [lease.url.pathComponents.filter { $0 != "/" }])
        return LeasedByteSource(identity: identity, source: try await fileSystem.open(location), lease: lease)
    }
}
