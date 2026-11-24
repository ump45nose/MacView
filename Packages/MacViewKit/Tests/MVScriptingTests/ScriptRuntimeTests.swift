import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVScripting

private final class RuntimeTestHost: ScriptHost, Sendable {
    struct Call: Sendable { var method: ScriptAPI.Method; var args: [JSONValue]; var context: ScriptCallContext }
    struct State { var calls: [Call] = []; var blocked = false; var cancelled = false; var active = 0; var peak = 0 }
    let state = Mutex(State())
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        state.withLock { s in s.calls.append(Call(method: method, args: args, context: context)); s.active += 1; s.peak = max(s.peak, s.active) }
        defer { state.withLock { $0.active -= 1 } }
        do { while state.withLock({ $0.blocked }) { try await Task.sleep(for: .milliseconds(10)) } }
        catch { state.withLock { $0.cancelled = true }; throw error }
        if method == .prompt { throw TestError.failure }
        return .object(["nested": .array([.null, .bool(true), .string("ok")])])
    }
    enum TestError: Error { case failure }
}

private func runtimeDirectory(_ scripts: [String: String]) throws -> URL {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/MVScriptingRuntimeTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, source) in scripts { try source.write(to: dir.appendingPathComponent("\(name).js"), atomically: true, encoding: .utf8) }
    return dir
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(2)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { while !Task.isCancelled { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }; return false }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let result = await group.next() ?? false; group.cancelAll(); return result
    }
}

private let testContext = ScriptCallContext(caller: "script.test", callerName: "Test", session: nil, selection: ["selection"])

@Test func runtimeBridgeAndExceptions() async throws {
    let dir = try runtimeDirectory(["test": """
    const expected = [null, true, {x: [1, "中"]}];
    for (const f of [mv.book, mv.page, mv.pages, mv.selection, mv.command, mv.goTo, mv.open, mv.toast, mv.confirm, mv.storage.get, mv.storage.set, mv.storage.remove]) {
      const r = f(...expected); if (r.nested[0] !== null || r.nested[1] !== true || r.nested[2] !== 'ok') throw Error('bad result');
    }
    try { mv.prompt(); throw Error('not thrown'); } catch(e) { if (String(e).includes('not thrown')) throw e; }
    if (mv.args.x !== 3 || mv.event !== null) throw Error('bad context');
    console.log('hello'); console.warn('warn'); console.error('error');
    """])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log)
    runtime.setHost(host); runtime.run("test", arguments: ["x": .number(3)], context: testContext)
    #expect(await waitUntil { log.entries().contains { $0.text.contains("error") } })
    #expect(Set(host.state.withLock { $0.calls.map(\.method) }) == Set(ScriptAPI.Method.allCases))
    #expect(host.state.withLock { $0.calls.first?.args } == [.null, .bool(true), .object(["x": .array([.number(1), .string("中")])])])
    #expect(host.state.withLock { $0.calls.first?.context } == testContext)
    #expect(log.entries().contains { $0.level == .warning && $0.text.contains("warn") })
    #expect(!log.entries().contains { $0.text.contains("bad context") || $0.text.contains("bad result") })
}

@Test func runtimeEventsAndStop() async throws {
    let dir = try runtimeDirectory(["test": "// @name 名称\n// @event pageChanged\nif (mv.event.value !== 42) throw Error('payload'); mv.toast('go');", "loop": "mv.toast('loop started'); while(true) {}"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log)
    runtime.setHost(host)
    let recorder = RuntimeRecorder(); let events = runtime.events()
    let eventTask = Task { for await event in events { recorder.events.withLock { $0.append(event) } } }
    defer { eventTask.cancel() }
    let sessionA = SessionID(); let sessionB = SessionID()
    #expect(runtime.hasSubscribers(for: .pageChanged)); #expect(!runtime.hasSubscribers(for: .startup))
    runtime.dispatch(.pageChanged, payload: ["value": .number(42)], session: sessionA)
    runtime.dispatch(.pageChanged, payload: ["value": .number(42)], session: sessionB)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 2 } })
    #expect(Set(host.state.withLock { $0.calls.compactMap(\.context.session) }) == [sessionA, sessionB])
    #expect(host.state.withLock { $0.calls.allSatisfy { $0.context.caller == "script.test" && $0.context.callerName == "名称" && $0.context.selection.isEmpty } })
    runtime.stop("test")
    #expect(await waitUntil { host.state.withLock { $0.cancelled } && runtime.runStates()["test"] == nil })
    #expect(await waitUntil { recorder.events.withLock { $0.filter { if case .stopped = $0 { return true }; return false }.count >= 2 } })
    let stoppedSessions = recorder.events.withLock { events in events.compactMap { event -> SessionID? in if case let .stopped(run) = event { return run.session }; return nil } }
    #expect(Set(stoppedSessions) == [sessionA, sessionB])
    host.state.withLock { $0.blocked = false }
    runtime.run("loop", arguments: nil, context: testContext)
    #expect(await waitUntil { if case .running = runtime.runStates()["loop"] { return true }; return false })
    #expect(await waitUntil { host.state.withLock { $0.calls.contains { $0.args == [.string("loop started")] } } })
    runtime.stop("loop")
    #expect(await waitUntil({ runtime.runStates()["loop"] == nil }, timeout: .seconds(1)))
    runtime.run("loop", arguments: nil, context: testContext)
    #expect(await waitUntil { if case .running = runtime.runStates()["loop"] { return true }; return false })
    runtime.stopAll()
    #expect(await waitUntil { runtime.runStates().isEmpty })
}

