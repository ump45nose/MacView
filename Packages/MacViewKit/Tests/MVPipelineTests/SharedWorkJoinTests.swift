import Foundation
@testable import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVTestSupport
import Synchronization
import Testing
@testable import MVPipeline

/// B 在登记表的锁内加入后，唯一在等的 A 取消：作业还有成员，不放弃，B 照样拿到结果。
@Test func sharedWorkJoinedMemberSurvivesLastWaiterCancel() async throws {
    let work = SharedWork<Int>(scheduler: nil, lifetime: PipelineLifetime())
    let gate = TestGate()
    let operation: @Sendable (SharedWork<Int>) async throws -> Int = { _ in
        try await gate.pass()
        return 7
    }
    let a = UUID(), b = UUID()
    #expect(work.join(consumer: a, priority: .near))
    let first = Task { try await work.value(consumer: a, priority: .near, operation: operation) }
    try await pollUntil { gate.entered }
    #expect(work.join(consumer: b, priority: .book))
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    let second = Task { try await work.value(consumer: b, priority: .book, operation: operation) }
    gate.open()
    #expect(try await second.value == 7)
    #expect(!gate.cancelled)
}

@Test func sharedWorkCancelsOperationWhenAllMembersCancel() async throws {
    let work = SharedWork<Int>(scheduler: nil, lifetime: PipelineLifetime())
    let gate = TestGate()
    let operation: @Sendable (SharedWork<Int>) async throws -> Int = { _ in
        try await gate.pass()
        return 7
    }
    let a = UUID(), b = UUID()
    #expect(work.join(consumer: a, priority: .near))
    #expect(work.join(consumer: b, priority: .book))
    let first = Task { try await work.value(consumer: a, priority: .near, operation: operation) }
    let second = Task { try await work.value(consumer: b, priority: .book, operation: operation) }
    try await pollUntil { gate.entered }
    first.cancel()
    second.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    try await pollUntil { gate.cancelled }
    #expect(!work.join(consumer: UUID(), priority: .near), "放弃后的作业不再接受成员")
}

/// 同上，换成原始读取：唯一在等的 A 取消时 B 已经是成员，读取不放弃，B 拿到完整文件。
@Test func contentWorkJoinedMemberSurvivesLastWaiterCancel() async throws {
    let fixture = try await ContentWorkFixture()
    defer { fixture.close() }
    let work = fixture.makeWork()
    let a = UUID(), b = UUID()
    #expect(work.join(consumer: a))
    let first = Task { try await work.value(full: true, metadata: false, consumer: a, priority: .near) }
    try await pollUntil { fixture.gate.entered }
    #expect(work.join(consumer: b))
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    let second = Task { try await work.value(full: true, metadata: false, consumer: b, priority: .book) }
    fixture.gate.open()
    let content = try await second.value
    #expect(Int64(content.data.count) == fixture.identity.size)
    #expect(!fixture.gate.cancelled)
}

@Test func contentWorkCancelsReadWhenAllMembersCancel() async throws {
    let fixture = try await ContentWorkFixture()
    defer { fixture.close() }
    let work = fixture.makeWork()
    let a = UUID(), b = UUID()
    #expect(work.join(consumer: a))
    #expect(work.join(consumer: b))
    let first = Task { try await work.value(full: true, metadata: false, consumer: a, priority: .near) }
    let second = Task { try await work.value(full: true, metadata: false, consumer: b, priority: .book) }
    try await pollUntil { fixture.gate.entered }
    first.cancel()
    second.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    try await pollUntil { fixture.gate.cancelled }
    #expect(fixture.completedCount >= 1, "放弃时从登记表撤下")
    #expect(!work.join(consumer: UUID()), "放弃后的作业不再接受成员")
}

private func pollUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SharedWorkJoinTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private enum SharedWorkJoinTestFailure: Error { case timedOut }

/// 停住操作或读取，直到 `open`；记录有没有被取消。
private final class TestGate: Sendable {
    private struct State {
        var entered = false
        var opened = false
        var cancelled = false
    }
    private let state = Mutex(State())
    var entered: Bool { state.withLock { $0.entered } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func open() { state.withLock { $0.opened = true } }

    func pass() async throws {
        state.withLock { $0.entered = true }
        do {
            while !state.withLock({ $0.opened }) { try await Task.sleep(for: .milliseconds(2)) }
        } catch {
            state.withLock { $0.cancelled = true }
            throw error
        }
    }
}

private final class ContentWorkFixture: Sendable {
    let root: URL
    let base: FileSourceRegistry
    let registry: GatedRegistry
    let caches: PipelineCaches
    let identity: ContentIdentity
    let lifetime = PipelineLifetime()
    private let completed = Mutex(0)
    var gate: TestGate { registry.gate }
    var completedCount: Int { completed.withLock { $0 } }

    init() async throws {
        root = Fixtures.root.deletingLastPathComponent().appendingPathComponent("build/stage4-repair/pipeline-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        base = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        registry = GatedRegistry(base: base)
        let index = try CacheIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        caches = PipelineCaches(raw: MemoryCache(budget: 64 << 20), decoded: MemoryCache(budget: 64 << 20),
                                thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: root, budget: 16 << 20, index: index),
                                browse: nil, metadata: MetadataIndex(index: index))
        let location = try await base.location(for: Fixtures.url("image/size/3600x5400.jpg"))
        identity = try await base.provider(for: location).entry(at: location).identity
    }

    func makeWork() -> ContentWork {
        ContentWork(identity: identity, sources: registry, caches: caches, lifetime: lifetime) { [self] in
            completed.withLock { $0 += 1 }
        }
    }

    func close() {
        lifetime.stop()
        base.scheduler.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

/// 每次读取都先过闸门。
private final class GatedRegistry: SourceRegistry {
    let base: FileSourceRegistry
    let gate = TestGate()
    init(base: FileSourceRegistry) { self.base = base }
    func provider(for location: Location) throws -> any ContainerProvider { GatedProvider(base: try base.provider(for: location), gate: gate) }
    func location(for fileURL: URL) async throws -> Location { try await base.location(for: fileURL) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
}

private struct GatedProvider: ContainerProvider {
    let base: any ContainerProvider
    let gate: TestGate
    func canHandle(_ location: Location) -> Bool { base.canHandle(location) }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> { base.children(of: container, priority: priority) }
    func entry(at location: Location) async throws -> Entry { try await base.entry(at: location) }
    func open(_ location: Location) async throws -> any ByteSource { GatedSource(base: try await base.open(location), gate: gate) }
    func fileLease(for location: Location) async throws -> FileLease { try await base.fileLease(for: location) }
}

private struct GatedSource: ByteSource {
    let base: any ByteSource
    let gate: TestGate
    var identity: ContentIdentity { base.identity }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        try await gate.pass()
        return try await base.read(range, priority: priority, group: group)
    }
}
