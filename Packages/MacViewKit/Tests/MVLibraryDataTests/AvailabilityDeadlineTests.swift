import Foundation
import GRDB
import MVFoundation
import MVIO
import Synchronization
import Testing
@testable import MVCache
@testable import MVLibraryData

private final class CacheReadGate: Sendable {
    private struct State { var entered = false; var released = false; var returned = false }
    private let state = Mutex(State())
    private let release = DispatchGroup()

    init() { release.enter() }
    var entered: Bool { state.withLock { $0.entered } }
    var returned: Bool { state.withLock { $0.returned } }
    func wait() {
        state.withLock { $0.entered = true }
        release.wait()
        state.withLock { $0.returned = true }
    }
    func open() {
        let shouldRelease = state.withLock { state in
            guard !state.released else { return false }
            state.released = true
            return true
        }
        if shouldRelease { release.leave() }
    }
}

private final class DirectoryWriteTrace: Sendable {
    private let total = Mutex(0)
    var count: Int { total.withLock { $0 } }
    func record() { total.withLock { $0 += 1 } }
}

private final class DeadlineFixture {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: ".c124-\(UUID())")
    let index: CacheIndex
    let directories: DirectoryCache
    let store: SQLiteLibraryStore
    let gate = CacheReadGate()
    let directoryWrites = DirectoryWriteTrace()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = try CacheIndex(databaseURL: root.appending(path: "cache.sqlite"))
        directories = DirectoryCache(index: index)
        store = try SQLiteLibraryStore(databaseURL: root.appending(path: "library.sqlite"), historyLimit: 10)
    }

    deinit { gate.open(); try? FileManager.default.removeItem(at: root) }

    // 与阶段 2 的 SQL 视图复现相同：真实 cachedChildren 进入数据库后卡住；
    // 用可释放的 SQL 函数代替长递归，测试不占用 CPU，也能清理所有读取。
    func blockCache(of container: Location) async throws {
        let entry = deadlineEntry(container.appending("page.jpg"))
        _ = try await directories.update(container, listing: DirectoryListing(entries: [entry]))
        let function = DatabaseFunction("c124_wait", argumentCount: 1) { [gate] arguments in
            gate.wait()
            return arguments[0]
        }
        let readers = index.pool.configuration.maximumReaderCount
        let registered = Mutex(0)
        let registrationGate = CacheReadGate()
        let tasks = (0..<readers).map { _ in
            Task.detached { [index] in
                try await index.pool.read { database in
                    database.add(function: function)
                    registered.withLock { $0 += 1 }
                    registrationGate.wait()
                }
            }
        }
        let ready = await deadlineUntil { registered.withLock { $0 == readers } }
        registrationGate.open()
        for task in tasks { try await task.value }
        try #require(ready)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode(container).map { String(format: "%02x", $0) }.joined()
        try await index.pool.write { database in
            database.add(function: function)
            try database.execute(sql: """
                ALTER TABLE directory_listings RENAME TO c124_listings;
                CREATE VIEW directory_listings AS
                SELECT location, CASE WHEN location = X'\(key)' THEN c124_wait(value) ELSE value END AS value
                FROM c124_listings;
                """)
        }
    }

    func finishReads() async throws {
        gate.open()
        // 等待读取任务释放连接后再删除夹具，避免留下后台数据库操作。
        try await index.pool.barrierWriteWithoutTransaction { _ in }
    }

    func observeDirectoryWrites() async throws {
        let function = DatabaseFunction("c124_record_write", argumentCount: 0) { [directoryWrites] _ in
            directoryWrites.record()
            return nil
        }
        try await index.pool.write { database in
            database.add(function: function)
            try database.execute(sql: """
                CREATE TRIGGER c124_directory_write AFTER INSERT ON directory_listings
                BEGIN SELECT c124_record_write(); END;
                CREATE TRIGGER c124_directory_update AFTER UPDATE ON directory_listings
                BEGIN SELECT c124_record_write(); END;
                """)
        }
    }
}

