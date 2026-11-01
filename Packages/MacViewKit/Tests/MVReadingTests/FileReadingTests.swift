import Foundation
import MVCache
import MVFoundation
import MVIO
import MVSettings
import MVTestSupport
import Testing
@testable import MVReading

struct FileReadingTests {
    @Test("实际 zip 的 __MACOSX 与 AppleDouble 不成为页面")
    func zipFiltering() async throws {
        let fixture = try ReadingFixture()
        let url = fixture.directory.appending(path: "macos.zip")
        try FileManager.default.copyItem(at: Fixtures.url("archive/zip/macos-metadata.zip"), to: url)
        let pipeline = fixture.mockPipeline([.archive("macos.zip", [.directory("book", [.image("001.jpg", PixelSize(width: 600, height: 900)), .image("002.jpg", PixelSize(width: 600, height: 900))])])])
        let book = try await fixture.location(url)
        let pages = try await loadedPages(fixture.loader(pipeline), book: book)
        #expect(pages.map { $0.entry.name } == ["001.jpg", "002.jpg"])
        #expect(pages.allSatisfy { $0.id.layers.last?.first == "book" && $0.metadata != nil })
    }

    @Test("真实一万项目录渐进交付、后台排序、缓存立即 sorted")
    @MainActor func tenThousandPages() async throws {
        let fixture = try ReadingFixture()
        let names = (1...10_000).map { "page\($0).png" }
        let directory = try fixture.pageDirectory("large", names: names)
        let pipeline = fixture.mockPipeline([.directory("large", names.map { .image($0, PixelSize(width: 64, height: 64)) })])
        let loader = fixture.loader(pipeline)
        let location = try await fixture.location(directory)
        let start = ContinuousClock.now
        let stream = loader.load(location, settings: .default, startingAt: nil)
        #expect(ContinuousClock.now - start < .milliseconds(50))
        var sawPartial = false, sortedCount = 0
        var result: [Page] = []
        for try await event in stream {
            switch event {
            case let .appended(pages):
                #expect(sortedCount == 0)
                if !sawPartial { #expect(pages.count > 0 && pages.count < 10_000); sawPartial = true }
            case let .sorted(pages): result = pages; sortedCount += 1
            case .metadata: break
            }
        }
        #expect(sawPartial && sortedCount == 1)
        #expect(result.map { $0.entry.name } == names)
        let value = ImageMetadata(pixelSize: PixelSize(width: 64, height: 64))
        try await fixture.metadata.store(Dictionary(uniqueKeysWithValues: result.map { ($0.entry.identity.cacheKey, value) }), in: location)
        var stages: [String] = []
        for try await event in loader.load(location, settings: .default, startingAt: nil) {
            switch event {
            case .appended: stages.append("appended")
            case .sorted: stages.append("sorted")
            case let .metadata(values): #expect(values.count == 10_000); stages.append("metadata")
            }
        }
        #expect(stages == ["sorted", "metadata"])
    }

    @Test("缓存后后台 diff 只在内容变化时再发 sorted")
    func changedCachedDirectory() async throws {
        let fixture = try ReadingFixture()
        let directory = try fixture.pageDirectory("book", names: ["2.png"])
        let pipeline = fixture.mockPipeline([.directory("book", [.image("2.png", PixelSize(width: 64, height: 64)), .image("1.png", PixelSize(width: 64, height: 64))])])
        let location = try await fixture.location(directory)
        _ = try await loadedPages(fixture.loader(pipeline), book: location)
        try FileManager.default.linkItem(at: Fixtures.url("image/size/64x64.png"), to: directory.appending(path: "1.png"))
        var counts: [Int] = []
        for try await event in fixture.loader(pipeline).load(location, settings: .default, startingAt: nil) {
            if case let .sorted(pages) = event { counts.append(pages.count) }
            if case .appended = event { Issue.record("缓存命中不得 appended") }
        }
        #expect(counts == [1, 2])
    }

    @Test("慢来源重新枚举前，缓存 sorted 与命中元数据先交付")
    func cachedMetadataBeforeEnumeration() async throws {
        let fixture = try ReadingFixture(), tree = MockTree(nodes: [.book("book", pages: 2)])
        var timing = MockTiming.instant
        timing.latency = .milliseconds(200)
        let environment = MockEnvironment(MockOptions(tree: tree, timing: timing))
        let registry = MockSourceRegistry(environment: environment), book = tree.location("book")
        var entries: [Entry] = []
        for try await batch in try registry.provider(for: book).children(of: book, priority: .book) { entries.append(contentsOf: batch) }
        _ = try await fixture.directories.update(book, listing: DirectoryListing(entries: entries))
        let metadata = ImageMetadata(pixelSize: PixelSize(width: 100, height: 200))
        try await fixture.metadata.store(Dictionary(uniqueKeysWithValues: entries.filter(ReadingListing.media).map { ($0.identity.cacheKey, metadata) }), in: book)
        let loader = FileBookLoader(sources: registry, directories: fixture.directories, metadata: fixture.metadata, pipeline: MockImagePipeline(environment: environment))
        var iterator = loader.load(book, settings: .default, startingAt: nil).makeAsyncIterator()
        let start = ContinuousClock.now
        if let event = try await iterator.next(), case .sorted = event {} else { Issue.record("缓存首项必须 sorted") }
        if let event = try await iterator.next(), case let .metadata(values) = event { #expect(values.count == 2) } else { Issue.record("元数据不得等来源枚举") }
        #expect(ContinuousClock.now - start < .milliseconds(150))
        while try await iterator.next() != nil {}
    }

    @Test("递归深度、系统条目过滤、单层穿透与全部排序键")
    func recursiveBooksAndSortKeys() async throws {
        let fixture = try ReadingFixture()
        let shape = PixelSize(width: 10, height: 20)
        let tree = MockTree(nodes: [.directory("root", [
            .image("0.jpg", shape), .image("._0.jpg", shape), .file("Thumbs.db"), .file("desktop.ini"), .file("a.url"),
            .directory("A", [.image("a.jpg", shape), .directory("deep", [.image("deep.jpg", shape)])]),
            .directory("B", [.image("b.jpg", shape)]),
        ]), .directory("pass", [.file(".DS_Store"), .directory("one", [.directory("two", [.image("1.jpg", shape)])])])])
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let registry = MockSourceRegistry(environment: environment)
        let pipeline = MockImagePipeline(environment: environment)
        let loader = FileBookLoader(sources: registry, directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline)
        var settings = ResolvedBookSettings.default
        settings.recursion = RecursionSpec(enabled: true, maxDepth: 1)
        let pages = try await loadedPages(loader, book: tree.location("root"), settings: settings)
        #expect(pages.map { $0.entry.name } == ["a.jpg", "b.jpg", "0.jpg"])
        let passed = try await loadedPages(loader, book: tree.location("pass"))
        #expect(passed.map { $0.entry.name } == ["1.jpg"])
        settings.sort.foldersFirst = false
        let mixed = try await loadedPages(loader, book: tree.location("root"), settings: settings)
        #expect(mixed.map { $0.entry.name } == ["0.jpg", "a.jpg", "b.jpg"])
        settings.recursion.enabled = false
        #expect(try await loadedPages(loader, book: tree.location("root"), settings: settings).map { $0.entry.name } == ["0.jpg"])
        let a = Entry(identity: ContentIdentity(location: tree.location("A2.jpg"), size: 10, modificationNanos: 20), name: "A2.jpg", kind: .image, created: Date(timeIntervalSince1970: 3))
        let b = Entry(identity: ContentIdentity(location: tree.location("A10.png"), size: 20, modificationNanos: 10), name: "A10.png", kind: .image, created: Date(timeIntervalSince1970: 2))
        let expected: [(SortKey, String)] = [(.name, a.name), (.modified, b.name), (.created, b.name), (.size, a.name), (.type, a.name)]
        for (key, first) in expected {
            #expect(ReadingOrder.sorted([b, a], by: SortSpec(key: key)).first?.name == first)
            #expect(ReadingOrder.sorted([b, a], by: SortSpec(key: key, ascending: false)).last?.name == first)
        }
        let many = (0..<30).map { index in Page(entry: Entry(identity: ContentIdentity(location: tree.location("\(index).jpg"), size: Int64(index), modificationNanos: 0), name: "\(index).jpg", kind: .image)).entry }
        let random = SortSpec(key: .random, randomSeed: 7)
        #expect(ReadingOrder.sorted(many, by: random) == ReadingOrder.sorted(many.reversed(), by: random))
        #expect(ReadingOrder.sorted(many, by: random) != ReadingOrder.sorted(many, by: SortSpec(key: .random, randomSeed: 8)))
    }

    @Test("先用容器元数据缓存，再从目标页补齐整个前缀后探测后续")
    func probingOrder() async throws {
        let fixture = try ReadingFixture()
        let tree = MockTree(nodes: [.book("book", pages: 8)])
        let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
        let registry = MockSourceRegistry(environment: environment)
        let pipeline = TracingPipeline(base: MockImagePipeline(environment: environment))
        let book = tree.location("book")
        let cached = try await registry.provider(for: book).entry(at: tree.location("book/002.jpg"))
        try await fixture.metadata.store([cached.identity.cacheKey: ImageMetadata(pixelSize: PixelSize(width: 2, height: 3))], in: book)
        let loader = FileBookLoader(sources: registry, directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline)
        let result = try await loadedPages(loader, book: book, at: tree.location("book/005.jpg"))
        #expect(result.count == 8)
        #expect(pipeline.metadataOrder.map(\.name) == ["005.jpg", "001.jpg", "003.jpg", "004.jpg", "006.jpg", "007.jpg", "008.jpg"])
        #expect(result[1].metadata?.pixelSize.width == 2)
    }

    @Test("真实书架、缓存首批、排序相邻书、封面和穿透")
    func bookshelf() async throws {
        let fixture = try ReadingFixture()
        let a = try fixture.pageDirectory("shelf/2", names: ["10.png", "2.png"])
        _ = try fixture.pageDirectory("shelf/10", names: ["1.png"])
        let root = try await fixture.location(fixture.directory.appending(path: "shelf"))
        let book = try await fixture.location(a)
        let shelf = FileBookshelf(sources: fixture.registry, directories: fixture.directories)
        var stages: [String] = []
        for try await event in shelf.items(in: root, sort: SortSpec(key: .name)) {
            switch event { case .appended: break; case let .sorted(entries): #expect(entries.map(\.name) == ["2", "10"]); stages.append("sorted") }
        }
        #expect(stages == ["sorted"])
        var iterator = shelf.items(in: root, sort: SortSpec(key: .name)).makeAsyncIterator()
        if let event = try await iterator.next(), case let .sorted(entries) = event { #expect(entries.map(\.name) == ["2", "10"]) }
        else { Issue.record("缓存书架首项必须 sorted") }
        #expect(try await shelf.neighbor(of: book, .forward, sort: SortSpec(key: .name))?.name == "10")
        #expect(try await shelf.neighbor(of: book, .backward, sort: SortSpec(key: .name)) == nil)
        #expect(try await shelf.neighbor(of: book, .backward, sort: SortSpec(key: .name, ascending: false))?.name == "10")
        #expect(try await shelf.cover(of: book, priority: .book)?.name == "2.png")
        let pass = fixture.directory.appending(path: "pass/one/two")
        try FileManager.default.createDirectory(at: pass, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: Fixtures.url("image/size/64x64.png"), to: pass.appending(path: "1.png"))
        let passRoot = try await fixture.location(fixture.directory.appending(path: "pass"))
        let passLocation = try await fixture.location(pass)
        #expect(try await shelf.passThrough(passRoot) == passLocation)
    }
}
