import Foundation
import MVFoundation
import MVIO
import MVScripting
import Synchronization

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
            return String(localized: "找不到插件：\(id)", bundle: .main)
        case .disabled(let id):
            return String(localized: "插件未启用：\(id)", bundle: .main)
        case .needsConsent(let id):
            return String(localized: "插件需要重新确认权限：\(id)", bundle: .main)
        case .invalid(let problem):
            return problem.errorDescription ?? problem.message
        case let .missingPermission(plugin, permission):
            return String(localized: "插件 \(plugin) 缺少权限：\(permission.rawValue)", bundle: .main)
        case .timeout(let method):
            return String(localized: "插件请求超时：\(method)", bundle: .main)
        case .cancelled:
            return String(localized: "插件请求已取消", bundle: .main)
        case .processExited(let code):
            return String(localized: "插件进程已退出（代码 \(code)）", bundle: .main)
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
    var isClosed: Bool { get }
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

/// 保障 `CheckedContinuation` 至多恢复一次。
final class OnceContinuation<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>
    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }
    func resume(with result: Result<Value, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

/// 并发限流与排队原语：支持按 `IOPriority` 出队，且取消在锁内无竞态地出队。
final class PriorityPermitQueue: Sendable {
    private struct Waiter {
        var id: UUID
        var priority: IOPriority
        var sequence: UInt64
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var active = 0
        var sequence: UInt64 = 0
        var waiters: [Waiter] = []
        var cancelledBeforeEnqueue: Set<UUID> = []
    }

    private let limit: Int
    private let cancellationError: @Sendable () -> any Error
    private let state = Mutex(State())

    init(limit: Int, cancellationError: @escaping @Sendable () -> any Error = { CancellationError() }) {
        self.limit = max(1, limit)
        self.cancellationError = cancellationError
    }

    func withPermit<Value: Sendable>(
        priority: IOPriority = .visible,
        operation: () async throws -> Value
    ) async throws -> Value {
        try await acquire(priority: priority)
        defer { release() }
        if Task.isCancelled { throw cancellationError() }
        return try await operation()
    }

    private func acquire(priority: IOPriority) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case acquired, cancelled, queued }
                let outcome: Outcome = state.withLock { state in
                    if state.cancelledBeforeEnqueue.remove(waiterID) != nil || Task.isCancelled {
                        return .cancelled
                    }
                    if state.active < limit {
                        state.active += 1
                        return .acquired
                    }
                    state.sequence &+= 1
                    state.waiters.append(Waiter(id: waiterID, priority: priority, sequence: state.sequence, continuation: continuation))
                    return .queued
                }
                switch outcome {
                case .acquired: continuation.resume()
                case .cancelled: continuation.resume(throwing: cancellationError())
                case .queued: break
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id: waiterID)
        }
    }

    private func cancelWaiter(id: UUID) {
        let removed = state.withLock { state -> Waiter? in
            if let idx = state.waiters.firstIndex(where: { $0.id == id }) {
                return state.waiters.remove(at: idx)
            }
            state.cancelledBeforeEnqueue.insert(id)
            return nil
        }
        removed?.continuation.resume(throwing: cancellationError())
    }

    private func release() {
        let next = state.withLock { state -> Waiter? in
            if state.waiters.isEmpty {
                state.active = max(0, state.active - 1)
                return nil
            }
            var bestIndex = 0
            for index in 1..<state.waiters.count {
                let candidate = state.waiters[index]
                let best = state.waiters[bestIndex]
                if candidate.priority > best.priority || (candidate.priority == best.priority && candidate.sequence < best.sequence) {
                    bestIndex = index
                }
            }
            return state.waiters.remove(at: bestIndex)
        }
        next?.continuation.resume()
    }
}