private func deadlineEntry(_ location: Location) -> Entry {
    Entry(identity: ContentIdentity(location: location, size: 1, modificationNanos: 1), name: location.name, kind: .image)
}

private final class DeadlineSource: SourceRegistry, ContainerProvider {
    private struct State {
        var requests: [Location: [AsyncThrowingStream<[Entry], any Error>.Continuation]] = [:]
        var cancellations: Set<Location> = []
    }
    private let state = Mutex(State())
    let immediate: [Location: [Entry]]

    init(immediate: [Location: [Entry]] = [:]) { self.immediate = immediate }
    func requested(_ container: Location) -> Bool { state.withLock { $0.requests[container] != nil } }
    func requestCount(_ container: Location) -> Int { state.withLock { $0.requests[container]?.count ?? 0 } }
    func cancelled(_ container: Location) -> Bool { state.withLock { $0.cancellations.contains(container) } }
    func complete(_ container: Location, request: Int = 0, entries: [Entry]) {
        let continuation = state.withLock { state in
            state.requests[container].flatMap { $0.indices.contains(request) ? $0[request] : nil }
        }
        continuation?.yield(entries)
        continuation?.finish()
    }
    func provider(for location: Location) throws -> any ContainerProvider { self }
    func location(for fileURL: URL) async throws -> Location { Location(root: .local, layers: [fileURL.pathComponents.filter { $0 != "/" }]) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { AsyncStream { $0.finish() } }
    func canHandle(_ location: Location) -> Bool { true }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] reason in
                if case .cancelled = reason { _ = state.withLock { $0.cancellations.insert(container) } }
            }
            state.withLock { $0.requests[container, default: []].append(continuation) }
            if let entries = immediate[container] { continuation.yield(entries); continuation.finish() }
        }
    }
    func entry(at location: Location) async throws -> Entry { throw IOError.unsupported(location) }
    func open(_ location: Location) async throws -> any ByteSource { throw IOError.unsupported(location) }
    func fileLease(for location: Location) async throws -> FileLease { throw IOError.unsupported(location) }
}

private final class DeadlineTrace: Sendable {
    private struct State { var batches: [[Location: Availability]] = []; var ended = false }
    private let state = Mutex(State())
    var ended: Bool { state.withLock { $0.ended } }
    func results(for location: Location) -> [Availability] { state.withLock { $0.batches.compactMap { $0[location] } } }
    func consume(_ stream: AsyncStream<[Location: Availability]>) -> Task<Void, Never> {
        Task {
            for await batch in stream { state.withLock { $0.batches.append(batch) } }
            state.withLock { $0.ended = true }
        }
    }
}

private func deadlineUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while !predicate(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    return predicate()
}

// C1.24 会故意占住真实数据库连接；与 100/150 ms 的时限测量互相隔离。
// 每个检查项内部的多容器、重叠重查与读写并发仍照常运行。
@Suite(.serialized)
struct LibraryDataTests {
    @Suite struct AvailabilityDeadlineTests {}
    @Suite struct LibraryLoadingTests {}
    @Suite struct LibraryStoreTests {}
}

extension LibraryDataTests.AvailabilityDeadlineTests {
    @Test("C1.24：真实数据库预读阻塞不阻挡其他容器，来源返回即交付并结束整批")
    func c124BlockedCacheDoesNotDelaySourceOrStream() async throws {
        let fixture = try DeadlineFixture()
        let slow = Location(root: .local, layers: [["blocked-cache"]])
        let healthy = Location(root: .local, layers: [["healthy"]])
        let target = slow.appending("page.jpg"), good = healthy.appending("page.jpg")
        try await fixture.blockCache(of: slow)
        let source = DeadlineSource(immediate: [healthy: [deadlineEntry(good)]])
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let trace = DeadlineTrace()
        let consumer = trace.consume(checker.check([target, good]))
        defer { consumer.cancel(); fixture.gate.open() }
        #expect(await deadlineUntil { fixture.gate.entered })
        #expect(await deadlineUntil { trace.results(for: good) == [.available] })
        #expect(await deadlineUntil { source.requested(slow) })
        let returned = ContinuousClock.now
        source.complete(slow, entries: [])
        #expect(await deadlineUntil { trace.ended })
        #expect(ContinuousClock.now - returned < .seconds(1))
        #expect(trace.results(for: target) == [.missing])
        #expect(!fixture.gate.returned)
        consumer.cancel()
        await consumer.value
        try await fixture.finishReads()
    }

