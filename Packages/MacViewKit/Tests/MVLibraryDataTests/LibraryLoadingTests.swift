import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import Synchronization
import Testing
@testable import MVLibraryData

private final class LoadingFixture {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: ".w12-tests-\(UUID().uuidString)")
    let store: SQLiteLibraryStore
    let directories: DirectoryCache
    let metadata: MetadataIndex

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteLibraryStore(databaseURL: directory.appending(path: "library.sqlite"), historyLimit: 1000)
        let index = try CacheIndex(databaseURL: directory.appending(path: "cache.sqlite"))
        directories = DirectoryCache(index: index)
        metadata = MetadataIndex(index: index)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func loadingEntry(_ location: Location, size: Int64 = 10, time: Int64 = 20, kind: EntryKind = .image) -> Entry {
    Entry(identity: ContentIdentity(location: location, size: size, modificationNanos: time), name: location.name, kind: kind)
}

private final class LoadingSource: SourceRegistry, ContainerProvider {
    let listings: [Location: [Entry]]
    let slow: Set<Location>
    private let calls = Mutex<[(Location, IOPriority)]>([])
    var requests: [(Location, IOPriority)] { calls.withLock { $0 } }

    init(_ listings: [Location: [Entry]], slow: Set<Location> = []) { self.listings = listings; self.slow = slow }
    func provider(for location: Location) throws -> any ContainerProvider {
        if case .network = location.root { throw IOError.volumeUnavailable(location.root) }
        return self
    }
    func location(for fileURL: URL) async throws -> Location {
        Location(root: .local, layers: [fileURL.pathComponents.filter { $0 != "/" }])
    }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { AsyncStream { $0.finish() } }
    func canHandle(_ location: Location) -> Bool { true }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        calls.withLock { $0.append((container, priority)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if slow.contains(container) { try await Task.sleep(for: .seconds(60)) }
                    guard let entries = listings[container] else { throw IOError.notFound(container) }
                    continuation.yield(entries.reversed())
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func entry(at location: Location) async throws -> Entry { throw IOError.unsupported(location) }
    func open(_ location: Location) async throws -> any ByteSource { throw IOError.unsupported(location) }
    func fileLease(for location: Location) async throws -> FileLease { throw IOError.unsupported(location) }
}

private final class LoadingPipeline: ImagePipeline {
    private let probes = Mutex<[ContentIdentity]>([])
    let slow: Set<Location>
    init(slow: Set<Location> = []) { self.slow = slow }
    var identities: [ContentIdentity] { probes.withLock { $0 } }
    func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata {
        probes.withLock { $0.append(identity) }
        if slow.contains(identity.location) { try await Task.sleep(for: .seconds(60)) }
        return ImageMetadata(pixelSize: PixelSize(width: 600, height: 900), duration: identity.location.name.hasSuffix(".mp4") ? 3 : nil)
    }
    func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { throw IOError.unsupported(identity.location) }
    func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> { AsyncStream { $0.finish() } }
    func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> { AsyncThrowingStream { $0.finish(throwing: IOError.unsupported(identity.location)) } }
    func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource { throw IOError.unsupported(identity.location) }
    func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource { throw IOError.unsupported(identity.location) }
    func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { throw IOError.unsupported(identity.location) }
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) {}
    func cancelAll(session: SessionID) {}
}

private func availability(_ checker: AvailabilityChecker, _ locations: [Location]) async -> [Location: Availability] {
    var result: [Location: Availability] = [:]
    for await batch in checker.check(locations) { result.merge(batch, uniquingKeysWith: { _, new in new }) }
    return result
}

extension LibraryDataTests.LibraryLoadingTests {
    @Test("C1.7：300 项仅列 10 次，后台优先级，虚拟书不查来源")
    func c17GroupingAndVirtualBooks() async throws {
        let fixture = try LoadingFixture()
        let containers = (0..<10).map { Location(root: .local, layers: [["books", "\($0)"]]) }
        let listings = Dictionary(uniqueKeysWithValues: containers.map { container in
            (container, (0..<30).map { loadingEntry(container.appending("\($0).jpg")) })
        })
        let source = LoadingSource(listings)
        let id = try await fixture.store.createPlaylist(named: "列表")
        let virtual = Location.playlist(id)
        let checker = AvailabilityChecker(sources: source, directories: fixture.directories, store: fixture.store)
        let locations = listings.values.flatMap { $0.map(\.location) }
        let result = await availability(checker, locations + [virtual, virtual])
        #expect(result.count == 301 && result.values.allSatisfy { $0 == .available })
        #expect(source.requests.count == 10)
        #expect(Set(source.requests.map(\.0)) == Set(containers))
        #expect(source.requests.allSatisfy { $0.1 == .background })
        try await fixture.store.deletePlaylist(id)
        #expect(await availability(checker, [virtual])[virtual] == .missing)
        #expect(source.requests.count == 10)
    }

