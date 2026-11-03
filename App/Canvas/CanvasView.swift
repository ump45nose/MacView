import AppKit
import MVFoundation
import MVIO
import MVLayout
import MVPipeline
import MVSettings
import os
import QuartzCore

/// 画布的一项：内容身份与宽高比（宽除以高，未知时为 nil）。
struct CanvasItem: Equatable {
    var identity: ContentIdentity
    var aspectRatio: Double?
    /// 右下角的角标，例如视频的时长。
    var badge: String?
    /// 底部的标题，网格用。
    var label: String?
    /// 图还不能请求，例如书架上还没解析封面的书。换成真正的身份时项的位置不变。
    var isPending = false
}

/// 回报给预取计划的范围：可见项，以及可见区加余量内的项。砌体中可见项不一定连续，范围取最小到最大的序号。
struct CanvasVisibleRange: Equatable {
    var visible: Range<Int>
    var margin: Range<Int>
}

/// 主线程上的用时，供测试窗口统计。
enum CanvasMeasure {
    /// 滚动时一次图层分配。
    case scroll(Duration)
    /// 一次重排，包括恢复锚点和更新已分配图层的位置。
    case relayout(Duration)
    /// 滚动停止后，可见项的请求全部发出所用的时间；滚动中已经发出的记为 0。
    case settled(latency: Duration, visible: Int)
}

struct CanvasCounters {
    var activeLayers = 0
    var peakLayers = 0
    var createdLayers = 0
    var loadedImages = 0
    var inFlight = 0
    /// 带锚点的重排次数，以及重排后锚点项不在视口内的次数。
    var anchoredRelayouts = 0
    var anchorMisses = 0
}

/// 画布引擎：NSScrollView 加图层池。
///
/// - 布局由 MVLayout 的 `CollectionLayout` 计算，只为可见区前后各加一屏余量内的项分配图层，滚出余量的图层回收复用，请求随之取消。
/// - 视口尺寸、缩略图尺寸、布局种类或方向变化时保持可见区前沿的项；数据整体重排时保持选中项，没有选中项时保持中心项。
/// - 图像在后台向管线请求，回到主线程后按每帧限额设置图层内容。
/// - 滚动停止（50 ms 内没有变化）时回报可见范围，并补发可见项缺少的请求。
final class CanvasView: NSScrollView {
    var kind: CollectionLayoutKind {
        didSet { if kind != oldValue { configurationChanged() } }
    }

    var direction: ReadingDirection {
        didSet { if direction != oldValue { configurationChanged() } }
    }

    /// 砌体与网格的目标列宽；条的横截长度上限（传 `.infinity` 时适合视口）。
    var itemExtent: Double {
        didSet { if itemExtent != oldValue { configurationChanged() } }
    }

    /// 捏合缩放时 `itemExtent` 的范围。
    var itemExtentRange: ClosedRange<Double> = 80...640
    var spacing: Double = 8 {
        didSet { if spacing != oldValue { configurationChanged() } }
    }

    /// 单击直接激活，不选中；主区的瀑布流和条用。
    var activatesOnSingleClick = false
    /// 方向键移动选中项。关掉时由响应链处理（翻页），上下键滚动一行。
    var arrowKeysMoveSelection = true
    /// 条的末尾：排在最后一项之后、占主方向 `footerLength` 点的视图，加进文档视图。
    var footerView: NSView? {
        didSet {
            if footerView === oldValue { return }
            oldValue?.removeFromSuperview()
            if let footerView { content.addSubview(footerView) }
            relayout(geometry: false, anchor: stickyAnchor ?? layout.leadingAnchor(in: viewport))
        }
    }
    var footerLength = 200.0

    var imageSource: CanvasImageSource {
        get { loader.source }
        set { if newValue != loader.source { reloadImages(pipeline: loader.pipeline, source: newValue) } }
    }

    private(set) var items: [CanvasItem] = []
    private(set) var selection: Set<Int> = []
    private(set) var visibleRange = CanvasVisibleRange(visible: 0..<0, margin: 0..<0)

    /// 滚动停止或可见项变化后（去抖）回报，交给 `ReaderSession.visibleRangeChanged` 或面板的预取计划。
    var onVisibleRangeChange: ((CanvasVisibleRange) -> Void)?
    var onSelectionChange: ((Set<Int>) -> Void)?
    /// 双击或回车。
    var onActivate: ((Int) -> Void)?
    /// 双击；没有设置时走 `onActivate`。
    var onDoubleClick: ((Int) -> Void)?
    /// 捏合缩放改了 `itemExtent`。
    var onItemExtentChange: ((Double) -> Void)?
    var onMeasure: ((CanvasMeasure) -> Void)?

