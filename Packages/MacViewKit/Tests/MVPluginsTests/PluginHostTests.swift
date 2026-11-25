import Foundation
import MVFoundation
import MVScripting
import MVSettings
import Synchronization
import Testing
@testable import MVPlugins

private final class StubAPIHost: PluginAPIHost, Sendable {
    struct Call: Sendable {
        var plugin: String
        var method: ScriptAPI.Method
        var params: [JSONValue]
        var context: ScriptCallContext
    }

    let calls = Mutex<[Call]>([])
    let handler: @Sendable (String, ScriptAPI.Method, [JSONValue], ScriptCallContext) async throws -> JSONValue

    init(handler: @escaping @Sendable (String, ScriptAPI.Method, [JSONValue], ScriptCallContext) async throws -> JSONValue = { _, _, _, _ in .object(["ok": .bool(true)]) }) {
        self.handler = handler
    }

    func call(plugin: String, method: ScriptAPI.Method, params: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        calls.withLock { $0.append(Call(plugin: plugin, method: method, params: params, context: context)) }
        return try await handler(plugin, method, params, context)
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeHostEnv(_ name: String) throws -> (root: URL, pluginsDir: URL, settings: JSONDocumentStore<PluginSettingsFile>, secrets: PluginSecrets, log: ScriptLog) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/MVPluginsHostTests/\(name)-\(UUID().uuidString)")
    let pluginsDir = root.appendingPathComponent("Plugins")
    try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    let settings = try JSONDocumentStore(fileURL: root.appendingPathComponent("plugins.json"), version: 1, defaultValue: PluginSettingsFile())
    let secrets = try PluginSecrets(fileURL: root.appendingPathComponent("plugin-secrets.json"))
    let log = ScriptLog()
    return (root, pluginsDir, settings, secrets, log)
}

private func waitUntil(timeout: Duration = .seconds(3), _ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            while !Task.isCancelled {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private let sampleContext = ScriptCallContext(caller: "test", callerName: "Test", session: nil, selection: [])

@Test func jsPluginCallsHostAndEnforcesPermissions() async throws {
    let env = try makeHostEnv("js-perms")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("js-demo")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try """
    {
      "name": "JS Demo",
      "version": "1.0",
      "runtime": { "js": "main.js" },
      "permissions": [],
      "commands": [
        { "id": "goto", "title": "跳页" },
        { "id": "need-cmd", "title": "执行命令" },
        { "id": "need-net", "title": "请求网络" }
      ],
      "events": ["pageChanged"]
    }
    """.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try """
    plugin.commands.goto = (args) => {
      const r = mv.goTo(args.index);
      return { res: r };
    };
    plugin.commands["need-cmd"] = () => mv.command("page.next");
    plugin.commands["need-net"] = () => mv.http({ url: "https://example.com" });
    """.write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["js-demo"] = PluginState(enabled: true, grantedPermissions: []) }
    let httpCalled = Mutex(false)
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "js-demo" } })

    let config = PluginHostConfiguration(
        supportDirectory: env.root,
        httpHandler: { _ in
            httpCalled.withLock { $0 = true }
            return PluginHTTPResponse(status: 200, body: "ok")
        }
    )
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log, configuration: config)
    defer { host.shutdown() }
    let apiHost = StubAPIHost { _, method, params, _ in
        if method == .goTo { return .object(["jumped": params.first ?? .null]) }
        return .null
    }
    host.setAPIHost(apiHost)

    // hasSubscribers 与清单一致
    #expect(host.hasSubscribers(for: .pageChanged))
    #expect(!host.hasSubscribers(for: .startup))

    // mv.goTo 反向调用成功
    let result = try await host.runCommand(plugin: "js-demo", command: "goto", arguments: ["index": .number(5)], context: sampleContext)
    #expect(result == .object(["res": .object(["jumped": .number(5)])]))
    #expect(apiHost.calls.withLock { $0.count == 1 && $0[0].method == .goTo && $0[0].context.caller == "plugin:js-demo" })

    // 缺 commands 权限时抛写明权限的错误，且宿主替身没收到调用
    do {
        _ = try await host.runCommand(plugin: "js-demo", command: "need-cmd", arguments: nil, context: sampleContext)
        Issue.record("缺 commands 权限应失败")
    } catch {
        #expect(error.localizedDescription.contains("commands"))
        #expect(apiHost.calls.withLock { !$0.contains { $0.method == .command } })
    }

    // 缺 network 权限时 mv.http 抛写明权限的错误，且未调用网络
    do {
        _ = try await host.runCommand(plugin: "js-demo", command: "need-net", arguments: nil, context: sampleContext)
        Issue.record("缺 network 权限应失败")
    } catch {
        #expect(error.localizedDescription.contains("network"))
        #expect(httpCalled.withLock { !$0 })
    }
}

