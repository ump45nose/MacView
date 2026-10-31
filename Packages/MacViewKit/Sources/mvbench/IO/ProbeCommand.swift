import ArgumentParser
import Foundation

/// `mvbench io probe`：打开、读开头一小段、关闭，测元数据探测的延迟。
struct ProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "小读：打开、读开头 --length 字节、关闭，分阶段统计延迟。",
        discussion: """
            first 轮把文件按并发值分成互不重叠的几组，每个文件在本进程里第一次被打开；
            repeat 轮再按每个并发值把全部文件各探测一遍，用来对照客户端缓存的影响。
            """
    )

    @OptionGroup var report: ReportOptions
    @OptionGroup var access: TransportOptions

    @Option(name: .customLong("dir"), help: "样本目录（系统挂载下的路径），可重复。")
    var directories: [String]

    @Option(help: "每个目录最多取的文件数。")
    var limit: Int?

    @Option(parsing: .upToNextOption, help: "同时探测的文件数，可给多个值。")
    var concurrency: [Int] = [1, 4]

    @Option(help: "读取的长度。")
    var length = ByteCount(64 << 10)

    @Flag(help: "posix：允许本机缓存数据（默认用 F_NOCACHE 绕过）。")
    var useCache = false

    func run() throws {
        let backend = try makeBackend(access, noCache: !useCache)
        let samples = try directories.map { (path: $0, files: try backend.files(in: $0, limit: limit)) }
        let files = samples.flatMap(\.files)
        var runs: [ProbeRun] = []
        let groupSize = (files.count + concurrency.count - 1) / concurrency.count
        for (index, concurrency) in concurrency.enumerated() {
            let group = Array(files.dropFirst(index * groupSize).prefix(groupSize))
            runs.append(try measure(backend, group, concurrency: concurrency, pass: "first"))
        }
        for concurrency in concurrency {
            runs.append(try measure(backend, files, concurrency: concurrency, pass: "repeat"))
        }
        let result = ProbeResult(
            lengthBytes: length.bytes,
            noCache: !useCache,
            directories: samples.map { SampleDirectory(path: $0.path, files: $0.files) },
            runs: runs
        )
        try IOReport.write(result, label: report.label, transport: access.transport, paths: directories, output: report.output)
    }

    private func measure(_ backend: any IOBackend, _ files: [SampleFile], concurrency: Int, pass: String) throws -> ProbeRun {
        let outcome = try backend.probe(files, concurrency: concurrency, length: length.bytes)
        let run = ProbeRun(
            concurrency: concurrency,
            pass: pass,
            operations: outcome.timings.count + outcome.errors.count,
            seconds: outcome.seconds,
            operationsPerSecond: Double(outcome.timings.count) / outcome.seconds,
            open: Summary(outcome.timings.map(\.open)),
            read: Summary(outcome.timings.map(\.read)),
            close: Summary(outcome.timings.map(\.close)),
            total: Summary(outcome.timings.map(\.total)),
            errors: errorCounts(outcome.errors)
        )
        progress(String(
            format: "%@ %@ 并发 %d：P50 %.1f ms，P95 %.1f ms，错误 %d",
            report.label, pass, concurrency, run.total?.p50 ?? .nan, run.total?.p95 ?? .nan, outcome.errors.count
        ))
        return run
    }
}

struct ProbeResult: Encodable {
    var lengthBytes: Int
    var noCache: Bool
    var directories: [SampleDirectory]
    var runs: [ProbeRun]
}

/// 一轮小读的结果。各阶段耗时单位为毫秒，只统计成功的操作。
struct ProbeRun: Codable, Sendable {
    var concurrency: Int
    /// first：本进程第一次打开这些文件；repeat：已打开过一次。
    var pass: String
    var operations: Int
    var seconds: Double
    var operationsPerSecond: Double
    var open: Summary?
    var read: Summary?
    var close: Summary?
    var total: Summary?
    var errors: [String: Int]
}
