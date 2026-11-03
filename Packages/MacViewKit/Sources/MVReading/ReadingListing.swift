import Foundation
import MVCache
import MVFoundation
import MVIO
import MVSettings

/// BookLoader 与 Bookshelf 共用真实来源、目录缓存和过滤规则。
struct ReadingListing: Sendable {
    let sources: any SourceRegistry
    let directories: DirectoryCache

    static func visible(_ entry: Entry) -> Bool {
        let name = entry.name.lowercased()
        return !name.hasPrefix("._") && ![".ds_store", "thumbs.db", "desktop.ini", "__macosx"].contains(name)
            && !name.hasSuffix(".url") && !entry.location.layers.joined().contains { $0.lowercased() == "__macosx" }
    }

    static func media(_ entry: Entry) -> Bool { visible(entry) && (entry.kind == .image || entry.kind == .video) }
    static func book(_ entry: Entry) -> Bool {
        guard visible(entry) else { return false }
        switch entry.kind { case .directory, .archive: return true; default: return false }
    }

    static func passage(_ entries: [Entry]) -> Entry? {
        let books = entries.filter(book)
        return !entries.contains(where: media) && books.count == 1 && books[0].kind == .directory ? books[0] : nil
    }

    func children(_ container: Location, priority: IOPriority, batch: @Sendable ([Entry]) -> Void = { _ in }) async throws -> (entries: [Entry], changed: Bool) {
        let provider = try sources.provider(for: container)
        var entries: [Entry] = []
        for try await items in provider.children(of: container, priority: priority) {
            try Task.checkCancellation()
            entries.append(contentsOf: items)
            batch(items)
        }
        let diff = try await directories.update(container, listing: DirectoryListing(entries: entries))
        return (entries, !diff.added.isEmpty || !diff.removed.isEmpty || !diff.changed.isEmpty)
    }

    func cachedOrFresh(_ container: Location, priority: IOPriority) async throws -> [Entry] {
        if let cached = try await directories.cachedChildren(of: container) { return cached.entries }
        return try await children(container, priority: priority).entries
    }
}

public enum ReadingOrder {
    public static func sorted(_ entries: [Entry], by sort: SortSpec) -> [Entry] {
        entries.sorted { compare($0, $1, by: sort) == .orderedAscending }
    }

    static func compare(_ lhs: Entry, _ rhs: Entry, by sort: SortSpec) -> ComparisonResult {
        if sort.foldersFirst, (lhs.kind == .directory) != (rhs.kind == .directory) {
            return lhs.kind == .directory ? .orderedAscending : .orderedDescending
        }
        let primary: ComparisonResult = switch sort.key {
        case .name: NameOrder.compare(lhs.name, rhs.name)
        case .modified: order(lhs.identity.modificationNanos, rhs.identity.modificationNanos)
        case .created: order(lhs.created ?? .distantPast, rhs.created ?? .distantPast)
        case .size: order(lhs.size, rhs.size)
        case .type: NameOrder.compare((lhs.name as NSString).pathExtension, (rhs.name as NSString).pathExtension)
        case .random: order(randomRank(lhs.location, seed: sort.randomSeed ?? 0), randomRank(rhs.location, seed: sort.randomSeed ?? 0))
        }
        var result = primary == .orderedSame ? NameOrder.compare(lhs.name, rhs.name) : primary
        if result == .orderedSame { result = lhs.location.description.compare(rhs.location.description, options: .literal) }
        return sort.ascending ? result : reversed(result)
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
    private static func reversed(_ result: ComparisonResult) -> ComparisonResult {
        result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
    private static func randomRank(_ location: Location, seed: UInt64) -> UInt64 {
        var value = 14_695_981_039_346_656_037 ^ seed
        for byte in location.description.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
