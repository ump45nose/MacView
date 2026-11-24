import Darwin
import Foundation
import Synchronization

public struct ProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

public final class ProcessRunner: Sendable {
    public init() {}
    public func run(executable: String, arguments: [String], workingDirectory: String?) async throws -> ProcessResult {
        let operation = ProcessOperation(executable: executable, arguments: arguments, directory: workingDirectory)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try operation.run()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { operation.cancel() }
    }
    public func runShell(_ command: String, workingDirectory: String?) async throws -> ProcessResult {
        let shell: String
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell, !String(cString: path).isEmpty {
            shell = String(cString: path)
        } else { shell = "/bin/zsh" }
        return try await run(executable: shell, arguments: ["-lc", command], workingDirectory: workingDirectory)
    }
}

private struct ProcessRunnerError: LocalizedError, Sendable {
    var executable: String
    var message: String
    var errorDescription: String? { "无法运行 \(executable)：\(message)" }
}

private final class ProcessOperation: Sendable {
    private struct State { var cancelled = false; var completed = false; var pid: pid_t?; var killDone: DispatchSemaphore? }
    private let state = Mutex(State())
    private let executable: String
    private let arguments: [String]
    private let directory: String?
    init(executable: String, arguments: [String], directory: String?) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
    }
    func cancel() {
        let target = state.withLock { state -> (pid_t, DispatchSemaphore)? in
            guard !state.completed && !state.cancelled else { return nil }
            state.cancelled = true
            let done = DispatchSemaphore(value: 0)
            state.killDone = done
            return state.pid.map { ($0, done) }
        }
        if let (pid, done) = target { terminate(pid, done: done) }
    }
    private func terminate(_ pid: pid_t, done: DispatchSemaphore) {
        _ = killpg(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
            _ = killpg(pid, SIGKILL)
            done.signal()
        }
    }
    func run() throws -> ProcessResult {
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        guard !([executable] + arguments + [directory].compactMap { $0 }).contains(where: { $0.utf8.contains(0) }) else {
            throw ProcessRunnerError(executable: executable, message: "路径或参数包含空字符")
        }
        var outputPipe: [Int32] = [-1, -1], errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw failure(errno) }
        guard pipe(&errorPipe) == 0 else { let code = errno; close(outputPipe[0]); close(outputPipe[1]); throw failure(code) }
        defer {
            for descriptor in outputPipe + errorPipe where descriptor >= 0 { close(descriptor) }
        }
        for descriptor in outputPipe + errorPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw failure(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw failure(code) }
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO))
        for descriptor in outputPipe + errorPipe { try check(posix_spawn_file_actions_addclose(&actions, descriptor)) }
        if let directory { try check(posix_spawn_file_actions_addchdir(&actions, directory)) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        guard argv.dropLast().allSatisfy({ $0 != nil }) else {
            for pointer in argv { free(pointer) }
            throw failure(ENOMEM)
        }
        defer { for pointer in argv { free(pointer) } }
        var mutableArgv = argv
        var pid: pid_t = 0
        code = mutableArgv.withUnsafeMutableBufferPointer { pointer in
            posix_spawn(&pid, executable, &actions, &attributes, pointer.baseAddress!, environ)
        }
        guard code == 0 else {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            throw failure(code)
        }
        let killDone = state.withLock { state -> DispatchSemaphore? in
            state.pid = pid
            return state.cancelled ? state.killDone : nil
        }
        if let killDone { terminate(pid, done: killDone) }
        close(outputPipe[1]); outputPipe[1] = -1
        close(errorPipe[1]); errorPipe[1] = -1
        let readers = DispatchGroup()
        let output = OutputBuffer(); let errors = OutputBuffer()
        let outputDescriptor = outputPipe[0], errorDescriptor = errorPipe[0]
        readers.enter(); DispatchQueue.global(qos: .utility).async { output.readAll(outputDescriptor); readers.leave() }
        readers.enter(); DispatchQueue.global(qos: .utility).async { errors.readAll(errorDescriptor); readers.leave() }
        // Keep the leader unreaped until a pending SIGKILL has run. Its PID then
        // cannot be reused for an unrelated process group during the grace period.
        var info = siginfo_t()
        var observed: Int32
        repeat { observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while observed < 0 && errno == EINTR
        let waitError = observed < 0 ? errno : 0
        readers.wait()
        let pendingKill = state.withLock { state -> DispatchSemaphore? in
            if state.cancelled { return state.killDone }
            state.completed = true
            return nil
        }
        pendingKill?.wait()
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
        let reapError = waited < 0 ? errno : 0
        let cancelled = state.withLock { state in state.completed = true; return state.cancelled }
        if cancelled { throw CancellationError() }
        if waitError != 0 { throw failure(waitError) }
        if reapError != 0 { throw failure(reapError) }
        let signal = status & 0x7f
        let exitCode: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ProcessResult(exitCode: exitCode, stdout: output.text, stderr: errors.text)
    }
    private func check(_ code: Int32) throws { if code != 0 { throw failure(code) } }
    private func failure(_ code: Int32) -> ProcessRunnerError {
        ProcessRunnerError(executable: executable, message: String(cString: strerror(code)))
    }
}

private final class OutputBuffer: Sendable {
    private let buffer = Mutex(Data())
    var text: String {
        buffer.withLock { data in
            let decoded = String(decoding: data, as: UTF8.self)
            let suffix = decoded.utf8.suffix(65536).drop(while: { $0 & 0xc0 == 0x80 })
            return String(decoding: suffix, as: UTF8.self)
        }
    }
    func readAll(_ descriptor: Int32) {
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            buffer.withLock { data in
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 65536 { data.removeFirst(data.count - 65536) }
            }
        }
    }
}
