import ArgumentParser
import Darwin
import Foundation
import Synchronization

/// `mvbench io`：比较 NAS 访问方式的吞吐、小读延迟、目录枚举，以及 NAS 卡住或断线时的行为。
struct IOCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "io",
        abstract: "测量读取吞吐、小读延迟、目录枚举和 NAS 故障时的行为。",
        subcommands: [
            ReadCommand.self,
            ProbeCommand.self,
            ListCommand.self,
            ProxyCommand.self,
            FaultCommand.self,
            HoldCommand.self,
            BatchCommand.self,
        ]
    )
}

/// 访问文件的方式。
enum Transport: String, Codable, Sendable, ExpressibleByArgument {
    /// 经由系统挂载的路径，走内核的 SMB 或 NFS 客户端。
    case posix
    /// 用 libsmb2 直连路径所在的 SMB 共享，凭据取自钥匙串。
    case smb2
}

/// 读取、小读和枚举共用的访问方式选项。
struct TransportOptions: ParsableArguments {
    @Option(help: "访问方式：posix 走系统挂载；smb2 用 libsmb2 直连路径所在的 SMB 共享。")
    var transport: Transport = .posix

    @Option(help: "libsmb2 动态库的路径，由 scripts/build-libsmb2.sh 生成。")
    var libsmb2 = "build/libsmb2/install/lib/libsmb2.dylib"

    @Option(help: "smb2：命令超时的秒数。")
    var smb2Timeout: Int32 = 30
}

/// 结果文件共用的选项。
struct ReportOptions: ParsableArguments {
    @Option(help: "写进结果的标签，用来区分被测的访问方式，例如 smb、nfs、smb2。")
    var label: String

    @Option(name: .shortAndLong, help: "JSON 输出文件；省略时输出到标准输出。")
    var output: String?
}

/// 一次 io 测量写出的 JSON。
struct IOReport<Result: Encodable>: Encodable {
    var label: String
    var transport: Transport
    var environment: BenchEnvironment
    var finishedAt: Date
    var result: Result

    /// 采集环境信息并写出结果。环境里记录各目录所在的卷，以及访问 NAS 所用的网络接口。
    static func write(_ result: Result, label: String, transport: Transport, paths: [String], output: String?) throws {
        let host = paths.lazy.compactMap { try? MountInfo.of($0).host }.first
        var environment = BenchEnvironment.collect(paths: paths, host: host)
        for index in environment.volumes.indices {
            environment.volumes[index].path = SampleDirectory.anonymizedPath(environment.volumes[index].path)
        }
        let report = IOReport(
            label: label,
            transport: transport,
            environment: environment,
            finishedAt: Date(),
            result: result
        )
        try JSONReport.write(report, to: output)
    }
}

/// 字节数参数，接受 `65536`、`64K`、`8M` 这样的写法，单位按 1024 进位。
struct ByteCount: ExpressibleByArgument, Hashable, Sendable {
    var bytes: Int

    init(_ bytes: Int) {
        self.bytes = bytes
    }

    init?(argument: String) {
        let scales: [Character: Int] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30]
        var digits = Substring(argument.uppercased())
        var scale = 1
        if let unit = digits.last, let value = scales[unit] {
            scale = value
            digits = digits.dropLast()
        }
        guard let value = Int(digits), value > 0 else { return nil }
        bytes = value * scale
    }
}

/// 被测目录里的一个文件。posix 方式下是绝对路径，smb2 方式下是共享内的相对路径。
struct SampleFile: Sendable {
    var path: String
    var size: Int64
}

/// 结果里记录的样本目录。
struct SampleDirectory: Codable, Sendable {
    var name: String
    var files: Int
    var bytes: Int64

    init(path: String, files: [SampleFile]) {
        name = Self.anonymizedName(path)
        self.files = files.count
        bytes = files.reduce(0) { $0 + $1.size }
    }

    /// 图集目录名含有模特姓名，结果里只记编号，例如 `[XiuRen秀人网] 2022.06.10 No.5133 …` → `No.5133`。
    static func anonymizedName(_ path: String) -> String {
        albumNumber((path as NSString).lastPathComponent)
    }

    /// 路径里的每一级图集目录都只记编号。
    static func anonymizedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { albumNumber(String($0)) }.joined(separator: "/")
    }

    private static func albumNumber(_ name: String) -> String {
        name.firstMatch(of: /(?i)(?:no|vol)\.\s*(\d+)/).map { "No.\($0.1)" } ?? name
    }
}

enum Samples {
    /// 列出目录下的普通文件（跳过隐藏文件），按名称排序；limit 限制取的文件数。
    static func files(in directory: String, limit: Int?) throws -> [SampleFile] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var files: [SampleFile] = []
        for name in names {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            files.append(SampleFile(path: path, size: Int64(info.st_size)))
            if let limit, files.count == limit { break }
        }
        return files
    }

    /// 列出目录下的子目录（跳过隐藏项），按名称排序。
    static func subdirectories(of directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { directory + "/" + $0 }
            .filter { path in
                var info = stat()
                return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
    }
}

/// 阻塞的文件系统调用放在专用线程上，不占用 Swift 并发的协作线程池。
enum BlockingThreads {
    /// 启动 count 个线程运行 body(序号)，全部结束后返回。
    static func run(count: Int, _ body: @escaping @Sendable (Int) -> Void) {
        let group = DispatchGroup()
        for index in 0..<count {
            group.enter()
            Thread {
                body(index)
                group.leave()
            }.start()
        }
        group.wait()
    }
}

/// 多个线程共同领取的任务列表，每项只交给一个线程。
final class WorkQueue<Item: Sendable>: Sendable {
    let items: [Item]
    private let next = Atomic<Int>(0)

    init(_ items: [Item]) {
        self.items = items
    }

    func take() -> Item? {
        let index = next.wrappingAdd(1, ordering: .relaxed).oldValue
        return index < items.count ? items[index] : nil
    }
}

/// 多个线程共同写入的结果。
final class ResultSink<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    func append(contentsOf values: [Value]) {
        storage.withLock { $0.append(contentsOf: values) }
    }

    var values: [Value] {
        storage.withLock { $0 }
    }
}

/// 按错误描述计数。
func errorCounts(_ errors: some Sequence<String?>) -> [String: Int] {
    errors.compactMap { $0 }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}

/// 进度输出到标准错误，标准输出留给 JSON。
func progress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
