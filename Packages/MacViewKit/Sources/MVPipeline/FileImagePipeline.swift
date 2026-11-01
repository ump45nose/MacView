import AVFoundation
import Foundation
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
        var coverage: PixelSize
        var derivatives: Task<Void, any Error>
    }
    private struct PrefetchKey: Hashable, Sendable {
        var identity: ContentIdentity
        var renditions: Set<RenditionSpec>
    }
    private struct Prefetch: Sendable {
        var item: PrefetchItem
        var context: RequestContext
        var task: Task<Void, Never>
    }
    private struct State: Sendable {
        var content: [String: (UUID, ContentWork)] = [:]
        var renders: [String: (UUID, SharedWork<RenderedImage>)] = [:]
        var bundles: [String: (UUID, SharedWork<Bundle>)] = [:]
        var bundleBounds: [String: PixelSize] = [:]
        var sourceDecodes = 0
        var sessions: [SessionID: [PrefetchKey: Prefetch]] = [:]
    }
    private let sources: any SourceRegistry
    private let decoder: ImageDecoder
    private let caches: PipelineCaches
    private let configuration: PipelineConfiguration
    private let scheduler: IOScheduler?
    private let state = Mutex(State())

    public init(sources: any SourceRegistry, decoder: ImageDecoder, caches: PipelineCaches, configuration: PipelineConfiguration) {
        self.sources = sources
        self.decoder = decoder
        self.caches = caches
        self.configuration = configuration
        scheduler = (sources as? FileSourceRegistry)?.scheduler
    }

    public func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata {
        try await metadata(identity, context: RequestContext(priority))
    }

    private func metadata(_ identity: ContentIdentity, context: RequestContext) async throws -> ImageMetadata {
        if let value = try await caches.metadata.values(for: [identity.cacheKey])[identity.cacheKey] { return value }
        if EntryKind(fileName: identity.location.name) == .video {
            return try await withVideo(identity, priority: context.priority) { asset, actual in
                let value = try await MediaProbe.video(asset)
                if let parent = actual.location.parent { try await self.caches.metadata.store([actual.cacheKey: value], in: parent) }
                return value
            }
        }
        let result = try await content(identity, full: false, metadata: true, context: context)
        return result.metadata!
    }

    public func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage {
        try await thumbnail(identity, maxPixel: maxPixel, context: RequestContext(priority))
    }

    private func thumbnail(_ identity: ContentIdentity, maxPixel: Int, context: RequestContext) async throws -> RenderedImage {
        if EntryKind(fileName: identity.location.name) == .video { return try await videoPoster(for: identity, maxPixel: maxPixel) }
        let key = identity.cacheKey + "|thumb|\(maxPixel)"
        return try await render(key, context: context) { [self] context in
            if let data = try await caches.thumbnails.data(for: identity.cacheKey) {
                let size = try Self.probe(data).pixelSize.fitting(longSide: maxPixel)
                let image = try await decoder.image(data, target: DisplayTarget(pixelSize: size))
                caches.decoded.insert(image, for: key, cost: Self.cost(image))
                return image
            }
            let loaded = try await bundle(identity, target: nil, context: context)
            try await loaded.derivatives.value
            let size = PixelSize(width: loaded.base.image.width, height: loaded.base.image.height).fitting(longSide: maxPixel)
            let image = try await Self.resize(loaded.base, target: DisplayTarget(pixelSize: size), quality: .exact, priority: context.priority)
            caches.decoded.insert(image, for: loaded.identity.cacheKey + "|thumb|\(maxPixel)", cost: Self.cost(image))
            return image
        }
    }

    public func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> {
        AsyncStream { continuation in
            let task = Task(priority: priority.taskPriority) {
                let memory = Dictionary(identities.compactMap { identity -> (String, RenderedImage)? in
                    let key = identity.cacheKey + "|thumb|\(maxPixel)"
                    return self.caches.decoded.value(for: key).map { (identity.cacheKey, $0) }
                }, uniquingKeysWith: { first, _ in first })
                // 一个批次只查一次 L2 索引；L1 命中的项不再读磁盘。
                let disk: [String: Data]
                do { disk = try await caches.thumbnails.data(for: identities.filter { memory[$0.cacheKey] == nil }.map(\.cacheKey)) }
                catch {
                    // 单个缓存文件读取失败时，下面逐项重试并分别交付该项的错误。
                    disk = [:]
                }
                await withTaskGroup(of: Void.self) { group in
                    for identity in identities {
                        group.addTask(priority: priority.taskPriority) {
                            guard !Task.isCancelled else { return }
                            do {
                                let image: RenderedImage
                                let key = identity.cacheKey + "|thumb|\(maxPixel)"
                                if let cached = memory[identity.cacheKey] { image = cached }
                                else if let data = disk[identity.cacheKey] {
                                    image = try await self.render(key, context: RequestContext(priority)) { _ in
                                        let size = try Self.probe(data).pixelSize.fitting(longSide: maxPixel)
                                        let image = try await self.decoder.image(data, target: DisplayTarget(pixelSize: size))
                                        self.caches.decoded.insert(image, for: key, cost: Self.cost(image))
                                        return image
                                    }
                                } else { image = try await self.thumbnail(for: identity, maxPixel: maxPixel, priority: priority) }
                                if !Task.isCancelled { continuation.yield((identity, .success(image))) }
                            } catch {
                                if !Task.isCancelled { continuation.yield((identity, .failure(error))) }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: priority.taskPriority) {
                let context = RequestContext(priority)
                do {
                    let exactKey = Self.key(identity, target)
                    if let exact = caches.decoded.value(for: exactKey), exact.quality >= .exact {
                        continuation.yield(exact)
                        continuation.finish()
                        return
                    }
                    var delivered: RenditionQuality?
                    // 优先检查高质量阶段，有浏览图时不再放大缩略图。
                    let browseData = try await caches.browse?.data(for: identity.cacheKey)
                    if let browseData {
                        let size = try Self.probe(browseData).pixelSize
                        if Self.contains(size, target.pixelSize) {
                            let exact = try await render(exactKey, context: context) { [self] _ in
                                let image = try await decoder.image(browseData, target: target)
                                caches.decoded.insert(image, for: exactKey, cost: Self.cost(image))
                                return image
                            }
                            continuation.yield(exact)
                            continuation.finish()
                            return
                        }
                        continuation.yield(try await decoder.image(browseData, target: target, quality: .browse))
                        delivered = .browse
                    } else if let thumbnail = try await caches.thumbnails.data(for: identity.cacheKey) {
                        let size = try Self.probe(thumbnail).pixelSize
                        if Self.contains(size, target.pixelSize) {
                            let exact = try await render(exactKey, context: context) { [self] _ in
                                let image = try await decoder.image(thumbnail, target: target)
                                caches.decoded.insert(image, for: exactKey, cost: Self.cost(image))
                                return image
                            }
                            continuation.yield(exact)
                            continuation.finish()
                            return
                        }
                        continuation.yield(try await decoder.image(thumbnail, target: target, quality: .placeholder))
                        delivered = .placeholder
                        // L3 可以在缩略图显示期间由另一个消费者生成。
                        if let browse = try await caches.browse?.data(for: identity.cacheKey) {
                            continuation.yield(try await decoder.image(browse, target: target, quality: .browse))
                            delivered = .browse
                        }
                    }
                    try Task.checkCancellation()
                    let loaded = try await bundle(identity, target: target, context: context)
                    if delivered == .placeholder, let browseCache = caches.browse {
                        try await loaded.derivatives.value
                        if let browse = try await browseCache.data(for: loaded.identity.cacheKey) {
                            continuation.yield(try await decoder.image(browse, target: target, quality: .browse))
                        }
                    }
                    let image = try await exact(identity, target: target, allowOriginal: allowOriginal, context: context, loaded: loaded)
                    try Task.checkCancellation()
                    continuation.yield(image)
                    try await loaded.derivatives.value
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
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
            let result = try await Self.resize(loaded.base, target: actualTarget, quality: original ? .original : .exact, priority: context.priority)
            caches.decoded.insert(result, for: Self.key(loaded.identity, actualTarget), cost: Self.cost(result))
            return result
        }
    }

    public func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource {
        let loaded = try await content(identity, full: true, metadata: false, context: RequestContext(.visible))
        return try decoder.tiledSource(loaded.data)
    }

    public func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource {
        let loaded = try await content(identity, full: true, metadata: false, context: RequestContext(.visible))
        return try decoder.animatedFrames(loaded.data, target: target)
    }

    public func videoPoster(for identity: ContentIdentity, maxPixel: Int) async throws -> RenderedImage {
        let key = identity.cacheKey + "|video|\(maxPixel)"
        return try await render(key, context: RequestContext(.near)) { [self] _ in
            if let data = try await caches.thumbnails.data(for: identity.cacheKey) {
                let size = try Self.probe(data).pixelSize.fitting(longSide: maxPixel)
                return try await decoder.image(data, target: DisplayTarget(pixelSize: size))
            }
            return try await withVideo(identity, priority: .near) { asset, actual in
                let image = try await self.decoder.videoPoster(asset, maxPixel: max(self.configuration.thumbnailLongSide, maxPixel))
                let data = try await Task.detached(priority: .utility) { try RenditionEncoding.default.encode(image.image) }.value
                try await self.caches.thumbnails.store(data, for: actual.cacheKey)
                return try await Self.resize(image, target: DisplayTarget(pixelSize: PixelSize(width: image.image.width, height: image.image.height).fitting(longSide: maxPixel)), quality: .exact, priority: .near)
            }
        }
    }

    private func withVideo<Value: Sendable>(_ identity: ContentIdentity, priority: IOPriority, operation: (AVAsset, ContentIdentity) async throws -> Value) async throws -> Value {
        let provider = try sources.provider(for: identity.location)
        if case .network = identity.location.root, identity.location.layers.count == 1 {
            let source = try await provider.open(identity.location)
            let bridge = ByteSourceAsset(source: source, priority: priority)
            let result = try await operation(bridge.asset, source.identity)
            withExtendedLifetime(bridge) {}
            return result
        }
        let source = try await provider.open(identity.location)
        let url = try await provider.fileURL(for: identity.location)
        return try await operation(AVURLAsset(url: url), source.identity)
    }

    private func content(_ identity: ContentIdentity, full: Bool, metadata: Bool, context: RequestContext) async throws -> PipelineContent {
        if let data = caches.raw.value(for: identity.cacheKey), Int64(data.count) == identity.size {
            var value: ImageMetadata?
            if metadata {
                value = try await caches.metadata.values(for: [identity.cacheKey])[identity.cacheKey]
                if value == nil {
                    value = try Self.probe(data)
                    if let parent = identity.location.parent { try await caches.metadata.store([identity.cacheKey: value!], in: parent) }
                }
            }
            return PipelineContent(identity: identity, data: data, metadata: value)
        }
        let key = identity.cacheKey
        let work = state.withLock { state in
            if let work = state.content[key] { return work.1 }
            let id = UUID()
            let work = ContentWork(identity: identity, sources: sources, caches: caches) { [weak self] in
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
        let key = identity.cacheKey
        var requestedBounds = caches.browse == nil ? PixelSize(width: configuration.thumbnailLongSide, height: configuration.thumbnailLongSide) : configuration.browseBounds
        requestedBounds.width = max(requestedBounds.width, configuration.thumbnailLongSide, target?.pixelSize.width ?? 0)
        requestedBounds.height = max(requestedBounds.height, configuration.thumbnailLongSide, target?.pixelSize.height ?? 0)
        let pair = state.withLock { state -> (UUID, SharedWork<Bundle>) in
            var bounds = state.bundleBounds[key] ?? requestedBounds
            bounds.width = max(bounds.width, requestedBounds.width)
            bounds.height = max(bounds.height, requestedBounds.height)
            state.bundleBounds[key] = bounds
            if let pair = state.bundles[key], pair.1.isAccepting { return pair }
            let pair = (UUID(), SharedWork<Bundle>(scheduler: scheduler))
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
            if ImageDecoder.needsTiling(requiredSize, maxDecodeLongSide: configuration.maxDecodeLongSide) { throw MediaError.requiresTiling(size) }
            // 保留 ImageDecoder 的 DCT 缩小级别，目标滤镜和锐化只在各自最终缩放时应用。
            let ratio = min(Double(size.width) / Double(requiredSize.width), Double(size.height) / Double(requiredSize.height))
            var factor = 1
            while factor < 8, Double(factor * 2) * 0.9 <= ratio { factor *= 2 }
            let decodeSize = PixelSize(width: (size.width + factor - 1) / factor, height: (size.height + factor - 1) / factor)
            let baseKey = Self.key(loaded.identity, DisplayTarget(pixelSize: decodeSize))
            let base: RenderedImage
            if let cached = caches.decoded.value(for: baseKey) { base = cached }
            else {
                state.withLock { $0.sourceDecodes += 1 }
                base = try await decoder.image(loaded.data, target: DisplayTarget(pixelSize: decodeSize))
                caches.decoded.insert(base, for: baseKey, cost: Self.cost(base))
            }
            let derivatives = Task(priority: work.priority.taskPriority) { [self] in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let thumbnailTarget = DisplayTarget(pixelSize: size.fitting(longSide: self.configuration.thumbnailLongSide))
                        let thumbnail = try await Self.resize(base, target: thumbnailTarget, quality: .exact, priority: work.priority)
                        let data = try await Task.detached(priority: work.priority.taskPriority) { try RenditionEncoding.default.encode(thumbnail.image) }.value
                        try await self.caches.thumbnails.store(data, for: loaded.identity.cacheKey)
                    }
                    if let browse = caches.browse {
                        group.addTask {
                            let image = try await Self.resize(base, target: DisplayTarget(pixelSize: size.fitting(within: self.configuration.browseBounds)), quality: .browse, priority: work.priority)
                            let data = try await Task.detached(priority: work.priority.taskPriority) { try RenditionEncoding.default.encode(image.image) }.value
                            try await browse.store(data, for: loaded.identity.cacheKey)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            return Bundle(identity: loaded.identity, base: base, originalSize: size, coverage: requiredSize, derivatives: derivatives)
        }
        if let target {
            let required = value.originalSize.fitting(within: target.pixelSize)
            let available = value.coverage
            // 解码已经开始后才提出更大的尺寸时，下一轮使用 L0；不重复文件读取。
            if !Self.contains(available, required) { return try await bundle(value.identity, target: target, context: context) }
        }
        return value
    }

    var sourceDecodeCount: Int { state.withLock { $0.sourceDecodes } }

    private func render(_ key: String, context: RequestContext, operation: @escaping @Sendable (RequestContext) async throws -> RenderedImage) async throws -> RenderedImage {
        if let image = caches.decoded.value(for: key) { return image }
        let pair = state.withLock { state -> (UUID, SharedWork<RenderedImage>) in
            if let pair = state.renders[key], pair.1.isAccepting { return pair }
            let pair = (UUID(), SharedWork<RenderedImage>(scheduler: scheduler))
            state.renders[key] = pair
            return pair
        }
        let binding = context.bind { pair.1.setPriority($0, consumer: context.id) }
        defer { context.unbind(binding) }
        return try await pair.1.value(consumer: context.id, priority: context.priority) { [self] work in
            defer { state.withLock { if $0.renders[key]?.0 == pair.0 { $0.renders[key] = nil } } }
            let image = try await operation(work.context)
            return image
        }
    }

    public func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) {
        state.withLock { state in
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
                    current[key] = old
                } else {
                    let context = RequestContext(item.priority)
                    let task = Task(priority: item.priority.taskPriority) { [self] in
                        do { try await prefetch(item, context: context) }
                        catch { /* 预取没有交付通道；下次前台请求从真实边界重新报错。 */ }
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

    private func prefetch(_ item: PrefetchItem, context: RequestContext) async throws {
        if item.renditions.isEmpty {
            _ = try await content(item.identity, full: true, metadata: false, context: context)
            return
        }
        for rendition in item.renditions {
            try Task.checkCancellation()
            switch rendition {
            case .metadata: _ = try await metadata(item.identity, context: context)
            case .thumbnail: _ = try await thumbnail(item.identity, maxPixel: configuration.thumbnailLongSide, context: context)
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
    private static func probe(_ data: Data) throws -> ImageMetadata {
        guard case let .metadata(metadata) = try MediaProbe.image(data, isComplete: true) else { preconditionFailure("完整渲染件必须含有尺寸") }
        return metadata
    }
    private static func resize(_ image: RenderedImage, target: DisplayTarget, quality: RenditionQuality, priority: IOPriority) async throws -> RenderedImage {
        if image.image.width == target.pixelSize.width, image.image.height == target.pixelSize.height {
            return RenderedImage(image: image.image, quality: quality, surface: image.surface)
        }
        return try await Task.detached(priority: priority.taskPriority) {
            try Bitmap.resampled(image.image, to: target.pixelSize, filter: target.filter, sharpen: target.sharpen, quality: quality)
        }.value
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
