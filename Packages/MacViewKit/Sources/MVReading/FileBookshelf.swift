import MVCache
import MVFoundation
import MVIO
import MVSettings

public final class FileBookshelf: Bookshelf {
    private let listing: ReadingListing

    public init(sources: any SourceRegistry, directories: DirectoryCache) {
        listing = ReadingListing(sources: sources, directories: directories)
    }

    public func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [listing] in
                do {
                    let cached = try await listing.directories.cachedChildren(of: directory)
                    if let cached { continuation.yield(.sorted(ReadingOrder.sorted(cached.entries.filter(ReadingListing.book), by: sort))) }
                    let result = try await listing.children(directory, priority: .book) { entries in
                        let books = entries.filter(ReadingListing.book)
                        if cached == nil && !books.isEmpty { continuation.yield(.appended(books)) }
                    }
                    if cached == nil || result.changed { continuation.yield(.sorted(ReadingOrder.sorted(result.entries.filter(ReadingListing.book), by: sort))) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cover(of book: Location, priority: IOPriority) async throws -> Location? {
        let entries = ReadingOrder.sorted(try await listing.cachedOrFresh(book, priority: priority), by: SortSpec(key: .name))
        // 目录缓存保存排序后的项；再次取封面直接复用，不访问来源。
        _ = try await listing.directories.update(book, listing: DirectoryListing(entries: entries))
        if let page = entries.first(where: ReadingListing.media) { return page.location }
        for child in entries where ReadingListing.book(child) {
            if let cover = try await cover(of: child.location, priority: priority) { return cover }
        }
        return nil
    }

    public func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? {
        guard let parent = book.parent else { return nil }
        var books: [Entry] = []
        for try await event in items(in: parent, sort: sort) {
            switch event { case let .appended(entries): books.append(contentsOf: entries); case let .sorted(entries): books = entries }
        }
        guard let index = books.firstIndex(where: { $0.location == book }) else { throw IOError.notFound(book) }
        let next = direction == .forward ? index + 1 : index - 1
        return books.indices.contains(next) ? books[next].location : nil
    }

    public func passThrough(_ location: Location) async throws -> Location {
        var current = location
        while true {
            try Task.checkCancellation()
            let entries = try await listing.cachedOrFresh(current, priority: .book)
            guard let child = ReadingListing.passage(entries) else { return current }
            current = child.location
        }
    }
}
