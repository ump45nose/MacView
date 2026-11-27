import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVLibraryData
import MVMedia
import MVPipeline
import MVPlugins
import MVReading
import MVSettings
import QuartzCore

/// 分页查看器：把当前页帧按 `PageFrameFit` 排在视图里，处理缩放、平移和翻页时的图像替换。
///
/// 坐标：`ViewerTransform` 和 `PageFrameFit` 用设备像素，图层用点。
/// `zoom == 1` 时请求 `displayTargets` 的目标，翻到已预解码的页直接命中 L1；放大后按 `decodeSize × zoom` 另外请求。
@MainActor
final class PagedViewerView: NSView, NSDraggingSource {
    /// 最近一次翻页到目标质量上屏的结果，供调试接口和自检读取。
    struct DisplayRecord {
        var page: Int
        var quality: RenditionQuality
        var duration: Duration
    }

    private let session: ReaderSession
    private let pipeline: any ImagePipeline
    private let sources: any SourceRegistry
    private(set) var slots: [PageSlot] = []
    /// 翻页时旧页留到新页有图（最多 `retireDelay`），避免闪一帧空白。
    private var retiring: [PageSlot] = []
    private var retireTimer: Timer?
    private static let retireDelay = 0.12
    private let shadowLayer = CALayer()
    /// 效果容器：页槽、分块、动图和视频都在里面，统一挂一份 Core Image 滤镜；导航图、错误、占位与放大镜留在容器外。
    let contentContainer: NSView = EffectContainerView()
    private var appliedEffects: EffectChain = .empty
    private var resolvedPluginFilters: ResolvedPluginFilters = .empty
    private var filterPreheatTasks: [ContentIdentity: (target: DisplayTarget, task: Task<Void, Never>)] = [:]
    weak var pluginFilterActivity: PluginFilterActivity?
    var onPluginFilterFailure: ((String, String) -> Void)?
    private var errorViews: [ObjectIdentifier: ItemErrorView] = [:]
    /// 虚拟书里不可用或取图失败的页盖上占位页。
    private var placeholders: [ObjectIdentifier: UnavailablePageView] = [:]
    /// 检查器给出的可用性，占位页据此说明原因（卷没有连接还是找不到）。
    var availability: [Location: Availability] = [:] {
        didSet { updateFailures() }
    }
    /// 虚拟书里某页取图失败：查看器据此重查这一页。
    var onPageFailure: ((Location) -> Void)?
    private(set) var transform = ViewerTransform.identity
    private(set) var fit = PageFrameFit(pages: [], size: PixelSize(width: 0, height: 0))
    /// 查看器自己探测到的元数据：书的加载没探测成功（或还没轮到）时，当前页不能一直等。
    private var probed: [ContentIdentity: ImageMetadata] = [:]
    private var decodeLimit = 0
    private var probes: [ContentIdentity: Task<Void, Never>] = [:]
    private var probeFailures: [ContentIdentity: any Error] = [:]
    /// `probeFailures` 所属的那一轮加载；会话开始新一轮加载时清空。
    private var probeLoadID = 0
    /// 已因取图失败交给重查的页，同一页只报一次。
    private var reportedFailures: Set<Location> = []
    private var requestTimer: Timer?
    private var awaitingDisplay = false
    private(set) var lastDisplay: DisplayRecord?
    private var lastMouse: CGPoint?
    private var dragOrigin: CGPoint?
    private var dragPageCandidate: (page: Int, point: NSPoint)?
    private var leftDownPoint: NSPoint?
    private var leftDidDrag = false
    private var leftClickCount = 0
    private var occlusionObserver: (any NSObjectProtocol)?
    let navigator = NavigatorView()
    private(set) var video: VideoPageView?
    private var pendingVideoStart: (identity: ContentIdentity, seconds: Double)?
    let magnifier = MagnifierLayer()
    private(set) var isMagnifying = false
    private var magnifierTiles: (identity: ContentIdentity, source: any TiledImageSource)?
    private var magnifierTask: Task<Void, Never>?
    /// 缩放或平移变了，HUD 上的比例随之更新。
    var onTransformChange: (() -> Void)?
    /// 左键单击命中查看器区域（参数为视图坐标与视图宽度）。
    var onClickZone: ((CGPoint, CGFloat) -> Void)?
    /// 滚轮分派（参数为事件与当前是否允许触控板双指横扫）。
    var onScrollWheel: ((NSEvent, Bool) -> ViewerGestureRecognizer.WheelDispatchResult)?

