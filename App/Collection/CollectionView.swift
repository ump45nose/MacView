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
    /// 项本身读取失败（例如书架封面）时的错误文字：列表和表格显示文字，网格和瀑布流显示错误标记。
    var failure: String?
}

/// 统一的集合组件：列表和详情表格用 NSTableView，网格和瀑布流用画布。
final class CollectionView: NSView, NSTableViewDataSource, NSTableViewDelegate, InputScoped {
    private static let tableColumn = NSUserInterfaceItemIdentifier("second")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    var inputScope: InputScope { .list }

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
    var onContextMenu: (([Int]) -> NSMenu?)?
    /// 可见项加余量变化。
    var onVisibleRangeChange: ((Range<Int>) -> Void)?
    #if DEBUG
    /// 当前可见项都有缩略图时调用，只给首屏计时用。布局和图片到达都会再检查。
    var onVisibleThumbnails: (() -> Void)?
    #endif
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
    private var isUpdatingCanvas = false
    private var pendingTableWriters: [Int: any NSPasteboardWriting] = [:]
    #if DEBUG
    /// 可见区还是空的时候通知被跳过，等视图出现或下一次绘制再试。
    private var visibleThumbnailsPending = false
    private(set) var lastDragSession: (session: NSDraggingSession, writers: [any NSPasteboardWriting])?
    #endif

    init(pipeline: any ImagePipeline, settings: any SettingsStore, style: CollectionStyle, itemExtent: Double, secondColumn: String, thumbSize: CGSize) {
        self.pipeline = pipeline
        self.style = style
        self.itemExtent = itemExtent
        self.thumbSize = thumbSize
        canvas = CanvasView(pipeline: pipeline, settings: settings, kind: style == .grid ? .grid : .masonry, imageSource: .thumbnail, itemExtent: itemExtent)
        rowImages = CollectionRowImages(pipeline: pipeline, settings: settings)
        super.init(frame: .zero)
        canvas.itemExtentRange = PanelExtent.range
        canvas.spacing = 6
        canvas.activatesOnSingleClick = false
        canvas.onActivate = { [weak self] in self?.onActivate?($0) }
        canvas.onDoubleClick = { [weak self] in self?.onDoubleClick?($0) }
        canvas.onSelectionChange = { [weak self] selection in
            guard let self, !isUpdatingCanvas, selection.count == 1, let index = selection.first else { return }
            if (NSApp.currentEvent?.modifierFlags ?? []).isDisjoint(with: [.command, .shift]) { onActivate?(index) }
        }
        canvas.onContextMenu = { [weak self] in $0.flatMap { self?.contextMenu(forItemAt: $0) } }
        canvas.onDraggingWriters = { [weak self] in self?.draggingWriters(forItemAt: $0) ?? [] }
        canvas.onDragSessionBegan = { [weak self] session, writers in
            #if DEBUG
            self?.lastDragSession = (session, writers)
            #endif
        }
        canvas.onDragSessionEnded = { operation in
            (NSApp.delegate as? AppDelegate)?.fileOps?.dragSessionEnded(operation: operation)
        }
        canvas.onVisibleRangeChange = { [weak self] in self?.onVisibleRangeChange?($0.margin) }
        canvas.onItemExtentChange = { [weak self] extent in
            self?.itemExtent = extent
            self?.onItemExtentChange?(extent)
        }
        #if DEBUG
        canvas.onImageApplied = { [weak self] in self?.notifyVisibleThumbnails() }
        #endif
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
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // App 内给 `.generic`，书签和播放列表面板按它接收位置（与画布一致）。
        table.setDraggingSourceOperationMask(.generic, forLocal: true)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.onReturn = { [weak self] in
            guard let self, table.selectedRow >= 0 else { return }
            onActivate?(table.selectedRow)
        }
        table.onContextMenu = { [weak self] in $0.flatMap { self?.contextMenu(forItemAt: $0) } }
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

        messageLabel.font = Theme.font(.panels, size: 12)
        messageLabel.textColor = Theme.text2
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        addSubview(messageLabel)
        canvas.fontRole = .panels
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
        styleChanged()
    }

