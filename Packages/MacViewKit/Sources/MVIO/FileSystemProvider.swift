import Darwin
import Foundation
import MVFoundation
import Synchronization

/// 本机目录与系统挂载的网络共享。处理只有一层的 Location，全部调用经 `IOScheduler`。
public final class FileSystemProvider: ContainerProvider {
    let scheduler: IOScheduler

    public init(scheduler: IOScheduler) {
        self.scheduler = scheduler
    }

    public func canHandle(_ location: Location) -> Bool {
        guard location.layers.count == 1 else { return false }
        if case .plugin = location.root { return false }
        return true
    }

    public func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do throws(IOError) {
                    let (volume, path) = try resolve(container)
                    let backend = scheduler.backend(for: volume)
                    let _: Void = try await scheduler.perform(on: volume, .metadata, priority: priority, group: nil) { finish, touch in
                        backend.list(path, batch: { batch in
                            touch()
                            let entries = batch.map { Self.entry(in: container, $0) }
                            if case .terminated = continuation.yield(entries) { return false }
                            return true
                        }, completion: { result in
                            finish(result.mapError { Self.ioError($0, at: container, volume: volume) })
                        })
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
        let (volume, path) = try resolve(location)
        let backend = scheduler.backend(for: volume)
        let attributes: FileAttributes = try await scheduler.perform(on: volume, .metadata, priority: .visible, group: nil) { finish, _ in
            backend.stat(path) { result in finish(result.mapError { Self.ioError($0, at: location, volume: volume) }) }
        }
        var entry = Self.entry(in: location.parent ?? location, attributes)
        entry.identity.location = location
        entry.name = location.name
        return entry
    }

    public func open(_ location: Location) async throws -> any ByteSource {
        let entry = try await entry(at: location)
        guard entry.kind != .directory else { throw IOError.unsupported(location) }
        let (volume, path) = try resolve(location)
        return FileByteSource(identity: entry.identity, path: path, volume: volume, scheduler: scheduler)
    }

    public func fileURL(for location: Location) async throws -> URL {
        URL(filePath: try resolve(location).path, directoryHint: .inferFromPath)
    }

    private func resolve(_ location: Location) throws(IOError) -> (volume: Volume, path: String) {
        guard canHandle(location) else { throw .unsupported(location) }
        let volume = try scheduler.volume(for: location)
        return (volume, volume.path(of: location.layers[0]))
    }

    static func entry(in container: Location, _ attributes: FileAttributes) -> Entry {
        let kind: EntryKind = switch attributes.type {
        case .directory: .directory
        case .regular: EntryKind(fileName: attributes.name)
        case .symbolicLink, .other: .other
        }
        return Entry(
            identity: ContentIdentity(location: container.appending(attributes.name), size: attributes.size, modificationNanos: attributes.modificationNanos),
            name: attributes.name,
            kind: kind,
            created: attributes.creationNanos.map { Date(timeIntervalSince1970: Double($0) / 1e9) }
        )
    }

    static func ioError(_ error: FileOperationError, at location: Location, volume: Volume) -> IOError {
        switch error {
        case let .system(_, code) where code == ENOENT || code == ENOTDIR:
            .notFound(location)
        case let .system(_, code) where code == ETIMEDOUT:
            .timeout
        case let .system(call, code):
            .underlying("\(call): \(String(cString: strerror(code)))")
        case .changed:
            .corrupted(location, "文件在打开后被修改")
        case .helperLost:
            .volumeDegraded(volume.root)
        }
    }
}

/// 一个文件的字节。小读走元数据通道；大块读取按块走大块读取通道，块与块之间检查取消。
final class FileByteSource: ByteSource {
    let identity: ContentIdentity
    private let path: String
    private let volume: Volume
    private let scheduler: IOScheduler

    init(identity: ContentIdentity, path: String, volume: Volume, scheduler: IOScheduler) {
        self.identity = identity
        self.path = path
        self.volume = volume
        self.scheduler = scheduler
    }

    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        let lower = max(0, range.lowerBound)
        let upper = min(range.upperBound, identity.size)
        guard lower < upper else { return Data() }
        let configuration = scheduler.configuration
        if upper - lower <= Int64(configuration.smallReadLimit) {
            return try await chunk(lower, Int(upper - lower), .metadata, priority: priority, group: group)
        }
        let size = volume.isLocal ? configuration.local.chunk : configuration.network.chunk
        var data = Data(capacity: Int(upper - lower))
        var offset = lower
        while offset < upper {
            if Task.isCancelled { throw IOError.cancelled }
            let length = Int(min(Int64(size), upper - offset))
            let part = try await chunk(offset, length, .bulk, priority: priority, group: group)
            data.append(part)
            guard part.count == length else { break }
            offset += Int64(length)
        }
        return data
    }

    private func chunk(_ offset: Int64, _ length: Int, _ channel: IOScheduler.Channel, priority: IOPriority, group: IORequestGroup?) async throws(IOError) -> Data {
        let request = ReadRequest(
            path: path,
            offset: offset,
            length: length,
            expectedSize: identity.size,
            expectedModificationNanos: identity.modificationNanos,
            noCache: channel == .bulk,
            retryByReopening: !volume.isLocal
        )
        let backend = scheduler.backend(for: volume)
        let (location, volume) = (identity.location, volume)
        return try await scheduler.perform(on: volume, channel, priority: priority, group: group) { finish, _ in
            backend.read(request) { result in finish(result.mapError { FileSystemProvider.ioError($0, at: location, volume: volume) }) }
        }
    }
}

/// 来源注册表：一层的 Location 交给文件系统，压缩包内的交给登记进来的 provider（MVArchive 在组合根中登记）。
public final class FileSourceRegistry: SourceRegistry {
    public let scheduler: IOScheduler
    public let fileSystem: FileSystemProvider
    private let providers = Mutex<[any ContainerProvider]>([])

    public init(scheduler: IOScheduler) {
        self.scheduler = scheduler
        fileSystem = FileSystemProvider(scheduler: scheduler)
    }

    public func register(_ provider: any ContainerProvider) {
        providers.withLock { $0.append(provider) }
    }

    public func provider(for location: Location) throws -> any ContainerProvider {
        if fileSystem.canHandle(location) { return fileSystem }
        guard let provider = providers.withLock({ $0.first { $0.canHandle(location) } }) else { throw IOError.unsupported(location) }
        return provider
    }

    /// 只查挂载表，不访问文件，网络卷卡住时也立即返回。路径不解析符号链接。
    public func location(for fileURL: URL) async throws -> Location {
        guard fileURL.isFileURL else { throw IOError.underlying("不是文件 URL：\(fileURL)") }
        let path = fileURL.standardizedFileURL.path
        guard let volume = scheduler.table.volume(containing: path) else { throw IOError.underlying("找不到 \(path) 所在的卷") }
        return Location(root: volume.root, layers: [volume.components(ofPath: path)])
    }

    public func volumeHealth() -> AsyncStream<[VolumeHealth]> {
        scheduler.volumeHealth()
    }
}
