import Foundation
import MVFoundation
import MVScripting
import MVSettings
import Synchronization

/// 插件宿主：统一管理 JS 与外部程序插件的生命周期、热重载、命令、事件、日志与状态流。
public final class PluginHost: Sendable {
    private struct EventGroup: Hashable, Sendable {
        var pluginID: String
        var session: SessionID?
        var event: ScriptEventName
    }

    private struct EventJob: Sendable {
        var group: EventGroup
        var payload: [String: JSONValue]
    }

    private struct State {
        var apiHost: (any PluginAPIHost)?
        var connections: [String: any PluginConnection] = [:]
        var createdConnectionCount = 0
        var inFlight: [String: Int] = [:]
        var runningSince: [String: Date] = [:]
        var failures: [String: String] = [:]
        var lastSignatures: [String: String] = [:]
        var lastStatuses: [String: PluginStatus] = [:]
        var statusObservers: [UUID: AsyncStream<[String: PluginStatus]>.Continuation] = [:]
        var eventQueues: [EventGroup: [EventJob]] = [:]
        var activeEventGroups: Set<EventGroup> = []
        var isShutdown = false
    }

    public let library: PluginLibrary
    public let settings: JSONDocumentStore<PluginSettingsFile>
    public let secrets: PluginSecrets
    public let log: ScriptLog
    public let configuration: PluginHostConfiguration
    private let state = Mutex(State())
    private let watcherTasks = Mutex<[Task<Void, Never>]>([])

    public init(
        library: PluginLibrary,
        settings: JSONDocumentStore<PluginSettingsFile>,
        secrets: PluginSecrets,
        log: ScriptLog,
        configuration: PluginHostConfiguration = PluginHostConfiguration()
    ) {
        self.library = library
        self.settings = settings
        self.secrets = secrets
        self.log = log
        self.configuration = configuration

        state.withLock { state in
            state.lastSignatures = library.signatures()
            state.lastStatuses = computeStatuses(state: state)
        }

        let libraryChanges = library.changes()
        let libraryTask = Task { [weak self] in
            for await _ in libraryChanges {
                guard !Task.isCancelled, let self else { return }
                self.reconcileConnections(checkSignatures: true)
            }
        }
        let settingsChanges = settings.changes()
        let settingsTask = Task { [weak self] in
            for await _ in settingsChanges {
                guard !Task.isCancelled, let self else { return }
                self.reconcileConnections(checkSignatures: false)
            }
        }
        watcherTasks.withLock { $0 = [libraryTask, settingsTask] }
    }

    deinit {
        shutdown()
    }

    public func setAPIHost(_ host: any PluginAPIHost) {
        state.withLock { $0.apiHost = host }
    }

    public func statuses() -> [String: PluginStatus] {
        state.withLock { computeStatuses(state: $0) }
    }

