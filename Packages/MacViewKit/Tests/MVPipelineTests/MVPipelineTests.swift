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

@Test func concurrentRenditionsShareTheReadAndSourceDecode() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let thumbnail = Task { try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .book) }
    try await eventually { environment.registry.control.reads.count == 1 }
    let metadata = Task { try await environment.pipeline.metadata(for: identity, priority: .visible) }
    let display = Task { try await collect(environment.pipeline.image(for: identity, target: DisplayTarget(pixelSize: PixelSize(width: 800, height: 1200)), allowOriginal: false, priority: .visible)) }
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.browse], priority: .near)]), session: SessionID())
    try await Task.sleep(for: .milliseconds(20))
    await gate.release()
    let image = try await thumbnail.value
    #expect(image.image.height == 128)
    #expect(try await metadata.value.pixelSize == PixelSize(width: 3600, height: 5400))
    let images = try await display.value
    #expect(images.last?.image.width == 800)
    #expect(images.last?.image.height == 1200)
    #expect(environment.registry.control.opens == 1)
    #expect(environment.pipeline.sourceDecodeCount == 1)
    let ranges = environment.registry.control.reads.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
    #expect(ranges.first?.lowerBound == 0)
    #expect(ranges.last?.upperBound == identity.size)
    for pair in zip(ranges, ranges.dropFirst()) { #expect(pair.0.upperBound == pair.1.lowerBound) }
}

@Test func metadataOnlyReadsAHeaderAndThenUsesTheIndex() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let first = try await environment.pipeline.metadata(for: identity, priority: .book)
    #expect(first.pixelSize == PixelSize(width: 3600, height: 5400))
    #expect(environment.registry.control.reads.map { $0.range.count }.reduce(0, +) == min(Int(identity.size), MediaProbe.initialHeaderLength))
    let count = environment.registry.control.reads.count
    #expect(try await environment.pipeline.metadata(for: identity, priority: .visible) == first)
    #expect(environment.registry.control.reads.count == count)
    #expect(environment.pipeline.sourceDecodeCount == 0)
}

@Test func actualSourceIdentityOwnsAllCacheEntries() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let actual = try await environment.identity("image/size/3600x5400.jpg")
    var stale = actual
    stale.size = 1
    stale.modificationNanos -= 1
    _ = try await environment.pipeline.thumbnail(for: stale, maxPixel: 128, priority: .visible)
    #expect(environment.caches.raw.value(for: stale.cacheKey) == nil)
    #expect(environment.caches.raw.value(for: actual.cacheKey)?.count == Int(actual.size))
    #expect(try await environment.caches.thumbnails.data(for: stale.cacheKey) == nil)
    #expect(try await environment.caches.thumbnails.data(for: actual.cacheKey) != nil)
    #expect(try await environment.caches.browse?.data(for: stale.cacheKey) == nil)
    #expect(try await environment.caches.browse?.data(for: actual.cacheKey) != nil)
    let values = try await environment.caches.metadata.values(in: actual.location.parent!)
    #expect(values[stale.cacheKey] == nil)
    #expect(values[actual.cacheKey]?.pixelSize == PixelSize(width: 3600, height: 5400))
    #expect(environment.caches.decoded.value(for: stale.cacheKey + "|thumb|128") == nil)
    #expect(environment.caches.decoded.value(for: actual.cacheKey + "|thumb|128") != nil)
}

@Test func progressiveDeliveryUsesAllThreeStagesAndSkipsLowerCachedQuality() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let source = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
    let low = try await ImageDecoder().image(source, target: DisplayTarget(pixelSize: PixelSize(width: 32, height: 48)))
    try await environment.caches.thumbnails.store(RenditionEncoding.default.encode(low.image), for: identity.cacheKey)
    let target = DisplayTarget(pixelSize: PixelSize(width: 800, height: 1200))
    let first = try await collect(environment.pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible))
    #expect(first.map(\.quality) == [.placeholder, .browse, .exact])
    #expect(first.allSatisfy { $0.image.width == 800 && $0.image.height == 1200 })
    let repeatImages = try await collect(environment.pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible))
    #expect(repeatImages.map(\.quality) == [.exact])
    let secondTarget = DisplayTarget(pixelSize: PixelSize(width: 900, height: 1350), filter: .nearest)
    let second = try await collect(environment.pipeline.image(for: identity, target: secondTarget, allowOriginal: false, priority: .visible))
    #expect(second.first?.quality == .browse)
    #expect(second.last?.quality == .exact)
    #expect(!second.contains { $0.quality == .placeholder })
}

