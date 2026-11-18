import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVSettings
import MVTestSupport
import Synchronization
import Testing
@testable import MVReading

@MainActor struct VirtualBookSessionTests {
    let tree = MockTree(nodes: [.book("A", pages: 4), .book("B", pages: 4)])

    private func setup() -> (ReaderSession, LibrarySessionLoader, MockSettingsStore, LibrarySessionShelf, TracingPipeline) {
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let ordered = [pages(in: tree.location("B"), count: 4)[2], pages(in: tree.location("A"), count: 4)[0],
                       pages(in: tree.location("B"), count: 4)[0], pages(in: tree.location("A"), count: 4)[3]]
        let loader = LibrarySessionLoader(pages: ordered)
        let store = MockSettingsStore(), shelf = LibrarySessionShelf()
        let pipeline = TracingPipeline(base: MockImagePipeline(environment: environment))
        let session = ReaderSession(loader: loader, settings: store, bookshelf: shelf, pipeline: pipeline)
        return (session, loader, store, shelf, pipeline)
    }

    @Test("C1.9 虚拟书保留列表顺序与页、单双页、缩放记忆，不访问书架")
    func virtualOrderSettingsMemoryAndShelfIsolation() async throws {
        let (session, loader, store, shelf, pipeline) = setup()
        let location = Location.playlist(UUID())
        session.shelfSortChanged(SortSpec(key: .name))
        await session.open(location, at: nil)
        let order = try #require(session.book).pages.map(\.id)
        #expect(session.isVirtualBook)
        session.go(.index(2))
        session.update { $0.sort = SortSpec(key: .name, ascending: false); $0.recursion = RecursionSpec(enabled: true, maxDepth: 3) }
        session.update { $0.pageMode = .double; $0.scaleMode = .fitWidth }
        try await store.updateGlobal { $0.defaultBook.sort = SortSpec(key: .modified); $0.defaultBook.direction = .rightToLeft }
        await wait { session.settings.direction == .rightToLeft }
        #expect(session.book?.pages.map(\.id) == order)
        #expect(loader.loads == 1)
        await session.openNeighborBook(.forward, sort: SortSpec(key: .name))
        #expect(session.book?.location == location)
        #expect(shelf.calls == 0)
        #expect(pipeline.base.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)
        await session.flush()
        let reopened = ReaderSession(loader: loader, settings: store, bookshelf: shelf, pipeline: pipeline)
        await reopened.open(location, at: nil)
        #expect(reopened.currentPage == 2)
        #expect(reopened.settings.pageMode == .double)
        #expect(reopened.settings.scaleMode == .fitWidth)
        #expect(await store.bookMemory(for: location)?.lastPage == order[2])
        #expect(shelf.calls == 0)
    }

    @Test("C1.10 删除后保留页与占位状态，撤销刷新身份和取图计划")
    func virtualDeletionUndoAndAvailabilityRecovery() async throws {
        let (session, loader, _, _, pipeline) = setup()
        await session.open(.playlist(UUID()), at: nil)
        let original = try #require(session.book?.pages[1])
        _ = try await pipeline.thumbnail(for: original.entry.identity, maxPixel: 128, priority: .visible)
        session.applyFileChanges([.removed(original.id)])
        #expect(session.book?.pages[1].id == original.id)
        #expect(session.unavailablePages.contains(original.id))
        #expect(pipeline.base.prefetchPlan(for: session.id)?.items.contains { $0.identity.location == original.id } == false)
        var restored = original.entry
        restored.identity.modificationNanos += 1
        let trash = Location(root: .local, layers: [["trash", "001.jpg"]])
        session.applyFileChanges([.moved(from: trash, to: restored)])
        await wait { session.book?.pages[1].metadata != nil && !session.unavailablePages.contains(original.id) }
        #expect(session.book?.pages[1].entry == restored)
        #expect(pipeline.base.prefetchPlan(for: session.id)?.items.contains { $0.identity == restored.identity } == true)
        #expect(pipeline.metadataOrder.contains(original.id))
        _ = try await pipeline.thumbnail(for: restored.identity, maxPixel: 128, priority: .visible)

        let volume = Location.Root.network(scheme: "nfs", host: "192.0.2.1", share: "images")
        session.setAvailability([original.id: .volumeUnavailable(volume)])
        #expect(session.unavailablePages.contains(original.id))
        var refreshed = original
        refreshed.entry.identity.modificationNanos += 2
        var refreshedPages = try #require(session.book).pages
        refreshedPages[1] = refreshed
        loader.replace(with: refreshedPages)
        session.setAvailability([original.id: .available])
        // 校验结束前仍显示占位页，不能闪回旧身份已缓存的图。
        #expect(session.unavailablePages.contains(original.id))
        await wait { session.book?.pages[1].entry.identity == refreshed.entry.identity && !session.unavailablePages.contains(original.id) }
        #expect(session.book?.pages.map(\.id) == refreshedPages.map(\.id))
        #expect(pipeline.base.prefetchPlan(for: session.id)?.items.contains { $0.identity == refreshed.entry.identity } == true)
        session.setAvailability([original.id: .missing])
        #expect(session.unavailablePages.contains(original.id))
    }

