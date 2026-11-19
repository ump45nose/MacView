import Darwin
import AVFoundation
import CoreVideo
import Foundation
import MVCommands
import MVFoundation
@testable import MVFileOps
import MVMedia
import MVMetadata
@testable import MVLibraryData
@testable import MVPipeline
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

    @Test("缓存索引落盘队列卡住时仍在一秒内返回")
    func shutdownDeadlineDoesNotWaitForStorage() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let index = try #require(services.runtime?.index)
        let gate = DispatchSemaphore(value: 0), started = Atomic(false)
        let pending = Task {
            try await index.diskOperations.perform { started.store(true, ordering: .relaxed); gate.wait() }
        }
        defer { gate.signal() }
        try await waitUntil { started.load(ordering: .relaxed) }
        await fixture.shutdown(services)
        let location = try await services.sources.location(for: fixture.sourceImage)
        let identity = try await services.sources.provider(for: location).entry(at: location).identity
        await #expect(throws: CancellationError.self) { try await services.pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible) }
        gate.signal()
        try await pending.value
    }

#if DEBUG
    @Test("C1.16 退出入口同步取消耗时也计入一秒期限")
    func shutdownDeadlineIncludesCancellationSetup() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let real = try await fixture.make()
        let pipeline = try #require(real.pipeline as? FileImagePipeline)
        let settings = ShutdownDelaySettings(base: real.settings)
        let services = CoreServices(sources: real.sources, pipeline: pipeline, settings: settings,
                                    commands: real.commands, bookshelf: real.bookshelf, loader: real.loader)
        try await waitUntil { settings.waiting.load(ordering: .relaxed) }
        let release = AsyncStream<Void>.makeStream(), entered = Atomic(false)
        let held = Task { for await _ in release.stream { break } }
        defer { release.continuation.finish() }
        pipeline.bundleContentLoaded.withLock { $0 = {
            entered.store(true, ordering: .relaxed)
            await held.value
        } }
        let location = try await real.sources.location(for: fixture.sourceImage)
        let identity = try await real.sources.provider(for: location).entry(at: location).identity
        let request = Task { try await pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible) }
        try await waitUntil { entered.load(ordering: .relaxed) }
        let started = ContinuousClock.now
        await fixture.shutdown(services)
        let interval = try #require(settings.cancellationInterval.withLock { $0 })
        #expect(interval.lowerBound >= started)
        #expect(interval.lowerBound.duration(to: interval.upperBound) >= .milliseconds(250))
        release.continuation.finish()
        await held.value
        await #expect(throws: CancellationError.self) { try await request.value }
        pipeline.bundleContentLoaded.withLock { $0 = nil }
        await fixture.shutdown(real)
    }

    @Test("C1.16 取图排空超时后跳过资料库与缓存落盘")
    func shutdownTimeoutSkipsFollowingFlushes() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        var services: CoreServices? = try await fixture.make()
        weak let settings = services?.runtime?.settings
        let pipeline = try #require(services?.pipeline as? FileImagePipeline)
        let index = try #require(services?.runtime?.index)
        let library = try #require(services?.library as? SQLiteLibraryStore)
        let checkpoints = Atomic(0)
        try await library.database.queue.write { database in
            database.trace { event in
                if case let .statement(statement) = event, statement.sql.contains("wal_checkpoint") {
                    checkpoints.wrappingAdd(1, ordering: .relaxed)
                }
            }
        }
        let release = AsyncStream<Void>.makeStream(), entered = Atomic(false)
        let held = Task { for await _ in release.stream { break } }
        defer { release.continuation.finish() }
        pipeline.bundleContentLoaded.withLock { $0 = {
            entered.store(true, ordering: .relaxed)
            await held.value
        } }
        let location = try await services!.sources.location(for: fixture.sourceImage)
        let identity = try await services!.sources.provider(for: location).entry(at: location).identity
        let request = Task { try await pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible) }
        try await waitUntil { entered.load(ordering: .relaxed) }
        // 保持缓存队列占用：若取消后仍调 index.flush，关闭工作就无法结束。
        let diskGate = DispatchSemaphore(value: 0), diskEntered = Atomic(false)
        let disk = Task {
            try await index.diskOperations.perform { diskEntered.store(true, ordering: .relaxed); diskGate.wait() }
        }
        defer { diskGate.signal() }
        try await waitUntil { diskEntered.load(ordering: .relaxed) }
        await fixture.shutdown(services!)
        services = nil
        #expect(settings != nil) // 尚未结束的关闭工作仍持有 runtime。
        #expect(checkpoints.load(ordering: .relaxed) == 0)
        release.continuation.finish()
        await held.value
        await #expect(throws: CancellationError.self) { try await request.value }
        pipeline.bundleContentLoaded.withLock { $0 = nil }
        // 等真实关闭工作释放 runtime，之后再检查没有启动后续落盘。
        try await waitUntil { settings == nil || index.diskOperations.pendingCount > 1 }
        let workFinished = settings == nil
        #expect(workFinished)
        #expect(checkpoints.load(ordering: .relaxed) == 0)
        #expect(index.diskOperations.pendingCount == 1)
        diskGate.signal()
        try await disk.value
        try await waitUntil { settings == nil }
    }
