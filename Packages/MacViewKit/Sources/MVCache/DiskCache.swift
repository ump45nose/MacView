import CryptoKit
import Darwin
import Foundation
import GRDB
import Synchronization

public enum DiskTier: String, Sendable { case thumbnails, browse }

/// L2/L3 的文件存储。只有索引里存在的文件才是缓存命中。
public final class DiskCache: Sendable {
    private static var fileReads: OperationQueue {
        CacheFileReads.queue
    }
    private let tier: DiskTier
    private let root: URL
    private let temporary: URL
    private let index: CacheIndex
    private struct State: Sendable {
        var budget: Int64
        var sweepCursor = 0
    }
    private let state: Mutex<State>

    public init(tier: DiskTier, cacheDirectory: URL, budget: Int64, index: CacheIndex) throws {
        self.tier = tier
        self.index = index
        root = cacheDirectory.appendingPathComponent(tier.rawValue, isDirectory: true)
        temporary = root.appendingPathComponent("tmp", isDirectory: true)
        state = Mutex(State(budget: max(0, budget)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    public func data(for key: String) async throws -> Data? {
        try await data(for: [key])[key]
    }

    public func data(for keys: [String]) async throws -> [String: Data] {
        let keys = Array(Set(keys))
        guard !keys.isEmpty else { return [:] }
        let tier = tier.rawValue
        let files = try await index.pool.read { database -> [String: String] in
            var files: [String: String] = [:]
            for chunk in cacheChunks(keys) {
                let rows = try Row.fetchAll(database, sql: "SELECT key, filename FROM disk_entries WHERE tier = ? AND key IN (\(cachePlaceholders(chunk.count)))", arguments: StatementArguments([tier] + Array(chunk)))
                for row in rows { files[row["key"]] = row["filename"] }
            }
            return files
        }
        let root = root
        let pairs = Array(files)
        let result = try await withThrowingTaskGroup(of: (String, Data?).self) { group in
            var next = 0
            func enqueue() {
                let (key, filename) = pairs[next]
                next += 1
                group.addTask {
                    let data = try await Self.readFile(root.appendingPathComponent(filename))
                    return (key, data)
                }
            }
            for _ in 0..<min(16, pairs.count) { enqueue() }
            var result: [String: Data] = [:]
            while let (key, data) = try await group.next() {
                if let data { result[key] = data }
                if next < pairs.count { enqueue() }
            }
            return result
        }
        index.recordAccess(tier: self.tier, keys: Array(result.keys))
        return result
    }

    public func store(_ data: Data, for key: String) async throws {
        try await index.diskOperations.perform { [self] in
            let filename = Self.filename(for: key)
            let destination = root.appendingPathComponent(filename)
            let budget = state.withLock { $0.budget }
            guard Int64(data.count) <= budget else { return }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = temporary.appendingPathComponent(UUID().uuidString)
            do {
                try data.write(to: staging)
                let handle = try FileHandle(forWritingTo: staging)
                try handle.synchronize()
                try handle.close()
                guard rename(staging.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try index.pool.write { database in
                    try database.execute(sql: """
                        INSERT INTO disk_entries(tier, key, filename, size, accessed) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(tier, key) DO UPDATE SET filename = excluded.filename, size = excluded.size, accessed = excluded.accessed
                        """, arguments: [tier.rawValue, key, filename, data.count, Date().timeIntervalSince1970])
                }
            } catch {
                if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                throw error
            }
            try evict(to: budget)
        }
    }

    public func setBudget(_ budget: Int64) async throws {
        try await index.diskOperations.perform { [self] in
            let budget = max(0, budget)
            state.withLock { $0.budget = budget }
            try evict(to: budget)
        }
    }

    private func evict(to budget: Int64) throws {
        try index.flushAccesses()
        let tier = tier.rawValue
        let removed = try index.pool.write { database -> [String] in
            var size = try Int64.fetchOne(database, sql: "SELECT COALESCE(SUM(size), 0) FROM disk_entries WHERE tier = ?", arguments: [tier]) ?? 0
            guard size > budget else { return [] }
            let rows = try Row.fetchAll(database, sql: "SELECT key, filename, size FROM disk_entries WHERE tier = ? ORDER BY accessed, key", arguments: [tier])
            var removed: [String] = []
            let statement = try database.makeStatement(sql: "DELETE FROM disk_entries WHERE tier = ? AND key = ?")
            for row in rows where size > budget {
                let key: String = row["key"]
                let cost: Int64 = row["size"]
                try statement.execute(arguments: [tier, key])
                removed.append(row["filename"])
                size -= cost
            }
            return removed
        }
        // 先提交删除索引，再删文件。崩溃不会留下指向缺失文件的索引。
        for filename in removed { try removeIfPresent(root.appendingPathComponent(filename)) }
        if !removed.isEmpty { try sweepOrphans() }
    }

    private func sweepOrphans() throws {
        let prefix = state.withLock { state in
            let prefix = String(format: "%02x", state.sweepCursor)
            state.sweepCursor = (state.sweepCursor + 1) % 256
            return prefix
        }
        let directory = root.appendingPathComponent(prefix, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let tier = tier.rawValue
        let known = try index.pool.read { database in
            Set(try String.fetchAll(database, sql: "SELECT filename FROM disk_entries WHERE tier = ? AND filename LIKE ?", arguments: [tier, prefix + "/%"]))
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate,
                  modified < index.processStarted, !known.contains(prefix + "/" + file.lastPathComponent) else { continue }
            try removeIfPresent(file)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    private static func filename(for key: String) -> String {
        let safe = key.count == 32 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        let name = safe ? key : SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(name.prefix(2)) + "/" + name
    }

    private static func readFile(_ url: URL) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            fileReads.addOperation {
                do { continuation.resume(returning: try Data(contentsOf: url)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continuation.resume(returning: nil)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private enum CacheFileReads {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacView.cache.files.read"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 16
        return queue
    }()
}
