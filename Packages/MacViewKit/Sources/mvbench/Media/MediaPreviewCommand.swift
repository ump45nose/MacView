import ArgumentParser
import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import Synchronization

struct MediaPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "逐视频测量二十张预览帧的冷取首帧、冷取全部、内存命中和磁盘命中用时。",
        discussion: "每轮使用独立空缓存；冷取指应用缓存为空，不清系统文件缓存。缓存命中阶段禁止重新打开视频。临时缓存放在当前目录的 build 下，结束时清理；JSON 不记录文件名。"
    )

    @OptionGroup var options: MediaOptions

    @Option(help: "每个视频独立重复的次数。")
    var `repeat` = 1

    struct Sample: Encodable {
        var fileIndex: Int
        var iteration: Int
        var format: String
        var coldFirstFrameMilliseconds: Double
        var coldAllFramesMilliseconds: Double
        var memoryAllFramesMilliseconds: Double
        var diskAllFramesMilliseconds: Double
    }

    struct Result: Encodable {
        var frameCount = VideoPreview.frameCount
        var longSide = VideoPreview.longSide
        var repeats: Int
        var coldFirstFrameMilliseconds: Summary?
        var coldAllFramesMilliseconds: Summary?
        var memoryAllFramesMilliseconds: Summary?
        var diskAllFramesMilliseconds: Summary?
        var samples: [Sample]
    }

    mutating func validate() throws {
        guard self.repeat > 0 else { throw ValidationError("--repeat 必须大于 0") }
        if let limit = options.limit, limit <= 0 { throw ValidationError("--limit 必须大于 0") }
    }

    static func videoFiles(directory: String, limit: Int?) throws -> [SampleFile] {
        let videos = try Samples.files(in: directory, limit: nil).filter { EntryKind(fileName: $0.path) == .video }
        let selected = limit.map { Array(videos.prefix($0)) } ?? videos
        guard !selected.isEmpty else { throw ValidationFailure("样本目录下没有 mp4、mov 或 m4v 视频") }
        return selected
    }

    func run() async throws {
        let files = try Self.videoFiles(directory: options.directory, limit: options.limit)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/mvbench-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var samples: [Sample] = []
        for (index, file) in files.enumerated() {
            for iteration in 1...self.repeat {
                let timings = try await Self.measure(file, cacheDirectory: root.appending(path: "\(index)-\(iteration)"))
                samples.append(Sample(
                    fileIndex: index, iteration: iteration, format: URL(fileURLWithPath: file.path).pathExtension.lowercased(),
                    coldFirstFrameMilliseconds: timings.cold.first, coldAllFramesMilliseconds: timings.cold.all,
                    memoryAllFramesMilliseconds: timings.memory.all, diskAllFramesMilliseconds: timings.disk.all
                ))
            }
        }
        let result = Result(
            repeats: self.repeat,
            coldFirstFrameMilliseconds: Summary(samples.map(\.coldFirstFrameMilliseconds)),
            coldAllFramesMilliseconds: Summary(samples.map(\.coldAllFramesMilliseconds)),
            memoryAllFramesMilliseconds: Summary(samples.map(\.memoryAllFramesMilliseconds)),
            diskAllFramesMilliseconds: Summary(samples.map(\.diskAllFramesMilliseconds)), samples: samples
        )
        progress(String(format: "视频预览 %d 个 × %d 轮：冷取首帧最大 %.1f ms，全部最大 %.1f ms，内存最大 %.1f ms，磁盘最大 %.1f ms",
                        files.count, self.repeat, result.coldFirstFrameMilliseconds?.max ?? 0, result.coldAllFramesMilliseconds?.max ?? 0,
                        result.memoryAllFramesMilliseconds?.max ?? 0, result.diskAllFramesMilliseconds?.max ?? 0))
        try MediaReport.write(result, directory: options.directory, files: files.count, output: options.output)
    }

    private static func measure(_ file: SampleFile, cacheDirectory: URL) async throws -> (cold: Timing, memory: Timing, disk: Timing) {
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: URL(fileURLWithPath: CommandLine.arguments[0])))
        defer { scheduler.shutdown() }
        let base = FileSourceRegistry(scheduler: scheduler)
        let sources = PreviewBenchmarkSources(base: base)
        let location = try await base.location(for: URL(fileURLWithPath: file.path))
        let identity = try await base.provider(for: location).entry(at: location).identity
        let cache = try PreviewBenchmarkCache(directory: cacheDirectory)
        let pipeline = cache.pipeline(sources: sources)
        do {
            let cold = try await consume(pipeline, identity: identity)
            // 确认二十帧都在内存，避免把磁盘回退误报成内存命中。
            guard (0..<VideoPreview.frameCount).allSatisfy({ cache.caches.thumbnailMemory.value(for: "\(identity.cacheKey)|preview|\($0)") != nil }) else {
                throw ValidationFailure("冷取结束后预览帧未全部进入内存缓存")
            }
            sources.forbidVideoReads()
            let memory = try await consume(pipeline, identity: identity)
            // 先等完整帧条落盘；shutdown 会取消仍在执行的衍生写入。
            let deadline = ContinuousClock.now + .seconds(5)
            while try await !cache.caches.thumbnails.contains(identity.cacheKey + "|preview") {
                guard ContinuousClock.now < deadline else { throw ValidationFailure("完整预览帧条五秒内未写入磁盘缓存") }
                try await Task.sleep(for: .milliseconds(10))
            }
            // 磁盘阶段重建全部内存缓存及索引实例。
            await pipeline.shutdown()
            try await cache.index.flush()
            let restarted = try PreviewBenchmarkCache(directory: cacheDirectory)
            let diskPipeline = restarted.pipeline(sources: sources)
            do {
                let disk = try await consume(diskPipeline, identity: identity)
                await diskPipeline.shutdown()
                try await restarted.index.flush()
                return (cold, memory, disk)
            } catch {
                await diskPipeline.shutdown()
                throw error
            }
        } catch {
            await pipeline.shutdown()
            throw error
        }
    }

    private struct Timing { var first: Double; var all: Double }

    private static func consume(_ pipeline: FileImagePipeline, identity: ContentIdentity) async throws -> Timing {
        let start = ContinuousClock.now
        var first: Double?
        var indices: Set<Int> = []
        for try await frame in pipeline.videoPreviewFrames(for: identity, priority: .near) {
            if first == nil { first = start.duration(to: .now).milliseconds }
            guard (0..<VideoPreview.frameCount).contains(frame.index), indices.insert(frame.index).inserted else {
                throw ValidationFailure("预览流交付了重复或越界的帧下标")
            }
        }
        guard indices.count == VideoPreview.frameCount, let first else { throw ValidationFailure("预览流未交付完整二十帧") }
        return Timing(first: first, all: start.duration(to: .now).milliseconds)
    }
}

