import Foundation
import MVIO
import Synchronization

/// 任务的登记、步骤准入和停止共用一个关口；取消消费者不会提前移除实际仍在运行的任务。
final class PipelineLifetime: Sendable {
    private struct State: Sendable {
        var stopped = false
        var tasks: [UUID: @Sendable () -> Void] = [:]
        var drained: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func checkRunning() throws {
        try Task.checkCancellation()
        try state.withLock { if $0.stopped { throw CancellationError() } }
    }

    /// 在锁内准入并登记，再让任务执行；shutdown 不会漏掉尚未开始执行的任务。
    func start<Value: Sendable>(priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> Value) throws -> Task<Value, any Error> {
        try state.withLock { state in
            guard !state.stopped else { throw CancellationError() }
            let id = UUID()
            let task = Task(priority: priority) {
                defer { self.finished(id) }
                return try await operation()
            }
            state.tasks[id] = { task.cancel() }
            return task
        }
    }

    func value<Value: Sendable>(priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let task = try start(priority: priority) {
            try self.checkRunning()
            return try await operation()
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }

    /// 同步缓存写入与停止也在同一把锁上排序。
    func whileRunning<Value>(_ operation: () throws -> Value) throws -> Value {
        try state.withLock { state in
            guard !state.stopped else { throw CancellationError() }
            return try operation()
        }
    }

    func stop() {
        let tasks = state.withLock { state in
            state.stopped = true
            return Array(state.tasks.values)
        }
        for cancel in tasks { cancel() }
    }

    func shutdown() async {
        stop()
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state in
                if state.tasks.isEmpty { return true }
                state.drained.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }

    private func finished(_ id: UUID) {
        let waiters = state.withLock { state in
            state.tasks[id] = nil
            guard state.stopped, state.tasks.isEmpty else { return [CheckedContinuation<Void, Never>]() }
            defer { state.drained.removeAll() }
            return state.drained
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// 独立的消费者等待同一个任务；取消一个等待者不会取消其他等待者。
/// 消费者先在登记表的锁内 `join` 成为成员，再调用 `value`。只有最后一个成员因取消退出时作业才放弃，
/// 放弃后 `join` 返回 false，所以加入和放弃不会交错。
final class SharedWork<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var task: Task<Void, any Error>?
        var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
        /// 已加入的成员及其优先级，包括还没开始等待的。
        var members: [UUID: IOPriority] = [:]
        var cancelled: Set<UUID> = []
        var result: Result<Value, any Error>?
        var started = false
        var abandoned = false
    }
    private let state = Mutex(State())
    let group = IORequestGroup()
    let context = RequestContext(.background)
    private let scheduler: IOScheduler?
    private let lifetime: PipelineLifetime

    init(scheduler: IOScheduler?, lifetime: PipelineLifetime) {
        self.scheduler = scheduler
        self.lifetime = lifetime
    }

    var priority: IOPriority { state.withLock { $0.members.values.max() ?? .background } }

    /// 在登记表的锁内调用，不回调登记表。返回 false 表示作业已放弃，调用方应换一个新作业。
    func join(consumer: UUID, priority: IOPriority) -> Bool {
        state.withLock { state in
            guard !state.abandoned else { return false }
            state.members[consumer] = priority
            return true
        }
    }

    func setPriority(_ priority: IOPriority, consumer: UUID) {
        let effective = state.withLock { state in
            if state.members[consumer] != nil { state.members[consumer] = priority }
            return state.members.values.max() ?? .background
        }
        apply(effective)
    }

    /// 消费者通过续体等待，运行时不会把优先级传给运行中的任务；任务优先级只升不降。
    private func apply(_ priority: IOPriority) {
        context.setPriority(priority)
        scheduler?.setPriority(priority, for: group)
        state.withLock { $0.task }?.escalatePriority(to: priority.taskPriority)
    }

    private enum Admission {
        case deliver(Result<Value, any Error>)
        case cancelled(abandoned: Bool, task: Task<Void, any Error>?)
        case wait(start: Bool, priority: IOPriority)
    }

    /// `consumer` 必须已经 `join`；拿到结果、自己被取消、作业出错时都会退出成员关系。
    func value(consumer: UUID, priority: IOPriority, operation: @escaping @Sendable (SharedWork<Value>) async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            if Task.isCancelled {
                let action = state.withLock { state in (Self.leave(consumer, cancelled: true, in: &state), state.task) }
                if action.0 { abandon(action.1) }
                throw CancellationError()
            }
            return try await withCheckedThrowingContinuation { continuation in
                let action = state.withLock { state -> Admission in
                    if state.cancelled.contains(consumer) { return .cancelled(abandoned: Self.leave(consumer, cancelled: true, in: &state), task: state.task) }
                    if let result = state.result {
                        _ = Self.leave(consumer, cancelled: false, in: &state)
                        return .deliver(result)
                    }
                    state.waiters[consumer] = continuation
                    state.members[consumer] = priority
                    let start = !state.started
                    state.started = true
                    return .wait(start: start, priority: state.members.values.max() ?? priority)
                }
                switch action {
                case let .deliver(result): continuation.resume(with: result)
                case let .cancelled(abandoned, task):
                    if abandoned { abandon(task) }
                    continuation.resume(throwing: CancellationError())
                case let .wait(start, priority):
                    apply(priority)
                    guard start else { return }
                    let task: Task<Void, any Error>
                    do {
                        task = try lifetime.start(priority: priority.taskPriority) {
                            let result: Result<Value, any Error>
                            do {
                                try self.lifetime.checkRunning()
                                result = .success(try await operation(self))
                            }
                            catch { result = .failure(error) }
                            self.finish(result)
                        }
                    } catch { finish(.failure(error)); return }
                    // 任务登记之前加入的消费者没能提升它；登记之前全部成员已取消时由这里取消。
                    let (abandoned, effective) = state.withLock { state in
                        state.task = task
                        return (state.abandoned, state.members.values.max())
                    }
                    if let effective { task.escalatePriority(to: effective.taskPriority) }
                    if abandoned { task.cancel() }
                }
            }
        } onCancel: { self.cancel(consumer) }
    }

    /// 在作业的锁内退出成员关系。因取消退出、没有成员剩下且还没有结果时放弃作业，之后 `join` 都返回 false。
    private static func leave(_ consumer: UUID, cancelled: Bool, in state: inout State) -> Bool {
        state.members[consumer] = nil
        state.cancelled.remove(consumer)
        guard cancelled, state.members.isEmpty, state.result == nil else { return false }
        state.abandoned = true
        return true
    }

    private func abandon(_ task: Task<Void, any Error>?) {
        scheduler?.cancel(group)
        task?.cancel()
    }

    private func cancel(_ consumer: UUID) {
        let action = state.withLock { state -> (CheckedContinuation<Value, any Error>?, Bool, Task<Void, any Error>?, IOPriority) in
            guard let continuation = state.waiters.removeValue(forKey: consumer) else {
                // 还没开始等待的成员，由 `value` 看到标记后退出。
                if state.members[consumer] != nil, state.result == nil { state.cancelled.insert(consumer) }
                return (nil, false, nil, state.members.values.max() ?? .background)
            }
            let abandoned = Self.leave(consumer, cancelled: true, in: &state)
            return (continuation, abandoned, state.task, state.members.values.max() ?? .background)
        }
        context.setPriority(action.3)
        action.0?.resume(throwing: CancellationError())
        if action.1 { abandon(action.2) }
        else { scheduler?.setPriority(action.3, for: group) }
    }

    private func finish(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state in
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            state.members.removeAll()
            state.task = nil
            return waiters
        }
        for continuation in waiters { continuation.resume(with: result) }
    }
}

extension IOPriority {
    /// 可见页必须高于预取。`.userInitiated` 和 `.high` 的原始值都是 25，解码队列同档先进先出。
    var taskPriority: TaskPriority {
        switch self {
        case .visible: .high
        case .near: .medium
        case .book: .low
        case .adjacent: .low
        case .background: .background
        }
    }
}
