import Foundation
import MVFoundation
import MVIO
import MVPipeline
import MVSettings
import MVTestSupport
import Testing
@testable import MVReading

@MainActor struct ReadingSessionTests {
    let tree = MockTree(nodes: [.book("A", pages: 100), .book("B", pages: 8)])

    func setup(global: GlobalSettings = .default, memories: [BookMemory] = []) -> (ReaderSession, MockSettingsStore, MockImagePipeline) {
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let store = MockSettingsStore(global: global, memories: memories)
        let pipeline = MockImagePipeline(environment: environment)
        let session = ReaderSession(loader: MockBookLoader(environment: environment), settings: store, bookshelf: MockBookshelf(environment: environment), pipeline: pipeline)
        return (session, store, pipeline)
    }

    @Test("切书立即保存第50页，重开按身份恢复；缺失身份回退序号")
    func restoresMemory() async throws {
        let (original, store, pipeline) = setup()
        var session: ReaderSession? = original
        await session?.open(tree.location("A"), at: nil)
        session?.go(.index(49))
        // 切书会在打开下一本之前保存，无需等待去抖。
        await session?.open(tree.location("B"), at: nil)
        #expect(await store.bookMemory(for: tree.location("A"))?.lastPage == tree.location("A/050.jpg"))
        await session?.open(tree.location("A"), at: nil)
        #expect(session?.currentFrame == 49)
        let missing = BookMemory(book: tree.location("B"), lastPage: tree.location("B/missing.jpg"), lastPageIndex: 5)
        await store.saveBookMemory(missing)
        await session?.open(tree.location("B"), at: nil)
        #expect(session?.currentFrame == 5)
        #expect(pipeline.prefetchPlan(for: original.id) != nil)
        session = nil
    }

    @Test("析构保存最新位置并取消本会话预取，不影响另一会话")
    func closesAndCancels() async throws {
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let store = MockSettingsStore(), pipeline = MockImagePipeline(environment: environment)
        let make: () -> ReaderSession = { ReaderSession(loader: MockBookLoader(environment: environment), settings: store, bookshelf: MockBookshelf(environment: environment), pipeline: pipeline) }
        var session: ReaderSession? = make()
        let other = make()
        let id = session!.id
        await session!.open(tree.location("A"), at: nil)
        await other.open(tree.location("B"), at: nil)
        session!.go(.index(49))
        weak let weakSession = session
        session = nil
        #expect(weakSession == nil)
        await eventually { await store.bookMemory(for: tree.location("A"))?.lastPageIndex == 49 }
        #expect(pipeline.prefetchPlan(for: id) == nil)
        #expect(pipeline.prefetchPlan(for: other.id) != nil)
        let reopened = make()
        await reopened.open(tree.location("A"), at: nil)
        #expect(reopened.currentFrame == 49)
    }

    @Test("书设置去抖一秒保存；清除覆盖后重新解析继承值")
    func debounceAndInheritance() async throws {
        let (session, store, _) = setup()
        await session.open(tree.location("A"), at: nil)
        session.go(.index(49))
        session.update { $0.pageMode = .double }
        #expect(session.settings.pageMode == .double)
        #expect(await store.bookMemory(for: tree.location("A")) == nil)
        try await Task.sleep(for: .milliseconds(1150))
        #expect(await store.bookMemory(for: tree.location("A"))?.settings.pageMode == .double)
        #expect(await store.bookMemory(for: tree.location("A"))?.lastPageIndex == 49)
        session.update { $0.pageMode = nil }
        try await Task.sleep(for: .milliseconds(1150))
        #expect(session.settings.pageMode == .single)
        #expect(await store.bookMemory(for: tree.location("A"))?.settings.pageMode == nil)
    }

    @Test("flush 不等去抖就保存最新页和书设置，并取消旧的待保存快照")
    func flushesLatestMemory() async throws {
        let (session, store, _) = setup()
        await session.open(tree.location("A"), at: nil)
        session.go(.index(49))
        session.update { $0.pageMode = .double }
        await session.flush()
        #expect(await store.bookMemory(for: tree.location("A"))?.lastPageIndex == 49)
        #expect(await store.bookMemory(for: tree.location("A"))?.settings.pageMode == .double)
        session.go(.index(60))
        await session.flush()
        #expect(await store.bookMemory(for: tree.location("A"))?.lastPageIndex == 60)
    }

