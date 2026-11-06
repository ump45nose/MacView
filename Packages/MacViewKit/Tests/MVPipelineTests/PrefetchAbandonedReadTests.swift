import Foundation
@testable import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVTestSupport
import Synchronization
import Testing
@testable import MVPipeline

/// 冷填充缺页：书刚枚举完还没排序时，这一页排在锚点后面，有一条 `.near` 原始读取；排序后它不再是近邻，
/// 这条预取被取消。同一页 `.book` 缩略图预取在共享读取被放弃的间隙拿到它，加入时收到 CancellationError，
/// 预取吞掉错误照样归零，L2、L3 都没有写入。
@Test func bookPrefetchJoiningAbandonedReadStillWritesDerivatives() async throws {
    let root = Fixtures.root.deletingLastPathComponent().appendingPathComponent("build/stage4-repair/pipeline-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let base = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
    defer {
        base.scheduler.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    let registry = ProviderHoldRegistry(base: base)
    let index = try CacheIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
    let caches = PipelineCaches(raw: MemoryCache(budget: 64 << 20), decoded: MemoryCache(budget: 64 << 20),
                                thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: root, budget: 128 << 20, index: index),
                                browse: try DiskCache(tier: .browse, cacheDirectory: root, budget: 128 << 20, index: index),
                                metadata: MetadataIndex(index: index))
    let pipeline = FileImagePipeline(sources: registry, decoder: ImageDecoder(), caches: caches,
                                     configuration: PipelineConfiguration(thumbnailLongSide: 128, browseBounds: PixelSize(width: 320, height: 480)))
    let location = try await base.location(for: Fixtures.url("image/size/3600x5400.jpg"))
    let identity = try await base.provider(for: location).entry(at: location).identity
    let session = SessionID()

    registry.hold(location)
    pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [], priority: .near)]), session: session)
    try await waitForCondition { registry.isHolding }
    await Task(priority: .high) {
        pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.thumbnail, .metadata], priority: .book)]), session: session)
    }.value
    // `.book` 预取查完索引就会拿到还没撤下的同一份读取；这一步没有可观察的停点，留足时间让它排到取消之后。
    try await Task.sleep(for: .milliseconds(500))
    registry.release()
    try await waitForCondition { pipeline.prefetchInFlightCount(session: session) == 0 }
    #expect(try await caches.thumbnails.contains(identity.cacheKey), "预取已归零，L2 没有写入")
    #expect(try await caches.browse?.contains(identity.cacheKey) == true, "预取已归零，L3 没有写入")
    pipeline.cancelAll(session: session)
    await pipeline.shutdown()
}

private func waitForCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw AbandonedReadTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private enum AbandonedReadTestFailure: Error { case timedOut }

/// `ContentWork.run()` 在 actor 上同步取 provider。在这里停住共享读取，actor 上后到的作业排队等它。
private final class ProviderHoldRegistry: SourceRegistry {
    private struct State {
        var held: Location?
        var holding = false
    }
    let base: FileSourceRegistry
    private let state = Mutex(State())
    private let gate = DispatchSemaphore(value: 0)
    init(base: FileSourceRegistry) { self.base = base }
    var isHolding: Bool { state.withLock { $0.holding } }
    func hold(_ location: Location) { state.withLock { $0.held = location } }
    func release() { gate.signal() }
    func provider(for location: Location) throws -> any ContainerProvider {
        let hold = state.withLock { state -> Bool in
            guard state.held == location else { return false }
            state.held = nil
            state.holding = true
            return true
        }
        if hold { gate.wait() }
        return try base.provider(for: location)
    }
    func location(for fileURL: URL) async throws -> Location { try await base.location(for: fileURL) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
}