    @Test("C1.10 移动原文件及父目录时保留列表顺序，当前页跟随")
    func virtualMovesFollowCurrentPageWithoutSortingOrReload() async throws {
        let (session, loader, _, shelf, _) = setup()
        await session.open(.playlist(UUID()), at: nil)
        session.go(.index(2))
        let order = try #require(session.book).pages.map(\.id)
        var moved = try #require(session.book?.pages[2].entry)
        moved.identity.location = tree.location("A/moved.jpg")
        moved.name = "moved.jpg"
        session.applyFileChanges([.moved(from: order[2], to: moved)])
        #expect(session.currentPage == 2)
        #expect(session.book?.pages[2].entry == moved)
        #expect(session.book?.pages.map(\.id) == [order[0], order[1], moved.location, order[3]])
        let renamed = Entry(identity: ContentIdentity(location: tree.location("renamed"), size: 0, modificationNanos: 1), name: "renamed", kind: .directory)
        session.applyFileChanges([.moved(from: tree.location("A"), to: renamed)])
        #expect(session.book?.pages[2].id == tree.location("renamed/moved.jpg"))
        #expect(session.currentPage == 2)
        #expect(loader.loads == 1)
        #expect(shelf.calls == 0)
    }

    @Test("C1.10 移动不可用页，仅直接得到页 Entry 时取图恢复，目录子页须重新校验", arguments: [false, true])
    func unavailableMoveUsesSourceValidationForDescendants(moveContainer: Bool) async throws {
        let (session, loader, _, _, _) = setup()
        await session.open(.playlist(UUID()), at: nil)
        var fresh = try #require(session.book?.pages)
        let original = fresh[1]
        session.setAvailability([original.id: .missing])
        let from = moveContainer ? tree.location("A") : original.id
        let destination = moveContainer ? tree.location("renamed") : tree.location("B/002.jpg")
        let entry = moveContainer
            ? Entry(identity: ContentIdentity(location: destination, size: 0, modificationNanos: 10), name: destination.name, kind: .directory)
            : pages(in: tree.location("B"), count: 4)[1].entry
        for index in fresh.indices where fresh[index].id.hasPrefix(from) {
            if moveContainer {
                fresh[index].entry.identity.location = destination.appending(fresh[index].entry.name)
                fresh[index].entry.identity.modificationNanos = 10
            } else { fresh[index].entry = entry }
        }
        loader.replace(with: fresh)
        session.applyFileChanges([.moved(from: from, to: entry)])
        let moved = moveContainer ? destination.appending(original.entry.name) : destination
        #expect(session.unavailablePages.contains(moved))
        await wait { !session.unavailablePages.contains(moved) }
        #expect(session.book?.pages[1].entry.identity == fresh[1].entry.identity)
        #expect(loader.loads == (moveContainer ? 2 : 1))
    }