@Test func sufficientDiskRenditionDeliversExactWithoutOpeningTheSource() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    _ = try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .visible)
    environment.caches.raw.setBudget(0)
    environment.caches.decoded.setBudget(0)
    environment.registry.control.reset()
    let result = try await collect(environment.pipeline.image(for: identity, target: DisplayTarget(pixelSize: PixelSize(width: 40, height: 60)), allowOriginal: false, priority: .visible))
    #expect(result.map(\.quality) == [.exact])
    #expect(result.last?.image.width == 40)
    #expect(environment.registry.control.opens == 0)
}

@Test func cancellingOneSubscriberKeepsAnotherAlive() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let cancelled = Task { try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .book) }
    try await eventually { environment.registry.control.reads.count == 1 }
    let survivor = Task { try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .visible) }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("已取消的消费者不应交付") }
    catch is CancellationError {}
    await gate.release()
    #expect(try await survivor.value.image.height == 128)
    #expect(environment.registry.control.opens == 1)
}

@Test func batchFailureDoesNotInterruptOtherItems() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/64x64.png")
    let missing = ContentIdentity(location: identity.location.parent!.appending("missing.jpg"), size: 10, modificationNanos: 1)
    var successes: [ContentIdentity] = []
    var failures: [ContentIdentity] = []
    for await (identity, result) in environment.pipeline.thumbnails(for: [missing, identity], maxPixel: 32, priority: .visible) {
        switch result {
        case .success: successes.append(identity)
        case let .failure(error):
            failures.append(identity)
            #expect(error as? IOError == .notFound(missing.location))
        }
    }
    #expect(successes == [identity])
    #expect(failures == [missing])
}

@Test func replacingPrefetchAddsRemovesAndChangesPriority() async throws {
    let environment = try PipelineEnvironment(browse: false)
    defer { environment.clean() }
    let identity = try await environment.largeIdentity()
    let other = try await environment.identity("image/size/64x64.png")
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let session = SessionID()
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [], priority: .background)]), session: session)
    try await eventually { environment.registry.control.reads.count == 1 }
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [], priority: .visible), PrefetchItem(identity: other, renditions: [.metadata], priority: .book)]), session: session)
    try await Task.sleep(for: .milliseconds(20))
    await gate.release()
    try await eventually { environment.caches.raw.value(for: identity.cacheKey)?.count == Int(identity.size) }
    #expect(environment.registry.control.reads.first?.priority == .background)
    #expect(environment.registry.control.reads.contains { $0.range.lowerBound > 0 && $0.priority == .visible })
    try await eventually { environment.registry.control.opens == 2 }
    environment.pipeline.setPrefetchPlan(PrefetchPlan(), session: session)
    #expect(environment.pipeline.sourceDecodeCount == 0)
    #expect(try await environment.caches.thumbnails.data(for: identity.cacheKey) == nil)
}

@Test func cancellingAPrefetchSessionDoesNotCancelOtherSessionsOrForeground() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let first = SessionID(), second = SessionID()
    let plan = PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.thumbnail], priority: .book)])
    environment.pipeline.setPrefetchPlan(plan, session: first)
    try await eventually { environment.registry.control.reads.count == 1 }
    environment.pipeline.setPrefetchPlan(plan, session: second)
    let foreground = Task { try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .visible) }
    try await Task.sleep(for: .milliseconds(20))
    environment.pipeline.cancelAll(session: first)
    await gate.release()
    #expect(try await foreground.value.image.height == 128)
    try await eventually { environment.caches.raw.value(for: identity.cacheKey)?.count == Int(identity.size) }
    #expect(environment.registry.control.opens == 1)
    environment.pipeline.cancelAll(session: second)
}

