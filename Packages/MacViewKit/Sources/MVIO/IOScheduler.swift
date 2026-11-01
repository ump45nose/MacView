import Dispatch
import Foundation
import MVFoundation
import Synchronization

/// I/O 调度的参数。网络卷的取值来自 S0-T2 的实测，见 docs/reports/S0-T2.md §4。
public struct IOConfiguration: Sendable {
    public struct Channels: Sendable {
        /// 枚举、stat、文件头探测等小请求的并发上限。
        public var metadata: Int
        /// 大块读取的并发上限。
        public var bulk: Int
        /// 大块读取每次读的字节数；块与块之间检查取消。
        public var chunk: Int

        public init(metadata: Int, bulk: Int, chunk: Int) {
            self.metadata = metadata
            self.bulk = bulk
            self.chunk = chunk
        }
    }

    public var local = Channels(metadata: 8, bulk: 4, chunk: 4 << 20)
    public var network = Channels(metadata: 4, bulk: 4, chunk: 4 << 20)
    /// 不超过这个长度的读取走元数据通道。
    public var smallReadLimit = 1 << 20
    /// 每次调用的期限；硬挂载在故障期间一直阻塞、不报错，期限是唯一的超时来源。不短于 5 秒。
    public var deadline: Duration {
        get { storedDeadline }
        set { storedDeadline = max(newValue, .seconds(5)) }
    }
    /// 没有成功穿插的连续超时达到这个次数时，卷标为 degraded。
    public var degradeAfterTimeouts = 2
    /// degraded 的卷上，健康探测失败后的重试间隔。
    public var probeInterval: Duration = .seconds(2)
    /// 网络卷的辅助进程：宿主自己的可执行文件，`main` 开头调用了 `IOHelper.runIfRequested()`。
    /// 为 nil 时网络卷也在进程内执行，只用于测试。
    public var helperExecutable: URL?

    private var storedDeadline: Duration = .seconds(10)

    public init(helperExecutable: URL?) {
        self.helperExecutable = helperExecutable
    }

    /// 测试用：期限可以短于 5 秒。
    mutating func setDeadlineForTesting(_ deadline: Duration) {
        storedDeadline = deadline
    }
}

/// 按卷分通道、带优先级、取消和期限的 I/O 调度器。
///
/// - 每个卷两个通道：元数据和大块读取，各有并发上限，小请求不会排在大块读取后面。
/// - 排队的请求按优先级（同级按到达顺序）出队；同一 `IORequestGroup` 可以整批取消或改优先级。
/// - 执行中的调用超过期限时，调用方收到 `timeout`，调用本身仍占着槽位，计为 stuck，直到它返回。
/// - 连续超时后卷标为 degraded：新请求立即失败，只做健康探测，探测成功即恢复。网络卷同时弃用卡住的辅助进程。
public final class IOScheduler: Sendable {
    enum Channel: Sendable {
        case metadata, bulk
    }

    /// 一个卷的通道与健康状态。
    private struct VolumeRecord {
        var volume: Volume
        var queues: [Channel: [UInt64]] = [.metadata: [], .bulk: []]
        var running: [Channel: Int] = [.metadata: 0, .bulk: 0]
        var stuck = 0
        var consecutiveTimeouts = 0
        var degradedReason: String?
        var probing = false
        var unavailable = false
    }

    private enum Phase {
        case queued, running, timedOut
    }

    private struct Job {
        var volume: String
        var channel: Channel
        var priority: IOPriority
        var group: IORequestGroup?
        var phase = Phase.queued
        /// 期限计时的代数；`touch` 时加一，旧的计时器到期后不再生效。
        var generation = 0
        var start: @Sendable (_ id: UInt64) -> Void
        var fail: @Sendable (IOError) -> Void
    }

    private struct State {
        var volumes: [String: VolumeRecord] = [:]
        var jobs: [UInt64: Job] = [:]
        var nextID: UInt64 = 1
        var groupPriorities: [IORequestGroup: IOPriority] = [:]
        var cancelledGroups: Set<IORequestGroup> = []
        /// 还没入队就被取消的请求；入队时直接失败。
        var cancelledBeforeEnqueue: Set<UInt64> = []
        var observers: [UUID: AsyncStream<[VolumeHealth]>.Continuation] = [:]
    }

