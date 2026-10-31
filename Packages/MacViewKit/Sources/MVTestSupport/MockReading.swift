import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVReading
import MVSettings

/// 在内存目录树上加载书：分批 appended（到达顺序）→ sorted → 按阅读顺序分批的 metadata。
public struct MockBookLoader: BookLoader {
    public let environment: MockEnvironment

    public init(environment: MockEnvironment) {
        self.environment = environment
    }

    public func load(_ location: Location, settings: ResolvedBookSettings) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        let environment = environment
        let arrivals = environment.batches(of: location) { MockOrder.isPage($0.entry) ? $0.entry : nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var entries: [Entry] = []
                    for try await batch in arrivals {
                        entries += batch
                        continuation.yield(.appended(batch.map { Page(entry: $0) }))
                    }
                    let sorted = MockOrder.sorted(entries, by: settings.sort)
                    continuation.yield(.sorted(sorted.map { Page(entry: $0) }))
                    let size = max(environment.timing.batchSize, 1)
                    for start in stride(from: 0, to: sorted.count, by: size) {
                        try await environment.pause(environment.timing.batchInterval)
                        var metadata: [Location: ImageMetadata] = [:]
                        for entry in sorted[start..<min(start + size, sorted.count)] {
                            metadata[entry.location] = try environment.media(at: entry.location).metadata
                        }
                        continuation.yield(.metadata(metadata))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 内存目录树上的书架：书是子文件夹与压缩包。
public struct MockBookshelf: Bookshelf {
    public let environment: MockEnvironment

    public init(environment: MockEnvironment) {
        self.environment = environment
    }

    public func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        let arrivals = environment.batches(of: directory) { MockOrder.isBook($0.entry) ? $0.entry : nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var entries: [Entry] = []
                    for try await batch in arrivals {
                        entries += batch
                        continuation.yield(.appended(batch))
                    }
                    continuation.yield(.sorted(MockOrder.sorted(entries, by: sort)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 按名称排第一的页；书里没有媒体时找第一个子书，最多 3 层。
    public func cover(of book: Location, priority: IOPriority) async throws -> Location? {
        try await environment.access(book)
        return try firstPage(in: book, depth: 0)
    }

    public func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? {
        guard let parent = book.parent else { return nil }
        try await environment.access(parent)
        let books = MockOrder.sorted(try environment.children(of: parent).map(\.entry).filter(MockOrder.isBook), by: sort)
        guard let index = books.firstIndex(where: { $0.location == book }) else { throw IOError.notFound(book) }
        let next = direction == .forward ? index + 1 : index - 1
        return books.indices.contains(next) ? books[next].location : nil
    }

    public func passThrough(_ location: Location) async throws -> Location {
        var current = location
        while true {
            try await environment.access(current)
            let entries = try environment.children(of: current).map(\.entry)
            let books = entries.filter(MockOrder.isBook)
            guard !entries.contains(where: MockOrder.isPage), books.count == 1, books[0].kind == .directory else { return current }
            current = books[0].location
        }
    }

    private func firstPage(in container: Location, depth: Int) throws -> Location? {
        let entries = MockOrder.sorted(try environment.children(of: container).map(\.entry), by: SortSpec(key: .name))
        if let page = entries.first(where: MockOrder.isPage) {
            return page.location
        }
        guard depth < 3 else { return nil }
        for book in entries where MockOrder.isBook(book) {
            if let page = try firstPage(in: book.location, depth: depth + 1) {
                return page
            }
        }
        return nil
    }
}

/// Mock 的过滤与排序。名称用 Foundation 的数字感知比较，代替 S1-T6 的名称比较器。
enum MockOrder {
    static func isHidden(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.hasSuffix(".url")
    }

    static func isPage(_ entry: Entry) -> Bool {
        (entry.kind == .image || entry.kind == .video) && !isHidden(entry.name)
    }

    static func isBook(_ entry: Entry) -> Bool {
        switch entry.kind {
        case .directory, .archive: !isHidden(entry.name)
        case .image, .video, .other: false
        }
    }

    static func sorted(_ entries: [Entry], by sort: SortSpec) -> [Entry] {
        if sort.key == .random {
            var random = MockRandom(seed: sort.randomSeed ?? 0)
            return sorted(entries, by: SortSpec(key: .name)).shuffled(using: &random)
        }
        return entries.sorted { a, b in
            if sort.foldersFirst, (a.kind == .directory) != (b.kind == .directory) {
                return a.kind == .directory
            }
            let order = compare(a, b, key: sort.key)
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ a: Entry, _ b: Entry, key: SortKey) -> ComparisonResult {
        let primary: ComparisonResult = switch key {
        case .modified: compareValues(a.identity.modificationNanos, b.identity.modificationNanos)
        case .size: compareValues(a.size, b.size)
        case .type: (a.name as NSString).pathExtension.localizedStandardCompare((b.name as NSString).pathExtension)
        case .name, .created, .random: .orderedSame
        }
        return primary == .orderedSame ? a.name.localizedStandardCompare(b.name) : primary
    }

    private static func compareValues<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
