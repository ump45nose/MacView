import Darwin
import Foundation
import GRDB
import MVFoundation
import Synchronization
import Testing
@testable import MVCache

// MARK: L0/L1

@Test func memoryLRUUsesCostAndPromotesHits() {
    let cache = MemoryCache<String, String>(budget: 10)
    cache.insert("A", for: "a", cost: 4)
    cache.insert("B", for: "b", cost: 4)
    #expect(cache.value(for: "a") == "A")
    cache.insert("C", for: "c", cost: 4)
    #expect(cache.value(for: "b") == nil)
    #expect(cache.value(for: "a") == "A")
    #expect(cache.value(for: "c") == "C")
    #expect(cache.totalCost == 8)
    cache.insert("new A", for: "a", cost: 7)
    #expect(cache.totalCost == 7)
    #expect(cache.value(for: "c") == nil)
    #expect(cache.value(for: "a") == "new A")
    cache.removeValue(for: "a")
    #expect(cache.totalCost == 0)
}

@Test func memoryRejectsOversizeAndShrinksImmediately() {
    let cache = MemoryCache<Int, Int>(budget: 8)
    for key in 0..<4 { cache.insert(key, for: key, cost: 2) }
    cache.insert(99, for: 99, cost: 9)
    #expect(cache.value(for: 99) == nil)
    cache.setBudget(4)
    #expect(cache.totalCost == 4)
    #expect(cache.value(for: 0) == nil)
    #expect(cache.value(for: 1) == nil)
    #expect(cache.value(for: 2) == 2)
    cache.setBudget(16)
    cache.insert(4, for: 4, cost: 10)
    #expect(cache.totalCost == 14)
    cache.setBudget(0)
    #expect(cache.totalCost == 0)
}

@Test func memoryPressureTrimKeepsConfiguredBudget() {
    let cache = MemoryCache<Int, Int>(budget: 16)
    for key in 0..<8 { cache.insert(key, for: key, cost: 2) }
    cache.trim(toFraction: 0.5)
    #expect(cache.totalCost == 8)
    #expect(cache.budget == 16)
    #expect(cache.value(for: 3) == nil)
    #expect(cache.value(for: 4) == 4)
    cache.trim(toFraction: 0.25)
    #expect(cache.totalCost == 4)
    #expect(cache.budget == 16)
    cache.insert(9, for: 9, cost: 12)
    #expect(cache.totalCost == 16)
}

@Test func memoryConcurrentAccessPreservesCost() async {
    let cache = MemoryCache<Int, Int>(budget: 128)
    await withTaskGroup(of: Void.self) { group in
        for worker in 0..<8 {
            group.addTask {
                for step in 0..<1_000 {
                    let key = (step + worker) % 64
                    cache.insert(key, for: key, cost: 4)
                    _ = cache.value(for: (key + 1) % 64)
                    if step % 3 == 0 { cache.removeValue(for: (key + 2) % 64) }
                }
            }
        }
    }
    #expect(cache.totalCost <= 128)
    #expect(cache.totalCost >= 0)
}

// MARK: SQLite、L2/L3 与批量访问时间

@Test func diskTiersAndIndexesSurviveReopening() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let key = "0123456789abcdef0123456789abcdef"
    let metadata = TestMetadata(width: 800, height: 600, format: "jpeg")
    let container = Location(root: .local).appending("书.zip")
    let listing = DirectoryListing(entries: [testEntry("001.jpg", in: container.appendingLayer([]))], directoryModificationNanos: 123)
    do {
        let index = try CacheIndex(databaseURL: directory.database)
        #expect(try await index.pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
        let thumbnail = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 100, index: index)
        let browse = try DiskCache(tier: .browse, cacheDirectory: directory.url, budget: 100, index: index)
        try await thumbnail.store(Data([1, 2, 3]), for: key)
        try await browse.store(Data([4, 5]), for: key)
        try await MetadataIndex<TestMetadata>(index: index).store([key: metadata])
        _ = try await DirectoryCache(index: index).update(container, listing: listing)
        try await index.flush()
    }
    let reopened = try CacheIndex(databaseURL: directory.database)
    let thumbnail = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 100, index: reopened)
    let browse = try DiskCache(tier: .browse, cacheDirectory: directory.url, budget: 100, index: reopened)
    #expect(try await thumbnail.data(for: key) == Data([1, 2, 3]))
    #expect(try await browse.data(for: key) == Data([4, 5]))
    #expect(try await MetadataIndex<TestMetadata>(index: reopened).values(for: [key, "missing", key]) == [key: metadata])
    #expect(try await DirectoryCache(index: reopened).cachedChildren(of: container) == listing)
    #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("thumbnails/01/" + key).path))
}