    public func statusChanges() -> AsyncStream<[String: PluginStatus]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: PluginStatus].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let snapshot = state.withLock { state -> [String: PluginStatus] in
            state.statusObservers[id] = continuation
            return computeStatuses(state: state)
        }
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.statusObservers.removeValue(forKey: id) }
        }
        return stream
    }

    /// 返回当前已启用、清单有效且权限已同意的插件。
    public func enabledPlugins() -> [PluginInfo] {
        let pluginStates = settings.value().plugins
        return library.plugins().filter { Self.isRunnable($0, states: pluginStates) }
    }

    public func hasSubscribers(for event: ScriptEventName) -> Bool {
        enabledPlugins().contains { $0.manifest?.events.contains(event) == true }
    }

    /// 面板调用应用 API 的唯一入口。检查插件存在、有效、已启用、权限已同意；
    /// `method == .command` 时要求 `.commands` 权限。通过后交给 `PluginAPIHost`，`context.caller` 固定为 `"plugin:<id>"`，
    /// `context.callerName` 为插件名，`session` 与 `selection` 保持调用方给的值。
    public func panelCall(
        plugin: String,
        method: ScriptAPI.Method,
        params: [JSONValue],
        context: ScriptCallContext
    ) async throws -> JSONValue {
        let (sourceName, lookup) = lookupEnabledPlugin(plugin)
        do {
            let (_, manifest) = try lookup.get()
            if method == .command && !manifest.permissions.contains(.commands) {
                throw PluginError.missingPermission(plugin: plugin, permission: .commands)
            }
            guard let host = state.withLock({ $0.apiHost }) else {
                throw PluginError.runtimeError(String(localized: "插件宿主 API 不可用", bundle: .main))
            }
            var callContext = context
            callContext.caller = "plugin:\(plugin)"
            callContext.callerName = manifest.name
            return try await host.call(plugin: plugin, method: method, params: params, context: callContext)
        } catch {
            log.append(source: sourceName, level: .error, text: error.localizedDescription)
            throw error
        }
    }

    public func runCommand(
        plugin: String,
        command: String,
        arguments: [String: JSONValue]?,
        context: ScriptCallContext
    ) async throws -> JSONValue {
        let info = try requireEnabledPlugin(plugin)
        var callContext = context
        callContext.caller = "plugin:\(plugin)"
        callContext.callerName = info.manifest?.name ?? plugin
        let params: JSONValue = .object([
            "command": .string(command),
            "arguments": .object(arguments ?? [:]),
            "context": .object([
                "session": context.session.map { .string($0.raw.uuidString) } ?? .null,
                "selection": .array(context.selection.map(JSONValue.string)),
            ]),
        ])
        return try await sendRequest(
            plugin: plugin,
            method: "command.run",
            params: params,
            timeout: configuration.requestTimeout,
            callContext: callContext
        )
    }

    public func dispatch(_ event: ScriptEventName, payload: [String: JSONValue], session: SessionID?) {
        let targets = enabledPlugins().filter { $0.manifest?.events.contains(event) == true }
        for info in targets {
            let group = EventGroup(pluginID: info.id, session: session, event: event)
            let job = EventJob(group: group, payload: payload)
            var dropped = false
            let shouldStart: Bool = state.withLock { state in
                guard !state.isShutdown else { return false }
                var list = state.eventQueues[group] ?? []
                if event == .pageChanged, !list.isEmpty {
                    list[0] = job
                } else if list.count >= 8 {
                    dropped = true
                    return false
                } else {
                    list.append(job)
                }
                state.eventQueues[group] = list
                if state.activeEventGroups.contains(group) {
                    return false
                }
                state.activeEventGroups.insert(group)
                return true
            }
            if dropped {
                log.append(source: info.manifest?.name ?? info.id, level: .warning, text: String(localized: "插件事件排队已满，已丢弃一次事件", bundle: .main))
            }
            if shouldStart {
                Task { [weak self] in
                    await self?.drainEventGroup(group)
                }
            }
        }
    }

    public func stop(_ plugin: String) {
        let connection = state.withLock { state -> (any PluginConnection)? in
            let conn = state.connections[plugin]
            if let proc = conn as? ProcessPluginConnection {
                state.connections.removeValue(forKey: plugin)
                return proc
            }
            return conn
        }
        connection?.stop()
        publishStatusesIfChanged()
    }

    public func shutdown() {
        let tasks = watcherTasks.withLock { list -> [Task<Void, Never>] in
            let current = list
            list.removeAll()
            return current
        }
        for task in tasks { task.cancel() }

        let (connections, observers) = state.withLock { state -> ([any PluginConnection], [AsyncStream<[String: PluginStatus]>.Continuation]) in
            state.isShutdown = true
            let conns = Array(state.connections.values)
            state.connections.removeAll()
            state.eventQueues.removeAll()
            state.activeEventGroups.removeAll()
            let obs = Array(state.statusObservers.values)
            state.statusObservers.removeAll()
            return (conns, obs)
        }
        for conn in connections { conn.terminate() }
        for obs in observers { obs.finish() }
    }

    // MARK: - 供 PluginSourceProvider 与 PluginFilterRunner 使用的内部接口

    func enabledVersion(of plugin: String) -> String? {
        guard let info = try? requireEnabledPlugin(plugin) else { return nil }
        return info.manifest?.version
    }

    func sourceInstance(id: UUID) -> SourceInstance? {
        settings.value().sources.first { $0.id == id }
    }

    func resolvedSourcePayload(for sourceID: UUID) throws -> (pluginID: String, payload: JSONValue) {
        guard let instance = sourceInstance(id: sourceID) else {
            throw PluginError.notFound("source/\(sourceID.uuidString)")
        }
        _ = try requireEnabledPlugin(instance.plugin)
        var merged = instance.values
        for (k, v) in secrets.values(for: sourceID) {
            merged[k] = v
        }
        let payload: JSONValue = .object([
            "id": .string(instance.id.uuidString),
            "type": .string(instance.type),
            "name": .string(instance.name),
            "values": .object(merged.mapValues(JSONValue.string)),
        ])
        return (instance.plugin, payload)
    }

    func sendRequest(
        plugin: String,
        method: String,
        params: JSONValue,
        timeout: Duration? = nil,
        callContext: ScriptCallContext? = nil
    ) async throws -> JSONValue {
        let info = try requireEnabledPlugin(plugin)
        guard let manifest = info.manifest else {
            throw PluginError.invalid(info.problem ?? PluginProblem(file: "manifest.json", message: String(localized: "清单无效", bundle: .main)))
        }
        let connection = try getOrCreateConnection(for: info, manifest: manifest)
        let context = callContext ?? ScriptCallContext(caller: "plugin:\(plugin)", callerName: manifest.name, session: nil, selection: [])
        let effectiveTimeout = timeout ?? (method == "filter.apply" ? configuration.filterTimeout : configuration.requestTimeout)

        beginInFlight(plugin: plugin)
        defer { endInFlight(plugin: plugin) }

        let result = try await connection.request(method: method, params: params, timeout: effectiveTimeout, callContext: context)
        let cleared = state.withLock { $0.failures.removeValue(forKey: plugin) != nil }
        if cleared { publishStatusesIfChanged() }
        return result
    }

    // MARK: - 内部实现

    private func drainEventGroup(_ group: EventGroup) async {
        while true {
            let next: EventJob? = state.withLock { state in
                guard !state.isShutdown, var list = state.eventQueues[group], !list.isEmpty else {
                    state.eventQueues.removeValue(forKey: group)
                    state.activeEventGroups.remove(group)
                    return nil
                }
                let item = list.removeFirst()
                state.eventQueues[group] = list
                return item
            }
            guard let job = next else { return }
            guard let info = try? requireEnabledPlugin(group.pluginID),
                  let manifest = info.manifest,
                  let connection = try? getOrCreateConnection(for: info, manifest: manifest) else {
                continue
            }
            let context = ScriptCallContext(caller: "plugin:\(group.pluginID)", callerName: manifest.name, session: group.session, selection: [])
            let params: JSONValue = .object([
                "name": .string(group.event.rawValue),
                "payload": .object(job.payload),
                "session": group.session.map { .string($0.raw.uuidString) } ?? .null,
            ])
            await connection.notify(method: "event", params: params, callContext: context)
        }
    }

    var createdConnectionCount: Int {
        state.withLock { $0.createdConnectionCount }
    }

    private func lookupEnabledPlugin(_ id: String) -> (sourceName: String, result: Result<(info: PluginInfo, manifest: PluginManifest), PluginError>) {
        guard let info = library.plugins().first(where: { $0.id == id }) else {
            return (id, .failure(.notFound(id)))
        }
        let name = info.manifest?.name ?? info.id
        if let problem = info.problem {
            return (name, .failure(.invalid(problem)))
        }
        guard let manifest = info.manifest else {
            return (name, .failure(.invalid(PluginProblem(file: "manifest.json", message: String(localized: "清单无效", bundle: .main)))))
        }
        guard let pluginState = settings.value().plugins[id], pluginState.enabled else {
            return (name, .failure(.disabled(id)))
        }
        guard Set(manifest.permissions).isSubset(of: Set(pluginState.grantedPermissions)) else {
            return (name, .failure(.needsConsent(id)))
        }
        return (name, .success((info, manifest)))
    }

    private func requireEnabledPlugin(_ id: String) throws -> PluginInfo {
        try lookupEnabledPlugin(id).result.get().info
    }

    private func getOrCreateConnection(for info: PluginInfo, manifest: PluginManifest) throws -> any PluginConnection {
        guard let runtime = manifest.runtime else {
            throw PluginError.runtimeError(String(localized: "插件 \(info.id) 没有声明运行时", bundle: .main))
        }
        if let existing = state.withLock({ $0.connections[info.id] }), !existing.isClosed {
            return existing
        }
        let created: any PluginConnection
        switch runtime {
        case .javascript(let entry):
            created = JSPluginConnection(
                info: info,
                manifest: manifest,
                entryFile: entry,
                configuration: configuration,
                log: log,
                apiHostProvider: { [weak self] in self?.state.withLock { $0.apiHost } },
                onLoadFailure: { [weak self] connection, message in
                    self?.handleConnectionFailure(plugin: info.id, connection: connection, message: message, dropConnection: true)
                }
            )
        case let .process(command, arguments):
            created = ProcessPluginConnection(
                info: info,
                manifest: manifest,
                command: command,
                arguments: arguments,
                configuration: configuration,
                log: log,
                apiHostProvider: { [weak self] in self?.state.withLock { $0.apiHost } },
                onExit: { [weak self] connection, exitCode, unexpected in
                    self?.handleProcessExit(plugin: info.id, connection: connection, exitCode: exitCode, unexpected: unexpected)
                }
            )
        }

        let toDrop: (any PluginConnection)? = state.withLock { state in
            if state.isShutdown { return created }
            if let existing = state.connections[info.id], !existing.isClosed {
                return created // 已有并发创建的活跃连接，释放刚建的
            }
            state.connections[info.id] = created
            state.createdConnectionCount += 1
            return nil
        }
        if let toDrop {
            toDrop.terminate()
            if let existing = state.withLock({ $0.connections[info.id] }), !existing.isClosed {
                return existing
            }
            throw PluginError.cancelled
        }
        return created
    }

    private func handleConnectionFailure(plugin: String, connection: any PluginConnection, message: String, dropConnection: Bool) {
        let dropped: (any PluginConnection)? = state.withLock { state in
            guard state.connections[plugin] === connection else { return nil }
            state.failures[plugin] = message
            return dropConnection ? state.connections.removeValue(forKey: plugin) : nil
        }
        dropped?.terminate()
        publishStatusesIfChanged()
    }

    private func handleProcessExit(plugin: String, connection: any PluginConnection, exitCode: Int32, unexpected: Bool) {
        let matched = state.withLock { state -> Bool in
            guard state.connections[plugin] === connection else { return false }
            state.connections.removeValue(forKey: plugin)
            if unexpected {
                state.failures[plugin] = PluginError.processExited(code: exitCode).localizedDescription
            }
            return true
        }
        if matched { publishStatusesIfChanged() }
    }

    private static func isRunnable(_ info: PluginInfo, states: [String: PluginState]) -> Bool {
        guard info.problem == nil, let manifest = info.manifest,
              let st = states[info.id], st.enabled else { return false }
        return Set(manifest.permissions).isSubset(of: Set(st.grantedPermissions))
    }

    private func reconcileConnections(checkSignatures: Bool) {
        let newSignatures = checkSignatures ? library.signatures() : nil
        let pluginMap = Dictionary(uniqueKeysWithValues: library.plugins().map { ($0.id, $0) })
        let settingsMap = settings.value().plugins

        let toTerminate: [any PluginConnection] = state.withLock { state in
            var dropped: [any PluginConnection] = []
            for (id, conn) in state.connections {
                let sigChanged = newSignatures.map { state.lastSignatures[id] != $0[id] } ?? false
                let runnable = pluginMap[id].map { Self.isRunnable($0, states: settingsMap) && $0.manifest?.runtime != nil } ?? false
                if sigChanged || !runnable {
                    dropped.append(conn)
                    state.connections.removeValue(forKey: id)
                    state.failures.removeValue(forKey: id)
                }
            }
            if let newSignatures {
                state.lastSignatures = newSignatures
            }
            return dropped
        }
        for conn in toTerminate { conn.terminate() }
        publishStatusesIfChanged()
    }

    private func beginInFlight(plugin: String) {
        state.withLock { state in
            let next = (state.inFlight[plugin] ?? 0) + 1
            state.inFlight[plugin] = next
            if next == 1 {
                state.runningSince[plugin] = Date()
            }
        }
        publishStatusesIfChanged()
    }

    private func endInFlight(plugin: String) {
        state.withLock { state in
            let next = (state.inFlight[plugin] ?? 1) - 1
            if next <= 0 {
                state.inFlight.removeValue(forKey: plugin)
                state.runningSince.removeValue(forKey: plugin)
            } else {
                state.inFlight[plugin] = next
            }
        }
        publishStatusesIfChanged()
    }

    private func computeStatuses(state: State) -> [String: PluginStatus] {
        let plugins = library.plugins()
        let settingsMap = settings.value().plugins
        var result: [String: PluginStatus] = [:]
        for info in plugins {
            result[info.id] = PluginStatus.evaluate(
                info: info,
                state: settingsMap[info.id],
                runningSince: state.runningSince[info.id],
                failure: state.failures[info.id]
            )
        }
        return result
    }

    private func publishStatusesIfChanged() {
        let payload: ([String: PluginStatus], [AsyncStream<[String: PluginStatus]>.Continuation])? = state.withLock { state in
            let next = computeStatuses(state: state)
            guard next != state.lastStatuses else { return nil }
            state.lastStatuses = next
            return (next, Array(state.statusObservers.values))
        }
        if let (statuses, observers) = payload {
            for observer in observers { observer.yield(statuses) }
        }
    }
}
