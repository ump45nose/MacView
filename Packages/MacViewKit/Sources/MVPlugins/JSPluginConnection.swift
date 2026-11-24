import Foundation
import JavaScriptCore
import MVFoundation
import MVScripting
import Synchronization

/// JS 插件常驻连接：专用线程 + 常驻 JSContext，请求串行执行，支持超时与 stop 后复用。
final class JSPluginConnection: PluginConnection, @unchecked Sendable {
    private struct WorkItem: Sendable {
        var id: UUID
        var method: String
        var params: JSONValue
        var timeout: Duration
        var callContext: ScriptCallContext
        var isNotification: Bool
        var completion: (@Sendable (Result<JSONValue, any Error>) -> Void)?
    }

    private let info: PluginInfo
    private let manifest: PluginManifest
    private let entryFile: String
    private let configuration: PluginHostConfiguration
    private let log: ScriptLog
    private let apiHostProvider: @Sendable () -> (any PluginAPIHost)?
    private let control = JSExecutionControl()
    private let activeContext: Mutex<ScriptCallContext>
    private let condition = NSCondition()
    private var queue: [WorkItem] = []
    private var cancelledBeforeEnqueue: Set<UUID> = []
    private var currentWorkID: UUID?
    private var terminated = false
    private let onLoadFailure: @Sendable (JSPluginConnection, String) -> Void

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return terminated
    }

    init(
        info: PluginInfo,
        manifest: PluginManifest,
        entryFile: String,
        configuration: PluginHostConfiguration,
        log: ScriptLog,
        apiHostProvider: @escaping @Sendable () -> (any PluginAPIHost)?,
        onLoadFailure: @escaping @Sendable (JSPluginConnection, String) -> Void
    ) {
        self.info = info
        self.manifest = manifest
        self.entryFile = entryFile
        self.configuration = configuration
        self.log = log
        self.apiHostProvider = apiHostProvider
        self.onLoadFailure = onLoadFailure
        self.activeContext = Mutex(ScriptCallContext(caller: "plugin:\(info.id)", callerName: manifest.name, session: nil, selection: []))
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread.name = "MacView.Plugin.JS.\(info.id)"
        thread.start()
    }

    func request(
        method: String,
        params: JSONValue,
        timeout: Duration,
        callContext: ScriptCallContext
    ) async throws -> JSONValue {
        let workID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeOnce = OnceContinuation(continuation)
                let item = WorkItem(
                    id: workID,
                    method: method,
                    params: params,
                    timeout: timeout,
                    callContext: callContext,
                    isNotification: false,
                    completion: { result in resumeOnce.resume(with: result) }
                )
                switch enqueue(item) {
                case .queued:
                    break
                case .cancelled:
                    resumeOnce.resume(with: .failure(CancellationError()))
                case .terminated:
                    resumeOnce.resume(with: .failure(PluginError.cancelled))
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWork(id: workID)
        }
    }

    func notify(method: String, params: JSONValue, callContext: ScriptCallContext) async {
        let item = WorkItem(
            id: UUID(),
            method: method,
            params: params,
            timeout: configuration.requestTimeout,
            callContext: callContext,
            isNotification: true,
            completion: nil
        )
        _ = enqueue(item)
    }

    private enum EnqueueOutcome { case queued, cancelled, terminated }

    private func enqueue(_ item: WorkItem) -> EnqueueOutcome {
        condition.lock()
        defer { condition.unlock() }
        if terminated { return .terminated }
        if cancelledBeforeEnqueue.remove(item.id) != nil || (!item.isNotification && Task.isCancelled) {
            return .cancelled
        }
        queue.append(item)
        condition.signal()
        return .queued
    }

    func stop() {
        condition.lock()
        let queued = queue
        queue.removeAll()
        if currentWorkID != nil {
            control.stop()
        }
        condition.unlock()
        for item in queued {
            item.completion?(.failure(PluginError.cancelled))
        }
    }

    func terminate() {
        condition.lock()
        terminated = true
        let queued = queue
        queue.removeAll()
        control.stop()
        condition.broadcast()
        condition.unlock()
        for item in queued {
            item.completion?(.failure(PluginError.cancelled))
        }
    }

    private func cancelWork(id: UUID) {
        var removed: WorkItem?
        condition.lock()
        if let idx = queue.firstIndex(where: { $0.id == id }) {
            removed = queue.remove(at: idx)
        } else if currentWorkID == id {
            control.stop()
        } else {
            cancelledBeforeEnqueue.insert(id)
        }
        condition.unlock()
        if let removed {
            removed.completion?(.failure(CancellationError()))
        }
    }

    private func runLoop() {
        let entryURL = info.directory.appendingPathComponent(entryFile)
        var context: JSContext?
        var loadError: String?

        func ensureContext() -> JSContext? {
            if let context { return context }
            if loadError != nil { return nil }
            guard let source = try? String(contentsOf: entryURL, encoding: .utf8) else {
                loadError = "无法读取 JS 插件入口：\(entryFile)"
                log.append(source: manifest.name, level: .error, text: loadError!)
                onLoadFailure(self, loadError!)
                return nil
            }
            guard let created = makeJSContext() else {
                loadError = "无法创建 JavaScript 环境"
                onLoadFailure(self, loadError!)
                return nil
            }
            _ = JSBridge.setExecutionTimeLimit(on: created, interval: 0.05, control: control)
            created.evaluateScript("globalThis.plugin = { commands: {}, sources: {}, onEvent: null };")
            created.evaluateScript("mv.log = (...args) => __mvLog('info', args);")
            if !control.isStopped {
                created.evaluateScript(source, withSourceURL: entryURL)
            }
            if control.isStopped {
                JSBridge.clearExecutionTimeLimit(on: created)
                return nil
            }
            if let problem = JSBridge.exceptionProblem(from: created) {
                let message = problem.line.map { "第 \($0) 行：\(problem.message)" } ?? problem.message
                loadError = message
                log.append(source: manifest.name, level: .error, text: message)
                onLoadFailure(self, message)
                JSBridge.clearExecutionTimeLimit(on: created)
                return nil
            }
            context = created
            return created
        }

        defer {
            if let context {
                JSBridge.clearExecutionTimeLimit(on: context)
            }
        }

        while true {
            condition.lock()
            while queue.isEmpty && !terminated {
                condition.wait()
            }
            if terminated {
                let remaining = queue
                queue.removeAll()
                currentWorkID = nil
                condition.unlock()
                for item in remaining {
                    item.completion?(.failure(PluginError.cancelled))
                }
                return
            }
            let item = queue.removeFirst()
            currentWorkID = item.id
            // 在持锁状态下与 stop()/cancelWork() 严格定序，避免 stop() 信号在 begin() 之前丢失。
            control.begin(timeout: item.timeout)
            condition.unlock()

            let result = execute(item, ensureContext: ensureContext, loadError: { loadError })

            condition.lock()
            if currentWorkID == item.id {
                currentWorkID = nil
            }
            condition.unlock()

            if item.isNotification {
                if case let .failure(error) = result {
                    log.append(source: manifest.name, level: .error, text: error.localizedDescription)
                }
            } else {
                item.completion?(result)
            }
        }
    }

    private func execute(
        _ item: WorkItem,
        ensureContext: () -> JSContext?,
        loadError: () -> String?
    ) -> Result<JSONValue, any Error> {
        guard let context = ensureContext() else {
            let (wasStopped, termReason) = control.endAndSnapshot()
            if wasStopped {
                return .failure(termReason == .timedOut ? PluginError.timeout(method: item.method) : PluginError.cancelled)
            }
            return .failure(PluginError.runtimeError(loadError() ?? "插件上下文不可用"))
        }
        activeContext.withLock { $0 = item.callContext }
        context.exception = nil
        _ = JSBridge.setExecutionTimeLimit(on: context, interval: 0.05, control: control)
        let jsResult = control.isStopped ? nil : dispatch(method: item.method, params: item.params, in: context)
        let (wasStopped, termReason) = control.endAndSnapshot()

        if wasStopped {
            _ = JSBridge.resetAfterTermination(on: context, interval: 0.05, control: control)
            if termReason == .timedOut {
                return .failure(PluginError.timeout(method: item.method))
            }
            return .failure(PluginError.cancelled)
        }
        if let problem = JSBridge.exceptionProblem(from: context) {
            context.exception = nil
            let message = problem.line.map { "第 \($0) 行：\(problem.message)" } ?? problem.message
            return .failure(PluginError.runtimeError(message))
        }
        if let jsResult {
            return .success(JSBridge.jsonValue(jsResult))
        }
        return .success(.object([:]))
    }

    private func dispatch(method: String, params: JSONValue, in context: JSContext) -> JSValue? {
        let paramsValue = JSBridge.jsValue(params, in: context)
        switch method {
        case "initialize":
            return JSBridge.jsValue(.object([:]), in: context)
        case "command.run":
            let fn = context.evaluateScript("""
            (function(p) {
              const handler = globalThis.plugin && globalThis.plugin.commands && globalThis.plugin.commands[p.command];
              if (typeof handler !== 'function') throw new Error('插件未注册命令：' + p.command);
              return handler(p.arguments || {}, p.context || {});
            })
            """)
            return fn?.call(withArguments: [paramsValue])
        case "event":
            let fn = context.evaluateScript("""
            (function(p) {
              if (globalThis.plugin && typeof globalThis.plugin.onEvent === 'function') {
                globalThis.plugin.onEvent(p.name, p.payload || {}, p.session || null);
              }
            })
            """)
            return fn?.call(withArguments: [paramsValue])
        case "source.list":
            let fn = context.evaluateScript("""
            (function(p) {
              const src = p.source || {};
              const handler = globalThis.plugin && globalThis.plugin.sources && globalThis.plugin.sources[src.type];
              if (!handler || typeof handler.list !== 'function') throw new Error('插件未注册来源：' + src.type);
              const res = handler.list(src, p.path || []);
              return Array.isArray(res) ? { entries: res } : (res || { entries: [] });
            })
            """)
            return fn?.call(withArguments: [paramsValue])
        case "source.read":
            let fn = context.evaluateScript("""
            (function(p) {
              const src = p.source || {};
              const handler = globalThis.plugin && globalThis.plugin.sources && globalThis.plugin.sources[src.type];
              if (!handler || typeof handler.read !== 'function') throw new Error('来源不支持 source.read：' + src.type);
              const res = handler.read(src, p.path || [], p.offset || 0, p.length || 0);
              return typeof res === 'string' ? { data: res } : (res || { data: '' });
            })
            """)
            return fn?.call(withArguments: [paramsValue])
        default:
            context.exception = JSValue(newErrorFromMessage: "不支持的插件方法：\(method)", in: context)
            return nil
        }
    }

    private func makeJSContext() -> JSContext? {
        let pluginID = info.id
        let permissions = Set(manifest.permissions)
        let manifestName = manifest.name
        let control = self.control
        let apiHostProvider = self.apiHostProvider
        let configuration = self.configuration
        let log = self.log

        let httpMethod: @Sendable ([JSONValue]) throws -> JSONValue = { args in
            guard permissions.contains(.network) else {
                throw PluginError.missingPermission(plugin: pluginID, permission: .network)
            }
            guard case let .object(reqObj) = args.first,
                  case let .string(urlString)? = reqObj["url"],
                  !urlString.isEmpty else {
                throw PluginError.runtimeError("mv.http 需要包含有效 url 的对象参数")
            }
            let method: String
            if case let .string(m)? = reqObj["method"], !m.isEmpty { method = m } else { method = "GET" }
            var headers: [String: String] = [:]
            if case let .object(h)? = reqObj["headers"] {
                for (k, v) in h {
                    if case let .string(s) = v { headers[k] = s }
                }
            }
            let body: String?
            if case let .string(b)? = reqObj["body"] { body = b } else { body = nil }
            let request = PluginHTTPRequest(url: urlString, method: method, headers: headers, body: body)
            return try control.syncCall {
                let response: PluginHTTPResponse
                if let customHandler = configuration.httpHandler {
                    response = try await customHandler(request)
                } else {
                    response = try await Self.performHTTP(request)
                }
                var dict: [String: JSONValue] = [
                    "status": .number(Double(response.status)),
                    "headers": .object(response.headers.mapValues(JSONValue.string)),
                    "body": .string(response.body),
                ]
                if let b64 = response.bodyBase64 {
                    dict["bodyBase64"] = .string(b64)
                }
                return .object(dict)
            }
        }

        return JSBridge.makeContext(
            call: { [weak self] method, args in
                if method == .command && !permissions.contains(.commands) {
                    throw PluginError.missingPermission(plugin: pluginID, permission: .commands)
                }
                guard let host = apiHostProvider() else {
                    throw PluginError.runtimeError("插件宿主 API 不可用")
                }
                let ctx = self?.activeContext.withLock { $0 } ?? ScriptCallContext(caller: "plugin:\(pluginID)", callerName: manifestName, session: nil, selection: [])
                return try control.syncCall {
                    try await host.call(plugin: pluginID, method: method, params: args, context: ctx)
                }
            },
            log: { level, text in
                log.append(source: manifestName, level: level, text: text)
            },
            extraMethods: ["http": httpMethod]
        )
    }

    private static func performHTTP(_ request: PluginHTTPRequest) async throws -> PluginHTTPResponse {
        guard let url = URL(string: request.url) else {
            throw PluginError.runtimeError("无效的 URL：\(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw PluginError.runtimeError("非 HTTP 响应")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        let text = String(data: data, encoding: .utf8)
        let bodyText = text ?? String(decoding: data, as: UTF8.self)
        let base64 = text == nil ? data.base64EncodedString() : nil
        return PluginHTTPResponse(status: http.statusCode, headers: headers, body: bodyText, bodyBase64: base64)
    }
}
