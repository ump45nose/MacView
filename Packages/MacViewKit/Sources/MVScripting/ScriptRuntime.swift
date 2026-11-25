import Foundation
import JavaScriptCore
import MVFoundation
import Synchronization

public struct ScriptCallContext: Sendable, Hashable {
    public var caller: String
    public var callerName: String
    public var session: SessionID?
    public var selection: [String]
    public init(caller: String, callerName: String, session: SessionID?, selection: [String]) {
        self.caller = caller; self.callerName = callerName; self.session = session; self.selection = selection
    }
}

public protocol ScriptHost: Sendable {
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue
}

public enum ScriptAPI {
    public enum Method: String, Sendable, CaseIterable {
        case book, page, pages, selection, command, goTo, open, toast, confirm, prompt, storageGet, storageSet, storageRemove
    }
    public static let syncShimSource = """
    globalThis.mv = {};
    for (const name of ['book', 'page', 'pages', 'selection', 'command', 'goTo', 'open', 'toast', 'confirm', 'prompt']) {
      mv[name] = (...args) => __mvCall(name, args);
    }
    mv.storage = {
      get: (...args) => __mvCall('storageGet', args),
      set: (...args) => __mvCall('storageSet', args),
      remove: (...args) => __mvCall('storageRemove', args)
    };
    """
}

public enum ScriptTrigger: Sendable, Hashable { case command, event(ScriptEventName) }
public struct ScriptRun: Sendable, Hashable {
    public var runID: UInt64
    public var scriptID: String
    public var session: SessionID?
    public var trigger: ScriptTrigger
    public init(runID: UInt64, scriptID: String, session: SessionID?, trigger: ScriptTrigger) {
        self.runID = runID; self.scriptID = scriptID; self.session = session; self.trigger = trigger
    }
}
public enum ScriptRunState: Sendable, Hashable { case idle, queued, running(since: Date) }
public enum ScriptRunEvent: Sendable {
    case started(ScriptRun), finished(ScriptRun), failed(ScriptRun, ScriptProblem), stopped(ScriptRun)
}

public final class ScriptRuntime: Sendable {
    private struct Group: Hashable, Sendable { var id: String; var session: SessionID?; var trigger: ScriptTrigger }
    private struct Job: Sendable {
        var run: ScriptRun
        var name: String
        var arguments: [String: JSONValue]?
        var payload: [String: JSONValue]?
        var context: ScriptCallContext
        var control: JSExecutionControl
        var group: Group { Group(id: run.scriptID, session: run.session, trigger: run.trigger) }
    }
    private struct Active: Sendable { var job: Job; var since: Date }
    private struct State {
        var host: (any ScriptHost)?
        var nextID: UInt64 = 0
        var queue: [Job] = []
        var active: [UInt64: Active] = [:]
        var statesObservers: [UUID: AsyncStream<[String: ScriptRunState]>.Continuation] = [:]
        var eventObservers: [UUID: AsyncStream<ScriptRunEvent>.Continuation] = [:]
    }
    private let library: ScriptLibrary
    private let log: ScriptLog
    private let maxConcurrent: Int
    private let state = Mutex(State())
    private static let warnedUnsupported = Mutex(false)

    public init(library: ScriptLibrary, log: ScriptLog, maxConcurrent: Int = 4) {
        self.library = library; self.log = log; self.maxConcurrent = max(1, maxConcurrent)
    }
    public func setHost(_ host: any ScriptHost) { state.withLock { $0.host = host } }

