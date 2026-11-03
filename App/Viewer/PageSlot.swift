import AppKit
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import os
import QuartzCore

/// 页帧中的一页：一个图层和它的图像请求。
///
/// 图像分两级：`base` 是 `PageFrameFit.displayTargets` 给出的目标，和预解码用同一个键；
/// 放大后不够清晰时由查看器发出 `upgrade`，到达后替换图层内容，基础图留作占位。
@MainActor
final class PageSlot {
    let element: PageFrameElement
    let identity: ContentIdentity
    /// 视频页的播放器由查看器放在这一页上。
    let isVideo: Bool
    let root = CALayer()
    let imageLayer = CALayer()
    private(set) var failure: (any Error)?
    private(set) var hasImage = false
    /// 当前图层内容的质量。
    private(set) var quality: RenditionQuality?
    private(set) var baseTarget: DisplayTarget?
    private(set) var upgradeTarget: DisplayTarget?
    private var baseTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    /// 放大图已经到达：基础图不再覆盖它。
    private var upgradeDelivered = false
    private let pipeline: any ImagePipeline
    private let logger = Logger(category: "page-view")
    /// 有新图设到图层，或请求失败。
    var onChange: (() -> Void)?
    var tiled: TiledPageLayer?
    var animated: AnimatedPageLayer?

    init(element: PageFrameElement, page: Page, pipeline: any ImagePipeline) {
        self.element = element
        identity = page.entry.identity
        isVideo = page.entry.kind == .video
        self.pipeline = pipeline
        root.masksToBounds = true
        imageLayer.contentsGravity = .resize
        switch element.part {
        case .whole: break
        case .leftHalf: imageLayer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: imageLayer.contentsRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        }
        root.addSublayer(imageLayer)
    }

    var contents: Any? { imageLayer.contents }

    /// 显示占位底色（图像迟迟没有到达时）。
    func showPlaceholder() {
        if !hasImage { root.backgroundColor = Theme.line.cgColor }
    }

    func requestBase(_ target: DisplayTarget) {
        guard target != baseTarget || failure != nil else { return }
        baseTarget = target
        failure = nil
        baseTask?.cancel()
        if isVideo {
            let pipeline = pipeline
            let identity = identity
            let longSide = max(target.pixelSize.width, target.pixelSize.height)
            baseTask = Task { [weak self] in
                do {
                    let image = try await pipeline.videoPoster(for: identity, maxPixel: longSide)
                    guard !Task.isCancelled else { return }
                    self?.apply(image, isUpgrade: false)
                } catch {
                    self?.fail(error)
                }
            }
            return
        }
        baseTask = load(target, allowOriginal: false, isUpgrade: false)
    }

    /// `target` 为 nil 时撤销放大图请求（缩回去了）。已到达的图保留，不再换回模糊的基础图。
    func requestUpgrade(_ target: DisplayTarget?, allowOriginal: Bool = false) {
        guard target != upgradeTarget else { return }
        upgradeTarget = target
        upgradeDelivered = false
        upgradeTask?.cancel()
        upgradeTask = target.map { load($0, allowOriginal: allowOriginal, isUpgrade: true) }
    }

    func retry() {
        guard failure != nil, let target = baseTarget else { return }
        failure = nil
        onChange?()
        baseTarget = nil
        requestBase(target)
    }

    /// 窗口隐藏或页面离开时停止全部请求。
    func cancel() {
        baseTask?.cancel()
        upgradeTask?.cancel()
        tiled?.cancel()
        animated?.stop()
    }

    private func load(_ target: DisplayTarget, allowOriginal: Bool, isUpgrade: Bool) -> Task<Void, Never> {
        let stream = pipeline.image(for: identity, target: target, allowOriginal: allowOriginal, priority: .visible)
        return Task { [weak self] in
            do {
                for try await image in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(image, isUpgrade: isUpgrade)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    private func apply(_ image: RenderedImage, isUpgrade: Bool) {
        if !isUpgrade, upgradeDelivered { return }
        // 放大图渐进交付的占位和浏览图可能比基础图模糊。
        if isUpgrade {
            if image.quality < .exact, quality.map({ $0 >= .exact }) == true { return }
            upgradeDelivered = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.surface ?? image.image
        root.backgroundColor = nil
        CATransaction.commit()
        hasImage = true
        quality = image.quality
        onChange?()
    }

    func fail(_ error: any Error) {
        if error is CancellationError { return }
        if case IOError.cancelled = error { return }
        logger.error("读取页面失败：\(self.identity.location.description, privacy: .public) \(String(describing: error), privacy: .public)")
        failure = error
        onChange?()
    }
}
