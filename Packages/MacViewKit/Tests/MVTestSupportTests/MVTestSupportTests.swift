import CoreGraphics
import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVReading
import MVServices
import MVSettings
import Testing
@testable import MVTestSupport

/// 验收：用 makeMock 打开 100 页的模拟书，翻到第 50 页，依次收到占位图、浏览图和精确图。时序用默认值（2.5 张/秒）。
@MainActor
@Test func mockServicesDeliverPageFiftyInThreeStages() async throws {
    let tree = MockTree(nodes: [.book("模拟书", pages: 100)])
    let services = CoreServices.makeMock(MockOptions(tree: tree))
    let session = services.makeSession()
    await session.open(tree.location("模拟书"), at: nil)
    #expect(session.loadError == nil)
    #expect(session.book?.isEnumerated == true)
    #expect(session.frames.count == 100)

    session.go(.index(49))
    let book = try #require(session.book)
    let page = book.pages[session.frames[session.currentFrame].elements[0].page]
    #expect(page.entry.name == "050.jpg")
    #expect(page.metadata?.pixelSize == PixelSize(width: 3600, height: 5400))

    var stages: [RenderedImage] = []
    let target = DisplayTarget(pixelSize: PixelSize(width: 1200, height: 1800))
    for try await image in services.pipeline.image(for: page.id, target: target, allowOriginal: false, priority: .visible) {
        stages.append(image)
    }
    #expect(stages.map(\.quality) == [.placeholder, .browse, .exact])
    #expect(stages.map { PixelSize(width: $0.image.width, height: $0.image.height) } == [
        PixelSize(width: 341, height: 512), PixelSize(width: 1365, height: 2048), PixelSize(width: 1200, height: 1800),
    ])
}

@MainActor
struct ReaderSessionTests {
    let tree = MockTree(nodes: [.directory("书架", [.book("A", pages: 5), .book("B", pages: 3), .book("C", pages: 4)])])

    private func makeSession() -> ReaderSession {
        CoreServices.makeMock(MockOptions(tree: tree, timing: .instant)).makeSession()
    }

    @Test func opensAtTheRequestedPageAndNavigates() async {
        let session = makeSession()
        await session.open(tree.location("书架/A"), at: tree.location("书架/A/003.jpg"))
        #expect(session.currentFrame == 2)
        session.go(.nextPage)
        #expect(session.currentFrame == 3)
        session.go(.nextFrame)
        session.go(.nextFrame)
        #expect(session.currentFrame == 4)
        session.go(.previousPage)
        #expect(session.currentFrame == 3)
        session.go(.first)
        session.go(.previousFrame)
        #expect(session.currentFrame == 0)
        session.go(.index(99))
        #expect(session.currentFrame == 4)
    }

    @Test func opensNeighborBooksInShelfOrder() async {
        let session = makeSession()
        let byName = SortSpec(key: .name)
        await session.open(tree.location("书架/B"), at: nil)
        await session.openNeighborBook(.forward, sort: byName)
        #expect(session.book?.location == tree.location("书架/C"))
        #expect(session.book?.pages.count == 4)
        await session.openNeighborBook(.forward, sort: byName)
        #expect(session.book?.location == tree.location("书架/C"))
        await session.openNeighborBook(.forward, sort: SortSpec(key: .name, ascending: false))
        #expect(session.book?.location == tree.location("书架/B"))
        await session.openNeighborBook(.backward, sort: byName)
        #expect(session.book?.location == tree.location("书架/A"))
    }

    @Test func settingChangesGoToTheBookLayer() async {
        let session = makeSession()
        await session.open(tree.location("书架/A"), at: nil)
        #expect(session.settings == .default)
        session.update { $0.direction = .rightToLeft }
        #expect(session.settings.direction == .rightToLeft)
        #expect(session.settings.pageMode == ResolvedBookSettings.default.pageMode)
    }

    @Test func missingBookReportsTheError() async {
        let session = makeSession()
        await session.open(tree.location("书架/不存在"), at: nil)
        #expect(session.loadError as? IOError == .notFound(tree.location("书架/不存在")))
        #expect(session.frames.isEmpty)
    }
}

struct MockSourceTests {
    @Test func treeLocationsFollowArchiveLayers() {
        #expect(MockTree.sample.location("漫画/作品 1.zip!/001.jpg").layers == [["漫画", "作品 1.zip"], ["001.jpg"]])
        #expect(MockTree.sample.location("") == Location(root: MockTree.defaultRoot))
    }