    public func run(_ id: String, arguments: [String: JSONValue]?, context: ScriptCallContext) {
        guard let info = library.scripts().first(where: { $0.id == id }) else {
            log.append(source: id, level: .error, text: String(localized: "找不到脚本：\(id)", bundle: .main)); return
        }
        enqueue(info: info, trigger: .command, arguments: arguments, payload: nil, context: context)
    }
    public func dispatch(_ event: ScriptEventName, payload: [String: JSONValue], session: SessionID?) {
        let scripts = library.subscribers(for: event)
        for info in scripts {
            let context = ScriptCallContext(caller: "script.\(info.id)", callerName: info.name, session: session, selection: [])
            enqueue(info: info, trigger: .event(event), arguments: nil, payload: payload, context: context)
        }
    }
    public func hasSubscribers(for event: ScriptEventName) -> Bool { !library.subscribers(for: event).isEmpty }
    private func enqueue(info: ScriptInfo, trigger: ScriptTrigger, arguments: [String: JSONValue]?, payload: [String: JSONValue]?, context: ScriptCallContext) {
        var dropped = false
        let start = state.withLock { state -> [Job] in
            state.nextID &+= 1
            let run = ScriptRun(runID: state.nextID, scriptID: info.id, session: context.session, trigger: trigger)
            let job = Job(run: run, name: info.name, arguments: arguments, payload: payload, context: context, control: JSExecutionControl())
            let matching = state.queue.indices.filter { state.queue[$0].group == job.group }
            if trigger == .event(.pageChanged), let index = matching.first {
                state.queue[index] = job
            } else if matching.count >= 8 {
                dropped = true; return []
            } else { state.queue.append(job) }
            Self.publishStates(&state)
            return schedule(&state)
        }
        if dropped { log.append(source: info.name, level: .warning, text: String(localized: "脚本排队已满，已丢弃一次运行", bundle: .main)) }
        launch(start)
    }
    private func schedule(_ state: inout State) -> [Job] {
        var jobs: [Job] = []
        while state.active.count < maxConcurrent,
              let index = state.queue.firstIndex(where: { queued in !state.active.values.contains { $0.job.group == queued.group } }) {
            let job = state.queue.remove(at: index)
            state.active[job.run.runID] = Active(job: job, since: Date())
            Self.publishStates(&state)
            for observer in state.eventObservers.values { observer.yield(.started(job.run)) }
            jobs.append(job)
        }
        return jobs
    }
    private func launch(_ jobs: [Job]) {
        for job in jobs { Thread.detachNewThread { [self] in execute(job) } }
    }
    public func stop(_ id: String) { stopMatching { $0.run.scriptID == id } }
    public func stopAll() { stopMatching { _ in true } }
    private func stopMatching(_ predicate: (Job) -> Bool) {
        let controls = state.withLock { state -> [JSExecutionControl] in
            let previous = state.queue.count
            state.queue.removeAll(where: predicate)
            if previous != state.queue.count { Self.publishStates(&state) }
            return state.active.values.filter { predicate($0.job) }.map { $0.job.control }
        }
        for control in controls { control.stop() }
    }
    public func runStates() -> [String: ScriptRunState] { state.withLock { Self.snapshot($0) } }
    private static func snapshot(_ state: State) -> [String: ScriptRunState] {
        var result: [String: ScriptRunState] = [:]
        for job in state.queue { result[job.run.scriptID] = .queued }
        for active in state.active.values {
            if case let .running(since) = result[active.job.run.scriptID] {
                result[active.job.run.scriptID] = .running(since: min(since, active.since))
            } else { result[active.job.run.scriptID] = .running(since: active.since) }
        }
        return result
    }
    private static func publishStates(_ state: inout State) {
        let value = snapshot(state)
        for observer in state.statesObservers.values { observer.yield(value) }
    }
    public func runStateChanges() -> AsyncStream<[String: ScriptRunState]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: ScriptRunState].self, bufferingPolicy: .bufferingNewest(1)); let id = UUID()
        state.withLock { $0.statesObservers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.statesObservers.removeValue(forKey: id) } }
        return stream
    }
    public func events() -> AsyncStream<ScriptRunEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScriptRunEvent.self); let id = UUID()
        state.withLock { $0.eventObservers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.eventObservers.removeValue(forKey: id) } }
        return stream
    }

    private func finish(_ job: Job, problem: ScriptProblem?) {
        let stopped = job.control.isStopped
        let event: ScriptRunEvent
        if stopped { event = .stopped(job.run); log.append(source: job.name, level: .info, text: String(localized: "脚本已停止", bundle: .main)) }
        else if let problem { event = .failed(job.run, problem); log.append(source: job.name, level: .error, text: Self.describe(problem)) }
        else { event = .finished(job.run) }
        let jobs = state.withLock { state -> [Job] in
            state.active.removeValue(forKey: job.run.runID)
            Self.publishStates(&state)
            for observer in state.eventObservers.values { observer.yield(event) }
            return schedule(&state)
        }
        launch(jobs)
    }
    private static func describe(_ problem: ScriptProblem) -> String {
        if let line = problem.line { return String(localized: "第 \(line) 行：\(problem.message)", bundle: .main) }
        return problem.message
    }

    private func execute(_ job: Job) {
        if job.control.isStopped { finish(job, problem: nil); return }
        if let problem = library.scripts().first(where: { $0.id == job.run.scriptID })?.problem {
            finish(job, problem: problem); return
        }
        let source: String
        do { source = try library.source(of: job.run.scriptID) }
        catch { finish(job, problem: ScriptProblem(line: nil, message: error.localizedDescription)); return }
        guard let host = state.withLock({ $0.host }) else {
            finish(job, problem: ScriptProblem(line: nil, message: String(localized: "脚本宿主不可用", bundle: .main))); return
        }
        guard let context = JSBridge.makeContext(
            call: { method, args in
                try job.control.syncCall {
                    try await host.call(method, args, context: job.context)
                }
            },
            log: { [log] level, text in
                log.append(source: job.name, level: level, text: text)
            }
        ) else {
            finish(job, problem: ScriptProblem(line: nil, message: String(localized: "无法创建 JavaScript 环境", bundle: .main))); return
        }

        if let mv = context.objectForKeyedSubscript("mv") {
            mv.setObject(JSBridge.jsValue(job.arguments.map(JSONValue.object) ?? .null, in: context), forKeyedSubscript: "args" as NSString)
            mv.setObject(JSBridge.jsValue(job.payload.map(JSONValue.object) ?? .null, in: context), forKeyedSubscript: "event" as NSString)
        }

        if JSBridge.setExecutionTimeLimit(on: context, interval: 0.1, control: job.control) {
            defer { JSBridge.clearExecutionTimeLimit(on: context) }
            if !job.control.isStopped {
                context.evaluateScript(source, withSourceURL: library.directory.appendingPathComponent("\(job.run.scriptID).js"))
            }
        } else {
            let shouldWarn = Self.warnedUnsupported.withLock { warned in if warned { return false }; warned = true; return true }
            if shouldWarn { log.append(source: job.name, level: .warning, text: String(localized: "当前系统不支持强制停止，脚本会在下一次调用 mv 时停下", bundle: .main)) }
            if !job.control.isStopped {
                context.evaluateScript(source, withSourceURL: library.directory.appendingPathComponent("\(job.run.scriptID).js"))
            }
        }

        if job.control.isStopped { finish(job, problem: nil); return }
        finish(job, problem: JSBridge.exceptionProblem(from: context))
    }
}