@Test func diskEvictionUsesPendingReadsAndRuntimeBudget() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 12, index: index)
    for key in ["a", "b", "c"] { try await cache.store(Data(repeating: 3, count: 4), for: key) }
    try await index.pool.write { database in
        for (offset, key) in ["a", "b", "c"].enumerated() {
            try database.execute(sql: "UPDATE disk_entries SET accessed = ? WHERE key = ?", arguments: [offset + 1, key])
        }
    }
    #expect(try await cache.data(for: "a") != nil)
    // 一次命中没有立即写库；真正淘汰之前必须把这次命中算进去。
    #expect(try accessTime(index, key: "a") == 1)
    try await cache.setBudget(8)
    #expect(try await cache.data(for: "b") == nil)
    #expect(try await cache.data(for: ["a", "c", "missing"]).count == 2)
    try await cache.setBudget(0)
    #expect(try indexedSize(index) == 0)
    #expect(try cacheFileSize(directory.url.appendingPathComponent("thumbnails")) == 0)
    try await cache.store(Data([9]), for: "oversized")
    #expect(try await cache.data(for: "oversized") == nil)
    try await cache.setBudget(4)
    try await cache.store(Data([1, 2]), for: "new")
    #expect(try await cache.data(for: "new") == Data([1, 2]))
}

@Test func accessTimesFlushAsOneBatchAndOnTimer() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 1_024, index: index)
    for key in ["a", "b"] { try await cache.store(Data([7]), for: key) }
    try await index.pool.write { try $0.execute(sql: "UPDATE disk_entries SET accessed = 1") }
    _ = try await cache.data(for: ["a", "b"])
    #expect(try accessTime(index, key: "a") == 1)
    #expect(try accessTime(index, key: "b") == 1)
    try await index.flush()
    #expect(try accessTime(index, key: "a") > 1)
    #expect(try accessTime(index, key: "a") == accessTime(index, key: "b"))
    try await index.pool.write { try $0.execute(sql: "UPDATE disk_entries SET accessed = 1") }
    _ = try await cache.data(for: "a")
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while try accessTime(index, key: "a") == 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(try accessTime(index, key: "a") > 1)
}

@Test func accessCountAlsoTriggersBatchFlush() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let keys = (0..<256).map(String.init)
    try await seedAccessRows(index, keys: keys)
    let clock = ContinuousClock()
    let start = clock.now
    index.recordAccess(tier: .thumbnails, keys: keys)
    while try accessTime(index, key: "0") == 1, clock.now - start < .milliseconds(800) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try accessTime(index, key: "0") > 1)
}

@Test func accessesArrivingDuringFlushAreRescheduled() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    try await seedAccessRows(index, keys: ["first", "second"])
    let acquired = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let blocker = Task {
        try await index.pool.write { _ in
            acquired.continuation.yield(())
            release.wait()
        }
    }
    for await _ in acquired.stream { break }
    index.recordAccess(tier: .thumbnails, keys: ["first"])
    try await Task.sleep(for: .milliseconds(1_200))
    index.recordAccess(tier: .thumbnails, keys: ["second"])
    release.signal()
    try await blocker.value
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    while try accessTime(index, key: "second") == 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(try accessTime(index, key: "second") > 1)
}

@Test func failedAccessFlushRetainsPendingBatch() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    try await seedAccessRows(index, keys: ["retry"])
    try await index.pool.write {
        try $0.execute(sql: "CREATE TRIGGER reject_access BEFORE UPDATE ON disk_entries BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END")
    }
    index.recordAccess(tier: .thumbnails, keys: ["retry"])
    await #expect(throws: (any Error).self) { try await index.flush() }
    #expect(try accessTime(index, key: "retry") == 1)
    try await index.pool.write { try $0.execute(sql: "DROP TRIGGER reject_access") }
    try await index.flush()
    #expect(try accessTime(index, key: "retry") > 1)
}

