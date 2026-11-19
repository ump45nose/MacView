// MVServices：真实服务的组合根；命令处理器由 App 按窗口登记。
import Foundation
import MVArchive
import MVCache
import MVCommands
import MVFoundation
@_exported import MVFileOps
import MVIO
@_exported import MVLibraryData
import MVMedia
import MVMetadata
import MVPipeline
import MVReading
@_exported import MVSearch
import MVSettings
import os
import Synchronization

public struct CoreConfiguration: Sendable {
    public var supportDirectory: URL
    public var cacheDirectory: URL
    public var browseBounds: PixelSize
    public var helperExecutable: URL?

    public init(supportDirectory: URL, cacheDirectory: URL, browseBounds: PixelSize, helperExecutable: URL? = nil) {
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
        self.browseBounds = browseBounds
        self.helperExecutable = helperExecutable
    }
}

@MainActor public final class CoreServices {
    public let sources: any SourceRegistry
    public let pipeline: any ImagePipeline
    public let settings: any SettingsStore
    public let commands: CommandRegistry
    public let bookshelf: any Bookshelf
    public let fileOperations: FileOperationService?
    public let library: (any LibraryStore)?
    public let availability: AvailabilityChecker?
    public let search: SearchCatalog?
    public let indexer: FolderIndexer?
    public let keyBindings: JSONDocumentStore<KeyBindingsFile>?
    let loader: any BookLoader
    let runtime: Runtime?
    private var sessions: [WeakSession] = []
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var settingsTask: Task<Void, Never>?
    private var fileChangesTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var historyTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryTask: Task<ResumeReport, Never>?
    private var shutdownTask: Task<Void, Never>?
    nonisolated private let fileChangeObservers = Mutex<[UUID: AsyncStream<[FileChange]>.Continuation]>([:])
    private static let log = Logger(category: "services")

    struct Runtime: Sendable {
        let scheduler: IOScheduler
        let settings: FileSettingsStore
        let index: CacheIndex
        let caches: PipelineCaches
    }

    private struct WeakSession { weak var value: ReaderSession? }

    /// 保留 Mock 与消费方现有的构造入口。
    public convenience init(
        sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore,
        commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader,
        library: (any LibraryStore)? = nil, search: SearchCatalog? = nil, indexer: FolderIndexer? = nil
    ) {
        self.init(sources: sources, pipeline: pipeline, settings: settings, commands: commands,
                  bookshelf: bookshelf, loader: loader, keyBindings: nil, fileOperations: nil,
                  library: library, availability: nil, search: search, indexer: indexer, runtime: nil)
    }