    @objc private func applyFonts() {
        messageLabel.font = Theme.font(.panels, size: 12)
        guard !style.usesCanvas else { return }
        let savedSelection = table.selectedRowIndexes
        let savedOrigin = scrollOrigin
        let isList = style == .list
        table.rowHeight = isList ? ceil(max(thumbSize.height + 8, 48 * Theme.fontScale(.panels))) : ceil(24 * Theme.fontScale(.panels))
        table.enumerateAvailableRowViews { rowView, _ in
            for column in 0..<rowView.numberOfColumns {
                (rowView.view(atColumn: column) as? CollectionCell)?.applyFonts()
            }
        }
        if table.selectedRowIndexes != savedSelection {
            table.selectRowIndexes(savedSelection, byExtendingSelection: false)
        }
        scrollOrigin = savedOrigin
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // AppKit 会在并行生成多项拖动图像时查询坐标方向；常量 getter 不访问主线程状态。
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        messageLabel.frame = bounds.insetBy(dx: 16, dy: 16).divided(atDistance: 60, from: .minYEdge).slice
        #if DEBUG
        notifyVisibleThumbnails()
        #endif
    }

    #if DEBUG
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
    #endif

    private func styleChanged() {
        canvas.removeFromSuperview()
        tableScroll.removeFromSuperview()
        if style.usesCanvas {
            canvas.frame = bounds
            canvas.kind = style == .grid ? .grid : .masonry
            addSubview(canvas, positioned: .below, relativeTo: messageLabel)
            isUpdatingCanvas = true
            canvas.setItems(canvasItems())
            isUpdatingCanvas = false
            highlightCanvas(reveal: true)
        } else {
            tableScroll.frame = bounds
            addSubview(tableScroll, positioned: .below, relativeTo: messageLabel)
            configureTable()
            table.reloadData()
            selectCurrentRow()
            revealCurrent()
            reportTableRange()
        }
    }