@Test func memoryPressureCancelsOnlyBackgroundPrefetchAcrossSessions() async throws {
    let environment = try PipelineEnvironment(browse: false)
    defer { environment.clean() }
    let background = try await environment.largeIdentity()
    let sharedURL = environment.root.appending(path: "shared.jpg")
    try FileManager.default.copyItem(at: environment.root.appending(path: "large.jpg"), to: sharedURL)
    let sharedLocation = try await environment.registry.location(for: sharedURL)
    let shared = try await environment.registry.provider(for: sharedLocation).entry(at: sharedLocation).identity
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let first = SessionID(), second = SessionID()
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [
        PrefetchItem(identity: background, renditions: [], priority: .background),
        PrefetchItem(identity: shared, renditions: [], priority: .background),
    ]), session: first)
    try await eventually { environment.registry.control.reads.count == 2 }
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: shared, renditions: [], priority: .near)]), session: second)
    let foreground = Task { try await environment.pipeline.metadata(for: shared, priority: .visible) }
    try await Task.sleep(for: .milliseconds(20))
    environment.pipeline.cancelBackgroundPrefetch()
    try await Task.sleep(for: .milliseconds(20))
    await gate.release()
    #expect(try await foreground.value.pixelSize == PixelSize(width: 3600, height: 5400))
    try await eventually { environment.caches.raw.value(for: shared.cacheKey)?.count == Int(shared.size) }
    #expect(environment.caches.raw.value(for: background.cacheKey) == nil)
    // 被移除的项可由后续新计划重新加入；原来的 near 消费者仍完整交付。
    environment.registry.control.gate = nil
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: background, renditions: [], priority: .book)]), session: first)
    try await eventually { environment.caches.raw.value(for: background.cacheKey)?.count == Int(background.size) }
    environment.pipeline.cancelAll(session: first)
    environment.pipeline.cancelAll(session: second)
}

@Test func rawAndRenditionPrefetchForTheSameIdentityBothTakeEffect() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    _ = try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .visible)
    environment.caches.raw.setBudget(0)
    environment.caches.raw.setBudget(64 << 20)
    environment.registry.control.reset()
    let session = SessionID()
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.thumbnail, .metadata], priority: .book), PrefetchItem(identity: identity, renditions: [], priority: .near)]), session: session)
    try await eventually { environment.caches.raw.value(for: identity.cacheKey)?.count == Int(identity.size) }
    #expect(environment.registry.control.opens == 1)
    environment.pipeline.cancelAll(session: session)
}

@Test func cancellationKeepsTheReadPrefixAndTheNextRequestResumesIt() async throws {
    let environment = try PipelineEnvironment(browse: false)
    defer { environment.clean() }
    let identity = try await environment.largeIdentity()
    let gate = ReadGate(blockFrom: 2)
    environment.registry.control.gate = gate
    let session = SessionID()
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [], priority: .background)]), session: session)
    try await eventuallyForCancellationResume("等待第二次读取") { environment.registry.control.reads.count == 2 }
    environment.pipeline.cancelAll(session: session)
    try await eventuallyForCancellationResume("等待取消后保留前缀") {
        environment.caches.raw.value(for: identity.cacheKey)?.count == 4 << 20
    }
    let retained = try #require(environment.caches.raw.value(for: identity.cacheKey))
    #expect(retained.count == 4 << 20)
    let returnedBefore = environment.registry.control.returnedReads.count
    await gate.release()
    // 被挡住的读取返回后才插入缓存；成功时等到这次范围的上界，取消时当时的缓存就是前缀。
    try await eventuallyForCancellationResume("等待被挡住的读取结束") {
        environment.registry.control.returnedReads.count > returnedBefore
    }
    let returned = environment.registry.control.returnedReads[returnedBefore]
    if returned.succeeded {
        let upperBound = Int(returned.range.upperBound)
        do {
            try await eventuallyForCancellationResume("等待放行读取写入缓存") {
                (environment.caches.raw.value(for: identity.cacheKey)?.count ?? 0) >= upperBound
            }
        } catch let CancellationResumeTestFailure.timedOut(message) {
            let count = environment.caches.raw.value(for: identity.cacheKey)?.count ?? -1
            let reads = environment.registry.control.reads.map { "\($0.range.lowerBound)..<\($0.range.upperBound)" }.joined(separator: ",")
            throw CancellationResumeTestFailure.timedOut("\(message)；缓存长度 \(count)，读取 \(reads)")
        }
    }
    let prefix = try #require(environment.caches.raw.value(for: identity.cacheKey))
    environment.registry.control.gate = nil
    let previous = environment.registry.control.reads.count
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [], priority: .near)]), session: session)
    try await eventuallyForCancellationResume("等待续读开始") {
        environment.registry.control.reads.count > previous
    }
    let resume = try #require(environment.registry.control.reads.dropFirst(previous).first).range.lowerBound
    // 更大是跳过保留字节，更小是重读保留字节。
    #expect(resume == Int64(prefix.count))
    try await eventuallyForCancellationResume("等待原始缓存完整") { environment.caches.raw.value(for: identity.cacheKey)?.count == Int(identity.size) }
    let cached = try #require(environment.caches.raw.value(for: identity.cacheKey))
    let source = try Data(contentsOf: environment.root.appendingPathComponent("large.jpg"))
    #expect(cached == source)
    environment.pipeline.cancelAll(session: session)
}

