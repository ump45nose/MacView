import AppKit
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import MVPlugins
import MVReading
import MVSettings
import Observation
import os
import QuartzCore

/// 主区插件滤镜的进度出口，供状态栏与效果面板共用；键为 `"<插件 id>.<滤镜 id>"`，只反映当前窗口当前页。
@MainActor
@Observable
final class PluginFilterActivity {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    private(set) var names: [String: String] = [:]

    static func key(plugin: String, filter: String) -> String {
        "\(plugin).\(filter)"
    }

    func update(_ nextStates: [String: State], names nextNames: [String: String]) {
        if names != nextNames { names = nextNames }
        if states != nextStates { states = nextStates }
    }

    func update(from itemStates: some Collection<State>, filters: ResolvedPluginFilters) {
        guard !filters.isEmpty else {
            reset()
            return
        }
        let combined: State
        if itemStates.contains(.running) {
            combined = .running
        } else if let failedMessage = itemStates.compactMap({ state -> String? in
            if case let .failed(msg) = state { return msg }
            return nil
        }).first {
            combined = .failed(failedMessage)
        } else {
            combined = .idle
        }
        var next: [String: State] = [:]
        next.reserveCapacity(filters.requests.count)
        for req in filters.requests {
            next[Self.key(plugin: req.plugin, filter: req.filter)] = combined
        }
        update(next, names: filters.names)
    }

    func reset() {
        if !states.isEmpty { states = [:] }
        if !names.isEmpty { names = [:] }
    }

    var statusText: String? {
        for (key, state) in states where state == .running {
            let name = names[key] ?? key
            return String(localized: "\(name) 处理中…")
        }
        return nil
    }
}

/// 当前窗口生效的插件滤镜请求与展示元数据快照。
struct ResolvedPluginFilters: Equatable {
    var requests: [PluginFilterRequest]
    /// 键 `"<插件 id>.<滤镜 id>"` 到显示名。
    var names: [String: String]
    /// 参与插件 ID 到版本号快照，插件热重载换版本时据此重新处理。
    var versions: [String: String]
    /// 插件 ID 到插件显示名，用于错误日志来源。
    var pluginNames: [String: String]