@Test func jsPluginHotReloadsMainJS() async throws {
    let env = try makeHostEnv("js-reload")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("reload-demo")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try #"{"name":"Reload","version":"1.0","runtime":{"js":"main.js"},"commands":[{"id":"ver","title":"版本"}]}"#
        .write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try #"plugin.commands.ver = () => ({ v: 1 });"#
        .write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["reload-demo"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "reload-demo" } })
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log)
    defer { host.shutdown() }
    host.setAPIHost(StubAPIHost())

    let v1 = try await host.runCommand(plugin: "reload-demo", command: "ver", arguments: nil, context: sampleContext)
    #expect(v1 == .object(["v": .number(1)]))

    // 修改 main.js
    let previousSignature = library.signatures()["reload-demo"]
    try await Task.sleep(for: .milliseconds(50))
    try #"plugin.commands.ver = () => ({ v: 2 });"#
        .write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

    let reloaded = await waitUntil(timeout: .seconds(3)) {
        // 等待库签名刷新后再等待宿主热重载
        library.signatures()["reload-demo"] != previousSignature
    }
    #expect(reloaded)
    // 等待防抖与 host 热重载生效（旧连接被热重载终止时在途请求可能返回 .cancelled）
    var gotV2 = false
    for _ in 0..<30 {
        do {
            let v = try await host.runCommand(plugin: "reload-demo", command: "ver", arguments: nil, context: sampleContext)
            if v == .object(["v": .number(2)]) { gotV2 = true; break }
        } catch PluginError.cancelled {
            // 热重载刚好切掉旧连接，继续重试
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(gotV2)
}

@Test func jsPluginInfiniteLoopStoppedWithin1SecondAndRemainsUsable() async throws {
    let env = try makeHostEnv("js-loop")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("loop-demo")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try #"{"name":"Loop","version":"1.0","runtime":{"js":"main.js"},"commands":[{"id":"spin","title":"死循环"},{"id":"ping","title":"心跳"}]}"#
        .write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try """
    let counter = 0;
    plugin.commands.spin = () => { counter++; mv.toast("spin-started"); while (true) {} };
    plugin.commands.ping = () => ({ ok: true, counter });
    """.write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["loop-demo"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "loop-demo" } })
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log)
    defer { host.shutdown() }
    let apiHost = StubAPIHost()
    host.setAPIHost(apiHost)

    let spinTask = Task {
        try await host.runCommand(plugin: "loop-demo", command: "spin", arguments: nil, context: sampleContext)
    }
    #expect(await waitUntil {
        apiHost.calls.withLock { $0.contains { $0.method == .toast && $0.params == [.string("spin-started")] } }
    })

    let stopStart = ContinuousClock.now
    host.stop("loop-demo")
    let callElapsed = ContinuousClock.now - stopStart
    // C1.11: stop 本身不阻塞调用线程超过 50 ms
    #expect(callElapsed < .milliseconds(50))

    do {
        _ = try await spinTask.value
        Issue.record("死循环应被 stop 终止")
    } catch {
        let stopDuration = ContinuousClock.now - stopStart
        #expect(stopDuration < .seconds(1))
    }

    // 同一插件的其他命令继续可用，且常驻上下文状态保留
    let ping = try await host.runCommand(plugin: "loop-demo", command: "ping", arguments: nil, context: sampleContext)
    #expect(ping == .object(["ok": .bool(true), "counter": .number(1)]))
}

@Test func processPluginRandomPageReverseCallsHost() async throws {
    let env = try makeHostEnv("py-random")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let src = repoRootURL().appendingPathComponent("Examples/Plugins/random-page")
    let dst = env.pluginsDir.appendingPathComponent("random-page")
    try FileManager.default.copyItem(at: src, to: dst)

    try await env.settings.update { $0.plugins["random-page"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "random-page" } })

    let config = PluginHostConfiguration(
        pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
        supportDirectory: env.root
    )
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log, configuration: config)
    defer { host.shutdown() }

    let apiHost = StubAPIHost { _, method, _, _ in
        if method == .pages {
            return .array([.object(["index": .number(0)]), .object(["index": .number(1)]), .object(["index": .number(2)])])
        }
        return .null
    }
    host.setAPIHost(apiHost)

    let result = try await host.runCommand(plugin: "random-page", command: "random", arguments: nil, context: sampleContext)
    if case let .object(dict) = result, case let .bool(jumped)? = dict["jumped"], case let .number(index)? = dict["index"] {
        #expect(jumped == true)
        #expect(index >= 0 && index < 3)
    } else {
        Issue.record("random-page 返回结果异常：\(result)")
    }
    let methods = apiHost.calls.withLock { $0.map(\.method) }
    #expect(methods == [.pages, .goTo])
}

