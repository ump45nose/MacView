import CoreGraphics
import Darwin
import Foundation
import ImageIO
import MVCache
import MVFoundation
import MVIO
import MVMedia
import MVMetadata
import MVSearch
import Synchronization
import Testing
import UniformTypeIdentifiers

@Suite(.serialized) struct FolderIndexerTests {
    // MARK: - Helpers

    private static func writeFileDirect(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        }
    }

    private static func makeTempDirectory(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeSmallJPEG(width: Int = 32, height: Int = 24) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw MediaError.decodeFailed("无法生成测试图像")
        }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let filled = context.makeImage() else { return try encodeJPEG(cgImage) }
        return try encodeJPEG(filled)
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError.decodeFailed("无法创建 JPEG 编码器")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.decodeFailed("JPEG 编码失败")
        }
        return data as Data
    }

    private final class CountingSourceRegistry: SourceRegistry {
        struct Counters: Sendable {
            var opens: [Location: Int] = [:]
            var reads: [Location: Int] = [:]
            var listPriorities: [IOPriority] = []
            var readPriorities: [IOPriority] = []
        }

        let base: any SourceRegistry
        private let counters = Mutex(Counters())
        private let injectedReadErrors = Mutex<[Location: any Error]>([:])
        private let injectedListErrors = Mutex<[Location: any Error]>([:])
        private let listHook = Mutex<(@Sendable (Location) async -> Void)?>(nil)
        private let readHook = Mutex<(@Sendable (Location) async -> Void)?>(nil)
        private let healthStreamOverride = Mutex<AsyncStream<[VolumeHealth]>?>(nil)

        init(base: any SourceRegistry) {
            self.base = base
        }

        func resetCounters() {
            counters.withLock { $0 = Counters() }
        }

        func snapshot() -> Counters {
            counters.withLock { $0 }
        }

        func setReadError(_ error: (any Error)?, for location: Location) {
            injectedReadErrors.withLock { $0[location] = error }
        }

        func setListError(_ error: (any Error)?, for location: Location) {
            injectedListErrors.withLock { $0[location] = error }
        }

        func setListHook(_ hook: (@Sendable (Location) async -> Void)?) {
            listHook.withLock { $0 = hook }
        }

        func setReadHook(_ hook: (@Sendable (Location) async -> Void)?) {
            readHook.withLock { $0 = hook }
        }

        func setHealthStream(_ stream: AsyncStream<[VolumeHealth]>?) {
            healthStreamOverride.withLock { $0 = stream }
        }

        func provider(for location: Location) throws -> any ContainerProvider {
            CountingContainerProvider(
                base: try base.provider(for: location),
                owner: self
            )
        }

        func recordListPriority(_ priority: IOPriority) {
            counters.withLock { $0.listPriorities.append(priority) }
        }

        func recordOpen(_ location: Location) {
            counters.withLock { $0.opens[location, default: 0] += 1 }
        }

        func recordRead(_ location: Location, priority: IOPriority) {
            counters.withLock {
                $0.reads[location, default: 0] += 1
                $0.readPriorities.append(priority)
            }
        }

        func listError(for location: Location) -> (any Error)? {
            injectedListErrors.withLock { $0[location] }
        }

        func readError(for location: Location) -> (any Error)? {
            injectedReadErrors.withLock { $0[location] }
        }

        func currentListHook() -> (@Sendable (Location) async -> Void)? {
            listHook.withLock { $0 }
        }

        func currentReadHook() -> (@Sendable (Location) async -> Void)? {
            readHook.withLock { $0 }
        }

        func location(for fileURL: URL) async throws -> Location {
            try await base.location(for: fileURL)
        }

        func volumeHealth() -> AsyncStream<[VolumeHealth]> {
            if let override = healthStreamOverride.withLock({ $0 }) {
                return override
            }
            return base.volumeHealth()
        }
    }

    private struct CountingContainerProvider: ContainerProvider {
        let base: any ContainerProvider
        let owner: CountingSourceRegistry

        func canHandle(_ location: Location) -> Bool { base.canHandle(location) }

        func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error> {
            owner.recordListPriority(priority)
            let error = owner.listError(for: container)
            let hook = owner.currentListHook()
            let base = base
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        if let hook { await hook(container) }
                        if let error { throw error }
                        for try await batch in base.children(of: container, priority: priority) {
                            continuation.yield(batch)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func entry(at location: Location) async throws -> Entry {
            try await base.entry(at: location)
        }

        func open(_ location: Location) async throws -> any ByteSource {
            owner.recordOpen(location)
            if let hook = owner.currentReadHook() { await hook(location) }
            if let error = owner.readError(for: location) { throw error }
            let source = try await base.open(location)
            return CountingByteSource(base: source, owner: owner)
        }

        func fileLease(for location: Location) async throws -> FileLease {
            try await base.fileLease(for: location)
        }
    }

    private struct CountingByteSource: ByteSource {
        let base: any ByteSource
        let owner: CountingSourceRegistry
        var identity: ContentIdentity { base.identity }

        func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
            owner.recordRead(identity.location, priority: priority)
            return try await base.read(range, priority: priority, group: group)
        }
    }

    // MARK: - C1.14

    @Test("C1.14 三层 2000 项两步索引、深层可搜、评分标签可筛、增量复用与单文件变更重扫")
    func c114ThreeLevelTwoThousandItemsAndIncrementalProbing() async throws {
        let rootDir = try Self.makeTempDirectory(prefix: "mvsearch-c114")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c114-cache")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let plainJPEG = try Self.makeSmallJPEG()
        let ratedJPEG = try XMPWriter.write(XMPFields(rating: 5, tags: ["精选", "风景"]), into: plainJPEG)

        // 3 层结构：10 个一级目录 × 10 个二级目录 × 19 张图 = 1900 张图 + 110 个目录 = 2010 项。
        var targetDeepURL: URL!
        var modifyTargetURL: URL!
        let fm = FileManager.default
        for i in 0..<10 {
            let l1 = rootDir.appending(path: String(format: "dir-%02d", i), directoryHint: .isDirectory)
            try fm.createDirectory(at: l1, withIntermediateDirectories: true)
            for j in 0..<10 {
                let l2 = l1.appending(path: String(format: "sub-%02d", j), directoryHint: .isDirectory)
                try fm.createDirectory(at: l2, withIntermediateDirectories: true)
                for k in 0..<19 {
                    let isDeepSpecial = (i == 9 && j == 9 && k == 18)
                    let isModifyTarget = (i == 5 && j == 4 && k == 3)
                    let name = isDeepSpecial ? "deep_aurora_star.jpg" : String(format: "img-%02d-%02d-%02d.jpg", i, j, k)
                    let fileURL = l2.appending(path: name)
                    if isDeepSpecial {
                        try ratedJPEG.write(to: fileURL)
                        targetDeepURL = fileURL
                    } else {
                        try plainJPEG.write(to: fileURL)
                        if isModifyTarget { modifyTargetURL = fileURL }
                    }
                }
            }
        }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let baseSources = FileSourceRegistry(scheduler: scheduler)
        let counting = CountingSourceRegistry(base: baseSources)
        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let directories = DirectoryCache(index: index)
        let metadata = MetadataIndex(index: index)
        let catalog = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: counting, directories: directories, metadata: metadata)

        let rootLocation = try await counting.location(for: rootDir)
        let deepLocation = try await counting.location(for: targetDeepURL)
        let modifyLocation = try await counting.location(for: modifyTargetURL)

        var checkedAfterListing = false
        var finalProgress: IndexProgress?

        for try await progress in indexer.index(rootLocation) {
            if progress.phase == .probing && !checkedAfterListing {
                checkedAfterListing = true
                // 第一步刚结束即可搜到深层文件
                let deepSearch = try await catalog.query(SearchQuery(terms: ["aurora"], scope: rootLocation))
                #expect(deepSearch.hits.map(\.entry.location) == [deepLocation])
                #expect(deepSearch.indexedCount == 2010)
            }
            finalProgress = progress
        }

        let finished = try #require(finalProgress)
        #expect(checkedAfterListing)
        #expect(finished.phase == .finished)
        #expect(finished.listed == 2010)
        #expect(finished.toProbe == 1900)
        #expect(finished.probed == 1900)
        #expect(finished.failures == 0)

        let firstCounters = counting.snapshot()
        #expect(firstCounters.listPriorities.allSatisfy { $0 == .background })
        #expect(firstCounters.readPriorities.allSatisfy { $0 == .background })

        // 第二步完成后评分与标签可筛
        let ratedResult = try await catalog.query(
            SearchQuery(scope: rootLocation, minimumRating: 5, tags: ["精选", "风景"])
        )
        #expect(ratedResult.hits.count == 1)
        #expect(ratedResult.hits.first?.entry.location == deepLocation)
        #expect(ratedResult.hits.first?.rating == 5)
        #expect(ratedResult.hits.first?.tags == ["精选", "风景"])

        // 再跑一次：已探测文件一次都不读
        counting.resetCounters()
        var secondFinal: IndexProgress?
        for try await progress in indexer.index(rootLocation) {
            secondFinal = progress
        }
        let second = try #require(secondFinal)
        #expect(second.phase == .finished)
        #expect(second.toProbe == 0)
        #expect(second.probed == 0)
        #expect(second.failures == 0)
        let secondCounters = counting.snapshot()
        #expect(secondCounters.opens.isEmpty)
        #expect(secondCounters.reads.isEmpty)

        // 改动其中一张图（写入新 XMP 评分与标签，改变文件大小与修改时间），第三次只读这一张
        let updatedJPEG = try XMPWriter.write(XMPFields(rating: 4, tags: ["人像"]), into: plainJPEG)
        try updatedJPEG.write(to: modifyTargetURL, options: .atomic)
        let futureDate = Date().addingTimeInterval(5)
        try fm.setAttributes([.modificationDate: futureDate], ofItemAtPath: modifyTargetURL.path)

        counting.resetCounters()
        var thirdFinal: IndexProgress?
        for try await progress in indexer.index(rootLocation) {
            thirdFinal = progress
        }
        let third = try #require(thirdFinal)
        #expect(third.phase == .finished)
        #expect(third.toProbe == 1)
        #expect(third.probed == 1)
        #expect(third.failures == 0)
        let thirdCounters = counting.snapshot()
        #expect(Array(thirdCounters.opens.keys) == [modifyLocation])
        #expect(Array(thirdCounters.reads.keys) == [modifyLocation])

        let modifiedResult = try await catalog.query(
            SearchQuery(scope: rootLocation, minimumRating: 4, tags: ["人像"])
        )
        #expect(modifiedResult.hits.map(\.entry.location) == [modifyLocation])
        #expect(modifiedResult.hits.first?.rating == 4)
        #expect(modifiedResult.hits.first?.tags == ["人像"])
    }

    // MARK: - C1.15

    @Test("C1.15 跳过 ._ 与回收目录，保留压缩包条目但不展开递归")
    func c115SkipsAppleDoubleRecycleDirsAndDoesNotExpandArchives() async throws {
        let rootDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-filter")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-filter-cache")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let jpeg = try Self.makeSmallJPEG()
        let fm = FileManager.default
        try jpeg.write(to: rootDir.appending(path: "keep.jpg"))
        try jpeg.write(to: rootDir.appending(path: "._keep.jpg"))
        try Data("PK\u{03}\u{04}dummy".utf8).write(to: rootDir.appending(path: "album.zip"))

        for recycle in [".Trash", ".Trashes", "#recycle", "@Recycle", "$RECYCLE.BIN"] {
            let dir = rootDir.appending(path: recycle, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpeg.write(to: dir.appending(path: "ignored.jpg"))
        }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let catalog = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: sources, directories: DirectoryCache(index: index), metadata: MetadataIndex(index: index))

        let rootLocation = try await sources.location(for: rootDir)
        var finalProgress: IndexProgress?
        for try await progress in indexer.index(rootLocation) {
            finalProgress = progress
        }

        let finished = try #require(finalProgress)
        #expect(finished.phase == .finished)
        #expect(finished.listed == 2)
        #expect(finished.probed == 1)
        #expect(finished.failures == 0)

        let all = try await catalog.query(SearchQuery(scope: rootLocation))
        let names = Set(all.hits.map(\.entry.name))
        #expect(names == ["keep.jpg", "album.zip"])
        #expect(all.hits.first(where: { $0.entry.name == "album.zip" })?.entry.kind == .archive(.zip))
    }

    @Test("C1.15 取消后流结束且已写入部分保留")
    func c115CancellationStopsAndPreservesWrittenPart() async throws {
        let rootDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-cancel")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-cancel-cache")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let jpeg = try Self.makeSmallJPEG()
        let fm = FileManager.default
        for i in 0..<20 {
            let sub = rootDir.appending(path: String(format: "sub-%02d", i), directoryHint: .isDirectory)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try jpeg.write(to: sub.appending(path: "p.jpg"))
        }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let counting = CountingSourceRegistry(base: FileSourceRegistry(scheduler: scheduler))
        counting.setListHook { _ in
            try? await Task.sleep(for: .milliseconds(15))
        }

        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let catalog = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: counting, directories: DirectoryCache(index: index), metadata: MetadataIndex(index: index))
        let rootLocation = try await counting.location(for: rootDir)

        var sawFinished = false
        var lastListed = 0
        for try await progress in indexer.index(rootLocation) {
            lastListed = progress.listed
            if progress.phase == .finished { sawFinished = true }
            if progress.phase == .listing && progress.listed >= 21 {
                break
            }
        }

        #expect(!sawFinished)
        #expect(lastListed >= 21)
        let indexedCount = try await catalog.indexedCount(under: rootLocation)
        #expect(indexedCount >= 21)
        #expect(indexedCount < 40)
    }

    @Test("C1.15 单项读失败计入 failures 后继续，修复后下次重试成功")
    func c115SingleItemFailureCountsAndRetriesNextRun() async throws {
        let rootDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-fail")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-fail-cache")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let jpeg = try Self.makeSmallJPEG()
        let goodURL = rootDir.appending(path: "good.jpg")
        let badURL = rootDir.appending(path: "corrupt.jpg")
        let ioFailURL = rootDir.appending(path: "iofail.jpg")
        try jpeg.write(to: goodURL)
        try Data("not a jpeg".utf8).write(to: badURL)
        try jpeg.write(to: ioFailURL)

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let counting = CountingSourceRegistry(base: FileSourceRegistry(scheduler: scheduler))
        let rootLocation = try await counting.location(for: rootDir)
        let ioFailLocation = try await counting.location(for: ioFailURL)
        counting.setReadError(IOError.underlying("injected read error"), for: ioFailLocation)

        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let metadata = MetadataIndex(index: index)
        let indexer = FolderIndexer(sources: counting, directories: DirectoryCache(index: index), metadata: metadata)

        var firstFinal: IndexProgress?
        for try await progress in indexer.index(rootLocation) {
            firstFinal = progress
        }
        let first = try #require(firstFinal)
        #expect(first.phase == .finished)
        #expect(first.listed == 3)
        #expect(first.toProbe == 3)
        #expect(first.probed == 1)
        #expect(first.failures == 2)

        // 失败项未落库
        let cachedValues = try await metadata.values(in: rootLocation)
        #expect(cachedValues.count == 1)

        // 修复坏图并解除注入错误，下次运行只重试这 2 张且全部成功
        try jpeg.write(to: badURL, options: .atomic)
        counting.setReadError(nil, for: ioFailLocation)
        counting.resetCounters()

        var secondFinal: IndexProgress?
        for try await progress in indexer.index(rootLocation) {
            secondFinal = progress
        }
        let second = try #require(secondFinal)
        #expect(second.phase == .finished)
        #expect(second.toProbe == 2)
        #expect(second.probed == 2)
        #expect(second.failures == 0)
        #expect(try await metadata.values(in: rootLocation).count == 3)
    }

    @Test("C1.15 同卷并发调用串行排队")
    func c115SameVolumeSerialQueue() async throws {
        let rootA = try Self.makeTempDirectory(prefix: "mvsearch-c115-vol-a")
        let rootB = try Self.makeTempDirectory(prefix: "mvsearch-c115-vol-b")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-vol-cache")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let jpeg = try Self.makeSmallJPEG()
        try jpeg.write(to: rootA.appending(path: "a.jpg"))
        try jpeg.write(to: rootB.appending(path: "b.jpg"))

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let counting = CountingSourceRegistry(base: FileSourceRegistry(scheduler: scheduler))
        let locA = try await counting.location(for: rootA)
        let locB = try await counting.location(for: rootB)

        let events = Mutex<[String]>([])
        let aEntered = AsyncStream<Void>.makeStream()
        let releaseA = AsyncStream<Void>.makeStream()

        counting.setListHook { location in
            if location == locA {
                events.withLock { $0.append("A-start") }
                aEntered.continuation.yield()
                for await _ in releaseA.stream { break }
                events.withLock { $0.append("A-end") }
            } else if location == locB {
                events.withLock { $0.append("B-start") }
            }
        }

        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let indexer = FolderIndexer(sources: counting, directories: DirectoryCache(index: index), metadata: MetadataIndex(index: index))

        let taskA = Task {
            for try await _ in indexer.index(locA) {}
        }
        // 等 A 真正进入 listing 后再启动同卷的 B
        for await _ in aEntered.stream { break }

        let taskB = Task {
            for try await _ in indexer.index(locB) {}
        }
        try await Task.sleep(for: .milliseconds(40))
        // B 必须仍在排队，尚未开始 list
        #expect(events.withLock { $0 } == ["A-start"])

        releaseA.continuation.yield()
        releaseA.continuation.finish()

        try await taskA.value
        try await taskB.value

        #expect(events.withLock { $0 } == ["A-start", "A-end", "B-start"])
    }

    @Test("C1.15 卷进入 degraded 时整步以错误结束且已完成部分保留")
    func c115VolumeDegradedStopsWithErrorAndPreservesProgress() async throws {
        let rootDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-degraded")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c115-degraded-cache")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        let jpeg = try Self.makeSmallJPEG()
        let fm = FileManager.default
        let sub1 = rootDir.appending(path: "sub-1", directoryHint: .isDirectory)
        let sub2 = rootDir.appending(path: "sub-2", directoryHint: .isDirectory)
        try fm.createDirectory(at: sub1, withIntermediateDirectories: true)
        try fm.createDirectory(at: sub2, withIntermediateDirectories: true)
        try jpeg.write(to: sub1.appending(path: "ok.jpg"))
        try jpeg.write(to: sub2.appending(path: "fail.jpg"))

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let counting = CountingSourceRegistry(base: FileSourceRegistry(scheduler: scheduler))
        let rootLocation = try await counting.location(for: rootDir)
        let sub2Location = try await counting.location(for: sub2)
        counting.setListError(IOError.volumeDegraded(rootLocation.root), for: sub2Location)

        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let catalog = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: counting, directories: DirectoryCache(index: index), metadata: MetadataIndex(index: index))

        var caughtError: (any Error)?
        do {
            for try await _ in indexer.index(rootLocation) {}
        } catch {
            caughtError = error
        }

        #expect(caughtError as? IOError == .volumeDegraded(rootLocation.root))
        // 根目录和 sub-1 中已写入的部分仍保留在索引里
        #expect(try await catalog.indexedCount(under: rootLocation) >= 2)
    }

    // MARK: - C1.16

    @Test("C1.16 NFS 300 个小 JPEG 两步实测计时并彻底清理")
    func c116NfsThreeHundredSmallJpegsTiming() async throws {
        let nfsBase = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "MacViewBench/fileops-a", directoryHint: .isDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: nfsBase.path), fm.isWritableFile(atPath: nfsBase.path) else {
            // CI 或未挂载 NFS 测试目录时跳过
            return
        }

        let benchName = "w14-bench-\(UUID().uuidString)"
        let benchDir = nfsBase.appending(path: benchName, directoryHint: .isDirectory)
        let benchAppleDouble = nfsBase.appending(path: "._\(benchName)")
        let cacheDir = try Self.makeTempDirectory(prefix: "mvsearch-c116-cache")
        try fm.createDirectory(at: benchDir, withIntermediateDirectories: true)
        defer {
            for _ in 0..<3 {
                if !fm.fileExists(atPath: benchDir.path) { break }
                try? fm.removeItem(at: benchDir)
            }
            try? fm.removeItem(at: benchAppleDouble)
            try? fm.removeItem(at: cacheDir)
        }

        let plainJPEG = try Self.makeSmallJPEG(width: 64, height: 48)
        let ratedJPEG = try XMPWriter.write(XMPFields(rating: 5, tags: ["NFS", "基准"]), into: plainJPEG)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<300 {
                if i >= 8 { try await group.next() }
                let fileURL = benchDir.appending(path: String(format: "nfs-%03d.jpg", i))
                let payload = (i == 0) ? ratedJPEG : plainJPEG
                group.addTask {
                    try Self.writeFileDirect(payload, to: fileURL)
                }
            }
            try await group.waitForAll()
        }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        let index = try CacheIndex(databaseURL: cacheDir.appending(path: "index.sqlite"))
        let catalog = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: sources, directories: DirectoryCache(index: index), metadata: MetadataIndex(index: index))

        let benchLocation = try await sources.location(for: benchDir)
        let clock = ContinuousClock()
        let start = clock.now
        var listingEnd: ContinuousClock.Instant?
        var finalProgress: IndexProgress?

        for try await progress in indexer.index(benchLocation) {
            if progress.phase == .probing, listingEnd == nil {
                listingEnd = clock.now
            }
            finalProgress = progress
        }
        let end = clock.now

        let finished = try #require(finalProgress)
        let tListingEnd = try #require(listingEnd)
        let listingDuration = start.duration(to: tListingEnd)
        let probingDuration = tListingEnd.duration(to: end)
        let totalDuration = start.duration(to: end)

        let listingMs = Double(listingDuration.components.seconds) * 1000
            + Double(listingDuration.components.attoseconds) / 1e15
        let probingMs = Double(probingDuration.components.seconds) * 1000
            + Double(probingDuration.components.attoseconds) / 1e15
        let totalMs = Double(totalDuration.components.seconds) * 1000
            + Double(totalDuration.components.attoseconds) / 1e15
        print(String(format: "[C1.16 NFS 300 JPEG] listing=%.1fms probing=%.1fms total=%.1fms", listingMs, probingMs, totalMs))

        #expect(finished.phase == .finished)
        #expect(finished.listed == 300)
        #expect(finished.toProbe == 300)
        #expect(finished.probed == 300)
        #expect(finished.failures == 0)

        let hit = try await catalog.query(SearchQuery(scope: benchLocation, minimumRating: 5, tags: ["NFS"]))
        #expect(hit.hits.count == 1)
        #expect(hit.hits.first?.entry.name == "nfs-000.jpg")
    }
}
