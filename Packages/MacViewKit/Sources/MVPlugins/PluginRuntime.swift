import Foundation
import MVFoundation
import MVScripting

public struct PluginHTTPRequest: Sendable, Hashable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: String?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct PluginHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: String
    public var bodyBase64: String?

    public init(status: Int, headers: [String: String] = [:], body: String = "", bodyBase64: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyBase64 = bodyBase64
    }
}

public enum PluginError: Error, LocalizedError, Sendable, Equatable {
    case notFound(String)
    case disabled(String)
    case needsConsent(String)
    case invalid(PluginProblem)
    case missingPermission(plugin: String, permission: PluginPermission)
    case timeout(method: String)
    case cancelled
    case processExited(code: Int32)
    case rpcError(code: Int, message: String)
    case runtimeError(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "找不到插件：\(id)"
        case .disabled(let id):
            return "插件未启用：\(id)"
        case .needsConsent(let id):
            return "插件需要重新确认权限：\(id)"
        case .invalid(let problem):
            return problem.errorDescription ?? problem.message
        case let .missingPermission(plugin, permission):
            return "插件 \(plugin) 缺少权限：\(permission.rawValue)"
        case .timeout(let method):
            return "插件请求超时：\(method)"
        case .cancelled:
            return "插件请求已取消"
        case .processExited(let code):
            return "插件进程已退出（代码 \(code)）"
        case let .rpcError(_, message):
            return message
        case .runtimeError(let message):
            return message
        }
    }
}

public protocol PluginAPIHost: Sendable {
    func call(plugin: String, method: ScriptAPI.Method, params: [JSONValue], context: ScriptCallContext) async throws -> JSONValue
}

public struct PluginHostConfiguration: Sendable {
    public var pythonLibraryDirectory: URL?
    public var supportDirectory: URL?
    public var appVersion: String
    public var language: String
    public var idleTimeout: Duration
    public var requestTimeout: Duration
    public var filterTimeout: Duration
    /// 仅供测试注入的 `mv.http` 处理函数；为 nil 时使用 `URLSession.shared`。
    public var httpHandler: (@Sendable (PluginHTTPRequest) async throws -> PluginHTTPResponse)?

    public init(
        pythonLibraryDirectory: URL? = nil,
        supportDirectory: URL? = nil,
        appVersion: String = "1.0",
        language: String = Locale.preferredLanguages.first ?? "zh-Hans",
        idleTimeout: Duration = .seconds(300),
        requestTimeout: Duration = .seconds(30),
        filterTimeout: Duration = .seconds(120),
        httpHandler: (@Sendable (PluginHTTPRequest) async throws -> PluginHTTPResponse)? = nil
    ) {
        self.pythonLibraryDirectory = pythonLibraryDirectory
        self.supportDirectory = supportDirectory
        self.appVersion = appVersion
        self.language = language
        self.idleTimeout = idleTimeout
        self.requestTimeout = requestTimeout
        self.filterTimeout = filterTimeout
        self.httpHandler = httpHandler
    }
}

protocol PluginConnection: AnyObject, Sendable {
    func request(
        method: String,
        params: JSONValue,
        timeout: Duration,
        callContext: ScriptCallContext
    ) async throws -> JSONValue
    func notify(method: String, params: JSONValue, callContext: ScriptCallContext) async
    /// 停止当前在途请求（JS 保留常驻上下文，外部程序结束进程组）。
    func stop()
    /// 彻底销毁连接与后台线程/进程（热重载、停用或关闭宿主时调用）。
    func terminate()
}
