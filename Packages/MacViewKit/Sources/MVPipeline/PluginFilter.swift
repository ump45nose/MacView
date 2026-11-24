import Foundation
import MVFoundation

/// 单个插件滤镜的执行请求；管线模块不依赖 MVPlugins 与 MVSettings。
public struct PluginFilterRequest: Sendable, Hashable {
    public var plugin: String
    public var filter: String
    public var parameters: [String: JSONValue]

    public init(plugin: String, filter: String, parameters: [String: JSONValue] = [:]) {
        self.plugin = plugin
        self.filter = filter
        self.parameters = parameters
    }
}

/// 插件滤镜执行协议：由 MVPlugins 实现、组合根注入 `FileImagePipeline`。
public protocol PluginFilterExecuting: Sendable {
    /// 返回已启用插件的版本字符串；插件未启用或不可用时返回 nil。
    func version(of plugin: String) -> String?
    /// 执行插件滤镜，把 `input` 处理结果写到 `output`；随调用方 Task 取消。
    func apply(_ request: PluginFilterRequest, input: URL, output: URL) async throws
}
