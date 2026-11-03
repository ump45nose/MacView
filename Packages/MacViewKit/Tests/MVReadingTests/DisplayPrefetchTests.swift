import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVSettings
import MVTestSupport
import Synchronization
import Testing
@testable import MVReading

struct DisplayPrefetchTests {
    @Test("分页预解码后下一页帧命中 L1，100 次里第 95 次不超过 8ms")
    func prefetchedDisplayHitsMemoryCache() async throws {
        let fixture = try ReadingFixture()
        let registry = CountingRegistry(base: fixture.registry)
        let cacheDirectory = fixture.directory.appending(path: "pipeline-cache")
        let index = try CacheIndex(databaseURL: cacheDirectory.appending(path: "index.sqlite"))
        let thumbnails = try DiskCache(tier: .thumbnails, cacheDirectory: cacheDirectory, budget: 32 << 20, index: index)
        let caches = PipelineCaches(
            raw: MemoryCache(budget: 32 << 20), decoded: MemoryCache(budget: 256 << 20),
            thumbnails: thumbnails, browse: nil, metadata: MetadataIndex(index: index)
        )
        let pipeline = FileImagePipeline(
            sources: registry, decoder: ImageDecoder(), caches: caches,
            configuration: PipelineConfiguration(thumbnailLongSide: 128, browseBounds: PixelSize(width: 320, height: 480))
        )
        do {
            let samples = try await samples(fixture: fixture, registry: registry, caches: caches, pipeline: pipeline)
            #expect(samples.count == 100)
            guard samples.count == 100 else { return }
            let sorted = samples.sorted()
            #expect(sorted[94] <= .milliseconds(8), "P95 \(sorted[94])，最大 \(sorted[sorted.count - 1])")
        } catch {
            await pipeline.shutdown()
            fixture.registry.scheduler.shutdown()
            throw error
        }
        await pipeline.shutdown()
        fixture.registry.scheduler.shutdown()
    }

