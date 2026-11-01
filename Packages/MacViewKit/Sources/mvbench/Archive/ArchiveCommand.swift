import ArgumentParser
import Foundation
import MVArchive
import MVFoundation
import MVIO

struct ArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive", abstract: "测量归档容器的解压、索引与原始读取吞吐。",
        discussion: "原始读取使用 4 并发、4 MB 块，与首次解压交替测量，默认取 3 轮中位数。来源只读；解出文件在每轮后删除。"
    )

    @Option(help: "zip、tar 或 gzip 文件；NAS 文件使用已有挂载路径。")
    var file: String

    @Option(help: "结果标签；图集请只写 No.xxxx 编号。")
    var label = "archive"

    @Option(help: "交替测量轮数。")
    var rounds = 3

    @Option(help: "临时解出目录的父目录；每次运行创建并清理自己的子目录。")
    var workDirectory = "build/stage-1-work"

    @Option(name: .shortAndLong, help: "JSON 输出文件；省略时输出到标准输出。")
    var output: String?

    struct Measurement: Encodable {
        var rawReadSeconds: Double
        var archiveSeconds: Double
        var rawMegabytesPerSecond: Double
        var archiveMegabytesPerSecond: Double
        var ratio: Double
        var rootEntries: Int
        var files: Int
        var mediaFiles: Int
        var extractedBytes: Int64
    }

    struct Result: Encodable {
        var sample: String
        var compressedBytes: Int64
        var rawConcurrency: Int
        var rawChunkBytes: Int
        var rounds: [Measurement]
        var medianRawMegabytesPerSecond: Double
        var medianArchiveMegabytesPerSecond: Double
        var throughputRatio: Double
        var nfsAcceptance: String
        var browsedAsTar: Bool
    }

    func validate() throws {
        guard rounds > 0 else { throw ValidationError("rounds 必须大于 0") }
    }

    func run() async throws {
        let runDirectory = URL(fileURLWithPath: workDirectory).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: executable))
        defer { scheduler.shutdown() }
        let registry = FileSourceRegistry(scheduler: scheduler)
        let location = try await registry.location(for: URL(fileURLWithPath: file))
        let source = try await registry.fileSystem.open(location)
        let mount = try MountInfo.of(file)
        let clock = ContinuousClock()
        var measurements: [Measurement] = []
        var browsedAsTar = EntryKind(fileName: location.name) == .archive(.tar)
        for round in 0..<rounds {
            let extract = runDirectory.appending(path: "round-\(round)")
            var rawSeconds = 0.0
            var archiveSeconds = 0.0
            var rootEntries = 0
            var counts = (files: 0, media: 0)
            func raw() async throws {
                let begin = clock.now
                try await Self.readRaw(source)
                rawSeconds = (clock.now - begin).milliseconds / 1000
            }
            func archive() async throws {
                let provider = try ArchiveProvider(fileSystem: registry.fileSystem, extractDirectory: extract)
                let begin = clock.now
                var children: [Entry] = []
                for try await batch in provider.children(of: location, priority: .visible) { children.append(contentsOf: batch) }
                rootEntries = children.count
                counts = try await Self.count(children, provider: provider)
                archiveSeconds = (clock.now - begin).milliseconds / 1000
            }
            if round.isMultiple(of: 2) { try await raw(); try await archive() }
            else { try await archive(); try await raw() }
            let extractedFiles = try FileManager.default.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil)
            var expanded: Int64 = 0
            for url in extractedFiles {
                let extractedLocation = try await registry.location(for: url)
                let bytes = try await registry.fileSystem.open(extractedLocation)
                expanded += bytes.identity.size
                if bytes.identity.size >= 512 {
                    let header = try await bytes.read(0..<512, priority: .visible, group: nil)
                    browsedAsTar = browsedAsTar || Self.isTarHeader(header)
                }
            }
            let mb = Double(source.identity.size) / 1_000_000
            let measurement = Measurement(
                rawReadSeconds: rawSeconds, archiveSeconds: archiveSeconds,
                rawMegabytesPerSecond: mb / rawSeconds, archiveMegabytesPerSecond: mb / archiveSeconds,
                ratio: rawSeconds / archiveSeconds, rootEntries: rootEntries, files: counts.files,
                mediaFiles: counts.media, extractedBytes: expanded
            )
            measurements.append(measurement)
            progress(String(format: "第 %d 轮：原始读取 %.1f MB/s，解压与索引 %.1f MB/s，比值 %.3f；%d 个文件，%d 个媒体文件",
                            round + 1, measurement.rawMegabytesPerSecond, measurement.archiveMegabytesPerSecond,
                            measurement.ratio, counts.files, counts.media))
            try FileManager.default.removeItem(at: extract)
        }
        let raw = Self.median(measurements.map(\.rawMegabytesPerSecond))
        let archive = Self.median(measurements.map(\.archiveMegabytesPerSecond))
        let result = Result(
            sample: SampleDirectory.anonymizedName(file), compressedBytes: source.identity.size,
            rawConcurrency: 4, rawChunkBytes: 4 << 20, rounds: measurements,
            medianRawMegabytesPerSecond: raw, medianArchiveMegabytesPerSecond: archive, throughputRatio: archive / raw,
            nfsAcceptance: mount.fileSystem == "nfs" ? "已测量" : "未验证：样本不在 NFS 挂载上",
            browsedAsTar: browsedAsTar
        )
        try IOReport.write(result, label: label, transport: .scheduler, paths: [file], output: output)
    }

    private static func readRaw(_ source: any ByteSource) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    let chunk: Int64 = 4 << 20
                    var offset = Int64(lane) * chunk
                    while offset < source.identity.size {
                        let upper = min(offset + chunk, source.identity.size)
                        let data = try await source.read(offset..<upper, priority: .visible, group: nil)
                        guard Int64(data.count) == upper - offset else { throw IOError.corrupted(source.identity.location, "原始读取不完整") }
                        offset += 4 * chunk
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private static func count(_ entries: [Entry], provider: ArchiveProvider) async throws -> (files: Int, media: Int) {
        var files = 0, media = 0
        for entry in entries {
            if entry.kind == .directory {
                var children: [Entry] = []
                for try await batch in provider.children(of: entry.location, priority: .visible) { children.append(contentsOf: batch) }
                let nested = try await count(children, provider: provider)
                files += nested.files
                media += nested.media
            } else {
                files += 1
                if entry.kind == .image || entry.kind == .video { media += 1 }
            }
        }
        return (files, media)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func isTarHeader(_ data: Data) -> Bool {
        guard data.count == 512 else { return false }
        let text = String(decoding: data[148..<156].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let expected = Int(text, radix: 8) else { return false }
        return expected == (0..<512).reduce(0) { $0 + ((148..<156).contains($1) ? 32 : Int(data[$1])) }
    }
}
