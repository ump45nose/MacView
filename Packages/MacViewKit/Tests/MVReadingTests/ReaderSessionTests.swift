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
        let changedAt = ContinuousClock.now
        session.update { $0.pageMode = .double }
        #expect(session.settings.pageMode == .double)
        #expect(await store.bookMemory(for: tree.location("A")) == nil)
        await eventually(attempts: 1000) {
            await store.bookMemory(for: tree.location("A"))?.settings.pageMode == .double
        }
        #expect(ContinuousClock.now - changedAt >= .seconds(1))
        #expect(await store.bookMemory(for: tree.location("A"))?.settings.pageMode == .double)
        #expect(await store.bookMemory(for: tree.location("A"))?.lastPageIndex == 49)
        session.update { $0.pageMode = nil }
        await eventually(attempts: 1000) {
            let memory = await store.bookMemory(for: tree.location("A"))
            return session.settings.pageMode == .single && memory?.settings.pageMode == nil
        }
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

    @Test("视口回报后预解码前后页帧，换视口替换目标；非分页与缺元数据不预解码")
    func displayPrefetchFollowsViewport() async throws {
        var global = GlobalSettings.default
        global.defaultBook.scaleMode = .fitWindow
        global.defaultBook.allowUpscale = true
        global.defaultBook.pageMode = .single
        global.prefetch.viewerDecodeFrames = 2
        global.prefetch.viewerReadAheadPages = 3
        global.maxDecodeLongSide = 8192
        let (session, _, pipeline) = setup(global: global)
        let viewport = PixelSize(width: 800, height: 600)
        let replaced = PixelSize(width: 1400, height: 800)
        await session.open(tree.location("A"), at: nil)
        #expect(session.book?.pages.count == 100)
        #expect(session.frames.count == 100)
        #expect(containsDisplay(pipeline.prefetchPlan(for: session.id)) == false)
        session.viewportChanged(viewport, backingScale: 1)
        session.go(.index(50))
        try expectDisplayWindow(session, pipeline, viewport: viewport, maxDecodeLongSide: global.maxDecodeLongSide, radius: 2)
        let pages = try #require(session.book).pages
        let current = pages[50].entry.identity
        let neighbor = pages[51].entry.identity
        let plan = try #require(pipeline.prefetchPlan(for: session.id))
        #expect(plan.items.filter { $0.identity == current } == [
            PrefetchItem(identity: current, renditions: [.thumbnail, .metadata], priority: .book),
        ])
        let target = try #require(PageFrameFit.fit(frame: session.frames[51], pages: pages, viewport: viewport, backingScale: 1, settings: session.settings)
            .displayTargets(settings: session.settings, maxDecodeLongSide: global.maxDecodeLongSide).first).target
        #expect(plan.items.filter { $0.identity == neighbor } == [
            PrefetchItem(identity: neighbor, renditions: [.thumbnail, .metadata], priority: .book),
            PrefetchItem(identity: neighbor, renditions: [], priority: .near),
            PrefetchItem(identity: neighbor, renditions: [.display(target)], priority: .near),
        ])
        session.go(.index(0))
        try expectDisplayWindow(session, pipeline, viewport: viewport, maxDecodeLongSide: global.maxDecodeLongSide, radius: 2)
        session.go(.index(99))
        try expectDisplayWindow(session, pipeline, viewport: viewport, maxDecodeLongSide: global.maxDecodeLongSide, radius: 2)
        let previous = displayRenditions(try #require(pipeline.prefetchPlan(for: session.id)))
        session.viewportChanged(replaced, backingScale: 1)
        let updated = displayRenditions(try #require(pipeline.prefetchPlan(for: session.id)))
        #expect(previous.isDisjoint(with: updated))
        #expect(!updated.isEmpty)
        try expectDisplayWindow(session, pipeline, viewport: replaced, maxDecodeLongSide: global.maxDecodeLongSide, radius: 2)
        await session.open(tree.location("B"), at: nil)
        #expect(session.book?.pages.count == 8)
        let kept = displayRenditions(try #require(pipeline.prefetchPlan(for: session.id)))
        #expect(kept.isDisjoint(with: previous))
        try expectDisplayWindow(session, pipeline, viewport: replaced, maxDecodeLongSide: global.maxDecodeLongSide, radius: 2)
        for mode in [BrowseMode.verticalStrip, .horizontalStrip, .waterfall] {
            session.update { $0.browseMode = mode }
            session.viewportChanged(PixelSize(width: 900, height: 700), backingScale: 1)
            session.visibleRangeChanged(0..<4)
            #expect(containsDisplay(pipeline.prefetchPlan(for: session.id)) == false)
        }
    }

    @Test("缺元数据的页不预解码，落入前后窗口后随元数据出现")
    func displayPrefetchWaitsForMetadata() async throws {
        let book = tree.location("A")
        let original = pages(in: book, count: 6)
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let pair = AsyncThrowingStream<BookLoadEvent, any Error>.makeStream()
        var global = GlobalSettings.default
        global.defaultBook.scaleMode = .fitWindow
        global.defaultBook.allowUpscale = true
        global.defaultBook.pageMode = .single
        global.prefetch.viewerDecodeFrames = 2
        global.prefetch.viewerReadAheadPages = 0
        global.prefetch.currentBookPages = false
        global.maxDecodeLongSide = 8192
        let pipeline = MockImagePipeline(environment: environment)
        let session = ReaderSession(
            loader: EventLoader(stream: pair.stream), settings: MockSettingsStore(global: global),
            bookshelf: MockBookshelf(environment: environment), pipeline: pipeline
        )
        let task = Task { await session.open(book, at: nil) }
        pair.continuation.yield(.sorted(original))
        await eventually { session.book?.isEnumerated == true && session.frames.count == 6 }
        #expect(containsDisplay(pipeline.prefetchPlan(for: session.id)) == false)
        let viewport = PixelSize(width: 800, height: 600)
        session.viewportChanged(viewport, backingScale: 1)
        session.go(.index(2))
        #expect(pipeline.prefetchPlan(for: session.id)?.items.isEmpty == true)
        let metadata = ImageMetadata(pixelSize: PixelSize(width: 1000, height: 2000))
        pair.continuation.yield(.metadata([
            original[2].id: metadata, original[3].id: metadata, original[5].id: metadata,
        ]))
        await eventually { session.book?.pages[3].metadata != nil }
        let loaded = try #require(session.book).pages
        let targets = PageFrameFit.fit(frame: session.frames[3], pages: loaded, viewport: viewport, backingScale: 1, settings: session.settings)
            .displayTargets(settings: session.settings, maxDecodeLongSide: global.maxDecodeLongSide)
        let target = try #require(targets.first).target
        #expect(target.pixelSize == PixelSize(width: 300, height: 600))
        #expect(pipeline.prefetchPlan(for: session.id)?.items == [
            PrefetchItem(identity: original[3].entry.identity, renditions: [.display(target)], priority: .near),
        ])
        pair.continuation.finish()
        await task.value
    }

    @Test("相邻书与目录封面按书架排序进入同一份预取计划")
    func adjacentPrefetchFollowsShelf() async throws {
        let tree = MockTree(nodes: [.book("A", pages: 4), .book("B", pages: 6), .book("C", pages: 3), .book("D", pages: 5)])
        var global = GlobalSettings.default
        global.prefetch.neighborBooks = 2
        global.prefetch.shelfCovers = true
        global.prefetch.viewerReadAheadPages = 0
        global.prefetch.viewerDecodeFrames = 0
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let descending = BookSettings(sort: SortSpec(key: .name, ascending: false))
        let store = MockSettingsStore(global: global, pathRules: [PathRule(name: "B", prefix: tree.location("B"), settings: descending)])
        let pipeline = MockImagePipeline(environment: environment)
        let loader = MockBookLoader(environment: environment)
        let tracking = RefreshTrackingShelf(base: MockBookshelf(environment: environment))
        let session = ReaderSession(loader: loader, settings: store, bookshelf: tracking, pipeline: pipeline)
        let a = tree.location("A"), b = tree.location("B"), c = tree.location("C"), d = tree.location("D")

        await session.open(a, at: nil)
        #expect(session.loadError == nil)
        #expect(tracking.listings == 0)
        #expect(pipeline.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)

        session.shelfSortChanged(SortSpec(key: .name))
        let aPages = try await loadedPages(loader, book: a, settings: await store.resolve(for: a))
        let bPages = try await loadedPages(loader, book: b, settings: await store.resolve(for: b))
        let cPages = try await loadedPages(loader, book: c, settings: await store.resolve(for: c))
        #expect(bPages.map(\.entry.name) == ["006.jpg", "005.jpg", "004.jpg", "003.jpg", "002.jpg", "001.jpg"])
        let bCover = try await coverIdentity(loader, environment, b)
        let cCover = try await coverIdentity(loader, environment, c)
        let dCover = try await coverIdentity(loader, environment, d)
        let aCover = try await coverIdentity(loader, environment, a)
        let first = bPages.map(\.entry.identity) + cPages.map(\.entry.identity) + [dCover]
        await eventually { self.adjacentIdentities(pipeline, session) == first }
        expectAdjacent(pipeline, session, first)
        #expect(pipeline.prefetchPlan(for: session.id)?.items.filter { $0.priority == .book }.map(\.identity) == aPages.map(\.entry.identity))
        #expect(tracking.listings == 1)

        session.go(.index(2))
        #expect(self.adjacentIdentities(pipeline, session) == first)
        session.viewportChanged(PixelSize(width: 800, height: 600), backingScale: 1)
        expectAdjacent(pipeline, session, first)

        session.shelfSortChanged(SortSpec(key: .name, ascending: false))
        #expect(pipeline.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)
        await eventually { self.adjacentIdentities(pipeline, session) == [dCover, cCover, bCover] }
        expectAdjacent(pipeline, session, [dCover, cCover, bCover])

        await session.open(b, at: nil)
        let fullA = aPages.map(\.entry.identity)
        await eventually { self.adjacentIdentities(pipeline, session) == fullA + [dCover, cCover] }
        expectAdjacent(pipeline, session, fullA + [dCover, cCover])
        #expect(pipeline.prefetchPlan(for: session.id)?.items.filter { $0.priority == .adjacent }.contains { $0.identity == bCover } == false)

        try await store.updateGlobal { $0.prefetch.neighborBooks = 0 }
        await eventually { self.adjacentIdentities(pipeline, session) == [dCover, cCover, aCover] }
        expectAdjacent(pipeline, session, [dCover, cCover, aCover])

        try await store.updateGlobal { $0.prefetch.shelfCovers = false }
        await eventually { self.adjacentIdentities(pipeline, session).isEmpty }
        #expect(pipeline.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)

        try await store.updateGlobal { $0.prefetch.neighborBooks = 2 }
        await eventually { self.adjacentIdentities(pipeline, session) == fullA }
        expectAdjacent(pipeline, session, fullA)
        #expect(session.loadError == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(tracking.refreshed == false)

        let omitted = OmittingShelf(base: MockBookshelf(environment: environment), omitted: a)
        let another = ReaderSession(loader: loader, settings: MockSettingsStore(global: global), bookshelf: omitted, pipeline: pipeline)
        await another.open(a, at: nil)
        another.shelfSortChanged(SortSpec(key: .name))
        let covers = [bCover, cCover, dCover]
        await eventually { self.adjacentIdentities(pipeline, another) == covers }
        expectAdjacent(pipeline, another, covers)
        #expect(another.loadError == nil)
    }

    @Test("切书和改排序取消旧的相邻枚举，失败不写入 loadError")
    func adjacentPrefetchDropsStaleResults() async throws {
        let tree = MockTree(nodes: [.book("A", pages: 4), .book("B", pages: 6), .book("C", pages: 3), .book("D", pages: 5)])
        var global = GlobalSettings.default
        global.prefetch.neighborBooks = 2
        global.prefetch.shelfCovers = false
        global.prefetch.viewerReadAheadPages = 0
        global.prefetch.viewerDecodeFrames = 0
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let store = MockSettingsStore(global: global)
        let pipeline = MockImagePipeline(environment: environment)
        let shelf = HoldingShelf(environment: environment)
        let session = ReaderSession(loader: MockBookLoader(environment: environment), settings: store, bookshelf: shelf, pipeline: pipeline)
        let a = tree.location("A"), b = tree.location("B"), c = tree.location("C"), d = tree.location("D")

        await session.open(a, at: nil)
        session.shelfSortChanged(SortSpec(key: .name))
        await eventually { shelf.started == 1 }
        session.shelfSortChanged(SortSpec(key: .name, ascending: false))
        await eventually { shelf.started == 2 }
        shelf.release(0)
        await eventually { shelf.finished >= 1 }
        #expect(shelf.cancelled(0))
        #expect(shelf.yielded(0) == false)
        #expect(pipeline.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)
        shelf.release(1)
        await eventually { shelf.finished >= 2 && shelf.yielded(1) }
        #expect(pipeline.prefetchPlan(for: session.id)?.items.contains { $0.priority == .adjacent } == false)

        session.shelfSortChanged(SortSpec(key: .name))
        await eventually { shelf.started == 3 }
        await session.open(d, at: nil)
        await eventually { shelf.started == 4 }
        shelf.release(2)
        await eventually { shelf.finished >= 3 }
        #expect(shelf.cancelled(2))
        #expect(shelf.yielded(2) == false)
        #expect(self.adjacentIdentities(pipeline, session).isEmpty)
        shelf.release(3)
        await eventually { shelf.finished >= 4 && shelf.yielded(3) }
        #expect(self.adjacentIdentities(pipeline, session).isEmpty)
        #expect(session.loadError == nil)
        #expect(session.book?.location == d)

        let failingShelf = ThrowingShelf(base: MockBookshelf(environment: environment))
        let failingSession = ReaderSession(
            loader: MockBookLoader(environment: environment), settings: MockSettingsStore(global: global),
            bookshelf: failingShelf, pipeline: pipeline
        )
        await failingSession.open(a, at: nil)
        failingSession.shelfSortChanged(SortSpec(key: .name))
        await eventually { failingShelf.calls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(failingSession.loadError == nil)
        #expect(failingSession.book?.pages.isEmpty == false)
        #expect(pipeline.prefetchPlan(for: failingSession.id)?.items.contains { $0.priority == .adjacent } == false)

        let partial = ReaderSession(
            loader: FailingBookLoader(base: MockBookLoader(environment: environment), failing: c),
            settings: MockSettingsStore(global: global), bookshelf: MockBookshelf(environment: environment), pipeline: pipeline
        )
        await partial.open(a, at: nil)
        partial.shelfSortChanged(SortSpec(key: .name))
        let bPages = try await loadedPages(MockBookLoader(environment: environment), book: b)
        await eventually { self.adjacentIdentities(pipeline, partial) == bPages.map(\.entry.identity) }
        expectAdjacent(pipeline, partial, bPages.map(\.entry.identity))
        #expect(partial.loadError == nil)
    }

    private func expectAdjacent(_ pipeline: MockImagePipeline, _ session: ReaderSession, _ identities: [ContentIdentity]) {
        let items = pipeline.prefetchPlan(for: session.id)?.items ?? []
        let adjacent = items.filter { $0.priority == .adjacent }
        #expect(adjacent.map(\.identity) == identities)
        #expect(adjacent.allSatisfy { $0.renditions == [.thumbnail, .metadata] })
        guard let index = items.firstIndex(where: { $0.priority == .adjacent }) else {
            #expect(identities.isEmpty)
            return
        }
        #expect(items[..<index].allSatisfy { $0.priority != .adjacent })
        #expect(items[index...].allSatisfy { $0.priority == .adjacent })
    }

    private func adjacentIdentities(_ pipeline: MockImagePipeline, _ session: ReaderSession) -> [ContentIdentity] {
        pipeline.prefetchPlan(for: session.id)?.items.filter { $0.priority == .adjacent }.map(\.identity) ?? []
    }

    private func expectDisplayWindow(
        _ session: ReaderSession, _ pipeline: MockImagePipeline, viewport: PixelSize, maxDecodeLongSide: Int, radius: Int
    ) throws {
        let plan = try #require(pipeline.prefetchPlan(for: session.id))
        let pages = try #require(session.book).pages
        let current = session.currentFrame
        var expected: [PrefetchItem] = []
        let lower = max(session.frames.startIndex, current - radius)
        let upper = min(session.frames.endIndex, current + radius + 1)
        for index in lower..<upper where index != current {
            let targets = PageFrameFit.fit(frame: session.frames[index], pages: pages, viewport: viewport, backingScale: 1, settings: session.settings)
                .displayTargets(settings: session.settings, maxDecodeLongSide: maxDecodeLongSide)
            for (element, target) in targets {
                expected.append(PrefetchItem(identity: pages[element.page].entry.identity, renditions: [.display(target)], priority: .near))
            }
        }
        let actual = plan.items.filter(isDisplay)
        #expect(actual.count == expected.count)
        for item in expected { #expect(actual.contains(item)) }
        let currentIdentities = Set(session.frames[current].elements.map { pages[$0.page].entry.identity })
        #expect(!actual.contains { currentIdentities.contains($0.identity) })
    }

    private func displayRenditions(_ plan: PrefetchPlan) -> Set<RenditionSpec> {
        Set(plan.items.filter(isDisplay).flatMap(\.renditions))
    }

    private func containsDisplay(_ plan: PrefetchPlan?) -> Bool {
        plan?.items.contains(where: isDisplay) ?? false
    }

    private func isDisplay(_ item: PrefetchItem) -> Bool {
        item.renditions.contains { if case .display = $0 { true } else { false } }
    }

    private func eventually(attempts: Int = 200, _ predicate: @MainActor () async -> Bool) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("异步状态未在 \(attempts) 次轮询内到达")
    }
}

