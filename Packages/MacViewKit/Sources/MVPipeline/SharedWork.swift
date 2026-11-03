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
final class SharedWork<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var task: Task<Void, any Error>?
        var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
        var priorities: [UUID: IOPriority] = [:]
        var cancelled: Set<UUID> = []
        var result: Result<Value, any Error>?
        var started = false
        var accepting = true
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

    var isAccepting: Bool { state.withLock { $0.accepting } }
    var priority: IOPriority { state.withLock { $0.priorities.values.max() ?? .background } }

    func setPriority(_ priority: IOPriority, consumer: UUID) {
        let effective = state.withLock { state in
            if state.priorities[consumer] != nil { state.priorities[consumer] = priority }
            return state.priorities.values.max() ?? .background
        }
        apply(effective)
    }

    /// 消费者通过续体等待，运行时不会把优先级传给运行中的任务；任务优先级只升不降。
    private func apply(_ priority: IOPriority) {
        context.setPriority(priority)
        scheduler?.setPriority(priority, for: group)
        state.withLock { $0.task }?.escalatePriority(to: priority.taskPriority)
    }

    func value(consumer: UUID = UUID(), priority: IOPriority, operation: @escaping @Sendable (SharedWork<Value>) async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let action = state.withLock { state -> (Result<Value, any Error>?, Bool, IOPriority) in
                    if !state.accepting { return (.failure(CancellationError()), false, priority) }
                    if state.cancelled.remove(consumer) != nil { return (.failure(CancellationError()), false, priority) }
                    if let result = state.result { return (result, false, priority) }
                    state.waiters[consumer] = continuation
                    state.priorities[consumer] = priority
                    let start = !state.started
                    state.started = true
                    return (nil, start, state.priorities.values.max() ?? priority)
                }
                if let result = action.0 { continuation.resume(with: result); return }
                apply(action.2)
                guard action.1 else { return }
                let task: Task<Void, any Error>
                do {
                    task = try lifetime.start(priority: action.2.taskPriority) {
                        let result: Result<Value, any Error>
                        do {
                            try self.lifetime.checkRunning()
                            result = .success(try await operation(self))
                        }
                        catch { result = .failure(error) }
                        self.finish(result)
                    }
                } catch { finish(.failure(error)); return }
                // 任务登记之前加入的消费者没能提升它。
                let (cancelled, effective) = state.withLock { state in
                    state.task = task
                    return (state.waiters.isEmpty && state.result == nil, state.priorities.values.max())
                }
                if let effective { task.escalatePriority(to: effective.taskPriority) }
                if cancelled { task.cancel() }
            }
        } onCancel: { self.cancel(consumer) }
    }

    private func cancel(_ consumer: UUID) {
        let action = state.withLock { state -> (CheckedContinuation<Value, any Error>?, Task<Void, any Error>?, IOPriority) in
            guard let continuation = state.waiters.removeValue(forKey: consumer) else {
                if state.result == nil { state.cancelled.insert(consumer) }
                return (nil, nil, state.priorities.values.max() ?? .background)
            }
            state.priorities[consumer] = nil
            if state.waiters.isEmpty { state.accepting = false }
            return (continuation, state.waiters.isEmpty ? state.task : nil, state.priorities.values.max() ?? .background)
        }
        context.setPriority(action.2)
        action.0?.resume(throwing: CancellationError())
        if let task = action.1 { scheduler?.cancel(group); task.cancel() }
        else { scheduler?.setPriority(action.2, for: group) }
    }

    private func finish(_ result: Result<Value, any Error>) {
        let waiters = state.withLock { state in
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            state.priorities.removeAll()
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