#endif

    @Test("文件操作传播到两个会话、目录缓存和书记忆")
    func propagatesFileChanges() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let operations = try #require(services.fileOperations)
        let old = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let parent = try #require(old.parent)
        let directories = DirectoryCache(index: try #require(services.runtime?.index))
        for try await _ in services.bookshelf.items(in: parent, sort: SortSpec(key: .name)) {}
        let first = services.makeSession(), second = services.makeSession()
        await first.open(old, at: nil); await second.open(old, at: nil)
        first.go(.index(3)); second.go(.index(3))
        let deleted = try #require(first.book?.pages[3].id)
        let result = await operations.perform(.deletePermanently([deleted]))
        #expect(result.failures.isEmpty)
        try await waitUntil { first.book?.pages.count == 11 && second.book?.pages.count == 11 }
        #expect(first.book?.pages[first.currentPage].entry.name == "5.jpg")
        #expect(try await directories.cachedChildren(of: old)?.entries.contains(where: { $0.location == deleted }) == false)
        let renamed = parent.appending("renamed-pages")
        let move = await operations.perform(.rename(old, to: "renamed-pages"))
        #expect(move.failures.isEmpty)
        try await waitUntil { first.book?.location == renamed && second.book?.location == renamed && first.book?.pages.count == 11 && second.book?.pages.count == 11 }
        #expect(first.book?.pages[first.currentPage].entry.name == "5.jpg")
        let memory = await services.settings.bookMemory(for: renamed)
        #expect(memory?.lastPage == renamed.appending("5.jpg"))
        #expect(await services.settings.bookMemory(for: old) == nil)
        let parentEntries = try #require(try await directories.cachedChildren(of: parent)?.entries)
        #expect(parentEntries.contains { $0.location == renamed } && !parentEntries.contains { $0.location == old })
        await fixture.shutdown(services)
    }

    @Test("appliedFileChanges 在目录缓存、书记忆与会话更新之后才发出，支持多处订阅")
    func appliedFileChangesFiresAfterDirectoryCacheAndSessionUpdate() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let operations = try #require(services.fileOperations)
        let book = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let parent = try #require(book.parent)
        let directories = DirectoryCache(index: try #require(services.runtime?.index))
        for try await _ in services.bookshelf.items(in: parent, sort: SortSpec(key: .name)) {}
        let session = services.makeSession()
        await session.open(book, at: nil)
        let deleted = try #require(session.book?.pages[0].id)
        let stream1 = services.appliedFileChanges(), stream2 = services.appliedFileChanges()
        let observer1 = Task { @MainActor () throws -> [FileChange] in
            for await batch in stream1 {
                let cached = try #require(try await directories.cachedChildren(of: book))
                #expect(!cached.entries.contains { $0.location == deleted })
                #expect(session.book?.pages.count == 11)
                return batch
            }
            return []
        }
        let observer2 = Task { () -> [FileChange] in for await batch in stream2 { return batch }; return [] }
        #expect((await operations.perform(.deletePermanently([deleted]))).failures.isEmpty)
        let first = try await observer1.value, second = await observer2.value
        #expect(first == [.removed(deleted)] && second == first)

        session.go(.index(3))
        let currentName = try #require(session.book?.pages[session.currentPage].entry.name)
        let renamed = parent.appending("renamed-pages")
        let moveStream = services.appliedFileChanges()
        let moveObserver = Task { @MainActor () throws -> [FileChange] in
            for await batch in moveStream {
                let cached = try #require(try await directories.cachedChildren(of: parent))
                #expect(cached.entries.contains { $0.location == renamed } && !cached.entries.contains { $0.location == book })
                #expect(await services.settings.bookMemory(for: renamed)?.lastPage == renamed.appending(currentName))
                #expect(await services.settings.bookMemory(for: book) == nil)
                return batch
            }
            return []
        }
        let moved = await operations.perform(.rename(book, to: "renamed-pages"))
        #expect(moved.failures.isEmpty)
        #expect(try await moveObserver.value == moved.changes)
        await fixture.shutdown(services)
    }

    @Test("启动时恢复未完成的传输")
    func recoversTransfersAtStartup() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let sourceURL = fixture.root.appending(path: "recover.dat")
        let targetURL = fixture.root.appending(path: "recovered.dat")
        try Data([7, 8, 9]).write(to: sourceURL)
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        let source = try await registry.location(for: sourceURL)
        let target = try await registry.location(for: targetURL)
        let temporary = try await registry.location(for: fixture.root.appending(path: ".recovered.dat.macview-part"))
        func encoded(_ location: Location) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(location)) }
        let json: [String: Any] = ["version": 1, "transfers": [["id": UUID().uuidString, "source": try encoded(source), "target": try encoded(target), "temporary": try encoded(temporary)]]]
        try FileManager.default.createDirectory(at: fixture.configuration.supportDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.configuration.supportDirectory.appending(path: "transfers.json"))
        let services = try await fixture.make()
        let report = await services.interruptedTransfersReport()
        #expect(report == ResumeReport(completed: 1, pending: 0, failed: 0))
        #expect(await services.interruptedTransfersReport() == report)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path) && FileManager.default.fileExists(atPath: targetURL.path))
        #expect(try Data(contentsOf: targetURL) == Data([7, 8, 9]))
        await fixture.shutdown(services)
    }

    @Test("Mock 保留原构造入口，没有 keybindings 存储，组合根只弱持有会话")
    func mockAndWeakSessions() async throws {
        let services = CoreServices.makeMock(MockOptions(timing: .instant))
        #expect(services.keyBindings == nil && services.fileOperations == nil)
        #expect(await services.interruptedTransfersReport() == nil)
        var received = 0
        for await _ in services.appliedFileChanges() { received += 1 }
        #expect(received == 0)
        var session: ReaderSession? = services.makeSession()
        weak let weakSession = session
        session = nil
        #expect(weakSession == nil)
        await services.shutdown()
    }

    @Test("C1.14 历史接线及文件广播前已完成资料库迁移，删除撤销保留条目")
    func libraryFileChanges() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let trashURL = fixture.root.appending(path: "trash")
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let trash = Location(root: .local, layers: [Array(trashURL.pathComponents.dropFirst())])
        let services = try await CoreServices.make(configuration: fixture.configuration, fileOperations: { fs, journal in
            try FileOperationService(fileSystem: fs, journalURL: journal, isNetwork: { _ in false }, volumeRoot: { _ in trash }, networkRoots: { [] }, trash: { source in
                let target = trash.appending(source.name)
                try await fs.rename(source, to: target, exclusive: true)
                return target
            })
        })
        let library = try #require(services.library)
        let operations = try #require(services.fileOperations)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let zip = try await services.sources.location(for: fixture.zip)
        let first = services.makeSession(), second = services.makeSession()
        await first.open(folder, at: nil)
        try await waitUntil { try await library.history().count == 1 }
        await second.open(zip, at: nil)
        try await waitUntil { try await library.history().map(\.book) == [zip, folder] }
        _ = try await library.addBookmarks([folder], into: nil, at: nil)
        let playlist = try await library.createPlaylist(named: "迁移")
        _ = try await library.addItems([try #require(first.book?.pages[2].entry)], to: playlist)
        let renamed = try #require(folder.parent).appending("renamed-library")
        let stream = services.appliedFileChanges()
        let observer = Task { @MainActor in
            for await _ in stream {
                #expect(try await library.history().contains { $0.book == renamed })
                #expect(try await library.items(of: playlist).first?.location == renamed.appending("3.jpg"))
                guard case let .book(_, location, _) = try await library.bookmarks().first else { Issue.record("书签缺失"); return }
                #expect(location == renamed)
                return
            }
        }
        #expect((await operations.perform(.rename(folder, to: renamed.name))).failures.isEmpty)
        try await observer.value
        try await waitUntil { first.book?.location == renamed && first.book?.isEnumerated == true }
        let page = renamed.appending("3.jpg")
        // 只把系统废纸篓适配到工作区，删除、反向操作与通知均走真实服务。
        var applied = services.appliedFileChanges().makeAsyncIterator()
        let removed = await operations.perform(.delete([page]))
        #expect(removed.failures.isEmpty && removed.changes == [.removed(page)])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "renamed-library/3.jpg").path))
        _ = await applied.next()
        #expect(try await library.items(of: playlist).map(\.location) == [page])
        let inverse = try #require(removed.inverse)
        #expect(inverse == .relocate([Relocation(source: trash.appending(page.name), target: page)]))
        let restored = await operations.perform(inverse)
        #expect(restored.failures.isEmpty)
        if case let .moved(from, to) = restored.changes.first {
            #expect(from == trash.appending(page.name) && to.location == page)
        } else { Issue.record("撤销应广播 moved") }
        _ = await applied.next()
        #expect(try await library.items(of: playlist).map(\.location) == [page])
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "renamed-library/3.jpg").path))
        await fixture.shutdown(services)
    }

    @Test("C1.23 资料库迁移事务失败仍更新会话并广播，三表保持原样")
    func libraryApplyFailureStillUpdatesSessionAndBroadcasts() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library as? SQLiteLibraryStore)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        var entries: [Entry] = []
        for index in 1...3 {
            entries.append(try await services.sources.provider(for: folder).entry(at: folder.appending("\(index).jpg")))
        }
        try await library.recordOpened(folder, at: Date())
        let id = try await library.createPlaylist(named: "迁移失败")
        _ = try await library.addItems(entries, to: id)
        _ = try await library.addBookmarks([folder, entries[1].location], into: nil, at: nil)
        let session = services.makeSession()
        await session.open(.playlist(id), at: entries[1].location)
        try await waitUntil { try await library.history().count == 2 }
        let history = try await library.history(), bookmarks = try await library.bookmarks()
        let snapshots = try await library.items(of: id)
        // 在最后一张表失败，验证此前已执行的历史和书签更新一并回滚。
        try await library.database.queue.write { database in
            try database.execute(sql: "CREATE TRIGGER fail_relocation BEFORE UPDATE OF location ON playlist_item BEGIN SELECT RAISE(ABORT, 'C1.23 injected failure'); END")
        }
        let target = try #require(folder.parent).appending("apply-failure-moved")
        let expected = entries.map { target.appending($0.name) }
        let stream = services.appliedFileChanges()
        var broadcast: [FileChange]?
        let observer = Task<Void, any Error> { @MainActor in
            for await batch in stream {
                broadcast = batch
                #expect(session.book?.pages.map(\.id) == expected)
                #expect(session.currentPage == 1)
                let observedHistory = try await library.history()
                let observedBookmarks = try await library.bookmarks()
                let observedItems = try await library.items(of: id)
                #expect(observedHistory == history)
                #expect(observedBookmarks == bookmarks)
                #expect(observedItems == snapshots)
                return
            }
        }
        defer { observer.cancel() }
        let result = try #require(await services.fileOperations?.perform(.rename(folder, to: target.name)))
        #expect(result.failures.isEmpty)
        try await waitUntil { broadcast != nil }
        try await observer.value
        #expect(broadcast == result.changes)
        #expect(session.unavailablePages.isEmpty)
        var availability: [Location: Availability] = [:]
        for await values in try #require(services.availability).check(snapshots.map(\.location)) {
            availability.merge(values, uniquingKeysWith: { _, new in new })
        }
        #expect(availability == Dictionary(uniqueKeysWithValues: snapshots.map { ($0.location, .missing) }))
        // 去掉故障后也不自动补偿或重试，资料库继续保留原位置。
        try await library.database.queue.write { try $0.execute(sql: "DROP TRIGGER fail_relocation") }
        for _ in 0..<20 { await Task.yield() }
        #expect(try await library.history() == history)
        #expect(try await library.bookmarks() == bookmarks)
        #expect(try await library.items(of: id) == snapshots)
        await fixture.shutdown(services)
    }

    @Test("C1.15 两会话随列表增删排序更新，移除当前项保留序号，删除列表报找不到")
    func libraryReloadsBothSessions() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        var entries: [Entry] = []
        for index in 1...5 { entries.append(try await services.sources.provider(for: folder).entry(at: folder.appending("\(index).jpg"))) }
        // 真实压缩包内的页也经组合根分派到 PlaylistBookLoader。
        let zip = try await services.sources.location(for: fixture.zip)
        let zippedPage = zip.appendingLayer(["1.jpg"])
        entries[4] = try await services.sources.provider(for: zippedPage).entry(at: zippedPage)
        let id = try await library.createPlaylist(named: "双会话")
        _ = try await library.addItems(Array(entries.prefix(4)), to: id)
        let first = services.makeSession(), second = services.makeSession()
        await first.open(.playlist(id), at: entries[2].location)
        await second.open(.playlist(id), at: entries[2].location)
        let expectedSize = PixelSize(width: 480, height: 720)
        func settled(_ expected: [Entry], current: Location) async throws {
            try await waitUntil {
                [first, second].allSatisfy {
                    // sorted 只表示页序已就绪；重载后的元数据由后续事件交付。
                    $0.book?.pages.map(\.id) == expected.map(\.location) && $0.book?.isEnumerated == true &&
                    $0.book?.pages.allSatisfy { $0.metadata?.pixelSize == expectedSize } == true &&
                    $0.book?.pages[$0.currentPage].id == current
                }
            }
        }
        try await settled(Array(entries.prefix(4)), current: entries[2].location)
        _ = try await library.addItems([entries[4]], to: id)
        try await settled(entries, current: entries[2].location)
        #expect([first, second].allSatisfy { $0.book?.pages.last?.metadata?.pixelSize == expectedSize })
        try await library.removeItems([entries[0].location], from: id)
        try await settled(Array(entries.dropFirst()), current: entries[2].location)
        try await library.moveItems([entries[4].location], in: id, to: 0)
        let reordered = [entries[4], entries[1], entries[2], entries[3]]
        try await settled(reordered, current: entries[2].location)
        try await library.removeItems([entries[2].location], from: id)
        try await settled([entries[4], entries[1], entries[3]], current: entries[3].location)
        #expect(first.currentPage == 2 && second.currentPage == 2)
        try await library.deletePlaylist(id)
        try await waitUntil { first.loadError as? IOError == .notFound(.playlist(id)) && second.loadError as? IOError == .notFound(.playlist(id)) }
        await fixture.shutdown(services)
    }

    @Test("C1.22 文件迁移与快照回写不重载虚拟书，当前页跟随")
    func libraryRelocationDoesNotReload() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let entry = try await services.sources.provider(for: folder).entry(at: folder.appending("2.jpg"))
        let before = try await services.sources.provider(for: folder).entry(at: folder.appending("1.jpg"))
        let after = try await services.sources.provider(for: folder).entry(at: folder.appending("3.jpg"))
        let id = try await library.createPlaylist(named: "不重载")
        var stale = entry
        stale.identity.size += 1
        _ = try await library.addItems([before, stale, after], to: id)
        let counter = CountedLibraryLoader(base: services.loader)
        let session = services.makeSession(loader: counter)
        await session.open(.playlist(id), at: entry.location)
        #expect(try await library.items(of: id) == [before, entry, after])

        // 同一订阅流后面的列表变更作为屏障，证明前面的通知已处理。
        let barrierID = try await library.createPlaylist(named: "通知屏障")
        _ = try await library.addItems([before], to: barrierID)
        let barrierSession = services.makeSession()
        await barrierSession.open(.playlist(barrierID), at: nil)
        var applied = services.appliedFileChanges().makeAsyncIterator()
        let moved = await services.fileOperations?.perform(.rename(entry.location, to: "current.jpg"))
        #expect(moved?.failures.isEmpty == true)
        _ = await applied.next()
        let target = folder.appending("current.jpg")
        #expect(session.book?.pages.map(\.id) == [before.location, target, after.location])
        #expect(session.currentPage == 1)
        #expect(try await library.items(of: id).map(\.location) == [before.location, target, after.location])
        try await library.updateSnapshots(try await library.items(of: id), in: id)
        _ = try await library.addItems([after], to: barrierID)
        try await waitUntil { barrierSession.book?.pages.count == 2 && barrierSession.book?.isEnumerated == true }
        #expect(counter.count.withLock { $0 } == 1)
        await fixture.shutdown(services)
    }

    @Test("C1.7 真实 ZIP 内缺项为 missing，存在的项仍可用")
    func libraryRealArchiveAvailability() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let checker = try #require(services.availability)
        let zip = try await services.sources.location(for: fixture.zip)
        let present = zip.appendingLayer(["1.jpg"]), missing = zip.appendingLayer(["absent.jpg"])
        var results: [Location: Availability] = [:]
        for await batch in checker.check([present, missing]) { results.merge(batch, uniquingKeysWith: { _, new in new }) }
        #expect(results[present] == .available)
        #expect(results[missing] == .missing)
        await fixture.shutdown(services)
    }

    @Test("C1.8 三个真实目录、真实 ZIP 和视频按列表顺序加载并回写过期快照")
    func libraryRealMixedSources() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        for name in ["a", "b", "c"] {
            let directory = fixture.root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture.sourceImage, to: directory.appending(path: "\(name).jpg"))
        }
        let videoURL = fixture.root.appending(path: "a/clip.mp4")
        try await writeLibraryVideo(to: videoURL)
        let services = try await fixture.make()
        let library = try #require(services.library)
        let zip = try await services.sources.location(for: fixture.zip)
        let locations = [try await services.sources.location(for: fixture.root.appending(path: "c/c.jpg")),
                         zip.appendingLayer(["1.jpg"]), try await services.sources.location(for: videoURL),
                         try await services.sources.location(for: fixture.root.appending(path: "b/b.jpg"))]
        var fresh: [Entry] = []
        for location in locations { fresh.append(try await services.sources.provider(for: location).entry(at: location)) }
        var stale = fresh
        stale[0].identity.size += 1
        stale[1].identity.modificationNanos += 1
        let id = try await library.createPlaylist(named: "真实混合来源")
        _ = try await library.addItems(stale, to: id)
        var settings = ResolvedBookSettings.default
        settings.sort = SortSpec(key: .name, ascending: false)
        settings.recursion = RecursionSpec(enabled: true, maxDepth: 10)
        var sorted: [[Page]] = [], metadata: [Location: ImageMetadata] = [:]
        for try await event in services.loader.load(.playlist(id), settings: settings, startingAt: locations[2]) {
            switch event {
            case let .sorted(pages): sorted.append(pages)
            case let .metadata(values): metadata.merge(values, uniquingKeysWith: { _, new in new })
            case .availability: break
            case .appended: Issue.record("播放列表不得按来源追加")
            }
        }
        #expect(sorted.count == 2)
        #expect(sorted.first?.map(\.entry) == stale && sorted.last?.map(\.entry) == fresh)
        #expect(sorted.allSatisfy { $0.map(\.id) == locations })
        #expect(try await library.items(of: id) == fresh)
        #expect(fresh[2].kind == .video)
        #expect(metadata[locations[2]]?.pixelSize == PixelSize(width: 64, height: 96))
        #expect(try #require(metadata[locations[2]]?.duration) > 0)
        #expect(metadata.count == 4)
        await fixture.shutdown(services)
    }

    @Test("C1.21 真实连续模式在未挂载项与已删除项之后仍排到末页")
    func libraryContinuousLayoutReachesLastPage() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let network = Location(root: .network(scheme: "nfs", host: "192.0.2.1", share: "unmounted-library"), layers: [["page.jpg"]])
        let missing = folder.appending("deleted.jpg")
        var entries = [Entry(identity: ContentIdentity(location: network, size: 1, modificationNanos: 1), name: network.name, kind: .image),
                       Entry(identity: ContentIdentity(location: missing, size: 1, modificationNanos: 1), name: missing.name, kind: .image)]
        for index in 1...3 { entries.append(try await services.sources.provider(for: folder).entry(at: folder.appending("\(index).jpg"))) }
        let id = try await library.createPlaylist(named: "连续占位")
        _ = try await library.addItems(entries, to: id)
        let session = services.makeSession()
        let start = ContinuousClock.now
        await session.open(.playlist(id), at: nil)
        session.update { $0.browseMode = .verticalStrip }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(session.book?.pages.map(\.id) == entries.map(\.location))
        let pages = try #require(session.book?.pages)
        #expect(pages.prefix(2).allSatisfy { $0.metadata?.pixelSize == PixelSize(width: 1000, height: 1414) })
        #expect(pages.suffix(3).allSatisfy { $0.metadata?.pixelSize == PixelSize(width: 480, height: 720) })
        #expect(session.frames.count == entries.count)
        session.visibleRangeChanged((entries.count - 1)..<entries.count)
        #expect(session.currentPage == entries.count - 1)
        await fixture.shutdown(services)
    }

    @Test("C1.10 真实图像进缓存后删除、撤销与来源恢复均刷新身份并重新取图")
    func libraryRealImageCacheRecovery() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let trashURL = fixture.root.appending(path: "trash")
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let trash = Location(root: .local, layers: [Array(trashURL.pathComponents.dropFirst())])
        let services = try await CoreServices.make(configuration: fixture.configuration, fileOperations: { fs, journal in
            try FileOperationService(fileSystem: fs, journalURL: journal, isNetwork: { _ in false }, volumeRoot: { _ in trash }, networkRoots: { [] }, trash: { source in
                let target = trash.appending(source.name)
                try await fs.rename(source, to: target, exclusive: true)
                return target
            })
        })
        let library = try #require(services.library)
        let operations = try #require(services.fileOperations)
        let pageURL = fixture.root.appending(path: "pages/1.jpg")
        let location = try await services.sources.location(for: pageURL)
        let entry = try await services.sources.provider(for: location).entry(at: location)
        let id = try await library.createPlaylist(named: "缓存恢复")
        _ = try await library.addItems([entry], to: id)
        let session = services.makeSession()
        await session.open(.playlist(id), at: nil)
        let target = DisplayTarget(pixelSize: PixelSize(width: 96, height: 144))
        var initial: RenderedImage?
        for try await image in services.pipeline.image(for: entry.identity, target: target, allowOriginal: false, priority: .visible) { initial = image }
        #expect(initial?.quality == .exact && initial?.image.height == 144)
        var applied = services.appliedFileChanges().makeAsyncIterator()
        let deletion = await operations.perform(.delete([location]))
        #expect(deletion.failures.isEmpty)
        _ = await applied.next()
        #expect(session.book?.pages.map(\.id) == [location])
        #expect(session.unavailablePages.contains(location))
        #expect((await operations.perform(try #require(deletion.inverse))).failures.isEmpty)
        _ = await applied.next()
        try await waitUntil { !session.unavailablePages.contains(location) && session.book?.pages.first?.metadata != nil }
        let restored = try #require(session.book?.pages.first?.entry)
        var restoredImage: RenderedImage?
        for try await image in services.pipeline.image(for: restored.identity, target: target, allowOriginal: false, priority: .visible) { restoredImage = image }
        #expect(restoredImage?.quality == .exact)

        session.setAvailability([location: .volumeUnavailable(.network(scheme: "nfs", host: "192.0.2.1", share: "none"))])
        #expect(session.unavailablePages.contains(location))
        try Data(contentsOf: Fixtures.url("image/format/image.png")).write(to: pageURL, options: .atomic)
        let fresh = try await services.sources.provider(for: location).entry(at: location)
        #expect(fresh.identity != restored.identity)
        session.setAvailability([location: .available])
        #expect(session.unavailablePages.contains(location))
        try await waitUntil { !session.unavailablePages.contains(location) && session.book?.pages.first?.entry.identity == fresh.identity }
        var recoveredImage: RenderedImage?
        for try await image in services.pipeline.image(for: fresh.identity, target: target, allowOriginal: false, priority: .visible) { recoveredImage = image }
        #expect(recoveredImage?.quality == .exact && recoveredImage?.image.height == 144)
        #expect(try await library.items(of: id).first?.identity == fresh.identity)

        // 撤销得到真实 Entry 后，图像探测失败也必须继续屏蔽缓存。
        let corruptDeletion = await operations.perform(.delete([location]))
        #expect(corruptDeletion.failures.isEmpty)
        _ = await applied.next()
        try Data("not an image".utf8).write(to: trashURL.appending(path: location.name), options: .atomic)
        #expect((await operations.perform(try #require(corruptDeletion.inverse))).failures.isEmpty)
        _ = await applied.next()
        #expect(session.unavailablePages.contains(location))
        let corruptEntry = try #require(session.book?.pages.first?.entry)
        do {
            _ = try await services.pipeline.metadata(for: corruptEntry.identity, priority: .visible)
            Issue.record("损坏图像探测不应成功")
        } catch {}
        for _ in 0..<10 { await Task.yield() }
        #expect(session.unavailablePages.contains(location))
        await fixture.shutdown(services)
    }

    @Test("C1.10 来源实际仍缺失时 available 不能清除占位并暴露旧图像缓存")
    func libraryFailedRecoveryKeepsUnavailable() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library)
        let url = fixture.root.appending(path: "pages/1.jpg")
        let location = try await services.sources.location(for: url)
        let entry = try await services.sources.provider(for: location).entry(at: location)
        let id = try await library.createPlaylist(named: "恢复必须校验")
        _ = try await library.addItems([entry], to: id)
        let loader = PausedLibraryLoader(base: services.loader, pauseSecondSorted: false)
        let session = services.makeSession(loader: loader)
        await session.open(.playlist(id), at: nil)
        let target = DisplayTarget(pixelSize: PixelSize(width: 96, height: 144))
        var cached: RenderedImage?
        for try await image in services.pipeline.image(for: entry.identity, target: target, allowOriginal: false, priority: .visible) { cached = image }
        #expect(cached?.quality == .exact)
        try FileManager.default.removeItem(at: url)
        session.setAvailability([location: .missing])
        session.setAvailability([location: .available])
        try await waitUntil { loader.completed == 2 }
        for _ in 0..<10 { await Task.yield() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(session.unavailablePages.contains(location), "加载器的失败占位不能当作真实校验成功")
        // 同一身份确实仍能命中旧图：会话必须继续屏蔽它。
        var stale: RenderedImage?
        for try await image in services.pipeline.image(for: entry.identity, target: target, allowOriginal: false, priority: .visible) { stale = image }
        #expect(stale?.quality == .exact && stale?.image.height == 144)
        await fixture.shutdown(services)
    }

    @Test("C1.10 首批 sorted 前真实删除，目录迁移及移回原位均不能凭缓存恢复", arguments: [0, 1, 2])
    func libraryDeletionBeforeFirstSortedKeepsUnavailable(parentMoves: Int) async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let trashURL = fixture.root.appending(path: "trash")
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let trash = Location(root: .local, layers: [Array(trashURL.pathComponents.dropFirst())])
        let services = try await CoreServices.make(configuration: fixture.configuration, fileOperations: { fs, journal in
            try FileOperationService(fileSystem: fs, journalURL: journal, isNetwork: { _ in false }, volumeRoot: { _ in trash }, networkRoots: { [] }, trash: { source in
                let target = trash.appending(source.name)
                try await fs.rename(source, to: target, exclusive: true)
                return target
            })
        })
        let library = try #require(services.library)
        let operations = try #require(services.fileOperations)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        var entries: [Entry] = []
        for index in 1...3 { entries.append(try await services.sources.provider(for: folder).entry(at: folder.appending("\(index).jpg"))) }
        let removed = entries[1]
        let target = DisplayTarget(pixelSize: PixelSize(width: 96, height: 144))
        var cached: RenderedImage?
        for try await image in services.pipeline.image(for: removed.identity, target: target, allowOriginal: false, priority: .visible) { cached = image }
        #expect(cached?.quality == .exact)
        _ = try await services.pipeline.metadata(for: removed.identity, priority: .visible)
        _ = try await services.pipeline.thumbnail(for: removed.identity, maxPixel: 128, priority: .visible)
        let id = try await library.createPlaylist(named: "首批页前删除")
        _ = try await library.addItems(entries, to: id)
        let loader = PausedLibraryLoader(base: services.loader, pauseSecondSorted: false, pauseFirstSorted: true)
        let session = services.makeSession(loader: loader)
        let opening = Task { await session.open(.playlist(id), at: removed.location) }
        defer { loader.release(); opening.cancel() }
        try await waitUntil { loader.isPaused && session.book?.pages.isEmpty == true }
        var applied = services.appliedFileChanges().makeAsyncIterator()
        #expect((await operations.perform(.delete([removed.location]))).failures.isEmpty)
        _ = await applied.next()
        var destination = folder
        if parentMoves > 0 {
            destination = try #require(folder.parent).appending("moved-before-first-sorted")
            #expect((await operations.perform(.rename(folder, to: destination.name))).failures.isEmpty)
            _ = await applied.next()
        }
        if parentMoves > 1 {
            #expect((await operations.perform(.rename(destination, to: folder.name))).failures.isEmpty)
            _ = await applied.next()
            destination = folder
        }
        #expect(session.book?.pages.isEmpty == true)
        loader.release()
        await opening.value
        let missing = destination.appending(removed.name)
        // 缓存探测有机会完成后仍须占位；父目录 Entry 不能证明其子页存在。
        try await Task.sleep(for: .milliseconds(25))
        #expect(session.book?.pages.map(\.id) == entries.map { destination.appending($0.name) })
        #expect(session.currentPage == 1)
        #expect(session.unavailablePages == [missing])
        if parentMoves > 0 {
            #expect(loader.loads == 2, "移动不可用子页必须重新校验来源")
            if loader.loads == 2 {
                try await waitUntil { loader.completed == 2 }
                #expect(loader.availability[missing] == .missing)
                #expect(session.unavailablePages == [missing])
            }
        }
        #expect(loader.availability[removed.location] != nil, "真实加载器的在途校验事件已交付")
        // 再做一次真实校验，明确收到删除后 missing 的结果。
        session.setAvailability([missing: .missing])
        let completed = loader.completed
        session.setAvailability([missing: .available])
        try await waitUntil { loader.completed == completed + 1 }
        #expect(loader.availability[missing] == .missing)
        #expect(session.unavailablePages == [missing])
        var stale: RenderedImage?
        for try await image in services.pipeline.image(for: removed.identity, target: target, allowOriginal: false, priority: .visible) { stale = image }
        #expect(stale?.quality == .exact, "原身份仍能命中旧缓存，会话必须保持占位")
        await fixture.shutdown(services)
    }

    @Test("C1.22 加载尚未结束时实际迁移当前文件，旧 sorted 不能回退位置")
    func libraryRelocationDuringLoadDoesNotRollback() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let library = try #require(services.library)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        var entries: [Entry] = []
        for index in 1...3 { entries.append(try await services.sources.provider(for: folder).entry(at: folder.appending("\(index).jpg"))) }
        var stale = entries
        stale[1].identity.size += 1
        let id = try await library.createPlaylist(named: "加载中迁移")
        _ = try await library.addItems(stale, to: id)
        let loader = PausedLibraryLoader(base: services.loader)
        let session = services.makeSession(loader: loader)
        let opening = Task { await session.open(.playlist(id), at: entries[1].location) }
        try await waitUntil { loader.isPaused && session.book?.pages.count == 3 }
        #expect(session.currentPage == 1)
        var applied = services.appliedFileChanges().makeAsyncIterator()
        let moved = await services.fileOperations?.perform(.rename(entries[1].location, to: "during-load.jpg"))
        #expect(moved?.failures.isEmpty == true)
        _ = await applied.next()
        let target = folder.appending("during-load.jpg")
        let expected = [entries[0].location, target, entries[2].location]
        #expect(session.book?.pages.map(\.id) == expected)
        loader.release()
        await opening.value
        #expect(session.book?.pages.map(\.id) == expected)
        #expect(session.currentPage == 1)
        #expect(try await library.items(of: id).map(\.location) == expected)
        #expect(loader.loads == 1)
        await fixture.shutdown(services)
    }

    @Test("C1.16 shutdown 落盘资料库；全局上限即时生效；Mock 内存资料库可列可加入可打开")
    func libraryShutdownAndMock() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        #expect(services.library != nil && services.availability != nil)
        let folder = try await services.sources.location(for: fixture.root.appending(path: "pages"))
        let session = services.makeSession()
        await session.open(folder, at: nil)
        await fixture.shutdown(services)
        let persisted = try SQLiteLibraryStore(databaseURL: fixture.configuration.supportDirectory.appending(path: "library.sqlite"), historyLimit: 1000)
        #expect(try await persisted.history().map(\.book) == [folder])
        let reopened = try await fixture.make()
        let reopenedLibrary = try #require(reopened.library)
        try await reopenedLibrary.recordOpened(folder.appending("other"), at: Date().addingTimeInterval(1))
        try await reopened.settings.updateGlobal { $0.historyLimit = 1 }
        try await waitUntil { try await reopenedLibrary.history().count == 1 }
        await fixture.shutdown(reopened)

        let mock = CoreServices.makeMock(MockOptions(timing: .instant))
        #expect(mock.availability == nil)
        let memory = try #require(mock.library as? MockLibraryStore)
        let root = Location(root: MockTree.sample.root)
        var books: [Entry] = []
        for try await event in mock.bookshelf.items(in: root, sort: SortSpec(key: .name)) {
            if case let .sorted(entries) = event { books = entries }
        }
        let book = try #require(books.first)
        let regular = mock.makeSession()
        await regular.open(book.location, at: nil)
        let page = try #require(regular.book?.pages.first?.entry)
        let id = try await memory.createPlaylist(named: "内存")
        #expect(try await memory.addItems([page, page], to: id) == AddReport(added: 1, alreadyPresent: 1))
        #expect(await memory.playlists().first?.count == 1)
        let virtual = mock.makeSession()
        await virtual.open(.playlist(id), at: nil)
        #expect(virtual.loadError == nil && virtual.book?.pages.map(\.id) == [page.location])
        await mock.shutdown()
    }

    @Test("C1.12 真实组合根写评分后广播 rewritten、缩略图不重解码、搜索可筛、会话当前页不变")
    func setMetadataChangeChainAndCarryOver() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let pagesDir = fixture.root.appending(path: "pages")
        let folderLocation = try await services.sources.location(for: pagesDir)

        let session = services.makeSession()
        await session.open(folderLocation, at: nil)
        #expect(session.loadError == nil)
        session.go(.index(2))
        let targetPage = try #require(session.book?.pages[2])
        let oldIdentity = targetPage.entry.identity

        // 先生成缩略图并记录管线解码次数
        let initialThumb = try await services.pipeline.thumbnail(for: oldIdentity, maxPixel: 96, priority: .visible)
        #expect(initialThumb.image.height == 96)
        let pipeline = try #require(services.pipeline as? FileImagePipeline)
        let sessionID = session.id
        try await waitUntil { pipeline.prefetchInFlightCount(session: sessionID) == 0 }
        let decodeCountBefore = pipeline.sourceDecodeCount

        let appliedStream = services.appliedFileChanges()
        let receivedTask = Task {
            for await batch in appliedStream { return batch }
            return [FileChange]()
        }

        let fileOps = try #require(services.fileOperations)
        let opResult = await fileOps.perform(.setMetadata([targetPage.id], XMPFields(rating: 5, tags: ["精选"])))
        #expect(opResult.failures.isEmpty)
        let appliedBatch = await receivedTask.value
        guard case let .rewritten(newEntry, previous, newMeta) = try #require(appliedBatch.first) else {
            Issue.record("appliedFileChanges 应收到 .rewritten")
            await fixture.shutdown(services)
            return
        }
        #expect(previous == oldIdentity)
        #expect(newEntry.identity != oldIdentity)
        #expect(newMeta.rating == 5)
        #expect(newMeta.tags == ["精选"])

        // 缩略图已改挂到新 key，取新 identity 缩略图不重新解码
        let carriedThumb = try await services.pipeline.thumbnail(for: newEntry.identity, maxPixel: 96, priority: .visible)
        #expect(carriedThumb.image.height == 96)
        #expect(pipeline.sourceDecodeCount == decodeCountBefore)

        // SearchCatalog 按新评分与标签可筛到
        let search = try #require(services.search)
        let searchResult = try await search.query(SearchQuery(scope: folderLocation, minimumRating: 5, tags: ["精选"]))
        #expect(searchResult.hits.map(\.entry.location) == [targetPage.id])
        #expect(searchResult.hits.first?.rating == 5)
        #expect(searchResult.hits.first?.tags == ["精选"])

        // 会话保持当前页不变、不重载，页的 identity 与 metadata 已更新
        #expect(session.currentFrame == 2)
        #expect(session.book?.pages.count == 12)
        #expect(session.book?.pages[2].entry.identity == newEntry.identity)
        #expect(session.book?.pages[2].metadata?.rating == 5)
        #expect(session.book?.pages[2].metadata?.tags == ["精选"])

        await fixture.shutdown(services)
    }

    @Test("C1.13 metadataDetails 对本机 JPEG 与压缩包内 JPEG 都返回字段")
    func metadataDetailsForLocalAndArchiveJPEG() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()

        // 写一张带评分与标签的本机 JPEG，并打包进独立 zip
        let localURL = fixture.root.appending(path: "detail-sample.jpg")
        let baseData = try Data(contentsOf: fixture.sourceImage)
        let taggedData = try XMPWriter.write(XMPFields(rating: 4, tags: ["样张", "精选"]), into: baseData)
        try taggedData.write(to: localURL)

        let archiveDir = fixture.root.appending(path: "detail-archive-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try taggedData.write(to: archiveDir.appending(path: "inside.jpg"))
        let zipURL = fixture.root.appending(path: "detail-sample.zip")
        try run("/usr/bin/zip", ["-q", zipURL.path, "inside.jpg"], in: archiveDir)

        let localLocation = try await services.sources.location(for: localURL)
        let localEntry = try await services.sources.provider(for: localLocation).entry(at: localLocation)
        let localDetails = try await services.metadataDetails(for: localEntry)
        #expect(localDetails.format == "JPEG")
        #expect(localDetails.pixelSize == PixelSize(width: 480, height: 720))
        #expect(localDetails.fields?.rating == 4)
        #expect(localDetails.fields?.tags == ["样张", "精选"])

        let archiveLocation = try await services.sources.location(for: zipURL).appendingLayer(["inside.jpg"])
        let archiveEntry = try await services.sources.provider(for: archiveLocation).entry(at: archiveLocation)
        let archiveDetails = try await services.metadataDetails(for: archiveEntry)
        #expect(archiveDetails.format == "JPEG")
        #expect(archiveDetails.pixelSize == PixelSize(width: 480, height: 720))
        #expect(archiveDetails.fields?.rating == 4)
        #expect(archiveDetails.fields?.tags == ["样张", "精选"])

        await fixture.shutdown(services)
    }

    @Test("C1.18 改名、同卷移动打过分的图和所在文件夹后，搜索按评分仍能筛到新位置")
    func ratedFileMetadataFollowsRenameAndFolderMove() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.clean() }
        let services = try await fixture.make()
        let fileOps = try #require(services.fileOperations)
        let search = try #require(services.search)

        let workRoot = fixture.root.appending(path: "s9-move", directoryHint: .isDirectory)
        let folderA = workRoot.appending(path: "folderA", directoryHint: .isDirectory)
        let destDir = workRoot.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.sourceImage, to: folderA.appending(path: "hero.jpg"))

        let rootLocation = try await services.sources.location(for: workRoot)
        let folderALocation = try await services.sources.location(for: folderA)
        let destLocation = try await services.sources.location(for: destDir)
        let heroLocation = folderALocation.appending("hero.jpg")

        // 先通过书架与会话加载，填充 DirectoryCache 与 search_entries
        for try await _ in services.bookshelf.items(in: rootLocation, sort: SortSpec(key: .name)) {}
        for try await _ in services.bookshelf.items(in: destLocation, sort: SortSpec(key: .name)) {}
        let session = services.makeSession()
        await session.open(folderALocation, at: nil)
        #expect(session.book?.pages.count == 1)

        func waitNextApplied(_ operation: FileOperation) async throws {
            let stream = services.appliedFileChanges()
            let waiter = Task {
                for await batch in stream { return batch }
                return [FileChange]()
            }
            let result = await fileOps.perform(operation)
            #expect(result.failures.isEmpty)
            let batch = await waiter.value
            #expect(!batch.isEmpty)
        }

        // 1. 打 4 星与标签
        try await waitNextApplied(.setMetadata([heroLocation], XMPFields(rating: 4, tags: ["迁移测试"])))
        var hits = try await search.query(SearchQuery(scope: rootLocation, minimumRating: 4, tags: ["迁移测试"])).hits
        #expect(hits.map(\.entry.location) == [heroLocation])

        // 2. 改名文件 hero.jpg -> renamed.jpg
        try await waitNextApplied(.rename(heroLocation, to: "renamed.jpg"))
        let renamedLocation = folderALocation.appending("renamed.jpg")
        hits = try await search.query(SearchQuery(scope: rootLocation, minimumRating: 4, tags: ["迁移测试"])).hits
        #expect(hits.map(\.entry.location) == [renamedLocation])

        // 3. 改名所在文件夹 folderA -> folderB
        try await waitNextApplied(.rename(folderALocation, to: "folderB"))
        let folderBLocation = rootLocation.appending("folderB")
        let afterFolderRename = folderBLocation.appending("renamed.jpg")
        hits = try await search.query(SearchQuery(scope: rootLocation, minimumRating: 4, tags: ["迁移测试"])).hits
        #expect(hits.map(\.entry.location) == [afterFolderRename])

        // 4. 同卷移动文件夹 folderB -> dest/folderB
        try await waitNextApplied(.transfer([folderBLocation], into: destLocation, mode: .move, conflict: .skip))
        let finalLocation = destLocation.appending("folderB").appending("renamed.jpg")
        hits = try await search.query(SearchQuery(scope: rootLocation, minimumRating: 4, tags: ["迁移测试"])).hits
        #expect(hits.map(\.entry.location) == [finalLocation])
        #expect(hits.first?.rating == 4)
        #expect(hits.first?.tags == ["迁移测试"])

        await fixture.shutdown(services)
    }
}

