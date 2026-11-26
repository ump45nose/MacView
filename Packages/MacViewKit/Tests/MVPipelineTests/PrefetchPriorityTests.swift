import Foundation
import MVCache
import MVFoundation
@testable import MVIO
import MVMedia
import MVTestSupport
import Synchronization
import Testing
@testable import MVPipeline

@Test func bookPrefetchOpenDoesNotJumpAheadOfNearRequest() async throws {
    let directory = Fixtures.root.deletingLastPathComponent().appending(path: "build/prefetch-priority-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appending(path: "photo.jpg")
    try FileManager.default.copyItem(at: Fixtures.url("image/format/baseline.jpg"), to: image)
    let backend = OpenPriorityBackend()
    var configuration = IOConfiguration(helperExecutable: nil)
    configuration.local.metadata = 1
    let scheduler = IOScheduler(configuration: configuration, backend: backend)
    defer { scheduler.shutdown() }
    let sources = FileSourceRegistry(scheduler: scheduler)
    let location = try await sources.location(for: image)
    let identity = try await sources.fileSystem.entry(at: location).identity
    backend.order.withLock { $0.removeAll() }
    let volume = try scheduler.volume(for: location)
    let gate = Mutex<(@Sendable () -> Void)?>(nil)
    let blocker = Task {
        let _: Void = try await scheduler.perform(on: volume, .metadata, priority: .visible, group: nil) { finish, _ in
            gate.withLock { $0 = { finish(.success(())) } }
        }
    }
    try await waitForPriorityCondition { gate.withLock { $0 != nil } }
    let index = try CacheIndex(databaseURL: directory.appending(path: "index.sqlite"))
    let caches = PipelineCaches(raw: MemoryCache(budget: 4 << 20), decoded: MemoryCache(budget: 4 << 20), thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: directory, budget: 4 << 20, index: index), browse: nil, metadata: MetadataIndex(index: index), thumbnailMemory: MemoryCache(budget: 4 << 20), preload: MemoryCache(budget: 4 << 20))
    let pipeline = FileImagePipeline(sources: sources, decoder: ImageDecoder(), caches: caches, configuration: PipelineConfiguration(thumbnailLongSide: 128, browseBounds: PixelSize(width: 320, height: 480)))
    let session = SessionID()
    pipeline.setPrefetchPlan(PrefetchPlan(items: [PrefetchItem(identity: identity, renditions: [.metadata], priority: .book)]), session: session)
    try await waitForPriorityCondition { scheduler.queuedCount == 1 }
    let near = Task {
        let _: Void = try await scheduler.perform(on: volume, .metadata, priority: .near, group: nil) { finish, _ in
            backend.order.withLock { $0.append("near") }
            finish(.success(()))
        }
    }
    try await waitForPriorityCondition { scheduler.queuedCount == 2 }
    gate.withLock { $0?() }
    try await blocker.value
    try await near.value
    try await waitForPriorityCondition { pipeline.prefetchInFlightCount(session: session) == 0 }
    #expect(backend.order.withLock { $0.prefix(2).elementsEqual(["near", "prefetch"]) })
    pipeline.cancelAll(session: session)
    await pipeline.shutdown()
}

@Test func scopedBookOpenHonorsItsPriority() async throws {
    let directory = Fixtures.root.deletingLastPathComponent().appending(path: "build/scoped-priority-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "video.mp4")
    try Data([0]).write(to: file)
    let backend = OpenPriorityBackend()
    var configuration = IOConfiguration(helperExecutable: nil)
    configuration.local.metadata = 1
    let scheduler = IOScheduler(configuration: configuration, backend: backend)
    defer { scheduler.shutdown() }
    let sources = FileSourceRegistry(scheduler: scheduler)
    let location = try await sources.location(for: file)
    let volume = try scheduler.volume(for: location)
    let gate = Mutex<(@Sendable () -> Void)?>(nil)
    let blocker = Task {
        let _: Void = try await scheduler.perform(on: volume, .metadata, priority: .visible, group: nil) { finish, _ in
            gate.withLock { $0 = { finish(.success(())) } }
        }
    }
    try await waitForPriorityCondition { gate.withLock { $0 != nil } }
    let opening = Task {
        try await FileIORequestContext.$priority.withValue(.book) { try await sources.fileSystem.open(location) }
    }
    try await waitForPriorityCondition { scheduler.queuedCount == 1 }
    let near = Task {
        let _: Void = try await scheduler.perform(on: volume, .metadata, priority: .near, group: nil) { finish, _ in
            backend.order.withLock { $0.append("near") }
            finish(.success(()))
        }
    }
    try await waitForPriorityCondition { scheduler.queuedCount == 2 }
    gate.withLock { $0?() }
    try await blocker.value
    try await near.value
    _ = try await opening.value
    #expect(backend.order.withLock { $0.prefix(2).elementsEqual(["near", "prefetch"]) })
}

private func waitForPriorityCondition(_ condition: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < until else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class OpenPriorityBackend: FileBackend {
    let order = Mutex<[String]>([])
    private let direct = DirectBackend()
    func execute(_ request: HelperRequest, completion: @escaping @Sendable (Result<String?, FileOperationError>) -> Void) { direct.execute(request, completion: completion) }
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        order.withLock { $0.append("prefetch") }
        direct.stat(path, completion: completion)
    }
    func lstat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) { direct.lstat(path, completion: completion) }
    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) { direct.probe(mountPoint, completion: completion) }
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) { direct.read(request, completion: completion) }
    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) { direct.list(path, batch: batch, completion: completion) }
    func abandon() { direct.abandon() }
}
