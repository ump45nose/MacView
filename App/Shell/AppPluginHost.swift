import Foundation
import MVFoundation
import MVPlugins
import MVScripting

/// 将插件的反向 API 调用转交 `AppScriptHost`；权限检查已在 `MVPlugins` 内完成。
final class AppPluginHost: PluginAPIHost, Sendable {
    private let scriptHost: AppScriptHost

    init(scriptHost: AppScriptHost) {
        self.scriptHost = scriptHost
    }

    func call(
        plugin: String,
        method: ScriptAPI.Method,
        params: [JSONValue],
        context: ScriptCallContext
    ) async throws -> JSONValue {
        var pluginContext = context
        pluginContext.caller = "plugin:\(plugin)"
        return try await scriptHost.call(method, params, context: pluginContext)
    }
}