    @Test("C1.24：晚到的真实缓存结果不覆盖来源结果，其他容器仍进行时也一样")
    func c124LateCacheCannotOverwriteSource() async throws {
        let fixture = try DeadlineFixture()
        let slow = Location(root: .local, layers: [["late-cache"]])
        let pending = Location(root: .local, layers: [["pending-source"]])
        let target = slow.appending("page.jpg"), other = pending.appending("page.jpg")
        try await fixture.blockCache(of: slow)
        let source = DeadlineSource()
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let trace = DeadlineTrace(), consumer = trace.consume(checker.check([target, other]))
        defer { consumer.cancel(); fixture.gate.open() }
        #expect(await deadlineUntil { fixture.gate.entered && source.requested(slow) && source.requested(pending) })
        source.complete(slow, entries: [])
        #expect(await deadlineUntil { trace.results(for: target) == [.missing] })
        #expect(!trace.ended)
        try await fixture.finishReads()
        #expect(fixture.gate.returned)
        source.complete(pending, entries: [deadlineEntry(other)])
        #expect(await deadlineUntil { trace.ended })
        #expect(trace.results(for: target) == [.missing])
        #expect(trace.results(for: other) == [.available])
        consumer.cancel()
        await consumer.value
    }

    @Test("C1.24：缓存和来源都阻塞时仍按真实十秒期限结束，来源收到取消")
    func c124BlockedCacheAndSourceRespectTenSecondDeadline() async throws {
        let fixture = try DeadlineFixture()
        let container = Location(root: .local, layers: [["timeout"]])
        let target = container.appending("page.jpg")
        try await fixture.blockCache(of: container)
        let source = DeadlineSource()
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let trace = DeadlineTrace(), start = ContinuousClock.now
        let consumer = trace.consume(checker.check([target]))
        defer { consumer.cancel(); fixture.gate.open() }
        #expect(await deadlineUntil { fixture.gate.entered && source.requested(container) })
        #expect(await deadlineUntil(timeout: .seconds(11)) { trace.ended })
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .seconds(10) && elapsed < .seconds(12))
        #expect(trace.results(for: target) == [.volumeUnavailable(container.root)])
        #expect(await deadlineUntil { source.cancelled(container) })
        #expect(!fixture.gate.returned)
        consumer.cancel()
        await consumer.value
        try await fixture.finishReads()
    }

    @Test("C1.24：缓存先到仍提前交付，取消旧流后新检查正常结束")
    func c124EarlyCacheAndCancellation() async throws {
        let fixture = try DeadlineFixture()
        let container = Location(root: .local, layers: [["early-cache"]])
        let target = container.appending("page.jpg")
        _ = try await fixture.directories.update(container, listing: DirectoryListing(entries: [deadlineEntry(target)]))
        let source = DeadlineSource()
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let first = DeadlineTrace(), consumer = first.consume(checker.check([target]))
        #expect(await deadlineUntil { first.results(for: target) == [.available] && source.requested(container) })
        consumer.cancel()
        await consumer.value
        #expect(await deadlineUntil { source.cancelled(container) })
        let nextSource = DeadlineSource()
        let next = DeadlineTrace()
        let nextChecker = AvailabilityChecker(sources: nextSource, directories: fixture.directories, store: fixture.store)
        let recheck = next.consume(nextChecker.check([target]))
        defer { recheck.cancel() }
        #expect(await deadlineUntil { next.results(for: target) == [.available] && nextSource.requested(container) })
        nextSource.complete(container, entries: [])
        #expect(await deadlineUntil { next.ended })
        #expect(next.results(for: target) == [.available, .missing])
        await recheck.value
        try await fixture.finishReads()
    }

    @Test("C1.24：同一检查器重叠重查，旧来源晚到不改写较新的目录缓存")
    func c124OverlappingChecksPreserveNewerDirectoryCache() async throws {
        let fixture = try DeadlineFixture()
        let container = Location(root: .local, layers: [["overlap"]])
        let target = container.appending("page.jpg")
        _ = try await fixture.directories.update(container, listing: DirectoryListing(entries: [deadlineEntry(target)]))
        try await fixture.observeDirectoryWrites()
        let source = DeadlineSource()
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let old = DeadlineTrace(), recent = DeadlineTrace()
        let oldConsumer = old.consume(checker.check([target]))
        defer { oldConsumer.cancel() }
        #expect(await deadlineUntil { source.requestCount(container) == 1 && old.results(for: target) == [.available] })
        let recentConsumer = recent.consume(checker.check([target]))
        defer { recentConsumer.cancel() }
        #expect(await deadlineUntil { source.requestCount(container) == 2 && recent.results(for: target) == [.available] })

        var fresh = deadlineEntry(target)
        fresh.identity.modificationNanos = 999
        let latest = DirectoryListing(entries: [fresh, deadlineEntry(container.appending("new.jpg"))], directoryModificationNanos: 1000)
        _ = try await fixture.directories.update(container, listing: latest)
        source.complete(container, request: 1, entries: [fresh])
        #expect(await deadlineUntil { recent.ended })
        source.complete(container, request: 0, entries: [])
        #expect(await deadlineUntil { old.ended })
        await recentConsumer.value
        await oldConsumer.value

        // 观察数据库触发器，连被忽略的异步写回尝试也会计数。
        #expect(!(await deadlineUntil(timeout: .milliseconds(100)) { fixture.directoryWrites.count > 1 }))
        try await fixture.finishReads()
        #expect(fixture.directoryWrites.count == 1)
        #expect(try await fixture.directories.cachedChildren(of: container) == latest)
        #expect(old.results(for: target) == [.available, .missing])
        #expect(recent.results(for: target) == [.available, .available])
    }

    @Test("C1.24：数据库写入阻塞时重复检查结束后不留下缓存写回")
    func c124RepeatedChecksDoNotQueueDirectoryWrites() async throws {
        let fixture = try DeadlineFixture()
        let container = Location(root: .local, layers: [["blocked-writer"]])
        let target = container.appending("page.jpg")
        let cached = DirectoryListing(entries: [])
        _ = try await fixture.directories.update(container, listing: cached)
        try await fixture.observeDirectoryWrites()
        let writerGate = CacheReadGate()
        let blockedWriter = Task { [index = fixture.index] in try await index.pool.write { _ in writerGate.wait() } }
        defer { writerGate.open() }
        #expect(await deadlineUntil { writerGate.entered })
        let source = DeadlineSource(immediate: [container: [deadlineEntry(target)]])
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        for _ in 0..<8 {
            let trace = DeadlineTrace(), consumer = trace.consume(checker.check([target]))
            #expect(await deadlineUntil { trace.ended })
            consumer.cancel()
            await consumer.value
            #expect(trace.results(for: target).last == .available)
        }
        #expect(source.requestCount(container) == 8)
        writerGate.open()
        try await blockedWriter.value
        #expect(!(await deadlineUntil(timeout: .milliseconds(100)) { fixture.directoryWrites.count > 0 }))
        try await fixture.finishReads()
        #expect(fixture.directoryWrites.count == 0)
        #expect(try await fixture.directories.cachedChildren(of: container) == cached)
    }
}