func coverIdentity(_ loader: any BookLoader, _ environment: MockEnvironment, _ book: Location) async throws -> ContentIdentity {
    let cover = try #require(try await MockBookshelf(environment: environment).cover(of: book, priority: .adjacent))
    let pages = try await loadedPages(loader, book: book)
    return try #require(pages.first { $0.id == cover }).entry.identity
}

/// 在第一次 `.sorted` 之后停住。会话若结束流，这里的后续刷新不会发生。
final class RefreshTrackingShelf: Bookshelf, @unchecked Sendable {
    private let base: MockBookshelf
    private let state = Mutex<State>(State())
    private struct State { var listings = 0; var refreshed = false }
    init(base: MockBookshelf) { self.base = base }
    var listings: Int { state.withLock { $0.listings } }
    var refreshed: Bool { state.withLock { $0.refreshed } }

    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        state.withLock { $0.listings += 1 }
        let upstream = base.items(in: directory, sort: sort)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        continuation.yield(event)
                        if case .sorted = event {
                            try await Task.sleep(for: .milliseconds(300))
                            self.state.withLock { $0.refreshed = true }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cover(of book: Location, priority: IOPriority) async throws -> Location? { try await base.cover(of: book, priority: priority) }
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? { try await base.neighbor(of: book, direction, sort: sort) }
    func passThrough(_ location: Location) async throws -> Location { try await base.passThrough(location) }
}

/// 每次目录枚举先停住，测试放行后才把真实书架的结果交出去。
final class HoldingShelf: Bookshelf, @unchecked Sendable {
    private struct State {
        var nextID = 0
        var started = 0
        var finished = 0
        var cancelled: Set<Int> = []
        var yielded: Set<Int> = []
        var signals: [Int: AsyncStream<Void>.Continuation] = [:]
    }

