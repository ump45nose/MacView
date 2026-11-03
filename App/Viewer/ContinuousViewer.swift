import AppKit
import MVFoundation
import MVLayout
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
    private let pageLabel = NSTextField(labelWithString: "")
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
    /// 单击瀑布流的页、条里的视频：进入分页。
    var onEnterPaged: ((Int) -> Void)?

    init(session: ReaderSession, pipeline: any ImagePipeline, bookshelf: any Bookshelf) {
        self.session = session
        self.bookshelf = bookshelf
        canvas = CanvasView(pipeline: pipeline, kind: .masonry, imageSource: .display)
        super.init(frame: .zero)
        canvas.activatesOnSingleClick = true
        canvas.arrowKeysMoveSelection = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        pageLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        pageLabel.textColor = Theme.text2
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
        canvas.onItemExtentChange = { [weak self] extent in
            if self?.mode == .waterfall { self?.waterfallExtent = extent }
        }
        footer.onNext = { [weak self] in
            Task { await self?.openNext() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

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
            neighborFor = nil
        }
        canvas.direction = settings.direction
        layoutSubtreeIfNeeded()
        let items = current.pages.map { page -> CanvasItem in
            CanvasItem(
                identity: page.entry.identity,
                aspectRatio: page.metadata.flatMap { $0.pixelSize.height > 0 && $0.pixelSize.width > 0 ? Double($0.pixelSize.width) / Double($0.pixelSize.height) : nil },
                badge: page.entry.kind == .video ? page.metadata?.duration.map(Self.duration) : nil
            )
        }
        if items != canvas.items { canvas.setItems(items) }
        updateFooter(current)
        position(current)
        scaleLabel.isHidden = settings.browseMode == .waterfall
        scaleLabel.text = settings.browseMode == .verticalStrip ? String(localized: "适合宽度") : String(localized: "适合高度")
        let page = min(knownPage ?? session.currentPage, max(current.pages.count - 1, 0))
        pageLabel.stringValue = current.pages.isEmpty ? "" : "\(page + 1) / \(current.pages.count)"
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
        guard targetPage == nil, !visible.isEmpty else { return }
        if let pin = pinned, pin.visible == visible { return }
        pinned = nil
        knownPage = visible.lowerBound
        session.visibleRangeChanged(visible)
        if let count = session.book?.pages.count { pageLabel.stringValue = "\(visible.lowerBound + 1) / \(count)" }
    }

    private func activate(_ index: Int) {
        guard let pages = session.book?.pages, pages.indices.contains(index) else { return }
        if session.settings.browseMode == .waterfall || pages[index].entry.kind == .video {
            onEnterPaged?(index)
        }
    }

    // MARK: 条的末尾

    private func updateFooter(_ current: Book) {
        guard session.settings.browseMode != .waterfall, current.isEnumerated, !current.pages.isEmpty else {
            canvas.footerView = nil
            return
        }
        footer.showBook(name: current.location.name)
        if canvas.footerView == nil { canvas.footerView = footer }
        guard neighborFor != current.location else { return }
        neighborFor = current.location
        neighborTask?.cancel()
        let bookshelf = bookshelf
        let location = current.location
        let sort = session.neighborSort
        neighborTask = Task { [weak self] in
            let next = try? await bookshelf.neighbor(of: location, .forward, sort: sort)
            guard !Task.isCancelled else { return }
            self?.footer.showNext(name: next?.name)
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
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
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

/// 条的末尾：书名 · 完，和下一本的按钮。
@MainActor
private final class StripFooterView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let button = FlatButton(font: .systemFont(ofSize: 13, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 8, height: 32, padding: 14)
    var onNext: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.font = Theme.serif(22)
        title.textColor = Theme.text
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        button.target = self
        button.action = #selector(next)
        button.isHidden = true
        let stack = NSStackView(views: [title, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        button.isHidden = true
    }

    func showBook(name: String) {
        title.stringValue = String(localized: "\(name) · 完")
    }

    func showNext(name: String?) {
        button.isHidden = name == nil
        if let name { button.setText(String(localized: "下一本：\(name)")) }
    }

    @objc private func next() {
        onNext?()
    }
}
