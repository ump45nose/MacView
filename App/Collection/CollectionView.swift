import AppKit
import MVCommands
import MVFoundation
import MVLayout
import MVPipeline
import MVSettings

/// 面板的四种样式。旧的 layout.json 只有 `list` 和 `grid`。
enum CollectionStyle: String, Codable, CaseIterable {
    case list, table, grid, masonry

    var title: String {
        switch self {
        case .list: String(localized: "列表")
        case .table: String(localized: "详情表格")
        case .grid: String(localized: "网格")
        case .masonry: String(localized: "瀑布流")
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .table: "tablecells"
        case .grid: "square.grid.2x2"
        case .masonry: "rectangle.3.group"
        }
    }

    var usesCanvas: Bool { self == .grid || self == .masonry }
}

/// 集合的一项。
struct CollectionItem: Equatable {
    /// 图的身份、宽高比与角标。
    var canvas: CanvasItem
    var name: String
    /// 列表第二行。
    var detail: String
    /// 表格第二列与第三列。
    var column: String
    var size: String
}

/// 统一的集合组件：列表和详情表格用 NSTableView，网格和瀑布流用画布。
final class CollectionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let tableColumn = NSUserInterfaceItemIdentifier("second")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    var style: CollectionStyle {
        didSet { if style != oldValue { styleChanged() } }
    }

    var itemExtent: Double {
        didSet { canvas.itemExtent = itemExtent }
    }

    private(set) var items: [CollectionItem] = []
    private(set) var current: Int?
    /// 空状态的说明；为 nil 时不显示。
    var message: String? {
        didSet { updateMessage() }
    }

    /// 单击或回车。
    var onActivate: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    /// 可见项加余量变化。
    var onVisibleRangeChange: ((Range<Int>) -> Void)?
    /// 当前可见项都有缩略图时调用。布局和图片到达都会再检查。
    var onVisibleThumbnails: (() -> Void)?
    /// 捏合改了尺寸。
    var onItemExtentChange: ((Double) -> Void)?

    let canvas: CanvasView
    private let pipeline: any ImagePipeline
    private let thumbSize: CGSize
    private let tableScroll = NSScrollView()
    private let table = CollectionTable()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let rowImages: CollectionRowImages
    /// 列表和表格里加载失败的项，显示错误文字；点击时重试。
    private var failures: [ContentIdentity: String] = [:]
    /// 可见区还是空的时候通知被跳过，等视图出现或下一次绘制再试。
    private var visibleThumbnailsPending = false

    init(pipeline: any ImagePipeline, style: CollectionStyle, itemExtent: Double, secondColumn: String, thumbSize: CGSize) {
        self.pipeline = pipeline
        self.style = style
        self.itemExtent = itemExtent
        self.thumbSize = thumbSize
        canvas = CanvasView(pipeline: pipeline, kind: style == .grid ? .grid : .masonry, imageSource: .thumbnail, itemExtent: itemExtent)
        rowImages = CollectionRowImages(pipeline: pipeline)
        super.init(frame: .zero)
        canvas.itemExtentRange = PanelExtent.range
        canvas.spacing = 6
        canvas.activatesOnSingleClick = true
        canvas.onActivate = { [weak self] in self?.onActivate?($0) }
        canvas.onDoubleClick = { [weak self] in self?.onDoubleClick?($0) }
        canvas.onVisibleRangeChange = { [weak self] in self?.onVisibleRangeChange?($0.margin) }
        canvas.onItemExtentChange = { [weak self] extent in
            self?.itemExtent = extent
            self?.onItemExtentChange?(extent)
        }
        canvas.onImageApplied = { [weak self] in self?.notifyVisibleThumbnails() }
        canvas.autoresizingMask = [.width, .height]

        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.autoresizingMask = [.width, .height]
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.gridStyleMask = []
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onReturn = { [weak self] in
            guard let self, table.selectedRow >= 0 else { return }
            onActivate?(table.selectedRow)
        }
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = String(localized: "名称")
        name.resizingMask = .autoresizingMask
        let second = NSTableColumn(identifier: Self.tableColumn)
        second.title = secondColumn
        second.headerCell.alignment = .right
        second.width = 84
        second.minWidth = 50
        second.resizingMask = .userResizingMask
        let size = NSTableColumn(identifier: Self.sizeColumn)
        size.title = String(localized: "大小")
        size.headerCell.alignment = .right
        size.width = 64
        size.minWidth = 44
        size.resizingMask = .userResizingMask
        for column in [name, second, size] { table.addTableColumn(column) }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableScrolled(_:)), name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Theme.text2
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)
        styleChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        messageLabel.frame = bounds.insetBy(dx: 16, dy: 16).divided(atDistance: 60, from: .minYEdge).slice
        notifyVisibleThumbnails()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        notifyVisibleThumbnails()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        if visibleThumbnailsPending { notifyVisibleThumbnails() }
    }

    private func styleChanged() {
        canvas.removeFromSuperview()
        tableScroll.removeFromSuperview()
        if style.usesCanvas {
            canvas.frame = bounds
            canvas.kind = style == .grid ? .grid : .masonry
            addSubview(canvas, positioned: .below, relativeTo: messageLabel)
            canvas.setItems(canvasItems())
            highlightCanvas(reveal: true)
        } else {
            tableScroll.frame = bounds
            addSubview(tableScroll, positioned: .below, relativeTo: messageLabel)
            configureTable()
            table.reloadData()
            revealCurrent()
            reportTableRange()
        }
    }

    private func configureTable() {
        let isList = style == .list
        table.headerView = isList ? nil : NSTableHeaderView()
        table.rowHeight = isList ? thumbSize.height + 8 : 24
        for id in [Self.tableColumn, Self.sizeColumn] {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id.rawValue))?.isHidden = isList
        }
        tableScroll.contentInsets = NSEdgeInsetsZero
        table.sizeLastColumnToFit()
    }

    private func updateMessage() {
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
    }

    private func canvasItems() -> [CanvasItem] {
        items.map { item in
            var canvas = item.canvas
            if style == .grid { canvas.label = "\u{00A0}" + item.name }
            return canvas
        }
    }

    // MARK: 数据

    func setItems(_ newItems: [CollectionItem], current newCurrent: Int?) {
        let old = items
        items = newItems
        current = newCurrent
        if style.usesCanvas {
            canvas.setItems(canvasItems())
            highlightCanvas(reveal: false)
        } else if old.count == newItems.count {
            let changed = IndexSet(old.indices.filter { old[$0] != newItems[$0] })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
            }
            updateRowHighlights()
        } else {
            table.reloadData()
            reportTableRange()
        }
        notifyVisibleThumbnails()
    }

    func setCurrent(_ index: Int?, reveal: Bool) {
        guard index != current else { return }
        current = index
        if style.usesCanvas {
            highlightCanvas(reveal: reveal)
        } else {
            updateRowHighlights()
            if reveal { revealCurrent() }
        }
    }

    private func highlightCanvas(reveal: Bool) {
        canvas.select(current.map { [$0] } ?? [], focus: current)
        if reveal, let current, let frame = canvas.frame(of: current), !frame.intersects(canvas.documentVisibleRect) {
            canvas.scrollTo(index: current)
        }
    }

    private func revealCurrent() {
        if let current, current < items.count { table.scrollRowToVisible(current) }
    }

    /// 让当前项重新滚进视口；数据到齐后调用。
    func revealCurrentItem() {
        if style.usesCanvas { highlightCanvas(reveal: true) } else { revealCurrent() }
    }

    private func updateRowHighlights() {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView as? CollectionRowBackground)?.isCurrent = row == self.current
            for column in 0..<rowView.numberOfColumns {
                (rowView.view(atColumn: column) as? CollectionCell)?.setCurrent(row == self.current)
            }
        }
    }

    private func reportTableRange() {
        guard !style.usesCanvas else { return }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else {
            if !items.isEmpty { onVisibleRangeChange?(0..<min(items.count, 32)) }
            return
        }
        onVisibleRangeChange?(max(rows.location - rows.length, 0)..<min(rows.location + rows.length * 2, items.count))
    }

    @objc private func tableScrolled(_ notification: Notification) {
        reportTableRange()
        notifyVisibleThumbnails()
    }

    /// 重新请求失败的项。
    func retryFailed() {
        canvas.retryFailed()
        guard !failures.isEmpty else { return }
        failures.removeAll()
        table.reloadData()
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        style.usesCanvas ? 0 : items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CollectionRowBackground()
        view.isCurrent = row == current
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let column = tableColumn?.identifier else { return nil }
        let item = items[row]
        let failure = failures[item.canvas.identity]
        let isCurrent = row == current
        switch (style, column) {
        case (.list, _):
            let cell = reuse(CollectionListCell.self, in: tableView) { CollectionListCell(thumbSize: thumbSize) }
            cell.show(name: item.name, detail: failure ?? item.detail, isError: failure != nil, isCurrent: isCurrent)
            loadImage(item, into: cell)
            return cell
        case (_, Self.nameColumn):
            let cell = reuse(CollectionTextCell.self, in: tableView) { CollectionTextCell() }
            cell.show(item.name, alignment: .left, monospaced: false, isError: false, isCurrent: isCurrent)
            return cell
        case (_, Self.tableColumn):
            let cell = reuse(CollectionTextCell.self, in: tableView) { CollectionTextCell() }
            cell.show(failure ?? item.column, alignment: .right, monospaced: failure == nil, isError: failure != nil, isCurrent: isCurrent)
            return cell
        default:
            let cell = reuse(CollectionTextCell.self, in: tableView) { CollectionTextCell() }
            cell.show(item.size, alignment: .right, monospaced: true, isError: false, isCurrent: isCurrent)
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ type: Cell.Type, in tableView: NSTableView, make: () -> Cell) -> Cell {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: type))
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = identifier
        return cell
    }

    private func loadImage(_ item: CollectionItem, into cell: CollectionListCell) {
        cell.imageTask?.cancel()
        cell.imageTask = nil
        guard !item.canvas.isPending else {
            cell.setImage(nil)
            return
        }
        let identity = item.canvas.identity
        if let image = rowImages.cached(identity) {
            cell.setImage(image)
            notifyVisibleThumbnails()
            return
        }
        cell.setImage(nil)
        guard failures[identity] == nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let maxPixel = Int(max(thumbSize.width, thumbSize.height) * scale)
        cell.imageTask = Task { [weak self, weak cell, rowImages] in
            do {
                let image = try await rowImages.load(identity, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                cell?.setImage(image)
                self?.notifyVisibleThumbnails()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                failures[identity] = ErrorText.describe(error)
                if let row = items.firstIndex(where: { $0.canvas.identity == identity }) {
                    table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(table.tableColumns.indices))
                }
            }
        }
    }

    /// 列表看可见行的封面；网格和瀑布流看画布上的图层内容。
    private func visibleItemsHaveThumbnails() -> Bool {
        if style.usesCanvas { return canvas.visibleItemsHaveContents() }
        guard style == .list, !items.isEmpty else { return false }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return false }
        let upper = min(rows.location + rows.length, items.count)
        guard rows.location < upper else { return false }
        for row in rows.location..<upper {
            if items[row].canvas.isPending { return false }
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CollectionListCell, cell.hasThumbnail else { return false }
        }
        return true
    }

    private func notifyVisibleThumbnails() {
        guard visibleItemsHaveThumbnails() else {
            visibleThumbnailsPending = true
            return
        }
        visibleThumbnailsPending = false
        onVisibleThumbnails?()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        if failures.removeValue(forKey: items[row].canvas.identity) != nil {
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(table.tableColumns.indices))
        }
        onActivate?(row)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onDoubleClick?(row)
    }

    // MARK: 自检

    var rowCount: Int { table.numberOfRows }

    func rowPointInWindow(_ row: Int) -> NSPoint? {
        guard row < table.numberOfRows else { return nil }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    func cellText(row: Int) -> [String] {
        (0..<table.numberOfColumns).compactMap { column in
            (table.view(atColumn: column, row: row, makeIfNecessary: true) as? CollectionCell)?.texts
        }.flatMap(\.self)
    }
}