    @Test("C1.10 打开即接收逐容器状态，占位元数据不能清除不可用页")
    func openingConsumesExplicitAvailability() async throws {
        let (_, _, store, shelf, pipeline) = setup()
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        let session = ReaderSession(loader: EventLoader(stream: pair.stream), settings: store, bookshelf: shelf, pipeline: pipeline)
        let ordered = pages(in: tree.location("A"), count: 3)
        let opening = Task { await session.open(.playlist(UUID()), at: nil) }
        pair.continuation.yield(.sorted(ordered))
        pair.continuation.yield(.availability([ordered[0].id: .missing]))
        await wait { session.unavailablePages.contains(ordered[0].id) }
        pair.continuation.yield(.availability([ordered[1].id: .volumeUnavailable(ordered[1].id.root), ordered[2].id: .available]))
        pair.continuation.yield(.metadata(Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, ImageMetadata(pixelSize: PixelSize(width: 1000, height: 1414))) })))
        pair.continuation.finish()
        await opening.value
        #expect(session.unavailablePages == Set(ordered.prefix(2).map(\.id)))
        #expect(session.book?.pages.map(\.id) == ordered.map(\.id))
        #expect(session.book?.pages.allSatisfy { $0.metadata != nil } == true)
    }

    @Test("C1.10 打开中的旧可用结果和快照不能覆盖删除、撤销与再次删除")
    func openingAvailabilityDoesNotOverrideFileChanges() async throws {
        let (_, _, store, shelf, pipeline) = setup()
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        let session = ReaderSession(loader: EventLoader(stream: pair.stream), settings: store, bookshelf: shelf, pipeline: pipeline)
        let ordered = pages(in: tree.location("A"), count: 2)
        let original = ordered[0]
        let opening = Task { await session.open(.playlist(UUID()), at: original.id) }
        pair.continuation.yield(.sorted(ordered))
        await wait { session.book?.pages.count == 2 }
        session.applyFileChanges([.removed(original.id)])
        var restored = original.entry
        restored.identity.modificationNanos += 10
        session.applyFileChanges([.moved(from: tree.location("trash/001.jpg"), to: restored)])
        await wait { !session.unavailablePages.contains(original.id) }
        pair.continuation.yield(.sorted(ordered))
        pair.continuation.yield(.availability([original.id: .missing]))
        await wait { session.book?.pages.first?.entry == restored }
        session.applyFileChanges([.removed(original.id)])
        pair.continuation.yield(.availability([original.id: .available]))
        pair.continuation.finish()
        await opening.value
        #expect(session.book?.pages.first?.entry == restored)
        #expect(session.unavailablePages.contains(original.id))
        #expect(session.currentPage == 0)
    }

    @Test("C1.10 首批页前删除再迁移，旧位置或已迁移快照均保持占位与锚点", arguments: [false, true])
    func firstSnapshotAfterEarlyDeletionAndMove(alreadyMoved: Bool) async throws {
        let (_, _, store, shelf, pipeline) = setup()
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        let ordered = pages(in: tree.location("A"), count: 3)
        let destination = tree.location("renamed")
        let loader = LibrarySessionLoader(pages: ordered)
        loader.enqueue(pair.stream)
        loader.enqueue(AsyncThrowingStream { continuation in
            let pages = ordered.map { page in var result = page; result.entry.identity.location = destination.appending(page.entry.name); return result }
            continuation.yield(.sorted(pages))
            continuation.yield(.availability(Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.id, $0.offset == 1 ? Availability.missing : .available) })))
            continuation.finish()
        })
        let session = ReaderSession(loader: loader, settings: store, bookshelf: shelf, pipeline: pipeline)
        let virtual = Location.playlist(UUID())
        let opening = Task { await session.open(virtual, at: ordered[1].id) }
        await wait { session.book?.location == virtual }
        let directory = Entry(identity: ContentIdentity(location: destination, size: 0, modificationNanos: 10), name: destination.name, kind: .directory)
        session.applyFileChanges([.removed(ordered[1].id), .moved(from: tree.location("A"), to: directory)])
        let snapshots = ordered.map { page in
            var result = page
            if alreadyMoved { result.entry.identity.location = destination.appending(page.entry.name) }
            return result
        }
        pair.continuation.yield(.sorted(snapshots))
        pair.continuation.yield(.availability(Dictionary(uniqueKeysWithValues: snapshots.enumerated().map { ($0.element.id, $0.offset == 1 ? Availability.missing : .available) })))
        pair.continuation.finish()
        await opening.value
        #expect(loader.loads == 2)
        #expect(session.book?.pages.map(\.id) == ordered.map { destination.appending($0.entry.name) })
        #expect(session.unavailablePages == [destination.appending(ordered[1].entry.name)])
        #expect(session.currentPage == 1)
    }

    @Test("C1.10 重新校验与删除、撤销、后续不可用检查竞态以新变更为准")
    func refreshAvailabilityDoesNotOverrideNewerChanges() async throws {
        let (session, loader, _, _, _) = setup()
        await session.open(.playlist(UUID()), at: nil)
        let ordered = try #require(session.book?.pages)
        let original = ordered[1]
        session.setAvailability([original.id: .missing])
        let removedRefresh = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        loader.enqueue(removedRefresh.stream)
        session.setAvailability([original.id: .available])
        removedRefresh.continuation.yield(.sorted(ordered))
        removedRefresh.continuation.yield(.availability([original.id: .available]))
        session.applyFileChanges([.removed(original.id)])
        removedRefresh.continuation.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.unavailablePages.contains(original.id))

        let undoRefresh = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        loader.enqueue(undoRefresh.stream)
        session.setAvailability([original.id: .available])
        undoRefresh.continuation.yield(.sorted(ordered))
        undoRefresh.continuation.yield(.availability([original.id: .available]))
        var restored = original.entry
        restored.identity.modificationNanos += 10
        let undo = FileChange.moved(from: tree.location("trash/001.jpg"), to: restored)
        session.applyFileChanges([undo])
        undoRefresh.continuation.finish()
        await wait { !session.unavailablePages.contains(original.id) }
        #expect(session.book?.pages[1].entry == restored)

        session.applyFileChanges([.removed(original.id), undo, .removed(original.id)])
        for _ in 0..<20 { await Task.yield() }
        #expect(session.unavailablePages.contains(original.id))
        let checkerRefresh = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        loader.enqueue(checkerRefresh.stream)
        session.setAvailability([original.id: .available])
        checkerRefresh.continuation.yield(.sorted(ordered))
        checkerRefresh.continuation.yield(.availability([original.id: .available]))
        session.setAvailability([original.id: .missing])
        checkerRefresh.continuation.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(session.unavailablePages.contains(original.id))
        #expect(session.book?.pages[1].entry == restored)
    }

    @Test("重载保留页身份，移除当前项回退原序号，越界取末页，删除列表报找不到")
    func reloadAnchorsAndBookOpenedCallback() async throws {
        let (session, loader, _, _, _) = setup()
        let location = Location.playlist(UUID())
        var opened: [Location] = []
        session.onBookOpened = { opened.append($0) }
        await session.open(location, at: nil)
        #expect(opened == [location])
        session.go(.index(2))
        let initial = try #require(session.book).pages
        loader.replace(with: Array(initial.reversed()))
        session.reloadBook()
        await wait { session.book?.pages.first?.id == initial.last?.id }
        #expect(session.currentPage == 1)
        loader.replace(with: [initial[3], initial[0]])
        session.reloadBook()
        await wait { session.book?.pages.count == 2 }
        #expect(session.currentPage == 1 && session.book?.pages[1].id == initial[0].id)
        loader.replace(with: [initial[3]])
        session.reloadBook()
        await wait { session.book?.pages.count == 1 }
        #expect(session.currentPage == 0)
        #expect(opened == [location])
        loader.removeBook()
        session.reloadBook()
        await wait { session.loadError != nil }
        #expect(session.loadError as? IOError == .notFound(location))
        #expect(opened == [location])
    }

    @Test("打开回调在第一批非空页面到达时仅触发一次，失败和空书不记打开")
    func openedCallbackWaitsForFirstPages() async {
        let (_, _, store, shelf, pipeline) = setup()
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        let session = ReaderSession(loader: EventLoader(stream: pair.stream), settings: store, bookshelf: shelf, pipeline: pipeline)
        var opened = 0
        session.onBookOpened = { _ in opened += 1 }
        let location = tree.location("A")
        let task = Task { await session.open(location, at: nil) }
        pair.continuation.yield(.sorted([]))
        await wait { session.book?.isEnumerated == true }
        #expect(opened == 0)
        pair.continuation.yield(.appended(pages(in: location, count: 2)))
        await wait { opened == 1 }
        pair.continuation.yield(.sorted(pages(in: location, count: 2)))
        pair.continuation.finish()
        await task.value
        #expect(opened == 1)
    }

    @Test("C1.19 Mock 也迁移未打开的书和虚拟书页，目标记忆优先")
    func mockSettingsRelocateByPrefix() async {
        let from = tree.location("A"), to = tree.location("renamed")
        let book = from.appending("folder"), archive = from.appending("book.zip")
        let virtual = Location.playlist(UUID())
        let destination = BookMemory(book: to.appending("folder"), lastPageIndex: 99)
        let store = MockSettingsStore(memories: [
            BookMemory(book: book, settings: BookSettings(pageMode: .double), lastPage: book.appending("3.jpg"), lastPageIndex: 2),
            BookMemory(book: archive, settings: BookSettings(pageMode: .single), lastPage: Location(root: from.root, layers: [from.layers[0] + ["book.zip"], ["3.jpg"]]), lastPageIndex: 2),
            BookMemory(book: virtual, lastPage: book.appending("3.jpg")), destination,
        ])
        await store.relocateBookMemory(from: from, to: to)
        #expect(await store.bookMemory(for: book) == nil)
        #expect(await store.bookMemory(for: archive) == nil)
        #expect(await store.bookMemory(for: destination.book) == destination)
        #expect(await store.bookMemory(for: to.appending("book.zip"))?.lastPage == Location(root: to.root, layers: [to.layers[0] + ["book.zip"], ["3.jpg"]]))
        #expect(await store.bookMemory(for: virtual)?.lastPage == to.appending("folder").appending("3.jpg"))
    }

    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("虚拟书状态没有在一秒内更新")
    }
}

