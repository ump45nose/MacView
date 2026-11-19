import Foundation
import GRDB
import MVFoundation

public enum SearchKind: String, Sendable, Codable {
    case image, video, archive, directory
}

public struct SearchQuery: Sendable, Hashable {
    /// 已按空白拆分；空数组表示只按筛选。
    public var terms: [String]
    /// 该位置及以下。
    public var scope: Location
    /// 1–5；0 表示“未评分”。
    public var minimumRating: Int?
    /// 全部命中。
    public var tags: [String]
    /// 空表示全部。
    public var kinds: Set<SearchKind>
    /// 默认 5000。
    public var limit: Int

    public init(
        terms: [String] = [],
        scope: Location,
        minimumRating: Int? = nil,
        tags: [String] = [],
        kinds: Set<SearchKind> = [],
        limit: Int = 5000
    ) {
        self.terms = terms
        self.scope = scope
        self.minimumRating = minimumRating
        self.tags = tags
        self.kinds = kinds
        self.limit = limit
    }
}

public struct SearchHit: Sendable, Hashable {
    public var entry: Entry
    public var rating: Int?
    public var tags: [String]?

    public init(entry: Entry, rating: Int? = nil, tags: [String]? = nil) {
        self.entry = entry
        self.rating = rating
        self.tags = tags
    }
}

public struct SearchResult: Sendable {
    public var hits: [SearchHit]
    public var truncated: Bool
    /// `scope` 下已索引条目数。
    public var indexedCount: Int

    public init(hits: [SearchHit], truncated: Bool, indexedCount: Int) {
        self.hits = hits
        self.truncated = truncated
        self.indexedCount = indexedCount
    }
}

public final class SearchCatalog: Sendable {
    private let index: CacheIndex

    public init(index: CacheIndex) {
        self.index = index
    }

