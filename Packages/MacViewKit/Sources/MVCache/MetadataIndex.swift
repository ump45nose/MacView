import Foundation
import GRDB
import MVFoundation

/// 定长列保存图片元数据，按所属容器一次取回。
public final class MetadataIndex: Sendable {
    private let index: CacheIndex
    public init(index: CacheIndex) { self.index = index }

    public func values(in container: Location) async throws -> [String: ImageMetadata] {
        let key = try encodeLocationKey(container)
        return try await index.pool.read { database in
            try Self.fetch(database, predicate: "container = ?", arguments: [key])
        }
    }

    public func values(for keys: [String]) async throws -> [String: ImageMetadata] {
        guard !keys.isEmpty else { return [:] }
        return try await index.pool.read { database in
            var result: [String: ImageMetadata] = [:]
            result.reserveCapacity(keys.count)
            for chunk in cacheChunks(keys) {
                let values = try Self.fetch(database, predicate: "key IN (\(cachePlaceholders(chunk.count)))", arguments: StatementArguments(Array(chunk)))
                result.merge(values, uniquingKeysWith: { _, last in last })
            }
            return result
        }
    }

    public func store(_ values: [String: ImageMetadata], in container: Location) async throws {
        guard !values.isEmpty else { return }
        let containerKey = try encodeLocationKey(container)
        try await index.pool.write { database in
            let upsertMetadata = try database.makeStatement(sql: """
                INSERT INTO metadata(key, container, width, height, frameCount, duration, capturedAt, colorSpace, rating)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET container = excluded.container, width = excluded.width,
                    height = excluded.height, frameCount = excluded.frameCount, duration = excluded.duration,
                    capturedAt = excluded.capturedAt, colorSpace = excluded.colorSpace, rating = excluded.rating
                """)
            let deleteTags = try database.makeStatement(sql: "DELETE FROM metadata_tags WHERE key = ?")
            let insertTag = try database.makeStatement(sql: "INSERT OR IGNORE INTO metadata_tags(key, tag) VALUES (?, ?)")
            for (key, value) in values {
                try upsertMetadata.execute(arguments: [
                    key, containerKey, value.pixelSize.width, value.pixelSize.height,
                    value.frameCount, value.duration, value.capturedAt?.timeIntervalSince1970,
                    value.colorSpace, value.rating
                ])
                try deleteTags.execute(arguments: [key])
                if let tags = value.tags {
                    for tag in tags where !tag.isEmpty {
                        try insertTag.execute(arguments: [key, tag])
                    }
                }
            }
        }
    }

    public func remove(for keys: [String]) async throws {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return }
        try await index.pool.write { database in
            for chunk in cacheChunks(uniqueKeys) {
                let placeholders = cachePlaceholders(chunk.count)
                let arguments = StatementArguments(Array(chunk))
                try database.execute(sql: "DELETE FROM metadata_tags WHERE key IN (\(placeholders))", arguments: arguments)
                try database.execute(sql: "DELETE FROM metadata WHERE key IN (\(placeholders))", arguments: arguments)
            }
        }
    }

    /// 文件改名、移动后元数据（含评分、标签）跟到新 key。
    public func move(_ pairs: [(from: String, to: String, container: Location)]) async throws {
        guard !pairs.isEmpty else { return }
        let encoded = try pairs.map { (from: $0.from, to: $0.to, containerKey: try encodeLocationKey($0.container)) }
        try await index.pool.write { database in
            let existsStatement = try database.makeStatement(sql: "SELECT 1 FROM metadata WHERE key = ?")
            let updateContainer = try database.makeStatement(sql: "UPDATE metadata SET container = ? WHERE key = ?")
            let deleteMetadata = try database.makeStatement(sql: "DELETE FROM metadata WHERE key = ?")
            let deleteTags = try database.makeStatement(sql: "DELETE FROM metadata_tags WHERE key = ?")
            let moveMetadata = try database.makeStatement(sql: "UPDATE metadata SET key = ?, container = ? WHERE key = ?")
            let moveTags = try database.makeStatement(sql: "UPDATE metadata_tags SET key = ? WHERE key = ?")
            for pair in encoded {
                guard try Int.fetchOne(existsStatement, arguments: [pair.from]) != nil else { continue }
                if pair.from == pair.to {
                    try updateContainer.execute(arguments: [pair.containerKey, pair.from])
                } else {
                    try deleteTags.execute(arguments: [pair.to])
                    try deleteMetadata.execute(arguments: [pair.to])
                    try moveMetadata.execute(arguments: [pair.to, pair.containerKey, pair.from])
                    try moveTags.execute(arguments: [pair.to, pair.from])
                }
            }
        }
    }

    private static func fetch(_ database: Database, predicate: String, arguments: StatementArguments) throws -> [String: ImageMetadata] {
        let rows = try Row.fetchCursor(
            database,
            sql: "SELECT key, width, height, frameCount, duration, capturedAt, colorSpace, rating FROM metadata WHERE \(predicate)",
            arguments: arguments
        )
        var result: [String: ImageMetadata] = [:]
        var keys: [String] = []
        while let row = try rows.next() {
            let key: String = row[0]
            let capturedAt: Double? = row[5]
            keys.append(key)
            result[key] = ImageMetadata(
                pixelSize: PixelSize(width: row[1], height: row[2]),
                frameCount: row[3],
                duration: row[4],
                capturedAt: capturedAt.map(Date.init(timeIntervalSince1970:)),
                colorSpace: row[6],
                rating: row[7],
                tags: nil
            )
        }
        guard !keys.isEmpty else { return result }
        var tagsByKey: [String: [String]] = [:]
        for chunk in cacheChunks(keys) {
            let tagRows = try Row.fetchCursor(
                database,
                sql: "SELECT key, tag FROM metadata_tags WHERE key IN (\(cachePlaceholders(chunk.count))) ORDER BY tag",
                arguments: StatementArguments(Array(chunk))
            )
            while let row = try tagRows.next() {
                let key: String = row[0]
                let tag: String = row[1]
                tagsByKey[key, default: []].append(tag)
            }
        }
        for (key, tags) in tagsByKey {
            result[key]?.tags = tags
        }
        return result
    }
}
