import AppKit
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVSettings
import os
import QuartzCore

/// 图块的图像来源：画廊面板用缩略图；主区瀑布流和连续模式用管线渐进交付的显示图，由管线选择来源。
enum CanvasImageSource: String, CaseIterable {
    case thumbnail
    case display
}

/// 一张可以直接设为图层内容的图。
final class CanvasImage {
    /// IOSurface（真实管线）或 CGImage（Mock 没有 IOSurface）。
    let contents: Any
    let quality: RenditionQuality
    let longSide: Int

    init(_ rendered: RenderedImage) {
        contents = rendered.surface ?? rendered.image
        quality = rendered.quality
        longSide = max(rendered.image.width, rendered.image.height)
    }
}

/// 画布的取图：后台向管线请求，结果缓存在内存，回到主线程后按每帧限额交给画布设置图层内容。
///
/// 请求按内容身份去重；项滚出余量时由画布取消。失败的项记下来，直到画布要求重试。
@MainActor
final class CanvasImageLoader: NSObject {
    enum State {
        case idle
        case loading(since: ContinuousClock.Instant)
        case loaded
        case failed
    }

    private struct Load {
        var id: UInt64
        var task: Task<Void, Never>
        var issuedAt: ContinuousClock.Instant
    }

    private(set) var pipeline: any ImagePipeline
    private(set) var source: CanvasImageSource
    /// 每帧最多设置的图层内容数，超出的排到下一帧。
    private static let contentsPerFrame = 8
    /// 有图可以显示时调用；返回是否真的设置了图层内容（项不在画布上时返回 false，不占限额）。
    var onReady: ((ContentIdentity, CanvasImage) -> Bool)?
    var onFailure: ((ContentIdentity) -> Void)?
    private(set) var loadedImages = 0

    private let cache = NSCache<IdentityKey, CanvasImage>()
    private var loads: [ContentIdentity: Load] = [:]
    private var failures: Set<ContentIdentity> = []
    private var pending: [(identity: ContentIdentity, image: CanvasImage)] = []
    private var link: CADisplayLink?
    private weak var view: NSView?
    private var nextID: UInt64 = 0
    private let signposter = OSSignposter(category: .layout)

    init(pipeline: any ImagePipeline, source: CanvasImageSource, view: NSView) {
        self.pipeline = pipeline
        self.source = source
        self.view = view
        super.init()
        updateCacheBudget()
    }

    var inFlight: Int {
        loads.count
    }

    func cached(_ identity: ContentIdentity) -> CanvasImage? {
        updateCacheBudget()
        return cache.object(forKey: IdentityKey(identity))
    }

    func state(of identity: ContentIdentity) -> State {
        if let load = loads[identity] { return .loading(since: load.issuedAt) }
        if failures.contains(identity) { return .failed }
        return cached(identity) == nil ? .idle : .loaded
    }

    /// 需要长边 `longSide` 像素的图。`target` 为 nil 时取缩略图，否则取渐进的显示图。
    /// 已有足够清晰的图、已在请求或已失败时不发请求。返回是否发出了请求。
    @discardableResult
    func request(_ identity: ContentIdentity, longSide: Int, target: PixelSize?, priority: IOPriority) -> Bool {
        guard loads[identity] == nil, !failures.contains(identity) else { return false }
        // 缓存的图比需要的小不到 20%，或显示图已过占位阶段时，就够用了。
        if let cached = cached(identity), cached.longSide * 5 >= longSide * 4, target == nil || cached.quality > .placeholder {
            return false
        }
        nextID += 1
        let id = nextID
        let pipeline = pipeline
        signposter.emitEvent("request", "\(priority == .visible ? "visible" : "near", privacy: .public)")
        // 管线调用放在主线程之外；取消会传进管线，排队中的请求直接出队。
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 视频没有显示图，用封面。
                if let target, EntryKind(fileName: identity.location.name) != .video {
                    for try await rendered in pipeline.image(for: identity, target: DisplayTarget(pixelSize: target), allowOriginal: false, priority: priority) {
                        await self?.receive(rendered, for: identity)
                    }
                } else {
                    let rendered = try await pipeline.thumbnail(for: identity, maxPixel: longSide, priority: priority)
                    await self?.receive(rendered, for: identity)
                }
                await self?.finish(identity, id: id, failed: false)
            } catch {
                await self?.finish(identity, id: id, failed: !(error is CancellationError) && !Task.isCancelled)
            }
        }
        loads[identity] = Load(id: id, task: task, issuedAt: .now)
        return true
    }

    func cancel(_ identity: ContentIdentity) {
        loads.removeValue(forKey: identity)?.task.cancel()
    }

    func retry(_ identity: ContentIdentity) {
        failures.remove(identity)
    }

    /// 停止一切请求和待设置的内容；画布离开窗口时调用。缓存保留。
    func stop() {
        for load in loads.values { load.task.cancel() }
        loads.removeAll()
        pending.removeAll()
        link?.invalidate()
        link = nil
    }

    /// 换管线或图像来源：丢掉缓存、失败记录和进行中的请求。
    func reset(pipeline: any ImagePipeline, source: CanvasImageSource) {
        stop()
        self.pipeline = pipeline
        self.source = source
        cache.removeAllObjects()
        failures.removeAll()
    }

    private func receive(_ rendered: RenderedImage, for identity: ContentIdentity) {
        updateCacheBudget()
        let image = CanvasImage(rendered)
        let key = IdentityKey(identity)
        // 渐进交付时只换成更精确或更清晰的图。
        if let cached = cache.object(forKey: key), image.quality < cached.quality, image.longSide <= cached.longSide { return }
        cache.setObject(image, forKey: key, cost: rendered.image.bytesPerRow * rendered.image.height)
        loadedImages += 1
        if let index = pending.firstIndex(where: { $0.identity == identity }) {
            pending[index].image = image
        } else {
            pending.append((identity, image))
        }
        // 显示链接持有目标，只在画布在窗口里时创建，离开窗口时由 `stop()` 释放。
        if link == nil, let view, view.window != nil {
            let link = view.displayLink(target: self, selector: #selector(applyPending(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    private func updateCacheBudget() {
        // 与管线持有相同的图像对象，只限制引用保留量，不另加一份预算。
        cache.totalCostLimit = max(1, Int((pipeline as? FileImagePipeline)?.thumbnailMemoryBudget ?? CacheBudgets.default.thumbnailMemoryBytes))
    }

    private func finish(_ identity: ContentIdentity, id: UInt64, failed: Bool) {
        guard loads[identity]?.id == id else { return }
        loads[identity] = nil
        if failed {
            failures.insert(identity)
            onFailure?(identity)
        }
    }

    @objc private func applyPending(_ link: CADisplayLink) {
        var budget = Self.contentsPerFrame
        var consumed = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while budget > 0, consumed < pending.count {
            let next = pending[consumed]
            consumed += 1
            if onReady?(next.identity, next.image) == true {
                budget -= 1
            }
        }
        CATransaction.commit()
        pending.removeFirst(consumed)
        if pending.isEmpty {
            link.isPaused = true
        }
    }
}

/// NSCache 的键要求是对象。
private final class IdentityKey: NSObject {
    let identity: ContentIdentity

    init(_ identity: ContentIdentity) {
        self.identity = identity
    }

    override var hash: Int {
        identity.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? IdentityKey)?.identity == identity
    }
}
