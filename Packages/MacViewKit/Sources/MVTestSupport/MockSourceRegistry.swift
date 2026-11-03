import Foundation
import MVFoundation
import MVIO

/// 内存目录树上的来源注册表。`/Volumes/Mock` 下的文件 URL 映射到模拟树的根。
public final class MockSourceRegistry: SourceRegistry {
    public static let mountPath = "/Volumes/Mock"

    public let environment: MockEnvironment
    private let provider: MockContainerProvider

    public init(environment: MockEnvironment) {
        self.environment = environment
        provider = MockContainerProvider(environment: environment)
    }

    public func provider(for location: Location) throws -> any ContainerProvider {
        guard provider.canHandle(location) else { throw IOError.unsupported(location) }
        return provider
    }

    public func location(for fileURL: URL) async throws -> Location {
        let components = fileURL.standardizedFileURL.pathComponents
        let mount = URL(fileURLWithPath: Self.mountPath).pathComponents
        guard fileURL.isFileURL, components.starts(with: mount) else {
            throw IOError.unsupported(Location(root: .local, layers: [Array(components.dropFirst())]))
        }
        return Location(root: environment.tree.root, layers: [Array(components.dropFirst(mount.count))])
    }

    public func volumeHealth() -> AsyncStream<[VolumeHealth]> {
        environment.volumeUpdates()
    }
}

struct MockContainerProvider: ContainerProvider {
    let environment: MockEnvironment

    func canHandle(_ location: Location) -> Bool {
        location.root == environment.tree.root
    }

    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        environment.batches(of: container) { $0.entry }
    }

    func entry(at location: Location) async throws -> Entry {
        try await environment.access(location)
        return try environment.item(at: location).entry
    }

    func open(_ location: Location) async throws -> any ByteSource {
        try await environment.access(location)
        let entry = try environment.item(at: location).entry
        guard entry.kind != .directory else { throw IOError.unsupported(location) }
        return MockByteSource(environment: environment, identity: entry.identity)
    }

    /// 模拟树里的文件没有系统路径。
    func fileLease(for location: Location) async throws -> FileLease {
        throw IOError.unsupported(location)
    }
}

/// 字节内容是偏移量的低 8 位。
struct MockByteSource: ByteSource {
    let environment: MockEnvironment
    let identity: ContentIdentity

    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        try await environment.access(identity.location)
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, identity.size)
        guard lower < upper else { return Data() }
        return Data((lower..<upper).map { UInt8(truncatingIfNeeded: $0) })
    }
}
