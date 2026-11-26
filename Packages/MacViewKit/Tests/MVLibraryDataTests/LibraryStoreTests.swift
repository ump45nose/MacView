import Foundation
import GRDB
import Testing
@testable import MVLibraryData
import MVFoundation

private struct LibraryFixture {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: ".w11-tests-\(UUID().uuidString)")
    var url: URL { directory.appending(path: "library.sqlite") }
    func open(limit: Int = 1000) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(databaseURL: url, historyLimit: limit)
    }
    func clean() throws { try FileManager.default.removeItem(at: directory) }
}

private func book(_ name: String) -> Location {
    Location(root: .local, layers: [["Library", name]])
}

private func page(_ name: String, size: Int64 = 20) -> Entry {
    Entry(identity: ContentIdentity(location: book(name), size: size, modificationNanos: 123),
          name: name, kind: .image)
}

extension LibraryDataTests.LibraryStoreTests {
    @Test("列表快照序号与内容变更、删除通知一致")
    func playlistSnapshotRevisions() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        var changes = store.playlistChanges().makeAsyncIterator()
        let id = try await store.createPlaylist(named: "序号")
        let before = try await store.playlistSnapshot(id)
        _ = try await store.addItems([page("1.jpg")], to: id)
        let added = try #require(await changes.next())
        let after = try await store.playlistSnapshot(id)
        #expect(added.id == id && added.revision > before.revision)
        #expect(after.revision == added.revision && after.entries == [page("1.jpg")])
        try await store.deletePlaylist(id)
        let deleted = try #require(await changes.next())
        #expect(deleted.id == id && deleted.revision > after.revision)
        await #expect(throws: LibraryError.notFound) { _ = try await store.playlistSnapshot(id) }
    }

    @Test("C1.8 只读统计快照中的历史、书签条目和播放列表")
    func archiveSummaryReadsSnapshotWithoutModifyingIt() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        for name in ["a", "b", "c"] { try await store.recordOpened(book(name), at: Date()) }
        let folder = try await store.addBookmarkFolder(named: "收藏", into: nil, at: nil)
        _ = try await store.addBookmarks([book("a"), book("b")], into: folder, at: nil)
        let playlist = try await store.createPlaylist(named: "待读")
        _ = try await store.addItems([page("1.jpg"), page("2.jpg")], to: playlist)

        let snapshot = fixture.directory.appending(path: "snapshot.sqlite")
        try await store.database.queue.writeWithoutTransaction { database in
            try database.execute(sql: "VACUUM INTO ?", arguments: [snapshot.path])
        }
        let fileManager = FileManager.default
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try fileManager.setAttributes([.modificationDate: modified, .posixPermissions: 0o444], ofItemAtPath: snapshot.path)
        let summary = try SQLiteLibraryStore.summary(databaseURL: snapshot)
        #expect(summary == LibrarySummary(history: 3, bookmarks: 2, playlists: 1))
        let attributes = try fileManager.attributesOfItem(atPath: snapshot.path)
        #expect(attributes[.modificationDate] as? Date == modified)

        let missing = fixture.directory.appending(path: "missing.sqlite")
        #expect(throws: DatabaseError.self) { try SQLiteLibraryStore.summary(databaseURL: missing) }
        #expect(!fileManager.fileExists(atPath: missing.path))
    }

    @Test func c12HistoryLimitsAndPersistence() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open(limit: 3)
        for index in 0..<5 {
            try await store.recordOpened(book("\(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(try await store.history().map(\.book) == [book("4"), book("3"), book("2")])
        try await store.recordOpened(book("3"), at: Date(timeIntervalSince1970: 10))
        #expect(try await store.history().map(\.book) == [book("3"), book("4"), book("2")])
        try await store.setHistoryLimit(2)
        #expect(try await store.history().map(\.book) == [book("3"), book("4")])
        try await store.removeHistory([book("4")])
        #expect(try await store.history().map(\.book) == [book("3")])
        try await store.flush()
        #expect(try await fixture.open().history() == store.history())
        try await store.clearHistory()
        try await store.flush()
        #expect(try await fixture.open().history().isEmpty)
    }

    @Test func c13BookmarkTreeAndPersistence() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let outer = try await store.addBookmarkFolder(named: "外层", into: nil, at: nil)
        let inner = try await store.addBookmarkFolder(named: "内层", into: outer, at: nil)
        let report = try await store.addBookmarks([book("a"), book("b"), book("a")], into: nil, at: 0)
        #expect(report == AddReport(added: 2, alreadyPresent: 1))
        let roots = try await store.bookmarks()
        guard case let .book(first, _, _) = roots[0], case let .book(second, _, _) = roots[1] else {
            Issue.record("书签应按插入顺序排列")
            return
        }
        try await store.moveBookmarks([first, second], into: inner, at: 0)
        try await store.renameBookmark(first, to: "自定义")
        try await store.renameBookmark(first, to: nil)
        try await store.renameBookmark(second, to: "第二本")
        try await store.renameBookmark(outer, to: "收藏")
        await #expect(throws: LibraryError.intoItself) {
            try await store.moveBookmarks([outer], into: inner, at: 0)
        }
        await #expect(throws: LibraryError.intoItself) {
            try await store.moveBookmarks([inner], into: inner, at: 0)
        }
        await #expect(throws: LibraryError.invalidName) { try await store.renameBookmark(inner, to: " ") }
        #expect(try await store.addBookmarks([book("a")], into: nil, at: nil) == AddReport(added: 0, alreadyPresent: 1))
        let expected: [BookmarkNode] = [.folder(id: outer, name: "收藏", children: [
            .folder(id: inner, name: "内层", children: [
                .book(id: first, location: book("a"), label: nil),
                .book(id: second, location: book("b"), label: "第二本"),
            ]),
        ])]
        #expect(try await store.bookmarks() == expected)
        try await store.flush()
        #expect(try await fixture.open().bookmarks() == expected)
        try await store.removeBookmarks([outer])
        #expect(try await store.bookmarks().isEmpty)
    }

    @Test func c14PlaylistOrderSnapshotsAndPersistence() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let first = try await store.createPlaylist(named: "一")
        let second = try await store.createPlaylist(named: "二")
        var archive = page("001.jpg")
        archive.identity.location = book("a.zip").appendingLayer(["inner", "001.jpg"])
        let entries = [page("a.jpg"), archive, page("b.jpg")]
        #expect(try await store.addItems(entries + [archive], to: first) == AddReport(added: 3, alreadyPresent: 1))
        #expect(try await store.recentPlaylist() == first)
        _ = try await store.addItems([page("c.jpg")], to: second)
        #expect(try await store.recentPlaylist() == second)
        try await store.moveItems([entries[2].location], in: first, to: 0)
        #expect(try await store.items(of: first) == [entries[2], entries[0], archive])
        try await store.removeItems([entries[0].location], from: first)
        var refreshed = archive
        refreshed.identity.size = 222
        try await store.updateSnapshots([refreshed], in: first)
        #expect(try await store.items(of: first) == [entries[2], refreshed])
        try await store.renamePlaylist(first, to: "改名")
        try await store.movePlaylist(second, to: 0)
        #expect(try await store.playlists().map(\.id) == [second, first])
        #expect(try await store.playlists().map(\.count) == [1, 2])
        try await store.flush()
        #expect(try await fixture.open().items(of: first) == [entries[2], refreshed])
        #expect(try await fixture.open().playlists().map(\.name) == ["二", "改名"])
        try await store.recordOpened(.playlist(first), at: Date())
        try await store.deletePlaylist(first)
        #expect(try await store.history().isEmpty)
        await #expect(throws: LibraryError.notFound) { _ = try await store.items(of: first) }
        #expect(try await fixture.open().playlists().map(\.id) == [second])
    }

    @Test func c15PrefixRelocationAndAtomicRollback() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let folder = book("old")
        let renamed = book("new")
        let nested = folder.appending("a.zip").appendingLayer(["inner.zip"]).appendingLayer(["001.jpg"])
        let target = renamed.appending("a.zip").appendingLayer(["inner.zip"]).appendingLayer(["001.jpg"])
        let unrelated = book("old-extra")
        for location in [folder, nested, unrelated] { try await store.recordOpened(location, at: Date()) }
        _ = try await store.addBookmarks([folder, nested, unrelated], into: nil, at: nil)
        let playlist = try await store.createPlaylist(named: "迁移")
        let source = Entry(identity: ContentIdentity(location: nested, size: 40, modificationNanos: 5), name: nested.name, kind: .image)
        _ = try await store.addItems([source], to: playlist)
        let beforeHistory = try await store.history()
        let beforeBookmarks = try await store.bookmarks()
        try await store.database.queue.write { database in
            try database.execute(sql: "CREATE TRIGGER fail_relocation BEFORE UPDATE OF location ON playlist_item BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        let move = FileChange.moved(from: folder, to: Entry(identity: ContentIdentity(location: renamed, size: 0, modificationNanos: 8), name: "new", kind: .directory))
        let earlierMove = FileChange.moved(from: unrelated, to: page("different.jpg"))
        await #expect(throws: (any Error).self) { try await store.apply([earlierMove, move]) }
        #expect(try await store.history() == beforeHistory)
        #expect(try await store.bookmarks() == beforeBookmarks)
        #expect(try await store.items(of: playlist) == [source])
        try await store.database.queue.write { try $0.execute(sql: "DROP TRIGGER fail_relocation") }
        try await store.apply([move, .removed(unrelated), .added(page("irrelevant"))])
        #expect(Set(try await store.history().map(\.book)) == Set([renamed, target, unrelated]))
        let bookmarks = try await store.bookmarks().compactMap { node -> Location? in
            if case let .book(_, location, _) = node { return location }
            return nil
        }
        #expect(bookmarks == [renamed, target, unrelated])
        let relocated = try #require(try await store.items(of: playlist).first)
        #expect(relocated.location == target)
        #expect(relocated.name == target.name)
        #expect(relocated.size == source.size)
        // 直接移动的文件取目标身份与名称；容器里的页保留自己的大小、时间。
        let newPage = page("renamed.jpg", size: 900)
        try await store.apply([.moved(from: target, to: newPage)])
        #expect(try await store.items(of: playlist) == [newPage])
    }

    @Test func c120RelocationCollisionKeepsDestination() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let source = page("source.jpg")
        let target = page("target.jpg", size: 999)
        try await store.recordOpened(source.location, at: Date(timeIntervalSince1970: 30))
        try await store.recordOpened(target.location, at: Date(timeIntervalSince1970: 10))
        let sourceFolder = try await store.addBookmarkFolder(named: "来源", into: nil, at: nil)
        let targetFolder = try await store.addBookmarkFolder(named: "目标", into: nil, at: nil)
        _ = try await store.addBookmarks([source.location], into: sourceFolder, at: nil)
        _ = try await store.addBookmarks([target.location], into: targetFolder, at: nil)
        let tree = try await store.bookmarks()
        guard case let .folder(_, _, targetChildren) = tree[1], case let .book(targetID, _, _) = targetChildren[0] else {
            Issue.record("缺少目标书签")
            return
        }
        try await store.renameBookmark(targetID, to: "保留显示名")
        let playlist = try await store.createPlaylist(named: "撞车")
        let other = page("other.jpg")
        _ = try await store.addItems([source, other, target], to: playlist)
        var moved = source
        moved.identity.location = target.location
        moved.name = target.name
        let another = try await store.createPlaylist(named: "另一个列表")
        _ = try await store.addItems([source], to: another)
        try await store.apply([.moved(from: source.location, to: moved)])
        #expect(try await store.history() == [HistoryEntry(book: target.location, openedAt: Date(timeIntervalSince1970: 30))])
        #expect(try await store.items(of: playlist) == [other, target])
        #expect(try await store.items(of: another) == [moved])
        #expect(try await store.bookmarks() == [
            .folder(id: sourceFolder, name: "来源", children: []),
            .folder(id: targetFolder, name: "目标", children: [.book(id: targetID, location: target.location, label: "保留显示名")]),
        ])
    }

    @Test func notificationsOnlyFollowCommittedChanges() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let playlist = try await store.createPlaylist(named: "通知")
        let entry = page("a.jpg")
        _ = try await store.addItems([entry], to: playlist)
        var changes = store.changes().makeAsyncIterator()
        var secondObserver = store.changes().makeAsyncIterator()
        try await store.updateSnapshots([page("a.jpg", size: 500)], in: playlist)
        try await store.apply([.removed(entry.location), .added(page("b.jpg"))])
        try await store.renamePlaylist(playlist, to: "改名")
        #expect(await changes.next() == .playlists)
        #expect(await secondObserver.next() == .playlists)
        await #expect(throws: LibraryError.invalidName) { try await store.renamePlaylist(playlist, to: " ") }
        try await store.apply([.moved(from: entry.location, to: page("renamed.jpg"))])
        #expect(await changes.next() == .relocated)
        try await store.deletePlaylist(playlist)
        #expect(await changes.next() == .playlists)
        #expect(await changes.next() == .history)
        #expect(await changes.next() == .playlistRemoved(playlist))
    }

    @Test func c16ThreeThousandItems() async throws {
        let fixture = LibraryFixture()
        defer { try? fixture.clean() }
        let store = try fixture.open()
        let playlist = try await store.createPlaylist(named: "3000")
        let entries = (0..<3000).map { page(String(format: "%04d.jpg", $0)) }
        _ = try await store.addItems(entries, to: playlist)
        let clock = ContinuousClock()
        let readStart = clock.now
        let loaded = try await store.items(of: playlist)
        let read = readStart.duration(to: clock.now)
        #expect(loaded == entries)
        let moveStart = clock.now
        try await store.moveItems(Array(entries.prefix(100)).map(\.location), in: playlist, to: 2900)
        let move = moveStart.duration(to: clock.now)
        #expect(try await store.items(of: playlist) == Array(entries.dropFirst(100)) + Array(entries.prefix(100)))
        print("C1.6: 3000项读取=\(read), 移动100项=\(move)")
        #if !DEBUG
        #expect(read < .milliseconds(50))
        #expect(move < .milliseconds(50))
        #endif
    }
}