@Test func diskReadsAreIndexedAndWritesReplaceAtomically() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 1_000, index: index)
    try await cache.store(Data([1]), for: "same")
    try await cache.store(Data(repeating: 2, count: 500), for: "same")
    #expect(try await cache.data(for: "same") == Data(repeating: 2, count: 500))
    #expect(try indexedSize(index) == 500)
    try await index.pool.write { try $0.execute(sql: "DELETE FROM disk_entries") }
    #expect(try await cache.data(for: "same") == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("thumbnails/tmp").path).isEmpty)
}

// MARK: 目录差异与按书元数据

@Test func directoryDiffUsesLocationsAndContentIdentities() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let cache = DirectoryCache(index: index)
    let container = Location(root: .network(scheme: "nfs", host: "example", share: "books"), layers: [["a.zip"], ["inner"]])
    #expect(try await cache.cachedChildren(of: container) == nil)
    var a = testEntry("a.jpg", in: container)
    a.kind = .archive(.tarGzip)
    a.created = Date(timeIntervalSinceReferenceDate: 1_234.125)
    a.identity.checksum = 0xfedcba98
    var b = testEntry("b.jpg", in: container)
    b.name = "显示名称"
    let c = testEntry("c.jpg", in: container)
    let first = try await cache.update(container, listing: DirectoryListing(entries: [a, b], directoryModificationNanos: 10))
    #expect(first == ListingDiff(added: [a, b], removed: [], changed: []))
    #expect(try await cache.cachedChildren(of: container) == DirectoryListing(entries: [a, b], directoryModificationNanos: 10))
    var changed = b
    changed.identity.modificationNanos += 1
    let second = try await cache.update(container, listing: DirectoryListing(entries: [changed, c], directoryModificationNanos: 20))
    #expect(second == ListingDiff(added: [c], removed: [a.location], changed: [changed]))
    #expect(try await cache.cachedChildren(of: container)?.directoryModificationNanos == 20)
    let unchanged = try await cache.update(container, listing: DirectoryListing(entries: [c, changed], directoryModificationNanos: 30))
    #expect(unchanged == ListingDiff(added: [], removed: [], changed: []))
    #expect(try await cache.cachedChildren(of: container)?.entries == [c, changed])
}

@Test func metadataBatchIsCompleteAndUpdatesPersist() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let metadata = MetadataIndex<TestMetadata>(index: index)
    let values = Dictionary(uniqueKeysWithValues: (0..<1_200).map { ("key-\($0)", TestMetadata(width: $0, height: 600, format: "jpeg")) })
    try await metadata.store(values)
    #expect(try await metadata.values(for: Array(values.keys)) == values)
    let changed = TestMetadata(width: 5, height: 7, format: "png")
    try await metadata.store(["key-1": changed])
    let reopened = MetadataIndex<TestMetadata>(index: try CacheIndex(databaseURL: directory.database))
    #expect(try await reopened.values(for: ["key-1", "missing"]) == ["key-1": changed])
}

// MARK: 崩溃、启动与并发淘汰

@Test(arguments: [0, 23, 67]) func killedWriterLeavesOnlyCompleteIndexedFiles(delayMilliseconds: Int) async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/debug/mvtest-writer").standardizedFileURL
    let process = Process()
    let output = Pipe()
    let ready = Mutex(false)
    output.fileHandleForReading.readabilityHandler = { handle in
        if String(decoding: handle.availableData, as: UTF8.self).contains("ready") { ready.withLock { $0 = true } }
    }
    process.executableURL = executable
    process.arguments = ["cache", directory.url.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        output.fileHandleForReading.readabilityHandler = nil
    }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while !ready.withLock({ $0 }), process.isRunning, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(ready.withLock { $0 }, "writer 未进入写入循环")
    if delayMilliseconds > 0 { try await Task.sleep(for: .milliseconds(delayMilliseconds)) }
    #expect(kill(process.processIdentifier, SIGKILL) == 0)
    process.waitUntilExit()
    #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus == SIGKILL)
    let index = try CacheIndex(databaseURL: directory.database)
    let rows = try await index.pool.read { database in
        try Row.fetchAll(database, sql: "SELECT key, size FROM disk_entries").map { row -> (String, Int) in (row["key"], row["size"]) }
    }
    #expect(rows.count >= 8)
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 64 << 20, index: index)
    for row in rows {
        let key = row.0
        let sequence = try #require(Int(key, radix: 16))
        let data = try #require(await cache.data(for: key))
        #expect(data.count == 16_384 + sequence % 4096)
        #expect(data.count == row.1)
        #expect(data.allSatisfy { $0 == UInt8(sequence % 251) })
    }
    #expect(try await index.pool.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")
}