    @Test func providerEnumeratesInBatchesAndFindsArchiveEntries() async throws {
        var timing = MockTiming.instant
        timing.batchSize = 10
        let tree = MockTree.sample
        let registry = MockSourceRegistry(environment: MockEnvironment(MockOptions(tree: tree, timing: timing)))
        let book = tree.location("漫画/作品 1.zip")
        let provider = try registry.provider(for: book)
        var batches: [[Entry]] = []
        for try await batch in provider.children(of: book, priority: .visible) {
            batches.append(batch)
        }
        #expect(batches.map(\.count) == [10, 10, 10, 10, 3])
        #expect(batches.joined().contains { $0.name == "040.jpg" })
        let page = try await provider.entry(at: tree.location("漫画/作品 1.zip!/007.jpg"))
        #expect(page.kind == .image)
        #expect(try await registry.location(for: URL(fileURLWithPath: "/Volumes/Mock/画集/系列 A")) == tree.location("画集/系列 A"))
        #expect(throws: IOError.self) { try registry.provider(for: Location(root: .local)) }
    }

    @Test func volumeFollowsTheScriptAndBlocksAccess() async throws {
        let environment = MockEnvironment(MockOptions(tree: .sample, timing: .instant, volumeScript: [
            MockVolumeStep(after: .milliseconds(100), state: .degraded("NAS 响应慢"), stuck: 2),
            MockVolumeStep(after: .milliseconds(100), state: .unavailable),
        ]))
        let registry = MockSourceRegistry(environment: environment)
        var states: [VolumeState] = []
        for await health in registry.volumeHealth() {
            states.append(health[0].state)
            if states.count == 3 { break }
        }
        #expect(states == [.healthy, .degraded("NAS 响应慢"), .unavailable])
        let cover = MockTree.sample.location("动图与视频/封面.jpg")
        let pipeline = MockImagePipeline(environment: environment)
        await #expect(throws: IOError.volumeUnavailable(MockTree.defaultRoot)) {
            try await pipeline.metadata(for: cover, priority: .visible)
        }
        environment.setVolumeState(.healthy)
        #expect(try await pipeline.metadata(for: cover, priority: .visible).pixelSize == PixelSize(width: 2400, height: 3600))
    }
}

struct MockPipelineTests {
    private let tree = MockTree(nodes: [.book("书", pages: 20, hiddenFiles: false)])

    private func pipeline(readsPerSecond: Double = .infinity, failures: [Location: IOError] = [:]) -> MockImagePipeline {
        var timing = MockTiming.instant
        timing.readsPerSecond = readsPerSecond
        return MockImagePipeline(environment: MockEnvironment(MockOptions(tree: tree, timing: timing, failures: failures)))
    }

    private func page(_ number: Int) -> Location {
        tree.location(String(format: "书/%03d.jpg", number))
    }

    @Test func firstVisitsWaitForThroughputAndRevisitsDoNot() async throws {
        let pipeline = pipeline(readsPerSecond: 20)
        let pages = (1...6).map(page)
        let clock = ContinuousClock()
        let first = try await clock.measure {
            for await (_, result) in pipeline.thumbnails(for: pages, maxPixel: 256, priority: .visible) {
                _ = try result.get()
            }
        }
        let second = try await clock.measure {
            for await (_, result) in pipeline.thumbnails(for: pages, maxPixel: 256, priority: .visible) {
                _ = try result.get()
            }
        }
        #expect(first >= .milliseconds(250))
        #expect(second < .milliseconds(100))
    }

