import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVSettings
import Synchronization

/// Mock 的时序。默认值模拟经 NAS 首次浏览。
public struct MockTiming: Sendable {
    /// 首访时每秒完成的整文件读取数，所有请求共用，按优先级排队；默认 2.5 张/秒，无穷大表示不排队。
    public var readsPerSecond: Double = 2.5
    /// 每次请求的固定延迟；读过的文件只付这一项。
    public var latency: Duration = .milliseconds(20)
    /// 渐进交付时相邻两个阶段的间隔。
    public var stageInterval: Duration = .milliseconds(40)
    /// 枚举与元数据每批的条目数。
    public var batchSize = 64
    /// 相邻两批之间的间隔。
    public var batchInterval: Duration = .milliseconds(30)

    public init() {}

    /// 测试用：不排队，不等待。
    public static let instant: MockTiming = {
        var timing = MockTiming()
        timing.readsPerSecond = .infinity
        timing.latency = .zero
        timing.stageInterval = .zero
        timing.batchInterval = .zero
        return timing
    }()
}

/// 卷状态脚本的一步：上一步之后再过 `after`，卷变成 `state`。
public struct MockVolumeStep: Sendable {
    public var after: Duration
    public var state: VolumeState
    public var stuck: Int

    public init(after: Duration, state: VolumeState, stuck: Int = 0) {
        self.after = after
        self.state = state
        self.stuck = stuck
    }
}

public struct MockOptions: Sendable {
    public var tree: MockTree
    public var timing: MockTiming
    /// 访问这些位置时，在固定延迟之后抛出对应的错误。
    public var failures: [Location: IOError]
    /// 从创建环境起按顺序执行。
    public var volumeScript: [MockVolumeStep]
    public var settings: GlobalSettings

    public init(
        tree: MockTree = .sample, timing: MockTiming = MockTiming(), failures: [Location: IOError] = [:],
        volumeScript: [MockVolumeStep] = [], settings: GlobalSettings = .default
    ) {
        self.tree = tree
        self.timing = timing
        self.failures = failures
        self.volumeScript = volumeScript
        self.settings = settings
    }
}

/// 各 Mock 共用的内存目录树、卷状态、读取队列和注入的错误。
public final class MockEnvironment: Sendable {
    public let tree: MockTree
    public let timing: MockTiming
    private let failures: [Location: IOError]
    private let items: [Location: MockItem]
    private let volume: MockVolume
    private let queue: MockReadQueue?
    /// 读过的文件；再次读取只付固定延迟，相当于命中缓存。
    private let readFiles = Mutex<Set<Location>>([])

    public init(_ options: MockOptions = MockOptions()) {
        tree = options.tree
        timing = options.timing
        failures = options.failures
        let root = Location(root: options.tree.root)
        var items: [Location: MockItem] = [:]
        let children = Self.index(options.tree.nodes, in: root, archive: false, into: &items)
        let identity = ContentIdentity(location: root, size: 0, modificationNanos: MockNode.baseTime)
        items[root] = MockItem(entry: Entry(identity: identity, name: root.description, kind: .directory), media: nil, children: children)
        self.items = items
        let volume = MockVolume(root: options.tree.root)
        self.volume = volume
        let rate = options.timing.readsPerSecond
        queue = rate > 0 && rate.isFinite ? MockReadQueue(readsPerSecond: rate) : nil
        if !options.volumeScript.isEmpty {
            Task {
                for step in options.volumeScript {
                    try? await Task.sleep(for: step.after)
                    volume.set(step.state, stuck: step.stuck)
                }
            }
        }
    }

    public var rootLocation: Location { Location(root: tree.root) }

    /// 手动改变卷状态，供测试和界面开发使用。
    public func setVolumeState(_ state: VolumeState, stuck: Int = 0) {
        volume.set(state, stuck: stuck)
    }

    func volumeUpdates() -> AsyncStream<[VolumeHealth]> {
        volume.updates()
    }

    func item(at location: Location) throws -> MockItem {
        guard let item = items[location] else { throw IOError.notFound(location) }
        return item
    }

    func children(of container: Location) throws -> [MockItem] {
        let item = try item(at: container)
        switch item.entry.kind {
        case .directory, .archive: return item.children.compactMap { items[$0] }
        case .image, .video, .other: throw IOError.unsupported(container)
        }
    }

    func media(at location: Location) throws -> MockMedia {
        guard let media = try item(at: location).media else { throw IOError.unsupported(location) }
        return media
    }

    /// 一次访问：检查卷状态，等待固定延迟，再抛出注入的错误。
    func access(_ location: Location) async throws {
        try volume.check()
        try await pause(timing.latency)
        if let error = failures[location] {
            throw error
        }
    }