    private let base: MockBookshelf
    private let state = Mutex<State>(State())
    init(environment: MockEnvironment) { base = MockBookshelf(environment: environment) }
    var started: Int { state.withLock { $0.started } }
    var finished: Int { state.withLock { $0.finished } }
    func cancelled(_ id: Int) -> Bool { state.withLock { $0.cancelled.contains(id) } }
    func yielded(_ id: Int) -> Bool { state.withLock { $0.yielded.contains(id) } }

    func release(_ id: Int) {
        let continuation = state.withLock { $0.signals.removeValue(forKey: id) }
        continuation?.yield(())
        continuation?.finish()
    }

    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        let id = state.withLock { current -> Int in
            let id = current.nextID
            current.nextID += 1
            return id
        }
        let base = base
        return AsyncThrowingStream { continuation in
            let task = Task {
                var yielded = false
                do {
                    await self.wait(id)
                    if Task.isCancelled { throw CancellationError() }
                    for try await event in base.items(in: directory, sort: sort) {
                        if case .sorted = event { yielded = true }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                let cancelled = Task.isCancelled
                self.state.withLock { current in
                    current.finished += 1
                    if cancelled { current.cancelled.insert(id) }
                    if yielded { current.yielded.insert(id) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cover(of book: Location, priority: IOPriority) async throws -> Location? { try await base.cover(of: book, priority: priority) }
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? { try await base.neighbor(of: book, direction, sort: sort) }
    func passThrough(_ location: Location) async throws -> Location { try await base.passThrough(location) }

    private func wait(_ id: Int) async {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { current in
            current.signals[id] = continuation
            current.started += 1
        }
        for await _ in stream { break }
        state.withLock { $0.signals[id] = nil }
    }
}

final class ThrowingShelf: Bookshelf, @unchecked Sendable {
    private let base: MockBookshelf
    private let state = Mutex(0)
    init(base: MockBookshelf) { self.base = base }
    var calls: Int { state.withLock { $0 } }

    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        state.withLock { $0 += 1 }
        return AsyncThrowingStream { continuation in continuation.finish(throwing: IOError.notFound(directory)) }
    }

    func cover(of book: Location, priority: IOPriority) async throws -> Location? { try await base.cover(of: book, priority: priority) }
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? { try await base.neighbor(of: book, direction, sort: sort) }
    func passThrough(_ location: Location) async throws -> Location { try await base.passThrough(location) }
}

struct OmittingShelf: Bookshelf {
    var base: MockBookshelf
    var omitted: Location

    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error> {
        let upstream = base.items(in: directory, sort: sort)
        let omitted = omitted
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        switch event {
                        case let .appended(entries):
                            let books = entries.filter { $0.location != omitted }
                            if !books.isEmpty { continuation.yield(.appended(books)) }
                        case let .sorted(entries): continuation.yield(.sorted(entries.filter { $0.location != omitted }))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cover(of book: Location, priority: IOPriority) async throws -> Location? { try await base.cover(of: book, priority: priority) }
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location? { try await base.neighbor(of: book, direction, sort: sort) }
    func passThrough(_ location: Location) async throws -> Location { try await base.passThrough(location) }
}

struct FailingBookLoader: BookLoader {
    var base: MockBookLoader
    var failing: Location

    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        guard location != failing else {
            return AsyncThrowingStream { $0.finish(throwing: IOError.notFound(location)) }
        }
        return base.load(location, settings: settings, startingAt: page)
    }
}