private struct PreviewBenchmarkCache {
    let index: CacheIndex
    let caches: PipelineCaches

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try CacheIndex(databaseURL: directory.appending(path: "index.sqlite"))
        caches = PipelineCaches(
            raw: MemoryCache(budget: 1 << 20), decoded: MemoryCache(budget: 1 << 20),
            thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: directory, budget: 256 << 20, index: index),
            browse: nil, metadata: MetadataIndex(index: index),
            thumbnailMemory: MemoryCache(budget: 128 << 20), preload: MemoryCache(budget: 1 << 20)
        )
    }

    func pipeline(sources: any SourceRegistry) -> FileImagePipeline {
        FileImagePipeline(sources: sources, decoder: ImageDecoder(), caches: caches,
                          configuration: PipelineConfiguration(browseBounds: PixelSize(width: 640, height: 640)))
    }
}

/// 两次缓存测量禁止打开原视频，防止缓存失效后悄悄重新取帧。
private final class PreviewBenchmarkSources: SourceRegistry {
    let base: FileSourceRegistry
    private let readsForbidden = Mutex(false)

    init(base: FileSourceRegistry) { self.base = base }
    func forbidVideoReads() { readsForbidden.withLock { $0 = true } }
    func checkVideoRead() throws {
        if readsForbidden.withLock({ $0 }) { throw ValidationFailure("缓存命中测量重新打开了原视频") }
    }
    func provider(for location: Location) throws -> any ContainerProvider {
        PreviewBenchmarkProvider(base: try base.provider(for: location), sources: self)
    }
    func location(for fileURL: URL) async throws -> Location { try await base.location(for: fileURL) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
}

private struct PreviewBenchmarkProvider: ContainerProvider {
    let base: any ContainerProvider
    let sources: PreviewBenchmarkSources
    func canHandle(_ location: Location) -> Bool { base.canHandle(location) }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        base.children(of: container, priority: priority)
    }
    func entry(at location: Location) async throws -> Entry { try await base.entry(at: location) }
    func open(_ location: Location) async throws -> any ByteSource {
        try sources.checkVideoRead()
        return try await base.open(location)
    }
    func fileLease(for location: Location) async throws -> FileLease {
        try sources.checkVideoRead()
        return try await base.fileLease(for: location)
    }
}
