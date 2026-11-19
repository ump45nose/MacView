import Foundation
import GRDB
import MVFoundation

public struct DirectoryListing: Codable, Sendable, Hashable {
    public var entries: [Entry]
    public var directoryModificationNanos: Int64?

    public init(entries: [Entry], directoryModificationNanos: Int64? = nil) {
        self.entries = entries
        self.directoryModificationNanos = directoryModificationNanos
    }
}

public struct ListingDiff: Sendable, Hashable {
    public var added: [Entry]
    public var removed: [Location]
    public var changed: [Entry]

    public init(added: [Entry], removed: [Location], changed: [Entry]) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }
}

public final class DirectoryCache: Sendable {
    private let index: CacheIndex
    public init(index: CacheIndex) { self.index = index }

    public func cachedChildren(of container: Location) async throws -> DirectoryListing? {
        let key = try encodeLocationKey(container)
        let data = try await index.pool.read { database in
            try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [key])
        }
        return try data.map { try DirectoryListingStorage.decode($0) }
    }

    public func update(_ container: Location, listing: DirectoryListing) async throws -> ListingDiff {
        let containerKey = try encodeLocationKey(container)
        let encoded = try DirectoryListingStorage.encode(listing)
        return try await index.pool.write { database in
            let previousData = try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [containerKey])
            let previous = try previousData.map { try DirectoryListingStorage.decode($0) }
            try database.execute(
                sql: "INSERT INTO directory_listings(location, value) VALUES (?, ?) ON CONFLICT(location) DO UPDATE SET value = excluded.value",
                arguments: [containerKey, encoded]
            )
            let old = Dictionary((previous?.entries ?? []).map { ($0.location, $0) }, uniquingKeysWith: { _, last in last })
            let locations = Set(listing.entries.map(\.location))
            let removed = (previous?.entries ?? []).map(\.location).filter { !locations.contains($0) }

            let deleteSearch = try database.makeStatement(sql: "DELETE FROM search_entries WHERE location = ?")
            for removedLocation in removed {
                let removedKey = try encodeLocationKey(removedLocation)
                try deleteSearch.execute(arguments: [removedKey])
                if let previousEntry = old[removedLocation], Self.isContainerKind(previousEntry.kind) {
                    try Self.removeSubtree(under: removedLocation, key: removedKey, in: database)
                }
            }

            let upsertSearch = try Self.makeUpsertSearchStatement(in: database)
            for entry in listing.entries {
                try Self.upsertSearchEntry(entry, containerKey: containerKey, statement: upsertSearch)
            }

            return ListingDiff(
                added: listing.entries.filter { old[$0.location] == nil },
                removed: removed,
                changed: listing.entries.filter { entry in old[entry.location].map { $0.identity != entry.identity } ?? false }
            )
        }
    }

    /// 只更新已有的目录缓存，并在同一事务里维护 `search_entries`。
    public func apply(_ changes: [FileChange]) async throws {
        guard !changes.isEmpty else { return }
        try await index.pool.write { database in
            var listingCache: [Data: DirectoryListing?] = [:]
            var dirtyListings: Set<Data> = []
            let upsertSearch = try Self.makeUpsertSearchStatement(in: database)
            let deleteSearch = try database.makeStatement(sql: "DELETE FROM search_entries WHERE location = ?")

            func cachedListing(for containerKey: Data) throws -> DirectoryListing? {
                if let cached = listingCache[containerKey] { return cached }
                let data = try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [containerKey])
                let decoded = try data.map { try DirectoryListingStorage.decode($0) }
                listingCache[containerKey] = decoded
                return decoded
            }

            func flushDirtyListings() throws {
                guard !dirtyListings.isEmpty else { return }
                let updateStatement = try database.makeStatement(sql: "UPDATE directory_listings SET value = ? WHERE location = ?")
                for key in dirtyListings {
                    if let listing = listingCache[key] ?? nil {
                        try updateStatement.execute(arguments: [try DirectoryListingStorage.encode(listing), key])
                    }
                }
                dirtyListings.removeAll()
            }

            for change in changes {
                switch change {
                case let .added(entry), let .rewritten(entry, _, _):
                    guard let parent = entry.location.parent else { continue }
                    let parentKey = try encodeLocationKey(parent)
                    guard var listing = try cachedListing(for: parentKey) else { continue }
                    listing.entries.removeAll { $0.location == entry.location }
                    listing.entries.append(entry)
                    listingCache[parentKey] = listing
                    dirtyListings.insert(parentKey)
                    try Self.upsertSearchEntry(entry, containerKey: parentKey, statement: upsertSearch)

                case let .removed(location):
                    try flushDirtyListings()
                    let locationKey = try encodeLocationKey(location)
                    if let parent = location.parent {
                        let parentKey = try encodeLocationKey(parent)
                        if var listing = try cachedListing(for: parentKey) {
                            listing.entries.removeAll { $0.location == location }
                            listingCache[parentKey] = listing
                            dirtyListings.insert(parentKey)
                        }
                    }
                    try deleteSearch.execute(arguments: [locationKey])
                    let removedContainers = try Self.removeSubtree(under: location, key: locationKey, in: database)
                    for containerKey in removedContainers {
                        listingCache.removeValue(forKey: containerKey)
                        dirtyListings.remove(containerKey)
                    }

                case let .moved(from, to):
                    try flushDirtyListings()
                    let fromKey = try encodeLocationKey(from)
                    if let fromParent = from.parent {
                        let fromParentKey = try encodeLocationKey(fromParent)
                        if var listing = try cachedListing(for: fromParentKey) {
                            listing.entries.removeAll { $0.location == from }
                            listingCache[fromParentKey] = listing
                            dirtyListings.insert(fromParentKey)
                        }
                    }
                    try deleteSearch.execute(arguments: [fromKey])

                    if let toParent = to.location.parent {
                        let toParentKey = try encodeLocationKey(toParent)
                        if var listing = try cachedListing(for: toParentKey) {
                            listing.entries.removeAll { $0.location == to.location }
                            listing.entries.append(to)
                            listingCache[toParentKey] = listing
                            dirtyListings.insert(toParentKey)
                            try Self.upsertSearchEntry(to, containerKey: toParentKey, statement: upsertSearch)
                        }
                    }

                    try flushDirtyListings()
                    if try Self.moveSubtree(from: from, fromKey: fromKey, to: to.location, in: database) {
                        listingCache.removeAll()
                        dirtyListings.removeAll()
                    }
                }
            }

            try flushDirtyListings()
        }
    }

    private static func isContainerKind(_ kind: EntryKind) -> Bool {
        switch kind {
        case .directory, .archive: true
        case .image, .video, .other: false
        }
    }

    private static func makeUpsertSearchStatement(in database: Database) throws -> Statement {
        try database.makeStatement(sql: """
            INSERT INTO search_entries(location, container, prefix, name, kind, cacheKey)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(location) DO UPDATE SET container = excluded.container, prefix = excluded.prefix,
                name = excluded.name, kind = excluded.kind, cacheKey = excluded.cacheKey
            """)
    }

    private static func upsertSearchEntry(_ entry: Entry, containerKey: Data, statement: Statement) throws {
        try statement.execute(arguments: [
            try encodeLocationKey(entry.location),
            containerKey,
            entry.location.prefixKey,
            normalizedSearchText(entry.name),
            searchKindValue(for: entry.kind),
            entry.identity.cacheKey
        ])
    }

    @discardableResult
    private static func removeSubtree(under location: Location, key locationKey: Data, in database: Database) throws -> Set<Data> {
        let (lower, upper) = prefixRange(under: location)
        var containers = Set(try Data.fetchAll(
            database,
            sql: "SELECT DISTINCT container FROM search_entries WHERE prefix >= ? AND prefix < ?",
            arguments: [lower, upper]
        ))
        containers.insert(locationKey)
        try database.execute(sql: "DELETE FROM search_entries WHERE prefix >= ? AND prefix < ?", arguments: [lower, upper])
        for chunk in cacheChunks(Array(containers)) {
            try database.execute(
                sql: "DELETE FROM directory_listings WHERE location IN (\(cachePlaceholders(chunk.count)))",
                arguments: StatementArguments(Array(chunk))
            )
        }
        return containers
    }

    /// 移动目录（或压缩包）下全部已索引行和目录缓存。返回是否有子树被移动。
    private static func moveSubtree(from oldRoot: Location, fromKey: Data, to newRoot: Location, in database: Database) throws -> Bool {
        guard oldRoot != newRoot else { return false }
        let (lower, upper) = prefixRange(under: oldRoot)
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT location, container, name, kind, cacheKey FROM search_entries WHERE prefix >= ? AND prefix < ?",
            arguments: [lower, upper]
        )
        let hasRootListing = try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM directory_listings WHERE location = ?)",
            arguments: [fromKey]
        ) ?? false
        guard !rows.isEmpty || hasRootListing else { return false }

        var oldContainerKeys = Set<Data>()
        oldContainerKeys.insert(fromKey)
        for row in rows {
            let containerKey: Data = row[1]
            oldContainerKeys.insert(containerKey)
        }

        var updatedListings: [(newKey: Data, data: Data)] = []
        var updatedCacheKeys: [Location: String] = [:]
        var oldKeysToDelete: [Data] = []

        for oldContainerKey in oldContainerKeys {
            guard let data = try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [oldContainerKey]) else {
                continue
            }
            let oldContainer = try decodeLocationKey(oldContainerKey)
            let newContainer = oldContainer.replacingPrefix(oldRoot, with: newRoot) ?? oldContainer
            var listing = try DirectoryListingStorage.decode(data)
            for index in listing.entries.indices {
                let oldEntryLocation = listing.entries[index].identity.location
                let updatedLocation = oldEntryLocation.replacingPrefix(oldRoot, with: newRoot) ?? oldEntryLocation
                listing.entries[index].identity.location = updatedLocation
                updatedCacheKeys[updatedLocation] = listing.entries[index].identity.cacheKey
            }
            oldKeysToDelete.append(oldContainerKey)
            updatedListings.append((try encodeLocationKey(newContainer), try DirectoryListingStorage.encode(listing)))
        }

        for chunk in cacheChunks(oldKeysToDelete) {
            try database.execute(
                sql: "DELETE FROM directory_listings WHERE location IN (\(cachePlaceholders(chunk.count)))",
                arguments: StatementArguments(Array(chunk))
            )
        }
        let upsertListing = try database.makeStatement(sql: """
            INSERT INTO directory_listings(location, value) VALUES (?, ?)
            ON CONFLICT(location) DO UPDATE SET value = excluded.value
            """)
        for item in updatedListings {
            try upsertListing.execute(arguments: [item.newKey, item.data])
        }

        if !rows.isEmpty {
            try database.execute(sql: "DELETE FROM search_entries WHERE prefix >= ? AND prefix < ?", arguments: [lower, upper])
            let upsertSearch = try makeUpsertSearchStatement(in: database)
            for row in rows {
                let oldLocation = try decodeLocationKey(row[0])
                let oldContainer = try decodeLocationKey(row[1])
                let newLocation = oldLocation.replacingPrefix(oldRoot, with: newRoot) ?? oldLocation
                let newContainer = oldContainer.replacingPrefix(oldRoot, with: newRoot) ?? oldContainer
                let name: String = row[2]
                let kind: String = row[3]
                let fallbackCacheKey: String = row[4]
                let cacheKey = updatedCacheKeys[newLocation] ?? fallbackCacheKey
                try upsertSearch.execute(arguments: [
                    try encodeLocationKey(newLocation),
                    try encodeLocationKey(newContainer),
                    newLocation.prefixKey,
                    name,
                    kind,
                    cacheKey
                ])
            }
        }

        return true
    }
}