    @Test func visibleRequestsJumpAheadOfBackgroundOnes() async throws {
        let pipeline = pipeline(readsPerSecond: 50)
        let completed = Collector<Location>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 1...7 {
                group.addTask {
                    _ = try await pipeline.thumbnail(for: page(number), maxPixel: 64, priority: .background)
                    await completed.append(page(number))
                }
            }
            try await Task.sleep(for: .milliseconds(5))
            group.addTask {
                _ = try await pipeline.thumbnail(for: page(8), maxPixel: 64, priority: .visible)
                await completed.append(page(8))
            }
            try await group.waitForAll()
        }
        #expect(try #require(await completed.items.firstIndex(of: page(8))) <= 1)
    }

    @Test func cancelledRequestsLeaveTheQueue() async throws {
        let pipeline = pipeline(readsPerSecond: 10)
        let flood = Task {
            for await _ in pipeline.thumbnails(for: (1...19).map(page), maxPixel: 64, priority: .background) {}
        }
        try await Task.sleep(for: .milliseconds(30))
        flood.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let elapsed = try await ContinuousClock().measure {
            _ = try await pipeline.thumbnail(for: page(20), maxPixel: 64, priority: .background)
        }
        #expect(elapsed < .milliseconds(400))
    }

    @Test func injectedFailuresSurfaceAsIOErrors() async throws {
        let broken = page(2)
        let pipeline = pipeline(failures: [broken: .timeout])
        await #expect(throws: IOError.timeout) {
            try await pipeline.thumbnail(for: broken, maxPixel: 128, priority: .visible)
        }
        await #expect(throws: IOError.timeout) {
            for try await _ in pipeline.image(for: broken, target: DisplayTarget(pixelSize: PixelSize(width: 100, height: 150)), allowOriginal: false, priority: .visible) {}
        }
        var succeeded: [Location: Bool] = [:]
        for await (location, result) in pipeline.thumbnails(for: [page(1), broken], maxPixel: 128, priority: .visible) {
            succeeded[location] = (try? result.get()) != nil
        }
        #expect(succeeded == [page(1): true, broken: false])
        await #expect(throws: IOError.unsupported(tree.location("书"))) {
            try await pipeline.metadata(for: tree.location("书"), priority: .visible)
        }
    }

    @Test func upscaledTargetsGetTheOriginalWhenAllowed() async throws {
        let pipeline = pipeline()
        let target = DisplayTarget(pixelSize: PixelSize(width: 4000, height: 6000))
        var last: RenderedImage?
        for try await image in pipeline.image(for: page(1), target: target, allowOriginal: true, priority: .visible) {
            last = image
        }
        #expect(last?.quality == .original)
        #expect(last.map { PixelSize(width: $0.image.width, height: $0.image.height) } == PixelSize(width: 2731, height: 4096))
    }

    @Test func animatedVideoAndTiledSources() async throws {
        let sample = MockTree.sample
        let pipeline = MockImagePipeline(environment: MockEnvironment(MockOptions(tree: sample, timing: .instant)))
        let gif = try await pipeline.animatedFrames(for: sample.location("动图与视频/循环.gif"), target: DisplayTarget(pixelSize: PixelSize(width: 240, height: 135)))
        #expect(gif.frameCount == 24)
        #expect(try await gif.frame(at: 3).image.width == 240)
        let poster = try await pipeline.videoPoster(for: sample.location("动图与视频/片段.mp4"), maxPixel: 320)
        #expect(poster.image.width == 320 && poster.image.height == 180)
        let cover = sample.location("动图与视频/封面.jpg")
        await #expect(throws: IOError.unsupported(cover)) {
            try await pipeline.videoPoster(for: cover, maxPixel: 320)
        }
        let tiles = try await pipeline.tiledSource(for: cover)
        #expect(tiles.pixelSize == PixelSize(width: 2400, height: 3600))
        #expect(try await tiles.tile(CGRect(x: 0, y: 0, width: 512, height: 512), scale: 0.5).image.width == 256)
    }

    @Test func prefetchPlansAreKeptPerSession() {
        let pipeline = pipeline()
        let session = SessionID()
        let plan = PrefetchPlan(items: [PrefetchItem(location: page(1), renditions: [.thumbnail, .metadata], priority: .book)])
        pipeline.setPrefetchPlan(plan, session: session)
        #expect(pipeline.prefetchPlan(for: session) == plan)
        pipeline.cancelAll(session: session)
        #expect(pipeline.prefetchPlan(for: session) == nil)
    }
}

struct MockSettingsTests {
    @Test func resolvesRulesBySpecificityThenBookMemory() async {
        let tree = MockTree.sample
        let book = tree.location("画集/系列 A/第 1 卷")
        let store = MockSettingsStore(pathRules: [
            PathRule(name: "系列 A", prefix: tree.location("画集/系列 A"), settings: BookSettings(direction: .rightToLeft, scaleMode: .fitWidth)),
            PathRule(name: "画集", prefix: tree.location("画集"), settings: BookSettings(pageMode: .double, direction: .leftToRight)),
            PathRule(name: "漫画", prefix: tree.location("漫画"), settings: BookSettings(browseMode: .waterfall)),
        ], memories: [BookMemory(book: book, settings: BookSettings(scaleMode: .original))])
        let resolved = await store.resolve(for: book)
        #expect(resolved.pageMode == .double)
        #expect(resolved.direction == .rightToLeft)
        #expect(resolved.scaleMode == .original)
        #expect(resolved.browseMode == .paged)
    }