    private struct Tile {
        let layer: CALayer
        let identity: ContentIdentity
    }

    private let content: CanvasDocumentView
    private let loader: CanvasImageLoader
    private var layout: CollectionLayout
    private var ratios: [Double?] = []
    private var tiles: [Int: Tile] = [:]
    private var tileIndex: [ContentIdentity: Int] = [:]
    private var spare: [CALayer] = []
    /// 上一次处理过的视口；视口尺寸变化时用它取锚点。
    private var viewport = CGRect.zero
    /// 连续的重排（拖动窗口尺寸、捏合）共用最初的锚点，用户滚动后清除。
    private var stickyAnchor: LayoutAnchor?
    private var isRelayingOut = false
    private var focus: Int?
    private var reportedRange: CanvasVisibleRange?
    private var lastMotion = ContinuousClock.now
    /// 去抖用的计时器：每次更新把触发时间推后，停止 `settleDelay` 秒后触发一次。
    private var settleTimer: Timer?
    private var counts = CanvasCounters()
    private let signposter = OSSignposter(category: .layout)
    private lazy var errorImage = Self.makeErrorImage()
    private static let settleDelay = 0.05

    init(pipeline: any ImagePipeline, kind: CollectionLayoutKind, imageSource: CanvasImageSource, itemExtent: Double = 220, direction: ReadingDirection = .leftToRight) {
        self.kind = kind
        self.direction = direction
        self.itemExtent = itemExtent
        layout = CollectionLayout(kind: kind, viewportSize: .zero, itemExtent: itemExtent, spacing: 8, direction: direction)
        let content = CanvasDocumentView()
        self.content = content
        loader = CanvasImageLoader(pipeline: pipeline, source: imageSource, view: content)
        super.init(frame: .zero)
        loader.onReady = { [unowned self] identity, image in
            guard let index = tileIndex[identity], let tile = tiles[index] else { return false }
            tile.layer.contentsGravity = contentGravity
            tile.layer.contents = image.contents
            return true
        }
        loader.onFailure = { [unowned self] identity in
            if let index = tileIndex[identity], let tile = tiles[index] { showError(on: tile.layer) }
        }

        content.canvas = self
        drawsBackground = false
        autohidesScrollers = true
        allowsMagnification = false
        documentView = content
        configureScrollers()
        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged(_:)), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged(_:)), name: NSView.frameDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if DEBUG
    override class var isCompatibleWithResponsiveScrolling: Bool { !SyntheticScroll.isInUse }
    #endif

    var counters: CanvasCounters {
        var counters = counts
        counters.activeLayers = tiles.count
        counters.loadedImages = loader.loadedImages
        counters.inFlight = loader.inFlight
        return counters
    }

    // MARK: - 数据

    /// 换一组项。前面的项不变（只追加项或补上宽高比）时，已排的项不动；否则视为整体重排，按身份保留选中项并以它为锚点。
    func setItems(_ newItems: [CanvasItem]) {
        let appended = newItems.count >= items.count && zip(items, newItems).allSatisfy { $0.identity == $1.identity || $0.isPending }
        var anchor: LayoutAnchor?
        if appended {
            anchor = stickyAnchor ?? layout.leadingAnchor(in: viewport)
            // 已分配的项：身份变了的重新分配，其余只更新角标和标题。
            recycle(tiles.compactMap { index, tile in newItems[index].identity == tile.identity ? nil : index })
            for (index, tile) in tiles where newItems[index] != items[index] {
                setOverlays(newItems[index], on: tile.layer)
            }
        } else {
            var newIndex: [ContentIdentity: Int] = [:]
            newIndex.reserveCapacity(newItems.count)
            for (index, item) in newItems.enumerated() where newIndex[item.identity] == nil {
                newIndex[item.identity] = index
            }
            if let old = layout.reorderAnchor(in: viewport, selected: focus.flatMap { selection.contains($0) ? $0 : nil } ?? selection.min()),
               old.index < items.count, let index = newIndex[items[old.index].identity] {
                anchor = LayoutAnchor(index: index, offset: old.offset, extent: old.extent)
            }
            selection = Set(selection.compactMap { newIndex[items[$0].identity] })
            focus = focus.flatMap { newIndex[items[$0].identity] }
            stickyAnchor = nil
            recycle(Array(tiles.keys))
            onSelectionChange?(selection)
        }
        items = newItems
        ratios = newItems.map(\.aspectRatio)
        relayout(geometry: false, anchor: anchor)
    }

    /// 把一项滚到视口开头。这一项还没排时返回 false。
    @discardableResult
    func scrollTo(index: Int) -> Bool {
        guard index < layout.count, let origin = layout.viewportOrigin(restoring: LayoutAnchor(index: index, offset: spacing, extent: 0)) else { return false }
        isRelayingOut = true
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        isRelayingOut = false
        stickyAnchor = nil
        updateVisible(scrolled: false)
        return true
    }

    /// 已排的项数（不含条的末尾）。
    var placedCount: Int {
        min(layout.count, items.count)
    }

    func frame(of index: Int) -> CGRect? {
        layout.frame(of: index)
    }

    /// 重试全部失败的项；返回是否有失败的项。
    @discardableResult
    func retryFailed() -> Bool {
        var failed = false
        for item in items {
            if case .failed = loader.state(of: item.identity) {
                loader.retry(item.identity)
                failed = true
            }
        }
        guard failed else { return false }
        for (index, tile) in tiles {
            tile.layer.contents = loader.cached(tile.identity)?.contents
            tile.layer.contentsGravity = contentGravity
            request(index, frame: tile.layer.frame, priority: tile.layer.frame.intersects(viewport) ? .visible : .near)
        }
        return true
    }

    /// 窗口上正显示为失败的项。
    var failedCount: Int {
        tiles.values.reduce(0) { count, tile in
            if case .failed = loader.state(of: tile.identity) { return count + 1 }
            return count
        }
    }

    func cachedContents(at index: Int) -> Any? {
        guard items.indices.contains(index) else { return nil }
        return tiles[index]?.layer.contents
    }

    /// 换管线：丢掉缓存和进行中的请求，可见项重新加载。
    func replacePipeline(_ pipeline: any ImagePipeline) {
        reloadImages(pipeline: pipeline, source: loader.source)
    }

    private func reloadImages(pipeline: any ImagePipeline, source: CanvasImageSource) {
        loader.reset(pipeline: pipeline, source: source)
        recycle(Array(tiles.keys))
        updateVisible(scrolled: false)
    }

    // MARK: - 排版

    private func configurationChanged() {
        configureScrollers()
        relayoutKeepingLeading()
    }

    /// 按当前视口和配置重排，保持可见区前沿的项；连续的重排共用最初的锚点。
    private func relayoutKeepingLeading() {
        let anchor = stickyAnchor ?? layout.leadingAnchor(in: viewport)
        stickyAnchor = anchor
        relayout(geometry: true, anchor: anchor)
    }

    private func configureScrollers() {
        hasVerticalScroller = !kind.isHorizontal
        hasHorizontalScroller = kind.isHorizontal
        verticalScrollElasticity = kind.isHorizontal ? .none : .automatic
        horizontalScrollElasticity = kind.isHorizontal ? .automatic : .none
    }

    private var contentGravity: CALayerContentsGravity {
        kind == .grid ? .resizeAspect : .resizeAspectFill
    }

    /// 条的末尾在布局里占一项：所有项都已知才排到，宽高比按视口换算。
    private var footerRatio: [Double?] {
        guard footerView != nil, kind.isHorizontal || kind == .verticalStrip else { return [] }
        let size = contentView.bounds.size
        let cross = max(1, min(itemExtent, (kind.isHorizontal ? size.height : size.width) - spacing * 2))
        return [kind.isHorizontal ? footerLength / cross : cross / footerLength]
    }

    /// `geometry` 为 true 时按当前视口和配置新建布局，否则只在原布局上更新宽高比（已排的项不动）。
    private func relayout(geometry: Bool, anchor: LayoutAnchor?) {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("relayout")
        isRelayingOut = true
        if geometry {
            layout = CollectionLayout(kind: kind, viewportSize: contentView.bounds.size, itemExtent: itemExtent, spacing: spacing, direction: direction)
        }
        layout.setAspectRatios(ratios + footerRatio)
        content.setFrameSize(layout.contentSize)
        footerView?.isHidden = layout.count <= items.count
        if let footerView, let frame = layout.frame(of: items.count) { footerView.frame = frame }
        // 没有可见项可作锚点时（初次排版），停在第 0 项；右开的横向条因此从右端开始。
        let target = anchor ?? LayoutAnchor(index: 0, offset: spacing, extent: 0)
        if let origin = layout.viewportOrigin(restoring: target), origin != contentView.bounds.origin {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in tiles {
            if let frame = layout.frame(of: index) {
                tile.layer.frame = frame
                positionOverlays(in: tile.layer)
                // 错误标记居中显示，不随布局换填充方式。
                if tile.layer.contentsGravity != .center {
                    tile.layer.contentsGravity = contentGravity
                }
            } else {
                recycle([index])
            }
        }
        CATransaction.commit()
        isRelayingOut = false
        signposter.endInterval("relayout", state)
        onMeasure?(.relayout(ContinuousClock.now - start))
        if let anchor, let frame = layout.frame(of: anchor.index) {
            counts.anchoredRelayouts += 1
            if !frame.intersects(contentView.bounds) { counts.anchorMisses += 1 }
        }
        updateVisible(scrolled: false)
    }

    @objc private func clipChanged(_ notification: Notification) {
        guard !isRelayingOut else { return }
        if contentView.bounds.size != layout.viewportSize {
            relayoutKeepingLeading()
        } else if contentView.bounds.origin != viewport.origin {
            stickyAnchor = nil
            updateVisible(scrolled: true)
        }
    }

    // MARK: - 图层分配

    /// 按当前可见区分配图层。滚动时每帧调用。
    private func updateVisible(scrolled: Bool) {
        let start = ContinuousClock.now
        let state = signposter.beginInterval("updateVisible")
        let visibleRect = contentView.bounds
        viewport = visibleRect
        let marginRect = kind.isHorizontal ? visibleRect.insetBy(dx: -visibleRect.width, dy: 0) : visibleRect.insetBy(dx: 0, dy: -visibleRect.height)
        let wanted = layout.items(in: marginRect)
        var wantedSet = Set<Int>(minimumCapacity: wanted.count)
        for item in wanted {
            wantedSet.insert(item.index)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recycle(tiles.keys.filter { !wantedSet.contains($0) })
        var visible = (low: Int.max, high: Int.min)
        var margin = (low: Int.max, high: Int.min)
        for (index, frame) in wanted where index < items.count {
            let isVisible = frame.intersects(visibleRect)
            if isVisible {
                visible = (min(visible.low, index), max(visible.high, index))
            }
            margin = (min(margin.low, index), max(margin.high, index))
            if tiles[index] == nil {
                assign(index, frame: frame, priority: isVisible ? .visible : .near)
            }
        }
        CATransaction.commit()
        visibleRange = CanvasVisibleRange(
            visible: visible.low <= visible.high ? visible.low..<(visible.high + 1) : 0..<0,
            margin: margin.low <= margin.high ? margin.low..<(margin.high + 1) : 0..<0
        )
        counts.peakLayers = max(counts.peakLayers, tiles.count)
        signposter.endInterval("updateVisible", state)
        if scrolled {
            onMeasure?(.scroll(ContinuousClock.now - start))
        }
        lastMotion = start
        scheduleSettle()
    }

    private func assign(_ index: Int, frame: CGRect, priority: IOPriority) {
        let identity = items[index].identity
        let layer = spare.popLast() ?? makeLayer()
        layer.frame = frame
        layer.isHidden = false
        layer.borderWidth = selection.contains(index) ? 3 : 0
        switch loader.state(of: identity) {
        case .failed:
            showError(on: layer)
        case .idle, .loading, .loaded:
            layer.contentsGravity = contentGravity
            layer.contents = loader.cached(identity)?.contents
        }
        setOverlays(items[index], on: layer)
        tiles[index] = Tile(layer: layer, identity: identity)
        tileIndex[identity] = index
        request(index, frame: frame, priority: priority)
    }

    private func recycle(_ indices: [Int]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in indices {
            guard let tile = tiles.removeValue(forKey: index) else { continue }
            tileIndex[tile.identity] = nil
            tile.layer.isHidden = true
            tile.layer.contents = nil
            tile.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            spare.append(tile.layer)
            loader.cancel(tile.identity)
        }
        CATransaction.commit()
    }

    private func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer.borderColor = Theme.accent.cgColor
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.contentsScale = window?.backingScaleFactor ?? 2
        content.layer?.addSublayer(layer)
        counts.createdLayers += 1
        return layer
    }

    private func setOverlays(_ item: CanvasItem, on layer: CALayer) {
        setOverlay("badge", text: item.badge, on: layer) { overlay in
            overlay.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            overlay.alignmentMode = .center
            overlay.cornerRadius = 4
        }
        setOverlay("label", text: item.label, on: layer) { overlay in
            overlay.font = NSFont.systemFont(ofSize: 11)
            overlay.alignmentMode = .left
            overlay.truncationMode = .end
        }
        positionOverlays(in: layer)
    }

    private func setOverlay(_ name: String, text: String?, on layer: CALayer, configure: (CATextLayer) -> Void) {
        let existing = layer.sublayers?.first { $0.name == name } as? CATextLayer
        guard let text else {
            existing?.removeFromSuperlayer()
            return
        }
        let overlay = existing ?? {
            let overlay = CATextLayer()
            overlay.name = name
            overlay.fontSize = 11
            overlay.foregroundColor = NSColor.white.cgColor
            overlay.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            overlay.contentsScale = window?.backingScaleFactor ?? 2
            configure(overlay)
            layer.addSublayer(overlay)
            return overlay
        }()
        overlay.string = text
    }

    private func positionOverlays(in layer: CALayer) {
        for overlay in layer.sublayers ?? [] {
            guard let overlay = overlay as? CATextLayer else { continue }
            if overlay.name == "label" {
                overlay.frame = CGRect(x: 0, y: layer.bounds.height - 18, width: layer.bounds.width, height: 18)
            } else if let text = overlay.string as? String {
                let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width) + 10
                let bottom = layer.sublayers?.contains { $0.name == "label" } == true ? 18.0 : 0
                overlay.frame = CGRect(x: layer.bounds.width - width - 6, y: layer.bounds.height - bottom - 22, width: width, height: 16)
            }
        }
    }

    private func showError(on layer: CALayer) {
        layer.contentsGravity = .center
        layer.contents = errorImage
    }

    /// 按项在屏幕上的像素尺寸请求。显示图要宽高比才能定目标尺寸；网格的单元是正方形，按宽高比放进单元。
    @discardableResult
    private func request(_ index: Int, frame: CGRect, priority: IOPriority) -> Bool {
        guard !items[index].isPending else { return false }
        let scale = window?.backingScaleFactor ?? 2
        let size = PixelSize(width: Int((frame.width * scale).rounded(.up)), height: Int((frame.height * scale).rounded(.up)))
        let longSide = max(size.width, size.height)
        var target: PixelSize?
        if loader.source == .display, let ratio = items[index].aspectRatio {
            if kind == .grid {
                target = ratio >= 1
                    ? PixelSize(width: longSide, height: max(1, Int((Double(longSide) / ratio).rounded())))
                    : PixelSize(width: max(1, Int((Double(longSide) * ratio).rounded())), height: longSide)
            } else {
                target = size
            }
        }
        return loader.request(items[index].identity, longSide: longSide, target: target, priority: priority)
    }

    private func scheduleSettle() {
        guard window != nil else { return }
        if settleTimer == nil {
            // 重复间隔取很大的值：触发一次后等下一次推后，不再自己触发。
            let timer = Timer(timeInterval: 1e9, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        }
        settleTimer?.fireDate = Date(timeIntervalSinceNow: Self.settleDelay)
    }

    /// 滚动停止：统计可见项请求的发出时间，补发缺少的和尺寸变大后不够清晰的请求，回报可见范围。
    private func settle() {
        var latency = Duration.zero
        var visibleCount = 0
        for (index, tile) in tiles where tile.layer.frame.intersects(viewport) {
            visibleCount += 1
            switch loader.state(of: tile.identity) {
            case let .loading(since):
                latency = max(latency, since - lastMotion)
            case .idle:
                if request(index, frame: tile.layer.frame, priority: .visible) {
                    latency = max(latency, ContinuousClock.now - lastMotion)
                }
            case .loaded, .failed:
                break
            }
        }
        for (index, tile) in tiles {
            request(index, frame: tile.layer.frame, priority: tile.layer.frame.intersects(viewport) ? .visible : .near)
        }
        signposter.emitEvent("settled", "visible \(visibleCount) latency \(latency.milliseconds, format: .fixed(precision: 3)) ms")
        onMeasure?(.settled(latency: latency, visible: visibleCount))
        if visibleRange != reportedRange {
            reportedRange = visibleRange
            onVisibleRangeChange?(visibleRange)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            settleTimer?.invalidate()
            settleTimer = nil
            loader.stop()
        } else {
            updateVisible(scrolled: false)
        }
    }

    // MARK: - 交互

    func select(_ indices: Set<Int>, focus: Int?) {
        selection = indices
        self.focus = focus
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in tiles {
            tile.layer.borderWidth = selection.contains(index) ? 3 : 0
        }
        CATransaction.commit()
        onSelectionChange?(selection)
    }

    /// 点击选中，⌘ 切换，⇧ 从焦点项选到点击项；双击激活。点到失败的项时重试。
    fileprivate func click(_ event: NSEvent) {
        window?.makeFirstResponder(content)
        let point = content.convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let index = layout.items(in: CGRect(x: point.x, y: point.y, width: 1, height: 1)).first(where: { $0.frame.contains(point) })?.index, index < items.count else {
            if !flags.contains(.command), !flags.contains(.shift) { select([], focus: nil) }
            return
        }
        if event.clickCount == 2 {
            (onDoubleClick ?? onActivate)?(index)
            return
        }
        if case .failed = loader.state(of: items[index].identity), let tile = tiles[index] {
            loader.retry(tile.identity)
            tile.layer.contents = nil
            request(index, frame: tile.layer.frame, priority: .visible)
        }
        if activatesOnSingleClick {
            onActivate?(index)
        } else if flags.contains(.command) {
            var next = selection
            if next.remove(index) == nil { next.insert(index) }
            select(next, focus: index)
        } else if flags.contains(.shift), let focus {
            select(Set(min(focus, index)...max(focus, index)), focus: focus)
        } else {
            select([index], focus: index)
        }
    }

    /// 方向键按画面上的位置移动选中项，回车激活。其余按键交给响应链。
    fileprivate func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty, let key = event.specialKey else { return false }
        if !arrowKeysMoveSelection {
            guard !kind.isHorizontal, key == .upArrow || key == .downArrow else { return false }
            let line = key == .upArrow ? -verticalLineScroll * 3 : verticalLineScroll * 3
            contentView.scroll(to: CGPoint(x: 0, y: min(max(contentView.bounds.minY + line, 0), max(0, content.frame.height - contentView.bounds.height))))
            reflectScrolledClipView(contentView)
            return true
        }
        let move: LayoutMove
        switch key {
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .leftArrow: move = .left
        case .rightArrow: move = .right
        case .carriageReturn, .enter:
            if let focus { onActivate?(focus) }
            return focus != nil
        default: return false
        }
        guard let current = focus ?? layout.leadingAnchor(in: viewport)?.index else { return true }
        let next = min(focus == nil ? current : layout.index(moving: current, move) ?? current, max(items.count - 1, 0))
        select([next], focus: next)
        if let frame = layout.frame(of: next) {
            content.scrollToVisible(frame.insetBy(dx: -spacing, dy: -spacing))
        }
        return true
    }

    /// 捏合改缩略图尺寸，锚点不动。
    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification)
    }

    func zoom(by factor: Double) {
        // 条的尺寸可以是“适合视口”的无穷大：从实际的横截长度开始缩放。
        let cross = kind.isHorizontal ? contentView.bounds.height : contentView.bounds.width
        let extent = min(max(min(itemExtent, cross) * factor, itemExtentRange.lowerBound), itemExtentRange.upperBound)
        guard extent != itemExtent else { return }
        itemExtent = extent
        onItemExtentChange?(extent)
    }

    private static func makeErrorImage() -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
        guard let symbol = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        var rect = NSRect(x: 0, y: 0, width: symbol.size.width * 2, height: symbol.size.height * 2)
        return symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) * 1e-15
    }
}

/// 画布的文档视图：只承载图层，把鼠标和按键交给画布。
private final class CanvasDocumentView: NSView {
    weak var canvas: CanvasView?

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
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        canvas?.click(event)
    }

    override func keyDown(with event: NSEvent) {
        if canvas?.key(event) != true {
            super.keyDown(with: event)
        }
    }
}
