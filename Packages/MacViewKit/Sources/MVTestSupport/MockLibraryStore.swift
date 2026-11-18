import Foundation
import MVLibraryData
import MVIO
import MVMedia
import MVReading
import MVSettings
import Synchronization

/// Mock 服务使用的内存资料库；与真实存储共用位置、去重和通知规则。
public actor MockLibraryStore: LibraryStore {
    private struct Mark {
        let id: BookmarkID
        var parent: BookmarkID?
        var name: String?
        var book: Location?
    }
    private struct Playlist {
        var summary: PlaylistSummary
        var entries: [Entry] = []
    }
    private var opened: [Location: Date] = [:]
    private var limit: Int
    private var marks: [BookmarkID: Mark] = [:]
    private var order: [BookmarkID?: [BookmarkID]] = [nil: []]
    private var lists: [Playlist] = []
    private nonisolated let observers = Mutex<[UUID: AsyncStream<LibraryChange>.Continuation]>([:])

    public init(historyLimit: Int = 1000) { limit = max(1, historyLimit) }
    deinit { observers.withLock { $0.values.forEach { $0.finish() } } }

    public func history() -> [HistoryEntry] {
        opened.map { HistoryEntry(book: $0.key, openedAt: $0.value) }.sorted {
            $0.openedAt == $1.openedAt ? $0.book.prefixKey < $1.book.prefixKey : $0.openedAt > $1.openedAt
        }
    }
    public func recordOpened(_ book: Location, at date: Date) {
        opened[book] = date
        trimHistory()
        emit(.history)
    }
    public func removeHistory(_ books: [Location]) {
        guard !books.isEmpty else { return }
        books.forEach { opened.removeValue(forKey: $0) }
        emit(.history)
    }
    public func clearHistory() { opened.removeAll(); emit(.history) }
    public func setHistoryLimit(_ limit: Int) throws {
        guard limit > 0 else { throw LibraryError.invalidName }
        self.limit = limit
        trimHistory()
        emit(.history)
    }
    private func trimHistory() { for entry in history().dropFirst(limit) { opened.removeValue(forKey: entry.book) } }

    public func bookmarks() -> [BookmarkNode] { children(in: nil) }
    private func children(in parent: BookmarkID?) -> [BookmarkNode] {
        (order[parent] ?? []).compactMap { id in
            guard let mark = marks[id] else { return nil }
            if let book = mark.book { return .book(id: id, location: book, label: mark.name) }
            return .folder(id: id, name: mark.name ?? "", children: children(in: id))
        }
    }
    public func addBookmarks(_ books: [Location], into folder: BookmarkID?, at index: Int?) throws -> AddReport {
        try requireFolder(folder)
        var existing = Set(marks.values.compactMap(\.book)), inserted: [BookmarkID] = []
        for book in books where existing.insert(book).inserted {
            let id = BookmarkID()
            marks[id] = Mark(id: id, parent: folder, book: book)
            inserted.append(id)
        }
        var siblings = order[folder] ?? []
        siblings.insert(contentsOf: inserted, at: clamped(index ?? siblings.count, count: siblings.count))
        order[folder] = siblings
        emit(.bookmarks)
        return AddReport(added: inserted.count, alreadyPresent: books.count - inserted.count)
    }
    public func addBookmarkFolder(named name: String, into folder: BookmarkID?, at index: Int?) throws -> BookmarkID {
        let name = try validName(name)
        try requireFolder(folder)
        let id = BookmarkID()
        marks[id] = Mark(id: id, parent: folder, name: name)
        var siblings = order[folder] ?? []
        siblings.insert(id, at: clamped(index ?? siblings.count, count: siblings.count))
        order[folder] = siblings
        order[id] = []
        emit(.bookmarks)
        return id
    }
    public func moveBookmarks(_ ids: [BookmarkID], into folder: BookmarkID?, at index: Int) throws {
        guard !ids.isEmpty else { return }
        try requireFolder(folder)
        guard ids.allSatisfy({ marks[$0] != nil }) else { throw LibraryError.notFound }
        let selected = Set(ids)
        var ancestor = folder
        while let id = ancestor {
            guard !selected.contains(id) else { throw LibraryError.intoItself }
            ancestor = marks[id]?.parent
        }
        var seen: Set<BookmarkID> = []
        let moving = ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            var ancestor = marks[id]?.parent
            while let parent = ancestor {
                if selected.contains(parent) { return false }
                ancestor = marks[parent]?.parent
            }
            return true
        }
        for id in moving {
            let parent = marks[id]?.parent
            order[parent]?.removeAll { $0 == id }
            marks[id]?.parent = folder
        }
        var siblings = order[folder] ?? []
        siblings.insert(contentsOf: moving, at: clamped(index, count: siblings.count))
        order[folder] = siblings
        emit(.bookmarks)
    }
    public func renameBookmark(_ id: BookmarkID, to name: String?) throws {
        guard let mark = marks[id] else { throw LibraryError.notFound }
        marks[id]?.name = mark.book == nil ? try validName(name ?? "") : name
        emit(.bookmarks)
    }
    public func removeBookmarks(_ ids: [BookmarkID]) {
        guard !ids.isEmpty else { return }
        ids.forEach(removeMark)
        emit(.bookmarks)
    }
    private func removeMark(_ id: BookmarkID) {
        guard let mark = marks[id] else { return }
        for child in order[id] ?? [] { removeMark(child) }
        order[mark.parent]?.removeAll { $0 == id }
        order.removeValue(forKey: id)
        marks.removeValue(forKey: id)
    }
    private func requireFolder(_ folder: BookmarkID?) throws {
        if let folder, marks[folder] == nil || marks[folder]?.book != nil { throw LibraryError.notFound }
    }

    public func playlists() -> [PlaylistSummary] {
        lists.map { list in var summary = list.summary; summary.count = list.entries.count; return summary }
    }
    public func createPlaylist(named name: String) throws -> UUID {
        let name = try validName(name), id = UUID()
        lists.append(Playlist(summary: PlaylistSummary(id: id, name: name, count: 0)))
        emit(.playlists)
        return id
    }
    public func renamePlaylist(_ id: UUID, to name: String) throws {
        let name = try validName(name), index = try listIndex(id)
        lists[index].summary.name = name
        emit(.playlists)
    }
    public func deletePlaylist(_ id: UUID) throws {
        lists.remove(at: try listIndex(id))
        opened.removeValue(forKey: .playlist(id))
        emit(.playlists, .history, .playlistRemoved(id))
    }
    public func movePlaylist(_ id: UUID, to index: Int) throws {
        let list = lists.remove(at: try listIndex(id))
        lists.insert(list, at: clamped(index, count: lists.count))
        emit(.playlists)
    }
    public func items(of playlist: UUID) throws -> [Entry] { lists[try listIndex(playlist)].entries }
    public func addItems(_ entries: [Entry], to playlist: UUID) throws -> AddReport {
        let index = try listIndex(playlist)
        var locations = Set(lists[index].entries.map(\.location))
        let added = entries.filter { locations.insert($0.location).inserted }
        lists[index].entries += added
        if !entries.isEmpty { lists[index].summary.lastUsedAt = Date() }
        emit(.playlists, .items(playlist))
        return AddReport(added: added.count, alreadyPresent: entries.count - added.count)
    }
    public func moveItems(_ locations: [Location], in playlist: UUID, to index: Int) throws {
        guard !locations.isEmpty else { return }
        let list = try listIndex(playlist), selected = Set(locations)
        let moving = lists[list].entries.filter { selected.contains($0.location) }
        lists[list].entries.removeAll { selected.contains($0.location) }
        lists[list].entries.insert(contentsOf: moving, at: clamped(index, count: lists[list].entries.count))
        emit(.items(playlist))
    }
    public func removeItems(_ locations: [Location], from playlist: UUID) throws {
        guard !locations.isEmpty else { return }
        let list = try listIndex(playlist), selected = Set(locations)
        lists[list].entries.removeAll { selected.contains($0.location) }
        emit(.playlists, .items(playlist))
    }
    public func updateSnapshots(_ entries: [Entry], in playlist: UUID) throws {
        let list = try listIndex(playlist)
        let fresh = Dictionary(entries.map { ($0.location, $0) }, uniquingKeysWith: { _, new in new })
        lists[list].entries = lists[list].entries.map { fresh[$0.location] ?? $0 }
    }
    public func recentPlaylist() -> UUID? {
        lists.filter { $0.summary.lastUsedAt != nil }.max {
            ($0.summary.lastUsedAt ?? .distantPast) < ($1.summary.lastUsedAt ?? .distantPast)
        }?.summary.id
    }
    private func listIndex(_ id: UUID) throws -> Int {
        guard let index = lists.firstIndex(where: { $0.summary.id == id }) else { throw LibraryError.notFound }
        return index
    }

    public func apply(_ changes: [FileChange]) {
        var moved = false
        for change in changes {
            guard case let .moved(from, to) = change else { continue }
            moved = true
            for (location, date) in opened where location.hasPrefix(from) {
                let target = rebased(location, from: from, to: to.location)
                guard target != location else { continue }
                opened.removeValue(forKey: location)
                opened[target] = max(date, opened[target] ?? .distantPast)
            }
            for mark in Array(marks.values) {
                guard let location = mark.book, location.hasPrefix(from) else { continue }
                let target = rebased(location, from: from, to: to.location)
                if marks.values.contains(where: { $0.id != mark.id && $0.book == target }) { removeMark(mark.id) }
                else { marks[mark.id]?.book = target }
            }
            for index in lists.indices {
                let existing = Set(lists[index].entries.map(\.location))
                lists[index].entries = lists[index].entries.compactMap { entry in
                    guard entry.location.hasPrefix(from) else { return entry }
                    let location = rebased(entry.location, from: from, to: to.location)
                    if location != entry.location, existing.contains(location) { return nil }
                    var fresh = entry
                    fresh.identity.location = location
                    fresh.name = location.name
                    if entry.location == from { fresh.identity = to.identity; fresh.kind = to.kind; fresh.created = to.created }
                    return fresh
                }
            }
        }
        if moved { emit(.relocated) }
    }
    private func rebased(_ location: Location, from: Location, to: Location) -> Location {
        var layers = to.layers
        layers[layers.count - 1] += location.layers[from.layers.count - 1].dropFirst(from.layers.last?.count ?? 0)
        layers += location.layers.dropFirst(from.layers.count)
        return Location(root: to.root, layers: layers)
    }
    private func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LibraryError.invalidName }
        return value
    }
    private func clamped(_ index: Int, count: Int) -> Int { min(max(0, index), count) }
    private func emit(_ changes: LibraryChange...) {
        observers.withLock { observers in for change in changes { observers.values.forEach { $0.yield(change) } } }
    }
    public nonisolated func changes() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            let id = UUID()
            observers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.observers.withLock { _ = $0.removeValue(forKey: id) } }
        }
    }
}

struct MockPlaylistBookLoader: BookLoader {
    let store: any LibraryStore
    let environment: MockEnvironment
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let id = location.playlistID else { throw IOError.notFound(location) }
                    let entries: [Entry]
                    do { entries = try await store.items(of: id) }
                    catch LibraryError.notFound { throw IOError.notFound(location) }
                    continuation.yield(.sorted(entries.map { Page(entry: $0) }))
                    var values: [Location: ImageMetadata] = [:]
                    var availability: [Location: Availability] = [:]
                    for entry in entries {
                        try Task.checkCancellation()
                        let metadata = try? environment.media(at: entry.location).metadata
                        values[entry.location] = metadata ?? ImageMetadata(pixelSize: PixelSize(width: 1000, height: 1414))
                        availability[entry.location] = metadata == nil ? .missing : .available
                    }
                    continuation.yield(.availability(availability))
                    continuation.yield(.metadata(values))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
