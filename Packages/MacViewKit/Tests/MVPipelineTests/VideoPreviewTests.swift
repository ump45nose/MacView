import AVFoundation
import Foundation
@testable import MVCache
import MVFoundation
import MVIO
@testable import MVMedia
import MVTestSupport
import Synchronization
import Testing
@testable import MVPipeline

/// C1.6、C1.7：冷取得到完整时间线，再访只使用内存。
@Test func videoPreviewColdThenMemory() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    let frames = try await previewCollect(env.pipeline, env.registry.identity)
    #expect(frames.map(\.index) == Array(0..<20))
    #expect(Set(frames.compactMap { $0.image.image.dataProvider?.data as Data? }).count == 20)
    let metadata = try await env.pipeline.metadata(for: env.registry.identity, priority: .near)
    for frame in frames {
        #expect(frame.duration == metadata.duration)
        #expect(frame.time == VideoPreview.time(of: frame.index, duration: frame.duration))
        #expect(frame.image.surface != nil)
        #expect(max(frame.image.image.width, frame.image.image.height) <= 640)
    }
    env.registry.resetOpens()
    let start = ContinuousClock.now
    let cached = try await previewCollect(env.pipeline, env.registry.identity)
    #expect(start.duration(to: .now) < .milliseconds(50))
    #expect(cached.map(\.index) == Array(0..<20))
    #expect(env.registry.opens == 0)
    await env.pipeline.shutdown()
}

/// C1.8：清空内存和重建全部缓存对象后仍能从同一磁盘目录恢复。
@Test func videoPreviewDiskAndRestart() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    let cold = try await previewCollect(env.pipeline, env.registry.identity)
    try await previewEventually { try await env.caches.thumbnails.contains(env.key) }
    env.caches.thumbnailMemory.removeValues { _ in true }
    env.registry.resetOpens()
    let disk = try await previewCollect(env.pipeline, env.registry.identity)
    #expect(disk.map(\.index) == Array(0..<20))
    #expect(disk.map { $0.image.image.width } == cold.map { $0.image.image.width })
    #expect(disk.allSatisfy { $0.image.surface != nil })
    for (original, restored) in zip(cold, disk) {
        let before = try #require(original.image.image.dataProvider?.data as Data?)
        let after = try #require(restored.image.image.dataProvider?.data as Data?)
        var difference = 0, samples = 0
        for y in stride(from: 0, to: original.image.image.height, by: 16) {
            for x in stride(from: 0, to: original.image.image.width, by: 16) {
                for channel in 0..<3 {
                    difference += abs(Int(before[y * original.image.image.bytesPerRow + x * 4 + channel])
                                      - Int(after[y * restored.image.image.bytesPerRow + x * 4 + channel]))
                    samples += 1
                }
            }
        }
        #expect(Double(difference) / Double(samples) < 20, "JPEG 恢复应保留对应帧的位置和内容")
    }
    #expect(env.registry.opens == 0)
    await env.pipeline.shutdown()
    try await env.index.flush()
    let restarted = try PreviewEnvironment(root: env.root, registry: env.registry)
    let restored = try await previewCollect(restarted.pipeline, restarted.registry.identity)
    #expect(restored.count == 20)
    #expect(env.registry.opens == 0)
    await restarted.pipeline.shutdown()
}

