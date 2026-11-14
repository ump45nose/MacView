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

    /// 只更新已有的目录缓存；同一个目录的变更在一次数据库事务中顺序应用。
    public func apply(_ changes: [FileChange]) async throws {
        enum Mutation: Sendable { case remove(Location), add(Entry) }
        var groups: [Location: [Mutation]] = [:]
        for change in changes {
            switch change {
            case let .added(entry):
                if let parent = entry.location.parent { groups[parent, default: []].append(.add(entry)) }
            case let .removed(location):
                if let parent = location.parent { groups[parent, default: []].append(.remove(location)) }
            case let .moved(from, to):
                if let parent = from.parent { groups[parent, default: []].append(.remove(from)) }
                if let parent = to.location.parent { groups[parent, default: []].append(.add(to)) }
            }
        }
        let items = try groups.map { (try locationKey($0.key), $0.value) }
        try await index.pool.write { database in
            for (key, mutations) in items {
                guard let data = try Data.fetchOne(database, sql: "SELECT value FROM directory_listings WHERE location = ?", arguments: [key]) else { continue }
                var listing = try DirectoryListingStorage.decode(data)
                for mutation in mutations {
                    switch mutation {
                    case let .remove(location): listing.entries.removeAll { $0.location == location }
                    case let .add(entry):
                        listing.entries.removeAll { $0.location == entry.location }
                        listing.entries.append(entry)
                    }
                }
                try database.execute(sql: "UPDATE directory_listings SET value = ? WHERE location = ?", arguments: [try DirectoryListingStorage.encode(listing), key])
            }
        }
    }

    private func locationKey(_ location: Location) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(location)
    }
}