    init(session: ReaderSession, pipeline: any ImagePipeline, sources: any SourceRegistry) {
        self.session = session
        self.pipeline = pipeline
        self.sources = sources
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.25
        shadowLayer.shadowRadius = 15
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        layer?.addSublayer(shadowLayer)
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        addSubview(contentContainer)
        navigator.isHidden = true
        navigator.onPan = { [weak self] fraction in self?.pan(toFraction: fraction) }
        addSubview(navigator)
        // 子视图增删时 AppKit 会重排子视图图层，手加的图层可能被压到下面；用 zPosition 固定阴影在最底、放大镜在最上。
        shadowLayer.zPosition = -1
        magnifier.root.zPosition = 1
        layer?.addSublayer(magnifier.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var backing: Double { Double((window ?? NSApp.mainWindow)?.backingScaleFactor ?? 2) }

    /// 视口的设备像素。
    var viewportPixels: PixelSize {
        PixelSize(width: Int((bounds.width * backing).rounded()), height: Int((bounds.height * backing).rounded()))
    }

    private var viewport: CGSize { CGSize(width: bounds.width * backing, height: bounds.height * backing) }
    private var frameSize: CGSize { CGSize(width: fit.size.width, height: fit.size.height) }

    // MARK: 会话变化

    /// 会话状态变化后调用；可以频繁调用，没有变化时不发请求。
    func refresh() {
        guard session.settings.browseMode == .paged else { return }
        decodeLimit = session.maxDecodeLongSide
        if probeLoadID != session.loadID {
            probeLoadID = session.loadID
            probeFailures.removeAll()
            reportedFailures.removeAll()
        }
        var pages = session.book?.pages ?? []
        for index in pages.indices where pages[index].metadata == nil {
            pages[index].metadata = probed[pages[index].entry.identity]
        }
        guard session.frames.indices.contains(session.currentFrame) else {
            replaceSlots(with: [], pages: pages)
            fit = PageFrameFit(pages: [], size: PixelSize(width: 0, height: 0))
            layoutSlots()
            return
        }
        let frame = session.frames[session.currentFrame]
        let elements = frame.elements.filter { pages.indices.contains($0.page) }
        let turned = replaceSlots(with: elements, pages: pages)
        // 不可用的页不显示缓存里的旧图，恢复后重新请求。
        let unavailable = session.isVirtualBook ? session.unavailablePages : []
        for slot in slots { slot.setUnavailable(unavailable.contains(slot.identity.location)) }
        fit = PageFrameFit.fit(
            frame: PageFrame(elements: elements), pages: pages, viewport: viewportPixels, backingScale: backing, settings: session.settings
        )
        if turned {
            if !session.settings.keepZoomOnPageTurn { transform = startTransform() } else { transform = transform.clamped(frame: frameSize, viewport: viewport) }
            awaitingDisplay = true
            onTransformChange?()
        } else {
            transform = transform.clamped(frame: frameSize, viewport: viewport)
        }
        probeUnknown(pages: pages, elements: elements.filter { !unavailable.contains(pages[$0.page].id) })
        layoutSlots()
        let needsFilter = !resolvedPluginFilters.isEmpty && slots.contains { $0.needsPluginFilterUpdate(for: resolvedPluginFilters) }
        requestImages(immediately: turned || needsFilter || slots.contains { $0.baseTarget == nil })
        updateFailures()
    }

    /// 离开分页模式：停掉请求、播放器和动图。
    func clear() {
        pendingVideoStart = nil
        cancelFilterPreheat()
        replaceSlots(with: [], pages: [])
        finishRetiring()
        pluginFilterActivity?.reset()
        fit = PageFrameFit(pages: [], size: PixelSize(width: 0, height: 0))
        updateFailures()
        layoutSlots()
    }

    /// 选了缩放模式：回到模式给出的尺寸。
    func resetTransform() {
        refresh()
        transform = startTransform()
        layoutSlots()
        requestImages(immediately: true)
        onTransformChange?()
    }

    /// 超出视口时从页帧的开头看起：顶部对齐，水平方向贴阅读方向的起点。
    private func startTransform() -> ViewerTransform {
        let room = CGSize(width: max(0, frameSize.width - viewport.width) / 2, height: max(0, frameSize.height - viewport.height) / 2)
        return ViewerTransform(zoom: 1, offset: CGPoint(x: session.settings.direction == .leftToRight ? room.width : -room.width, y: room.height))
    }

    /// 返回页帧是否换了。页码、拆分部分和文件身份相同才复用。
    @discardableResult
    private func replaceSlots(with elements: [PageFrameElement], pages: [Page]) -> Bool {
        let same = elements.count == slots.count && zip(elements, slots).allSatisfy { element, slot in
            element == slot.element && pages[element.page].entry.identity == slot.identity
        }
        if same { return false }
        let hadImages = slots.contains { $0.hasImage }
        for slot in retiring { dispose(slot) }
        retiring = hadImages ? slots : []
        if !hadImages { slots.forEach(dispose) }
        for slot in retiring { slot.cancel() }
        slots = elements.map { element in
            let slot = PageSlot(element: element, page: pages[element.page], pipeline: pipeline)
            slot.onChange = { [weak self] in self?.slotChanged() }
            slot.onFilterStateChange = { [weak self] slot, state, failure in
                self?.slotFilterStateChanged(slot, state: state, failure: failure)
            }
            if !hadImages { slot.showPlaceholder() }
            contentContainer.layer?.addSublayer(slot.root)
            return slot
        }
        syncFilterActivity()
        retireTimer?.invalidate()
        retireTimer = nil
        if !retiring.isEmpty {
            let timer = Timer(timeInterval: Self.retireDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRetiring() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retireTimer = timer
        }
        stopVideo()
        return true
    }

    private func finishRetiring() {
        retireTimer?.invalidate()
        retireTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        retiring.forEach(dispose)
        retiring = []
        slots.forEach { $0.showPlaceholder() }
        CATransaction.commit()
    }

    private func dispose(_ slot: PageSlot) {
        slot.cancel()
        slot.root.removeFromSuperlayer()
    }

    private func slotChanged() {
        if !retiring.isEmpty, slots.allSatisfy({ $0.hasImage || $0.failure != nil || $0.isUnavailable }) { finishRetiring() }
        updateFailures()
        if awaitingDisplay, !slots.isEmpty, slots.allSatisfy({ ($0.quality ?? .placeholder) >= .exact }) {
            awaitingDisplay = false
            if let start = session.lastMoveAt, let first = slots.first {
                lastDisplay = DisplayRecord(page: first.element.page, quality: slots.map { $0.quality ?? .placeholder }.min() ?? .placeholder, duration: .now - start)
            }
        }
        navigator.needsDisplay = true
        updateVideo()
        updateAnimation()
    }

    /// 当前页还没有元数据时自己探测，失败的错误留在这一页上。
    private func probeUnknown(pages: [Page], elements: [PageFrameElement]) {
        for element in elements where pages[element.page].metadata == nil {
            let identity = pages[element.page].entry.identity
            guard probes[identity] == nil, probeFailures[identity] == nil else { continue }
            let pipeline = pipeline
            let loadID = probeLoadID
            probes[identity] = Task { [weak self] in
                do {
                    let metadata = try await pipeline.metadata(for: identity, priority: .visible)
                    guard let self else { return }
                    probes[identity] = nil
                    probed[identity] = metadata
                    refresh()
                } catch {
                    guard let self else { return }
                    probes[identity] = nil
                    // 上一轮加载的探测晚到时不再记成失败。
                    if !(error is CancellationError), loadID == probeLoadID { probeFailures[identity] = error }
                    updateFailures()
                }
            }
        }
    }

    // MARK: 排版

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        requestImages(immediately: true)
    }

    private func layoutSlots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = backing
        let zoom = transform.zoom
        let width = frameSize.width * zoom
        let height = frameSize.height * zoom
        let left = viewport.width / 2 + transform.offset.x - width / 2
        let top = viewport.height / 2 + transform.offset.y - height / 2
        var x = left
        for (index, slot) in slots.enumerated() {
            let size = fit.pages.indices.contains(index) ? fit.pages[index].pixelSize : PixelSize(width: 0, height: 0)
            // 宽高比未知的页按 2:3 占位。
            let pageHeight = size.height > 0 ? Double(size.height) * zoom : (height > 0 ? height : viewport.height)
            let pageWidth = size.width > 0 ? Double(size.width) * zoom : pageHeight * 2 / 3
            let y = viewport.height / 2 + transform.offset.y - pageHeight / 2
            let rect = CGRect(x: x / scale, y: y / scale, width: pageWidth / scale, height: pageHeight / scale)
            slot.root.frame = rect
            slot.imageLayer.frame = CGRect(origin: .zero, size: rect.size)
            slot.tiled?.layout(in: slot.root.bounds, visible: slot.root.convert(bounds, from: contentContainer.layer), scale: scale)
            errorViews[ObjectIdentifier(slot)]?.frame = rect.intersection(bounds).isEmpty ? rect : rect.intersection(bounds)
            placeholders[ObjectIdentifier(slot)]?.frame = Self.placeholderFrame(rect)
            if slot.isVideo { video?.frame = rect }
            x += pageWidth
        }
        let frameRect = CGRect(x: left / scale, y: top / scale, width: width / scale, height: height / scale)
        shadowLayer.frame = frameRect
        shadowLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: frameRect.size), transform: nil)
        shadowLayer.isHidden = slots.isEmpty || fit.size.width == 0
        navigator.frame = CGRect(x: bounds.width - 12 - navigator.preferredSize.width, y: 12, width: navigator.preferredSize.width, height: navigator.preferredSize.height)
        let overflow = width > viewport.width + 1 || height > viewport.height + 1
        navigator.isHidden = !overflow
        if overflow {
            navigator.update(slots: slots, frame: frameRect, viewport: bounds)
        }
        CATransaction.commit()
    }

    // MARK: 图像请求

    /// 新页立即请求；视口或缩放变化在停下 150 ms 后请求，拖动窗口尺寸时不反复解码。
    private func requestImages(immediately: Bool) {
        requestTimer?.invalidate()
        requestTimer = nil
        if immediately, !inLiveResize {
            applyTargets()
            return
        }
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.inLiveResize else { return }
                self.applyTargets()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        requestTimer = timer
    }

    private func applyTargets() {
        requestTimer = nil
        let settings = session.settings
        let limit = decodeLimit
        let targets = fit.displayTargets(settings: settings, maxDecodeLongSide: limit)
        for (index, slot) in slots.enumerated() where fit.pages.indices.contains(index) {
            if slot.isUnavailable {
                setTiled(false, slot: slot, source: nil)
                continue
            }
            guard let base = targets.first(where: { $0.element == slot.element })?.target else { continue }
            slot.requestBase(base)
            guard !slot.isVideo, frameCount(of: slot) <= 1 else { continue }
            let decode = fit.pages[index].decodeSize
            let zoom = max(transform.zoom, 1)
            let source = sourceSize(of: index)
            var needed = PixelSize(width: Int((Double(decode.width) * zoom).rounded()), height: Int((Double(decode.height) * zoom).rounded()))
            // 放大镜要看到原图的像素；超大图由放大镜自己取块，这里不铺满分块。
            if isMagnifying, let source, !ImageDecoder.needsTiling(source, maxDecodeLongSide: limit), source.width > needed.width { needed = source }
            let neededLong = max(needed.width, needed.height)
            let baseLong = max(base.pixelSize.width, base.pixelSize.height)
            if neededLong <= baseLong {
                slot.requestUpgrade(nil)
                setTiled(false, slot: slot, source: nil)
            } else if neededLong <= limit {
                setTiled(false, slot: slot, source: nil)
                slot.requestUpgrade(DisplayTarget(pixelSize: needed, filter: settings.resample, sharpen: settings.sharpen))
            } else if let source, ImageDecoder.needsTiling(source, maxDecodeLongSide: limit) {
                slot.requestUpgrade(nil)
                setTiled(true, slot: slot, source: source)
            } else {
                setTiled(false, slot: slot, source: nil)
                slot.requestUpgrade(DisplayTarget(pixelSize: needed, filter: settings.resample, sharpen: settings.sharpen), allowOriginal: true)
            }
            if !resolvedPluginFilters.isEmpty {
                let target = slot.upgradeTarget ?? base
                slot.setPluginFilters(resolvedPluginFilters, target: target, eligible: isStaticFilterEligible(slot: slot))
            } else if slot.isShowingFiltered || slot.filterState != .idle {
                slot.setPluginFilters(.empty, target: nil, eligible: false)
            }
        }
        layoutSlots()
        updateVideo()
        updateAnimation()
        updatePluginFilterPreheat()
    }

    private func sourceSize(of index: Int) -> PixelSize? {
        let element = fit.pages[index].element
        guard let pages = session.book?.pages, pages.indices.contains(element.page) else { return nil }
        let page = pages[element.page]
        return page.metadata?.pixelSize ?? probed[page.entry.identity]?.pixelSize
    }

    private func setTiled(_ on: Bool, slot: PageSlot, source: PixelSize?) {
        if on, slot.tiled == nil, let source {
            let layer = TiledPageLayer(identity: slot.identity, sourceSize: source, part: slot.element.part, pipeline: pipeline)
            slot.tiled = layer
            slot.root.addSublayer(layer.root)
        } else if !on, let tiled = slot.tiled {
            tiled.cancel()
            tiled.root.removeFromSuperlayer()
            slot.tiled = nil
        }
    }

    // MARK: 视频与动图

    /// 指定视频的起播时间：播放器已存在时直接跳转；否则记下，只在为该身份建播放器时消费一次。
    func startVideo(at seconds: Double, for identity: ContentIdentity) {
        guard seconds.isFinite else { return }
        let target = max(0, seconds)
        if let video, video.identity == identity {
            pendingVideoStart = nil
            video.seek(to: target)
        } else {
            pendingVideoStart = (identity, target)
        }
    }

    /// 每个窗口只有一个活动的播放器：页帧里第一个视频页。
    private func updateVideo() {
        guard let slot = slots.first(where: \.isVideo), slot.failure == nil, !slot.isUnavailable else {
            pendingVideoStart = nil
            stopVideo()
            return
        }
        if video?.identity != slot.identity {
            stopVideo()
            let startTime = pendingVideoStart?.identity == slot.identity ? pendingVideoStart?.seconds : nil
            pendingVideoStart = nil
            let view = VideoPageView(identity: slot.identity, sources: sources, pipeline: pipeline, startTime: startTime)
            view.onFailure = { [weak slot] error in slot?.fail(error) }
            view.frame = slot.root.frame
            contentContainer.addSubview(view)
            video = view
            view.start()
        }
    }

    private func stopVideo() {
        video?.stop()
        video?.removeFromSuperview()
        video = nil
    }

    /// 动图只在分页模式播放，帧按基础图的目标解码。
    private func updateAnimation() {
        for slot in slots where !slot.isVideo && !slot.isUnavailable {
            guard frameCount(of: slot) > 1, let target = slot.baseTarget, slot.hasImage else { continue }
            if slot.animated?.target != target {
                slot.animated?.stop()
                let animated = AnimatedPageLayer(identity: slot.identity, target: target, pipeline: pipeline, layer: slot.imageLayer, view: self)
                animated.onFailure = { [weak slot] error in slot?.fail(error) }
                slot.animated = animated
                animated.start()
            }
            slot.animated?.setVisible(isWindowVisible)
        }
    }

    private func frameCount(of slot: PageSlot) -> Int {
        metadata(of: slot)?.frameCount ?? 1
    }

    private func metadata(of slot: PageSlot) -> ImageMetadata? {
        guard let pages = session.book?.pages, pages.indices.contains(slot.element.page) else { return nil }
        return pages[slot.element.page].metadata ?? probed[slot.identity]
    }

    private func isStaticFilterEligible(slot: PageSlot) -> Bool {
        guard !slot.isUnavailable, !slot.isVideo, slot.tiled == nil,
              let meta = metadata(of: slot) else { return false }
        return meta.frameCount <= 1 && !ImageDecoder.needsTiling(meta.pixelSize, maxDecodeLongSide: decodeLimit)
    }

    func setPluginFilters(_ filters: ResolvedPluginFilters) {
        guard filters != resolvedPluginFilters else { return }
        resolvedPluginFilters = filters
        cancelFilterPreheat()
        guard session.settings.browseMode == .paged else { return }
        if filters.isEmpty {
            for slot in slots {
                slot.setPluginFilters(.empty, target: nil, eligible: false)
            }
            pluginFilterActivity?.reset()
            return
        }
        for slot in slots {
            let target = slot.upgradeTarget ?? slot.baseTarget
            slot.setPluginFilters(filters, target: target, eligible: isStaticFilterEligible(slot: slot))
        }
        syncFilterActivity()
        updatePluginFilterPreheat()
    }

    private func slotFilterStateChanged(_ slot: PageSlot, state: PluginFilterActivity.State, failure: String?) {
        syncFilterActivity()
        if let failure {
            let pluginName = resolvedPluginFilters.requests.first.flatMap { resolvedPluginFilters.pluginNames[$0.plugin] ?? $0.plugin } ?? ""
            onPluginFilterFailure?(pluginName, failure)
        }
    }

    private func syncFilterActivity() {
        guard session.settings.browseMode == .paged, let activity = pluginFilterActivity else { return }
        let eligibleStates = slots.filter { isStaticFilterEligible(slot: $0) }.map(\.filterState)
        activity.update(from: eligibleStates, filters: resolvedPluginFilters)
    }

    private func updatePluginFilterPreheat() {
        guard !resolvedPluginFilters.isEmpty,
              session.settings.browseMode == .paged,
              let pages = session.book?.pages,
              session.frames.indices.contains(session.currentFrame) else {
            cancelFilterPreheat()
            return
        }
        let unavailable = session.isVirtualBook ? session.unavailablePages : []
        let neighborIndices = [session.currentFrame - 1, session.currentFrame + 1]
            .filter { session.frames.indices.contains($0) }
        var desired: [ContentIdentity: DisplayTarget] = [:]
        for frameIndex in neighborIndices {
            let elements = session.frames[frameIndex].elements.filter { pages.indices.contains($0.page) }
            guard !elements.isEmpty else { continue }
            let frameFit = PageFrameFit.fit(
                frame: PageFrame(elements: elements),
                pages: pages,
                viewport: viewportPixels,
                backingScale: backing,
                settings: session.settings
            )
            let targets = frameFit.displayTargets(settings: session.settings, maxDecodeLongSide: decodeLimit)
            for item in targets {
                let page = pages[item.element.page]
                guard page.entry.kind == .image,
                      !unavailable.contains(page.id),
                      let meta = page.metadata ?? probed[page.entry.identity],
                      meta.frameCount <= 1,
                      !ImageDecoder.needsTiling(meta.pixelSize, maxDecodeLongSide: decodeLimit) else { continue }
                desired[page.entry.identity] = item.target
            }
        }
        for (identity, existing) in filterPreheatTasks where desired[identity] != existing.target {
            existing.task.cancel()
            filterPreheatTasks[identity] = nil
        }
        let requests = resolvedPluginFilters.requests
        let pipeline = pipeline
        for (identity, target) in desired where filterPreheatTasks[identity] == nil {
            let task = Task.detached(priority: .background) {
                _ = try? await pipeline.filteredImage(for: identity, filters: requests, target: target, priority: .adjacent)
            }
            filterPreheatTasks[identity] = (target, task)
        }
    }

    private func cancelFilterPreheat() {
        for entry in filterPreheatTasks.values { entry.task.cancel() }
        filterPreheatTasks.removeAll()
    }

    private var isWindowVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let observer = occlusionObserver { NotificationCenter.default.removeObserver(observer) }
        occlusionObserver = newWindow.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimation() }
            }
        }
    }

    // MARK: 错误

    private func updateFailures() {
        var wanted = Set<ObjectIdentifier>()
        var wantedPlaceholders = Set<ObjectIdentifier>()
        for slot in slots {
            let error = slot.failure ?? probeFailures[slot.identity]
            let key = ObjectIdentifier(slot)
            if session.isVirtualBook, slot.isUnavailable || error != nil {
                if error != nil, !slot.isUnavailable, reportedFailures.insert(slot.identity.location).inserted {
                    onPageFailure?(slot.identity.location)
                }
                wantedPlaceholders.insert(key)
                showPlaceholder(for: slot, error: slot.isUnavailable ? nil : error)
                continue
            }
            guard let error else { continue }
            wanted.insert(key)
            let view = errorViews[key] ?? {
                let view = ItemErrorView()
                view.onRetry = { [weak self, weak slot] in
                    guard let self, let slot else { return }
                    retry(slot)
                }
                addSubview(view, positioned: .below, relativeTo: navigator)
                errorViews[key] = view
                return view
            }()
            view.show(ErrorText.describe(error))
            view.frame = slot.root.frame.intersection(bounds).isEmpty ? slot.root.frame : slot.root.frame.intersection(bounds)
        }
        for (key, view) in errorViews where !wanted.contains(key) {
            view.removeFromSuperview()
            errorViews[key] = nil
        }
        for (key, view) in placeholders where !wantedPlaceholders.contains(key) {
            view.removeFromSuperview()
            placeholders[key] = nil
        }
    }

    /// 占位页的原因：不可用的页按检查结果（没有结果时是找不到），取图失败的页按错误。
    private func showPlaceholder(for slot: PageSlot, error: (any Error)?) {
        let key = ObjectIdentifier(slot)
        let view = placeholders[key] ?? {
            let view = UnavailablePageView()
            addSubview(view, positioned: .below, relativeTo: navigator)
            placeholders[key] = view
            return view
        }()
        let location = slot.identity.location
        let reason: UnavailablePageView.Reason
        if let error {
            switch error as? IOError {
            case let .volumeUnavailable(root): reason = .volume(root)
            case .notFound: reason = .missing
            default: reason = .failed(ErrorText.describe(error))
            }
        } else if case let .volumeUnavailable(root) = availability[location] {
            reason = .volume(root)
        } else {
            reason = .missing
        }
        view.show(reason)
        view.onRemove = { [weak self] in self?.removeFromPlaylist(location) }
        view.frame = Self.placeholderFrame(slot.root.frame)
    }

    /// 占位页盖住整页；页太小（没有放大的小图）时按最小尺寸居中，放得下原因和按钮。
    private static func placeholderFrame(_ page: CGRect) -> CGRect {
        let width = max(page.width, 320), height = max(page.height, 220)
        return CGRect(x: page.midX - width / 2, y: page.midY - height / 2, width: width, height: height)
    }

    private func removeFromPlaylist(_ location: Location) {
        guard let playlist = session.book?.location.playlistID, let app = NSApp.delegate as? AppDelegate else { return }
        Task { await LibraryActions.removeFromPlaylist([location], playlist: playlist, app: app) }
    }

    /// 页帧里位于 `point`（视图坐标）的页序号。
    func page(at point: CGPoint) -> Int? {
        slots.first { $0.root.frame.contains(point) }?.element.page
    }

    private func retry(_ slot: PageSlot) {
        reportedFailures.remove(slot.identity.location)
        if probeFailures.removeValue(forKey: slot.identity) != nil {
            refresh()
        } else {
            slot.retry()
        }
    }

    /// `item.retryFailed`：重试当前页帧里全部失败的项。
    @discardableResult
    func retryFailed() -> Bool {
        let failed = slots.filter { $0.failure != nil || probeFailures[$0.identity] != nil }
        failed.forEach(retry)
        return !failed.isEmpty
    }

    var hasFailures: Bool {
        slots.contains { $0.failure != nil || probeFailures[$0.identity] != nil }
    }

    #if DEBUG
    /// 自检：模拟停服时当前页探测失败留下的记录。
    func debugRecordProbeFailure(_ error: any Error, for identity: ContentIdentity) {
        probeFailures[identity] = error
        updateFailures()
    }
    #endif

    // MARK: 输入

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func devicePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * backing, y: point.y * backing)
    }

    /// 以光标为中心缩放；光标不在视图里时以中心。
    func zoom(by factor: Double, around point: CGPoint? = nil) {
        guard fit.size.width > 0 else { return }
        let center = point ?? lastMouse ?? CGPoint(x: bounds.midX, y: bounds.midY)
        transform = transform.zoomed(by: factor, around: devicePoint(center), frame: frameSize, viewport: viewport)
        layoutSlots()
        requestImages(immediately: false)
        onTransformChange?()
    }

    private func pan(by delta: CGPoint) {
        transform = transform.panned(by: delta, frame: frameSize, viewport: viewport)
        layoutSlots()
        requestImages(immediately: false)
        updateMagnifier()
    }

    /// 导航图上按比例定位：`fraction` 是视口中心在页帧上的位置。
    private func pan(toFraction fraction: CGPoint) {
        let width = frameSize.width * transform.zoom
        let height = frameSize.height * transform.zoom
        let offset = CGPoint(x: (0.5 - fraction.x) * width, y: (0.5 - fraction.y) * height)
        transform = ViewerTransform(zoom: transform.zoom, offset: offset).clamped(frame: frameSize, viewport: viewport)
        layoutSlots()
        requestImages(immediately: false)
    }

    private var isHorizontallyOverflowing: Bool {
        frameSize.width * transform.zoom > viewport.width + 1
    }

    private var isOverflowing: Bool {
        isHorizontallyOverflowing || frameSize.height * transform.zoom > viewport.height + 1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview)
        leftDownPoint = event.locationInWindow
        leftDidDrag = false
        leftClickCount = event.clickCount
        let point = viewPoint(event)
        if isOverflowing {
            dragOrigin = point
            dragPageCandidate = nil
        } else if let pageIndex = page(at: point) {
            dragOrigin = nil
            dragPageCandidate = (pageIndex, event.locationInWindow)
        } else {
            dragOrigin = point
            dragPageCandidate = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let down = leftDownPoint,
           hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 {
            leftDidDrag = true
        }
        if let origin = dragOrigin {
            let point = viewPoint(event)
            dragOrigin = point
            pan(by: CGPoint(x: (point.x - origin.x) * backing, y: (point.y - origin.y) * backing))
            return
        }
        guard let candidate = dragPageCandidate else { return }
        let point = event.locationInWindow
        guard hypot(point.x - candidate.point.x, point.y - candidate.point.y) > 4 else { return }
        dragPageCandidate = nil
        guard let pages = session.book?.pages, pages.indices.contains(candidate.page),
              let fileOps = (NSApp.delegate as? AppDelegate)?.fileOps,
              let writer = fileOps.pasteboardWriter(for: pages[candidate.page].entry, in: window?.windowController as? ReaderWindowController) else {
            return
        }
        let slot = slots.first { $0.element.page == candidate.page }
        let frame = slot?.root.frame ?? CGRect(origin: viewPoint(event), size: CGSize(width: 64, height: 64))
        let raw = slot?.contents
        let image: Any = (raw != nil && CFGetTypeID(raw as AnyObject) == CGImage.typeID) ? raw! : NSWorkspace.shared.icon(for: .data)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(frame, contents: image)
        let dragSession = beginDraggingSession(with: [item], event: event, source: self)
        dragSession.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        let down = leftDownPoint
        let didDrag = leftDidDrag
        let downClickCount = leftClickCount
        dragOrigin = nil
        dragPageCandidate = nil
        leftDownPoint = nil
        leftDidDrag = false
        leftClickCount = 0

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let down, !didDrag, flags.isEmpty, downClickCount == 1, event.clickCount == 1 {
            let distance = hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y)
            let point = viewPoint(event)
            if distance < 4, bounds.contains(point) {
                onClickZone?(point, bounds.width)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        superview?.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        superview?.rightMouseUp(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .generic
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        (NSApp.delegate as? AppDelegate)?.fileOps?.dragSessionEnded(operation: operation)
    }

    /// 页帧超出视口时平移；没超出时，只有鼠标滚轮（没有相位）翻页，触控板不翻；先按 `InputBindings` 分派滚轮与横扫。
    override func scrollWheel(with event: NSEvent) {
        if let result = onScrollWheel?(event, !isHorizontallyOverflowing) {
            switch result {
            case .handled:
                return
            case let .zoom(factor):
                zoom(by: factor, around: viewPoint(event))
                return
            case .standard:
                break
            }
        }
        let isMouseWheel = event.phase.isEmpty && event.momentumPhase.isEmpty && !event.hasPreciseScrollingDeltas
        if isOverflowing {
            let factor = event.hasPreciseScrollingDeltas ? backing : backing * 16
            pan(by: CGPoint(x: event.scrollingDeltaX * factor, y: event.scrollingDeltaY * factor))
        } else if isMouseWheel, event.scrollingDeltaY != 0 {
            session.go(event.scrollingDeltaY < 0 ? .nextFrame : .previousFrame)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: viewPoint(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouse = viewPoint(event)
        updateMagnifier()
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        lastMouse = nil
        updateMagnifier()
        super.mouseExited(with: event)
    }

    // MARK: 放大镜

    func toggleMagnifier() {
        isMagnifying.toggle()
        if !isMagnifying { magnifier.hide() }
        magnifierTask?.cancel()
        magnifierTiles = nil
        applyTargets()
        updateMagnifier()
    }

    /// 放大镜显示光标下 1/3 大小的区域：先用图层已有的图，超大图再取光标附近的块。
    private func updateMagnifier() {
        guard isMagnifying else { return }
        guard let point = lastMouse, let slot = slots.first(where: { $0.root.frame.contains(point) }) else {
            magnifier.hide()
            return
        }
        let frame = slot.root.frame
        var fraction = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        // contentsRect 的 x 是整页的比例，半页要换算。
        let rect = slot.imageLayer.contentsRect
        fraction = CGPoint(x: rect.minX + fraction.x * rect.width, y: fraction.y)
        let wholeWidth = frame.width / rect.width
        magnifier.show(contents: slot.contents, at: point, fraction: fraction, wholeSize: CGSize(width: wholeWidth, height: frame.height))
        guard let index = slots.firstIndex(where: { $0 === slot }), let source = sourceSize(of: index),
              ImageDecoder.needsTiling(source, maxDecodeLongSide: session.maxDecodeLongSide) else { return }
        requestMagnifierTile(identity: slot.identity, source: source, fraction: fraction, wholeWidth: wholeWidth)
    }

    private func requestMagnifierTile(identity: ContentIdentity, source: PixelSize, fraction: CGPoint, wholeWidth: Double) {
        magnifierTask?.cancel()
        let pipeline = pipeline
        let known = magnifierTiles?.identity == identity ? magnifierTiles?.source : nil
        let side = MagnifierLayer.diameter * backing
        // 区域对应的源像素：屏幕上一个点在图上有多少源像素，再除以放大倍数。
        let perPoint = Double(source.width) / wholeWidth / MagnifierLayer.magnification
        let regionSide = MagnifierLayer.diameter * perPoint
        let region = CGRect(
            x: fraction.x * Double(source.width) - regionSide / 2, y: fraction.y * Double(source.height) - regionSide / 2,
            width: regionSide, height: regionSide
        )
        magnifierTask = Task { [weak self] in
            // 光标停下 60 ms 才取块。
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            do {
                let tiles: any TiledImageSource
                if let known { tiles = known } else { tiles = try await pipeline.tiledSource(for: identity) }
                self?.magnifierTiles = (identity, tiles)
                let image = try await tiles.tile(region, scale: min(1, side / regionSide))
                guard !Task.isCancelled else { return }
                self?.magnifier.showDetail(image.surface ?? image.image)
            } catch {
                guard !Task.isCancelled else { return }
                self?.slots.first { $0.identity == identity }?.fail(error)
            }
        }
    }

    /// HUD 上显示的比例：100% 是 1 源像素 = 1 点。
    var displayPercent: Int? {
        guard let page = fit.pages.first, page.pixelSize.width > 0, let source = fit.pages.indices.first.flatMap({ sourceSize(of: $0) }) else { return nil }
        let sourceWidth = page.element.part == .whole ? source.width : source.width / 2
        return Int((Double(page.pixelSize.width) * transform.zoom / Double(max(sourceWidth, 1)) / backing * 100).rounded())
    }

    /// 某个缩放模式下的比例，显示选项里的提示用。
    func percent(for mode: ScaleMode, fixedScale: Double) -> Int? {
        guard let pages = session.book?.pages, session.frames.indices.contains(session.currentFrame) else { return nil }
        var settings = session.settings
        settings.scaleMode = mode
        settings.fixedScale = fixedScale
        let fitted = PageFrameFit.fit(frame: session.frames[session.currentFrame], pages: pages, viewport: viewportPixels, backingScale: backing, settings: settings)
        guard let page = fitted.pages.first, page.pixelSize.width > 0, let source = pages[page.element.page].metadata?.pixelSize else { return nil }
        let sourceWidth = page.element.part == .whole ? source.width : source.width / 2
        return Int((Double(page.pixelSize.width) / Double(max(sourceWidth, 1)) / backing * 100).rounded())
    }

    /// 挂在内容容器和放大镜上的滤镜：只在链变化时替换，不重建图层。
    func setEffects(_ chain: EffectChain) {
        guard chain != appliedEffects else { return }
        appliedEffects = chain
        let mainFilters = EffectFilters.filters(for: chain)
        let active = !mainFilters.isEmpty
        layerUsesCoreImageFilters = active
        contentContainer.layerUsesCoreImageFilters = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentContainer.layer?.filters = active ? mainFilters : nil
        CATransaction.commit()
        magnifier.setFilters(EffectFilters.filters(for: chain))
    }

    var effectFilterCount: Int {
        contentContainer.layer?.filters?.count ?? 0
    }

    /// 窗口关闭时取消全部请求。
    func cancelLoads() {
        pendingVideoStart = nil
        cancelFilterPreheat()
        slots.forEach { $0.cancel() }
        retiring.forEach { $0.cancel() }
        probes.values.forEach { $0.cancel() }
        magnifierTask?.cancel()
        stopVideo()
        retireTimer?.invalidate()
        requestTimer?.invalidate()
        pluginFilterActivity?.reset()
    }
}

/// 出错的项：错误留在那一格，不打断整本书。
@MainActor
final class ItemErrorView: NSView {
    private let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = FlatButton(font: Theme.font(.overlays, size: 12, weight: .medium), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10)
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = Theme.danger
        label.font = Theme.font(.overlays, size: 12)
        label.textColor = Theme.text2
        label.alignment = .center
        button.setText(String(localized: "重试"))
        button.target = self
        button.action = #selector(retry)
        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        label.font = Theme.font(.overlays, size: 12)
        button.applyFont(Theme.font(.overlays, size: 12, weight: .medium))
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String) {
        label.stringValue = text
    }

    @objc private func retry() {
        onRetry?()
    }
}

/// 虚拟书里不可用的页：原因、“从列表移除”，卷没有连接时另有“连接”。盖住整页，不显示缓存里的旧图。
@MainActor
final class UnavailablePageView: NSView {
    enum Reason: Equatable {
        case missing
        case volume(Location.Root)
        case failed(String)
    }

    private let title = NSTextField(labelWithString: String(localized: "这一页不可用"))
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let connect = UnavailablePageView.button(String(localized: "连接"))
    private let remove = UnavailablePageView.button(String(localized: "从列表移除"))
    private let buttons = NSStackView()
    private var mountURL: URL?
    private(set) var reason: Reason?
    var onRemove: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        title.font = Theme.serif(16)
        title.textColor = Theme.text
        title.alignment = .center
        detail.font = Theme.font(.overlays, size: 12)
        detail.textColor = Theme.text2
        detail.alignment = .center
        detail.maximumNumberOfLines = 4
        connect.target = self
        connect.action = #selector(connectPressed)
        remove.target = self
        remove.action = #selector(removePressed)
        buttons.addArrangedSubview(connect)
        buttons.addArrangedSubview(remove)
        buttons.spacing = 6
        let stack = NSStackView(views: [title, detail, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        detail.font = Theme.font(.overlays, size: 12)
        let buttonFont = Theme.font(.overlays, size: 12)
        connect.applyFont(buttonFont)
        remove.applyFont(buttonFont)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func button(_ title: String) -> FlatButton {
        let button = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10)
        button.setText(title)
        return button
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        let orientation: NSUserInterfaceLayoutOrientation = bounds.width < 320 ? .vertical : .horizontal
        if buttons.orientation != orientation { buttons.orientation = orientation }
        super.layout()
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.well.cgColor
        layer?.borderColor = Theme.line.cgColor
    }

    func show(_ reason: Reason) {
        guard reason != self.reason else { return }
        self.reason = reason
        switch reason {
        case .missing:
            detail.stringValue = String(localized: "找不到原文件：可能已被删除，或在 MacView 之外被移走")
            mountURL = nil
        case let .volume(root):
            detail.stringValue = PluginSourceProvider.sourceID(of: root) != nil
                ? ErrorText.describe(IOError.volumeUnavailable(root))
                : String(localized: "所在的网络卷没有连接")
            mountURL = root.mountURL
        case let .failed(text):
            detail.stringValue = text
            mountURL = nil
        }
        connect.isHidden = mountURL == nil
    }

    @objc private func connectPressed() {
        if let mountURL { NSWorkspace.shared.open(mountURL) }
    }

    @objc private func removePressed() {
        onRemove?()
    }
}

/// 分页视图的内容容器：翻转坐标、启用 Core Image 滤镜，不挡鼠标命中。
@MainActor
private final class EffectContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
