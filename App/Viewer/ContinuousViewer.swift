import AppKit
import MVFoundation
import MVLayout
import MVMedia
import MVPipeline
import MVReading
import MVSettings

/// 纵向连续、横向连续和主区瀑布流：在画布引擎上显示整本书。
///
/// 打开到第 k 页时，先等前 k 页的尺寸（布局只排已知宽高比的最长前缀），期间显示定位进度，到位后滚到这一页。
@MainActor
final class ContinuousViewer: NSView {
    private let session: ReaderSession
    private let bookshelf: any Bookshelf
    let canvas: CanvasView
    private let progress = PillLabel()
    private let scaleLabel = PillLabel()
    private let pageLabel = PillLabel()
    private let footer = StripFooterView()
    /// 正在定位到的页；定位期间不回报可见范围。
    private var targetPage: Int?
    /// 滚到某一页时的可见范围：范围没变就是还没滚动，当前页不跟着变成可见区的第一项。
    private var pinned: (page: Int, visible: Range<Int>)?
    /// 查看器最后知道的当前页；会话的当前页和它不同时是翻页命令移动的。
    private var knownPage: Int?
    private var book: Location?
    private var mode: BrowseMode?
    private var neighborTask: Task<Void, Never>?
    private var neighborFor: Location?
    /// 瀑布流的列宽，工具栏的滑块和捏合都改它。
    var waterfallExtent = 220.0 {
        didSet {
            if mode == .waterfall { canvas.itemExtent = waterfallExtent }
            onWaterfallExtentChange?()
        }
    }
    var onWaterfallExtentChange: (() -> Void)?
    /// 单击瀑布流的页、条里的视频：进入分页；悬停预览视频时带上目标起播时间。
    var onEnterPaged: ((Int, Double?) -> Void)?
    /// 虚拟书的占位页与分页模式共用原因和操作。
    var unavailableReason: ((Location) -> UnavailablePageView.Reason)?
    var onPageFailure: ((Location) -> Void)?
    var onRemoveUnavailable: ((Location) -> Void)?
    private var placeholders: [Location: UnavailablePageView] = [:]
    private var appliedEffects: EffectChain = .empty
    private var resolvedPluginFilters: ResolvedPluginFilters = .empty
    weak var pluginFilterActivity: PluginFilterActivity?
    var onPluginFilterFailure: ((String, String) -> Void)?

