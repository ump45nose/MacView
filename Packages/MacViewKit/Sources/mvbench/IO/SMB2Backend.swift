import Darwin
import Foundation

/// 用 libsmb2 直连 SMB 共享的访问方式。
/// 目录参数仍是系统挂载下的路径，由挂载来源换算成服务器、共享和共享内路径；数据不经过系统挂载。
final class SMB2Backend: IOBackend {
    let library: LibSMB2
    let timeout: Int32
    private var share: SMBShare?
    private var credentials: SMBCredentials?
    /// 枚举用的会话，只在调用 list 的线程上使用。
    private var listSession: SMB2Session?

    init(libraryPath: String, timeout: Int32) throws {
        library = try LibSMB2(path: libraryPath)
        self.timeout = timeout
    }

    func files(in directory: String, limit: Int?) throws -> [SampleFile] {
        let path = try sharePath(of: directory)
        let session = try session()
        guard let dir = library.opendir(session.context, path) else {
            throw SMB2Error("smb2_opendir \(SampleDirectory.anonymizedName(directory))：\(session.lastError)")
        }
        defer { library.closedir(session.context, dir) }
        var files: [SampleFile] = []
        while let entry = library.readdir(session.context, dir) {
            let name = SMB2DirectoryEntry.name(entry)
            guard !name.hasPrefix("."),
                  entry.load(fromByteOffset: SMB2DirectoryEntry.typeOffset, as: UInt32.self) == SMB2DirectoryEntry.fileType
            else { continue }
            let size = entry.load(fromByteOffset: SMB2DirectoryEntry.sizeOffset, as: UInt64.self)
            files.append(SampleFile(path: path.isEmpty ? name : path + "/" + name, size: Int64(size)))
        }
        files.sort { $0.path < $1.path }
        return limit.map { Array(files.prefix($0)) } ?? files
    }

    func read(_ files: [SampleFile], shape: ReadShape) throws -> ReadOutcome {
        let chunk = min(shape.chunk, try session().maxReadSize)
        let depth = shape.depth
        let connections = min(shape.connections, shape.concurrency)
        let slots = (shape.concurrency + connections - 1) / connections
        let elapsed = try runOnConnections(connections, files: files) { session, queue, sink in
            let loop = SMB2ReadLoop(session: session, chunk: chunk, depth: depth, queue: queue)
            try loop.run(slots: slots)
            sink.append(contentsOf: loop.results.map { .read($0) })
        }
        return ReadOutcome(files: elapsed.results.compactMap(\.read), seconds: elapsed.seconds, chunk: chunk)
    }

    func probe(_ files: [SampleFile], concurrency: Int, length: Int) throws -> ProbeOutcome {
        let elapsed = try runOnConnections(1, files: files) { session, queue, sink in
            let loop = SMB2ProbeLoop(session: session, length: length, queue: queue)
            try loop.run(slots: concurrency)
            sink.append(contentsOf: loop.results)
        }
        return ProbeOutcome(
            timings: elapsed.results.compactMap(\.probe),
            errors: elapsed.results.compactMap(\.error),
            seconds: elapsed.seconds
        )
    }

    func list(_ directory: String, method: ListMethod, timeout: Double) throws -> ListAttempt {
        let path = try sharePath(of: directory)
        let session = try session()
        let clock = ContinuousClock()
        let start = clock.now
        guard let dir = library.opendir(session.context, path) else {
            let milliseconds = (clock.now - start).milliseconds
            return ListAttempt(error: "smb2_opendir: \(session.lastError)", milliseconds: milliseconds, timedOut: milliseconds > timeout * 1_000)
        }
        var count = 0
        while let entry = library.readdir(session.context, dir) {
            let name = SMB2DirectoryEntry.name(entry)
            if name != ".", name != ".." { count += 1 }
        }
        library.closedir(session.context, dir)
        let milliseconds = (clock.now - start).milliseconds
        return ListAttempt(entries: count, milliseconds: milliseconds, timedOut: milliseconds > timeout * 1_000)
    }

    /// 系统挂载路径在共享内的相对路径。第一次调用时确定共享并取得凭据，之后的路径必须在同一个共享里。
    private func sharePath(of directory: String) throws -> String {
        let mount = try MountInfo.of(directory)
        guard mount.fileSystem == "smbfs", let found = SMBShare.parse(source: mount.source) else {
            throw ValidationFailure("\(directory) 不在 SMB 挂载上，smb2 方式需要从 SMB 挂载换算共享")
        }
        if let share, share != found {
            throw ValidationFailure("smb2 方式下所有目录必须在同一个共享里")
        }
        if credentials == nil {
            credentials = try SMBCredentials.obtain(server: found.server, user: found.user)
        }
        share = found
        return try mount.relativePath(of: directory)
    }