@Test func runtimeCoalescingAndQueue() async throws {
    let dir = try runtimeDirectory(["test": "// @event pageChanged pageEnd\nmv.toast(mv.event ? mv.event.n : mv.args.n);", "other": "mv.toast('other');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: ScriptLog(), maxConcurrent: 2); runtime.setHost(host)
    let session = SessionID()
    runtime.dispatch(.pageChanged, payload: ["n": .number(0)], session: session)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 1 } })
    for n in 1...50 { runtime.dispatch(.pageChanged, payload: ["n": .number(Double(n))], session: session) }
    host.state.withLock { $0.blocked = false }
    #expect(await waitUntil { host.state.withLock { $0.calls.count >= 2 } && runtime.runStates().isEmpty })
    #expect(host.state.withLock { $0.calls.map(\.args) } == [[.number(0)], [.number(50)]])
    for n in 1...5 { runtime.run("test", arguments: ["n": .number(Double(n))], context: testContext) }
    #expect(await waitUntil { host.state.withLock { $0.calls.count >= 7 } && runtime.runStates().isEmpty })
    #expect(host.state.withLock { Array($0.calls.suffix(5)).map(\.args) } == (1...5).map { [.number(Double($0))] })
    #expect(host.state.withLock { $0.peak } <= 2)
}

@Test func runtimeFailureHasLine() async throws {
    let dir = try runtimeDirectory(["test": "// header\nconst n = 1;\nthrow Error('broken');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log)
    runtime.setHost(RuntimeTestHost()); runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { log.entries().contains { $0.level == .error && $0.text.contains("broken") } })
    #expect(log.entries().contains { $0.text.contains("3") })
}

private final class RuntimeRecorder: Sendable {
    let events = Mutex<[ScriptRunEvent]>([])
    let states = Mutex<[[String: ScriptRunState]]>([])
}

@Test func runtimeEventAndStateStreams() async throws {
    let dir = try runtimeDirectory(["test": "// @event pageChanged\nmv.toast('start');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: ScriptLog(), maxConcurrent: 1); runtime.setHost(host)
    let recorder = RuntimeRecorder(); let events = runtime.events(); let states = runtime.runStateChanges()
    let eventTask = Task { for await event in events { recorder.events.withLock { $0.append(event) } } }
    let stateTask = Task { for await state in states { recorder.states.withLock { $0.append(state) } } }
    defer { eventTask.cancel(); stateTask.cancel() }
    let session = SessionID()
    runtime.dispatch(.pageChanged, payload: [:], session: session)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 1 } })
    #expect(await waitUntil { recorder.states.withLock { !$0.isEmpty } })
    runtime.dispatch(.pageChanged, payload: [:], session: session)
    #expect(await waitUntil { recorder.states.withLock { $0.count >= 2 } })
    host.state.withLock { $0.blocked = false }
    #expect(await waitUntil { recorder.events.withLock { $0.count == 4 } })
    let captured = recorder.events.withLock { $0 }
    guard captured.count == 4,
          case let .started(a) = captured[0], case let .finished(b) = captured[1],
          case let .started(c) = captured[2], case let .finished(d) = captured[3] else {
        Issue.record("运行事件顺序不正确"); return
    }
    #expect(a == b && c == d && a.runID != c.runID)
    #expect(a.session == session && a.trigger == .event(.pageChanged))
    #expect(recorder.states.withLock { $0.contains { $0.isEmpty } })
}