    public func indexedCount(under scope: Location) async throws -> Int {
        let (lower, upper) = prefixRange(under: scope)
        return try await index.pool.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM search_entries WHERE prefix >= ? AND prefix < ?",
                arguments: [lower, upper]
            ) ?? 0
        }
    }

    public func query(_ query: SearchQuery) async throws -> SearchResult {
        let (lower, upper) = prefixRange(under: query.scope)
        let normalizedTerms = query.terms.map(normalizedSearchText).filter { !$0.isEmpty }
        let uniqueTags = Array(Set(query.tags.filter { !$0.isEmpty })).sorted()
        let kindValues = query.kinds.map(\.rawValue).sorted()
        let limit = max(0, query.limit)

        return try await index.pool.read { database in
            let indexedCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM search_entries WHERE prefix >= ? AND prefix < ?",
                arguments: [lower, upper]
            ) ?? 0

            var fromClause: String
            var whereClauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            let needsPositiveRating = (query.minimumRating ?? -1) >= 1
            let metadataJoin = needsPositiveRating
                ? "JOIN metadata m ON m.key = s.cacheKey"
                : "LEFT JOIN metadata m ON m.key = s.cacheKey"

            if let firstTag = uniqueTags.first {
                fromClause = "FROM metadata_tags t0 JOIN search_entries s ON s.cacheKey = t0.key \(metadataJoin)"
                whereClauses.append("t0.tag = ?")
                arguments.append(firstTag)
                for tag in uniqueTags.dropFirst() {
                    whereClauses.append("EXISTS (SELECT 1 FROM metadata_tags mt WHERE mt.key = s.cacheKey AND mt.tag = ?)")
                    arguments.append(tag)
                }
            } else {
                fromClause = "FROM search_entries s \(metadataJoin)"
            }

            whereClauses.append("s.prefix >= ? AND s.prefix < ?")
            arguments.append(lower)
            arguments.append(upper)

            if let minimumRating = query.minimumRating {
                if minimumRating == 0 {
                    whereClauses.append("(m.rating IS NULL OR m.rating = 0)")
                } else {
                    whereClauses.append("m.rating >= ?")
                    arguments.append(minimumRating)
                }
            }

            if !kindValues.isEmpty {
                whereClauses.append("s.kind IN (\(cachePlaceholders(kindValues.count)))")
                for value in kindValues { arguments.append(value) }
            }

            for term in normalizedTerms {
                whereClauses.append("s.name LIKE ? ESCAPE '\\'")
                arguments.append(likePattern(for: term, leadingWildcard: true))
            }

            arguments.append(limit + 1)

            let sql = """
                SELECT s.location, s.container, s.cacheKey, m.rating
                \(fromClause)
                WHERE \(whereClauses.joined(separator: " AND "))
                LIMIT ?
                """

            struct MatchedRow {
                var location: Location
                var containerKey: Data
                var cacheKey: String
                var rating: Int?
            }

            let rawRows = try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments))
            let truncated = rawRows.count > limit
            let decoder = JSONDecoder()
            var matched: [MatchedRow] = []
            matched.reserveCapacity(min(rawRows.count, limit))
            var targetsByContainer: [Data: Set<Location>] = [:]
            for row in rawRows.prefix(limit) {
                let locationKey: Data = row[0]
                let containerKey: Data = row[1]
                let cacheKey: String = row[2]
                let rating: Int? = row[3]
                let location = try decoder.decode(Location.self, from: locationKey)
                matched.append(MatchedRow(location: location, containerKey: containerKey, cacheKey: cacheKey, rating: rating))
                targetsByContainer[containerKey, default: []].insert(location)
            }

            guard !matched.isEmpty else {
                return SearchResult(hits: [], truncated: truncated, indexedCount: indexedCount)
            }

            let containerKeys = Array(targetsByContainer.keys)
            var entriesByLocation: [Location: Entry] = [:]
            entriesByLocation.reserveCapacity(matched.count)
            for chunk in cacheChunks(containerKeys) {
                let listingRows = try Row.fetchCursor(
                    database,
                    sql: "SELECT location, value FROM directory_listings WHERE location IN (\(cachePlaceholders(chunk.count)))",
                    arguments: StatementArguments(Array(chunk))
                )
                while let row = try listingRows.next() {
                    let containerKey: Data = row[0]
                    let data: Data = row[1]
                    guard let targets = targetsByContainer[containerKey] else { continue }
                    let decoded = try DirectoryListingStorage.decodeMatching(data, targets: targets)
                    entriesByLocation.merge(decoded, uniquingKeysWith: { _, last in last })
                }
            }

            let cacheKeys = Array(Set(matched.map(\.cacheKey)))
            var tagsByKey: [String: [String]] = [:]
            for chunk in cacheChunks(cacheKeys) {
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

            var hits: [SearchHit] = []
            hits.reserveCapacity(matched.count)
            for item in matched {
                guard let entry = entriesByLocation[item.location] else { continue }
                hits.append(SearchHit(entry: entry, rating: item.rating, tags: tagsByKey[item.cacheKey]))
            }

            return SearchResult(hits: hits, truncated: truncated, indexedCount: indexedCount)
        }
    }

    /// 已索引标签里按出现次数降序返回建议。
    public func tagSuggestions(prefix: String, limit: Int) async throws -> [String] {
        guard limit > 0 else { return [] }
        return try await index.pool.read { database in
            if prefix.isEmpty {
                return try String.fetchAll(
                    database,
                    sql: """
                        SELECT tag
                        FROM metadata_tags
                        GROUP BY tag
                        ORDER BY COUNT(*) DESC, tag ASC
                        LIMIT ?
                        """,
                    arguments: [limit]
                )
            }
            return try String.fetchAll(
                database,
                sql: """
                    SELECT tag
                    FROM metadata_tags
                    WHERE tag LIKE ? ESCAPE '\\'
                    GROUP BY tag
                    ORDER BY COUNT(*) DESC, tag ASC
                    LIMIT ?
                    """,
                arguments: [likePattern(for: prefix, leadingWildcard: false), limit]
            )
        }
    }
}