    private func session() throws -> SMB2Session {
        if let listSession { return listSession }
        guard let share, let credentials else { throw ValidationFailure("还没有确定 SMB 共享") }
        let session = try SMB2Session.connect(library, share: share, credentials: credentials, timeout: timeout)
        listSession = session
        return session
    }

    /// 在 count 个连接上并行处理 files。各连接先在自己的线程上建立，全部建好后才开始计时。
    private func runOnConnections(
        _ count: Int,
        files: [SampleFile],
        _ body: @escaping @Sendable (SMB2Session, WorkQueue<SampleFile>, ResultSink<SMB2Result>) throws -> Void
    ) throws -> (results: [SMB2Result], seconds: Double) {
        guard let share, let credentials else { throw ValidationFailure("还没有确定 SMB 共享") }
        let library = library
        let timeout = timeout
        let queue = WorkQueue(files)
        let sink = ResultSink<SMB2Result>()
        let failures = ResultSink<String>()
        let connected = DispatchGroup()
        let finished = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0..<count {
            connected.enter()
            finished.enter()
            Thread {
                defer { finished.leave() }
                let session: SMB2Session
                do {
                    session = try SMB2Session.connect(library, share: share, credentials: credentials, timeout: timeout)
                } catch {
                    failures.append("\(error)")
                    connected.leave()
                    return
                }
                connected.leave()
                start.wait()
                do {
                    try body(session, queue, sink)
                } catch {
                    failures.append("\(error)")
                }
            }.start()
        }
        connected.wait()
        let clock = ContinuousClock()
        let begin = clock.now
        for _ in 0..<count { start.signal() }
        finished.wait()
        let seconds = (clock.now - begin).milliseconds / 1_000
        if let failure = failures.values.first { throw SMB2Error(failure) }
        return (sink.values, seconds)
    }
}

/// 各连接线程交回的结果。
enum SMB2Result: Sendable {
    case read(FileOutcome)
    case probe(ProbeTiming)
    case failure(String)

    var read: FileOutcome? {
        if case .read(let outcome) = self { outcome } else { nil }
    }

    var probe: ProbeTiming? {
        if case .probe(let timing) = self { timing } else { nil }
    }

    var error: String? {
        if case .failure(let message) = self { message } else { nil }
    }
}

/// 一个连接上的读取：同时打开 slots 个文件，每个文件保持 depth 个未完成的读请求。
/// 回复依次在同一线程上处理，所有请求共用一块缓冲区，数据只计字节数。
private final class SMB2ReadLoop {
    let session: SMB2Session
    let chunk: Int
    let depth: Int
    let queue: WorkQueue<SampleFile>
    let buffer: UnsafeMutablePointer<UInt8>
    let clock = ContinuousClock()
    private(set) var results: [FileOutcome] = []
    private var active = 0

    init(session: SMB2Session, chunk: Int, depth: Int, queue: WorkQueue<SampleFile>) {
        self.session = session
        self.chunk = chunk
        self.depth = depth
        self.queue = queue
        buffer = .allocate(capacity: chunk)
    }

    deinit {
        buffer.deallocate()
    }

    func run(slots: Int) throws(SMB2Error) {
        for _ in 0..<slots {
            guard let file = queue.take() else { break }
            start(file)
        }
        try session.run { active == 0 }
    }

    private final class FileRead {
        let file: SampleFile
        let started: ContinuousClock.Instant
        var handle: OpaquePointer?
        var nextOffset: Int64 = 0
        var outstanding = 0
        var received: Int64 = 0
        var error: String?

        init(file: SampleFile, started: ContinuousClock.Instant) {
            self.file = file
            self.started = started
        }
    }

    private func start(_ file: SampleFile) {
        let read = FileRead(file: file, started: clock.now)
        active += 1
        let library = session.library
        let context = session.context
        let submitted = session.submit({ callback, data in
            library.openAsync(context, file.path, O_RDONLY, callback, data)
        }) { status, data in
            guard status >= 0 else { return self.finish(read, error: "open: \(SMB2Session.describe(status))") }
            read.handle = OpaquePointer(data)
            self.fill(read)
        }
        if !submitted { finish(read, error: "open: \(session.lastError)") }
    }