@Test func tilesAnimationAndLocalVideoUseExistingMediaImplementations() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let image = try await environment.identity("image/size/64x64.png")
    let tiles = try await environment.pipeline.tiledSource(for: image)
    #expect(tiles.pixelSize == PixelSize(width: 64, height: 64))
    let animation = try await environment.identity("animated/loop.gif")
    let frames = try await environment.pipeline.animatedFrames(for: animation, target: DisplayTarget(pixelSize: PixelSize(width: 16, height: 16)))
    #expect(frames.frameCount > 1)
    #expect(try await frames.frame(at: 0).image.width == 16)
    let fixture = try #require(Fixtures.manifest().fixtures.first { $0.video != nil })
    let video = try await environment.identity(fixture.path)
    let metadata = try await environment.pipeline.metadata(for: video, priority: .book)
    #expect(metadata.pixelSize == fixture.video?.pixelSize)
    let poster = try await environment.pipeline.videoPoster(for: video, maxPixel: 64)
    #expect(max(poster.image.width, poster.image.height) <= 64)
    #expect(environment.registry.control.fileURLs > 0)
}

@Test func differentFiltersAndSharpeningProduceDistinctL1Entries() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let size = PixelSize(width: 80, height: 120)
    for target in [DisplayTarget(pixelSize: size), DisplayTarget(pixelSize: size, filter: .nearest), DisplayTarget(pixelSize: size, sharpen: 0.5), DisplayTarget(pixelSize: PixelSize(width: 960, height: 1440))] {
        let images = try await collect(environment.pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible))
        #expect(images.last?.quality == .exact)
        let key = identity.cacheKey + "|display|\(target.pixelSize.width)x\(target.pixelSize.height)|\(target.filter.rawValue)|\(target.sharpen.bitPattern)"
        #expect(environment.caches.decoded.value(for: key) != nil)
    }
}

