import MVFoundation
import MVSettings
import MVTestSupport
import Testing
@testable import MVReading

extension ReadingSessionTests {
    @Test("C1.23 首末页翻越回调：单页、双页、首页单页")
    func scriptBoundaryForPageLayouts() async throws {
        for layout in [(PageMode.single, false), (.double, false), (.double, true)] {
            var global = GlobalSettings.default
            global.defaultBook.pageMode = layout.0
            global.defaultBook.firstPageSingle = layout.1
            let (session, _, _) = setup(global: global)
            await session.open(tree.location("B"), at: nil)
            var events: [NavigationDirection] = []
            session.onBoundaryReached = { events.append($0) }
            session.go(.first)
            let initial = session.currentPage
            session.go(.previousFrame); session.go(.previousPage)
            #expect(events == [.backward, .backward])
            #expect(session.currentFrame == 0 && session.currentPage == initial)
            events.removeAll()
            session.go(.nextFrame)
            session.go(.nextPage)
            #expect(events.isEmpty)
            session.go(.last)
            let end = session.currentPage
            session.go(.nextFrame); session.go(.nextPage)
            #expect(events == [.forward, .forward])
            #expect(session.currentFrame == session.frames.count - 1 && session.currentPage == end)
        }
    }

    @Test("C1.23 单张图片前后越界不改变位置")
    func scriptBoundaryForSingleImageBook() async {
        let tree = MockTree(nodes: [.book("Only", pages: 1)])
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let session = ReaderSession(loader: MockBookLoader(environment: environment), settings: MockSettingsStore(), bookshelf: MockBookshelf(environment: environment), pipeline: MockImagePipeline(environment: environment))
        await session.open(tree.location("Only"), at: nil)
        var events: [NavigationDirection] = []
        session.onBoundaryReached = { events.append($0) }
        for move: PageMove in [.previousFrame, .previousPage, .nextFrame, .nextPage] { session.go(move) }
        #expect(events == [.backward, .backward, .forward, .forward])
        #expect(session.currentPage == 0 && session.currentFrame == 0)
    }

    @Test("C1.23 双页同一帧内锚点不因越界而改变")
    func scriptBoundaryPreservesPageAnchor() async {
        var global = GlobalSettings.default
        global.defaultBook.pageMode = .double; global.defaultBook.firstPageSingle = false
        let (session, _, _) = setup(global: global)
        await session.open(tree.location("B"), at: nil)
        session.go(.index(1))
        #expect(session.currentFrame == 0 && session.currentPage == 1)
        var events: [NavigationDirection] = []
        session.onBoundaryReached = { events.append($0) }
        session.go(.previousFrame)
        #expect(events == [.backward] && session.currentPage == 1)
    }
}