#if DEBUG
/// 取消设置订阅是 shutdown 入口的同步步骤，必定先于内部关闭任务的创建。
private final class ShutdownDelaySettings: SettingsStore {
    let base: any SettingsStore
    let waiting = Atomic(false)
    let cancellationInterval = Mutex<ClosedRange<ContinuousClock.Instant>?>(nil)
    private let next = Mutex<CheckedContinuation<SettingsChange?, Never>?>(nil)

    init(base: any SettingsStore) { self.base = base }
    func resolve(for book: Location) async -> ResolvedBookSettings { await base.resolve(for: book) }
    func bookMemory(for book: Location) async -> BookMemory? { await base.bookMemory(for: book) }
    func saveBookMemory(_ memory: BookMemory) async { await base.saveBookMemory(memory) }
    func relocateBookMemory(from source: Location, to target: Location) async { await base.relocateBookMemory(from: source, to: target) }
    func global() async -> GlobalSettings { await base.global() }
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws { try await base.updateGlobal(change) }
    func pathRules() async -> [PathRule] { await base.pathRules() }
    func updatePathRules(_ change: @Sendable (inout [PathRule]) -> Void) async throws { try await base.updatePathRules(change) }
    func changes() -> AsyncStream<SettingsChange> {
        AsyncStream(unfolding: { [self] in
            await withCheckedContinuation { continuation in
                next.withLock { $0 = continuation }
                waiting.store(true, ordering: .relaxed)
            }
        }, onCancel: { [self] in
            let start = ContinuousClock.now
            Thread.sleep(forTimeInterval: 0.25)
            cancellationInterval.withLock { $0 = start ... .now }
            next.withLock { $0.take() }?.resume(returning: nil)
        })
    }
}
#endif