    static let empty = ResolvedPluginFilters(requests: [], names: [:], versions: [:], pluginNames: [:])
    var isEmpty: Bool { requests.isEmpty }
}

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
    /// 虚拟书里不可用的页：不请求图像，图层不留旧图，由查看器盖上占位页。
    private(set) var isUnavailable = false
    private(set) var baseTarget: DisplayTarget?
    private(set) var upgradeTarget: DisplayTarget?
    private var baseTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    /// 放大图已经到达：基础图不再覆盖它。
    private var upgradeDelivered = false
    /// 最新交付的原图，供关闭插件滤镜或参数变化时立即切回。
    private var originalImage: RenderedImage?
    private var activeFilters: ResolvedPluginFilters = .empty
    private var filterTarget: DisplayTarget?
    private var filterTask: Task<Void, Never>?
    private var filterGeneration: UInt64 = 0
    private(set) var isShowingFiltered = false
    private(set) var filterState: PluginFilterActivity.State = .idle
    private let pipeline: any ImagePipeline
    private let logger = Logger(category: "page-view")
    /// 有新图设到图层，或请求失败。
    var onChange: (() -> Void)?
    /// 插件滤镜处理状态变化（最后一个参数为失败文案，仅在进入 failed 时非 nil）。
    var onFilterStateChange: ((PageSlot, PluginFilterActivity.State, String?) -> Void)?
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
        guard !isUnavailable, target != baseTarget || failure != nil else { return }
        baseTarget = target
        failure = nil
        baseTask?.cancel()
        if isVideo {
            let pipeline = pipeline
            let identity = identity
            let longSide = max(target.pixelSize.width, target.pixelSize.height)
            baseTask = Task { [weak self] in
                do {
                    let image = try await pipeline.videoPoster(for: identity, maxPixel: longSide, priority: .visible)
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
        guard !isUnavailable, target != upgradeTarget else { return }
        upgradeTarget = target
        upgradeDelivered = false
        upgradeTask?.cancel()
        upgradeTask = target.flatMap { load($0, allowOriginal: allowOriginal, isUpgrade: true) }
    }

    func retry() {
        guard failure != nil, let target = baseTarget else { return }
        failure = nil
        onChange?()
        baseTarget = nil
        requestBase(target)
    }

    /// 变为不可用时停掉请求并清掉图层里的图（可能是缓存里的旧图）；恢复后由查看器重新请求。
    func setUnavailable(_ unavailable: Bool) {
        guard unavailable != isUnavailable else { return }
        isUnavailable = unavailable
        cancel()
        animated = nil
        baseTarget = nil
        upgradeTarget = nil
        upgradeDelivered = false
        let hadFilterState = filterState != .idle
        originalImage = nil
        activeFilters = .empty
        filterTarget = nil
        isShowingFiltered = false
        filterState = .idle
        failure = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        root.backgroundColor = unavailable ? nil : Theme.line.cgColor
        CATransaction.commit()
        hasImage = false
        quality = nil
        if hadFilterState {
            onFilterStateChange?(self, .idle, nil)
        }
        onChange?()
    }

    /// 窗口隐藏或页面离开时停止全部请求。
    func cancel() {
        baseTask?.cancel()
        upgradeTask?.cancel()
        filterTask?.cancel()
        filterTask = nil
        filterGeneration &+= 1
        tiled?.cancel()
        animated?.stop()
    }

    /// 针对静态非分块页应用或撤回插件滤镜：原图照常先上屏，结果到达后按代次替换；关闭或变参立即取消并切回原图。
    func setPluginFilters(_ filters: ResolvedPluginFilters, target: DisplayTarget?, eligible: Bool) {
        guard !isUnavailable, !isVideo, eligible, !filters.isEmpty, let target else {
            cancelFilterAndRestoreOriginal()
            return
        }
        if filters == activeFilters && target == filterTarget && (filterTask != nil || isShowingFiltered) {
            return
        }
        filterTask?.cancel()
        filterTask = nil
        filterGeneration &+= 1
        activeFilters = filters
        filterTarget = target
        if isShowingFiltered {
            isShowingFiltered = false
            restoreOriginalContents()
        }
        let generation = filterGeneration
        filterState = .running
        onFilterStateChange?(self, .running, nil)
        let pipeline = pipeline
        let identity = identity
        let requests = filters.requests
        filterTask = Task { [weak self] in
            do {
                let rendered = try await pipeline.filteredImage(
                    for: identity,
                    filters: requests,
                    target: target,
                    priority: .visible
                )
                guard !Task.isCancelled, let self, self.filterGeneration == generation, !self.isUnavailable else { return }
                self.applyFiltered(rendered)
            } catch {
                guard !Task.isCancelled, let self, self.filterGeneration == generation, !self.isUnavailable else { return }
                if error is CancellationError { return }
                if case IOError.cancelled = error { return }
                if case PluginError.cancelled = error { return }
                let message = ErrorText.describe(error)
                self.filterTask = nil
                self.filterState = .failed(message)
                self.onFilterStateChange?(self, .failed(message), message)
            }
        }
    }

    /// 判断当前页槽是否已针对给定滤镜集合发出或完成了请求。
    func needsPluginFilterUpdate(for filters: ResolvedPluginFilters) -> Bool {
        guard !filters.isEmpty else { return isShowingFiltered || filterTask != nil || filterState != .idle }
        return activeFilters != filters || (filterTask == nil && !isShowingFiltered && filterState == .idle)
    }

    private func cancelFilterAndRestoreOriginal() {
        let hadWork = filterTask != nil || isShowingFiltered || !activeFilters.isEmpty || filterState != .idle
        guard hadWork else { return }
        filterTask?.cancel()
        filterTask = nil
        filterGeneration &+= 1
        activeFilters = .empty
        filterTarget = nil
        if isShowingFiltered {
            isShowingFiltered = false
            restoreOriginalContents()
        }
        if filterState != .idle {
            filterState = .idle
            onFilterStateChange?(self, .idle, nil)
        }
    }

    private func restoreOriginalContents() {
        guard let original = originalImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = original.surface ?? original.image
        root.backgroundColor = nil
        CATransaction.commit()
        onChange?()
    }

    private func applyFiltered(_ image: RenderedImage) {
        filterTask = nil
        isShowingFiltered = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image.surface ?? image.image
        root.backgroundColor = nil
        CATransaction.commit()
        hasImage = true
        filterState = .idle
        onFilterStateChange?(self, .idle, nil)
        onChange?()
    }

    /// 内存命中时在本次调用里直接设到图层，不再发异步请求。
    private func load(_ target: DisplayTarget, allowOriginal: Bool, isUpgrade: Bool) -> Task<Void, Never>? {
        if let image = pipeline.cachedImage(for: identity, target: target) {
            apply(image, isUpgrade: isUpgrade)
            return nil
        }
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
        if isUnavailable || (!isUpgrade && upgradeDelivered) { return }
        // 放大图渐进交付的占位和浏览图可能比基础图模糊。
        if isUpgrade {
            if image.quality < .exact, quality.map({ $0 >= .exact }) == true { return }
            upgradeDelivered = true
        }
        originalImage = image
        if !isShowingFiltered {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            OSSignposter(category: .render).emitEvent("PageLayerSetStart", "page=\(self.element.page, privacy: .public)")
            imageLayer.contents = image.surface ?? image.image
            root.backgroundColor = nil
            CATransaction.commit()
            OSSignposter(category: .render).emitEvent("PageLayerCommitted", "page=\(self.element.page, privacy: .public)")
        }
        hasImage = true
        quality = image.quality
        onChange?()
    }

    func fail(_ error: any Error) {
        if isUnavailable || error is CancellationError { return }
        if case IOError.cancelled = error { return }
        logger.error("读取页面失败：\(self.identity.location.description, privacy: .public) \(String(describing: error), privacy: .public)")
        failure = error
        onChange?()
    }
}
