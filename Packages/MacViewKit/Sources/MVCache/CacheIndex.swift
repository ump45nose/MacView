import Darwin
import Foundation
import GRDB
import Synchronization

/// 所有持久缓存共享一个 WAL 数据库；数据库写入由 GRDB 串行执行。
public final class CacheIndex: Sendable {
    let pool: DatabasePool
    let diskOperations = DiskOperations()
    let processStarted: Date

    struct AccessKey: Hashable, Sendable {
        var tier: String
        var key: String
    }

    private struct AccessState: Sendable {
        var pending: [AccessKey: Double] = [:]
        var scheduled = false
        var urgentScheduled = false
    }
    private let accesses = Mutex(AccessState())

    public init(databaseURL: URL) throws {
        processStarted = try cacheProcessStartDate()
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("cache-v1") { database in
            try database.execute(sql: """
                CREATE TABLE disk_entries (
                    tier TEXT NOT NULL, key TEXT NOT NULL, filename TEXT NOT NULL,
                    size INTEGER NOT NULL, accessed REAL NOT NULL,
                    PRIMARY KEY (tier, key)
                ) WITHOUT ROWID;
                CREATE INDEX disk_entries_lru ON disk_entries(tier, accessed);
                CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE directory_listings (location BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
                """)
        }
        try migrator.migrate(pool)
    }

    func recordAccess(tier: DiskTier, keys: [String]) {
        let now = Date().timeIntervalSince1970
        let action = accesses.withLock { state -> (start: Bool, immediate: Bool) in
            for key in keys { state.pending[AccessKey(tier: tier.rawValue, key: key)] = now }
            if state.pending.count >= 256, !state.urgentScheduled {
                state.urgentScheduled = true
                return (true, true)
            }
            guard !state.scheduled, !state.pending.isEmpty else { return (false, false) }
            state.scheduled = true
            return (true, false)
        }
        guard action.start else { return }
        Task { [weak self] in
            if !action.immediate { try? await Task.sleep(for: .seconds(1)) }
            guard let self else { return }
            var succeeded = false
            do {
                try await self.flush()
                succeeded = true
            }
            catch {
                // flush 已把这批放回队列；下次读取或 shutdown 会重试并向调用方报错。
            }
            let hasPending = self.accesses.withLock { state in
                if action.immediate { state.urgentScheduled = false }
                else { state.scheduled = false }
                return !state.pending.isEmpty
            }
            if succeeded, hasPending { self.recordAccess(tier: tier, keys: []) }
        }
    }

    /// 写回读取产生的访问时间；失败时保留待写批次。
    public func flush() async throws {
        try await diskOperations.perform { [self] in try flushAccesses() }
    }

    func flushAccesses() throws {
        let pending = accesses.withLock { state in
            let pending = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return pending
        }
        guard !pending.isEmpty else { return }
        do {
            try pool.write { database in
                let statement = try database.makeStatement(sql: "UPDATE disk_entries SET accessed = MAX(accessed, ?) WHERE tier = ? AND key = ?")
                for (key, timestamp) in pending {
                    try statement.execute(arguments: [timestamp, key.tier, key.key])
                }
            }
        } catch {
            accesses.withLock { state in
                for (key, timestamp) in pending {
                    state.pending[key] = max(state.pending[key] ?? 0, timestamp)
                }
            }
            throw error
        }
    }
}

/// 文件改名、更新索引和淘汰必须整体串行；读文件不经过这里。
final class DiskOperations: Sendable {
    private let queue = DispatchQueue(label: "MacView.cache.files.write", qos: .utility)

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

func cacheChunks<Element>(_ elements: [Element], size: Int = 500) -> [ArraySlice<Element>] {
    stride(from: 0, to: elements.count, by: size).map { elements[$0..<min($0 + size, elements.count)] }
}

func cachePlaceholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }

private func cacheProcessStartDate() throws -> Date {
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let result = name.withUnsafeMutableBufferPointer {
        sysctl($0.baseAddress, UInt32($0.count), &process, &size, nil, 0)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let time = process.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
}