@Test func startupOnlyClearsTemporaryFilesAndEvictionSweepsOldOrphans() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let prefix = directory.url.appendingPathComponent("thumbnails/00")
    let temporary = directory.url.appendingPathComponent("thumbnails/tmp")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let orphan = prefix.appendingPathComponent("orphan")
    let current = prefix.appendingPathComponent("current-process")
    try Data([9]).write(to: orphan)
    try Data([8]).write(to: temporary.appendingPathComponent("interrupted"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: orphan.path)
    let index = try CacheIndex(databaseURL: directory.database)
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: 2, index: index)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    try Data([7]).write(to: current)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: current.path)
    try await cache.store(Data([1, 2]), for: "kept")
    try await cache.setBudget(0)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
}

@Test func evictionConcurrentReadsAndWritesStayWithinBudget() async throws {
    let directory = try CacheTestDirectory()
    defer { directory.remove() }
    let index = try CacheIndex(databaseURL: directory.database)
    let budget: Int64 = 16_384
    let cache = try DiskCache(tier: .thumbnails, cacheDirectory: directory.url, budget: budget, index: index)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for worker in 0..<6 {
            group.addTask {
                for step in 0..<80 {
                    let number = (worker * 80 + step) % 73
                    let key = String(number)
                    let data = Data(repeating: UInt8(number), count: 1_024)
                    try await cache.store(data, for: key)
                    if let read = try await cache.data(for: key) { #expect(read == data) }
                    let batch = try await cache.data(for: (0..<16).map { String(($0 + step) % 73) })
                    for (key, data) in batch { #expect(data == Data(repeating: UInt8(Int(key)!), count: 1_024)) }
                    if step % 10 == 0 { try await cache.setBudget(step % 20 == 0 ? budget / 2 : budget) }
                }
            }
        }
        try await group.waitForAll()
    }
    try await cache.setBudget(budget)
    try await index.flush()
    #expect(try indexedSize(index) <= budget)
    #expect(try cacheFileSize(directory.url.appendingPathComponent("thumbnails")) <= budget)
    let keys = try await index.pool.read { try String.fetchAll($0, sql: "SELECT key FROM disk_entries") }
    #expect(try await cache.data(for: keys).count == keys.count)
}

private struct TestMetadata: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var format: String
}

private func testEntry(_ name: String, in container: Location) -> Entry {
    Entry(identity: ContentIdentity(location: container.appending(name), size: 42, modificationNanos: 100), name: name, kind: .image)
}

private func accessTime(_ index: CacheIndex, key: String) throws -> Double {
    try index.pool.read { try Double.fetchOne($0, sql: "SELECT accessed FROM disk_entries WHERE key = ?", arguments: [key]) ?? 0 }
}

private func indexedSize(_ index: CacheIndex) throws -> Int64 {
    try index.pool.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(size), 0) FROM disk_entries") ?? 0 }
}

private func seedAccessRows(_ index: CacheIndex, keys: [String]) async throws {
    try await index.pool.write { database in
        let statement = try database.makeStatement(sql: "INSERT INTO disk_entries(tier, key, filename, size, accessed) VALUES ('thumbnails', ?, ?, 1, 1)")
        for key in keys { try statement.execute(arguments: [key, key]) }
    }
}

private func cacheFileSize(_ root: URL) throws -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
    var size: Int64 = 0
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
    }
    return size
}

private struct CacheTestDirectory {
    let url: URL
    var database: URL { url.appendingPathComponent("index.sqlite") }

    init() throws {
        url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../build/stage-1-work/cache-tests/" + UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