    @Test func changesStreamReportsUpdatesAndFileErrors() async throws {
        let store = MockSettingsStore()
        var changes = store.changes().makeAsyncIterator()
        try await store.updateGlobal { $0.maxDecodeLongSide = 4096 }
        store.simulateFileError(file: "settings.json", message: "第 3 行语法错误")
        let first = await changes.next()
        let second = await changes.next()
        #expect(first == .global)
        #expect(second == .fileError(file: "settings.json", message: "第 3 行语法错误"))
        #expect(await store.global().maxDecodeLongSide == 4096)
    }
}

struct MockReadingTests {
    @Test func loaderEmitsArrivalsThenSortedThenMetadata() async throws {
        var timing = MockTiming.instant
        timing.batchSize = 4
        let tree = MockTree(nodes: [.book("书", pages: 10)])
        let loader = MockBookLoader(environment: MockEnvironment(MockOptions(tree: tree, timing: timing)))
        var appended: [Page] = []
        var sorted: [Page]?
        var metadata: [Location: ImageMetadata] = [:]
        for try await event in loader.load(tree.location("书"), settings: .default) {
            switch event {
            case let .appended(pages):
                #expect(sorted == nil)
                appended += pages
            case let .sorted(pages):
                #expect(sorted == nil)
                sorted = pages
            case let .metadata(values):
                #expect(sorted != nil)
                metadata.merge(values) { $1 }
            }
        }
        let names = try #require(sorted).map(\.entry.name)
        #expect(names == (1...10).map { String(format: "%03d.jpg", $0) })
        #expect(Set(appended.map(\.entry.name)) == Set(names))
        #expect(metadata.count == 10)
    }

    @Test func loaderFollowsTheSortSpec() async throws {
        let tree = MockTree(nodes: [.book("书", pages: 12, hiddenFiles: false)])
        let loader = MockBookLoader(environment: MockEnvironment(MockOptions(tree: tree, timing: .instant)))
        func order(_ sort: SortSpec) async throws -> [String] {
            var settings = ResolvedBookSettings.default
            settings.sort = sort
            for try await event in loader.load(tree.location("书"), settings: settings) {
                if case let .sorted(pages) = event {
                    return pages.map(\.entry.name)
                }
            }
            return []
        }
        let names = (1...12).map { String(format: "%03d.jpg", $0) }
        #expect(try await order(SortSpec(key: .name, ascending: false)) == Array(names.reversed()))
        #expect(try await order(SortSpec(key: .modified)) == names)
        let shuffled = try await order(SortSpec(key: .random, randomSeed: 42))
        #expect(shuffled != names)
        #expect(Set(shuffled) == Set(names))
        #expect(try await order(SortSpec(key: .random, randomSeed: 42)) == shuffled)
    }

    @Test func bookshelfListsBooksCoversNeighborsAndPassesThrough() async throws {
        let tree = MockTree.sample
        let shelf = MockBookshelf(environment: MockEnvironment(MockOptions(tree: tree, timing: .instant)))
        var sorted: [Entry] = []
        for try await event in shelf.items(in: tree.location("漫画"), sort: SortSpec(key: .name)) {
            if case let .sorted(entries) = event {
                sorted = entries
            }
        }
        #expect(sorted.map(\.name) == ["作品 3", "作品 1.zip", "作品 2.cbz"])
        #expect(try await shelf.cover(of: tree.location("画集/系列 A/第 1 卷"), priority: .visible) == tree.location("画集/系列 A/第 1 卷/001.jpg"))
        #expect(try await shelf.cover(of: tree.location("漫画/作品 3"), priority: .visible) == tree.location("漫画/作品 3/第 1 话/001.jpg"))
        let byName = SortSpec(key: .name)
        #expect(try await shelf.neighbor(of: tree.location("画集/系列 A/第 2 卷"), .forward, sort: byName) == tree.location("画集/系列 A/第 3 卷"))
        #expect(try await shelf.neighbor(of: tree.location("画集/系列 A/第 6 卷"), .forward, sort: byName) == nil)
        #expect(try await shelf.passThrough(tree.location("单层穿透")) == tree.location("单层穿透/唯一子目录/内层的书"))
        #expect(try await shelf.passThrough(tree.location("画集")) == tree.location("画集"))
    }
}

private actor Collector<Element: Sendable> {
    private(set) var items: [Element] = []

    func append(_ item: Element) {
        items.append(item)
    }
}
