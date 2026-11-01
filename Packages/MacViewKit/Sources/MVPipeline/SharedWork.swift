import Foundation
import MVIO
import Synchronization

/// 独立的消费者等待同一个任务；取消一个等待者不会取消其他等待者。
final class SharedWork<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var task: Task<Void, Never>?
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

    init(scheduler: IOScheduler?) { self.scheduler = scheduler }

    var isAccepting: Bool { state.withLock { $0.accepting } }
    var priority: IOPriority { state.withLock { $0.priorities.values.max() ?? .background } }

    func setPriority(_ priority: IOPriority, consumer: UUID) {
        let effective = state.withLock { state in
            if state.priorities[consumer] != nil { state.priorities[consumer] = priority }
            return state.priorities.values.max() ?? .background
        }
        context.setPriority(effective)
        scheduler?.setPriority(effective, for: group)
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
                context.setPriority(action.2)
                scheduler?.setPriority(action.2, for: group)
                guard action.1 else { return }
                let task = Task(priority: action.2.taskPriority) {
                    let result: Result<Value, any Error>
                    do { result = .success(try await operation(self)) }
                    catch { result = .failure(error) }
                    finish(result)
                }
                let cancelled = state.withLock { state in
                    state.task = task
                    return state.waiters.isEmpty && state.result == nil
                }
                if cancelled { task.cancel() }
            }
        } onCancel: { self.cancel(consumer) }
    }

    private func cancel(_ consumer: UUID) {
        let action = state.withLock { state -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?, IOPriority) in
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
    var taskPriority: TaskPriority {
        switch self {
        case .visible: .userInitiated
        case .near: .high
        case .book: .medium
        case .adjacent: .low
        case .background: .background
        }
    }
}