    private func configureTable() {
        let isList = style == .list
        table.headerView = isList ? nil : NSTableHeaderView()
        table.rowHeight = isList ? ceil(max(thumbSize.height + 8, 48 * Theme.fontScale(.panels))) : ceil(24 * Theme.fontScale(.panels))
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
            canvas.isFailed = item.failure != nil
            return canvas
        }
    }

    // MARK: 数据

    func setItems(_ newItems: [CollectionItem], current newCurrent: Int?) {
        let old = items
        let oldCurrent = current
        items = newItems
        current = newCurrent
        if style.usesCanvas {
            isUpdatingCanvas = true
            canvas.setItems(canvasItems())
            isUpdatingCanvas = false
            if newCurrent != oldCurrent || canvas.selection.isEmpty {
                highlightCanvas(reveal: false)
            }
        } else if old.count == newItems.count {
            let changed = IndexSet(old.indices.filter { old[$0] != newItems[$0] })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
            }
            if newCurrent != oldCurrent || table.selectedRowIndexes.isEmpty { selectCurrentRow() }
            updateRowHighlights()
        } else {
            table.reloadData()
            selectCurrentRow()
            reportTableRange()
        }
        #if DEBUG
        notifyVisibleThumbnails()
        #endif
    }

    func setCurrent(_ index: Int?, reveal: Bool) {
        guard index != current else { return }
        current = index
        if style.usesCanvas {
            highlightCanvas(reveal: reveal)
        } else {
            selectCurrentRow()
            updateRowHighlights()
            if reveal { revealCurrent() }
        }
    }

    private func selectCurrentRow() {
        table.selectRowIndexes(current.flatMap { items.indices.contains($0) ? IndexSet(integer: $0) : nil } ?? IndexSet(), byExtendingSelection: false)
    }

    private func highlightCanvas(reveal: Bool) {
        isUpdatingCanvas = true
        canvas.select(current.map { [$0] } ?? [], focus: current)
        isUpdatingCanvas = false
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

    /// 读写当前滚动位置；书架进入搜索再按 Esc 返回时恢复。
    var scrollOrigin: NSPoint {
        get {
            let clip = style.usesCanvas ? canvas.contentView : tableScroll.contentView
            return clip.bounds.origin
        }
        set {
            let scroll: NSScrollView = style.usesCanvas ? canvas : tableScroll
            scroll.contentView.scroll(to: newValue)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
        #if DEBUG
        notifyVisibleThumbnails()
        #endif
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
        let failure = item.failure ?? failures[item.canvas.identity]
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
        // 项本身失败（例如虚拟书里不可用的页）不显示图，缓存里的旧图也不用，与网格和查看器一致。
        guard !item.canvas.isPending, item.failure == nil else {
            cell.setImage(nil)
            return
        }
        let identity = item.canvas.identity
        if let image = rowImages.cached(identity) {
            cell.setImage(image)
            #if DEBUG
            notifyVisibleThumbnails()
            #endif
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
                #if DEBUG
                self?.notifyVisibleThumbnails()
                #endif
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                failures[identity] = ErrorText.describe(error)
                if let row = items.firstIndex(where: { $0.canvas.identity == identity }) {
                    table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(table.tableColumns.indices))
                }
            }
        }
    }

    #if DEBUG
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
            if items[row].failure != nil { continue }
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
    #endif

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        if failures.removeValue(forKey: items[row].canvas.identity) != nil {
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(table.tableColumns.indices))
        }
        if (NSApp.currentEvent?.modifierFlags ?? []).isDisjoint(with: [.command, .shift]) { onActivate?(row) }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onDoubleClick?(row)
    }

    var selectedIndices: [Int] {
        let valid = (style.usesCanvas ? Array(canvas.selection).sorted() : Array(table.selectedRowIndexes)).filter { items.indices.contains($0) }
        return !valid.isEmpty ? valid : (current.flatMap { items.indices.contains($0) ? [$0] : nil } ?? [])
    }

    func selectRows(_ rows: IndexSet) {
        if style.usesCanvas {
            isUpdatingCanvas = true; canvas.select(Set(rows), focus: rows.last); isUpdatingCanvas = false
        } else {
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    func contextMenu(forItemAt index: Int) -> NSMenu? {
        guard items.indices.contains(index) else { return nil }
        let selected = selectedIndices
        return onContextMenu?(selected.contains(index) ? selected : [index])
    }

    func pasteboardWriter(forItemAt index: Int) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(index) else { return nil }
        guard let writer = (NSApp.delegate as? AppDelegate)?.fileOps?.pasteboardWriter(forItemAt: index, in: self) else { return nil }
        return wrapDragWriter?(index, writer) ?? writer
    }

    /// 表格与画布共用同一条拖出路径，保留原文件 URL 或文件承诺并附加 App 内数据。
    var wrapDragWriter: ((Int, any NSPasteboardWriting) -> any NSPasteboardWriting)?

    func draggingWriters(forItemAt index: Int) -> [(index: Int, writer: any NSPasteboardWriting)] {
        guard items.indices.contains(index) else { return [] }
        let selected = selectedIndices
        let indices = selected.contains(index) ? selected : [index]
        return indices.compactMap { i in pasteboardWriter(forItemAt: i).map { (i, $0) } }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let writer = pasteboardWriter(forItemAt: row) else { return nil }
        pendingTableWriters[row] = writer
        return writer
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        #if DEBUG
        lastDragSession = (session, rowIndexes.compactMap { pendingTableWriters[$0] })
        #endif
        pendingTableWriters.removeAll()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pendingTableWriters.removeAll()
        (NSApp.delegate as? AppDelegate)?.fileOps?.dragSessionEnded(operation: operation)
    }

    // MARK: 自检

    var rowCount: Int { table.numberOfRows }

    func rowPointInWindow(_ row: Int) -> NSPoint? {
        guard row < table.numberOfRows else { return nil }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    func itemPointInWindow(_ index: Int) -> NSPoint? {
        if style.usesCanvas {
            guard index < canvas.placedCount else { return nil }
            if let frame = canvas.frame(of: index), !frame.intersects(canvas.documentVisibleRect) {
                canvas.scrollTo(index: index)
            }
            guard let frame = canvas.frame(of: index), let doc = canvas.documentView else { return nil }
            return doc.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        }
        return rowPointInWindow(index)
    }

    #if DEBUG
    func clearLastDragSession() { lastDragSession = nil }
    #endif

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
    var onContextMenu: ((Int?) -> NSMenu?)?
    var inputScope: InputScope { .list }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn || event.specialKey == .enter, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(row >= 0 ? row : nil)
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
    func applyFonts()
    var texts: [String] { get }
}

/// 列表的一行：封面、名称、说明。
private final class CollectionListCell: NSView, CollectionCell {
    var imageTask: Task<Void, Never>?
    private let thumbSize: CGSize
    private let thumb = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var isCurrentRow = false

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
        detail.font = Theme.font(.panels, size: 11)
        addSubview(name)
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var isFlipped: Bool { true }
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
        let nameH = max(17, ceil(name.intrinsicContentSize.height))
        let detailH = max(15, ceil(detail.intrinsicContentSize.height))
        let top = (bounds.height - (nameH + detailH + 2)) / 2
        name.frame = CGRect(x: x, y: top, width: width, height: nameH)
        detail.frame = CGRect(x: x, y: top + nameH + 2, width: width, height: detailH)
    }

    func show(name text: String, detail detailText: String, isError: Bool, isCurrent: Bool) {
        name.stringValue = text
        detail.stringValue = detailText
        detail.textColor = isError ? Theme.danger : Theme.text2
        detail.font = Theme.font(.panels, size: 11)
        setCurrent(isCurrent)
    }

    func setCurrent(_ isCurrent: Bool) {
        isCurrentRow = isCurrent
        name.font = Theme.font(.panels, size: 13, weight: isCurrent ? .semibold : .regular)
    }

    func applyFonts() {
        detail.font = Theme.font(.panels, size: 11)
        name.font = Theme.font(.panels, size: 13, weight: isCurrentRow ? .semibold : .regular)
        needsLayout = true
    }

    func setImage(_ image: CGImage?) {
        thumb.contents = image
    }

    #if DEBUG
    var hasThumbnail: Bool { thumb.contents != nil }
    #endif

    var texts: [String] { [name.stringValue, detail.stringValue] }
}

/// 详情表格的一格。
private final class CollectionTextCell: NSView, CollectionCell {
    private let label = NSTextField(labelWithString: "")
    private var monospaced = false
    private var isCurrentRow = false

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
        isCurrentRow = isCurrent
        label.font = monospaced
            ? Theme.font(.panels, size: 11, weight: .regular, monospacedDigits: true)
            : Theme.font(.panels, size: 12, weight: isCurrent ? .semibold : .regular)
    }

    func applyFonts() {
        setCurrent(isCurrentRow)
        needsLayout = true
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

    init(pipeline: any ImagePipeline, settings: any SettingsStore) {
        self.pipeline = pipeline
        followThumbnailMemoryBudget(cache, settings: settings)
    }

    func cached(_ identity: ContentIdentity) -> CGImage? {
        cache.object(forKey: identity.cacheKey as NSString)?.image
    }

    func load(_ identity: ContentIdentity, maxPixel: Int) async throws -> CGImage {
        let image = try await pipeline.thumbnail(for: identity, maxPixel: maxPixel, priority: .visible).image
        cache.setObject(CGImageBox(image), forKey: identity.cacheKey as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}
