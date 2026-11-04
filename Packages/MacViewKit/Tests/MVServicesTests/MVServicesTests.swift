import Darwin
import Foundation
import MVCommands
import MVFoundation
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import MVTestSupport
import Synchronization
import Testing
@testable import MVCache
@testable import MVIO
@testable import MVServices

@Suite(.serialized) @MainActor struct CoreIntegrationTests {
    @Test("真实 ZIP 完成枚举、自然排序和探测，第十页输出精确尺寸 IOSurface")
    func zipBook() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let session = services.makeSession()
        let book = try await services.sources.location(for: fixture.zip)
        await session.open(book, at: nil)
        #expect(session.loadError == nil)
        #expect(session.book?.isEnumerated == true)
        #expect(session.book?.pages.map(\.entry.name) == (1...12).map { "\($0).jpg" })
        #expect(session.book?.pages.allSatisfy { $0.metadata?.pixelSize == PixelSize(width: 480, height: 720) } == true)
        session.go(.index(9))
        #expect(session.currentFrame == 9)
        let page = try #require(session.book?.pages[9])
        var images: [RenderedImage] = []
        for try await image in services.pipeline.image(for: page.entry.identity, target: DisplayTarget(pixelSize: PixelSize(width: 160, height: 240)), allowOriginal: false, priority: .visible) { images.append(image) }
        #expect(images.last?.quality == .exact)
        #expect(images.last?.image.width == 160 && images.last?.image.height == 240)
        #expect(images.last?.surface != nil)
        #expect(services.commands.descriptors().isEmpty)
        await fixture.shutdown(services)
    }

    @Test("整书缩略图重建后由 L2 交付，源 ZIP 已删除")
    func thumbnailsSurviveMissingSource() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        var services: CoreServices? = try await fixture.make()
        var session: ReaderSession? = services!.makeSession()
        let location = try await services!.sources.location(for: fixture.zip)
        await session!.open(location, at: nil)
        let identities = try #require(session?.book?.pages.map(\.entry.identity))
        #expect(identities.count == 12)
        var generated = 0
        for await (_, result) in services!.pipeline.thumbnails(for: identities, maxPixel: 96, priority: .book) {
            #expect(try result.get().image.height == 96)
            generated += 1
        }
        #expect(generated == identities.count)
        let pipeline = try #require(services!.pipeline as? FileImagePipeline)
        let sessionID = try #require(session?.id)
        try await waitUntil { pipeline.prefetchInFlightCount(session: sessionID) == 0 }
        await fixture.shutdown(services!)
        session = nil
        services = nil
        // 只删除本测试创建的副本；保留原身份，确保没有重新 stat 或读源文件的路径。
        try FileManager.default.removeItem(at: fixture.zip)
        let reopened = try await fixture.make()
        var delivered: Set<ContentIdentity> = []
        for await (identity, result) in reopened.pipeline.thumbnails(for: identities, maxPixel: 96, priority: .visible) {
            #expect(try result.get().image.height == 96)
            delivered.insert(identity)
        }
        #expect(delivered == Set(identities))
        await fixture.shutdown(reopened)
    }

    @Test("书层单双页和排序立即退出后恢复")
    func remembersBookSettings() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let session = services.makeSession()
        let book = try await services.sources.location(for: fixture.zip)
        await session.open(book, at: nil)
        session.update { $0.pageMode = .double; $0.sort = SortSpec(key: .name, ascending: false) }
        try await waitUntil { session.book?.pages.first?.entry.name == "12.jpg" && session.loadError == nil }
        await fixture.shutdown(services)
        let reopened = try await fixture.make()
        let restored = reopened.makeSession()
        await restored.open(book, at: nil)
        #expect(restored.settings.pageMode == .double)
        #expect(restored.settings.sort == SortSpec(key: .name, ascending: false))
        #expect(restored.book?.pages.first?.entry.name == "12.jpg")
        await fixture.shutdown(reopened)
    }

    @Test("真实嵌套 ZIP 和 tar.gz 能打开、探测和翻页")
    func nestedAndTarGzip() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        for url in [fixture.nested, fixture.tarGzip] {
            let outer = try await services.sources.location(for: url)
            let location = url == fixture.nested ? outer.appendingLayer(["inner.zip"]) : outer
            let session = services.makeSession()
            await session.open(location, at: nil)
            #expect(session.loadError == nil)
            let pages = try #require(session.book?.pages)
            try #require(pages.count == (url == fixture.nested ? 12 : 3))
            session.go(.nextPage)
            #expect(session.currentFrame == 1)
            let identity = pages[1].entry.identity
            #expect(try await services.pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible).image.height == 96)
        }
        await fixture.shutdown(services)
    }

    @Test("外部原子改写 settings.json 后现有会话重新解析")
    func externalSettingsReload() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let session = services.makeSession()
        await session.open(try await services.sources.location(for: fixture.zip), at: nil)
        var settings = GlobalSettings.default
        settings.defaultBook.pageMode = .double
        settings.defaultBook.direction = .rightToLeft
        try fixture.writeSettings(settings)
        try await waitUntil { session.settings.pageMode == .double && session.settings.direction == .rightToLeft }
        await fixture.shutdown(services)
    }

    @Test("翻页后立即 shutdown，同一缓存目录反复重建并恢复最新页")
    func immediatelySavesLatestPage() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        for page in [9, 3, 11, 0, 6, 10] {
            let services = try await fixture.make()
            let session = services.makeSession()
            let location = try await services.sources.location(for: fixture.zip)
            await session.open(location, at: nil)
            #expect(session.loadError == nil)
            session.go(.index(page))
            await fixture.shutdown(services)
            let reopened = try await fixture.make()
            #expect(await reopened.settings.bookMemory(for: location)?.lastPageIndex == page)
            let restored = reopened.makeSession()
            await restored.open(location, at: nil)
            #expect(restored.loadError == nil)
            #expect(restored.currentFrame == page)
            await fixture.shutdown(reopened)
        }
    }

    @Test("内存 warning/critical 收缩到预算50%/25%，全局预算影响L0至L3")
    func memoryPressureAndBudgets() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        var initial = GlobalSettings.default
        initial.cache = CacheBudgets(rawBytes: 80, decodedBytes: 80, thumbnailBytes: 100, browseBytes: 100, browseCacheEnabled: true, thumbnailMemoryBytes: 80, preloadBytes: 80)
        try fixture.writeSettings(initial)
        let services = try await fixture.make()
        let caches = try #require(services.runtime?.caches)
        let image = try await ImageDecoder().image(Data(contentsOf: fixture.sourceImage), target: DisplayTarget(pixelSize: PixelSize(width: 2, height: 3)))
        for index in 0..<8 {
            caches.raw.insert(Data(count: 10), for: "raw-\(index)", cost: 10)
            caches.decoded.insert(image, for: "decoded-\(index)", cost: 10)
            caches.thumbnailMemory.insert(image, for: "thumbnail-\(index)", cost: 10)
            caches.preload.insert(image, for: "preload-\(index)", cost: 10)
        }
        services.handleMemoryPressure(.warning)
        #expect(caches.raw.totalCost == 40 && caches.decoded.totalCost == 40)
        #expect(caches.thumbnailMemory.totalCost == 40 && caches.preload.totalCost == 40)
        #expect(caches.raw.budget == 80 && caches.decoded.budget == 80)
        services.handleMemoryPressure(.critical)
        #expect(caches.raw.totalCost == 20 && caches.decoded.totalCost == 20)
        #expect(caches.thumbnailMemory.totalCost == 20 && caches.preload.totalCost == 20)
        try await services.settings.updateGlobal { $0.cache.thumbnailMemoryBytes = 15 }
        try await waitUntil { caches.thumbnailMemory.budget == 15 }
        #expect(caches.thumbnailMemory.totalCost == 10)
        #expect(caches.raw.budget == 80 && caches.decoded.budget == 80 && caches.preload.budget == 80)
        #expect(caches.raw.totalCost == 20 && caches.decoded.totalCost == 20 && caches.preload.totalCost == 20)
        try await caches.thumbnails.store(Data(count: 30), for: "before")
        try await caches.browse?.store(Data(count: 30), for: "before")
        try await services.settings.updateGlobal {
            $0.cache = CacheBudgets(rawBytes: 15, decodedBytes: 15, thumbnailBytes: 20, browseBytes: 20, browseCacheEnabled: false, thumbnailMemoryBytes: 15, preloadBytes: 15)
        }
        try await waitUntil {
            let thumbnail = try await caches.thumbnails.data(for: "before")
            let browse = try await caches.browse?.data(for: "before")
            return caches.raw.budget == 15 && caches.decoded.budget == 15 && caches.preload.budget == 15 && thumbnail == nil && browse == nil
        }
        #expect(caches.raw.totalCost == 10 && caches.decoded.totalCost == 10)
        try await caches.thumbnails.store(Data(count: 21), for: "oversized")
        try await caches.browse?.store(Data(count: 21), for: "oversized")
        #expect(try await caches.thumbnails.data(for: "oversized") == nil)
        #expect(try await caches.browse?.data(for: "oversized") == nil)
        #expect(caches.browse != nil)
        await fixture.shutdown(services)
        let reopened = try await fixture.make()
        #expect(reopened.runtime?.caches.browse == nil)
        try await reopened.settings.updateGlobal { $0.cache.browseCacheEnabled = true }
        try await waitUntil { await reopened.settings.global().cache.browseCacheEnabled }
        #expect(reopened.runtime?.caches.browse == nil)
        await fixture.shutdown(reopened)
        let enabled = try await fixture.make()
        #expect(enabled.runtime?.caches.browse != nil)
        await fixture.shutdown(enabled)
    }

    @Test("辅助进程真实 FIFO 读取卡住时 shutdown 仍在一秒内返回")
    func shutsDownBlockedHelper() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make(helper: helperExecutable)
        let scheduler = try #require(services.runtime?.scheduler)
        let fifo = fixture.root.appending(path: "blocked.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let volume = Volume(mountPoint: fixture.root.path, fileSystem: "nfs", root: .network(scheme: "nfs", host: "fixture", share: "isolated"), isLocal: false)
        let backend = scheduler.backend(for: volume)
        #expect(backend is HelperBackend)
        let sent = Atomic(false), finished = Atomic(false)
        let pending = Task {
            defer { finished.store(true, ordering: .relaxed) }
            return try await scheduler.perform(on: volume, .bulk, priority: .background, group: nil) { finish, _ in
                backend.read(ReadRequest(path: fifo.path, offset: 0, length: 1, noCache: false, retryByReopening: false)) { result in
                    finish(result.mapError { _ in IOError.cancelled })
                }
                sent.store(true, ordering: .relaxed)
            }
        }
        try await waitUntil { sent.load(ordering: .relaxed) }
        // 同一真实辅助进程仍能处理 stat；FIFO 的 open 没有写端，读取调用持续挂起。
        let size: Int64 = try await withCheckedThrowingContinuation { continuation in
            backend.stat(fixture.sourceImage.path) { continuation.resume(with: $0.map(\.size)) }
        }
        #expect(size > 0)
        try await Task.sleep(for: .milliseconds(30))
        let stillPending = !finished.load(ordering: .relaxed)
        #expect(stillPending)
        await fixture.shutdown(services)
        do { _ = try await pending.value; Issue.record("卡住的辅助进程请求应被弃用") }
        catch { #expect(error as? IOError == .cancelled) }
    }

    @Test("缓存落盘队列卡住也在一秒内返回，取消后不开始后续步骤")
    func shutdownDeadlineDoesNotWaitForStorage() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let index = try #require(services.runtime?.index)
        let gate = DispatchSemaphore(value: 0), started = Atomic(false)
        let pending = Task {
            try await index.diskOperations.perform { started.store(true, ordering: .relaxed); gate.wait() }
        }
        try await waitUntil { started.load(ordering: .relaxed) }
        await fixture.shutdown(services)
        let location = try await services.sources.location(for: fixture.sourceImage)
        let identity = try await services.sources.provider(for: location).entry(at: location).identity
        await #expect(throws: CancellationError.self) { try await services.pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible) }
        gate.signal()
        try await pending.value
    }

    @Test("Mock 保留原构造入口，没有 keybindings 存储，组合根只弱持有会话")
    func mockAndWeakSessions() async throws {
        let services = CoreServices.makeMock(MockOptions(timing: .instant))
        #expect(services.keyBindings == nil)
        var session: ReaderSession? = services.makeSession()
        weak let weakSession = session
        session = nil
        #expect(weakSession == nil)
        await services.shutdown()
    }
}