@Test func shutdownRejectsCachedRequestsAndManagedMediaSources() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/64x64.png")
    let animation = try await environment.identity("animated/loop.gif")
    let videoFixture = try #require(Fixtures.manifest().fixtures.first { $0.video != nil })
    let video = try await environment.identity(videoFixture.path)
    let target = DisplayTarget(pixelSize: PixelSize(width: 16, height: 16))
    _ = try await environment.pipeline.thumbnail(for: identity, maxPixel: 16, priority: .visible)
    _ = try await collect(environment.pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible))
    let tiles = try await environment.pipeline.tiledSource(for: identity)
    let frames = try await environment.pipeline.animatedFrames(for: animation, target: target)
    await environment.pipeline.shutdown()
    await environment.pipeline.shutdown()
    environment.registry.control.reset()
    await #expect(throws: CancellationError.self) { try await environment.pipeline.metadata(for: identity, priority: .visible) }
    await #expect(throws: CancellationError.self) { try await environment.pipeline.thumbnail(for: identity, maxPixel: 16, priority: .visible) }
    await #expect(throws: CancellationError.self) { try await collect(environment.pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible)) }
    await #expect(throws: CancellationError.self) { try await environment.pipeline.tiledSource(for: identity) }
    await #expect(throws: CancellationError.self) { try await environment.pipeline.animatedFrames(for: animation, target: target) }
    await #expect(throws: CancellationError.self) { try await environment.pipeline.videoPoster(for: video, maxPixel: 16) }
    await #expect(throws: CancellationError.self) { try await tiles.tile(CGRect(x: 0, y: 0, width: 16, height: 16), scale: 1) }
    await #expect(throws: CancellationError.self) { try await frames.frame(at: 0) }
    var failures = 0
    for await (_, result) in environment.pipeline.thumbnails(for: [identity, animation], maxPixel: 16, priority: .visible) {
        #expect(throws: CancellationError.self) { try result.get() }
        failures += 1
    }
    #expect(failures == 2)
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.thumbnail, .metadata, .browse], priority: .background)]), session: SessionID())
    #expect(environment.registry.control.opens == 0)
    #expect(environment.registry.control.reads.isEmpty)
}

@Test func shutdownWaitsForCancelledConsumersActualReadToEnd() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let gate = ReadGate()
    environment.registry.control.gate = gate
    let consumer = Task { try await environment.pipeline.thumbnail(for: identity, maxPixel: 128, priority: .visible) }
    try await eventually { environment.registry.control.reads.count == 1 }
    consumer.cancel()
    await #expect(throws: CancellationError.self) { try await consumer.value }
    let finished = Atomic(false)
    let shutdown = Task { await environment.pipeline.shutdown(); finished.store(true, ordering: .relaxed) }
    try await Task.sleep(for: .milliseconds(30))
    let shutdownFinished = finished.load(ordering: .relaxed)
    #expect(!shutdownFinished)
    await gate.release()
    await shutdown.value
    #expect(try await environment.caches.thumbnails.data(for: identity.cacheKey) == nil)
    #expect(try await environment.caches.browse?.data(for: identity.cacheKey) == nil)
    #expect(environment.pipeline.sourceDecodeCount == 0)
}

@Test func shutdownDrainsIndependentDerivativesAndQueuedDiskWrites() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let identity = try await environment.identity("image/size/3600x5400.jpg")
    let gate = DispatchSemaphore(value: 0), blocked = Atomic(false), finished = Atomic(false)
    let disk = Task {
        try await environment.index.diskOperations.perform { blocked.store(true, ordering: .relaxed); gate.wait() }
    }
    defer { gate.signal() }
    try await eventually { blocked.load(ordering: .relaxed) }
    // 取到精确图即离开消费者，衍生件仍独立持有自己的排队写入。
    let display = Task {
        for try await image in environment.pipeline.image(for: identity, target: DisplayTarget(pixelSize: PixelSize(width: 320, height: 480)), allowOriginal: false, priority: .visible) {
            if image.quality == .exact { return }
        }
        Issue.record("应先交付精确尺寸图")
    }
    try await display.value
    try await eventually { environment.index.diskOperations.pendingCount > 1 }
    let shutdown = Task { await environment.pipeline.shutdown(); finished.store(true, ordering: .relaxed) }
    try await Task.sleep(for: .milliseconds(30))
    let shutdownFinished = finished.load(ordering: .relaxed)
    #expect(!shutdownFinished)
    gate.signal()
    try await disk.value
    await shutdown.value
    let before = try cacheTree(environment.root)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try cacheTree(environment.root) == before)
}

private func cacheTree(_ root: URL) throws -> Set<String> {
    var paths: Set<String> = []
    for tier in ["thumbnails", "browse"] {
        let directory = root.appending(path: tier)
        let iterator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        for case let url as URL in iterator { paths.insert(url.path) }
    }
    return paths
}

private func collect(_ stream: AsyncThrowingStream<RenderedImage, any Error>) async throws -> [RenderedImage] {
    var result: [RenderedImage] = []
    for try await image in stream { result.append(image) }
    return result
}