/// 面板缩略图尺寸的范围。
enum PanelExtent {
    static let range = 60.0...360.0
    static let standard = 100.0
}

/// 表格：回车激活，输入作用域是列表。
private final class CollectionTable: NSTableView, InputScoped {
    var onReturn: (() -> Void)?
    var inputScope: InputScope { .list }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn || event.specialKey == .enter, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 行底色：当前项 selected，键盘选中项 accentSoft。
private final class CollectionRowBackground: NSTableRowView {
    var isCurrent = false {
        didSet { if isCurrent != oldValue { needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isCurrent || isSelected else { return }
        (isCurrent ? Theme.selected : Theme.accentSoft).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
private protocol CollectionCell: NSView {
    func setCurrent(_ isCurrent: Bool)
    var texts: [String] { get }
}

/// 列表的一行：封面、名称、说明。
private final class CollectionListCell: NSView, CollectionCell {
    var imageTask: Task<Void, Never>?
    private let thumbSize: CGSize
    private let thumb = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(thumbSize: CGSize) {
        self.thumbSize = thumbSize
        super.init(frame: .zero)
        wantsLayer = true
        thumb.cornerRadius = 3
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspectFill
        thumb.actions = ["contents": NSNull()]
        layer?.addSublayer(thumb)
        name.lineBreakMode = .byTruncatingTail
        name.textColor = Theme.text
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        addSubview(name)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        thumb.backgroundColor = Theme.selected.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = CGRect(x: 14, y: (bounds.height - thumbSize.height) / 2, width: thumbSize.width, height: thumbSize.height)
        CATransaction.commit()
        let x = 14 + thumbSize.width + 10
        let width = max(bounds.width - x - 14, 0)
        let middle = bounds.height / 2
        name.frame = CGRect(x: x, y: middle - 18, width: width, height: 17)
        detail.frame = CGRect(x: x, y: middle + 1, width: width, height: 15)
    }

    func show(name text: String, detail detailText: String, isError: Bool, isCurrent: Bool) {
        name.stringValue = text
        detail.stringValue = detailText
        detail.textColor = isError ? Theme.danger : Theme.text2
        setCurrent(isCurrent)
    }

    func setCurrent(_ isCurrent: Bool) {
        name.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
    }

    func setImage(_ image: CGImage?) {
        thumb.contents = image
    }

    var hasThumbnail: Bool { thumb.contents != nil }

    var texts: [String] { [name.stringValue, detail.stringValue] }
}

/// 详情表格的一格。
private final class CollectionTextCell: NSView, CollectionCell {
    private let label = NSTextField(labelWithString: "")
    private var monospaced = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 10, y: (bounds.height - height) / 2, width: max(bounds.width - 16, 0), height: height)
    }

    func show(_ text: String, alignment: NSTextAlignment, monospaced: Bool, isError: Bool, isCurrent: Bool) {
        label.stringValue = text
        label.alignment = alignment
        self.monospaced = monospaced
        label.textColor = isError ? Theme.danger : monospaced ? Theme.text2 : Theme.text
        setCurrent(isCurrent)
    }

    func setCurrent(_ isCurrent: Bool) {
        label.font = monospaced
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
    }

    var texts: [String] { [label.stringValue] }
}

/// 列表封面：按身份缓存的缩略图。
@MainActor
private final class CollectionRowImages {
    private let pipeline: any ImagePipeline
    private let cache = NSCache<NSString, CGImageBox>()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init(pipeline: any ImagePipeline) {
        self.pipeline = pipeline
        updateCacheBudget()
    }

    func cached(_ identity: ContentIdentity) -> CGImage? {
        updateCacheBudget()
        return cache.object(forKey: identity.cacheKey as NSString)?.image
    }

    func load(_ identity: ContentIdentity, maxPixel: Int) async throws -> CGImage {
        let image = try await pipeline.thumbnail(for: identity, maxPixel: maxPixel, priority: .visible).image
        updateCacheBudget()
        cache.setObject(CGImageBox(image), forKey: identity.cacheKey as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    private func updateCacheBudget() {
        cache.totalCostLimit = max(1, Int((pipeline as? FileImagePipeline)?.thumbnailMemoryBudget ?? CacheBudgets.default.thumbnailMemoryBytes))
    }
}