    let configuration: IOConfiguration
    let table: VolumeTable
    private let state = Mutex(State())
    private let direct: any FileBackend
    private let helper: (any FileBackend)?
    private let timers = DispatchQueue(label: "io.github.ump45nose.MacView.io.deadlines")

    public convenience init(configuration: IOConfiguration) {
        self.init(configuration: configuration, backend: nil)
    }

    /// 测试用：`backend` 代替进程内执行和辅助进程，所有卷都用它。
    init(configuration: IOConfiguration, backend: (any FileBackend)?) {
        self.configuration = configuration
        table = VolumeTable()
        direct = backend ?? DirectBackend()
        helper = backend == nil ? configuration.helperExecutable.map(HelperBackend.init) : nil
    }

    /// 全部卷上排队中的请求数。
    var queuedCount: Int {
        state.withLock { $0.volumes.values.reduce(0) { $0 + $1.queues.values.reduce(0) { $0 + $1.count } } }
    }

    // MARK: 请求组

    /// 取消组内排队中的请求，之后该组的新请求立即以 `cancelled` 失败。执行中的调用照常完成。
    public func cancel(_ group: IORequestGroup) {
        let failed = state.withLock { state -> [Job] in
            state.cancelledGroups.insert(group)
            state.groupPriorities[group] = nil
            let ids = state.jobs.filter { $0.value.group == group && $0.value.phase == .queued }.map(\.key)
            return ids.compactMap { id in
                guard let job = state.jobs.removeValue(forKey: id) else { return nil }
                state.volumes[job.volume]?.queues[job.channel]?.removeAll { $0 == id }
                return job
            }
        }
        failed.forEach { $0.fail(.cancelled) }
    }

    /// 改变组内排队中和之后的请求的优先级。
    public func setPriority(_ priority: IOPriority, for group: IORequestGroup) {
        state.withLock { state in
            guard !state.cancelledGroups.contains(group) else { return }
            state.groupPriorities[group] = priority
            for (id, job) in state.jobs where job.group == group && job.phase == .queued {
                state.jobs[id]?.priority = priority
            }
        }
    }

    // MARK: 卷健康

