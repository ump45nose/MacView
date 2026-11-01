import Foundation
import GRDB

/// 值的类型由消费方决定；MVCache 不依赖媒体模块。
public final class MetadataIndex<Value: Codable & Sendable>: Sendable {
    private let index: CacheIndex
    public init(index: CacheIndex) { self.index = index }

    public func values(for keys: [String]) async throws -> [String: Value] {
        guard !keys.isEmpty else { return [:] }
        let encoded = try await index.pool.read { database -> [(String, Data)] in
            var result: [(String, Data)] = []
            result.reserveCapacity(keys.count)
            for chunk in cacheChunks(keys) {
                let rows = try Row.fetchCursor(database, sql: "SELECT key, value FROM metadata WHERE key IN (\(cachePlaceholders(chunk.count)))", arguments: StatementArguments(Array(chunk)))
                while let row = try rows.next() { result.append((row[0], row[1])) }
            }
            return result
        }
        // 每块只解析一次 JSON 文档，避免一万个独立解析器；最多八块并行。
        let blocks = cacheChunks(encoded, size: max(1, (encoded.count + 7) / 8))
        return try await withThrowingTaskGroup(of: [String: Value].self) { group in
            for block in blocks {
                group.addTask {
                    var document = Data([0x5b])
                    document.reserveCapacity(block.reduce(2) { $0 + $1.1.count + 1 })
                    for (offset, pair) in block.enumerated() {
                        if offset > 0 { document.append(0x2c) }
                        document.append(pair.1)
                    }
                    document.append(0x5d)
                    let values = try JSONDecoder().decode([Value].self, from: document)
                    var result: [String: Value] = [:]
                    result.reserveCapacity(block.count)
                    for (pair, value) in zip(block, values) { result[pair.0] = value }
                    return result
                }
            }
            var result: [String: Value] = [:]
            result.reserveCapacity(encoded.count)
            for try await block in group { result.merge(block, uniquingKeysWith: { _, last in last }) }
            return result
        }
    }

    public func store(_ values: [String: Value]) async throws {
        let encoder = JSONEncoder()
        let encoded = try values.mapValues { try encoder.encode($0) }
        try await index.pool.write { database in
            let statement = try database.makeStatement(sql: "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
            for (key, value) in encoded { try statement.execute(arguments: [key, value]) }
        }
    }
}
