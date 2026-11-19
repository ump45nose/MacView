import Darwin
import Foundation
import GRDB
import MVFoundation
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
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("cache-v2") { database in
            try database.execute(sql: """
                CREATE TABLE disk_entries (
                    tier TEXT NOT NULL, key TEXT NOT NULL, filename TEXT NOT NULL,
                    size INTEGER NOT NULL, accessed REAL NOT NULL,
                    PRIMARY KEY (tier, key)
                ) WITHOUT ROWID;
                CREATE INDEX disk_entries_lru ON disk_entries(tier, accessed);
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY NOT NULL, container BLOB NOT NULL,
                    width INTEGER NOT NULL, height INTEGER NOT NULL, frameCount INTEGER NOT NULL,
                    duration REAL, capturedAt REAL, colorSpace TEXT
                ) WITHOUT ROWID;
                CREATE INDEX metadata_container ON metadata(container);
                CREATE TABLE directory_listings (location BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("cache-v3") { database in
            try database.execute(sql: """
                ALTER TABLE metadata ADD COLUMN rating INTEGER;
                CREATE TABLE metadata_tags (
                    key TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (key, tag)
                ) WITHOUT ROWID;
                CREATE INDEX metadata_tags_tag ON metadata_tags(tag);
                CREATE TABLE search_entries (
                    location BLOB PRIMARY KEY NOT NULL,
                    container BLOB NOT NULL,
                    prefix TEXT NOT NULL,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    cacheKey TEXT NOT NULL
                );
                CREATE INDEX search_entries_prefix ON search_entries(prefix);
                CREATE INDEX search_entries_cacheKey ON search_entries(cacheKey);
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
    private let pending = Mutex(0)

    var pendingCount: Int { pending.withLock { $0 } }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        pending.withLock { $0 += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                defer { self.pending.withLock { $0 -= 1 } }
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

func encodeLocationKey(_ location: Location) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(location)
}

func decodeLocationKey(_ data: Data) throws -> Location {
    try JSONDecoder().decode(Location.self, from: data)
}

/// 严格位于 `scope` 之下的 `prefixKey` 区间：`prefix >= lower AND prefix < upper`。
/// `'/'` (0x2F) 的下一个 ASCII 字节是 `'0'` (0x30)，可避免兄弟目录 `a` 与 `ab` 混入。
func prefixRange(under scope: Location) -> (lower: String, upper: String) {
    let base = scope.prefixKey
    return (base + "/", base + "0")
}

/// 任意 UTF-8 字符串在二进制字典序下的最小严格上界，用于 `>= prefix AND < upper` 范围查询。
func prefixUpperBound(_ prefix: String) -> String? {
    var scalars = Array(prefix.unicodeScalars)
    while let last = scalars.popLast() {
        if last.value == 0x10FFFF { continue }
        var next = last.value + 1
        if (0xD800...0xDFFF).contains(next) { next = 0xE000 }
        guard let scalar = UnicodeScalar(next) else { continue }
        scalars.append(scalar)
        return String(String.UnicodeScalarView(scalars))
    }
    return nil
}

func normalizedSearchText(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping.lowercased()
}

func likePattern(for text: String, leadingWildcard: Bool = true) -> String {
    var result = leadingWildcard ? "%" : ""
    result.reserveCapacity(text.count + 4)
    for character in text {
        switch character {
        case "\\", "%", "_":
            result.append("\\")
            result.append(character)
        default:
            result.append(character)
        }
    }
    result.append("%")
    return result
}

func searchKindValue(for kind: EntryKind) -> String {
    switch kind {
    case .image: SearchKind.image.rawValue
    case .video: SearchKind.video.rawValue
    case .archive: SearchKind.archive.rawValue
    case .directory: SearchKind.directory.rawValue
    case .other: "other"
    }
}

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