private final class CountedLibraryLoader: BookLoader {
    let base: any BookLoader
    let count = Mutex(0)
    init(base: any BookLoader) { self.base = base }
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        count.withLock { $0 += 1 }
        return base.load(location, settings: settings, startingAt: page)
    }
}

private final class PausedLibraryLoader: BookLoader {
    let base: any BookLoader
    let pauseSecondSorted: Bool
    let pauseFirstSorted: Bool
    private struct State {
        var loads = 0; var paused = false; var completed = 0
        var availability: [Location: Availability] = [:]
    }
    private let state = Mutex(State())
    private let gate = AsyncStream<Void>.makeStream()
    init(base: any BookLoader, pauseSecondSorted: Bool = true, pauseFirstSorted: Bool = false) {
        self.base = base; self.pauseSecondSorted = pauseSecondSorted; self.pauseFirstSorted = pauseFirstSorted
    }
    var loads: Int { state.withLock { $0.loads } }
    var isPaused: Bool { state.withLock { $0.paused } }
    var completed: Int { state.withLock { $0.completed } }
    var availability: [Location: Availability] { state.withLock { $0.availability } }
    func release() { gate.continuation.yield(()); gate.continuation.finish() }

    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        state.withLock { $0.loads += 1 }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var sorted = 0
                    for try await event in base.load(location, settings: settings, startingAt: page) {
                        if case .sorted = event {
                            sorted += 1
                            if sorted == 2 && pauseSecondSorted || sorted == 1 && pauseFirstSorted {
                                state.withLock { $0.paused = true }
                                for await _ in gate.stream { break }
                            }
                        }
                        if case let .availability(values) = event {
                            state.withLock { $0.availability.merge(values, uniquingKeysWith: { _, new in new }) }
                        }
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    state.withLock { $0.completed += 1 }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func writeLibraryVideo(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 96])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
        pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: 64, height: 96)))
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
        let pool = try #require(receiver.pixelBufferPool)
        var buffer = try pool.makeMutablePixelBuffer()
        buffer.accessUnsafeMutableRawPlaneBytes { planes in
            for plane in planes { plane.bytes.initializeMemory(as: UInt8.self, repeating: 127) }
        }
        try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(index), timescale: 3))
    }
    receiver.finish()
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    await writer.finishWriting()
    #expect(writer.status == .completed)
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
