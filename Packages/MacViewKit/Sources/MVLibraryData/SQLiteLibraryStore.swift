import Foundation
import GRDB
import MVFoundation
import Synchronization

public final class SQLiteLibraryStore: LibraryStore {
    let database: LibraryDatabase
    private let historyLimit: Mutex<Int>
    private let observers = Mutex<[UUID: AsyncStream<LibraryChange>.Continuation]>([:])

    public init(databaseURL: URL, historyLimit: Int) throws {
        guard historyLimit > 0 else { throw Self.invalidLimit() }
        database = try LibraryDatabase(url: databaseURL)
        self.historyLimit = Mutex(historyLimit)
        try database.write { try Self.trimHistory($0, limit: historyLimit) }
    }

    deinit { observers.withLock { $0.values.forEach { $0.finish() } } }

    public func flush() async throws {
        try await database.queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(FULL)") }
    }

    public func history() async throws -> [HistoryEntry] {
        try database.read { database in
            try Row.fetchAll(database, sql: "SELECT location, opened_at FROM history ORDER BY opened_at DESC, location").map {
                HistoryEntry(book: try Self.location($0), openedAt: Date(timeIntervalSince1970: $0["opened_at"]))
            }
        }
    }

    public func recordOpened(_ book: Location, at date: Date) async throws {
        try write([.history]) { database in
            try database.execute(sql: "INSERT INTO history (location, prefix_key, opened_at) VALUES (?, ?, ?) "
                + "ON CONFLICT(location) DO UPDATE SET opened_at = excluded.opened_at",
                arguments: [try LibraryDatabase.key(book), book.prefixKey, date.timeIntervalSince1970])
            try Self.trimHistory(database, limit: historyLimit.withLock { $0 })
        }
    }

    public func removeHistory(_ books: [Location]) async throws {
        guard !books.isEmpty else { return }
        try write([.history]) { database in
            let statement = try database.makeStatement(sql: "DELETE FROM history WHERE location = ?")
            for book in books { try statement.execute(arguments: [try LibraryDatabase.key(book)]) }
        }
    }

    public func clearHistory() async throws {
        try write([.history]) { try $0.execute(sql: "DELETE FROM history") }
    }

    public func setHistoryLimit(_ limit: Int) async throws {
        guard limit > 0 else { throw Self.invalidLimit() }
        try write([.history]) { database in
            try Self.trimHistory(database, limit: limit)
            historyLimit.withLock { $0 = limit }
        }
    }