private struct ServiceFixture {
    let root: URL
    let configuration: CoreConfiguration
    let sourceImage = Fixtures.url("image/format/baseline.jpg")
    var zip: URL { root.appending(path: "book.zip") }
    var nested: URL { root.appending(path: "nested.zip") }
    var tarGzip: URL { root.appending(path: "book.tar.gz") }

    init() throws {
        root = Fixtures.root.deletingLastPathComponent().appending(path: "build/stage4-repair/services-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        configuration = CoreConfiguration(supportDirectory: root.appending(path: "support"), cacheDirectory: root.appending(path: "cache"), browseBounds: PixelSize(width: 640, height: 960))
        let pages = root.appending(path: "pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        for index in (1...12).reversed() { try FileManager.default.copyItem(at: sourceImage, to: pages.appending(path: "\(index).jpg")) }
        try run("/usr/bin/zip", ["-q", zip.path] + (1...12).reversed().map { "\($0).jpg" }, in: pages)
        let inner = root.appending(path: "inner.zip")
        try FileManager.default.copyItem(at: zip, to: inner)
        try run("/usr/bin/zip", ["-q", nested.path, "inner.zip"], in: root)
        try FileManager.default.copyItem(at: Fixtures.url("archive/tar/book.tar.gz"), to: tarGzip)
    }

    @MainActor func make(helper: URL? = nil) async throws -> CoreServices {
        var config = configuration
        config.helperExecutable = helper
        let start = ContinuousClock.now
        let services = try await CoreServices.make(configuration: config)
        let elapsed = start.duration(to: .now)
        #expect(elapsed <= .milliseconds(200), "make 用时 \(elapsed)")
        print("S1-T8 make \(elapsed)")
        return services
    }

    @MainActor func shutdown(_ services: CoreServices) async {
        let start = ContinuousClock.now
        await services.shutdown()
        let elapsed = start.duration(to: .now)
        #expect(elapsed <= .seconds(1), "shutdown 用时 \(elapsed)")
        print("S1-T8 shutdown \(elapsed)")
    }

    func writeSettings(_ settings: GlobalSettings) throws {
        try FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "value": value], options: [.sortedKeys])
        try data.write(to: configuration.supportDirectory.appending(path: "settings.json"), options: .atomic)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@MainActor private func waitUntil(_ predicate: @MainActor () async throws -> Bool) async throws {
    let start = ContinuousClock.now
    while try await !predicate() {
        guard start.duration(to: .now) < .seconds(3) else { throw ServiceTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum ServiceTestFailure: Error { case timeout }
private final class BundleMarker {}
private let helperExecutable = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvio-helper")
