import Foundation
import MVFoundation
import MVPipeline
import Synchronization

/// 按插件 ID 串行调度 `filter.apply`，取消排队中的任务时立即出队且不调用插件。
public final class PluginFilterRunner: PluginFilterExecuting, Sendable {
    private let host: PluginHost
    private let queues = Mutex<[String: PriorityPermitQueue]>([:])

    public init(host: PluginHost) {
        self.host = host
    }

    public func version(of plugin: String) -> String? {
        host.enabledVersion(of: plugin)
    }

    public func apply(_ request: PluginFilterRequest, input: URL, output: URL) async throws {
        try Task.checkCancellation()
        let queue = serialQueue(for: request.plugin)
        try await queue.withPermit {
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
                throw PluginError.runtimeError(String(localized: "插件 \(request.plugin) 未写出输出文件：\(output.lastPathComponent)", bundle: .main))
            }
        }
    }

    private func serialQueue(for plugin: String) -> PriorityPermitQueue {
        queues.withLock { map in
            if let existing = map[plugin] { return existing }
            let created = PriorityPermitQueue(limit: 1)
            map[plugin] = created
            return created
        }
    }
}