    init(session: ReaderSession, pipeline: any ImagePipeline, settings: any SettingsStore, bookshelf: any Bookshelf) {
        self.session = session
        self.bookshelf = bookshelf
        canvas = CanvasView(pipeline: pipeline, settings: settings, kind: .masonry, imageSource: .display)
        super.init(frame: .zero)
        canvas.activatesOnSingleClick = true
        canvas.arrowKeysMoveSelection = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        for view in [progress, scaleLabel, pageLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor), canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor), canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor), progress.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scaleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), scaleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            pageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), pageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        progress.isHidden = true
        canvas.onVisibleRangeChange = { [weak self] range in self?.visibleChanged(range.visible) }
        canvas.onActivate = { [weak self] index in self?.activate(index) }
        canvas.onImageFailure = { [weak self] location in
            self?.onPageFailure?(location)
            self?.updatePlaceholders()
        }
        canvas.onItemExtentChange = { [weak self] extent in
            if self?.mode == .waterfall { self?.waterfallExtent = extent }
        }
        canvas.onPluginFilterStateChange = { [weak self] states, failure in
            self?.syncFilterActivity(states, failure: failure)
        }
        footer.onNext = { [weak self] in
            Task { await self?.openNext() }
        }
        footer.onRetry = { [weak self] in
            guard let self, let current = session.book else { return }
            loadNeighbor(of: current.location)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        canvas.layoutSubtreeIfNeeded()
        updatePlaceholders()
    }

    /// 会话状态变化后调用。
    func refresh() {
        guard let current = session.book else {
            leave()
            return
        }
        let settings = session.settings
        if mode != settings.browseMode || book != current.location {
            mode = settings.browseMode
            book = current.location
            configure(settings)
            targetPage = session.currentPage
            pinned = nil
            knownPage = nil
            canvas.setItems([])
            footer.reset()
            neighborTask?.cancel()
            neighborFor = nil
        }
        canvas.direction = settings.direction
        layoutSubtreeIfNeeded()
        // 虚拟书里不可用的页：不请求图、不显示缓存里的旧图，显示错误标记和原因。
        let unavailable = session.isVirtualBook ? session.unavailablePages : []
        let items = current.pages.map { page -> CanvasItem in
            let isUnavailable = unavailable.contains(page.id)
            let isEligible: Bool = {
                guard !isUnavailable, page.entry.kind == .image, let meta = page.metadata else { return false }
                return meta.frameCount <= 1 && !ImageDecoder.needsTiling(meta.pixelSize, maxDecodeLongSide: session.maxDecodeLongSide)
            }()
            return CanvasItem(
                identity: page.entry.identity,
                aspectRatio: page.metadata.flatMap { $0.pixelSize.height > 0 && $0.pixelSize.width > 0 ? Double($0.pixelSize.width) / Double($0.pixelSize.height) : nil },
                badge: page.entry.kind == .video && !isUnavailable ? page.metadata?.duration.map(Self.duration) : nil,
                isFailed: isUnavailable,
                failureText: nil,
                isVideo: page.entry.kind == .video && !isUnavailable,
                isPluginFilterEligible: isEligible
            )
        }
        if items != canvas.items { canvas.setItems(items) }
        updatePlaceholders()
        updateFooter(current)
        position(current)
        scaleLabel.isHidden = settings.browseMode == .waterfall
        scaleLabel.text = settings.browseMode == .verticalStrip ? String(localized: "适合宽度") : String(localized: "适合高度")
        let page = min(knownPage ?? session.currentPage, max(current.pages.count - 1, 0))
        pageLabel.text = current.pages.isEmpty ? "" : "\(page + 1) / \(current.pages.count)"
        pageLabel.isHidden = current.pages.isEmpty
    }

    /// 主视图画布的实时效果滤镜；只在链变化时替换。
    func setEffects(_ chain: EffectChain) {
        guard chain != appliedEffects else { return }
        appliedEffects = chain
        canvas.setEffectFilters(EffectFilters.filters(for: chain))
    }

    func setPluginFilters(_ filters: ResolvedPluginFilters) {
        guard filters != resolvedPluginFilters else { return }
        resolvedPluginFilters = filters
        canvas.setPluginFilters(filters)
        if filters.isEmpty {
            pluginFilterActivity?.reset()
        }
    }

    private func syncFilterActivity(_ itemStates: [ContentIdentity: PluginFilterActivity.State], failure: String?) {
        guard let activity = pluginFilterActivity else { return }
        guard !resolvedPluginFilters.isEmpty else {
            activity.reset()
            return
        }
        let combined: PluginFilterActivity.State
        if itemStates.values.contains(.running) {
            combined = .running
        } else if let failedMsg = itemStates.values.compactMap({ state -> String? in
            if case let .failed(msg) = state { return msg }
            return nil
        }).first {
            combined = .failed(failedMsg)
        } else {
            combined = .idle
        }
        var next: [String: PluginFilterActivity.State] = [:]
        for req in resolvedPluginFilters.requests {
            next[PluginFilterActivity.key(plugin: req.plugin, filter: req.filter)] = combined
        }
        activity.update(next, names: resolvedPluginFilters.names)
        if let failure {
            let pluginName = resolvedPluginFilters.requests.first.flatMap { resolvedPluginFilters.pluginNames[$0.plugin] ?? $0.plugin } ?? ""
            onPluginFilterFailure?(pluginName, failure)
        }
    }

    /// 离开连续模式：停掉请求。回来时重新定位。
    func leave() {
        guard mode != nil else { return }
        mode = nil
        book = nil
        targetPage = nil
        pinned = nil
        knownPage = nil
        canvas.footerView = nil
        canvas.setItems([])
        placeholders.values.forEach { $0.removeFromSuperview() }
        placeholders = [:]
        neighborTask?.cancel()
    }

    private func configure(_ settings: ResolvedBookSettings) {
        canvas.footerView = nil
        switch settings.browseMode {
        case .waterfall:
            canvas.spacing = 8
            canvas.itemExtentRange = 120...640
            canvas.itemExtent = waterfallExtent
            canvas.kind = .masonry
        case .verticalStrip, .horizontalStrip, .paged:
            canvas.spacing = 0
            canvas.itemExtentRange = 240...4096
            canvas.itemExtent = .infinity
            canvas.kind = settings.browseMode == .horizontalStrip ? .horizontalStrip : .verticalStrip
        }
    }

    // MARK: 定位

    private func position(_ current: Book) {
        if let target = targetPage {
            let wanted = min(target, max(current.pages.count - 1, 0))
            if canvas.placedCount > wanted {
                targetPage = nil
                progress.isHidden = true
                scroll(to: wanted)
            } else if current.isEnumerated, current.pages.isEmpty {
                targetPage = nil
                progress.isHidden = true
            } else {
                progress.isHidden = false
                progress.text = String(localized: "正在定位到第 \(wanted + 1) 页 · 已读取 \(canvas.placedCount) / \(wanted + 1) 页的尺寸")
            }
            return
        }
        // 翻页命令移动了会话的当前页。
        if let known = knownPage, session.currentPage != known, canvas.placedCount > session.currentPage {
            scroll(to: session.currentPage)
        }
    }

    private func scroll(to page: Int) {
        canvas.scrollTo(index: page)
        knownPage = page
        pinned = (page, canvas.visibleRange.visible)
    }

    private func visibleChanged(_ visible: Range<Int>) {
        updatePlaceholders()
        guard targetPage == nil, !visible.isEmpty else { return }
        if let pin = pinned, pin.visible == visible { return }
        pinned = nil
        knownPage = visible.lowerBound
        session.visibleRangeChanged(visible)
        if let count = session.book?.pages.count { pageLabel.text = "\(visible.lowerBound + 1) / \(count)" }
    }

    private func activate(_ index: Int) {
        guard let pages = session.book?.pages, pages.indices.contains(index) else { return }
        if session.settings.browseMode == .waterfall || pages[index].entry.kind == .video {
            let isKeyboard = NSApp.currentEvent?.type == .keyDown
            let videoStart = (!isKeyboard && pages[index].entry.kind == .video) ? canvas.previewTime(at: index) : nil
            onEnterPaged?(index, videoStart)
        }
    }

    /// 只给可见的失败页放真实控件；瀑布流和长条均能直接移除或连接。
    private func updatePlaceholders() {
        guard session.isVirtualBook, let pages = session.book?.pages, let document = canvas.documentView else {
            placeholders.values.forEach { $0.removeFromSuperview() }
            placeholders = [:]
            return
        }
        var wanted: Set<Location> = []
        for index in canvas.visibleRange.visible where pages.indices.contains(index) && canvas.isFailed(at: index) {
            guard let frame = canvas.frame(of: index) else { continue }
            let location = pages[index].id
            wanted.insert(location)
            let view = placeholders[location] ?? UnavailablePageView()
            if view.superview == nil { document.addSubview(view) }
            view.show(unavailableReason?(location) ?? .failed(String(localized: "无法读取原文件")))
            view.onRemove = { [weak self] in self?.onRemoveUnavailable?(location) }
            view.frame = frame
            placeholders[location] = view
        }
        for (location, view) in placeholders where !wanted.contains(location) {
            view.removeFromSuperview()
            placeholders[location] = nil
        }
    }

    // MARK: 条的末尾

    /// 虚拟书显示列表名 · 完，没有下一本。
    private func updateFooter(_ current: Book) {
        guard session.settings.browseMode != .waterfall, current.isEnumerated, !current.pages.isEmpty else {
            canvas.footerView = nil
            return
        }
        if let playlist = current.location.playlistID {
            footer.showBook(name: LibraryActions.playlists.first { $0.id == playlist }?.name ?? String(localized: "播放列表"))
        } else {
            footer.showBook(name: current.location.name)
        }
        if canvas.footerView == nil { canvas.footerView = footer }
        guard current.location.playlistID == nil, neighborFor != current.location else { return }
        loadNeighbor(of: current.location)
    }

    /// 查书架上的下一本。读取失败时在末尾显示错误和重试，不当成没有下一本。
    private func loadNeighbor(of location: Location) {
        neighborFor = location
        neighborTask?.cancel()
        footer.reset()
        let bookshelf = bookshelf
        let sort = session.neighborSort
        neighborTask = Task { [weak self] in
            do {
                let next = try await bookshelf.neighbor(of: location, .forward, sort: sort)
                guard !Task.isCancelled else { return }
                self?.footer.showNext(name: next?.name)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.footer.showFailure(ErrorText.describe(error))
            }
        }
    }

    private func openNext() async {
        await session.openNeighborBook(.forward, sort: session.neighborSort)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 浮在内容上的小标签。
@MainActor
final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        label.font = Theme.font(.overlays, size: 12)
        label.textColor = Theme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        label.font = Theme.font(.overlays, size: 12)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
    }
}