@Test func processPluginCrashFailsPendingLogsExitCodeAndAutoRestarts() async throws {
    let env = try makeHostEnv("py-crash")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("crashy")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try """
    {
      "name": "Crashy",
      "version": "1.0",
      "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
      "commands": [
        { "id": "crash", "title": "崩溃" },
        { "id": "ok", "title": "正常" }
      ]
    }
    """.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try """
    import os
    from macview_plugin import Plugin
    p = Plugin()
    @p.command("crash")
    def crash(args, ctx):
        os._exit(42)
    @p.command("ok")
    def ok(args, ctx):
        return {"pid": os.getpid()}
    p.run()
    """.write(to: pluginDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["crashy"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "crashy" } })
    let config = PluginHostConfiguration(
        pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
        supportDirectory: env.root
    )
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log, configuration: config)
    defer { host.shutdown() }
    host.setAPIHost(StubAPIHost())

    let first = try await host.runCommand(plugin: "crashy", command: "ok", arguments: nil, context: sampleContext)
    do {
        _ = try await host.runCommand(plugin: "crashy", command: "crash", arguments: nil, context: sampleContext)
        Issue.record("崩溃命令应失败")
    } catch {
        #expect(error.localizedDescription.contains("42"))
    }
    #expect(await waitUntil { env.log.entries().contains { $0.level == .error && $0.text.contains("42") } })

    // 下一次请求自动重启成功，且 PID 变化
    let second = try await host.runCommand(plugin: "crashy", command: "ok", arguments: nil, context: sampleContext)
    #expect(first != second)
    #expect(host.statuses()["crashy"] == .ready)
}

@Test func processPluginIdleTimeoutExitsCleanly() async throws {
    let env = try makeHostEnv("py-idle")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("idle-demo")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try """
    {
      "name": "Idle",
      "version": "1.0",
      "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
      "commands": [{ "id": "pid", "title": "PID" }]
    }
    """.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try """
    import os
    from macview_plugin import Plugin
    p = Plugin()
    @p.command("pid")
    def pid(args, ctx):
        return {"pid": os.getpid()}
    p.run()
    """.write(to: pluginDir.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["idle-demo"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "idle-demo" } })
    let config = PluginHostConfiguration(
        pythonLibraryDirectory: repoRootURL().appendingPathComponent("PluginSupport/python"),
        supportDirectory: env.root,
        idleTimeout: .milliseconds(200)
    )
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log, configuration: config)
    defer { host.shutdown() }
    host.setAPIHost(StubAPIHost())

    let first = try await host.runCommand(plugin: "idle-demo", command: "pid", arguments: nil, context: sampleContext)
    guard case let .object(d1) = first, case let .number(pid1)? = d1["pid"] else {
        Issue.record("未返回 PID"); return
    }
    // 等闲置超时进程退出
    #expect(await waitUntil(timeout: .seconds(2)) { kill(pid_t(pid1), 0) != 0 })
    // 闲置退出后状态应保持 ready（不是 failed）
    #expect(host.statuses()["idle-demo"] == .ready)
    // 下次请求重启新进程
    let second = try await host.runCommand(plugin: "idle-demo", command: "pid", arguments: nil, context: sampleContext)
    #expect(first != second)
}

@Test @MainActor func hostPublicMethodsDoNotBlockCallingThread() async throws {
    let env = try makeHostEnv("nonblock")
    defer { try? FileManager.default.removeItem(at: env.root) }
    let pluginDir = env.pluginsDir.appendingPathComponent("slow-js")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try #"{"name":"Slow","version":"1.0","runtime":{"js":"main.js"},"events":["pageChanged"],"commands":[{"id":"spin","title":"Spin"}]}"#
        .write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try #"plugin.commands.spin = () => { while (true) {} }; plugin.onEvent = () => { while (true) {} };"#
        .write(to: pluginDir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)

    try await env.settings.update { $0.plugins["slow-js"] = PluginState(enabled: true, grantedPermissions: []) }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "slow-js" } })
    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log)
    defer { host.shutdown() }
    host.setAPIHost(StubAPIHost())

    let start = ContinuousClock.now
    host.dispatch(.pageChanged, payload: [:], session: SessionID())
    _ = host.statuses()
    _ = host.enabledPlugins()
    _ = host.hasSubscribers(for: .pageChanged)
    host.stop("slow-js")
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .milliseconds(50))
}