    private func samples(
        fixture: ReadingFixture, registry: CountingRegistry, caches: PipelineCaches, pipeline: FileImagePipeline
    ) async throws -> [Duration] {
        let names = (0..<102).map { String(format: "%03d.png", $0) }
        let directory = try fixture.pageDirectory("spread", names: names)
        var bookSettings = ResolvedBookSettings.default
        bookSettings.scaleMode = .fitWindow
        bookSettings.allowUpscale = true
        bookSettings.pageMode = .single
        bookSettings.firstPageSingle = true
        bookSettings.resample = .lanczos
        bookSettings.sharpen = 0
        var global = GlobalSettings.default
        global.defaultBook = bookSettings
        global.prefetch.currentBookPages = false
        global.prefetch.viewerReadAheadPages = 0
        global.prefetch.viewerDecodeFrames = 2
        global.maxDecodeLongSide = 8192
        let location = try await registry.location(for: directory)
        let session = await ReaderSession(
            loader: FileBookLoader(sources: registry, directories: fixture.directories, metadata: fixture.metadata, pipeline: pipeline),
            settings: MockSettingsStore(global: global),
            bookshelf: FileBookshelf(sources: registry, directories: fixture.directories),
            pipeline: pipeline
        )
        await session.open(location, at: nil)
        let opened = await session.book
        let pages = try #require(opened).pages
        #expect(pages.map(\.entry.name) == names)
        #expect(pages.allSatisfy { $0.metadata?.pixelSize == PixelSize(width: 64, height: 64) })
        let frames = await session.frames
        #expect(frames.count == 102)
        let viewport = PixelSize(width: 40, height: 80)
        let settings = await session.settings
        let probe = PageFrameFit.fit(frame: frames[1], pages: pages, viewport: viewport, backingScale: 1, settings: settings)
        #expect(probe.pages.map(\.pixelSize) == [PixelSize(width: 40, height: 40)])
        #expect(probe.size == PixelSize(width: 40, height: 40))
        await session.viewportChanged(viewport, backingScale: 1)
        var samples: [Duration] = []
        samples.reserveCapacity(100)
        for index in 0..<100 {
            await session.go(.index(index))
            let current = await session.currentFrame
            #expect(current == index)
            let targets = PageFrameFit.fit(frame: frames[index + 1], pages: pages, viewport: viewport, backingScale: 1, settings: settings)
                .displayTargets(settings: settings, maxDecodeLongSide: global.maxDecodeLongSide)
            let pair = try #require(targets.first)
            #expect(targets.count == 1)
            #expect(pair.target.pixelSize == PixelSize(width: 40, height: 40))
            let identity = pages[pair.element.page].entry.identity
            let target = pair.target
            let key = identity.cacheKey + "|display|\(target.pixelSize.width)x\(target.pixelSize.height)|\(target.filter.rawValue)|\(target.sharpen.bitPattern)"
            try await waitUntilCached(caches.decoded, key: key, page: index)
            let hit = try await Task.detached {
                let opens = registry.opens(for: identity)
                let reads = registry.reads(for: identity)
                let started = ContinuousClock.now
                var elapsed: Duration?
                for try await image in pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible) {
                    if elapsed == nil, image.quality >= .exact { elapsed = ContinuousClock.now - started }
                }
                guard let elapsed else { throw DisplayPrefetchTimeout(page: index, key: key) }
                return Hit(elapsed: elapsed, opened: registry.opens(for: identity) - opens, read: registry.reads(for: identity) - reads)
            }.value
            #expect(hit.opened == 0, "第 \(index) 页 image(for:) 增加了 \(hit.opened) 次 open")
            #expect(hit.read == 0, "第 \(index) 页 image(for:) 增加了 \(hit.read) 次 read")
            samples.append(hit.elapsed)
        }
        return samples
    }

    private func waitUntilCached(_ cache: MemoryCache<String, RenderedImage>, key: String, page: Int) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            if let image = cache.value(for: key), image.quality >= .exact { return }
            if clock.now - start > .seconds(8) { throw DisplayPrefetchTimeout(page: page, key: key) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct Hit: Sendable {
    var elapsed: Duration
    var opened: Int
    var read: Int
}

private struct DisplayPrefetchTimeout: Error, CustomStringConvertible {
    var page: Int
    var key: String
    var description: String { "第 \(page) 页的显示尺寸未进入 L1 或未交付：\(key)" }
}

/// 真实文件来源的计数外壳，只记录 open 和 read。
private final class CountingRegistry: SourceRegistry, Sendable {
    let base: FileSourceRegistry
    private let control = ReadControl()

    init(base: FileSourceRegistry) { self.base = base }

    func opens(for identity: ContentIdentity) -> Int { control.opens(for: identity) }
    func reads(for identity: ContentIdentity) -> Int { control.reads(for: identity) }
    func provider(for location: Location) throws -> any ContainerProvider {
        CountingProvider(base: try base.provider(for: location), control: control)
    }
    func location(for fileURL: URL) async throws -> Location { try await base.location(for: fileURL) }
    func volumeHealth() -> AsyncStream<[VolumeHealth]> { base.volumeHealth() }
}

private final class ReadControl: Sendable {
    private struct Counts: Sendable {
        var opens = 0
        var reads = 0
    }

    private let counts = Mutex<[ContentIdentity: Counts]>([:])

    func opened(_ identity: ContentIdentity) {
        counts.withLock { state in
            var value = state[identity] ?? Counts()
            value.opens += 1
            state[identity] = value
        }
    }

    func read(_ identity: ContentIdentity) {
        counts.withLock { state in
            var value = state[identity] ?? Counts()
            value.reads += 1
            state[identity] = value
        }
    }

    func opens(for identity: ContentIdentity) -> Int { counts.withLock { $0[identity]?.opens ?? 0 } }
    func reads(for identity: ContentIdentity) -> Int { counts.withLock { $0[identity]?.reads ?? 0 } }
}

private struct CountingProvider: ContainerProvider {
    var base: any ContainerProvider
    var control: ReadControl

    func canHandle(_ location: Location) -> Bool { base.canHandle(location) }
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
        base.children(of: container, priority: priority)
    }
    func entry(at location: Location) async throws -> Entry { try await base.entry(at: location) }
    func open(_ location: Location) async throws -> any ByteSource {
        let source = try await base.open(location)
        control.opened(source.identity)
        return CountingSource(base: source, control: control)
    }
    func fileLease(for location: Location) async throws -> FileLease { try await base.fileLease(for: location) }
}

private struct CountingSource: ByteSource {
    var base: any ByteSource
    var control: ReadControl
    var identity: ContentIdentity { base.identity }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        control.read(identity)
        return try await base.read(range, priority: priority, group: group)
    }
}