    @Test("C1.7：真实目录移走后缺失，未挂载网络根预检耗时小于 100 ms")
    func c17RealMissingAndUnmountedVolume() async throws {
        let fixture = try LoadingFixture()
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        defer { registry.scheduler.shutdown() }
        let checker = AvailabilityChecker(sources: registry, directories: nil, store: fixture.store)
        let root = Location.Root.network(scheme: "smb", host: "192.0.2.1", share: "unmounted-w12")
        let container = Location(root: root, layers: [["book"]])
        let network = container.appending("page.jpg")

        // 100 ms 只计同步预检。首次读取系统挂载表，快照有效期内可复用；端到端检查另含后台任务调度。
        for attempt in ["首次", "再次"] {
            let start = ContinuousClock.now
            let preflight = Result { try libraryProvider(for: container, sources: registry) }
            let elapsed = ContinuousClock.now - start
            #expect(throws: IOError.volumeUnavailable(root)) { try preflight.get() }
            #expect(elapsed < .milliseconds(100))
            #expect(registry.currentVolumeHealth().allSatisfy { $0.inFlight == 0 })
            print("C1.7: 未挂载根\(attempt)预检=\(elapsed)")
        }
        #expect(await availability(checker, [network])[network] == .volumeUnavailable(root))
        #expect(registry.currentVolumeHealth().allSatisfy { $0.inFlight == 0 })

        let original = fixture.directory.appending(path: "gone")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let moved = try await registry.location(for: original)
        try FileManager.default.moveItem(at: original, to: fixture.directory.appending(path: "renamed"))
        #expect(await availability(checker, [moved])[moved] == .missing)
    }

    @Test("C1.8：容器来源的列表顺序与快照刷新单元测试，校验后只再 sorted 一次并持久化")
    func c18OrderAndSnapshotRefresh() async throws {
        let fixture = try LoadingFixture()
        let a = Location(root: .local, layers: [["a"]])
        let b = Location(root: .local, layers: [["b"]])
        let c = Location(root: .local, layers: [["c"]])
        let zip = Location(root: .local, layers: [["book.zip"]])
        let fresh = [loadingEntry(c.appending("z.jpg")), loadingEntry(zip.appendingLayer(["p.jpg"])),
                     loadingEntry(a.appending("v.mp4"), kind: .video), loadingEntry(b.appending("a.jpg"))]
        var snapshots = fresh
        snapshots[0].identity.size = 1
        snapshots[1].identity.modificationNanos = 1
        let id = try await fixture.store.createPlaylist(named: "顺序")
        _ = try await fixture.store.addItems(snapshots, to: id)
        let source = LoadingSource(Dictionary(grouping: fresh, by: { $0.location.parent! }))
        let pipeline = LoadingPipeline()
        let loader = PlaylistBookLoader(store: fixture.store, sources: source, directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline)
        var settings = ResolvedBookSettings.default
        settings.sort = SortSpec(key: .name, ascending: false)
        settings.recursion = RecursionSpec(enabled: true, maxDepth: 10)
        var sorted: [[Page]] = [], dimensions: [Location: ImageMetadata] = [:]
        var availability: [[Location: Availability]] = []
        for try await event in loader.load(.playlist(id), settings: settings, startingAt: fresh[2].location) {
            switch event {
            case let .sorted(pages): sorted.append(pages)
            case let .metadata(values): dimensions.merge(values, uniquingKeysWith: { _, new in new })
            case let .availability(values): availability.append(values)
            case .playlistRevision: break
            case .appended: Issue.record("播放列表只发 sorted")
            }
        }
        #expect(sorted.count == 2)
        #expect(sorted.first?.map(\.entry) == snapshots)
        #expect(sorted.last?.map(\.entry) == fresh)
        #expect(sorted.allSatisfy { $0.map(\.id) == fresh.map(\.location) })
        #expect(try await fixture.store.items(of: id) == fresh)
        try await fixture.store.flush()
        let reopened = try SQLiteLibraryStore(databaseURL: fixture.directory.appending(path: "library.sqlite"), historyLimit: 1000)
        #expect(try await reopened.items(of: id) == fresh)
        #expect(source.requests.count == 4 && pipeline.identities.count == 4)
        #expect(availability.count == 4 && availability.allSatisfy { $0.count == 1 && $0.values.allSatisfy { $0 == .available } })
        #expect(Set(availability.flatMap(\.keys)) == Set(fresh.map(\.location)))
        #expect(dimensions[fresh[2].location]?.duration == 3)
        await #expect(throws: IOError.notFound(.playlist(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))) {
            for try await _ in loader.load(.playlist(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), settings: .default, startingAt: nil) {}
        }
    }