private final class LibrarySessionLoader: BookLoader {
    private struct State {
        var pages: [Page]; var loads = 0; var removed = false
        var streams: [AsyncThrowingStream<BookLoadEvent, any Error>] = []
    }
    private let state: Mutex<State>
    init(pages: [Page]) { state = Mutex(State(pages: pages)) }
    var loads: Int { state.withLock { $0.loads } }
    func replace(with pages: [Page]) { state.withLock { $0.pages = pages } }
    func removeBook() { state.withLock { $0.removed = true } }
    func enqueue(_ stream: AsyncThrowingStream<BookLoadEvent, any Error>) { state.withLock { $0.streams.append(stream) } }
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        let (snapshot, stream) = state.withLock { current in
            current.loads += 1
            let stream = current.streams.isEmpty ? nil : current.streams.removeFirst()
            return (current, stream)
        }
        if let stream { return stream }
        return AsyncThrowingStream { continuation in
            guard !snapshot.removed else { continuation.finish(throwing: IOError.notFound(location)); return }
            continuation.yield(.sorted(snapshot.pages))
            continuation.yield(.availability(Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, .available) })))
            continuation.yield(.metadata(Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, ImageMetadata(pixelSize: PixelSize(width: 100, height: 140))) })))
            continuation.finish()
        }
    }
}

private final class LibrarySessionShelf: Bookshelf {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        count.withLock { $0 += 1 }
        return AsyncThrowingStream { $0.finish() }
    }
    func cover(of book: Location, priority: IOPriority) async throws -> Location? { count.withLock { $0 += 1 }; return nil }
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? { count.withLock { $0 += 1 }; return nil }
    func passThrough(_ location: Location) async throws -> Location { count.withLock { $0 += 1 }; return location }
    func rememberBook(_ location: Location) async { count.withLock { $0 += 1 } }
}
