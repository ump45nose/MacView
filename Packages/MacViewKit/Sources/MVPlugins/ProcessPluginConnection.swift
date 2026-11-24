import Darwin
import Foundation
import MVFoundation
import MVScripting
import Synchronization

/// 外部程序插件连接：独立进程组、按行 JSON-RPC 2.0 双向通信、闲置自动退出。
final class ProcessPluginConnection: PluginConnection, @unchecked Sendable {
    private struct PendingRequest: Sendable {
        var method: String
        var context: ScriptCallContext
        var resume: @Sendable (Result<JSONValue, any Error>) -> Void
        var timeoutTask: Task<Void, Never>?
    }

    private struct InitWaiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var pid: pid_t?
        var stdinFD: Int32 = -1
        var nextID: Int = 1
        var pending: [Int: PendingRequest] = [:]
        var cancelledRequestIDs: Set<Int> = []
        var activeContext: ScriptCallContext
        var closed = false
        var expectedShutdown = false
        var idleTask: Task<Void, Never>?
        var started = false
        var initWaiters: [InitWaiter] = []
        var cancelledInitWaiters: Set<UUID> = []
        var initResult: Result<Void, any Error>?
    }

    private let info: PluginInfo
    private let manifest: PluginManifest
    private let command: String
    private let arguments: [String]
    private let configuration: PluginHostConfiguration
    private let log: ScriptLog
    private let apiHostProvider: @Sendable () -> (any PluginAPIHost)?
    private let onExit: @Sendable (ProcessPluginConnection, _ exitCode: Int32, _ unexpected: Bool) -> Void
    private let state: Mutex<State>
    private let writeQueue: DispatchQueue

    var isClosed: Bool { state.withLock { $0.closed } }

    init(
        info: PluginInfo,
        manifest: PluginManifest,
        command: String,
        arguments: [String],
        configuration: PluginHostConfiguration,
        log: ScriptLog,
        apiHostProvider: @escaping @Sendable () -> (any PluginAPIHost)?,
        onExit: @escaping @Sendable (ProcessPluginConnection, _ exitCode: Int32, _ unexpected: Bool) -> Void
    ) {
        self.info = info
        self.manifest = manifest
        self.command = command
        self.arguments = arguments
        self.configuration = configuration
        self.log = log
        self.apiHostProvider = apiHostProvider
        self.onExit = onExit
        let defaultContext = ScriptCallContext(caller: "plugin:\(info.id)", callerName: manifest.name, session: nil, selection: [])
        self.state = Mutex(State(activeContext: defaultContext))
        self.writeQueue = DispatchQueue(label: "MacView.Plugin.Process.Write.\(info.id)")
    }

    deinit {
        terminate()
    }

    func request(
        method: String,
        params: JSONValue,
        timeout: Duration,
        callContext: ScriptCallContext
    ) async throws -> JSONValue {
        try await ensureInitialized()
        return try await sendRequest(method: method, params: params, timeout: timeout, callContext: callContext)
    }

    func notify(method: String, params: JSONValue, callContext: ScriptCallContext) async {
        do {
            try await ensureInitialized()
        } catch {
            log.append(source: manifest.name, level: .error, text: error.localizedDescription)
            return
        }
        state.withLock { state in
            state.activeContext = callContext
            state.idleTask?.cancel()
            state.idleTask = nil
        }
        writeMessage(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
        scheduleIdleCheckIfNeeded()
    }

    func stop() {
        closeProcess(expected: true, sendShutdownNotification: false, failure: PluginError.cancelled)
    }

    func terminate() {
        closeProcess(expected: true, sendShutdownNotification: false, failure: PluginError.cancelled)
    }

    private func ensureInitialized() async throws {
        enum Action {
            case ready
            case failed(any Error)
            case spawn
            case wait
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let action: Action = state.withLock { state in
                    if state.cancelledInitWaiters.remove(waiterID) != nil || Task.isCancelled {
                        return .failed(CancellationError())
                    }
                    if state.closed { return .failed(PluginError.cancelled) }
                    if let result = state.initResult {
                        switch result {
                        case .success: return .ready
                        case .failure(let err): return .failed(err)
                        }
                    }
                    state.initWaiters.append(InitWaiter(id: waiterID, continuation: continuation))
                    if !state.started {
                        state.started = true
                        return .spawn
                    }
                    return .wait
                }
                switch action {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .wait:
                    break
                case .spawn:
                    Task { [self] in
                        await performSpawnAndInitialize()
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancelInitWaiter(id: waiterID)
        }
    }

    private func cancelInitWaiter(id: UUID) {
        let removed = state.withLock { state -> InitWaiter? in
            if let idx = state.initWaiters.firstIndex(where: { $0.id == id }) {
                return state.initWaiters.remove(at: idx)
            }
            state.cancelledInitWaiters.insert(id)
            return nil
        }
        removed?.continuation.resume(throwing: CancellationError())
    }

    private func performSpawnAndInitialize() async {
        do {
            try spawnProcess()
            let initParams: JSONValue = .object([
                "pluginID": .string(info.id),
                "appVersion": .string(configuration.appVersion),
                "supportDirectory": .string(configuration.supportDirectory?.path ?? ""),
                "language": .string(configuration.language),
            ])
            let defaultCtx = ScriptCallContext(caller: "plugin:\(info.id)", callerName: manifest.name, session: nil, selection: [])
            _ = try await sendRequest(method: "initialize", params: initParams, timeout: configuration.requestTimeout, callContext: defaultCtx)
            let waiters = state.withLock { state -> [InitWaiter] in
                state.initResult = .success(())
                let list = state.initWaiters
                state.initWaiters.removeAll()
                return list
            }
            for waiter in waiters { waiter.continuation.resume() }
        } catch {
            let waiters = state.withLock { state -> [InitWaiter] in
                state.initResult = .failure(error)
                let list = state.initWaiters
                state.initWaiters.removeAll()
                return list
            }
            for waiter in waiters { waiter.continuation.resume(throwing: error) }
            closeProcess(expected: false, sendShutdownNotification: false, failure: error)
        }
    }

    private func sendRequest(
        method: String,
        params: JSONValue,
        timeout: Duration,
        callContext: ScriptCallContext
    ) async throws -> JSONValue {
        let reqID = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            return id
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeOnce = OnceContinuation(continuation)
                enum Outcome { case sent, cancelled, closed }
                let outcome: Outcome = state.withLock { state in
                    if state.cancelledRequestIDs.remove(reqID) != nil || Task.isCancelled {
                        return .cancelled
                    }
                    guard !state.closed else { return .closed }
                    state.idleTask?.cancel()
                    state.idleTask = nil
                    state.activeContext = callContext
                    let timeoutTask = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.handleTimeout(id: reqID, method: method)
                    }
                    state.pending[reqID] = PendingRequest(
                        method: method,
                        context: callContext,
                        resume: { result in resumeOnce.resume(with: result) },
                        timeoutTask: timeoutTask
                    )
                    return .sent
                }
                switch outcome {
                case .cancelled:
                    resumeOnce.resume(with: .failure(CancellationError()))
                case .closed:
                    resumeOnce.resume(with: .failure(PluginError.cancelled))
                case .sent:
                    writeMessage(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .number(Double(reqID)),
                        "method": .string(method),
                        "params": params,
                    ]))
                }
            }
        } onCancel: { [weak self] in
            self?.handleCancellation(id: reqID)
        }
    }

    private func handleTimeout(id: Int, method: String) {
        let pending = state.withLock { state -> PendingRequest? in
            state.pending.removeValue(forKey: id)
        }
        guard let pending else { return }
        writeMessage(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("$/cancelRequest"),
            "params": .object(["id": .number(Double(id))]),
        ]))
        pending.resume(.failure(PluginError.timeout(method: method)))
        scheduleIdleCheckIfNeeded()
    }

    private func handleCancellation(id: Int) {
        let pending = state.withLock { state -> PendingRequest? in
            if let item = state.pending.removeValue(forKey: id) {
                item.timeoutTask?.cancel()
                return item
            }
            state.cancelledRequestIDs.insert(id)
            return nil
        }
        guard let pending else { return }
        writeMessage(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("$/cancelRequest"),
            "params": .object(["id": .number(Double(id))]),
        ]))
        pending.resume(.failure(CancellationError()))
        scheduleIdleCheckIfNeeded()
    }

    private func scheduleIdleCheckIfNeeded() {
        let idleTimeout = configuration.idleTimeout
        state.withLock { state in
            guard !state.closed, state.pending.isEmpty, state.pid != nil else { return }
            state.idleTask?.cancel()
            state.idleTask = Task { [weak self] in
                try? await Task.sleep(for: idleTimeout)
                guard !Task.isCancelled else { return }
                self?.handleIdleTimeout()
            }
        }
    }

    private func handleIdleTimeout() {
        let isStillIdle = state.withLock { !$0.closed && $0.pending.isEmpty }
        guard isStillIdle else { return }
        closeProcess(expected: true, sendShutdownNotification: true, failure: PluginError.cancelled)
    }

    private func spawnProcess() throws {
        let executable = resolveExecutable(command, directory: info.directory)
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else { throw posixFailure(errno, executable: executable) }
        guard pipe(&stdoutPipe) == 0 else {
            let c = errno; close(stdinPipe[0]); close(stdinPipe[1]); throw posixFailure(c, executable: executable)
        }
        guard pipe(&stderrPipe) == 0 else {
            let c = errno
            close(stdinPipe[0]); close(stdinPipe[1]); close(stdoutPipe[0]); close(stdoutPipe[1])
            throw posixFailure(c, executable: executable)
        }
        let allFDs = stdinPipe + stdoutPipe + stderrPipe
        for fd in allFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeAll(allFDs); throw posixFailure(errno, executable: executable)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeAll(allFDs); throw posixFailure(errno, executable: executable)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        func check(_ code: Int32) throws {
            if code != 0 { throw posixFailure(code, executable: executable) }
        }
        do {
            try check(posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO))
            for fd in allFDs { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
            try check(posix_spawn_file_actions_addchdir(&actions, info.directory.path))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        } catch {
            closeAll(allFDs)
            throw error
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for ptr in argv { free(ptr) } }
        var env = ProcessInfo.processInfo.environment
        env["MACVIEW_PLUGIN_ID"] = info.id
        if let support = configuration.supportDirectory?.path {
            env["MACVIEW_SUPPORT_DIRECTORY"] = support
        }
        env["PYTHONUNBUFFERED"] = "1"
        if let pyLib = configuration.pythonLibraryDirectory?.path {
            if let existing = env["PYTHONPATH"], !existing.isEmpty {
                env["PYTHONPATH"] = pyLib + ":" + existing
            } else {
                env["PYTHONPATH"] = pyLib
            }
        }
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for ptr in envp { free(ptr) } }

        var mutableArgv = argv
        var mutableEnvp = envp
        var pid: pid_t = 0
        let spawnCode = mutableArgv.withUnsafeMutableBufferPointer { argPtr in
            mutableEnvp.withUnsafeMutableBufferPointer { envPtr in
                posix_spawn(&pid, executable, &actions, &attributes, argPtr.baseAddress!, envPtr.baseAddress!)
            }
        }
        guard spawnCode == 0 else {
            closeAll(allFDs)
            throw posixFailure(spawnCode, executable: executable)
        }

        // 关闭子进程端描述符
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        let stdinWriteFD = stdinPipe[1]
        let stdoutReadFD = stdoutPipe[0]
        let stderrReadFD = stderrPipe[0]
        _ = fcntl(stdinWriteFD, F_SETNOSIGPIPE, 1)

        let shouldImmediatelyKill = state.withLock { state -> Bool in
            if state.closed { return true }
            state.pid = pid
            state.stdinFD = stdinWriteFD
            return false
        }
        if shouldImmediatelyKill {
            close(stdinWriteFD); close(stdoutReadFD); close(stderrReadFD)
            _ = killpg(pid, SIGKILL)
            var s: Int32 = 0
            _ = waitpid(pid, &s, 0)
            throw PluginError.cancelled
        }

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readStdoutLines(fd: stdoutReadFD)
            close(stdoutReadFD)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readStderrLines(fd: stderrReadFD)
            close(stderrReadFD)
            readers.leave()
        }
        let spawnedPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(spawnedPID, &status, 0) } while waited < 0 && errno == EINTR
            readers.wait()
            let signal = status & 0x7f
            let exitCode: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            self?.handleProcessExit(exitCode: exitCode)
        }
    }

    private func handleProcessExit(exitCode: Int32) {
        let (fdToClose, pending, expected, initWaiters) = state.withLock { state -> (Int32, [PendingRequest], Bool, [InitWaiter]) in
            state.idleTask?.cancel()
            state.idleTask = nil
            let fd = state.stdinFD
            state.stdinFD = -1
            state.closed = true
            let wasExpected = state.expectedShutdown
            let items = Array(state.pending.values)
            for item in items { item.timeoutTask?.cancel() }
            state.pending.removeAll()
            let waiters = state.initWaiters
            state.initWaiters.removeAll()
            if state.initResult == nil {
                state.initResult = .failure(PluginError.processExited(code: exitCode))
            }
            return (fd, items, wasExpected, waiters)
        }
        if fdToClose >= 0 {
            writeQueue.async { close(fdToClose) }
        }
        let error = PluginError.processExited(code: exitCode)
        for item in pending { item.resume(.failure(error)) }
        for waiter in initWaiters { waiter.continuation.resume(throwing: error) }
        if !expected {
            log.append(source: manifest.name, level: .error, text: error.localizedDescription)
        }
        onExit(self, exitCode, !expected)
    }

    private func closeProcess(expected: Bool, sendShutdownNotification: Bool, failure: any Error) {
        let (pid, fd, pending, initWaiters) = state.withLock { state -> (pid_t?, Int32, [PendingRequest], [InitWaiter]) in
            state.idleTask?.cancel()
            state.idleTask = nil
            if expected { state.expectedShutdown = true }
            let wasClosed = state.closed
            state.closed = true
            let p = state.pid
            // 无论是否先发 shutdown，都原子接管 stdinFD，并全部串行交由 writeQueue 关闭，杜绝双关或写已关 fd。
            let f = state.stdinFD
            state.stdinFD = -1
            let items = Array(state.pending.values)
            for item in items { item.timeoutTask?.cancel() }
            state.pending.removeAll()
            let waiters = state.initWaiters
            state.initWaiters.removeAll()
            if wasClosed { return (nil, f, items, waiters) }
            return (p, f, items, waiters)
        }
        for item in pending { item.resume(.failure(failure)) }
        for waiter in initWaiters { waiter.continuation.resume(throwing: failure) }

        if sendShutdownNotification && fd >= 0 {
            let line = Data(#"{"jsonrpc":"2.0","method":"shutdown","params":{}}"#.utf8) + Data([0x0A])
            writeQueue.async {
                Self.writeAll(fd: fd, data: line)
                close(fd)
            }
            if let pid {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(150)) {
                    _ = killpg(pid, SIGTERM)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                        _ = killpg(pid, SIGKILL)
                    }
                }
            }
        } else {
            if fd >= 0 {
                writeQueue.async { close(fd) }
            }
            if let pid {
                _ = killpg(pid, SIGTERM)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                    _ = killpg(pid, SIGKILL)
                }
            }
        }
    }

    private func writeMessage(_ message: JSONValue) {
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        var buffer = encoded
        buffer.append(0x0A)
        let line = buffer
        writeQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.state.withLock { $0.stdinFD }
            guard fd >= 0 else { return }
            Self.writeAll(fd: fd, data: line)
        }
    }

    private static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n == 0 { return }
                written += n
            }
        }
    }

    private func readStdoutLines(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                handleStdoutLine(Data(lineData))
            }
        }
        if !buffer.isEmpty {
            handleStdoutLine(buffer)
        }
    }

    private func readStderrLines(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                let text = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
                if !text.isEmpty {
                    log.append(source: manifest.name, level: .warning, text: text)
                }
            }
        }
        let remainder = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            log.append(source: manifest.name, level: .warning, text: remainder)
        }
    }

    private func handleStdoutLine(_ data: Data) {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              case let .object(msg) = value else {
            log.append(source: manifest.name, level: .warning, text: "无法解析插件消息：\(trimmed)")
            return
        }

        if case let .string(method)? = msg["method"] {
            handleIncomingFromPlugin(method: method, id: msg["id"], params: msg["params"] ?? .null)
            return
        }

        // Response to a host -> plugin request
        guard case let .number(numID)? = msg["id"] else { return }
        let reqID = Int(numID)
        let pending = state.withLock { state -> PendingRequest? in
            let item = state.pending.removeValue(forKey: reqID)
            item?.timeoutTask?.cancel()
            return item
        }
        guard let pending else { return }
        if case let .object(errObj)? = msg["error"] {
            let code: Int
            if case let .number(c)? = errObj["code"] { code = Int(c) } else { code = -32000 }
            let message: String
            if case let .string(m)? = errObj["message"] { message = m } else { message = "插件返回错误" }
            pending.resume(.failure(PluginError.rpcError(code: code, message: message)))
        } else {
            pending.resume(.success(msg["result"] ?? .null))
        }
        scheduleIdleCheckIfNeeded()
    }

    private func handleIncomingFromPlugin(method: String, id: JSONValue?, params: JSONValue) {
        if method == "log" {
            if case let .object(obj) = params {
                let levelStr: String
                if case let .string(l)? = obj["level"] { levelStr = l } else { levelStr = "info" }
                let level: ScriptLogEntry.Level = (levelStr == "warn" || levelStr == "warning") ? .warning : (levelStr == "error" ? .error : .info)
                let message: String
                if case let .string(m)? = obj["message"] { message = m } else { message = "" }
                log.append(source: manifest.name, level: level, text: message)
            }
            return
        }
        guard let id else { return }
        guard method.hasPrefix("mv."),
              let apiMethod = ScriptAPI.Method(rawValue: String(method.dropFirst(3))) else {
            writeMessage(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object(["code": .number(-32601), "message": .string("未知宿主方法：\(method)")]),
            ]))
            return
        }
        let args: [JSONValue]
        if case let .array(items) = params { args = items } else { args = [] }
        let context = state.withLock { $0.activeContext }
        Task { [weak self] in
            guard let self else { return }
            guard let host = self.apiHostProvider() else {
                self.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "error": .object(["code": .number(-32000), "message": .string("插件宿主 API 不可用")]),
                ]))
                return
            }
            do {
                let result = try await host.call(plugin: self.info.id, method: apiMethod, params: args, context: context)
                self.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": result,
                ]))
            } catch {
                self.writeMessage(.object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "error": .object(["code": .number(-32000), "message": .string(error.localizedDescription)]),
                ]))
            }
        }
    }

    private func resolveExecutable(_ command: String, directory: URL) -> String {
        if command.hasPrefix("/") { return command }
        let candidate = directory.appendingPathComponent(command).path
        if command.contains("/") || FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = String(dir) + "/" + command
                if FileManager.default.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return candidate
    }

    private func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 { close(fd) }
    }

    private func posixFailure(_ code: Int32, executable: String) -> PluginError {
        PluginError.runtimeError("无法启动插件程序 \(executable)：\(String(cString: strerror(code)))")
    }
}