@Test func runtimeStateChangesKeepLatestSnapshot() async throws {
    let dir = try runtimeDirectory(["test": "mv.toast('start');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: ScriptLog())
    runtime.setHost(host)
    let states = runtime.runStateChanges()
    runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 1 } })
    host.state.withLock { $0.blocked = false }
    #expect(await waitUntil { runtime.runStates().isEmpty })
    var iterator = states.makeAsyncIterator()
    #expect(await iterator.next()?.isEmpty == true)
}

@Test func exampleNextBookHandlesCommandAndPageEvents() async throws {
    let root = try runtimeDirectory([:])
    defer { try? FileManager.default.removeItem(at: root) }
    let library = ScriptLibrary(directory: root.appendingPathComponent("Scripts"))
    let host = RuntimeTestHost(); let log = ScriptLog()
    let runtime = ScriptRuntime(library: library, log: log)
    runtime.setHost(host)
    let recorder = RuntimeRecorder(); let events = runtime.events()
    let task = Task { for await event in events { recorder.events.withLock { $0.append(event) } } }
    defer { task.cancel() }
    runtime.run("ask-next-book", arguments: nil, context: testContext)
    #expect(await waitUntil { recorder.events.withLock { $0.count >= 2 } })
    #expect(host.state.withLock { $0.calls.isEmpty })
    runtime.dispatch(.pageEnd, payload: ["direction": .string("backward")], session: nil)
    #expect(await waitUntil { recorder.events.withLock { $0.count >= 4 } })
    #expect(host.state.withLock { $0.calls.isEmpty })
    runtime.dispatch(.pageEnd, payload: ["direction": .string("forward")], session: nil)
    #expect(await waitUntil { recorder.events.withLock { $0.count >= 6 } })
    #expect(host.state.withLock { $0.calls.map(\.method) } == [.confirm, .command])
    #expect(!log.entries().contains { $0.level == .error })
}

@Test func runtimeSeparateGroupsAndConcurrency() async throws {
    let dir = try runtimeDirectory(["test": "// @event pageChanged pageEnd\nmv.toast(mv.event.n);", "other": "mv.toast('other');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: ScriptLog(), maxConcurrent: 2); runtime.setHost(host)
    let first = SessionID(), second = SessionID()
    runtime.dispatch(.pageChanged, payload: ["n": .number(1)], session: first)
    runtime.dispatch(.pageChanged, payload: ["n": .number(2)], session: second)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 2 } })
    runtime.dispatch(.pageEnd, payload: ["n": .number(3)], session: first)
    runtime.dispatch(.pageChanged, payload: ["n": .number(4)], session: first)
    runtime.run("other", arguments: nil, context: testContext)
    host.state.withLock { $0.blocked = false }
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 5 } && runtime.runStates().isEmpty })
    #expect(Set(host.state.withLock { $0.calls.flatMap(\.args) }) == [.number(1), .number(2), .number(3), .number(4), .string("other")])
    #expect(host.state.withLock { $0.peak } == 2)
}

@Test func runtimeSubscriberReloadAndSyntaxFailure() async throws {
    let dir = try runtimeDirectory(["test": "1;"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = ScriptLibrary(directory: dir); let log = ScriptLog(); let runtime = ScriptRuntime(library: library, log: log)
    let recorder = RuntimeRecorder(); let stream = runtime.events()
    let task = Task { for await event in stream { recorder.events.withLock { $0.append(event) } } }
    defer { task.cancel() }
    #expect(!runtime.hasSubscribers(for: .startup))
    try "// @event startup\n1;".write(to: dir.appendingPathComponent("test.js"), atomically: true, encoding: .utf8)
    #expect(await waitUntil { runtime.hasSubscribers(for: .startup) })
    try "// @event startup\nconst x = ;".write(to: dir.appendingPathComponent("test.js"), atomically: true, encoding: .utf8)
    #expect(await waitUntil { !runtime.hasSubscribers(for: .startup) })
    runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { recorder.events.withLock { $0.count == 2 } })
    #expect(recorder.events.withLock { events in events.contains { if case let .failed(_, problem) = $0 { return problem.line == 2 }; return false } })
    #expect(log.entries().contains { $0.level == .error && $0.text.contains("2") })
}

@MainActor private final class MainThreadHost: ScriptHost {
    var called = false
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        called = true
        return .bool(true)
    }
}