    private init(
        sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore,
        commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader,
        keyBindings: JSONDocumentStore<KeyBindingsFile>?, fileOperations: FileOperationService?,
        library: (any LibraryStore)?, availability: AvailabilityChecker?, search: SearchCatalog?,
        indexer: FolderIndexer?, runtime: Runtime?
    ) {
        self.sources = sources
        self.pipeline = pipeline
        self.settings = settings
        self.commands = commands
        self.bookshelf = bookshelf
        self.loader = loader
        self.keyBindings = keyBindings
        self.fileOperations = fileOperations
        self.library = library
        self.availability = availability
        self.search = search
        self.indexer = indexer
        self.runtime = runtime
        subscribeLibrary()
        let changes = settings.changes()
        settingsTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                if change == .global { await self?.updateBudgets() }
            }
        }
    }

    public static func make(configuration: CoreConfiguration) async throws -> CoreServices {
        try await make(configuration: configuration, fileOperations: nil)
    }

    static func make(configuration: CoreConfiguration, fileOperations factory: ((FileSystemProvider, URL) throws -> FileOperationService)?) async throws -> CoreServices {
        try FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.cacheDirectory, withIntermediateDirectories: true)
        let settings = try FileSettingsStore(directory: configuration.supportDirectory)
        let global = await settings.global()
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: configuration.helperExecutable))
        let sources = FileSourceRegistry(scheduler: scheduler)
        sources.register(try ArchiveProvider(fileSystem: sources.fileSystem,
                                            extractDirectory: configuration.cacheDirectory.appending(path: "extract")))
        let index = try CacheIndex(databaseURL: configuration.cacheDirectory.appending(path: "index.sqlite"))
        let budgets = global.cache
        let caches = PipelineCaches(
            raw: MemoryCache(budget: budgets.rawBytes), decoded: MemoryCache(budget: budgets.decodedBytes),
            thumbnails: try DiskCache(tier: .thumbnails, cacheDirectory: configuration.cacheDirectory, budget: budgets.thumbnailBytes, index: index),
            browse: try budgets.browseCacheEnabled ? DiskCache(tier: .browse, cacheDirectory: configuration.cacheDirectory, budget: budgets.browseBytes, index: index) : nil,
            metadata: MetadataIndex(index: index), thumbnailMemory: MemoryCache(budget: budgets.thumbnailMemoryBytes),
            preload: MemoryCache(budget: budgets.preloadBytes))
        let directories = DirectoryCache(index: index)
        let pipeline = FileImagePipeline(sources: sources, decoder: ImageDecoder(), caches: caches,
                                         configuration: PipelineConfiguration(browseBounds: configuration.browseBounds, maxDecodeLongSide: global.maxDecodeLongSide))
        let keyBindings = try JSONDocumentStore(fileURL: configuration.supportDirectory.appending(path: "keybindings.json"),
                                               version: 1, defaultValue: KeyBindingsFile())
        let journal = configuration.supportDirectory.appending(path: "transfers.json")
        let fileOperations = try factory?(sources.fileSystem, journal) ?? FileOperationService(fileSystem: sources.fileSystem, journalURL: journal)
        let library = try SQLiteLibraryStore(databaseURL: configuration.supportDirectory.appending(path: "library.sqlite"), historyLimit: global.historyLimit)
        let loader = LibraryBookLoader(
            files: FileBookLoader(sources: sources, directories: directories, metadata: caches.metadata, pipeline: pipeline),
            playlists: PlaylistBookLoader(store: library, sources: sources, directories: directories, metadata: caches.metadata, pipeline: pipeline))
        let search = SearchCatalog(index: index)
        let indexer = FolderIndexer(sources: sources, directories: directories, metadata: caches.metadata)
        let services = CoreServices(sources: sources, pipeline: pipeline, settings: settings, commands: CommandRegistry(),
                                    bookshelf: FileBookshelf(sources: sources, directories: directories),
                                    loader: loader, keyBindings: keyBindings, fileOperations: fileOperations,
                                    library: library, availability: AvailabilityChecker(sources: sources, directories: directories, store: library),
                                    search: search, indexer: indexer,
                                    runtime: Runtime(scheduler: scheduler, settings: settings, index: index, caches: caches))
        services.subscribe(directories: directories)
        services.recoveryTask = Task { await fileOperations.resumeInterruptedTransfers() }
        return services
    }

    deinit {
        pressureSource?.cancel()
        settingsTask?.cancel()
        fileChangesTask?.cancel()
        libraryTask?.cancel()
        historyTasks.values.forEach { $0.cancel() }
        recoveryTask?.cancel()
        let continuations = fileChangeObservers.withLock {
            let values = Array($0.values)
            $0.removeAll()
            return values
        }
        continuations.forEach { $0.finish() }
    }

    public func appliedFileChanges() -> AsyncStream<[FileChange]> {
        guard fileOperations != nil else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let id = UUID()
            fileChangeObservers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.fileChangeObservers.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    public func interruptedTransfersReport() async -> ResumeReport? {
        await recoveryTask?.value
    }

    /// 经 SourceRegistry 增量读取前 64 KB（最高扩至 MediaProbe.headerLimit），解析 EXIF/XMP 详情；压缩包内条目同样可读。
    public nonisolated func metadataDetails(for entry: Entry) async throws -> ImageDetails {
        let provider = try sources.provider(for: entry.location)
        let byteSource = try await provider.open(entry.location)
        let totalSize = max(0, byteSource.identity.size)
        let limit = min(totalSize, Int64(MediaProbe.headerLimit))
        var targetLength = min(limit, Int64(MediaProbe.initialHeaderLength))
        var data = Data()
        while true {
            if Int64(data.count) < targetLength {
                let part = try await byteSource.read(Int64(data.count)..<targetLength, priority: .visible, group: nil)
                data.append(part)
                if part.isEmpty { break }
            }
            if let details = XMPReader.details(fromHeader: data) {
                if details.pixelSize != nil || Int64(data.count) >= limit {
                    return details
                }
            }
            guard Int64(data.count) < limit else { break }
            targetLength = min(limit, max(Int64(MediaProbe.initialHeaderLength), Int64(data.count) * 2))
        }
        if let details = XMPReader.details(fromHeader: data) {
            return details
        }
        throw MediaError.unsupported
    }

    public func makeSession() -> ReaderSession {
        makeSession(loader: loader)
    }

    func makeSession(loader: any BookLoader) -> ReaderSession {
        let session = ReaderSession(loader: loader, settings: settings, bookshelf: bookshelf, pipeline: pipeline)
        session.onBookOpened = { [weak self] book in
            guard let self, let library = self.library, self.shutdownTask == nil else { return }
            let id = UUID(), date = Date()
            self.historyTasks[id] = Task { [weak self] in
                defer { self?.historyTasks.removeValue(forKey: id) }
                guard !Task.isCancelled else { return }
                do { try await library.recordOpened(book, at: date) }
                catch { Self.log.error("记录历史失败：\(error.localizedDescription)") }
            }
        }
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session))
        return session
    }

    private func subscribeLibrary() {
        guard let library else { return }
        let changes = library.changes()
        libraryTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled, let self else { return }
                let id: UUID
                switch change {
                case let .items(value), let .playlistRemoved(value): id = value
                default: continue
                }
                self.sessions.removeAll { $0.value == nil }
                for session in self.sessions.compactMap(\.value) where session.book?.location.playlistID == id {
                    session.reloadBook()
                }
            }
        }
    }

    private func subscribe(directories: DirectoryCache) {
        if let fileOperations {
            let changes = fileOperations.changes()
            fileChangesTask = Task { [weak self] in
                for await batch in changes {
                    guard !Task.isCancelled, let self else { return }
                    let metadataMoves = await self.collectMetadataMoves(for: batch, directories: directories)
                    do { try await directories.apply(batch) }
                    catch { Self.log.error("更新目录缓存失败：\(error.localizedDescription)") }
                    if let metadataIndex = self.runtime?.caches.metadata {
                        if !metadataMoves.isEmpty {
                            do { try await metadataIndex.move(metadataMoves) }
                            catch { Self.log.error("迁移元数据缓存失败：\(error.localizedDescription)") }
                        }
                        for change in batch {
                            if case let .rewritten(newEntry, previous, metadata) = change {
                                let container = newEntry.location.parent ?? newEntry.location
                                do {
                                    try await metadataIndex.store([newEntry.identity.cacheKey: metadata], in: container)
                                    if previous.cacheKey != newEntry.identity.cacheKey {
                                        try await metadataIndex.remove(for: [previous.cacheKey])
                                    }
                                } catch {
                                    Self.log.error("更新重写元数据缓存失败：\(error.localizedDescription)")
                                }
                                await self.pipeline.carryOver(from: previous, to: newEntry.identity)
                            }
                        }
                    }
                    let active = self.sessions.compactMap(\.value)
                    for task in Array(self.historyTasks.values) { await task.value }
                    // 把会话中的最新页先写入旧位置，再迁移书记忆。
                    for session in active where batch.contains(where: { change in
                        if case let .moved(from, _) = change {
                            return session.book?.location.hasPrefix(from) == true || session.book?.pages.contains { $0.id.hasPrefix(from) } == true
                        }
                        return false
                    }) { await session.flush() }
                    for change in batch {
                        if case let .moved(from, to) = change {
                            await self.settings.relocateBookMemory(from: from, to: to.location)
                        }
                    }
                    do { try await self.library?.apply(batch) }
                    catch {
                        Self.log.error("迁移资料库失败：\(error.localizedDescription)")
                    }
                    guard !Task.isCancelled else { return }
                    self.sessions.removeAll { $0.value == nil }
                    for session in active { session.applyFileChanges(batch) }
                    let continuations = self.fileChangeObservers.withLock { Array($0.values) }
                    continuations.forEach { $0.yield(batch) }
                }
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            Task { @MainActor [weak self] in self?.handleMemoryPressure(event) }
        }
        pressureSource = source
        source.resume()
    }

    private func collectMetadataMoves(
        for batch: [FileChange],
        directories: DirectoryCache
    ) async -> [(from: String, to: String, container: Location)] {
        var pairs: [(from: String, to: String, container: Location)] = []
        for change in batch {
            guard case let .moved(from, to) = change else { continue }
            let targetContainer = to.location.parent ?? to.location
            let fallbackOldIdentity = ContentIdentity(
                location: from,
                size: to.identity.size,
                modificationNanos: to.identity.modificationNanos,
                checksum: to.identity.checksum
            )
            pairs.append((from: fallbackOldIdentity.cacheKey, to: to.identity.cacheKey, container: targetContainer))
            if let fromParent = from.parent,
               let listing = try? await directories.cachedChildren(of: fromParent),
               let cached = listing.entries.first(where: { $0.location == from }),
               cached.identity.cacheKey != fallbackOldIdentity.cacheKey {
                pairs.append((from: cached.identity.cacheKey, to: to.identity.cacheKey, container: targetContainer))
            }
            let isContainer: Bool = switch to.kind {
            case .directory, .archive: true
            case .image, .video, .other: false
            }
            if isContainer,
               let search,
               let descendants = try? await search.query(SearchQuery(scope: from, limit: 1_000_000)) {
                for hit in descendants.hits {
                    let oldEntry = hit.entry
                    let newLocation = oldEntry.location.replacingPrefix(from, with: to.location) ?? oldEntry.location
                    var newIdentity = oldEntry.identity
                    newIdentity.location = newLocation
                    let newContainer = newLocation.parent ?? to.location
                    pairs.append((from: oldEntry.identity.cacheKey, to: newIdentity.cacheKey, container: newContainer))
                }
            }
        }
        return pairs
    }

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        guard let runtime else { return }
        let fraction = event.contains(.critical) ? 0.25 : 0.5
        runtime.caches.raw.trim(toFraction: fraction)
        runtime.caches.decoded.trim(toFraction: fraction)
        runtime.caches.thumbnailMemory.trim(toFraction: fraction)
        runtime.caches.preload.trim(toFraction: fraction)
        (pipeline as? FileImagePipeline)?.cancelBackgroundPrefetch()
    }

    private func updateBudgets() async {
        let global = await settings.global()
        do { try await library?.setHistoryLimit(global.historyLimit) }
        catch { Self.log.error("更新历史上限失败：\(error.localizedDescription)") }
        guard let runtime else { return }
        let budget = global.cache
        guard !Task.isCancelled else { return }
        (pipeline as? FileImagePipeline)?.setMaxDecodeLongSide(global.maxDecodeLongSide)
        runtime.caches.raw.setBudget(budget.rawBytes)
        runtime.caches.decoded.setBudget(budget.decodedBytes)
        runtime.caches.thumbnailMemory.setBudget(budget.thumbnailMemoryBytes)
        runtime.caches.preload.setBudget(budget.preloadBytes)
        do {
            try await runtime.caches.thumbnails.setBudget(budget.thumbnailBytes)
            guard !Task.isCancelled else { return }
            try await runtime.caches.browse?.setBudget(budget.browseBytes)
        } catch { Self.log.error("更新磁盘缓存预算失败：\(error.localizedDescription)") }
    }

    /// 留出调度余量；超时后取消剩余落盘步骤，并立即弃用辅助进程。
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let timeoutAt = DispatchTime.now() + .milliseconds(900)
        pressureSource?.cancel()
        settingsTask?.cancel()
        fileChangesTask?.cancel()
        libraryTask?.cancel()
        recoveryTask?.cancel()
        let continuations = fileChangeObservers.withLock {
            let values = Array($0.values)
            $0.removeAll()
            return values
        }
        continuations.forEach { $0.finish() }
        let sessions = sessions.compactMap(\.value)
        let runtime = runtime
        let pipeline = pipeline
        let library = library as? SQLiteLibraryStore
        let historyTasks = Array(historyTasks.values)
        let task = Task {
            await withCheckedContinuation { continuation in
                let completion = ShutdownCompletion(continuation)
                let work = Task {
                    for task in historyTasks {
                        guard !Task.isCancelled else { return }
                        await task.value
                    }
                    for session in sessions {
                        guard !Task.isCancelled else { return }
                        await session.flush()
                        guard !Task.isCancelled else { return }
                        pipeline.cancelAll(session: session.id)
                    }
                    guard !Task.isCancelled else { return }
                    await (pipeline as? FileImagePipeline)?.shutdown()
                    if let runtime {
                        guard !Task.isCancelled else { return }
                        do { try await runtime.settings.flush() }
                        catch { Self.log.error("书记忆落盘失败：\(error.localizedDescription)") }
                        guard !Task.isCancelled else { return }
                        do { try await library?.flush() }
                        catch { Self.log.error("资料库落盘失败：\(error.localizedDescription)") }
                        guard !Task.isCancelled else { return }
                        do { try await runtime.index.flush() }
                        catch { Self.log.error("缓存访问时间落盘失败：\(error.localizedDescription)") }
                        guard !Task.isCancelled else { return }
                        runtime.scheduler.shutdown()
                    }
                    completion.finish()
                }
                // 从 shutdown 入口计时；任务晚获调度不能把一秒总期限向后推。
                let deadline = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInteractive))
                deadline.schedule(deadline: timeoutAt, leeway: .nanoseconds(0))
                deadline.setEventHandler { @Sendable in
                    work.cancel()
                    historyTasks.forEach { $0.cancel() }
                    (pipeline as? FileImagePipeline)?.beginShutdown()
                    runtime?.scheduler.shutdown()
                    completion.finish()
                }
                deadline.resume()
                Task { await work.value; deadline.cancel() }
            }
        }
        shutdownTask = task
        await task.value
    }
}

/// 保持普通书与虚拟书共用同一会话入口。
public struct LibraryBookLoader: BookLoader {
    private let files: any BookLoader
    private let playlists: any BookLoader
    public init(files: any BookLoader, playlists: any BookLoader) { self.files = files; self.playlists = playlists }
    public func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> {
        (location.playlistID == nil ? files : playlists).load(location, settings: settings, startingAt: page)
    }
}

private final class ShutdownCompletion: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = Mutex(continuation) }
    func finish() { continuation.withLock { $0.take() }?.resume() }
}