/// 条的末尾：书名 · 完，和下一本的按钮；查下一本失败时是错误文字和重试按钮。
@MainActor
private final class StripFooterView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let button = FlatButton(font: Theme.font(.overlays, size: 13, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 8, height: 32, padding: 14)
    private var isFailure = false
    var onNext: (() -> Void)?
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.font = Theme.serif(22)
        title.textColor = Theme.text
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        failure.font = Theme.font(.overlays, size: 12)
        failure.textColor = Theme.danger
        failure.alignment = .center
        failure.isHidden = true
        button.target = self
        button.action = #selector(buttonPressed)
        button.isHidden = true
        let stack = NSStackView(views: [title, failure, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        failure.font = Theme.font(.overlays, size: 12)
        button.applyFont(Theme.font(.overlays, size: 13, weight: .semibold))
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        button.isHidden = true
        failure.isHidden = true
    }

    func showBook(name: String) {
        title.stringValue = String(localized: "\(name) · 完")
    }

    func showNext(name: String?) {
        isFailure = false
        failure.isHidden = true
        button.isHidden = name == nil
        if let name { button.setText(String(localized: "下一本：\(name)")) }
    }

    func showFailure(_ message: String) {
        isFailure = true
        failure.stringValue = message
        failure.isHidden = false
        button.isHidden = false
        button.setText(String(localized: "重试"))
    }

    @objc private func buttonPressed() {
        isFailure ? onRetry?() : onNext?()
    }
}