/// C1.9：在第 5 张交付处暂停真实管线，使取消边界确定；再次只请求缺失时间点。
@Test func videoPreviewCancellationKeepsPartialMemoryAndOnlyDecodesMissingTimes() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    env.pipeline.previewFrameDelivered.withLock { hook in
        hook = { index in if index == 4 { try await Task.sleep(for: .seconds(30)) } }
    }
    let partial = Task {
        var indices: [Int] = []
        do {
            for try await frame in env.pipeline.videoPreviewFrames(for: env.registry.identity, priority: .near) {
                indices.append(frame.index)
                if indices.count == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        } catch is CancellationError {} catch { throw error }
        return indices
    }
    #expect(try await partial.value == Array(0..<5))
    try await previewEventually { env.pipeline.memory.inFlightBytes == 0 }
    #expect(try await env.caches.thumbnails.contains(env.key) == false)
    for index in 0..<20 {
        #expect((env.caches.thumbnailMemory.value(for: env.key + "|\(index)") != nil) == (index < 5))
    }
    env.pipeline.previewFrameDelivered.withLock { $0 = nil }
    let requested = Mutex<[Double]>([])
    env.pipeline.previewDecodeTimes.withLock { $0 = { times in requested.withLock { $0 = times } } }
    let frames = try await previewCollect(env.pipeline, env.registry.identity)
    #expect(frames.map(\.index) == Array(0..<20))
    let duration = try #require(frames.first?.duration)
    #expect(requested.withLock { $0 } == (5..<20).map { VideoPreview.time(of: $0, duration: duration) })
    try await previewEventually { try await env.caches.thumbnails.contains(env.key) }
    await env.pipeline.shutdown()
}

/// C1.10：无效格式与关停都遵守协议；已有元数据缺时长时重新探测视频。
@Test func videoPreviewUnsupportedShutdownAndMissingDuration() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    var unsupported = env.registry.identity
    unsupported.location = Location(root: .local, layers: [["image.jpg"]])
    await #expect(throws: MediaError.unsupported) { _ = try await previewCollect(env.pipeline, unsupported) }
    try await env.caches.metadata.store([env.registry.identity.cacheKey: ImageMetadata(pixelSize: PixelSize(width: 640, height: 360))], in: env.registry.identity.location.parent!)
    #expect(try await previewCollect(env.pipeline, env.registry.identity).count == 20)
    await env.pipeline.shutdown()
    await #expect(throws: CancellationError.self) { _ = try await previewCollect(env.pipeline, env.registry.identity) }
}

@Test func videoPreviewMemoryHitRepairsMissingDiskStrip() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    try await env.caches.thumbnails.setBudget(0)
    _ = try await previewCollect(env.pipeline, env.registry.identity)
    try await previewEventually { env.pipeline.memory.inFlightBytes == 0 }
    #expect(try await env.caches.thumbnails.contains(env.key) == false)
    try await env.caches.thumbnails.setBudget(64 << 20)
    env.registry.resetOpens()
    #expect(try await previewCollect(env.pipeline, env.registry.identity).count == 20)
    #expect(env.registry.opens == 0)
    try await previewEventually { try await env.caches.thumbnails.contains(env.key) }
    await env.pipeline.shutdown()
}

@Test func videoPreviewRejectsNonpositiveDuration() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    try await env.caches.metadata.store([env.registry.identity.cacheKey: ImageMetadata(pixelSize: PixelSize(width: 1280, height: 720), duration: 0)],
                                        in: env.registry.identity.location.parent!)
    await #expect(throws: (any Error).self) { _ = try await previewCollect(env.pipeline, env.registry.identity) }
    #expect(env.registry.opens == 0)
    await env.pipeline.shutdown()
}

/// C1.10b：时长探测与取帧分别取消，100 ms 后没有新读取且读任务均已返回。
@Test(arguments: [false, true]) func videoPreviewNetworkCancellationStopsReads(metadataKnown: Bool) async throws {
    let env = try PreviewEnvironment(network: true)
    defer { env.clean() }
    if metadataKnown { _ = try await env.pipeline.metadata(for: env.registry.identity, priority: .near) }
    env.registry.reads.withLock { $0 = PreviewReadState(delay: .seconds(30)) }
    let consumer = Task { try await previewCollect(env.pipeline, env.registry.identity) }
    try await previewEventually { env.registry.reads.withLock { $0.started > 0 } }
    consumer.cancel()
    _ = try? await consumer.value
    try await Task.sleep(for: .milliseconds(100))
    let stopped = env.registry.reads.withLock { ($0.started, $0.active) }
    #expect(stopped.1 == 0)
    try await Task.sleep(for: .milliseconds(100))
    #expect(env.registry.reads.withLock { $0.started } == stopped.0)
    await env.pipeline.shutdown()
    #expect(env.pipeline.memory.inFlightBytes == 0)
}

