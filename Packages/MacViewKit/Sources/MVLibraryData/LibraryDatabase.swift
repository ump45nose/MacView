import Foundation
import GRDB

/// 所有改动经同一写队列提交；不在内存中常驻列表项。
final class LibraryDatabase: Sendable {
    let queue: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            var deadline: ContinuousClock.Instant?
            while true {
                do {
                    try database.execute(sql: "PRAGMA journal_mode = WAL")
                    break
                } catch let error as DatabaseError {
                    guard error.resultCode == .SQLITE_BUSY else { throw error }
                    let now = ContinuousClock.now
                    let retryDeadline = deadline ?? now + .seconds(5)
                    deadline = retryDeadline
                    guard now.duration(to: retryDeadline) >= .milliseconds(20) else { throw error }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        queue = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("library-v1") { database in
            try database.execute(sql: """
                CREATE TABLE history (location TEXT PRIMARY KEY NOT NULL, prefix_key TEXT NOT NULL, opened_at DOUBLE NOT NULL);
                CREATE INDEX history_prefix ON history(prefix_key);
                CREATE INDEX history_opened ON history(opened_at);
                CREATE TABLE bookmark (id TEXT PRIMARY KEY NOT NULL, parent TEXT REFERENCES bookmark(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('folder', 'book')), name TEXT,
                    location TEXT UNIQUE, prefix_key TEXT);
                CREATE INDEX bookmark_order ON bookmark(parent, position);
                CREATE INDEX bookmark_prefix ON bookmark(prefix_key);
                CREATE TABLE playlist (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL, last_used_at DOUBLE);
                CREATE INDEX playlist_order ON playlist(position);
                CREATE TABLE playlist_item (playlist TEXT NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, location TEXT NOT NULL, prefix_key TEXT NOT NULL, entry BLOB NOT NULL,
                    UNIQUE(playlist, location));
                CREATE INDEX item_order ON playlist_item(playlist, position);
                CREATE INDEX item_prefix ON playlist_item(prefix_key);
                """)
        }
        try migrator.migrate(queue)
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    func write<T>(_ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func key(_ location: Location) throws -> String {
        String(decoding: try encode(location), as: UTF8.self)
    }
}
