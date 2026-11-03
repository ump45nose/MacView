// MVIO：I/O 调度、卷通道与健康状态、文件系统来源与来源注册。职责与契约见 docs/architecture.md §2、§4。
import Foundation
import MVFoundation

/// I/O 请求的优先级，按声明顺序从高到低；比较时 `visible` 最大。
public enum IOPriority: Int, Sendable, Comparable {
    case visible, near, book, adjacent, background

    public static func < (lhs: IOPriority, rhs: IOPriority) -> Bool {
        lhs.rawValue > rhs.rawValue
    }
}

/// 一批可以整体取消或重排的请求，例如一次预取计划。
public struct IORequestGroup: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// 一个文件的字节，按范围读取。
public protocol ByteSource: Sendable {
    var identity: ContentIdentity { get }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data
}

/// 目录、压缩包等容器的来源，按根分派。
/// 一个可以按路径访问的文件。`holder` 释放后，提取目录才可以淘汰这个文件。
public struct FileLease: Sendable {
    public let url: URL
    private let holder: (any Sendable)?

    public init(url: URL, holder: (any Sendable)? = nil) {
        self.url = url
        self.holder = holder
    }
}

public protocol ContainerProvider: Sendable {
    func canHandle(_ location: Location) -> Bool
    /// 分批返回容器的直接子项，顺序为到达顺序。
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error>
    func entry(at location: Location) async throws -> Entry
    func open(_ location: Location) async throws -> any ByteSource
    /// 系统路径；压缩包内的条目先解出到 extract/，使用期间持有租约。
    func fileLease(for location: Location) async throws -> FileLease
}

public enum VolumeState: Sendable, Equatable {
    case healthy
    case degraded(String)
    case unavailable
}

public struct VolumeHealth: Sendable, Equatable {
    public var root: Location.Root
    public var state: VolumeState
    public var inFlight: Int
    public var stuck: Int

    public init(root: Location.Root, state: VolumeState, inFlight: Int = 0, stuck: Int = 0) {
        self.root = root
        self.state = state
        self.inFlight = inFlight
        self.stuck = stuck
    }
}

public enum IOError: Error, Sendable, Equatable {
    case timeout
    case cancelled
    case volumeUnavailable(Location.Root)
    /// 卷连续超时，暂停访问；健康探测成功后恢复。
    case volumeDegraded(Location.Root)
    case notFound(Location)
    case unsupported(Location)
    case corrupted(Location, String)
    case underlying(String)
}

/// 各来源的注册表，也是文件 URL 进入 MacView 的入口。
public protocol SourceRegistry: Sendable {
    func provider(for location: Location) throws -> any ContainerProvider
    /// 打开面板与拖放的入口；要查询卷信息，所以是异步的。
    func location(for fileURL: URL) async throws -> Location
    /// 先给出当前状态，之后每次变化给出全部卷的状态。
    func volumeHealth() -> AsyncStream<[VolumeHealth]>
}