    public func bookmarks() async throws -> [BookmarkNode] {
        try database.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM bookmark ORDER BY position, id")
            let children = Dictionary(grouping: rows) { $0["parent"] as String? }
            func nodes(in parent: String?) throws -> [BookmarkNode] {
                try (children[parent] ?? []).map { row in
                    let raw = try Self.uuid(row["id"])
                    let id = BookmarkID(raw: raw)
                    if row["kind"] as String == "folder" {
                        return .folder(id: id, name: row["name"], children: try nodes(in: raw.uuidString))
                    }
                    return .book(id: id, location: try Self.location(row), label: row["name"])
                }
            }
            return try nodes(in: nil)
        }
    }

    public func addBookmarks(_ books: [Location], into folder: BookmarkID?, at index: Int?) async throws -> AddReport {
        try write([.bookmarks]) { database in
            try Self.requireFolder(folder, database)
            var order = try Self.bookmarkOrder(folder, database)
            var added: [String] = []
            var duplicates = 0
            for book in books {
                let key = try LibraryDatabase.key(book)
                if try String.fetchOne(database, sql: "SELECT id FROM bookmark WHERE location = ?", arguments: [key]) != nil {
                    duplicates += 1
                    continue
                }
                let id = UUID().uuidString
                try database.execute(sql: "INSERT INTO bookmark (id, parent, position, kind, location, prefix_key) VALUES (?, ?, 0, 'book', ?, ?)",
                                     arguments: [id, folder?.raw.uuidString, key, book.prefixKey])
                added.append(id)
            }
            order.insert(contentsOf: added, at: Self.index(index ?? order.count, count: order.count))
            try Self.orderBookmarks(order, database)
            return AddReport(added: added.count, alreadyPresent: duplicates)
        }
    }

    public func addBookmarkFolder(named name: String, into folder: BookmarkID?, at index: Int?) async throws -> BookmarkID {
        let name = try Self.name(name)
        return try write([.bookmarks]) { database in
            try Self.requireFolder(folder, database)
            let id = BookmarkID()
            var order = try Self.bookmarkOrder(folder, database)
            try database.execute(sql: "INSERT INTO bookmark (id, parent, position, kind, name) VALUES (?, ?, 0, 'folder', ?)",
                                 arguments: [id.raw.uuidString, folder?.raw.uuidString, name])
            order.insert(id.raw.uuidString, at: Self.index(index ?? order.count, count: order.count))
            try Self.orderBookmarks(order, database)
            return id
        }
    }

    public func moveBookmarks(_ ids: [BookmarkID], into folder: BookmarkID?, at index: Int) async throws {
        guard !ids.isEmpty else { return }
        try write([.bookmarks]) { database in
            try Self.requireFolder(folder, database)
            let rows = try Row.fetchAll(database, sql: "SELECT id, parent FROM bookmark")
            let parents: [String: String?] = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["parent"] as String?) })
            let selected = Set(ids.map { $0.raw.uuidString })
            for id in selected where parents.index(forKey: id) == nil { throw LibraryError.notFound }
            var ancestor = folder?.raw.uuidString
            while let id = ancestor {
                guard !selected.contains(id) else { throw LibraryError.intoItself }
                ancestor = parents[id] ?? nil
            }
            var seen: Set<String> = []
            let moving = ids.map { $0.raw.uuidString }.filter { id in
                guard seen.insert(id).inserted else { return false }
                var parent = parents[id] ?? nil
                while let current = parent {
                    if selected.contains(current) { return false }
                    parent = parents[current] ?? nil
                }
                return true
            }
            let movingSet = Set(moving)
            var order = try Self.bookmarkOrder(folder, database).filter { !movingSet.contains($0) }
            order.insert(contentsOf: moving, at: Self.index(index, count: order.count))
            let oldParents = Set(moving.map { parents[$0] ?? nil })
            for id in moving {
                try database.execute(sql: "UPDATE bookmark SET parent = ? WHERE id = ?", arguments: [folder?.raw.uuidString, id])
            }
            for parent in oldParents where parent != folder?.raw.uuidString {
                let parentID = try parent.map { BookmarkID(raw: try Self.uuid($0)) }
                try Self.orderBookmarks(Self.bookmarkOrder(parentID, database), database)
            }
            try Self.orderBookmarks(order, database)
        }
    }

    public func renameBookmark(_ id: BookmarkID, to name: String?) async throws {
        try write([.bookmarks]) { database in
            guard let kind = try String.fetchOne(database, sql: "SELECT kind FROM bookmark WHERE id = ?", arguments: [id.raw.uuidString]) else {
                throw LibraryError.notFound
            }
            let name = kind == "folder" ? try Self.name(name ?? "") : name
            try database.execute(sql: "UPDATE bookmark SET name = ? WHERE id = ?", arguments: [name, id.raw.uuidString])
        }
    }

    public func removeBookmarks(_ ids: [BookmarkID]) async throws {
        guard !ids.isEmpty else { return }
        try write([.bookmarks]) { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id, parent FROM bookmark")
            let parents = Set(rows.map { $0["parent"] as String? })
            for id in ids { try database.execute(sql: "DELETE FROM bookmark WHERE id = ?", arguments: [id.raw.uuidString]) }
            for parent in parents {
                let parentID = try parent.map { BookmarkID(raw: try Self.uuid($0)) }
                try Self.orderBookmarks(Self.bookmarkOrder(parentID, database), database)
            }
        }
    }

    public func playlists() async throws -> [PlaylistSummary] {
        try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT p.*, (SELECT COUNT(*) FROM playlist_item i WHERE i.playlist = p.id) AS count
                FROM playlist p ORDER BY position, id
                """).map { row in
                    PlaylistSummary(id: try Self.uuid(row["id"]), name: row["name"], count: row["count"],
                                    lastUsedAt: (row["last_used_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
                }
        }
    }

    public func createPlaylist(named name: String) async throws -> UUID {
        let name = try Self.name(name)
        return try write([.playlists]) { database in
            let id = UUID()
            try database.execute(sql: "INSERT INTO playlist (id, name, position) VALUES (?, ?, (SELECT COUNT(*) FROM playlist))",
                                 arguments: [id.uuidString, name])
            return id
        }
    }

    public func renamePlaylist(_ id: UUID, to name: String) async throws {
        let name = try Self.name(name)
        try write([.playlists]) { database in
            try Self.requirePlaylist(id, database)
            try database.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
        }
    }

    public func deletePlaylist(_ id: UUID) async throws {
        try write([.playlists, .history, .playlistRemoved(id)]) { database in
            try Self.requirePlaylist(id, database)
            try database.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id.uuidString])
            try database.execute(sql: "DELETE FROM history WHERE location = ?", arguments: [try LibraryDatabase.key(.playlist(id))])
            try Self.orderPlaylists(String.fetchAll(database, sql: "SELECT id FROM playlist ORDER BY position, id"), database)
        }
    }

    public func movePlaylist(_ id: UUID, to index: Int) async throws {
        try write([.playlists]) { database in
            try Self.requirePlaylist(id, database)
            var ids = try String.fetchAll(database, sql: "SELECT id FROM playlist WHERE id != ? ORDER BY position, id", arguments: [id.uuidString])
            ids.insert(id.uuidString, at: Self.index(index, count: ids.count))
            try Self.orderPlaylists(ids, database)
        }
    }

    public func items(of playlist: UUID) async throws -> [Entry] {
        try database.read { database in
            try Self.requirePlaylist(playlist, database)
            let decoder = JSONDecoder()
            return try Data.fetchAll(database, sql: "SELECT entry FROM playlist_item WHERE playlist = ? ORDER BY position", arguments: [playlist.uuidString])
                .map { try decoder.decode(Entry.self, from: $0) }
        }
    }

    public func addItems(_ entries: [Entry], to playlist: UUID) async throws -> AddReport {
        try write([.playlists, .items(playlist)]) { database in
            try Self.requirePlaylist(playlist, database)
            var position = try Int.fetchOne(database, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM playlist_item WHERE playlist = ?", arguments: [playlist.uuidString]) ?? 0
            var added = 0
            let statement = try database.makeStatement(sql: "INSERT OR IGNORE INTO playlist_item (playlist, position, location, prefix_key, entry) VALUES (?, ?, ?, ?, ?)")
            for entry in entries {
                try statement.execute(arguments: [playlist.uuidString, position, try LibraryDatabase.key(entry.location), entry.location.prefixKey, try LibraryDatabase.encode(entry)])
                if database.changesCount > 0 { added += 1; position += 1 }
            }
            if !entries.isEmpty {
                try database.execute(sql: "UPDATE playlist SET last_used_at = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, playlist.uuidString])
            }
            return AddReport(added: added, alreadyPresent: entries.count - added)
        }
    }

    public func moveItems(_ locations: [Location], in playlist: UUID, to index: Int) async throws {
        guard !locations.isEmpty else { return }
        try write([.items(playlist)]) { database in
            try Self.requirePlaylist(playlist, database)
            let rows = try Row.fetchAll(database, sql: "SELECT location, position FROM playlist_item WHERE playlist = ? ORDER BY position", arguments: [playlist.uuidString])
            let selected = try Set(locations.map(LibraryDatabase.key))
            let moving: [String] = rows.compactMap { row in
                let key: String = row["location"]
                return selected.contains(key) ? key : nil
            }
            var order: [String] = rows.compactMap { row in
                let key: String = row["location"]
                return selected.contains(key) ? nil : key
            }
            order.insert(contentsOf: moving, at: Self.index(index, count: order.count))
            try Self.orderItems(order, in: playlist, database)
        }
    }

    public func removeItems(_ locations: [Location], from playlist: UUID) async throws {
        guard !locations.isEmpty else { return }
        try write([.playlists, .items(playlist)]) { database in
            try Self.requirePlaylist(playlist, database)
            let statement = try database.makeStatement(sql: "DELETE FROM playlist_item WHERE playlist = ? AND location = ?")
            for location in locations { try statement.execute(arguments: [playlist.uuidString, try LibraryDatabase.key(location)]) }
            let order = try String.fetchAll(database, sql: "SELECT location FROM playlist_item WHERE playlist = ? ORDER BY position", arguments: [playlist.uuidString])
            try Self.orderItems(order, in: playlist, database)
        }
    }

    public func updateSnapshots(_ entries: [Entry], in playlist: UUID) async throws {
        try database.write { database in
            try Self.requirePlaylist(playlist, database)
            let statement = try database.makeStatement(sql: "UPDATE playlist_item SET entry = ? WHERE playlist = ? AND location = ?")
            for entry in entries {
                try statement.execute(arguments: [try LibraryDatabase.encode(entry), playlist.uuidString, try LibraryDatabase.key(entry.location)])
            }
        }
    }

    public func recentPlaylist() async throws -> UUID? {
        try database.read { database in
            try String.fetchOne(database, sql: "SELECT id FROM playlist WHERE last_used_at IS NOT NULL ORDER BY last_used_at DESC, position LIMIT 1").map(Self.uuid)
        }
    }

    public func apply(_ changes: [FileChange]) async throws {
        guard changes.contains(where: { if case .moved = $0 { true } else { false } }) else { return }
        try write([.relocated]) { database in
            for change in changes {
                guard case let .moved(from, to) = change else { continue }
                for table in ["history", "bookmark", "playlist_item"] {
                    let key = from.prefixKey
                    let rows = try Row.fetchAll(database, sql: "SELECT rowid AS identity, * FROM \(table) WHERE prefix_key = ? OR (prefix_key >= ? AND prefix_key < ?)",
                                                arguments: [key, key + "/", key + "0"])
                    for row in rows {
                        let old = try Self.location(row)
                        guard old.hasPrefix(from) else { continue }
                        let location = Self.relocate(old, from: from, to: to.location)
                        let targetKey = try LibraryDatabase.key(location)
                        let identity: Int64 = row["identity"]
                        let conflictSQL = "SELECT rowid AS identity, * FROM \(table) WHERE location = ? AND rowid != ?"
                            + (table == "playlist_item" ? " AND playlist = ?" : "")
                        var arguments: StatementArguments = [targetKey, identity]
                        if table == "playlist_item" { arguments += [row["playlist"] as String] }
                        if let target = try Row.fetchOne(database, sql: conflictSQL, arguments: arguments) {
                            if table == "history" {
                                try database.execute(sql: "UPDATE history SET opened_at = MAX(opened_at, ?) WHERE rowid = ?",
                                                     arguments: [row["opened_at"] as Double, target["identity"] as Int64])
                            }
                            try database.execute(sql: "DELETE FROM \(table) WHERE rowid = ?", arguments: [identity])
                        } else if table == "playlist_item" {
                            var entry = try JSONDecoder().decode(Entry.self, from: row["entry"] as Data)
                            if old == from { entry = to }
                            else { entry.identity.location = location; entry.name = location.name }
                            try database.execute(sql: "UPDATE playlist_item SET location = ?, prefix_key = ?, entry = ? WHERE rowid = ?",
                                                 arguments: [targetKey, location.prefixKey, try LibraryDatabase.encode(entry), identity])
                        } else {
                            try database.execute(sql: "UPDATE \(table) SET location = ?, prefix_key = ? WHERE rowid = ?",
                                                 arguments: [targetKey, location.prefixKey, identity])
                        }
                    }
                }
            }
        }
    }

    public func changes() -> AsyncStream<LibraryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.observers.withLock { _ = $0.removeValue(forKey: id) } }
        observers.withLock { $0[id] = continuation }
        return stream
    }

    private func write<T>(_ changes: [LibraryChange], _ body: (Database) throws -> T) throws -> T {
        let result = try database.write(body)
        observers.withLock { observers in
            for change in changes { for observer in observers.values { observer.yield(change) } }
        }
        return result
    }

    private static func name(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidName }
        return name
    }

    private static func invalidLimit() -> NSError {
        NSError(domain: "MacView.LibraryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "历史上限必须为正数"])
    }

    private static func index(_ index: Int, count: Int) -> Int { min(max(0, index), count) }

    private static func uuid(_ string: String) throws -> UUID {
        guard let id = UUID(uuidString: string) else { throw LibraryError.notFound }
        return id
    }

    private static func location(_ row: Row) throws -> Location {
        try JSONDecoder().decode(Location.self, from: Data((row["location"] as String).utf8))
    }

    private static func trimHistory(_ database: Database, limit: Int) throws {
        try database.execute(sql: "DELETE FROM history WHERE location IN (SELECT location FROM history ORDER BY opened_at DESC, location LIMIT -1 OFFSET ?)", arguments: [limit])
    }

    private static func requireFolder(_ folder: BookmarkID?, _ database: Database) throws {
        guard let folder else { return }
        guard try String.fetchOne(database, sql: "SELECT kind FROM bookmark WHERE id = ?", arguments: [folder.raw.uuidString]) == "folder" else {
            throw LibraryError.notFound
        }
    }

    private static func requirePlaylist(_ playlist: UUID, _ database: Database) throws {
        guard try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM playlist WHERE id = ?)", arguments: [playlist.uuidString]) == true else {
            throw LibraryError.notFound
        }
    }

    private static func bookmarkOrder(_ folder: BookmarkID?, _ database: Database) throws -> [String] {
        try String.fetchAll(database, sql: "SELECT id FROM bookmark WHERE parent IS ? ORDER BY position, id", arguments: [folder?.raw.uuidString])
    }

    private static func orderBookmarks(_ ids: [String], _ database: Database) throws {
        let statement = try database.makeStatement(sql: "UPDATE bookmark SET position = ? WHERE id = ? AND position != ?")
        for (index, id) in ids.enumerated() { try statement.execute(arguments: [index, id, index]) }
    }

    private static func orderPlaylists(_ ids: [String], _ database: Database) throws {
        let statement = try database.makeStatement(sql: "UPDATE playlist SET position = ? WHERE id = ? AND position != ?")
        for (index, id) in ids.enumerated() { try statement.execute(arguments: [index, id, index]) }
    }

    private static func orderItems(_ keys: [String], in playlist: UUID, _ database: Database) throws {
        let statement = try database.makeStatement(sql: "UPDATE playlist_item SET position = ? WHERE playlist = ? AND location = ? AND position != ?")
        for (index, key) in keys.enumerated() { try statement.execute(arguments: [index, playlist.uuidString, key, index]) }
    }

    private static func relocate(_ location: Location, from: Location, to: Location) -> Location {
        let sourceLayers = from.layers.isEmpty ? [[]] : from.layers
        let originalLayers = location.layers.isEmpty ? [[]] : location.layers
        let last = sourceLayers.count - 1
        var layers = to.layers.isEmpty ? [[]] : to.layers
        layers[layers.count - 1].append(contentsOf: originalLayers[last].dropFirst(sourceLayers[last].count))
        layers.append(contentsOf: originalLayers.dropFirst(last + 1))
        return Location(root: to.root, layers: layers)
    }
}
