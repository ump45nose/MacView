import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import QuartzCore

/// 分页查看器：把当前页帧按 `PageFrameFit` 排在视图里，处理缩放、平移和翻页时的图像替换。
///
/// 坐标：`ViewerTransform` 和 `PageFrameFit` 用设备像素，图层用点。
/// `zoom == 1` 时请求 `displayTargets` 的目标，翻到已预解码的页直接命中 L1；放大后按 `decodeSize × zoom` 另外请求。
@MainActor
final class PagedViewerView: NSView {
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
    private var errorViews: [ObjectIdentifier: ItemErrorView] = [:]
    private(set) var transform = ViewerTransform.identity
    private(set) var fit = PageFrameFit(pages: [], size: PixelSize(width: 0, height: 0))
    /// 查看器自己探测到的元数据：书的加载没探测成功（或还没轮到）时，当前页不能一直等。
    private var probed: [ContentIdentity: ImageMetadata] = [:]
    private var probes: [ContentIdentity: Task<Void, Never>] = [:]
    private var probeFailures: [ContentIdentity: any Error] = [:]
    private var requestTimer: Timer?
    private var awaitingDisplay = false
    private(set) var lastDisplay: DisplayRecord?
    private var lastMouse: CGPoint?
    private var dragOrigin: CGPoint?
    private var occlusionObserver: (any NSObjectProtocol)?
    let navigator = NavigatorView()
    private(set) var video: VideoPageView?
    let magnifier = MagnifierLayer()
    private(set) var isMagnifying = false
    private var magnifierTiles: (identity: ContentIdentity, source: any TiledImageSource)?
    private var magnifierTask: Task<Void, Never>?
    /// 缩放或平移变了，HUD 上的比例随之更新。
    var onTransformChange: (() -> Void)?

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
        navigator.isHidden = true
        navigator.onPan = { [weak self] fraction in self?.pan(toFraction: fraction) }
        addSubview(navigator)
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
        probeUnknown(pages: pages, elements: elements)
        layoutSlots()
        requestImages(immediately: turned || slots.contains { $0.baseTarget == nil })
        updateFailures()
    }

    /// 离开分页模式：停掉请求、播放器和动图。
    func clear() {
        replaceSlots(with: [], pages: [])
        finishRetiring()
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

    /// 返回页帧是否换了。保留身份和部分相同的页。
    @discardableResult
    private func replaceSlots(with elements: [PageFrameElement], pages: [Page]) -> Bool {
        let same = elements.count == slots.count && zip(elements, slots).allSatisfy { element, slot in
            element.part == slot.element.part && pages[element.page].entry.identity == slot.identity
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
            if !hadImages { slot.showPlaceholder() }
            layer?.insertSublayer(slot.root, below: navigator.layer)
            return slot
        }
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
        if !retiring.isEmpty, slots.allSatisfy({ $0.hasImage || $0.failure != nil }) { finishRetiring() }
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
                    if !(error is CancellationError) { probeFailures[identity] = error }
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
            slot.tiled?.layout(in: slot.root.bounds, visible: slot.root.convert(bounds, from: layer), scale: scale)
            errorViews[ObjectIdentifier(slot)]?.frame = rect.intersection(bounds).isEmpty ? rect : rect.intersection(bounds)
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
        let limit = session.maxDecodeLongSide
        let targets = fit.displayTargets(settings: settings, maxDecodeLongSide: limit)
        for (index, slot) in slots.enumerated() where fit.pages.indices.contains(index) {
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
        }
        layoutSlots()
        updateVideo()
        updateAnimation()
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

    /// 每个窗口只有一个活动的播放器：页帧里第一个视频页。
    private func updateVideo() {
        guard let slot = slots.first(where: \.isVideo), slot.failure == nil else {
            stopVideo()
            return
        }
        if video?.identity != slot.identity {
            stopVideo()
            let view = VideoPageView(identity: slot.identity, sources: sources)
            view.onFailure = { [weak slot] error in slot?.fail(error) }
            view.frame = slot.root.frame
            addSubview(view, positioned: .below, relativeTo: navigator)
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
        for slot in slots where !slot.isVideo {
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
        guard let pages = session.book?.pages, pages.indices.contains(slot.element.page) else { return 1 }
        return (pages[slot.element.page].metadata ?? probed[slot.identity])?.frameCount ?? 1
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
        for slot in slots {
            let error = slot.failure ?? probeFailures[slot.identity]
            let key = ObjectIdentifier(slot)
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
    }

    private func retry(_ slot: PageSlot) {
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

    private var isOverflowing: Bool {
        frameSize.width * transform.zoom > viewport.width + 1 || frameSize.height * transform.zoom > viewport.height + 1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview)
        dragOrigin = viewPoint(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = viewPoint(event)
        guard let origin = dragOrigin else { return }
        dragOrigin = point
        pan(by: CGPoint(x: (point.x - origin.x) * backing, y: (point.y - origin.y) * backing))
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    /// 页帧超出视口时平移；没超出时，只有鼠标滚轮（没有相位）翻页，触控板不翻。
    override func scrollWheel(with event: NSEvent) {
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

    /// 窗口关闭时取消全部请求。
    func cancelLoads() {
        slots.forEach { $0.cancel() }
        retiring.forEach { $0.cancel() }
        probes.values.forEach { $0.cancel() }
        magnifierTask?.cancel()
        stopVideo()
        retireTimer?.invalidate()
        requestTimer?.invalidate()
    }
}

/// 出错的项：错误留在那一格，不打断整本书。
@MainActor
final class ItemErrorView: NSView {
    private let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = FlatButton(font: .systemFont(ofSize: 12, weight: .medium), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10)
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = Theme.danger
        label.font = .systemFont(ofSize: 12)
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