    @Test("元数据和第二次 sorted 改变页帧后仍按页身份保持位置")
    func anchorsDuringEvents() async {
        let book = tree.location("A"), original = pages(in: tree.location("A"), count: 6)
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        var global = GlobalSettings.default
        global.defaultBook.pageMode = .double
        global.defaultBook.firstPageSingle = false
        let session = ReaderSession(loader: EventLoader(stream: pair.stream), settings: MockSettingsStore(global: global), bookshelf: MockBookshelf(environment: environment), pipeline: MockImagePipeline(environment: environment))
        let task = Task { await session.open(book, at: nil) }
        pair.continuation.yield(.appended(Array(original.reversed())))
        pair.continuation.yield(.sorted(original))
        await eventually { session.book?.isEnumerated == true }
        #expect(session.currentFrame == 0)
        session.go(.index(3))
        pair.continuation.yield(.metadata([original[2].id: ImageMetadata(pixelSize: PixelSize(width: 200, height: 100))]))
        await eventually { session.book?.pages[2].metadata != nil }
        #expect(session.frames[session.currentFrame].elements.contains { $0.page == 3 })
        pair.continuation.yield(.sorted(Array(original.reversed())))
        await eventually { session.book?.pages.first?.id == original[5].id }
        #expect(session.frames[session.currentFrame].elements.contains { $0.page == 2 })
        let removed = Array(original.reversed()).filter { $0.id != original[3].id }
        pair.continuation.yield(.sorted(removed))
        await eventually { session.book?.pages.count == 5 }
        #expect(session.frames[session.currentFrame].elements.contains { $0.page == 2 })
        pair.continuation.finish()
        await task.value
    }

    @Test("连续模式只排已知元数据最长前缀，目标页不被早到的后缀夺走")
    func continuousPrefix() async {
        let book = tree.location("A"), original = pages(in: tree.location("A"), count: 5)
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        var global = GlobalSettings.default
        global.defaultBook.browseMode = .verticalStrip
        global.defaultBook.pageMode = .double
        let store = MockSettingsStore(global: global)
        let session = ReaderSession(loader: EventLoader(stream: pair.stream), settings: store, bookshelf: MockBookshelf(environment: environment), pipeline: MockImagePipeline(environment: environment))
        let task = Task { await session.open(book, at: original[4].id) }
        pair.continuation.yield(.sorted(original))
        await eventually { session.book?.isEnumerated == true }
        #expect(session.frames.isEmpty)
        let metadata = ImageMetadata(pixelSize: PixelSize(width: 10, height: 20))
        pair.continuation.yield(.metadata([original[4].id: metadata, original[3].id: metadata]))
        await eventually { session.book?.pages[4].metadata != nil }
        #expect(session.frames.isEmpty)
        pair.continuation.yield(.metadata([original[0].id: metadata, original[1].id: metadata]))
        await eventually { session.frames.count == 2 }
        pair.continuation.yield(.metadata([original[2].id: metadata]))
        await eventually { session.frames.count == 5 }
        #expect(session.currentFrame == 4)
        #expect(session.frames.allSatisfy { $0.elements.count == 1 })
        pair.continuation.finish()
        await task.value
    }

    @Test("全部导航、相邻书与外部设置变更")
    func navigationAndSettingsChanges() async throws {
        let (session, store, _) = setup()
        await session.open(tree.location("A"), at: nil)
        let moves: [(PageMove, Int)] = [(.nextFrame, 1), (.nextPage, 2), (.previousPage, 1), (.previousFrame, 0), (.last, 99), (.index(-4), 0), (.index(500), 99), (.first, 0)]
        for (move, expected) in moves { session.go(move); #expect(session.currentFrame == expected) }
        try await store.updateGlobal { $0.defaultBook.direction = .rightToLeft; $0.defaultBook.pageMode = .double }
        await eventually { session.settings.direction == .rightToLeft && session.settings.pageMode == .double }
        session.go(.first)
        session.go(.nextPage)
        #expect(session.currentFrame == 1)
        session.go(.nextPage)
        #expect(session.currentFrame == 2)
        session.go(.previousPage)
        #expect(session.currentFrame == 1)
        await session.openNeighborBook(.forward, sort: SortSpec(key: .name))
        #expect(session.book?.location == tree.location("B"))
        await session.openNeighborBook(.backward, sort: SortSpec(key: .name))
        #expect(session.book?.location == tree.location("A"))
    }

    @Test("分页原始字节、整书缩略图/元数据与三种连续模式的可见范围预取")
    func prefetchPlans() async throws {
        var global = GlobalSettings.default
        global.prefetch.viewerReadAheadPages = 3
        global.prefetch.galleryMarginScreens = 1
        let (session, store, pipeline) = setup(global: global)
        await session.open(tree.location("A"), at: nil)
        session.go(.index(49))
        let plan = try #require(pipeline.prefetchPlan(for: session.id))
        #expect(plan.items.filter { $0.renditions.isEmpty }.map { $0.identity.location.name } == ["051.jpg", "052.jpg", "053.jpg"])
        #expect(plan.items.filter { $0.renditions == [.thumbnail, .metadata] }.count == 100)
        #expect(!plan.items.contains { $0.renditions.contains { if case .display = $0 { true } else { false } } })
        for mode in [BrowseMode.verticalStrip, .horizontalStrip, .waterfall] {
            session.update { $0.browseMode = mode }
            session.visibleRangeChanged(20..<30)
            let items = try #require(pipeline.prefetchPlan(for: session.id)).items
            #expect(items.filter { $0.priority == .visible }.count == 10)
            #expect(items.filter { $0.priority == .near }.count == 20)
            #expect(items.filter { $0.renditions.contains(.browse) }.count == 30)
        }
        try await store.updateGlobal { $0.prefetch.currentBookPages = false }
        await eventually { pipeline.prefetchPlan(for: session.id)?.items.count == 30 }
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("异步状态未在一秒内到达")
    }
}