    /// 读取整个媒体文件：首访要在读取队列里等吞吐，之后只付固定延迟。
    func readMedia(_ location: Location, priority: IOPriority) async throws -> MockMedia {
        try await access(location)
        let media = try media(at: location)
        if let queue, !readFiles.withLock({ $0.contains(location) }) {
            try await queue.acquire(priority: priority)
            readFiles.withLock { _ = $0.insert(location) }
        }
        return media
    }

    func pause(_ duration: Duration) async throws {
        if duration > .zero {
            try await Task.sleep(for: duration)
        }
    }

    /// 分批给出容器的子项，顺序是确定性打乱的“到达顺序”；`transform` 返回 nil 的项不给出，空批跳过。
    func batches<Element: Sendable>(of container: Location, _ transform: @escaping @Sendable (MockItem) -> Element?) -> AsyncThrowingStream<[Element], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await access(container)
                    var random = MockRandom(seed: container.description)
                    let children = try children(of: container).shuffled(using: &random)
                    let size = max(timing.batchSize, 1)
                    for start in stride(from: 0, to: children.count, by: size) {
                        if start > 0 {
                            try await pause(timing.batchInterval)
                        }
                        let batch = children[start..<min(start + size, children.count)].compactMap(transform)
                        if !batch.isEmpty {
                            continuation.yield(batch)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func index(_ nodes: [MockNode], in container: Location, archive: Bool, into items: inout [Location: MockItem]) -> [Location] {
        nodes.map { node in
            let location = archive ? container.appendingLayer([node.name]) : container.appending(node.name)
            var children: [Location] = []
            var media: MockMedia?
            switch node.content {
            case let .directory(nodes): children = index(nodes, in: location, archive: false, into: &items)
            case let .archive(_, nodes): children = index(nodes, in: location, archive: true, into: &items)
            case let .image(size, frames): media = MockMedia(pixelSize: size, frameCount: frames, duration: nil)
            case let .video(size, duration): media = MockMedia(pixelSize: size, frameCount: 1, duration: duration)
            case .other: break
            }
            let identity = ContentIdentity(location: location, size: node.size, modificationNanos: node.modificationNanos)
            items[location] = MockItem(entry: Entry(identity: identity, name: node.name, kind: node.kind), media: media, children: children)
            return location
        }
    }
}

struct MockItem: Sendable {
    var entry: Entry
    var media: MockMedia?
    var children: [Location]
}

struct MockMedia: Sendable {
    var pixelSize: PixelSize
    var frameCount: Int
    var duration: Double?

    var metadata: ImageMetadata {
        ImageMetadata(pixelSize: pixelSize, frameCount: frameCount, duration: duration, colorSpace: "sRGB")
    }
}

/// 模拟卷的健康状态。不健康时所有访问立即失败。
final class MockVolume: Sendable {
    private struct State {
        var health: VolumeHealth
        var observers: [UUID: AsyncStream<[VolumeHealth]>.Continuation] = [:]
    }

    private let root: Location.Root
    private let state: Mutex<State>

    init(root: Location.Root) {
        self.root = root
        state = Mutex(State(health: VolumeHealth(root: root, state: .healthy)))
    }

    func check() throws {
        guard state.withLock({ $0.health.state }) == .healthy else { throw IOError.volumeUnavailable(root) }
    }

    func set(_ volumeState: VolumeState, stuck: Int) {
        state.withLock { current in
            current.health.state = volumeState
            current.health.stuck = stuck
            for observer in current.observers.values {
                observer.yield([current.health])
            }
        }
    }

    /// 先给出当前状态，之后每次变化给出一次。
    func updates() -> AsyncStream<[VolumeHealth]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [VolumeHealth].self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { current in
            current.observers[id] = continuation
            continuation.yield([current.health])
        }
        return stream
    }
}

/// 首访读取的队列：每 1/readsPerSecond 秒完成一次，选当时优先级最高、最早到达的请求。被取消的请求立即离开队列。
actor MockReadQueue {
    private struct Waiter {
        let id: UInt64
        let priority: IOPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let interval: Duration
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    private var lastFinish = ContinuousClock.now
    private var pumping = false

    init(readsPerSecond: Double) {
        interval = .seconds(1 / readsPerSecond)
    }

    func acquire(priority: IOPriority) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        guard !Task.isCancelled else {
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(waiter)
        if !pumping {
            pumping = true
            Task { await pump() }
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func pump() async {
        while !waiters.isEmpty {
            let due = max(lastFinish, .now) + interval
            try? await Task.sleep(until: due, clock: .continuous)
            lastFinish = due
            let best = waiters.indices.max { a, b in
                waiters[a].priority != waiters[b].priority ? waiters[a].priority < waiters[b].priority : waiters[a].id > waiters[b].id
            }
            guard let best else { break }
            waiters.remove(at: best).continuation.resume()
        }
        pumping = false
    }
}
