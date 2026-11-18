import Darwin
import Foundation
import MVCommands
import MVFoundation
@testable import MVFileOps
import MVMedia
import MVLibraryData
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
        func settled(_ expected: [Entry], current: Location) async throws {
            try await waitUntil {
                [first, second].allSatisfy {
                    $0.book?.pages.map(\.id) == expected.map(\.location) && $0.book?.isEnumerated == true &&
                    $0.book?.pages[$0.currentPage].id == current
                }
            }
        }
        _ = try await library.addItems([entries[4]], to: id)
        try await settled(entries, current: entries[2].location)
        #expect(first.book?.pages.last?.metadata?.pixelSize == PixelSize(width: 480, height: 720))
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
}

private final class CountedLibraryLoader: BookLoader {
    let base: any BookLoader
    let count = Mutex(0)
    init(base: any BookLoader) { self.base = base }
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        count.withLock { $0 += 1 }
        return base.load(location, settings: settings, startingAt: page)
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