@Test func panelOnlyPluginIsReadyWithoutCreatingAnyConnection() async throws {
    // C1.5: 只有面板的插件启用并同意后状态为 .ready，enabledPlugins() 含它，不创建任何连接
    let env = try makeHostEnv("panel-only")
    defer { try? FileManager.default.removeItem(at: env.root) }

    let pluginDir = env.pluginsDir.appendingPathComponent("page-notes")
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try """
    {
      "name": "页面笔记",
      "version": "1.0.0",
      "permissions": ["commands"],
      "panels": [
        { "id": "notes", "title": "页面笔记", "entry": "panel.html", "symbol": "note.text", "defaultEdge": "right" }
      ]
    }
    """.write(to: pluginDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "<html></html>".write(to: pluginDir.appendingPathComponent("panel.html"), atomically: true, encoding: .utf8)

    try await env.settings.update {
        $0.plugins["page-notes"] = PluginState(enabled: true, grantedPermissions: [.commands])
    }
    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().contains { $0.id == "page-notes" && $0.manifest != nil } })

    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log)
    defer { host.shutdown() }
    let apiHost = StubAPIHost { _, _, _, _ in .object(["ok": .bool(true)]) }
    host.setAPIHost(apiHost)

    #expect(host.statuses()["page-notes"] == .ready)
    #expect(host.enabledPlugins().map(\.id) == ["page-notes"])
    #expect(host.createdConnectionCount == 0)

    let session = SessionID()
    let ctx = ScriptCallContext(caller: "ignored", callerName: "Ignored", session: session, selection: ["/a.jpg"])
    _ = try await host.panelCall(plugin: "page-notes", method: .page, params: [], context: ctx)
    #expect(host.statuses()["page-notes"] == .ready)
    #expect(host.createdConnectionCount == 0)
}

