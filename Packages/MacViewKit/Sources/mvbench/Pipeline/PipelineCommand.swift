import ArgumentParser
import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVTestSupport

/// 包含真实 I/O、图片解码、缩放和渐进流交付的端到端基准。
struct PipelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pipeline", abstract: "测量首图、缓存首屏与交替的原始读取/缩略图生成吞吐。")

    @Option(name: .customLong("dir"), help: "首图样本目录；每次使用不同文件。")
    var directory: String?
    @Option(help: "首图文件数；正式验收为 10。")
    var limit = 10
    @Option(help: "显示目标长边。")
    var longSide = 2560
    @Option(help: "缓存目录条目数；正式验收为 10000。")
    var cachedEntries = 10_000
    @Option(help: "缓存首屏的输出长边。")
    var thumbnail = 256
    @Option(help: "缓存首屏测量轮数；每轮重新建立管线，L1 为空。")
    var repetitions = 10
    @Flag(help: "对 --dir 额外运行 3 轮交替吞吐测量；4 并发、4 MB 块。")
    var throughput = false
    @Option(help: "本次临时缓存的父目录；运行后清理。")
    var workDirectory = "build/stage3-work/pipeline-bench"
    @Option(name: .shortAndLong, help: "JSON 输出路径。")
    var output: String?

    struct Throughput: Encodable {
        var pass: Int
        var rawMegabytesPerSecond: Double
        var thumbnailMegabytesPerSecond: Double
        var thumbnailsPerSecond: Double
    }
    struct Result: Encodable {
        var environment: BenchEnvironment
        var finishedAt: Date
        var cacheCondition: String
        var firstImageMilliseconds: Summary?
        var firstImagePixelSize: PixelSize?
        var firstImageSourcePixelSizes: [PixelSize]
        var firstImageSourceBytes: Summary?
        var firstImageFiles: Int
        var firstImagePassed: Bool?
        var cachedEntries: Int
        var firstScreenFiles: Int
        var firstScreenOutputLongSide: Int
        var firstScreenMilliseconds: Summary?
        var firstScreenPassed: Bool
        var throughput: [Throughput]
        var thumbnailToRawRatio: Double?
        var nasValidation: String
    }

    func validate() throws {
        guard limit > 0, longSide > 0, cachedEntries >= 60, repetitions > 0, thumbnail > 0 else {
            throw ValidationError("limit、long-side、repetitions、thumbnail 必须大于 0，cached-entries 至少为 60。")
        }
        if throughput, directory == nil { throw ValidationError("吞吐测量需要 --dir。") }
    }

    func run() async throws {
        let root = URL(filePath: workDirectory, directoryHint: .isDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = SchedulerBackend.registry(concurrency: 4, chunk: 4 << 20)
        defer { registry.scheduler.shutdown() }
        let decoder = ImageDecoder()
        let fixture = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
        // ImageIO/IOSurface 的一次性初始化不属于某个文件的首次管线交付。
        _ = try await decoder.image(fixture, target: DisplayTarget(pixelSize: PixelSize(width: 64, height: 96)))
        var cold: [Double] = []
        var firstSize: PixelSize?
        var sourceSizes: [PixelSize] = []
        var sourceBytes: [Double] = []
        var identities: [ContentIdentity] = []
        if let directory {
            let location = try await registry.location(for: URL(filePath: directory, directoryHint: .isDirectory))
            for try await batch in try registry.provider(for: location).children(of: location, priority: .visible) {
                identities += batch.filter { $0.kind == .image }.map(\.identity)
            }
            identities.sort { $0.location.description < $1.location.description }
            guard !identities.isEmpty else { throw ValidationFailure("样本目录没有图片。") }
            let pipe = try Self.pipeline(root.appendingPathComponent("cold"), registry: registry, decoder: decoder, browse: true)
            for identity in identities.prefix(limit) {
                let metadata = try await Self.header(identity, registry: registry)
                let target = metadata.pixelSize.fitting(longSide: longSide)
                firstSize = target
                sourceSizes.append(metadata.pixelSize)
                sourceBytes.append(Double(identity.size))
                let clock = ContinuousClock()
                let begin = clock.now
                var exactTime: Double?
                for try await image in pipe.image(for: identity, target: DisplayTarget(pixelSize: target), allowOriginal: false, priority: .visible) {
                    if image.quality >= .exact, exactTime == nil { exactTime = (clock.now - begin).milliseconds }
                }
                guard let exactTime else { throw ValidationFailure("管线没有交付精确尺寸。") }
                cold.append(exactTime)
            }
        }
        progress("预置 \(cachedEntries) 个真实 JPEG 缩略图，逐轮清空 L1 测量 60 张解码交付……")
        let cachedRoot = root.appendingPathComponent("cached")
        let index = try CacheIndex(databaseURL: cachedRoot.appendingPathComponent("index.sqlite"))
        let disk = try DiskCache(tier: .thumbnails, cacheDirectory: cachedRoot, budget: 4 << 30, index: index)
        let rendition = try await decoder.image(fixture, target: DisplayTarget(pixelSize: PixelSize(width: 683, height: 1024)))
        let bytes = try RenditionEncoding.default.encode(rendition.image)
        let container = Location(root: .local, layers: [["pipeline-cached-benchmark"]])
        let cached = (0..<cachedEntries).map { ContentIdentity(location: container.appending("\($0).jpg"), size: 1, modificationNanos: Int64($0)) }
        for identity in cached { try await disk.store(bytes, for: identity.cacheKey) }
        _ = try await DirectoryCache(index: index).update(container, listing: DirectoryListing(entries: cached.map { Entry(identity: $0, name: $0.location.name, kind: .image) }, directoryModificationNanos: 1))
        try await index.flush()
        let firstScreen = (0..<60).map { cached[$0 * cached.count / 60] }
        var screen: [Double] = []
        for _ in 0..<repetitions {
            // 每轮新的 L0/L1；L2 文件可以在操作系统页缓存里。
            let caches = PipelineCaches(raw: MemoryCache(budget: 0), decoded: MemoryCache(budget: 0), thumbnails: disk, browse: nil, metadata: MetadataIndex(index: index))
            let pipe = FileImagePipeline(sources: registry, decoder: decoder, caches: caches, configuration: PipelineConfiguration(browseBounds: PixelSize(width: 2560, height: 1600)))
            let clock = ContinuousClock()
            let begin = clock.now
            var delivered = 0
            for await (_, result) in pipe.thumbnails(for: firstScreen, maxPixel: thumbnail, priority: .visible) {
                _ = try result.get()
                delivered += 1
            }
            guard delivered == 60 else { throw ValidationFailure("首屏交付数量错误。") }
            screen.append((clock.now - begin).milliseconds)
        }
        var rounds: [Throughput] = []
        if throughput {
            let bytes = identities.reduce(Int64(0)) { $0 + $1.size }
            for pass in 1...3 {
                // 两种测量交替，避免分开跑两组时网络负载漂移。
                let clock = ContinuousClock()
                let rawStart = clock.now
                try await Self.raw(identities, registry: registry)
                let rawSeconds = (clock.now - rawStart).milliseconds / 1000
                let pipe = try Self.pipeline(root.appendingPathComponent("throughput-\(pass)"), registry: registry, decoder: decoder, browse: false)
                let thumbnailStart = clock.now
                try await Self.thumbnailBatch(identities, pipeline: pipe)
                let thumbnailSeconds = (clock.now - thumbnailStart).milliseconds / 1000
                rounds.append(Throughput(pass: pass, rawMegabytesPerSecond: Double(bytes) / 1e6 / rawSeconds, thumbnailMegabytesPerSecond: Double(bytes) / 1e6 / thumbnailSeconds, thumbnailsPerSecond: Double(identities.count) / thumbnailSeconds))
            }
        }
        let rawMedian = Summary(rounds.map(\.rawMegabytesPerSecond))?.p50
        let thumbnailMedian = Summary(rounds.map(\.thumbnailMegabytesPerSecond))?.p50
        let ratio = rawMedian.flatMap { raw in thumbnailMedian.map { $0 / raw } }
        let nfs = try directory.map { try MountInfo.of($0).fileSystem == "nfs" } ?? false
        let coldSummary = Summary(cold)
        let screenSummary = Summary(screen)
        let result = Result(environment: .collect(paths: directory.map { [$0] } ?? [cachedRoot.path], host: nil), finishedAt: Date(),
                            cacheCondition: "首图每次不同 ContentIdentity，L0/L1/L2/L3 为空；计时从 image 调用到 exact 交付，含 I/O、解码、缩放。首屏为 10000 条 L2 中均匀选 60 条，L1 每轮为空，计时含 SQLite、文件读取、JPEG 解码、缩放与全部流交付；操作系统页缓存未清空。",
                            firstImageMilliseconds: coldSummary, firstImagePixelSize: firstSize, firstImageSourcePixelSizes: sourceSizes,
                            firstImageSourceBytes: Summary(sourceBytes), firstImageFiles: cold.count,
                            firstImagePassed: coldSummary.map { cold.count == 10 && sourceSizes.allSatisfy { $0 == PixelSize(width: 3600, height: 5400) } && $0.p95 <= 150 }, cachedEntries: cachedEntries, firstScreenFiles: 60,
                            firstScreenOutputLongSide: thumbnail, firstScreenMilliseconds: screenSummary,
                            firstScreenPassed: cachedEntries == 10_000 && (screenSummary?.p95 ?? .infinity) <= 100,
                            throughput: rounds, thumbnailToRawRatio: ratio,
                            nasValidation: nfs && throughput ? "NFS 只读，4 并发、4 MB 块，3 轮交替测量的中位数比值。" : "未验证：未提供在线 NFS 样本目录并启用吞吐测量。")
        progress(String(format: "首图 P95 %.2f ms；60 张首屏 P95 %.2f ms；缩略图/原始读取吞吐比 %.1f%%", coldSummary?.p95 ?? 0, screenSummary?.p95 ?? 0, (ratio ?? 0) * 100))
        try JSONReport.write(result, to: output)
    }

    private static func pipeline(_ root: URL, registry: FileSourceRegistry, decoder: ImageDecoder, browse: Bool) throws -> FileImagePipeline {
        let index = try CacheIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let thumbnails = try DiskCache(tier: .thumbnails, cacheDirectory: root, budget: 4 << 30, index: index)
        let browseCache = try browse ? DiskCache(tier: .browse, cacheDirectory: root, budget: 4 << 30, index: index) : nil
        let caches = PipelineCaches(raw: MemoryCache(budget: 256 << 20), decoded: MemoryCache(budget: 256 << 20), thumbnails: thumbnails, browse: browseCache, metadata: MetadataIndex(index: index))
        return FileImagePipeline(sources: registry, decoder: decoder, caches: caches, configuration: PipelineConfiguration(browseBounds: PixelSize(width: 2560, height: 1600)))
    }

    private static func header(_ identity: ContentIdentity, registry: FileSourceRegistry) async throws -> ImageMetadata {
        let source = try await registry.provider(for: identity.location).open(identity.location)
        var length = min(identity.size, Int64(MediaProbe.initialHeaderLength))
        while true {
            let data = try await source.read(0..<length, priority: .visible, group: nil)
            switch try MediaProbe.image(data, isComplete: length >= source.identity.size) {
            case let .metadata(value): return value
            case let .needsMoreData(next): length = min(source.identity.size, Int64(next ?? Int(source.identity.size)))
            }
        }
    }

    private static func raw(_ identities: [ContentIdentity], registry: FileSourceRegistry) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                let identity = identities[next]
                next += 1
                group.addTask {
                    let source = try await registry.provider(for: identity.location).open(identity.location)
                    _ = try await source.read(0..<source.identity.size, priority: .visible, group: nil)
                }
            }
            for _ in 0..<min(4, identities.count) { enqueue() }
            while try await group.next() != nil { if next < identities.count { enqueue() } }
        }
    }

    private static func thumbnailBatch(_ identities: [ContentIdentity], pipeline: FileImagePipeline) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                let identity = identities[next]
                next += 1
                group.addTask { _ = try await pipeline.thumbnail(for: identity, maxPixel: 1024, priority: .visible) }
            }
            for _ in 0..<min(4, identities.count) { enqueue() }
            while try await group.next() != nil { if next < identities.count { enqueue() } }
        }
    }
}