private func occupyMainThread() { _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(100)) }

@Test @MainActor func runtimeMainActorHostDoesNotDeadlock() async throws {
    let dir = try runtimeDirectory(["test": "mv.confirm('ok');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = MainThreadHost(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: ScriptLog())
    runtime.setHost(host); runtime.run("test", arguments: nil, context: testContext)
    let heartbeat = Task { @MainActor in true }
    occupyMainThread()
    #expect(await heartbeat.value)
    for _ in 0..<100 where !host.called { try await Task.sleep(for: .milliseconds(10)) }
    #expect(host.called)
}

private final class LateHost: ScriptHost, Sendable {
    let started = Mutex(false)
    let returned = Mutex(false)
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        started.withLock { $0 = true }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(350)) { continuation.resume() }
        }
        returned.withLock { $0 = true }
        return .string("late")
    }
}

@Test func runtimeStopDropsLateHostResult() async throws {
    let dir = try runtimeDirectory(["test": "const value = mv.toast('start'); console.log('late result', value);"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = LateHost(); let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log)
    runtime.setHost(host); runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { host.started.withLock { $0 } })
    runtime.stop("test")
    #expect(await waitUntil({ runtime.runStates().isEmpty }, timeout: .milliseconds(200)))
    #expect(await waitUntil { host.returned.withLock { $0 } })
    #expect(!log.entries().contains { $0.text.contains("late result") })
}

@Test func runtimeQueueLimit() async throws {
    let dir = try runtimeDirectory(["test": "mv.toast('test');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = RuntimeTestHost(); host.state.withLock { $0.blocked = true }
    let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log, maxConcurrent: 1)
    runtime.setHost(host); runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 1 } })
    for _ in 0..<10 { runtime.run("test", arguments: nil, context: testContext) }
    #expect(log.entries().filter { $0.level == .warning && $0.text.contains("丢弃") }.count == 2)
    host.state.withLock { $0.blocked = false }
    #expect(await waitUntil { host.state.withLock { $0.calls.count == 9 } && runtime.runStates().isEmpty })
}

private final class CrossHost: ScriptHost, Sendable {
    struct State { var runtime: ScriptRuntime?; var bCalled = false }
    let state = Mutex(State())
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        if context.caller == "script.a" {
            state.withLock { $0.runtime }?.run("b", arguments: nil, context: ScriptCallContext(caller: "script.b", callerName: "b", session: nil, selection: []))
            for _ in 0..<100 where !state.withLock({ $0.bCalled }) { try await Task.sleep(for: .milliseconds(10)) }
            if !state.withLock({ $0.bCalled }) { throw RuntimeTestHost.TestError.failure }
        } else { state.withLock { $0.bCalled = true } }
        return .null
    }
}

@Test func runtimeHostCanTriggerAnotherScript() async throws {
    let dir = try runtimeDirectory(["a": "mv.toast('a');", "b": "mv.toast('b');"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let host = CrossHost(); let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log, maxConcurrent: 2)
    host.state.withLock { $0.runtime = runtime }; runtime.setHost(host)
    runtime.run("a", arguments: nil, context: ScriptCallContext(caller: "script.a", callerName: "a", session: nil, selection: []))
    #expect(await waitUntil { host.state.withLock { $0.bCalled } && runtime.runStates().isEmpty })
    #expect(!log.entries().contains { $0.level == .error })
    host.state.withLock { $0.runtime = nil }
}

private struct EchoHost: ScriptHost {
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue { args.first ?? .null }
}

@Test func runtimeJSONValueRoundTrips() async throws {
    let dir = try runtimeDirectory(["test": """
    for (const value of [null, false, 3.5, '中', [null, {a: true}], {a: [1, 'x']}]) {
      const result = mv.toast(value);
      if (JSON.stringify(value) !== JSON.stringify(result)) throw Error('round trip');
    }
    console.log('round trips passed');
    """])
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = ScriptLog(); let runtime = ScriptRuntime(library: ScriptLibrary(directory: dir), log: log)
    runtime.setHost(EchoHost()); runtime.run("test", arguments: nil, context: testContext)
    #expect(await waitUntil { log.entries().contains { $0.text.contains("round trips passed") } })
    #expect(!log.entries().contains { $0.level == .error })
}