@Test(.serialized, arguments: [IOPriority.adjacent, .background])
func foregroundThumbnailJoiningPrefetchPromotesDecodeAheadOfQueue(_ priority: IOPriority) async throws {
    let decoder = ImageDecoder(maxConcurrentDecodes: 1)
    let environment = try PipelineEnvironment(decoder: decoder)
    defer { environment.clean() }
    // 先占住唯一的解码槽，让所有预取确定地排队，不靠大图负载和机器速度制造积压。
    let decodeGate = DispatchSemaphore(value: 0), markerGate = DispatchSemaphore(value: 0)
    defer { decodeGate.signal(); markerGate.signal() }
    let blocker = Task { try await decoder.perform { decodeGate.wait() } }
    try await eventually { decoder.limiter.runningCount == 1 }
    let readGate = ReadGate()
    defer { Task { await readGate.release() } }
    environment.registry.control.gate = readGate
    var identities: [ContentIdentity] = []
    for index in 0..<8 { identities.append(try await environment.copyIdentity("image/size/64x64.png", index: index)) }
    let session = SessionID()
    defer { environment.pipeline.cancelAll(session: session) }
    environment.pipeline.setPrefetchPlan(PrefetchPlan(items: identities.map { PrefetchItem(identity: $0, renditions: [.thumbnail], priority: priority) }), session: session)
    try await eventually { environment.registry.control.reads.count == identities.count }
    let joining = identities[0]
    let foregroundFinished = Atomic(false)
    let foreground = Task {
        defer { foregroundFinished.store(true, ordering: .relaxed) }
        return try await environment.pipeline.thumbnail(for: joining, maxPixel: 32, priority: .visible)
    }
    defer { foreground.cancel() }
    // 读取仍停在门闩上时观察到提升，才能确定前台加入了同一份预取工作。
    try await eventually { environment.registry.control.escalatedReads.contains(joining) }
    await readGate.release()
    try await eventually { decoder.limiter.waitingCount == identities.count }
    let markerStarted = Atomic(false)
    let marker = Task(priority: .medium) {
        try await decoder.perform {
            markerStarted.store(true, ordering: .relaxed)
            markerGate.wait()
        }
    }
    try await eventually { decoder.limiter.waitingCount == identities.count + 1 }
    decodeGate.signal()
    try await eventually { markerStarted.load(ordering: .relaxed) }
    // 中优先级标记会挡住其余低优先级解码；只有被前台提升的那张能先进入 L1。
    let baseSuffix = "|display|64x64|\(ResampleFilter.lanczos.rawValue)|\(Float(0).bitPattern)"
    try await eventually { environment.caches.decoded.value(for: joining.cacheKey + baseSuffix) != nil }
    #expect(identities.dropFirst().allSatisfy { environment.caches.decoded.value(for: $0.cacheKey + baseSuffix) == nil })
    markerGate.signal()
    // 实际交付也有五秒上限；超时直接失败并由 defer 取消前台任务。
    let deadline = ContinuousClock.now + .seconds(5)
    while !foregroundFinished.load(ordering: .relaxed), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let finished = foregroundFinished.load(ordering: .relaxed)
    try #require(finished, "前台缩略图未在五秒内完成交付")
    #expect(try await foreground.value.image.height == 32)
    #expect(environment.registry.control.opens == identities.count)
    try await blocker.value
    try await marker.value
    await environment.pipeline.shutdown()
}

private func eventually(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw PipelineTestFailure.timedOut
}

private func eventuallyForCancellationResume(
    _ description: String,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ predicate: () async throws -> Bool
) async throws {
    for _ in 0..<6_000 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationResumeTestFailure.timedOut("\(description)（\(fileID):\(line)）")
}

private enum PipelineTestFailure: Error { case timedOut }
private enum CancellationResumeTestFailure: Error { case timedOut(String) }

