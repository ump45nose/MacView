import AVFoundation
import Foundation
import IOSurface
import MVCache
import MVFoundation
import MVIO
import MVMedia
import Synchronization

/// 文件、归档和网络来源共用的图像管线。
public final class FileImagePipeline: ImagePipeline {
    private struct Bundle: Sendable {
        var identity: ContentIdentity
        var base: RenderedImage
        var originalSize: PixelSize
        var derivatives: Task<Void, any Error>
    }
    private struct PrefetchKey: Hashable, Sendable {
        var identity: ContentIdentity
        var renditions: Set<RenditionSpec>
    }
    private struct Prefetch: Sendable {
        var item: PrefetchItem
        var context: RequestContext
        var task: Task<Void, any Error>
    }
    private struct ManagedBytes: ByteSource {
        var source: any ByteSource
        var lifetime: PipelineLifetime
        var identity: ContentIdentity { source.identity }
        func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
            try await lifetime.value { try await source.read(range, priority: priority, group: group) }
        }
    }
    private struct ManagedTiles: TiledImageSource {
        var source: any TiledImageSource
        var lifetime: PipelineLifetime
        var pixelSize: PixelSize { source.pixelSize }
        func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage {
            try await lifetime.value { try await source.tile(rect, scale: scale) }
        }
    }
    private struct ManagedFrames: AnimatedFrameSource {
        var source: any AnimatedFrameSource
        var lifetime: PipelineLifetime
        var frameCount: Int { source.frameCount }
        var loopCount: Int { source.loopCount }
        func duration(at index: Int) -> Double { source.duration(at: index) }
        func frame(at index: Int) async throws -> RenderedImage {
            try await lifetime.value { try await source.frame(at: index) }
        }
    }
    private struct State: Sendable {
        var content: [String: (UUID, ContentWork)] = [:]
        var renders: [String: (UUID, SharedWork<RenderedImage>)] = [:]
        var bundles: [String: (UUID, SharedWork<Bundle>)] = [:]
        var bundleBounds: [String: PixelSize] = [:]
        var sourceDecodes = 0
        var deferredDerivatives: Set<String> = []
        var repairingDerivatives: Set<String> = []
        var sessions: [SessionID: [PrefetchKey: Prefetch]] = [:]
    }
    private let sources: any SourceRegistry
    private let decoder: ImageDecoder
    private let caches: PipelineCaches
    private let configuration: PipelineConfiguration
    private let maxDecode: Mutex<Int>
    private let scheduler: IOScheduler?
    private let state = Mutex(State())
    /// 各会话尚未结束的预取任务数，和 `state.sessions` 里的任务分开记，避免在持有 `state` 时等待任务收尾。
    private let prefetchInFlight = Mutex<[SessionID: Int]>([:])
    private let lifetime = PipelineLifetime()
    let inFlight = InFlightBudget()

    public init(sources: any SourceRegistry, decoder: ImageDecoder, caches: PipelineCaches, configuration: PipelineConfiguration) {
        self.sources = sources
        self.decoder = decoder
        self.caches = caches
        self.configuration = configuration
        maxDecode = Mutex(configuration.maxDecodeLongSide)
        scheduler = (sources as? FileSourceRegistry)?.scheduler
    }

    /// 解码上限，设置改变时热生效。
    public var maxDecodeLongSide: Int { maxDecode.withLock { $0 } }
    public func setMaxDecodeLongSide(_ value: Int) { maxDecode.withLock { $0 = value } }
    public var thumbnailMemoryBudget: Int64 { caches.thumbnailMemory.budget }
    public var memory: PipelineMemorySnapshot {
        let pending = inFlight.snapshot
        return PipelineMemorySnapshot(rawBytes: caches.raw.totalCost, decodedBytes: caches.decoded.totalCost,
                                      thumbnailMemoryBytes: caches.thumbnailMemory.totalCost, preloadBytes: caches.preload.totalCost,
                                      inFlightBytes: pending.bytes, waitingTasks: pending.waiting)
    }

    public func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata {
        try await lifetime.value(priority: priority.taskPriority) { [self] in
            try await metadata(identity, context: RequestContext(priority))
        }
    }

    private func metadata(_ identity: ContentIdentity, context: RequestContext) async throws -> ImageMetadata {
        if let value = try await lifetime.value(operation: { [self] in try await caches.metadata.values(for: [identity.cacheKey])[identity.cacheKey] }) { return value }
        if EntryKind(fileName: identity.location.name) == .video {
            return try await withVideo(identity, priority: context.priority) { asset, actual in
                let value = try await MediaProbe.video(asset)
                if let parent = actual.location.parent {
                    try await self.lifetime.value { try await self.caches.metadata.store([actual.cacheKey: value], in: parent) }
                }
                return value
            }
        }
        let result = try await content(identity, full: false, metadata: true, context: context)
        return result.metadata!
    }

    public func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage {
        try await lifetime.value(priority: priority.taskPriority) { [self] in
            try await thumbnail(identity, maxPixel: maxPixel, context: RequestContext(priority))
        }
    }

    private func thumbnail(_ identity: ContentIdentity, maxPixel: Int, context: RequestContext) async throws -> RenderedImage {
        if EntryKind(fileName: identity.location.name) == .video { return try await videoPoster(for: identity, maxPixel: maxPixel, priority: context.priority) }
        try retryDerivatives(identity, target: nil, context: context)
        let key = identity.cacheKey + "|thumb|\(maxPixel)"
        return try await render(key, context: context, thumbnail: true) { [self] context in
            if let data = try await diskData(caches.thumbnails, for: identity.cacheKey) {
                let size = try self.probe(data).pixelSize.fitting(longSide: maxPixel)
                let image = try await decode(data, target: DisplayTarget(pixelSize: size))
                try remember(image, for: key, priority: context.priority, thumbnail: true)
                return image
            }
            let loaded = try await bundle(identity, target: nil, context: context)
            // 衍生件已登记到 PipelineLifetime，后台完成写入；可见缩略图拿到基础图后即可返回。
            return try await thumbnail(loaded, maxPixel: maxPixel, priority: context.priority)
        }
    }

    private func thumbnail(_ loaded: Bundle, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage {
        let size = PixelSize(width: loaded.base.image.width, height: loaded.base.image.height).fitting(longSide: maxPixel)
        let image = try await resize(loaded.base, target: DisplayTarget(pixelSize: size), quality: .exact, priority: priority)
        try remember(image, for: loaded.identity.cacheKey + "|thumb|\(maxPixel)", priority: priority, thumbnail: true)
        return image
    }

    public func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> {
        AsyncStream { continuation in
            let task: Task<Void, any Error>
            do {
                task = try lifetime.start(priority: priority.taskPriority) { [self] in
                    do {
                        try lifetime.checkRunning()
                        let memory = Dictionary(identities.compactMap { identity -> (String, RenderedImage)? in
                            let key = identity.cacheKey + "|thumb|\(maxPixel)"
                            return self.caches.thumbnailMemory.value(for: key).map { (identity.cacheKey, $0) }
                        }, uniquingKeysWith: { first, _ in first })
                        // 一个批次只查一次 L2 索引；L1 命中的项不再读磁盘。
                        let disk: [String: Data]
                        do {
                            disk = try await lifetime.value { [self] in
                                try await caches.thumbnails.data(for: identities.filter { memory[$0.cacheKey] == nil }.map(\.cacheKey))
                            }
                        } catch {
                            try lifetime.checkRunning()
                            // 单个缓存文件读取失败时，下面逐项重试并分别交付该项的错误。
                            disk = [:]
                        }
                        await withTaskGroup(of: Void.self) { group in
                            for identity in identities {
                                group.addTask(priority: priority.taskPriority) {
                                    do {
                                        try self.lifetime.checkRunning()
                                        try self.retryDerivatives(identity, target: nil, context: RequestContext(priority))
                                        let image: RenderedImage
                                        let key = identity.cacheKey + "|thumb|\(maxPixel)"
                                        if let cached = memory[identity.cacheKey] { image = cached }
                                        else if let data = disk[identity.cacheKey] {
                                            image = try await self.render(key, context: RequestContext(priority), thumbnail: true) { _ in
                                                let size = try self.probe(data).pixelSize.fitting(longSide: maxPixel)
                                                let image = try await self.decode(data, target: DisplayTarget(pixelSize: size))
                                                try self.remember(image, for: key, priority: priority, thumbnail: true)
                                                return image
                                            }
                                        } else { image = try await self.thumbnail(for: identity, maxPixel: maxPixel, priority: priority) }
                                        try self.lifetime.checkRunning()
                                        continuation.yield((identity, .success(image)))
                                    } catch {
                                        if !Task.isCancelled { continuation.yield((identity, .failure(error))) }
                                    }
                                }
                            }
                        }
                    } catch {
                        if !Task.isCancelled {
                            for identity in identities { continuation.yield((identity, .failure(error))) }
                        }
                    }
                    continuation.finish()
                }
            } catch {
                for identity in identities { continuation.yield((identity, .failure(error))) }
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> {
        AsyncThrowingStream { continuation in
            let task: Task<Void, any Error>
            do {
                task = try lifetime.start(priority: priority.taskPriority) { [self] in
                    let context = RequestContext(priority)
                    do {
                        try lifetime.checkRunning()
                        try retryDerivatives(identity, target: target, context: context)
                        let exactKey = Self.key(identity, target)
                        if let exact = cached(exactKey, priority: context.priority), exact.quality >= .exact {
                            continuation.yield(exact)
                            continuation.finish()
                            return
                        }
                        var delivered: RenditionQuality?
                        // 优先检查高质量阶段，有浏览图时不再放大缩略图。
                        let browseData = try await diskData(caches.browse, for: identity.cacheKey)
                        if let browseData {
                            let size = try self.probe(browseData).pixelSize
                            if Self.contains(size, target.pixelSize) {
                                let exact = try await render(exactKey, context: context) { [self] context in
                                    let image = try await decode(browseData, target: target)
                                    try remember(image, for: exactKey, priority: context.priority)
                                    return image
                                }
                                continuation.yield(exact)
                                continuation.finish()
                                return
                            }
                            continuation.yield(try await decode(browseData, target: target, quality: .browse))
                            delivered = .browse
                        } else if let thumbnail = try await diskData(caches.thumbnails, for: identity.cacheKey) {
                            let size = try self.probe(thumbnail).pixelSize
                            if Self.contains(size, target.pixelSize) {
                                let exact = try await render(exactKey, context: context) { [self] context in
                                    let image = try await decode(thumbnail, target: target)
                                    try remember(image, for: exactKey, priority: context.priority)
                                    return image
                                }
                                continuation.yield(exact)
                                continuation.finish()
                                return
                            }
                            continuation.yield(try await decode(thumbnail, target: target, quality: .placeholder))
                            delivered = .placeholder
                            // L3 可以在缩略图显示期间由另一个消费者生成。
                            if let browse = try await diskData(caches.browse, for: identity.cacheKey) {
                                continuation.yield(try await decode(browse, target: target, quality: .browse))
                                delivered = .browse
                            }
                        }
                        try lifetime.checkRunning()
                        let loaded = try await bundle(identity, target: target, context: context)
                        if delivered == .placeholder, let browseCache = caches.browse {
                            try await loaded.derivatives.value
                            if let browse = try await diskData(browseCache, for: loaded.identity.cacheKey) {
                                continuation.yield(try await decode(browse, target: target, quality: .browse))
                            }
                        }
                        let image = try await exact(identity, target: target, allowOriginal: allowOriginal, context: context, loaded: loaded)
                        try lifetime.checkRunning()
                        continuation.yield(image)
                        try await loaded.derivatives.value
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            } catch { continuation.finish(throwing: error); return }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func exact(_ identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, context: RequestContext, loaded: Bundle? = nil) async throws -> RenderedImage {
        try await render(Self.key(identity, target) + (allowOriginal ? "|allowOriginal" : ""), context: context) { [self] context in
            let value: Bundle
            if let loaded { value = loaded }
            else { value = try await bundle(identity, target: target, context: context) }
            let loaded = value
            let sourceSize = loaded.originalSize
            let original = allowOriginal && Self.contains(target.pixelSize, sourceSize)
            let actualTarget = original ? DisplayTarget(pixelSize: sourceSize, filter: target.filter, sharpen: target.sharpen) : target
            let result = try await resize(loaded.base, target: actualTarget, quality: original ? .original : .exact, priority: context.priority)
            try remember(result, for: Self.key(loaded.identity, actualTarget), priority: context.priority)
            return result
        }
    }

    public func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource {
        try await lifetime.value { [self] in
            let loaded = try await content(identity, full: true, metadata: false, context: RequestContext(.visible))
            return try lifetime.whileRunning { try ManagedTiles(source: decoder.tiledSource(loaded.data), lifetime: lifetime) }
        }
    }

    public func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource {
        try await lifetime.value { [self] in
            let loaded = try await content(identity, full: true, metadata: false, context: RequestContext(.visible))
            return try lifetime.whileRunning { try ManagedFrames(source: decoder.animatedFrames(loaded.data, target: target), lifetime: lifetime) }
        }
    }

    public func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage {
        let key = identity.cacheKey + "|video|\(maxPixel)"
        return try await render(key, context: RequestContext(priority), thumbnail: true) { [self] _ in
            if let data = try await diskData(caches.thumbnails, for: identity.cacheKey) {
                let size = try self.probe(data).pixelSize.fitting(longSide: maxPixel)
                let image = try await decode(data, target: DisplayTarget(pixelSize: size))
                try remember(image, for: key, priority: priority, thumbnail: true)
                return image
            }
            return try await withVideo(identity, priority: priority) { asset, actual in
                let image = try await self.decoder.videoPoster(asset, maxPixel: max(self.configuration.thumbnailLongSide, maxPixel))
                let data = try await self.encode(image, priority: priority)
                try await self.store(data, in: self.caches.thumbnails, for: actual.cacheKey)
                let result = try await self.resize(image, target: DisplayTarget(pixelSize: PixelSize(width: image.image.width, height: image.image.height).fitting(longSide: maxPixel)), quality: .exact, priority: priority)
                try self.remember(result, for: actual.cacheKey + "|video|\(maxPixel)", priority: priority, thumbnail: true)
                return result
            }
        }
    }

    private func withVideo<Value: Sendable>(_ identity: ContentIdentity, priority: IOPriority, operation: (AVAsset, ContentIdentity) async throws -> Value) async throws -> Value {
        try lifetime.checkRunning()
        let provider = try sources.provider(for: identity.location)
        if case .network = identity.location.root, identity.location.layers.count == 1 {
            let source = try await lifetime.value { try await provider.open(identity.location) }
            let bridge = try lifetime.whileRunning {
                ByteSourceAsset(source: ManagedBytes(source: source, lifetime: lifetime), priority: priority)
            }
            try lifetime.checkRunning()
            let result = try await operation(bridge.asset, source.identity)
            withExtendedLifetime(bridge) {}
            return result
        }
        let source = try await lifetime.value { try await provider.open(identity.location) }
        let lease = try await lifetime.value { try await provider.fileLease(for: identity.location) }
        try lifetime.checkRunning()
        let result = try await operation(AVURLAsset(url: lease.url), source.identity)
        withExtendedLifetime(lease) {}
        return result
    }

    private func content(_ identity: ContentIdentity, full: Bool, metadata: Bool, context: RequestContext) async throws -> PipelineContent {
        try lifetime.checkRunning()
        if let data = caches.raw.value(for: identity.cacheKey), Int64(data.count) == identity.size {
            var value: ImageMetadata?
            if metadata {
                value = try await lifetime.value { [self] in try await caches.metadata.values(for: [identity.cacheKey])[identity.cacheKey] }
                if value == nil {
                    value = try self.probe(data)
                    if let parent = identity.location.parent {
                        let probed = value!
                        try await lifetime.value { [self] in try await caches.metadata.store([identity.cacheKey: probed], in: parent) }
                    }
                }
            }
            return PipelineContent(identity: identity, data: data, metadata: value)
        }
        let key = identity.cacheKey
        let work = try state.withLock { state in
            try lifetime.checkRunning()
            if let work = state.content[key] { return work.1 }
            let id = UUID()
            let work = ContentWork(identity: identity, sources: sources, caches: caches, lifetime: lifetime) { [weak self] in
                self?.state.withLock { state in if state.content[key]?.0 == id { state.content[key] = nil } }
            }
            state.content[key] = (id, work)
            return work
        }
        let binding = context.bind { priority in Task { await work.setPriority(priority, consumer: context.id) } }
        defer { context.unbind(binding) }
        return try await work.value(full: full, metadata: metadata, consumer: context.id, priority: context.priority)
    }

    private func bundle(_ identity: ContentIdentity, target: DisplayTarget?, context: RequestContext) async throws -> Bundle {
        try lifetime.checkRunning()
        let key = identity.cacheKey
        var requestedBounds = target?.pixelSize ?? PixelSize(width: 1, height: 1)
        if caches.browse == nil {
            requestedBounds.width = max(requestedBounds.width, configuration.thumbnailLongSide)
            requestedBounds.height = max(requestedBounds.height, configuration.thumbnailLongSide)
        }
        let pair = try state.withLock { state -> (UUID, SharedWork<Bundle>) in
            try lifetime.checkRunning()
            var bounds = state.bundleBounds[key] ?? requestedBounds
            bounds.width = max(bounds.width, requestedBounds.width)
            bounds.height = max(bounds.height, requestedBounds.height)
            state.bundleBounds[key] = bounds
            if let pair = state.bundles[key], pair.1.isAccepting { return pair }
            let pair = (UUID(), SharedWork<Bundle>(scheduler: scheduler, lifetime: lifetime))
            state.bundles[key] = pair
            return pair
        }
        let binding = context.bind { pair.1.setPriority($0, consumer: context.id) }
        defer { context.unbind(binding) }
        let value = try await pair.1.value(consumer: context.id, priority: context.priority) { [self] work in
            defer { state.withLock { state in
                if state.bundles[key]?.0 == pair.0 {
                    state.bundles[key] = nil
                    state.bundleBounds[key] = nil
                }
            } }
            let loaded = try await content(identity, full: true, metadata: true, context: work.context)
            let size = loaded.metadata!.pixelSize
            // 在原始读取完成后才确定解码尺寸；读取期间进入的不同渲染件合并到同一最大尺寸。
            let bounds = state.withLock { $0.bundleBounds[key]! }
            let requiredSize = size.fitting(within: bounds)
            let browseSize = size.fitting(within: caches.browse == nil ? bounds : configuration.browseBounds)
            let largest = PixelSize(width: max(requiredSize.width, browseSize.width), height: max(requiredSize.height, browseSize.height))
            if ImageDecoder.needsTiling(largest, maxDecodeLongSide: maxDecodeLongSide) { throw MediaError.requiresTiling(size) }
            // 浏览图允许小 20%，显示目标仍只允许小 10%；各算一级后取较细的一级。
            let displayRatio = min(Double(size.width) / Double(requiredSize.width), Double(size.height) / Double(requiredSize.height)) / 0.9
            let browseRatio = min(Double(size.width) / Double(browseSize.width), Double(size.height) / Double(browseSize.height)) / 0.8
            var factor = 1
            while factor < 8, Double(factor * 2) <= min(displayRatio, browseRatio) { factor *= 2 }
            let decodeSize = PixelSize(width: (size.width + factor - 1) / factor, height: (size.height + factor - 1) / factor)
            let baseKey = Self.key(loaded.identity, DisplayTarget(pixelSize: decodeSize))
            let bytes = Int64(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, decodeSize.width * 4) * decodeSize.height)
            let derivativesAllowed = try await inFlight.acquire(bytes, context: work.context)
            var ownsReservation = true
            defer { if ownsReservation { inFlight.release(bytes) } }
            try lifetime.checkRunning()
            let base: RenderedImage
            if let cached = cached(baseKey, priority: work.priority) { base = cached }
            else {
                state.withLock { $0.sourceDecodes += 1 }
                base = try await decode(loaded.data, target: DisplayTarget(pixelSize: decodeSize))
                try remember(base, for: baseKey, priority: work.priority)
            }
            if !derivativesAllowed {
                _ = state.withLock { $0.deferredDerivatives.insert(loaded.identity.cacheKey) }
                return Bundle(identity: loaded.identity, base: base, originalSize: size, derivatives: Task<Void, any Error> {})
            }
            _ = state.withLock { $0.deferredDerivatives.remove(loaded.identity.cacheKey) }
            // Bundle 交付后衍生件仍独立运行；在生命周期关口内登记，直到写入队列真正结束。
            let derivatives = try lifetime.start(priority: work.priority.taskPriority) { [self] in
                defer { inFlight.release(bytes) }
                try lifetime.checkRunning()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let thumbnailTarget = DisplayTarget(pixelSize: size.fitting(longSide: self.configuration.thumbnailLongSide))
                        let thumbnail = try await self.resize(base, target: thumbnailTarget, quality: .exact, priority: work.priority)
                        let data = try await self.encode(thumbnail, priority: work.priority)
                        try await self.store(data, in: self.caches.thumbnails, for: loaded.identity.cacheKey)
                    }
                    if let browse = caches.browse {
                        group.addTask {
                            let image = try await self.resize(base, target: DisplayTarget(pixelSize: size.fitting(within: self.configuration.browseBounds).fitting(within: decodeSize)), quality: .browse, priority: work.priority)
                            let data = try await self.encode(image, priority: work.priority)
                            try await self.store(data, in: browse, for: loaded.identity.cacheKey)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            ownsReservation = false
            return Bundle(identity: loaded.identity, base: base, originalSize: size, derivatives: derivatives)
        }
        if let target {
            let required = value.originalSize.fitting(within: target.pixelSize)
            // 迟到目标仍按显示图的 90% 要求检查实际像素；不够时下一轮使用 L0，不重复文件读取。
            if Double(value.base.image.width) < Double(required.width) * 0.9 || Double(value.base.image.height) < Double(required.height) * 0.9 {
                return try await bundle(value.identity, target: target, context: context)
            }
        }
        return value
    }

    var sourceDecodeCount: Int { state.withLock { $0.sourceDecodes } }

    private func render(_ key: String, context: RequestContext, thumbnail: Bool = false, operation: @escaping @Sendable (RequestContext) async throws -> RenderedImage) async throws -> RenderedImage {
        try lifetime.checkRunning()
        if let image = cached(key, priority: context.priority, thumbnail: thumbnail) { return image }
        let pair = try state.withLock { state -> (UUID, SharedWork<RenderedImage>) in
            try lifetime.checkRunning()
            if let pair = state.renders[key], pair.1.isAccepting { return pair }
            let pair = (UUID(), SharedWork<RenderedImage>(scheduler: scheduler, lifetime: lifetime))
            state.renders[key] = pair
            return pair
        }
        let binding = context.bind { pair.1.setPriority($0, consumer: context.id) }
        defer { context.unbind(binding) }
        let image = try await pair.1.value(consumer: context.id, priority: context.priority) { [self] work in
            defer { state.withLock { if $0.renders[key]?.0 == pair.0 { $0.renders[key] = nil } } }
            return try await operation(work.context)
        }
        if !thumbnail, context.priority == .visible { try remember(image, for: key, priority: .visible) }
        return image
    }

    /// 该会话还没结束的预取任务数。任务结束后归零，就算空闲。
    public func prefetchInFlightCount(session: SessionID) -> Int {
        prefetchInFlight.withLock { $0[session] ?? 0 }
    }

    public func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) {
        state.withLock { state in
            guard (try? lifetime.checkRunning()) != nil else { return }
            let desired = Dictionary(plan.items.map { (PrefetchKey(identity: $0.identity, renditions: $0.renditions), $0) }, uniquingKeysWith: { first, second in
                PrefetchItem(identity: first.identity, renditions: first.renditions, priority: max(first.priority, second.priority))
            })
            var current = state.sessions[session] ?? [:]
            for (key, old) in current where desired[key] == nil {
                old.task.cancel()
                current[key] = nil
            }
            for (key, item) in desired {
                if var old = current[key] {
                    old.item = item
                    old.context.setPriority(item.priority)
                    old.task.escalatePriority(to: item.priority.taskPriority)
                    current[key] = old
                } else {
                    let context = RequestContext(item.priority)
                    changePrefetchInFlight(session, by: 1)
                    guard let task = try? lifetime.start(priority: item.priority.taskPriority, operation: { [self] in
                        defer { self.changePrefetchInFlight(session, by: -1) }
                        do {
                            try lifetime.checkRunning()
                            try await prefetch(item, context: context)
                        }
                        catch { /* 预取没有交付通道；下次前台请求从真实边界重新报错。 */ }
                    }) else {
                        changePrefetchInFlight(session, by: -1)
                        continue
                    }
                    current[key] = Prefetch(item: item, context: context, task: task)
                }
            }
            state.sessions[session] = current
        }
    }

    public func cancelAll(session: SessionID) {
        let tasks = state.withLock { $0.sessions.removeValue(forKey: session)?.values.map(\.task) ?? [] }
        for task in tasks { task.cancel() }
    }

    /// 只移除后台预取；同一内容的前台与其他优先级消费者继续工作。
    public func cancelBackgroundPrefetch() {
        let tasks = state.withLock { state in
            var tasks: [Task<Void, any Error>] = []
            for session in state.sessions.keys {
                let background = state.sessions[session]!.filter { $0.value.item.priority == .background }
                for (key, prefetch) in background {
                    tasks.append(prefetch.task)
                    state.sessions[session]![key] = nil
                }
            }
            return tasks
        }
        for task in tasks { task.cancel() }
    }

    /// 停止接收新工作，取消包括独立衍生件在内的任务，并等待已准入的缓存写入排空。
    public func shutdown() async {
        await lifetime.shutdown()
        state.withLock {
            $0.sessions.removeAll()
            $0.content.removeAll()
            $0.renders.removeAll()
            $0.bundles.removeAll()
            $0.bundleBounds.removeAll()
            $0.deferredDerivatives.removeAll()
            $0.repairingDerivatives.removeAll()
        }
    }

    /// 组合根达到退出期限时先关闭准入，不等待仍被 I/O 占住的任务。
    package func beginShutdown() { lifetime.stop() }

    private func changePrefetchInFlight(_ session: SessionID, by delta: Int) {
        prefetchInFlight.withLock { counts in
            let next = (counts[session] ?? 0) + delta
            if next <= 0 { counts[session] = nil } else { counts[session] = next }
        }
    }

    private func prefetch(_ item: PrefetchItem, context: RequestContext) async throws {
        if item.renditions.isEmpty {
            _ = try await content(item.identity, full: true, metadata: false, context: context)
            return
        }
        for rendition in item.renditions {
            try lifetime.checkRunning()
            switch rendition {
            case .metadata: _ = try await metadata(item.identity, context: context)
            case .thumbnail:
                if try await diskData(caches.thumbnails, for: item.identity.cacheKey) != nil {
                    _ = try await thumbnail(item.identity, maxPixel: configuration.thumbnailLongSide, context: context)
                } else {
                    let loaded = try await bundle(item.identity, target: nil, context: context)
                    let key = item.identity.cacheKey + "|thumb|\(configuration.thumbnailLongSide)"
                    _ = try await render(key, context: context, thumbnail: true) { [self] context in
                        try await thumbnail(loaded, maxPixel: configuration.thumbnailLongSide, priority: context.priority)
                    }
                    // 预取完成仍表示衍生件已经写入，不能随可见缩略图的提前交付一起提早归零。
                    try await loaded.derivatives.value
                }
            case .browse:
                let loaded = try await bundle(item.identity, target: nil, context: context)
                try await loaded.derivatives.value
            case let .display(target): _ = try await exact(item.identity, target: target, allowOriginal: false, context: context)
            }
        }
    }

    private static func key(_ identity: ContentIdentity, _ target: DisplayTarget) -> String {
        identity.cacheKey + "|display|\(target.pixelSize.width)x\(target.pixelSize.height)|\(target.filter.rawValue)|\(target.sharpen.bitPattern)"
    }
    private static func cost(_ image: RenderedImage) -> Int64 { Int64(image.image.bytesPerRow * image.image.height) }
    private static func contains(_ size: PixelSize, _ other: PixelSize) -> Bool { size.width >= other.width && size.height >= other.height }
    private func probe(_ data: Data) throws -> ImageMetadata {
        try lifetime.whileRunning {
            guard case let .metadata(metadata) = try MediaProbe.image(data, isComplete: true) else { preconditionFailure("完整渲染件必须含有尺寸") }
            return metadata
        }
    }
    private func diskData(_ cache: DiskCache?, for key: String) async throws -> Data? {
        try await lifetime.value { try await cache?.data(for: key) }
    }
    private func decode(_ data: Data, target: DisplayTarget, quality: RenditionQuality = .exact) async throws -> RenderedImage {
        try await lifetime.value { [self] in try await decoder.image(data, target: target, quality: quality) }
    }
    private func cached(_ key: String, priority: IOPriority, thumbnail: Bool = false) -> RenderedImage? {
        if thumbnail { return caches.thumbnailMemory.value(for: key) }
        if let image = caches.decoded.value(for: key) { return image }
        guard let image = caches.preload.value(for: key) else { return nil }
        if priority == .visible {
            caches.preload.removeValue(for: key)
            caches.decoded.insert(image, for: key, cost: Self.cost(image))
        }
        return image
    }
    private func remember(_ image: RenderedImage, for key: String, priority: IOPriority, thumbnail: Bool = false) throws {
        try lifetime.whileRunning {
            if thumbnail { caches.thumbnailMemory.insert(image, for: key, cost: Self.cost(image)) }
            else if priority == .visible {
                caches.preload.removeValue(for: key)
                caches.decoded.insert(image, for: key, cost: Self.cost(image))
            } else if priority == .near { caches.preload.insert(image, for: key, cost: Self.cost(image)) }
        }
    }
    private func retryDerivatives(_ identity: ContentIdentity, target: DisplayTarget?, context: RequestContext) throws {
        let key = identity.cacheKey
        guard inFlight.snapshot.bytes < inFlight.limit, state.withLock({ state in
            state.deferredDerivatives.contains(key) && state.repairingDerivatives.insert(key).inserted
        }) else { return }
        do {
            _ = try lifetime.start(priority: context.priority.taskPriority) { [self] in
                defer { _ = state.withLock { $0.repairingDerivatives.remove(key) } }
                _ = try await bundle(identity, target: target, context: RequestContext(context.priority))
            }
        } catch {
            _ = state.withLock { $0.repairingDerivatives.remove(key) }
            throw error
        }
    }
    private func store(_ data: Data, in cache: DiskCache, for key: String) async throws {
        try await lifetime.value { try await cache.store(data, for: key) }
    }
    private func encode(_ image: RenderedImage, priority: IOPriority) async throws -> Data {
        try await lifetime.value(priority: priority.taskPriority) { [decoder] in
            try await decoder.perform { try RenditionEncoding.default.encode(image.image) }
        }
    }
    private func resize(_ image: RenderedImage, target: DisplayTarget, quality: RenditionQuality, priority: IOPriority) async throws -> RenderedImage {
        try await lifetime.value(priority: priority.taskPriority) { [decoder] in
            if image.image.width == target.pixelSize.width, image.image.height == target.pixelSize.height {
                return RenderedImage(image: image.image, quality: quality, surface: image.surface)
            }
            // 已入队的任务提升后仍留在原 QoS 的队列里；计算放进按优先级出队的限流器，前台不必排在后台积压之后。
            return try await decoder.perform {
                try Bitmap.resampled(image.image, to: target.pixelSize, filter: target.filter, sharpen: target.sharpen, quality: quality)
            }
        }
    }
}

/// 保留预取项变更优先级时，把变化传给当前共享读取和解码作业。
final class RequestContext: Sendable {
    let id = UUID()
    private struct State: Sendable {
        var priority: IOPriority
        var updates: [UUID: @Sendable (IOPriority) -> Void] = [:]
    }
    private let state: Mutex<State>
    init(_ priority: IOPriority) { state = Mutex(State(priority: priority)) }
    var priority: IOPriority { state.withLock { $0.priority } }
    func bind(_ update: @escaping @Sendable (IOPriority) -> Void) -> UUID {
        let id = UUID()
        let priority = state.withLock { $0.updates[id] = update; return $0.priority }
        update(priority)
        return id
    }
    func unbind(_ id: UUID) { state.withLock { $0.updates[id] = nil } }
    func setPriority(_ priority: IOPriority) {
        let updates = state.withLock { $0.priority = priority; return Array($0.updates.values) }
        for update in updates { update(priority) }
    }
}
