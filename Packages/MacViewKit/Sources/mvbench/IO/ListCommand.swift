import ArgumentParser
import Foundation

/// `mvbench io list`：重复列目录，比较列法的耗时，统计错误和超时。
struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "重复列出目录，统计各列法的耗时、错误和超时次数。",
        discussion: "每一轮依次用每种列法列每个目录，交错进行，避免某种列法总落在缓存刚填好的时候。"
    )

    @OptionGroup var report: ReportOptions
    @OptionGroup var access: TransportOptions

    @Option(name: .customLong("dir"), help: "要列的目录（系统挂载下的路径），可重复。")
    var directories: [String]

    @Option(parsing: .upToNextOption, help: "列法：bulk（getattrlistbulk）、readdir（readdir + lstat）；smb2 方式下固定为 smb2。")
    var method: [ListMethod] = [.bulk, .readdir]

    @Option(name: .customLong("repeat"), help: "每个目录、每种列法重复的次数。")
    var repetitions = 100

    @Option(help: "超过这个秒数记为超时。")
    var timeout: Double = 10

    func run() throws {
        let backend = try makeBackend(access, noCache: true)
        let methods = access.transport == .smb2 ? [ListMethod.smb2] : method
        var attempts: [String: [ListAttempt]] = [:]
        for round in 1...repetitions {
            for directory in directories {
                for method in methods {
                    let attempt = try backend.list(directory, method: method, timeout: timeout)
                    attempts["\(directory)\n\(method.rawValue)", default: []].append(attempt)
                    if attempt.error != nil || attempt.timedOut {
                        progress("\(report.label) 第 \(round) 轮 \(SampleDirectory.anonymizedName(directory)) \(method.rawValue)：\(attempt.error ?? "超时")")
                    }
                }
            }
            if round % 10 == 0 { progress("\(report.label) 已完成 \(round)/\(repetitions) 轮") }
        }
        let series = directories.flatMap { directory in
            methods.map { method in
                ListSeries(directory: directory, method: method, attempts: attempts["\(directory)\n\(method.rawValue)"] ?? [])
            }
        }
        try IOReport.write(
            ListResult(timeoutSeconds: timeout, series: series),
            label: report.label, transport: access.transport, paths: directories, output: report.output
        )
    }
}

struct ListResult: Encodable {
    var timeoutSeconds: Double
    var series: [ListSeries]
}

/// 一个目录、一种列法的全部结果。耗时单位为毫秒。
struct ListSeries: Encodable {
    var directory: String
    var method: ListMethod
    var attempts: Int
    /// 列出的项数及其出现次数；正常时只有一个值。
    var entries: [String: Int]
    /// 第一次列的耗时，客户端此时还没有这个目录的缓存。
    var firstMilliseconds: Double?
    /// 未超时的成功调用的耗时。
    var milliseconds: Summary?
    var errors: [String: Int]
    var timeouts: Int
    /// 超时的调用实际阻塞了多久。
    var timedOutMilliseconds: [Double]

    init(directory: String, method: ListMethod, attempts: [ListAttempt]) {
        self.directory = SampleDirectory.anonymizedName(directory)
        self.method = method
        self.attempts = attempts.count
        entries = attempts.compactMap(\.entries).reduce(into: [:]) { $0[String($1), default: 0] += 1 }
        firstMilliseconds = attempts.first?.milliseconds
        milliseconds = Summary(attempts.filter { $0.error == nil && !$0.timedOut }.map(\.milliseconds))
        errors = errorCounts(attempts.map(\.error))
        timeouts = attempts.filter(\.timedOut).count
        timedOutMilliseconds = attempts.filter(\.timedOut).map(\.milliseconds)
    }
}