    /// 补足未完成的读请求；文件读完或出错且没有未完成的请求时关闭文件。
    private func fill(_ read: FileRead) {
        let library = session.library
        let context = session.context
        let buffer = buffer
        while read.error == nil, read.outstanding < depth, read.nextOffset < read.file.size, let handle = read.handle {
            let offset = read.nextOffset
            let count = Int(min(Int64(chunk), read.file.size - offset))
            let submitted = session.submit({ callback, data in
                library.preadAsync(context, handle, buffer, UInt32(count), UInt64(offset), callback, data)
            }) { status, _ in
                read.outstanding -= 1
                if status < 0 {
                    read.error = read.error ?? "read: \(SMB2Session.describe(status))"
                } else {
                    read.received += Int64(status)
                    if Int(status) < count { read.error = read.error ?? "read: 只读到 \(status)/\(count) 字节" }
                }
                self.fill(read)
            }
            guard submitted else {
                read.error = "read: \(session.lastError)"
                break
            }
            read.outstanding += 1
            read.nextOffset += Int64(count)
        }
        if read.outstanding == 0, read.error != nil || read.nextOffset >= read.file.size, let handle = read.handle {
            read.handle = nil
            let submitted = session.submit({ callback, data in
                library.closeAsync(context, handle, callback, data)
            }) { status, _ in
                if status < 0, read.error == nil { read.error = "close: \(SMB2Session.describe(status))" }
                self.finish(read)
            }
            if !submitted { finish(read, error: read.error ?? "close: \(session.lastError)") }
        }
    }

    private func finish(_ read: FileRead, error: String? = nil) {
        active -= 1
        results.append(FileOutcome(milliseconds: (clock.now - read.started).milliseconds, bytes: read.received, error: error ?? read.error))
        if let next = queue.take() { start(next) }
    }
}

/// 一个连接上的小读：同时处理 slots 个文件，每个文件依次打开、读开头 length 字节、关闭。
private final class SMB2ProbeLoop {
    let session: SMB2Session
    let length: Int
    let queue: WorkQueue<SampleFile>
    let buffer: UnsafeMutablePointer<UInt8>
    let clock = ContinuousClock()
    private(set) var results: [SMB2Result] = []
    private var active = 0

    init(session: SMB2Session, length: Int, queue: WorkQueue<SampleFile>) {
        self.session = session
        self.length = length
        self.queue = queue
        buffer = .allocate(capacity: length)
    }

    deinit {
        buffer.deallocate()
    }

    func run(slots: Int) throws(SMB2Error) {
        for _ in 0..<slots {
            guard let file = queue.take() else { break }
            start(file)
        }
        try session.run { active == 0 }
    }

    private func start(_ file: SampleFile) {
        active += 1
        let library = session.library
        let context = session.context
        let buffer = buffer
        let length = UInt32(min(Int64(length), file.size))
        let begin = clock.now
        let opening = session.submit({ callback, data in
            library.openAsync(context, file.path, O_RDONLY, callback, data)
        }) { status, data in
            guard status >= 0, let handle = OpaquePointer(data) else {
                return self.finish(.failure("open: \(SMB2Session.describe(status))"))
            }
            let opened = self.clock.now
            let reading = self.session.submit({ callback, data in
                library.preadAsync(context, handle, buffer, length, 0, callback, data)
            }) { status, _ in
                let read = self.clock.now
                let readError = status < 0 ? "read: \(SMB2Session.describe(status))" : nil
                let closing = self.session.submit({ callback, data in
                    library.closeAsync(context, handle, callback, data)
                }) { status, _ in
                    let closed = self.clock.now
                    if let readError { return self.finish(.failure(readError)) }
                    if status < 0 { return self.finish(.failure("close: \(SMB2Session.describe(status))")) }
                    self.finish(.probe(ProbeTiming(
                        open: (opened - begin).milliseconds,
                        read: (read - opened).milliseconds,
                        close: (closed - read).milliseconds
                    )))
                }
                if !closing { self.finish(.failure("close: \(self.session.lastError)")) }
            }
            if !reading { self.finish(.failure("read: \(self.session.lastError)")) }
        }
        if !opening { finish(.failure("open: \(session.lastError)")) }
    }

    private func finish(_ result: SMB2Result) {
        active -= 1
        results.append(result)
        if let next = queue.take() { start(next) }
    }
}
