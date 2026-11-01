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
        let key = try locationKey(container)
        let data = try await index.pool.read { database in
            try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [key])
        }
        return try data.map { try DirectoryListingStorage.decode($0) }
    }

    public func update(_ container: Location, listing: DirectoryListing) async throws -> ListingDiff {
        let key = try locationKey(container)
        let encoded = try DirectoryListingStorage.encode(listing)
        return try await index.pool.write { database in
            let previousData = try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [key])
            let previous = try previousData.map { try DirectoryListingStorage.decode($0) }
            try database.execute(sql: "INSERT INTO directory_listings(location, value) VALUES (?, ?) ON CONFLICT(location) DO UPDATE SET value = excluded.value", arguments: [key, encoded])
            let old = Dictionary((previous?.entries ?? []).map { ($0.location, $0) }, uniquingKeysWith: { _, last in last })
            let locations = Set(listing.entries.map(\.location))
            return ListingDiff(
                added: listing.entries.filter { old[$0.location] == nil },
                removed: (previous?.entries ?? []).map(\.location).filter { !locations.contains($0) },
                changed: listing.entries.filter { entry in old[entry.location].map { $0.identity != entry.identity } ?? false }
            )
        }
    }

    private func locationKey(_ location: Location) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(location)
    }
}
