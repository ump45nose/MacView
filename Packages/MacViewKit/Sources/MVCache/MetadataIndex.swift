import Foundation
import GRDB
import MVFoundation

/// 定长列保存图片元数据，按所属容器一次取回。
public final class MetadataIndex: Sendable {
    private let index: CacheIndex
    public init(index: CacheIndex) { self.index = index }

    public func values(in container: Location) async throws -> [String: ImageMetadata] {
        let key = try Self.containerKey(container)
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
        let containerKey = try Self.containerKey(container)
        try await index.pool.write { database in
            let statement = try database.makeStatement(sql: """
                INSERT INTO metadata(key, container, width, height, frameCount, duration, capturedAt, colorSpace)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET container = excluded.container, width = excluded.width,
                    height = excluded.height, frameCount = excluded.frameCount, duration = excluded.duration,
                    capturedAt = excluded.capturedAt, colorSpace = excluded.colorSpace
                """)
            for (key, value) in values {
                try statement.execute(arguments: [key, containerKey, value.pixelSize.width, value.pixelSize.height,
                    value.frameCount, value.duration, value.capturedAt?.timeIntervalSince1970, value.colorSpace])
            }
        }
    }

    private static func fetch(_ database: Database, predicate: String, arguments: StatementArguments) throws -> [String: ImageMetadata] {
        let rows = try Row.fetchCursor(database, sql: "SELECT key, width, height, frameCount, duration, capturedAt, colorSpace FROM metadata WHERE \(predicate)", arguments: arguments)
        var result: [String: ImageMetadata] = [:]
        while let row = try rows.next() {
            let capturedAt: Double? = row[5]
            result[row[0]] = ImageMetadata(pixelSize: PixelSize(width: row[1], height: row[2]), frameCount: row[3],
                duration: row[4], capturedAt: capturedAt.map(Date.init(timeIntervalSince1970:)), colorSpace: row[6])
        }
        return result
    }

    private static func containerKey(_ container: Location) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(container)
    }
}
