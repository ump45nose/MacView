import Foundation
import MVFoundation
import MVPipeline
import Synchronization

/// 按插件 ID 串行调度 `filter.apply`，取消排队中的任务时立即出队且不调用插件。
public final class PluginFilterRunner: PluginFilterExecuting, Sendable {
    private final class SerialQueue: Sendable {
        private struct Waiter {
            var id: UUID
            var continuation: CheckedContinuation<Void, any Error>
        }
        private struct State {
            var busy = false
            var waiters: [Waiter] = []
        }
        private let state = Mutex(State())

        func withTurn<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
            try await acquire()
            defer { release() }
            if Task.isCancelled { throw CancellationError() }
            return try await operation()
        }

        private func acquire() async throws {
            if Task.isCancelled { throw CancellationError() }
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let acquired: Bool = state.withLock { state in
                        if !state.busy {
                            state.busy = true
                            return true
                        }
                        state.waiters.append(Waiter(id: waiterID, continuation: continuation))
                        return false
                    }
                    if acquired { continuation.resume() }
                }
            } onCancel: { [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }

        private func cancelWaiter(id: UUID) {
            let removed = state.withLock { state -> Waiter? in
                guard let idx = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: idx)
            }
            removed?.continuation.resume(throwing: CancellationError())
        }

        private func release() {
            let next = state.withLock { state -> Waiter? in
                if state.waiters.isEmpty {
                    state.busy = false
                    return nil
                }
                return state.waiters.removeFirst()
            }
            next?.continuation.resume()
        }
    }

    private let host: PluginHost
    private let queues = Mutex<[String: SerialQueue]>([:])

    public init(host: PluginHost) {
        self.host = host
    }

    public func version(of plugin: String) -> String? {
        host.enabledVersion(of: plugin)
    }

    public func apply(_ request: PluginFilterRequest, input: URL, output: URL) async throws {
        try Task.checkCancellation()
        let queue = serialQueue(for: request.plugin)
        try await queue.withTurn {
            try Task.checkCancellation()
            let params: JSONValue = .object([
                "filter": .string(request.filter),
                "input": .string(input.path),
                "output": .string(output.path),
                "parameters": .object(request.parameters),
            ])
            _ = try await host.sendRequest(
                plugin: request.plugin,
                method: "filter.apply",
                params: params,
                timeout: host.configuration.filterTimeout
            )
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw PluginError.runtimeError("插件 \(request.plugin) 未写出输出文件：\(output.lastPathComponent)")
            }
        }
    }

    private func serialQueue(for plugin: String) -> SerialQueue {
        queues.withLock { map in
            if let existing = map[plugin] { return existing }
            let created = SerialQueue()
            map[plugin] = created
            return created
        }
    }
}
