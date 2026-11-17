import Foundation
@_exported import MVFoundation

public struct HistoryEntry: Sendable, Hashable {
    public var book: Location
    public var openedAt: Date
    public init(book: Location, openedAt: Date) { self.book = book; self.openedAt = openedAt }
}

public struct BookmarkID: Hashable, Sendable, Codable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

public indirect enum BookmarkNode: Sendable, Hashable {
    case folder(id: BookmarkID, name: String, children: [BookmarkNode])
    case book(id: BookmarkID, location: Location, label: String?)
}

public struct PlaylistSummary: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var count: Int
    public var lastUsedAt: Date?
    public init(id: UUID, name: String, count: Int, lastUsedAt: Date? = nil) {
        self.id = id; self.name = name; self.count = count; self.lastUsedAt = lastUsedAt
    }
}

public struct AddReport: Sendable, Hashable {
    public var added: Int
    public var alreadyPresent: Int
    public init(added: Int, alreadyPresent: Int) { self.added = added; self.alreadyPresent = alreadyPresent }
}

public enum LibraryChange: Sendable, Hashable {
    case history, bookmarks, playlists
    case items(UUID)
    case playlistRemoved(UUID)
    case relocated
}

public enum LibraryError: Error, Sendable, Equatable {
    case notFound, invalidName, intoItself
}

public protocol LibraryStore: Sendable {
    func history() async throws -> [HistoryEntry]
    func recordOpened(_ book: Location, at date: Date) async throws
    func removeHistory(_ books: [Location]) async throws
    func clearHistory() async throws
    func setHistoryLimit(_ limit: Int) async throws
    func bookmarks() async throws -> [BookmarkNode]
    func addBookmarks(_ books: [Location], into folder: BookmarkID?, at index: Int?) async throws -> AddReport
    func addBookmarkFolder(named name: String, into folder: BookmarkID?, at index: Int?) async throws -> BookmarkID
    func moveBookmarks(_ ids: [BookmarkID], into folder: BookmarkID?, at index: Int) async throws
    func renameBookmark(_ id: BookmarkID, to name: String?) async throws
    func removeBookmarks(_ ids: [BookmarkID]) async throws
    func playlists() async throws -> [PlaylistSummary]
    func createPlaylist(named name: String) async throws -> UUID
    func renamePlaylist(_ id: UUID, to name: String) async throws
    func deletePlaylist(_ id: UUID) async throws
    func movePlaylist(_ id: UUID, to index: Int) async throws
    func items(of playlist: UUID) async throws -> [Entry]
    func addItems(_ entries: [Entry], to playlist: UUID) async throws -> AddReport
    func moveItems(_ locations: [Location], in playlist: UUID, to index: Int) async throws
    func removeItems(_ locations: [Location], from playlist: UUID) async throws
    func updateSnapshots(_ entries: [Entry], in playlist: UUID) async throws
    func recentPlaylist() async throws -> UUID?
    func apply(_ changes: [FileChange]) async throws
    func changes() -> AsyncStream<LibraryChange>
}