/// 真实文件来源的计数外壳；不替换文件解析、调度或解码。
private final class PipelineEnvironment: Sendable {
    let root: URL
    let registry: CountingRegistry
    let caches: PipelineCaches
    let index: CacheIndex
    let pipeline: FileImagePipeline
    init(browse: Bool = true, thumbnailLongSide: Int = 128, browseBounds: PixelSize = PixelSize(width: 320, height: 480), decoder: ImageDecoder = ImageDecoder()) throws {
        root = Fixtures.root.deletingLastPathComponent().appendingPathComponent("build/stage4-repair/pipeline-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        registry = CountingRegistry(base: FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil))))
        index = try CacheIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        let thumbnails = try DiskCache(tier: .thumbnails, cacheDirectory: root, budget: 128 << 20, index: index)
        let browseCache = try browse ? DiskCache(tier: .browse, cacheDirectory: root, budget: 128 << 20, index: index) : nil
        caches = PipelineCaches(raw: MemoryCache(budget: 64 << 20), decoded: MemoryCache(budget: 64 << 20), thumbnails: thumbnails, browse: browseCache, metadata: MetadataIndex(index: index))
        pipeline = FileImagePipeline(sources: registry, decoder: decoder, caches: caches, configuration: PipelineConfiguration(thumbnailLongSide: thumbnailLongSide, browseBounds: browseBounds))
    }
    func identity(_ path: String) async throws -> ContentIdentity {
        let location = try await registry.location(for: Fixtures.url(path))
        return try await registry.base.provider(for: location).entry(at: location).identity
    }
    func copyIdentity(_ path: String, index: Int) async throws -> ContentIdentity {
        let url = root.appendingPathComponent("copy-\(index)." + (path as NSString).pathExtension)
        try FileManager.default.copyItem(at: Fixtures.url(path), to: url)
        let location = try await registry.location(for: url)
        return try await registry.base.provider(for: location).entry(at: location).identity
    }
    func largeIdentity() async throws -> ContentIdentity {
        let url = root.appendingPathComponent("large.jpg")
        var data = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
        data.append(Data(count: 9 << 20))
        try data.write(to: url)
        let location = try await registry.location(for: url)
        return try await registry.base.provider(for: location).entry(at: location).identity
    }
    func clean() {
        registry.base.scheduler.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ReadGate {
    private var released = false
    private var count = 0
    private let blockFrom: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(blockFrom: Int = 1) { self.blockFrom = blockFrom }
    func wait() async {
        count += 1
        guard !released, count >= blockFrom else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class ReadControl: Sendable {
    struct Read: Sendable { var range: Range<Int64>; var priority: IOPriority }
    struct ReturnedRead: Sendable { var range: Range<Int64>; var succeeded: Bool }
    struct State: Sendable {
        var opens = 0
        var reads: [Read] = []
        var gate: ReadGate?
        var fileURLs = 0
        var returnedReads: [ReturnedRead] = []
        var escalatedReads: Set<ContentIdentity> = []
    }
    private let state = Mutex(State())
    var opens: Int { state.withLock { $0.opens } }
    var reads: [Read] { state.withLock { $0.reads } }
    var fileURLs: Int { state.withLock { $0.fileURLs } }
    var returnedReads: [ReturnedRead] { state.withLock { $0.returnedReads } }
    var escalatedReads: Set<ContentIdentity> { state.withLock { $0.escalatedReads } }
    var gate: ReadGate? {
        get { state.withLock { $0.gate } }
        set { state.withLock { $0.gate = newValue } }
    }
    func opened() { state.withLock { $0.opens += 1 } }
    func fileURL() { state.withLock { $0.fileURLs += 1 } }
    func read(_ range: Range<Int64>, priority: IOPriority) { state.withLock { $0.reads.append(Read(range: range, priority: priority)) } }
    func didReturn(_ range: Range<Int64>, succeeded: Bool) {
        state.withLock { $0.returnedReads.append(ReturnedRead(range: range, succeeded: succeeded)) }
    }
    func escalated(_ identity: ContentIdentity) { state.withLock { _ = $0.escalatedReads.insert(identity) } }
    func reset() { state.withLock { $0.opens = 0; $0.reads.removeAll(); $0.fileURLs = 0; $0.returnedReads.removeAll(); $0.escalatedReads.removeAll() } }
}

private final class CountingRegistry: SourceRegistry {
    let base: FileSourceRegistry
    let control = ReadControl()
    init(base: FileSourceRegistry) { self.base = base }
    func provider(for location: Location) throws -> any ContainerProvider { CountingProvider(base: try base.provider(for: location), control: control) }
    func location(for fileURL: URL) async throws -> Location { try await base.location(for: fileURL) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
}

private struct CountingProvider: ContainerProvider {
    var base: any ContainerProvider
    var control: ReadControl
    func canHandle(_ location: Location) -> Bool { base.canHandle(location) }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> { base.children(of: container, priority: priority) }
    func entry(at location: Location) async throws -> Entry { try await base.entry(at: location) }
    func open(_ location: Location) async throws -> any ByteSource {
        let source = try await base.open(location)
        control.opened()
        return CountingSource(base: source, control: control)
    }
    func fileLease(for location: Location) async throws -> FileLease {
        control.fileURL()
        return try await base.fileLease(for: location)
    }
}

private struct CountingSource: ByteSource {
    var base: any ByteSource
    var control: ReadControl
    var identity: ContentIdentity { base.identity }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        try await withTaskPriorityEscalationHandler {
            control.read(range, priority: priority)
            await control.gate?.wait()
            do {
                try Task.checkCancellation()
                let data = try await base.read(range, priority: priority, group: group)
                // 子任务已被取消时，调用方会在插入缓存前丢弃结果。
                control.didReturn(range, succeeded: !Task.isCancelled)
                return data
            } catch {
                control.didReturn(range, succeeded: false)
                throw error
            }
        } onPriorityEscalated: { _, priority in
            if priority >= .userInitiated { control.escalated(identity) }
        }
    }
}

@Test func networkVideoUsesByteSourceBridgeAndArchivedVideoUsesFileURL() async throws {
    let environment = try PipelineEnvironment()
    defer { environment.clean() }
    let fixture = try #require(Fixtures.manifest().fixtures.first { $0.video != nil })
    let local = try await environment.identity(fixture.path)
    for archived in [false, true] {
        var mirrored = local
        mirrored.location.root = .network(scheme: "nfs", host: "fixture", share: "readonly")
        if archived { mirrored.location.layers.insert(["fixture.zip"], at: 0) }
        let registry = MirroredVideoSource(base: environment.registry, local: local.location, mirrored: mirrored)
        let pipe = FileImagePipeline(sources: registry, decoder: ImageDecoder(), caches: environment.caches, configuration: PipelineConfiguration(browseBounds: PixelSize(width: 320, height: 480)))
        environment.registry.control.reset()
        let value = try await pipe.metadata(for: mirrored, priority: .book)
        #expect(value.pixelSize == fixture.video?.pixelSize)
        if archived { #expect(environment.registry.control.fileURLs == 1) }
        else {
            #expect(environment.registry.control.fileURLs == 0)
            #expect(!environment.registry.control.reads.isEmpty)
        }
    }
}

/// 以真实本地视频模拟两种根路由，只改变身份；文件字节仍由 FileSystemProvider 读取。
private struct MirroredVideoSource: SourceRegistry, ContainerProvider {
    var base: CountingRegistry
    var local: Location
    var mirrored: ContentIdentity
    func provider(for location: Location) throws -> any ContainerProvider { self }
    func location(for fileURL: URL) async throws -> Location { mirrored.location }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
    func canHandle(_ location: Location) -> Bool { location == mirrored.location }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { $0.finish(throwing: IOError.unsupported(container)) }
    }
    func entry(at location: Location) async throws -> Entry { Entry(identity: mirrored, name: mirrored.location.name, kind: .video) }
    func open(_ location: Location) async throws -> any ByteSource {
        MirroredBytes(base: try await base.provider(for: local).open(local), identity: mirrored)
    }
    func fileLease(for location: Location) async throws -> FileLease { try await base.provider(for: local).fileLease(for: local) }
}
private struct MirroredBytes: ByteSource {
    var base: any ByteSource
    var identity: ContentIdentity
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        try await base.read(range, priority: priority, group: group)
    }
}