@Test func panelCallChecksStatePermissionsContextAndLogsErrors() async throws {
    // C1.6 & C1.6b
    let env = try makeHostEnv("panel-call")
    defer { try? FileManager.default.removeItem(at: env.root) }

    // 1. 有效、无 commands 权限的仅面板插件
    let noCmdDir = env.pluginsDir.appendingPathComponent("notes-ro")
    try FileManager.default.createDirectory(at: noCmdDir, withIntermediateDirectories: true)
    try """
    {
      "name": "只读笔记",
      "version": "1.0",
      "permissions": [],
      "panels": [{ "id": "notes", "title": "笔记", "entry": "panel.html" }]
    }
    """.write(to: noCmdDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "<html></html>".write(to: noCmdDir.appendingPathComponent("panel.html"), atomically: true, encoding: .utf8)

    // 2. 需要 commands 权限的插件（用于测试未启用、未同意、已同意）
    let withCmdDir = env.pluginsDir.appendingPathComponent("notes-rw")
    try FileManager.default.createDirectory(at: withCmdDir, withIntermediateDirectories: true)
    try """
    {
      "name": "读写笔记",
      "version": "1.0",
      "permissions": ["commands"],
      "panels": [{ "id": "notes", "title": "笔记", "entry": "panel.html" }]
    }
    """.write(to: withCmdDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "<html></html>".write(to: withCmdDir.appendingPathComponent("panel.html"), atomically: true, encoding: .utf8)

    // 3. 有问题的插件（缺少入口文件）
    let invalidDir = env.pluginsDir.appendingPathComponent("broken-panel")
    try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
    try """
    {
      "name": "坏面板",
      "version": "1.0",
      "panels": [{ "id": "notes", "title": "笔记", "entry": "missing.html" }]
    }
    """.write(to: invalidDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    try await env.settings.update {
        $0.plugins["notes-ro"] = PluginState(enabled: true, grantedPermissions: [])
        $0.plugins["notes-rw"] = PluginState(enabled: false, grantedPermissions: [])
    }

    let library = PluginLibrary(directory: env.pluginsDir)
    #expect(await waitUntil { library.plugins().count == 3 })

    let host = PluginHost(library: library, settings: env.settings, secrets: env.secrets, log: env.log)
    defer { host.shutdown() }

    let shouldThrow = Mutex(false)
    let apiHost = StubAPIHost { _, method, params, _ in
        if shouldThrow.withLock({ $0 }) {
            throw PluginError.runtimeError("宿主拒绝执行")
        }
        return .object(["method": .string(method.rawValue), "count": .number(Double(params.count))])
    }
    host.setAPIHost(apiHost)

    let session = SessionID()
    let selection = ["/books/1.jpg", "/books/2.jpg"]
    let callerContext = ScriptCallContext(caller: "web", callerName: "Web", session: session, selection: selection)

    func expectFailure(
        plugin: String,
        method: ScriptAPI.Method,
        params: [JSONValue] = [],
        expectedSource: String,
        checkError: (PluginError) -> Bool
    ) async {
        let beforeCount = env.log.entries().count
        do {
            _ = try await host.panelCall(plugin: plugin, method: method, params: params, context: callerContext)
            Issue.record("预期 panelCall(\(plugin), \(method)) 失败")
        } catch let error as PluginError {
            #expect(checkError(error))
            let entries = env.log.entries()
            #expect(entries.count == beforeCount + 1)
            #expect(entries.last?.level == .error)
            #expect(entries.last?.source == expectedSource)
            #expect(entries.last?.text == error.localizedDescription)
        } catch {
            Issue.record("预期 PluginError，实际：\(error)")
        }
    }

    // 插件不存在 -> notFound
    await expectFailure(plugin: "nope", method: .book, expectedSource: "nope") {
        $0 == .notFound("nope")
    }

    // 有问题 -> invalid
    await expectFailure(plugin: "broken-panel", method: .book, expectedSource: "broken-panel") {
        if case .invalid = $0 { return true }
        return false
    }

    // 未启用 -> disabled（来源为插件名）
    await expectFailure(plugin: "notes-rw", method: .book, expectedSource: "读写笔记") {
        $0 == .disabled("notes-rw")
    }

    // 启用但权限未同意 -> needsConsent
    try await env.settings.update {
        $0.plugins["notes-rw"] = PluginState(enabled: true, grantedPermissions: [])
    }
    await expectFailure(plugin: "notes-rw", method: .book, expectedSource: "读写笔记") {
        $0 == .needsConsent("notes-rw")
    }

    // 没有 commands 权限调 command -> missingPermission
    await expectFailure(plugin: "notes-ro", method: .command, params: [.string("page.next")], expectedSource: "只读笔记") {
        $0 == .missingPermission(plugin: "notes-ro", permission: .commands)
    }
    #expect(apiHost.calls.withLock { $0.isEmpty })

    // 没有 commands 权限调其他方法照常成功，且不写日志
    let logCountBeforeSuccess = env.log.entries().count
    let pageResult = try await host.panelCall(
        plugin: "notes-ro",
        method: .page,
        params: [.number(3)],
        context: callerContext
    )
    #expect(pageResult == .object(["method": .string("page"), "count": .number(1)]))
    #expect(env.log.entries().count == logCountBeforeSuccess)

    let recorded = try #require(apiHost.calls.withLock { $0.last })
    #expect(recorded.plugin == "notes-ro")
    #expect(recorded.method == .page)
    #expect(recorded.params == [.number(3)])
    #expect(recorded.context.caller == "plugin:notes-ro")
    #expect(recorded.context.callerName == "只读笔记")
    #expect(recorded.context.session == session)
    #expect(recorded.context.selection == selection)

    // 同意 commands 权限后可调 command，且不写日志
    try await env.settings.update {
        $0.plugins["notes-rw"] = PluginState(enabled: true, grantedPermissions: [.commands])
    }
    let cmdResult = try await host.panelCall(
        plugin: "notes-rw",
        method: .command,
        params: [.string("page.next")],
        context: callerContext
    )
    #expect(cmdResult == .object(["method": .string("command"), "count": .number(1)]))
    #expect(env.log.entries().count == logCountBeforeSuccess)

    // 替身抛错 -> 记一条错误，来源为插件名，文本为本地化原因
    shouldThrow.withLock { $0 = true }
    await expectFailure(plugin: "notes-rw", method: .book, expectedSource: "读写笔记") {
        $0 == .runtimeError("宿主拒绝执行")
    }
    #expect(host.createdConnectionCount == 0)
}