    /// 先给出当前状态，之后每次变化给出全部卷的状态。
    public func volumeHealth() -> AsyncStream<[VolumeHealth]> {
        AsyncStream { continuation in
            let id = UUID()
            let snapshot = state.withLock { state in
                state.observers[id] = continuation
                return Self.health(state)
            }
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
            }
        }
    }

    /// 退出前调用：杀掉辅助进程，不等卡住的调用。
    public func shutdown() {
        helper?.abandon()
    }

    private static func health(_ state: State) -> [VolumeHealth] {
        state.volumes.values.sorted { $0.volume.mountPoint < $1.volume.mountPoint }.map { volume in
            let condition: VolumeState
            if volume.unavailable {
                condition = .unavailable
            } else if let reason = volume.degradedReason {
                condition = .degraded(reason)
            } else {
                condition = .healthy
            }
            return MVIO.VolumeHealth(
                root: volume.volume.root,
                state: condition,
                inFlight: volume.running.values.reduce(0, +),
                stuck: volume.stuck
            )
        }
    }

    private func publish(_ state: State) {
        let snapshot = Self.health(state)
        for observer in state.observers.values { observer.yield(snapshot) }
    }

    // MARK: 执行

    func backend(for volume: Volume) -> any FileBackend {
        if !volume.isLocal, let helper { return helper }
        return direct
    }

    /// 卷当前是否可用；不可用时抛出对应的错误。也用来登记第一次见到的卷。
    func volume(for location: Location) throws(IOError) -> Volume {
        guard let volume = table.volume(for: location) else {
            state.withLock { state in
                for key in state.volumes.keys where state.volumes[key]?.volume.root == location.root && location.root != .local {
                    if state.volumes[key]?.unavailable == false {
                        state.volumes[key]?.unavailable = true
                        publish(state)
                    }
                }
            }
            throw .volumeUnavailable(location.root)
        }
        return volume
    }

    /// 在卷的通道上执行一次调用。`body` 收到结束调用的 `finish` 和重置期限的 `touch`。
    func perform<T: Sendable>(
        on volume: Volume,
        _ channel: Channel,
        priority: IOPriority,
        group: IORequestGroup?,
        _ body: @escaping @Sendable (_ finish: @escaping @Sendable (Result<T, IOError>) -> Void, _ touch: @escaping @Sendable () -> Void) -> Void
    ) async throws(IOError) -> T {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let result: Result<T, IOError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, IOError>, Never>) in
                let resumed = Atomic(false)
                let resume: @Sendable (Result<T, IOError>) -> Void = { result in
                    if resumed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
                        continuation.resume(returning: result)
                    }
                }
                // 任务表持有这个闭包，请求结束时随任务一起移除，不会长期持有调度器。
                let start: @Sendable (UInt64) -> Void = { id in
                    body({ result in self.finish(id, result: result, resume: resume) }, { self.touch(id) })
                }
                enqueue(id, volume: volume, channel: channel, priority: priority, group: group, start: start, fail: { resume(.failure($0)) })
            }
        } onCancel: {
            dequeue(id)
        }
        return try result.get()
    }

    private func enqueue(
        _ id: UInt64,
        volume: Volume,
        channel: Channel,
        priority: IOPriority,
        group: IORequestGroup?,
        start: @escaping @Sendable (UInt64) -> Void,
        fail: @escaping @Sendable (IOError) -> Void
    ) {
        let rejection = state.withLock { state -> IOError? in
            if state.cancelledBeforeEnqueue.remove(id) != nil { return .cancelled }
            if let group, state.cancelledGroups.contains(group) { return .cancelled }
            if state.volumes[volume.mountPoint] == nil {
                state.volumes[volume.mountPoint] = VolumeRecord(volume: volume)
                publish(state)
            } else if state.volumes[volume.mountPoint]?.unavailable == true {
                state.volumes[volume.mountPoint]?.unavailable = false
                state.volumes[volume.mountPoint]?.volume = volume
                publish(state)
            }
            if state.volumes[volume.mountPoint]?.degradedReason != nil { return .volumeDegraded(volume.root) }
            let effective = group.flatMap { state.groupPriorities[$0] } ?? priority
            state.jobs[id] = Job(volume: volume.mountPoint, channel: channel, priority: effective, group: group, start: start, fail: fail)
            state.volumes[volume.mountPoint]?.queues[channel]?.append(id)
            return nil
        }
        if let rejection {
            fail(rejection)
            return
        }
        pump(volume.mountPoint, channel)
    }

    /// 调用方的任务被取消：排队中的直接出队；执行中的照常完成，由调用方在块之间检查取消。
    private func dequeue(_ id: UInt64) {
        let job = state.withLock { state -> Job? in
            guard let job = state.jobs[id] else {
                state.cancelledBeforeEnqueue.insert(id)
                return nil
            }
            guard job.phase == .queued else { return nil }
            state.jobs[id] = nil
            state.volumes[job.volume]?.queues[job.channel]?.removeAll { $0 == id }
            return job
        }
        job?.fail(.cancelled)
    }

    /// 在空出的槽位上启动排队中优先级最高的请求。
    private func pump(_ mountPoint: String, _ channel: Channel) {
        let limit = state.withLock { state in
            state.volumes[mountPoint].map { $0.volume.isLocal ? configuration.local : configuration.network }
        }
        guard let limit else { return }
        let capacity = channel == .metadata ? limit.metadata : limit.bulk
        while true {
            let next = state.withLock { state -> (UInt64, Job)? in
                guard let volume = state.volumes[mountPoint], volume.degradedReason == nil,
                      volume.running[channel, default: 0] < capacity,
                      let queue = volume.queues[channel], !queue.isEmpty
                else { return nil }
                // 优先级最高的；同级取最早到达的。队列不长，线性查找足够。
                var best = 0
                for index in queue.indices.dropFirst() where state.jobs[queue[index]]!.priority > state.jobs[queue[best]]!.priority {
                    best = index
                }
                let id = queue[best]
                state.volumes[mountPoint]?.queues[channel]?.remove(at: best)
                state.volumes[mountPoint]?.running[channel, default: 0] += 1
                state.jobs[id]?.phase = .running
                return (id, state.jobs[id]!)
            }
            guard let (id, job) = next else { return }
            armDeadline(id, generation: 0)
            job.start(id)
        }
    }

    private func armDeadline(_ id: UInt64, generation: Int) {
        timers.asyncAfter(deadline: .now() + configuration.deadline.timeInterval) { [weak self] in
            self?.expire(id, generation: generation)
        }
    }

    private func touch(_ id: UInt64) {
        let generation = state.withLock { state -> Int? in
            guard state.jobs[id]?.phase == .running else { return nil }
            state.jobs[id]?.generation += 1
            return state.jobs[id]?.generation
        }
        if let generation { armDeadline(id, generation: generation) }
    }

    private func finish<T>(_ id: UInt64, result: Result<T, IOError>, resume: @Sendable (Result<T, IOError>) -> Void) {
        let outcome = state.withLock { state -> (mountPoint: String, channel: Channel, deliver: Bool)? in
            guard let job = state.jobs.removeValue(forKey: id), job.phase != .queued else { return nil }
            state.volumes[job.volume]?.running[job.channel, default: 1] -= 1
            if job.phase == .timedOut {
                state.volumes[job.volume]?.stuck -= 1
            } else if case .success = result {
                state.volumes[job.volume]?.consecutiveTimeouts = 0
            }
            publish(state)
            return (job.volume, job.channel, job.phase == .running)
        }
        guard let outcome else { return }
        if outcome.deliver { resume(result) }
        pump(outcome.mountPoint, outcome.channel)
    }

    private func expire(_ id: UInt64, generation: Int) {
        let expired = state.withLock { state -> (Job, degraded: Volume?)? in
            guard let job = state.jobs[id], job.phase == .running, job.generation == generation,
                  var volume = state.volumes[job.volume]
            else { return nil }
            state.jobs[id]?.phase = .timedOut
            volume.stuck += 1
            volume.consecutiveTimeouts += 1
            var degraded: Volume?
            if volume.degradedReason == nil, volume.consecutiveTimeouts >= configuration.degradeAfterTimeouts {
                volume.degradedReason = "连续 \(volume.consecutiveTimeouts) 次调用超过 \(Int(configuration.deadline.timeInterval)) 秒没有返回"
                degraded = volume.volume
            }
            state.volumes[job.volume] = volume
            publish(state)
            return (job, degraded)
        }
        guard let (job, degraded) = expired else { return }
        job.fail(.timeout)
        if let degraded { degrade(degraded) }
    }

    /// 卷变为 degraded：排队中的请求立即失败；网络卷弃用卡住的辅助进程；开始健康探测。
    private func degrade(_ volume: Volume) {
        let queued = state.withLock { state -> [Job] in
            let ids = state.volumes[volume.mountPoint]?.queues.values.flatMap { $0 } ?? []
            state.volumes[volume.mountPoint]?.queues = [.metadata: [], .bulk: []]
            return ids.compactMap { state.jobs.removeValue(forKey: $0) }
        }
        queued.forEach { $0.fail(.volumeDegraded(volume.root)) }
        // 弃用后，卡住的调用以 helperLost 结束，释放槽位。
        backend(for: volume).abandon()
        probe(volume)
    }

    /// 健康探测：见 `FileOperations.probe`，不设期限。硬挂载上它会一直阻塞到网络恢复，返回本身就是恢复的信号，
    /// 所以同一时间只有一个探测，卡住的探测不会引出更多辅助进程。失败时隔一段时间再探。
    private func probe(_ volume: Volume) {
        let start = state.withLock { state -> Bool in
            guard state.volumes[volume.mountPoint]?.probing == false else { return false }
            state.volumes[volume.mountPoint]?.probing = true
            return true
        }
        guard start else { return }
        backend(for: volume).probe(volume.mountPoint) { [weak self] result in
            guard let self else { return }
            let healthy = (try? result.get()) != nil
            state.withLock { state in
                state.volumes[volume.mountPoint]?.probing = false
                if healthy {
                    state.volumes[volume.mountPoint]?.degradedReason = nil
                    state.volumes[volume.mountPoint]?.consecutiveTimeouts = 0
                    publish(state)
                }
            }
            if !healthy {
                timers.asyncAfter(deadline: .now() + configuration.probeInterval.timeInterval) { [weak self] in
                    self?.probe(volume)
                }
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
