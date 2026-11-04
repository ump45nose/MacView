import Foundation
import MVIO
import Synchronization

/// 后台在解码前等额度；前台立即准入，满额时只交付图像、不排衍生件。
final class InFlightBudget: Sendable {
    private struct Waiter {
        var id: UUID
        var bytes: Int64
        var continuation: CheckedContinuation<Bool, any Error>
    }
    private struct State {
        var bytes: Int64 = 0
        var waiting: [Waiter] = []
    }
    private let state = Mutex(State())
    let limit: Int64
    init(limit: Int64 = 512 << 20) { self.limit = limit }
    var snapshot: (bytes: Int64, waiting: Int) { state.withLock { ($0.bytes, $0.waiting.count) } }

    func acquire(_ bytes: Int64, context: RequestContext) async throws -> Bool {
        let id = UUID()
        let binding = context.bind { if $0 >= .near { self.promote(id) } }
        defer { context.unbind(binding) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    if state.bytes < limit || context.priority >= .near {
                        let derivatives = state.bytes < limit
                        state.bytes += bytes
                        continuation.resume(returning: derivatives)
                    } else {
                        state.waiting.append(Waiter(id: id, bytes: bytes, continuation: continuation))
                    }
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { state in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return Optional<Waiter>.none }
                return state.waiting.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func promote(_ id: UUID) {
        let ready = state.withLock { state -> (Waiter, Bool)? in
            guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
            let waiter = state.waiting.remove(at: index)
            let derivatives = state.bytes < limit
            state.bytes += waiter.bytes
            return (waiter, derivatives)
        }
        if let (waiter, derivatives) = ready { waiter.continuation.resume(returning: derivatives) }
    }

    func release(_ bytes: Int64) {
        let ready = state.withLock { state in
            state.bytes -= bytes
            var ready: [Waiter] = []
            while state.bytes < limit, !state.waiting.isEmpty {
                let waiter = state.waiting.removeFirst()
                state.bytes += waiter.bytes
                ready.append(waiter)
            }
            return ready
        }
        for waiter in ready { waiter.continuation.resume(returning: true) }
    }
}
