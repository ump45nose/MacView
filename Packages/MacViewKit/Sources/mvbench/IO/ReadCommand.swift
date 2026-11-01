import ArgumentParser
import Foundation

/// `mvbench io read`：读整个文件，测吞吐和单个文件的读取耗时。
struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "读整个文件，测吞吐（MB/s、张/s）和单个文件的读取耗时。",
        discussion: """
            默认先用 4 并发预热一轮，让文件进入服务端缓存，再按每种组合读 --passes 轮，各轮内依次跑所有组合。
            --cold 时不预热，每种组合只读一轮，第 i 种组合读第 i 个目录，用来测没读过的文件。
            smb2 的组合还包括 --depth 与 --connections；连接数超过并发数时按并发数算，重复的组合只跑一次。
            """
    )

    @OptionGroup var report: ReportOptions
    @OptionGroup var access: TransportOptions

    @Option(name: .customLong("dir"), help: "样本目录（系统挂载下的路径），可重复。")
    var directories: [String]

    @Option(help: "每个目录最多取的文件数。")
    var limit: Int?

    @Option(parsing: .upToNextOption, help: "同时读的文件数，可给多个值。")
    var concurrency: [Int] = [1]

    @Option(parsing: .upToNextOption, help: "每次读取的块大小，可给多个值，例如 64K 1M 8M。")
    var chunk: [ByteCount] = [ByteCount(1 << 20)]

    @Option(help: "每种组合读几轮。")
    var passes = 3

    @Flag(help: "冷读：不预热，每种组合只读一轮，第 i 种组合读第 i 个目录。")
    var cold = false

    @Flag(help: "posix：允许本机缓存数据（默认用 F_NOCACHE 绕过）。")
    var useCache = false

    @Option(parsing: .upToNextOption, help: "smb2：每个文件同时未完成的读请求数，可给多个值。")
    var depth: [Int] = [4]

    @Option(parsing: .upToNextOption, help: "smb2：连接数，并发的文件平均分到各连接，可给多个值。")
    var connections: [Int] = [1]

    func run() throws {
        let backend = try makeBackend(access, noCache: !useCache)
        let samples = try directories.map { (path: $0, files: try backend.files(in: $0, limit: limit)) }
        let shapes = shapes
        var runs: [ReadRun] = []
        if cold {
            guard shapes.count == samples.count else {
                throw ValidationError("冷读时每种组合对应一个目录：现有 \(shapes.count) 种组合、\(samples.count) 个目录")
            }
            for (shape, sample) in zip(shapes, samples) {
                let name = SampleDirectory.anonymizedName(sample.path)
                runs.append(try measure(backend, sample.files, shape: shape, pass: 1, directory: name))
            }
        } else {
            let files = samples.flatMap(\.files)
            runs.append(try measure(backend, files, shape: ReadShape(concurrency: 4, chunk: 1 << 20), pass: 0, directory: nil))
            for pass in 1...passes {
                for shape in shapes {
                    runs.append(try measure(backend, files, shape: shape, pass: pass, directory: nil))
                }
            }
        }
        let result = ReadResult(
            cold: cold,
            noCache: !useCache,
            directories: samples.map { SampleDirectory(path: $0.path, files: $0.files) },
            runs: runs
        )
        try IOReport.write(result, label: report.label, transport: access.transport, paths: directories, output: report.output)
    }

    /// 各参数的全部组合，按选项给出的顺序排列。
    var shapes: [ReadShape] {
        let isSMB2 = access.transport == .smb2
        var shapes: [ReadShape] = []
        for concurrency in concurrency {
            for chunk in chunk {
                for depth in isSMB2 ? depth : [4] {
                    for connections in isSMB2 ? connections : [1] {
                        let shape = ReadShape(concurrency: concurrency, chunk: chunk.bytes, depth: depth, connections: min(connections, concurrency))
                        if !shapes.contains(shape) { shapes.append(shape) }
                    }
                }
            }
        }
        return shapes
    }

    private func measure(_ backend: any IOBackend, _ files: [SampleFile], shape: ReadShape, pass: Int, directory: String?) throws -> ReadRun {
        let isSMB2 = access.transport == .smb2
        let before = NetworkCounters.receivedBytes()
        let outcome = try backend.read(files, shape: shape)
        let received = NetworkCounters.delta(from: before, to: NetworkCounters.receivedBytes())
        let succeeded = outcome.files.filter { $0.error == nil }
        let bytes = outcome.files.reduce(0) { $0 + $1.bytes }
        let run = ReadRun(
            concurrency: shape.concurrency,
            chunkBytes: outcome.chunk,
            depth: isSMB2 ? shape.depth : nil,
            connections: isSMB2 ? shape.connections : nil,
            pass: pass,
            directory: directory,
            files: outcome.files.count,
            bytes: bytes,
            seconds: outcome.seconds,
            megabytesPerSecond: Double(bytes) / 1e6 / outcome.seconds,
            filesPerSecond: Double(succeeded.count) / outcome.seconds,
            fileMilliseconds: Summary(succeeded.map(\.milliseconds)),
            errors: errorCounts(outcome.files.map(\.error)),
            receivedBytes: received
        )
        let pipeline = isSMB2 ? " 深度 \(shape.depth) 连接 \(shape.connections)" : ""
        progress(String(
            format: "%@ 并发 %d 块 %dK%@ 第 %d 轮：%.1f MB/s，%.2f 张/s，错误 %d",
            report.label, shape.concurrency, outcome.chunk >> 10, pipeline, pass, run.megabytesPerSecond, run.filesPerSecond,
            run.errors.values.reduce(0, +)
        ))
        return run
    }
}

struct ReadResult: Encodable {
    var cold: Bool
    var noCache: Bool
    var directories: [SampleDirectory]
    var runs: [ReadRun]
}

/// 一种组合读一轮的结果。吞吐按 1 MB = 10^6 字节计。
struct ReadRun: Codable, Sendable {
    var concurrency: Int
    var chunkBytes: Int
    /// smb2：每个文件同时未完成的读请求数。
    var depth: Int?
    /// smb2：连接数。
    var connections: Int?
    /// 第几轮；0 表示预热。
    var pass: Int
    /// 冷读时本轮读的目录。
    var directory: String?
    var files: Int
    var bytes: Int64
    var seconds: Double
    var megabytesPerSecond: Double
    var filesPerSecond: Double
    /// 单个文件从打开到读完的耗时，毫秒。
    var fileMilliseconds: Summary?
    var errors: [String: Int]
    /// 本轮各网络接口收到的字节数。
    var receivedBytes: [String: UInt64]
}

/// 按访问方式创建被测对象。
func makeBackend(_ options: TransportOptions, noCache: Bool) throws -> any IOBackend {
    switch options.transport {
    case .posix:
        PosixBackend(noCache: noCache)
    case .smb2:
        try SMB2Backend(libraryPath: options.libsmb2, timeout: options.smb2Timeout)
    case .scheduler:
        SchedulerBackend()
    }
}
