import Foundation
import MVFoundation
import MVLibraryData
import MVTestSupport
import Testing

struct MockLibraryStoreTests {
    @Test("内存资料库历史、书签、列表及迁移保持真实存储的规则")
    func completeStore() async throws {
        let store = MockLibraryStore(historyLimit: 2)
        let root = Location(root: .local, layers: [["mock"]])
        let a = root.appending("a"), b = root.appending("b"), c = root.appending("c")
        for (index, book) in [a, b, c].enumerated() { await store.recordOpened(book, at: Date(timeIntervalSince1970: Double(index))) }
        #expect(await store.history().map(\.book) == [c, b])
        try await store.setHistoryLimit(1)
        #expect(await store.history().map(\.book) == [c])
        await store.removeHistory([c])
        #expect(await store.history().isEmpty)
        await store.clearHistory()
        let folder = try await store.addBookmarkFolder(named: "收藏", into: nil, at: nil)
        let child = try await store.addBookmarkFolder(named: "子夹", into: folder, at: nil)
        #expect(try await store.addBookmarks([a, a], into: folder, at: nil) == AddReport(added: 1, alreadyPresent: 1))
        guard case let .folder(_, _, children) = await store.bookmarks().first,
              case let .book(id, _, _) = children.last else { Issue.record("书签树缺失"); return }
        try await store.renameBookmark(id, to: "别名")
        try await store.renameBookmark(id, to: nil)
        await #expect(throws: LibraryError.intoItself) { try await store.moveBookmarks([folder], into: child, at: 0) }
        try await store.moveBookmarks([id], into: nil, at: 0)
        try await store.renameBookmark(folder, to: "新收藏")
        let list = try await store.createPlaylist(named: "一")
        let other = try await store.createPlaylist(named: "二")
        try await store.movePlaylist(other, to: 0)
        try await store.renamePlaylist(list, to: "列表")
        #expect(await store.playlists().map(\.id) == [other, list])
        func entry(_ location: Location) -> Entry { Entry(identity: ContentIdentity(location: location, size: 1, modificationNanos: 1), name: location.name, kind: .image) }
        #expect(try await store.addItems([entry(a), entry(b), entry(c), entry(a)], to: list) == AddReport(added: 3, alreadyPresent: 1))
        #expect(await store.recentPlaylist() == list)
        try await store.moveItems([a], in: list, to: 2)
        #expect(try await store.items(of: list).map(\.location) == [b, c, a])
        try await store.removeItems([c], from: list)
        var fresh = entry(a)
        fresh.identity.size = 99
        try await store.updateSnapshots([fresh], in: list)
        #expect(try await store.items(of: list).last?.size == 99)
        await store.recordOpened(a, at: Date(timeIntervalSince1970: 2))
        await store.recordOpened(b, at: Date(timeIntervalSince1970: 1))
        _ = try await store.addBookmarks([b], into: folder, at: nil)
        await store.apply([.moved(from: a, to: entry(b)), .removed(b)])
        #expect(try await store.items(of: list).map(\.location) == [b])
        #expect(await store.history().map(\.book) == [b])
        #expect(await store.history().first?.openedAt == Date(timeIntervalSince1970: 2))
        #expect(await store.bookmarks().count == 1) // 目标书签的文件夹保留。
        await store.recordOpened(.playlist(list), at: Date())
        try await store.deletePlaylist(list)
        #expect(await store.history().allSatisfy { $0.book != .playlist(list) })
        await store.removeBookmarks([folder])
        #expect(await store.bookmarks().isEmpty)
    }
}
