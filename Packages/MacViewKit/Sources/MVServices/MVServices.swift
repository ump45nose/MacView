// MVServices：真实服务的组合根；命令处理器由 App 按窗口登记。
import Foundation
import MVArchive
import MVCache
import MVCommands
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVReading
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
    public let keyBindings: JSONDocumentStore<KeyBindingsFile>?
    private let loader: any BookLoader
    let runtime: Runtime?
    private var sessions: [WeakSession] = []
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var settingsTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
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
        commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader
    ) {
        self.init(sources: sources, pipeline: pipeline, settings: settings, commands: commands,
                  bookshelf: bookshelf, loader: loader, keyBindings: nil, runtime: nil)
    }

    private init(
        sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore,
        commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader,
        keyBindings: JSONDocumentStore<KeyBindingsFile>?, runtime: Runtime?
    ) {
        self.sources = sources
        self.pipeline = pipeline
        self.settings = settings
        self.commands = commands
        self.bookshelf = bookshelf
        self.loader = loader
        self.keyBindings = keyBindings
        self.runtime = runtime
    }

    public static func make(configuration: CoreConfiguration) async throws -> CoreServices {
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
            metadata: MetadataIndex(index: index))
        let directories = DirectoryCache(index: index)
        let pipeline = FileImagePipeline(sources: sources, decoder: ImageDecoder(), caches: caches,
                                         configuration: PipelineConfiguration(browseBounds: configuration.browseBounds, maxDecodeLongSide: global.maxDecodeLongSide))
        let keyBindings = try JSONDocumentStore(fileURL: configuration.supportDirectory.appending(path: "keybindings.json"),
                                               version: 1, defaultValue: KeyBindingsFile())
        let services = CoreServices(sources: sources, pipeline: pipeline, settings: settings, commands: CommandRegistry(),
                                    bookshelf: FileBookshelf(sources: sources, directories: directories),
                                    loader: FileBookLoader(sources: sources, directories: directories, metadata: caches.metadata, pipeline: pipeline),
                                    keyBindings: keyBindings, runtime: Runtime(scheduler: scheduler, settings: settings, index: index, caches: caches))
        services.subscribe()
        return services
    }

    deinit {
        pressureSource?.cancel()
        settingsTask?.cancel()
    }

    public func makeSession() -> ReaderSession {
        let session = ReaderSession(loader: loader, settings: settings, bookshelf: bookshelf, pipeline: pipeline)
        sessions.removeAll { $0.value == nil }
        sessions.append(WeakSession(value: session))
        return session
    }

    private func subscribe() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            Task { @MainActor [weak self] in self?.handleMemoryPressure(event) }
        }
        pressureSource = source
        source.resume()
        let changes = settings.changes()
        settingsTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                if change == .global { await self?.updateBudgets() }
            }
        }
    }

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        guard let runtime else { return }
        let fraction = event.contains(.critical) ? 0.25 : 0.5
        runtime.caches.raw.trim(toFraction: fraction)
        runtime.caches.decoded.trim(toFraction: fraction)
        (pipeline as? FileImagePipeline)?.cancelBackgroundPrefetch()
    }

    private func updateBudgets() async {
        guard let runtime else { return }
        let global = await settings.global()
        let budget = global.cache
        guard !Task.isCancelled else { return }
        (pipeline as? FileImagePipeline)?.setMaxDecodeLongSide(global.maxDecodeLongSide)
        runtime.caches.raw.setBudget(budget.rawBytes)
        runtime.caches.decoded.setBudget(budget.decodedBytes)
        do {
            try await runtime.caches.thumbnails.setBudget(budget.thumbnailBytes)
            guard !Task.isCancelled else { return }
            try await runtime.caches.browse?.setBudget(budget.browseBytes)
        } catch { Self.log.error("更新磁盘缓存预算失败：\(error.localizedDescription)") }
    }

    /// 留出调度余量；超时后取消剩余落盘步骤，并立即弃用辅助进程。
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        pressureSource?.cancel()
        settingsTask?.cancel()
        let sessions = sessions.compactMap(\.value)
        let runtime = runtime
        let pipeline = pipeline
        let task = Task {
            await withCheckedContinuation { continuation in
                let completion = ShutdownCompletion(continuation)
                let work = Task {
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
                        do { try await runtime.index.flush() }
                        catch { Self.log.error("缓存访问时间落盘失败：\(error.localizedDescription)") }
                        guard !Task.isCancelled else { return }
                        runtime.scheduler.shutdown()
                    }
                    completion.finish()
                }
                let deadline = Task.detached {
                    do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                    work.cancel()
                    (pipeline as? FileImagePipeline)?.beginShutdown()
                    runtime?.scheduler.shutdown()
                    completion.finish()
                }
                Task { await work.value; deadline.cancel() }
            }
        }
        shutdownTask = task
        await task.value
    }
}

private final class ShutdownCompletion: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = Mutex(continuation) }
    func finish() { continuation.withLock { $0.take() }?.resume() }
}
