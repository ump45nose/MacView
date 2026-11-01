import Darwin
import Foundation
import Synchronization

/// 执行阻塞文件操作的地方：本机卷在进程内的专用线程上，网络卷在辅助进程中。
/// 结果经回调在任意线程上返回；调用不能取消，只有列目录能在批与批之间停下。
protocol FileBackend: Sendable {
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void)
    /// 卷的健康探测，见 `FileOperations.probe`。
    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void)
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void)
    /// `batch` 返回 false 时停止，之后不再回调 completion 以外的方法。
    func list(
        _ path: String,
        batch: @escaping @Sendable ([FileAttributes]) -> Bool,
        completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void
    )
    /// 放弃卡住的执行者：之后的请求换新的执行者，还没返回的请求以 `helperLost` 结束。
    func abandon()
}

/// 进程内执行。并发由调度器的槽位限制，所以队列的线程数有上界。
final class DirectBackend: FileBackend {
    private let queue = DispatchQueue(label: "io.github.ump45nose.MacView.io", qos: .userInitiated, attributes: .concurrent)
    private let reader = FileReader()

    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        queue.async { completion(Result { () throws(FileOperationError) in try FileOperations.stat(path) }) }
    }

    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        queue.async { completion(Result { () throws(FileOperationError) in try FileOperations.probe(mountPoint) }) }
    }

    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {
        queue.async { [reader] in completion(Result { () throws(FileOperationError) in try reader.read(request) }) }
    }

    func list(
        _ path: String,
        batch: @escaping @Sendable ([FileAttributes]) -> Bool,
        completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void
    ) {
        queue.async { completion(Result { () throws(FileOperationError) in try FileOperations.list(path, batch: batch) }) }
    }

    /// 进程内被卡住的线程无法回收。
    func abandon() {}
}

/// 在辅助进程中执行。辅助进程按需启动；被弃用后杀掉，等它自行消失，下一个请求启动新的。
final class HelperBackend: FileBackend {
    private let executable: URL
    private let connection = Mutex<HelperConnection?>(nil)

    init(executable: URL) {
        self.executable = executable
    }

    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        send(.stat(path: path)) { response in
            switch response {
            case let .attributes(attributes): completion(.success(attributes)); return true
            case let .failure(error): completion(.failure(error)); return true
            default: completion(.failure(.helperLost)); return true
            }
        }
    }

    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        send(.probe(mountPoint: mountPoint)) { response in
            switch response {
            case .done: completion(.success(())); return true
            case let .failure(error): completion(.failure(error)); return true
            default: completion(.failure(.helperLost)); return true
            }
        }
    }

    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {
        send(.read(request)) { response in
            switch response {
            case let .data(data): completion(.success(data)); return true
            case let .failure(error): completion(.failure(error)); return true
            default: completion(.failure(.helperLost)); return true
            }
        }
    }

    func list(
        _ path: String,
        batch: @escaping @Sendable ([FileAttributes]) -> Bool,
        completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void
    ) {
        let stopped = Atomic(false)
        let target = Mutex<(HelperConnection, UInt64)?>(nil)
        let sent = send(.list(path: path)) { response in
            switch response {
            case let .batch(entries):
                guard !stopped.load(ordering: .relaxed) else { return false }
                if batch(entries) { return false }
                stopped.store(true, ordering: .relaxed)
                if let (connection, id) = target.withLock({ $0 }) { connection.send(.cancel(id: id), handler: nil) }
                completion(.success(()))
                return false
            case .done:
                if !stopped.load(ordering: .relaxed) { completion(.success(())) }
                return true
            case let .failure(error):
                if !stopped.load(ordering: .relaxed) { completion(.failure(error)) }
                return true
            default:
                completion(.failure(.helperLost))
                return true
            }
        }
        target.withLock { $0 = sent }
    }

    func abandon() {
        connection.withLock { $0.take() }?.terminate()
    }

    /// handler 返回 true 表示这个请求结束。
    @discardableResult
    private func send(_ request: HelperRequest, handler: @escaping @Sendable (HelperResponse) -> Bool) -> (HelperConnection, UInt64)? {
        let current: HelperConnection
        do {
            current = try connection.withLock { connection in
                if let existing = connection, existing.isAlive { return existing }
                let started = try HelperConnection(executable: executable)
                connection = started
                return started
            }
        } catch {
            _ = handler(.failure(.helperLost))
            return nil
        }
        guard let id = current.send(request, handler: handler) else { return nil }
        return (current, id)
    }
}

/// 一个辅助进程和它的套接字。
final class HelperConnection: Sendable {
    private struct State {
        var nextID: UInt64 = 1
        var handlers: [UInt64: @Sendable (HelperResponse) -> Bool] = [:]
        var alive = true
    }

    let pid: pid_t
    private let socket: Int32
    private let state = Mutex(State())
    private let writer = Mutex(())

    init(executable: URL) throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw FileOperationError.system(call: "socketpair", code: errno) }
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 只继承上面三个描述符。
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let path = executable.path
        let environment = ProcessInfo.processInfo.environment.merging([IOHelper.environmentKey: "1"]) { $1 }
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings([path]) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            }
        }
        close(pair[1])
        guard status == 0 else {
            close(pair[0])
            throw FileOperationError.system(call: "posix_spawn", code: status)
        }
        self.pid = pid
        socket = pair[0]
        let thread = Thread { [self] in receive() }
        thread.name = "MVIO helper \(pid)"
        thread.start()
        // 回收子进程。卡住的辅助进程要等网络恢复才会消失，这个线程就一直等着。
        let child = pid
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0, errno == EINTR {}
        }
    }

    var isAlive: Bool {
        state.withLock { $0.alive }
    }

    /// 发出请求，返回编号；连接已经断开时立即以 `helperLost` 回调并返回 nil。
    @discardableResult
    func send(_ request: HelperRequest, handler: (@Sendable (HelperResponse) -> Bool)?) -> UInt64? {
        let id: UInt64? = state.withLock { state in
            guard state.alive else { return nil }
            let id = state.nextID
            state.nextID += 1
            if let handler { state.handlers[id] = handler }
            return id
        }
        guard let id else {
            _ = handler?(.failure(.helperLost))
            return nil
        }
        let written = writer.withLock { _ in FrameIO.write(socket, HelperCodec.encode(id: id, request)) }
        if !written { fail() }
        return id
    }

    /// 杀掉辅助进程。卡在内核里的进程收不到信号也不会立即消失，所以不等它。
    func terminate() {
        kill(pid, SIGKILL)
        Darwin.shutdown(socket, SHUT_RDWR)
        fail()
    }

    private func receive() {
        while let body = FrameIO.read(socket) {
            guard let (id, response) = try? HelperCodec.decodeResponse(body) else { break }
            guard let handler = state.withLock({ $0.handlers[id] }) else { continue }
            if handler(response) {
                state.withLock { _ = $0.handlers.removeValue(forKey: id) }
            }
        }
        fail()
    }

    deinit {
        close(socket)
    }

    /// 连接断开：还没结束的请求都以 `helperLost` 结束。
    private func fail() {
        let pending = state.withLock { state in
            state.alive = false
            defer { state.handlers.removeAll() }
            return Array(state.handlers.values)
        }
        for handler in pending { _ = handler(.failure(.helperLost)) }
    }
}

/// 把字符串数组转成以 nil 结尾的 C 字符串数组，供 posix_spawn 使用。
private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