    @Test("C1.8：同容器从 startingAt 探测，命中身份缓存不重复探测")
    func c18ProbeOrderAndMetadataCache() async throws {
        let fixture = try LoadingFixture()
        let container = Location(root: .local, layers: [["order"]])
        let entries = (0..<4).map { loadingEntry(container.appending("\($0).jpg")) }
        let id = try await fixture.store.createPlaylist(named: "探测")
        _ = try await fixture.store.addItems(entries, to: id)
        let cached = ImageMetadata(pixelSize: PixelSize(width: 10, height: 20))
        try await fixture.metadata.store([entries[3].identity.cacheKey: cached], in: container)
        let pipeline = LoadingPipeline()
        let loader = PlaylistBookLoader(store: fixture.store, sources: LoadingSource([container: entries]), directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline)
        var values: [Location: ImageMetadata] = [:]
        for try await event in loader.load(.playlist(id), settings: .default, startingAt: entries[2].location) {
            if case let .metadata(batch) = event { values.merge(batch, uniquingKeysWith: { _, new in new }) }
        }
        #expect(pipeline.identities.map(\.location) == [entries[2].location, entries[0].location, entries[1].location])
        #expect(values[entries[3].location] == cached)
    }

    @Test("C1.21：未挂载、缺页与超时容器隔离，正常页先到，全部占位可排至末页")
    func c121ContainerIsolationAndPlaceholders() async throws {
        let fixture = try LoadingFixture()
        let network = loadingEntry(Location(root: .network(scheme: "smb", host: "192.0.2.1", share: "none"), layers: [["p.jpg"]]))
        let missing = loadingEntry(Location(root: .local, layers: [["deleted", "p.jpg"]]))
        let slow = loadingEntry(Location(root: .local, layers: [["slow", "p.jpg"]]))
        let blocked = loadingEntry(Location(root: .local, layers: [["blocked", "p.jpg"]]))
        let good = loadingEntry(Location(root: .local, layers: [["healthy", "p.jpg"]]))
        let absent = loadingEntry(good.location.parent!.appending("absent.jpg"))
        let entries = [network, missing, slow, blocked, absent, good]
        let id = try await fixture.store.createPlaylist(named: "隔离")
        _ = try await fixture.store.addItems(entries, to: id)
        let source = LoadingSource([slow.location.parent!: [slow], blocked.location.parent!: [blocked], good.location.parent!: [good]], slow: [slow.location.parent!])
        let pipeline = LoadingPipeline(slow: [blocked.location])
        let loader = PlaylistBookLoader(store: fixture.store, sources: source, directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline, deadline: .milliseconds(150))
        let start = ContinuousClock.now
        var pages: [Page] = [], values: [Location: ImageMetadata] = [:]
        var healthyArrived: Duration?
        var availability: [[Location: Availability]] = []
        for try await event in loader.load(.playlist(id), settings: .default, startingAt: network.location) {
            switch event {
            case let .sorted(value): pages = value
            case let .metadata(batch):
                values.merge(batch, uniquingKeysWith: { _, new in new })
                if batch[good.location] != nil { healthyArrived = ContinuousClock.now - start }
            case let .availability(batch): availability.append(batch)
            case .playlistRevision: break
            case .appended: Issue.record("不得改变页序")
            }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        let healthyElapsed = try #require(healthyArrived)
        #expect(healthyElapsed < .milliseconds(150))
        print("C1.21: 正常容器首批元数据=\(healthyElapsed)")
        #expect(pages.map(\.id) == entries.map(\.location) && values.count == entries.count)
        for entry in entries.dropLast() {
            #expect(values[entry.location]?.pixelSize == PixelSize(width: 1000, height: 1414))
        }
        #expect(values[good.location]?.pixelSize == PixelSize(width: 600, height: 900))
        #expect(availability.count == 5)
        #expect(availability.contains { $0 == [good.location: .available, absent.location: .missing] })
        let states = availability.reduce(into: [Location: Availability]()) { $0.merge($1, uniquingKeysWith: { _, new in new }) }
        #expect(states == [network.location: .volumeUnavailable(network.location.root), missing.location: .missing,
                           slow.location: .volumeUnavailable(slow.location.root), blocked.location: .available,
                           absent.location: .missing, good.location: .available])
        #expect(availability.reduce(0) { $0 + $1.count } == entries.count)
        #expect(!pipeline.identities.contains { $0.location == network.location || $0.location == missing.location })
        for index in pages.indices {
            pages[index].metadata = values[pages[index].id]
            let fit = PageFrameFit.fit(frame: PageFrame(elements: [PageFrameElement(page: index)]), pages: pages, viewport: PixelSize(width: 1000, height: 800), backingScale: 1, settings: .default)
            #expect(fit.size.height > 0)
        }
        #expect(pages.last?.id == good.location)
    }
}
