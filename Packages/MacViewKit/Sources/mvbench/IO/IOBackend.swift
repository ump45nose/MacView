import ArgumentParser
import Darwin
import Foundation
import Synchronization

/// 被测的访问方式。读取、小读和枚举三项测量通过它访问文件。
protocol IOBackend {
    /// 列出样本目录里的文件。directory 是系统挂载下的路径。
    func files(in directory: String, limit: Int?) throws -> [SampleFile]
    /// 按 shape 读完 files。
    func read(_ files: [SampleFile], shape: ReadShape) throws -> ReadOutcome
    /// 对 files 做小读，同时处理 concurrency 个文件。
    func probe(_ files: [SampleFile], concurrency: Int, length: Int) throws -> ProbeOutcome
    /// 列出一次目录。超过 timeout 秒记为超时。
    func list(_ directory: String, method: ListMethod, timeout: Double) throws -> ListAttempt
}

/// 一次读取测量的参数。depth 和 connections 只对 smb2 有效。
struct ReadShape: Equatable, Sendable {
    /// 同时读的文件数。
    var concurrency: Int
    /// 每次读取的块大小。
    var chunk: Int
    /// 每个文件同时未完成的读请求数。
    var depth = 4
    /// 连接数，不超过 concurrency。
    var connections = 1
}

/// 一个文件的读取结果。
struct FileOutcome: Sendable {
    var milliseconds: Double
    var bytes: Int64
    var error: String?
}

struct ReadOutcome: Sendable {
    var files: [FileOutcome]
    var seconds: Double
    /// 实际使用的块大小；smb2 会按服务器允许的上限截断。
    var chunk: Int
}

struct ProbeOutcome: Sendable {
    var timings: [ProbeTiming]
    var errors: [String]
    var seconds: Double
}

/// 目录的列法。
enum ListMethod: String, Codable, Sendable, ExpressibleByArgument, CaseIterable {
    /// getattrlistbulk，一次调用返回一批名称和属性。
    case bulk
    /// readdir 列名称，再逐项 lstat。
    case readdir
    /// libsmb2 的 opendir/readdir，一次 QUERY_DIRECTORY 返回名称和属性。
    case smb2
}

/// 一次列目录的结果。
struct ListAttempt: Sendable {
    var entries: Int?
    var error: String?
    var milliseconds: Double
    var timedOut = false
}

/// 系统挂载路径上的访问方式。
struct PosixBackend: IOBackend {
    var noCache: Bool

    func files(in directory: String, limit: Int?) throws -> [SampleFile] {
        try Samples.files(in: directory, limit: limit)
    }

    func read(_ files: [SampleFile], shape: ReadShape) -> ReadOutcome {
        let queue = WorkQueue(files)
        let sink = ResultSink<FileOutcome>()
        let noCache = noCache
        let chunk = shape.chunk
        let clock = ContinuousClock()
        let start = clock.now
        BlockingThreads.run(count: shape.concurrency) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: Int(getpagesize()))
            defer { buffer.deallocate() }
            while let file = queue.take() {
                let begin = clock.now
                do {
                    let bytes = try PosixFiles.readWhole(file.path, into: buffer, noCache: noCache)
                    sink.append(FileOutcome(milliseconds: (clock.now - begin).milliseconds, bytes: bytes))
                } catch {
                    sink.append(FileOutcome(milliseconds: (clock.now - begin).milliseconds, bytes: 0, error: "\(error)"))
                }
            }
        }
        return ReadOutcome(files: sink.values, seconds: (clock.now - start).milliseconds / 1_000, chunk: chunk)
    }

    func probe(_ files: [SampleFile], concurrency: Int, length: Int) -> ProbeOutcome {
        let queue = WorkQueue(files)
        let timings = ResultSink<ProbeTiming>()
        let errors = ResultSink<String>()
        let noCache = noCache
        let clock = ContinuousClock()
        let start = clock.now
        BlockingThreads.run(count: concurrency) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: Int(getpagesize()))
            defer { buffer.deallocate() }
            while let file = queue.take() {
                do {
                    timings.append(try PosixFiles.probe(file.path, into: buffer, noCache: noCache))
                } catch {
                    errors.append("\(error)")
                }
            }
        }
        return ProbeOutcome(timings: timings.values, errors: errors.values, seconds: (clock.now - start).milliseconds / 1_000)
    }

    func list(_ directory: String, method: ListMethod, timeout: Double) throws -> ListAttempt {
        let list: @Sendable (String) throws(SystemCallError) -> Int
        switch method {
        case .bulk: list = PosixFiles.listWithBulk
        case .readdir: list = PosixFiles.listWithReaddir
        case .smb2: throw ValidationFailure("smb2 列法只能和 --transport smb2 一起用")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let call = BlockingCall.start {
            let begin = clock.now
            do {
                let entries = try list(directory)
                return ListAttempt(entries: entries, milliseconds: (clock.now - begin).milliseconds)
            } catch {
                return ListAttempt(error: "\(error)", milliseconds: (clock.now - begin).milliseconds)
            }
        }
        if let attempt = call.wait(seconds: timeout) {
            return attempt
        }
        // 超时后继续等它返回，以记录实际阻塞的时长。
        var attempt = call.wait(seconds: abandonAfterSeconds - timeout)
            ?? ListAttempt(error: "超过 \(Int(abandonAfterSeconds)) 秒仍未返回", milliseconds: (clock.now - start).milliseconds)
        attempt.timedOut = true
        return attempt
    }
}

/// 被卡住的调用最多等这么久，之后放弃等待，线程留在后台。
let abandonAfterSeconds: Double = 120

/// 在专用线程上运行一次可能被卡住的调用，有期限地等待结果。系统调用无法取消，超时后线程留在后台。
final class BlockingCall<Value: Sendable>: Sendable {
    private let result = Mutex<Value?>(nil)
    private let done = DispatchSemaphore(value: 0)

    static func start(_ body: @escaping @Sendable () -> Value) -> BlockingCall {
        let call = BlockingCall()
        Thread {
            let value = body()
            call.result.withLock { $0 = value }
            call.done.signal()
        }.start()
        return call
    }

    /// 等 seconds 秒；结果已知时立即返回，超时返回 nil。可以多次调用。
    func wait(seconds: Double) -> Value? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        done.signal()
        return result.withLock { $0 }
    }
}