/// C1.10c：两个独立网络桥上的请求互不取消。
@Test func videoPreviewConcurrentCancellationIsIndependent() async throws {
    let env = try PreviewEnvironment(network: true)
    defer { env.clean() }
    env.pipeline.previewFrameDelivered.withLock { $0 = { _ in try await Task.sleep(for: .milliseconds(5)) } }
    let first = Task {
        do {
            for try await frame in env.pipeline.videoPreviewFrames(for: env.registry.identity, priority: .near) {
                if frame.index == 4 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        } catch is CancellationError {}
    }
    let second = Task { try await previewCollect(env.pipeline, env.registry.identity) }
    try await first.value
    #expect(try await second.value.map(\.index) == Array(0..<20))
    await env.pipeline.shutdown()
}

/// C1.10d：请求自持完整帧集；内存仅容几帧、最后一帧即取消也能完成衍生写入。
@Test func videoPreviewTinyMemoryAndFinalFrameCancellationStillPersists() async throws {
    let env = try PreviewEnvironment(memoryBudget: 2 << 20)
    defer { env.clean() }
    let consumer = Task {
        var count = 0
        do {
            for try await _ in env.pipeline.videoPreviewFrames(for: env.registry.identity, priority: .near) {
                count += 1
                if count == 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        } catch is CancellationError {}
        return count
    }
    #expect(try await consumer.value == 20)
    try await previewEventually { try await env.caches.thumbnails.contains(env.key) }
    await env.pipeline.shutdown()
    try await env.index.flush()
    let restarted = try PreviewEnvironment(root: env.root, registry: env.registry)
    env.registry.resetOpens()
    #expect(try await previewCollect(restarted.pipeline, env.registry.identity).count == 20)
    #expect(env.registry.opens == 0)
    await restarted.pipeline.shutdown()
}

/// C1.10b：写盘队列被占住时关停；返回时在途额度与临时文件均排空。
@Test func videoPreviewShutdownDrainsQueuedStripWrite() async throws {
    let env = try PreviewEnvironment()
    defer { env.clean() }
    let gate = DispatchSemaphore(value: 0)
    let occupied = Mutex(false)
    let blocker = Task { try await env.index.diskOperations.perform { occupied.withLock { $0 = true }; gate.wait() } }
    try await previewEventually { occupied.withLock { $0 } }
    #expect(try await previewCollect(env.pipeline, env.registry.identity).count == 20)
    try await previewEventually { env.index.diskOperations.pendingCount > 1 }
    let shutdown = Task { await env.pipeline.shutdown() }
    gate.signal()
    await shutdown.value
    try await blocker.value
    #expect(env.pipeline.memory.inFlightBytes == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: env.root.appendingPathComponent("thumbnails/tmp").path).isEmpty)
}

@Test func videoPreviewShutdownStopsActiveGeneratorAndReaders() async throws {
    let env = try PreviewEnvironment(network: true)
    defer { env.clean() }
    _ = try await env.pipeline.metadata(for: env.registry.identity, priority: .near)
    env.registry.reads.withLock { $0 = PreviewReadState(delay: .seconds(30)) }
    let consumer = Task { try await previewCollect(env.pipeline, env.registry.identity) }
    try await previewEventually { env.registry.reads.withLock { $0.active > 0 } }
    await env.pipeline.shutdown()
    await #expect(throws: CancellationError.self) { _ = try await consumer.value }
    #expect(env.registry.reads.withLock { $0.active } == 0)
    #expect(env.decoder.limiter.runningCount == 0)
    #expect(env.decoder.limiter.waitingCount == 0)
}

@Test func videoPreviewTimelineClampsPointerPositions() {
    #expect(VideoPreview.index(at: -1) == 0)
    #expect(VideoPreview.index(at: 0) == 0)
    #expect(VideoPreview.index(at: 0.5) == 10)
    #expect(VideoPreview.index(at: 1) == 19)
    #expect(VideoPreview.index(at: 2) == 19)
    #expect(VideoPreview.time(of: 0, duration: 20) == 0.5)
    #expect(VideoPreview.time(of: 19, duration: 20) == 19.5)
}

private func previewCollect(_ pipeline: FileImagePipeline, _ identity: ContentIdentity) async throws -> [VideoPreviewFrame] {
    var frames: [VideoPreviewFrame] = []
    for try await frame in pipeline.videoPreviewFrames(for: identity, priority: .near) { frames.append(frame) }
    return frames
}

private func previewEventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw PreviewFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private enum PreviewFailure: Error { case timeout }

private final class PreviewEnvironment: Sendable {
    let root: URL
    let registry: PreviewRegistry
    let caches: PipelineCaches
    let index: CacheIndex
    let pipeline: FileImagePipeline
    let decoder: ImageDecoder
    var key: String { registry.identity.cacheKey + "|preview" }
    init(root: URL? = nil, registry: PreviewRegistry? = nil, network: Bool = false, memoryBudget: Int64 = 64 << 20) throws {
        self.root = root ?? Fixtures.root.deletingLastPathComponent().appendingPathComponent("build/w13-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.registry = try registry ?? PreviewRegistry(network: network)
        index = try CacheIndex(databaseURL: self.root.appendingPathComponent("index.sqlite"))
        caches = PipelineCaches(raw: MemoryCache(budget: 0), decoded: MemoryCache(budget: 0),
                                thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: self.root, budget: 64 << 20, index: index),
                                browse: nil, metadata: MetadataIndex(index: index),
                                thumbnailMemory: MemoryCache(budget: memoryBudget), preload: MemoryCache(budget: 0))
        decoder = ImageDecoder(maxConcurrentDecodes: 1)
        pipeline = FileImagePipeline(sources: self.registry, decoder: decoder, caches: caches,
                                     configuration: PipelineConfiguration(browseBounds: PixelSize(width: 640, height: 480)))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct PreviewReadState: Sendable {
    var started = 0
    var active = 0
    var delay: Duration = .zero
}
private final class PreviewRegistry: SourceRegistry, ContainerProvider, ByteSource {
    let identity: ContentIdentity
    let url: URL
    let bytes: Data
    let reads = Mutex(PreviewReadState())
    private let openCount = Mutex(0)
    var opens: Int { openCount.withLock { $0 } }
    init(network: Bool) throws {
        url = Fixtures.url("local/generated/video/h264.mp4")
        bytes = try Data(contentsOf: url)
        identity = ContentIdentity(location: Location(root: network ? .network(scheme: "nfs", host: "fixture", share: "readonly") : .local,
                                                       layers: [["video", "h264.mp4"]]), size: Int64(bytes.count), modificationNanos: 1)
    }
    func resetOpens() { openCount.withLock { $0 = 0 } }
    func provider(for location: Location) throws -> any ContainerProvider { self }
    func location(for fileURL: URL) async throws -> Location { identity.location }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { AsyncStream { $0.finish() } }
    func canHandle(_ location: Location) -> Bool { location == identity.location }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> { AsyncThrowingStream { $0.finish() } }
    func entry(at location: Location) async throws -> Entry { Entry(identity: identity, name: location.name, kind: .video) }
    func open(_ location: Location) async throws -> any ByteSource { openCount.withLock { $0 += 1 }; return self }
    func fileLease(for location: Location) async throws -> FileLease { FileLease(url: url) }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        let delay = reads.withLock { $0.started += 1; $0.active += 1; return $0.delay }
        defer { reads.withLock { $0.active -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return bytes.subdata(in: Int(range.lowerBound)..<min(bytes.count, Int(range.upperBound)))
    }
}
