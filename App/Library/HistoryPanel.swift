import AppKit
import MVFoundation
import MVIO
import MVLibraryData
import MVPipeline
import MVReading
import MVServices
import MVSettings

/// 历史面板没有视图设置。
struct HistoryPanelSettings: Codable, Equatable {}

/// 历史：打开过的书（含当书打开的播放列表），从新到旧。单击打开并回到上次的页。
@MainActor
final class HistoryPanel: NSObject, DockPanel, NSTableViewDataSource, NSTableViewDelegate {
    typealias Settings = HistoryPanelSettings

    let settings = HistoryPanelSettings()
    var onSettingsChange: (() -> Void)?
    var view: NSView { host }

    private weak var owner: ReaderWindowController?
    private weak var services: CoreServices?
    private let table = LibraryTableView()
    private let host: LibraryPanelView
    private let countLabel = NSTextField(labelWithString: "")
    private let availability = LibraryAvailability()

    private(set) var entries: [HistoryEntry] = []
    private var playlistNames: [UUID: String] = [:]
    private var limit: Int?
    private var loadError: String?
    private var isConfirmingClear = false
    /// 封面只取一次；值为 nil 表示没有封面或读取失败。
    private var covers: [Location: CGImage?] = [:]
    private var coverLoading: Set<Location> = []
    /// “读到第 N 页”：每次重新读取历史或面板显示时对可见行重取。
    private var readTo: [Location: Int] = [:]
    private var readToFetched: Set<Location> = []
    private var reloadToken = 0
    private var observers: [Task<Void, Never>] = []

    /// 解析封面用到的服务。
    private struct CoverServices: Sendable {
        let sources: any SourceRegistry
        let pipeline: any ImagePipeline
        let bookshelf: any Bookshelf
        let library: any LibraryStore
    }

    /// 没有视图设置，参数只为与其他面板的登记方式一致。
    init(settings: HistoryPanelSettings?) {
        host = LibraryPanelView(document: table)
        super.init()
        table.headerView = nil
        table.rowHeight = ceil(52 * Theme.fontScale(.panels))
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.setDraggingSourceOperationMask(.generic, forLocal: true)
        table.onContextMenu = { [weak self] row in self?.contextMenu(row: row) }
        countLabel.font = Theme.font(.panels, size: 11)
        countLabel.textColor = Theme.text2
        host.setInfo(String(localized: "最近打开"), accessory: countLabel)
        host.onShow = { [weak self] in self?.shown() }
        host.onScroll = { [weak self] in
            self?.availability.scrolled()
            self?.loadDetails()
        }
        availability.view = host
        availability.visibleLocations = { [weak self] in self?.visibleLocations() ?? [] }
        availability.onChange = { [weak self] in self?.availabilityChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
        render()
    }

    @objc private func applyFonts() {
        countLabel.font = Theme.font(.panels, size: 11)
        let savedOrigin = host.scroll.contentView.bounds.origin
        table.rowHeight = ceil(52 * Theme.fontScale(.panels))
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? HistoryCell)?.applyFonts()
        }
        host.scroll.contentView.scroll(to: savedOrigin)
        host.scroll.reflectScrolledClipView(host.scroll.contentView)
        host.needsLayout = true
    }

    deinit { observers.forEach { $0.cancel() } }

    func bind(to window: ReaderWindowController?) {
        owner = window
        let services = window?.services
        guard services !== self.services else { return }
        self.services = services
        availability.attach(services)
        observe()
        reload()
    }

    func addOptions(to menu: NSMenu) {
        let clear = MenuAction(String(localized: "清空历史…")) { [weak self] in self?.askToClear() }.item
        clear.isEnabled = !entries.isEmpty
        menu.addItem(clear)
    }

    // MARK: 读取

    private func observe() {
        observers.forEach { $0.cancel() }
        observers = []
        guard let services, let library = services.library else { return }
        let changes = library.changes()
        let settingsChanges = services.settings.changes()
        observers = [
            Task { [weak self] in
                for await change in changes {
                    guard let self else { return }
                    switch change {
                    case .history, .relocated, .playlists, .playlistRemoved: reload()
                    case .bookmarks, .items: break
                    }
                }
            },
            Task { [weak self] in
                for await change in settingsChanges where change == .global {
                    guard let self else { return }
                    reload()
                }
            },
        ]
    }

    private func reload() {
        reloadToken += 1
        let token = reloadToken
        guard let services, let library = services.library else {
            entries = []
            render()
            return
        }
        Task { [weak self] in
            let result: Result<[HistoryEntry], any Error>
            do { result = .success(try await library.history()) } catch { result = .failure(error) }
            let history = (try? result.get()) ?? []
            let lists = history.contains { $0.book.playlistID != nil } ? (try? await library.playlists()) ?? [] : []
            let limit = await services.settings.global().historyLimit
            guard let self, token == reloadToken else { return }
            entries = history.sorted { $0.openedAt > $1.openedAt }
            if case let .failure(error) = result { loadError = ErrorText.describe(error) } else { loadError = nil }
            playlistNames = Dictionary(lists.map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
            self.limit = limit
            if entries.isEmpty { isConfirmingClear = false }
            readToFetched = []
            let present = Set(entries.map(\.book))
            covers = covers.filter { present.contains($0.key) }
            availability.retain(present)
            render()
        }
    }

    private func render() {
        let selected = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].book : nil })
        table.reloadData()
        table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].book) }), byExtendingSelection: false)
        countLabel.stringValue = limit.map { "\(entries.count) / \($0)" } ?? "\(entries.count)"
        host.setInfo(String(localized: "最近打开"), accessory: countLabel)
        host.setBanner(isConfirmingClear ? clearBanner() : nil)
        if let loadError {
            host.setEmpty(title: String(localized: "读不出历史"), message: loadError)
        } else if entries.isEmpty {
            host.setEmpty(title: String(localized: "还没有历史"), message: String(localized: "打开过的书会按时间从新到旧列在这里。"))
        } else {
            host.setEmpty(title: nil, message: "")
        }
        visibleRowsChanged()
    }

    private func shown() {
        readToFetched = []
        availability.recheckAll()
        loadDetails()
    }

    private func visibleRowsChanged() {
        availability.visibleChanged()
        loadDetails()
    }

    private var visibleRows: Range<Int> {
        let range = table.rows(in: table.visibleRect)
        return max(range.location, 0)..<min(range.location + range.length, entries.count)
    }

    private func visibleLocations() -> [Location] { visibleRows.map { entries[$0].book } }

    /// 可见行的封面和读到的页。
    private func loadDetails() {
        guard let services, host.window != nil else { return }
        let books = visibleLocations()
        let pages = books.filter { !readToFetched.contains($0) }
        if !pages.isEmpty {
            readToFetched.formUnion(pages)
            let settings = services.settings
            Task { [weak self] in
                var found: [Location: Int] = [:]
                for book in pages {
                    if let index = await settings.bookMemory(for: book)?.lastPageIndex { found[book] = index + 1 }
                }
                guard let self else { return }
                for book in pages { readTo[book] = found[book] }
                refreshVisibleCells()
            }
        }
        guard let library = services.library else { return }
        let deps = CoverServices(sources: services.sources, pipeline: services.pipeline, bookshelf: services.bookshelf, library: library)
        for book in books where covers.index(forKey: book) == nil && !coverLoading.contains(book) {
            coverLoading.insert(book)
            Task { [weak self] in
                let image = await Self.cover(of: book, services: deps)
                guard let self else { return }
                coverLoading.remove(book)
                covers[book] = .some(image)
                refreshVisibleCells()
            }
        }
    }

    /// 书的封面沿用书架的取法；播放列表取第一项。
    private nonisolated static func cover(of book: Location, services: CoverServices) async -> CGImage? {
        do {
            let identity: ContentIdentity
            if let playlist = book.playlistID {
                guard let first = try await services.library.items(of: playlist).first else { return nil }
                identity = first.identity
            } else {
                guard let location = try await services.bookshelf.cover(of: book, priority: .near) else { return nil }
                identity = try await services.sources.provider(for: location).entry(at: location).identity
            }
            return try await services.pipeline.thumbnail(for: identity, maxPixel: 96, priority: .visible).image
        } catch {
            return nil
        }
    }

    private func availabilityChanged() {
        // 恢复可用的书之前没取到封面的，重新取。
        for (book, state) in availability.states where state == .available {
            if case .some(.none) = covers[book] { covers[book] = nil }
        }
        refreshVisibleCells()
        loadDetails()
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("historyCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell ?? {
            let cell = HistoryCell()
            cell.identifier = id
            return cell
        }()
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LibraryRowView()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard entries.indices.contains(row), entries[row].book.playlistID == nil else { return nil }
        return LibraryPasteboard.writer(wrapping: nil, location: entries[row].book)
    }

    private func configure(_ cell: HistoryCell, row: Int) {
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        let book = entry.book
        var parts: [String] = []
        let name: String
        let path: String?
        if let playlist = book.playlistID {
            name = playlistNames[playlist] ?? String(localized: "播放列表")
            parts.append(String(localized: "播放列表"))
            path = nil
        } else {
            name = book.name.isEmpty ? book.root.displayName : book.name
            path = book.parent?.displayPath
        }
        if let page = readTo[book] { parts.append(String(localized: "读到第 \(page) 页")) }
        parts.append(LibraryPanels.ago(entry.openedAt))
        let state = availability.state(of: book)
        cell.show(
            name: name, detail: parts.joined(separator: " · "), path: path,
            cover: covers[book] ?? nil, isPlaylist: book.playlistID != nil, availability: state
        )
        cell.badge.onPress = { [weak self, weak cell] in
            guard let self, let cell else { return }
            showReason(for: book, from: cell.badge)
        }
    }

    private func refreshVisibleCells() {
        for row in visibleRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryCell { configure(cell, row: row) }
        }
    }

    // MARK: 操作

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard entries.indices.contains(row),
              NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true else { return }
        let book = entries[row].book
        if availability.state(of: book)?.isUnavailable == true,
           let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryCell {
            showReason(for: book, from: cell.badge)
            return
        }
        LibraryPanels.open(book, from: owner)
    }

    private func showReason(for book: Location, from badge: NSView) {
        guard let state = availability.state(of: book), state.isUnavailable else { return }
        UnavailableReasonPopover.show(
            state, what: String(localized: "这本书"), location: book, relativeTo: badge.bounds, of: badge
        ) { [weak self] in self?.remove([book]) }
    }

    /// 右键的行在选中项里时作用于全部选中项。
    private func targets(row: Int) -> [Location] {
        let selected = table.selectedRowIndexes
        let rows = selected.contains(row) ? Array(selected) : [row]
        return rows.filter { entries.indices.contains($0) }.map { entries[$0].book }
    }

    private func contextMenu(row: Int?) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let row, entries.indices.contains(row) {
            let book = entries[row].book
            let unavailable = availability.state(of: book)?.isUnavailable == true
            let open = MenuAction(String(localized: "打开")) { [weak self] in LibraryPanels.open(book, from: self?.owner) }.item
            open.isEnabled = !unavailable
            menu.addItem(open)
            if book.playlistID == nil, let app = NSApp.delegate as? AppDelegate {
                menu.addItem(LibraryActions.bookmarkMenuItem(for: [book], app: app))
                let reveal = MenuAction(String(localized: "在 Finder 中显示")) { [weak self] in
                    guard let services = self?.services else { return }
                    LibraryPanels.reveal(book, services: services)
                }.item
                reveal.isEnabled = !unavailable
                menu.addItem(reveal)
            }
            menu.addItem(.separator())
            let books = targets(row: row)
            menu.addItem(MenuAction(String(localized: "从历史中删除")) { [weak self] in self?.remove(books) }.item)
        }
        let clear = MenuAction(String(localized: "清空历史…")) { [weak self] in self?.askToClear() }.item
        clear.isEnabled = !entries.isEmpty
        menu.addItem(clear)
        Theme.applyMenuFont(to: menu)
        return menu
    }

    private func remove(_ books: [Location]) {
        guard let library = services?.library else { return }
        Task { [weak self] in
            do {
                try await library.removeHistory(books)
            } catch {
                self?.showError(error)
            }
        }
    }

    private func askToClear() {
        guard !entries.isEmpty else { return }
        isConfirmingClear = true
        render()
    }

    @objc private func cancelClear(_ sender: Any?) {
        isConfirmingClear = false
        render()
    }

    @objc private func confirmClear(_ sender: Any?) {
        isConfirmingClear = false
        render()
        guard let library = services?.library else { return }
        Task { [weak self] in
            do {
                try await library.clearHistory()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func clearBanner() -> LibraryConfirmBanner {
        let cancel = UnavailableReasonPopover.button(String(localized: "取消"), primary: false)
        cancel.target = self
        cancel.action = #selector(cancelClear(_:))
        let confirm = FlatButton(font: Theme.font(.panels, size: 12), fill: Theme.raised, foreground: Theme.danger, border: Theme.lineStrong, radius: 5, height: 22, padding: 9)
        confirm.setText(String(localized: "清空"))
        confirm.target = self
        confirm.action = #selector(confirmClear(_:))
        return LibraryConfirmBanner(
            text: String(localized: "清空全部 \(entries.count) 条历史？书的“上次看到的页”不受影响。"),
            buttons: [cancel, confirm]
        )
    }

    private func showError(_ error: any Error) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        LibraryActions.showMessage(ErrorText.describe(error), app: app)
    }
}

// MARK: - 历史的行

/// 一行：封面、书名、“读到第 N 页 · 多久前”、所在路径；不可用时变灰并显示右侧标记。
@MainActor
private final class HistoryCell: NSView {
    private static let thumbSize = CGSize(width: 30, height: 40)
    private let thumb = CALayer()
    private let listMark = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    let badge = UnavailableBadge()
    private var isDimmed = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        thumb.cornerRadius = 3
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspectFill
        thumb.actions = ["contents": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(thumb)
        listMark.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        listMark.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        listMark.contentTintColor = .white
        listMark.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowColor = .black.withAlphaComponent(0.5)
            return shadow
        }()
        for label in [name, detail, path] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        name.font = Theme.font(.panels, size: 13)
        name.textColor = Theme.text
        for label in [detail, path] {
            label.font = Theme.font(.panels, size: 11)
            label.textColor = Theme.text2
        }
        addSubview(listMark)
        addSubview(badge)
    }

    func applyFonts() {
        name.font = Theme.font(.panels, size: 13)
        let subFont = Theme.font(.panels, size: 11)
        detail.font = subFont
        path.font = subFont
        needsLayout = true
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

    /// 只有标记接收点击，其余交给表格（表格接受第一次点击）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        badge.isHidden ? nil : badge.hitTest(convert(point, from: superview))
    }

    override func layout() {
        super.layout()
        let size = Self.thumbSize
        let thumbFrame = CGRect(x: 10, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = thumbFrame
        CATransaction.commit()
        listMark.frame = thumbFrame
        badge.frame = CGRect(x: bounds.width - 10 - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let x = thumbFrame.maxX + 8
        let width = max((badge.isHidden ? bounds.width - 10 : badge.frame.minX - 4) - x, 0)
        let lines = path.isHidden ? [name, detail] : [name, detail, path]
        let heights: [CGFloat] = lines.map { $0 === name ? 17 : 15 }
        var y = (bounds.height - heights.reduce(0, +)) / 2
        for (label, height) in zip(lines, heights) {
            label.frame = CGRect(x: x, y: y, width: width, height: height)
            y += height
        }
    }

    func show(name: String, detail: String, path: String?, cover: CGImage?, isPlaylist: Bool, availability: Availability?) {
        self.name.stringValue = name
        self.detail.stringValue = detail
        self.path.stringValue = path ?? ""
        self.path.isHidden = path == nil
        thumb.contents = cover
        listMark.isHidden = !isPlaylist
        badge.show(availability)
        let dimmed = availability?.isUnavailable == true
        if dimmed != isDimmed {
            isDimmed = dimmed
            LibraryPanels.dim([self.name, self.detail, self.path], thumb: thumb, dimmed: dimmed)
        }
        needsLayout = true
    }
}

// MARK: - 资料库面板共用

/// 历史、书签面板共用的外框：可选的确认条、信息行、滚动的列表与空状态。
@MainActor
final class LibraryPanelView: NSView {
    let scroll = NSScrollView()
    /// 面板显示（进窗口或取消隐藏）。
    var onShow: (() -> Void)?
    /// 滚动或尺寸变化后可见行可能变了。
    var onScroll: (() -> Void)?

    private let infoLabel = NSTextField(labelWithString: "")
    private var infoAccessory: NSView?
    private let infoLine = CALayer()
    private var banner: LibraryConfirmBanner?
    private let emptyTitle = PassthroughLabel(labelWithString: "")
    private let emptyMessage = PassthroughLabel(wrappingLabelWithString: "")
    private static let infoHeight: CGFloat = 28

    init(document: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(infoLine)
        infoLabel.font = Theme.font(.panels, size: 11)
        infoLabel.textColor = Theme.text2
        infoLabel.lineBreakMode = .byTruncatingTail
        addSubview(infoLabel)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        emptyTitle.font = Theme.serif(16)
        emptyTitle.textColor = Theme.text
        emptyTitle.alignment = .center
        emptyMessage.font = Theme.font(.panels, size: 13)
        emptyMessage.textColor = Theme.text2
        emptyMessage.alignment = .center
        addSubview(emptyTitle)
        addSubview(emptyMessage)
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        infoLabel.font = Theme.font(.panels, size: 11)
        emptyMessage.font = Theme.font(.panels, size: 13)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        infoLine.backgroundColor = Theme.line.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onShow?() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onShow?()
    }

    @objc private func boundsChanged(_ notification: Notification) { onScroll?() }

    func setInfo(_ text: String, accessory: NSView?) {
        infoLabel.stringValue = text
        if accessory !== infoAccessory {
            infoAccessory?.removeFromSuperview()
            infoAccessory = accessory
            if let accessory { addSubview(accessory) }
        }
        needsLayout = true
    }

    func setBanner(_ view: LibraryConfirmBanner?) {
        banner?.removeFromSuperview()
        banner = view
        if let view { addSubview(view) }
        needsLayout = true
    }

    /// `title` 为 nil 时不显示空状态。
    func setEmpty(title: String?, message: String) {
        emptyTitle.stringValue = title ?? ""
        emptyMessage.stringValue = message
        emptyTitle.isHidden = title == nil
        emptyMessage.isHidden = title == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let banner {
            let width = max(bounds.width - 20, 0)
            let height = banner.height(for: width)
            banner.frame = CGRect(x: 10, y: 8, width: width, height: height)
            y = banner.frame.maxY + 8
        }
        var right = bounds.width - 10
        if let accessory = infoAccessory {
            let size = accessory.fittingSize
            accessory.frame = CGRect(x: right - size.width, y: y + (Self.infoHeight - size.height) / 2, width: size.width, height: size.height)
            right = accessory.frame.minX - 6
        }
        infoLabel.frame = CGRect(x: 10, y: y + (Self.infoHeight - 15) / 2, width: max(right - 10, 0), height: 15)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoLine.frame = CGRect(x: 0, y: y + Self.infoHeight - 1, width: bounds.width, height: 1)
        CATransaction.commit()
        y += Self.infoHeight
        scroll.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(bounds.height - y, 0))
        let width = max(bounds.width - 40, 0)
        emptyTitle.frame = CGRect(x: 20, y: y + 40, width: width, height: 22)
        emptyMessage.preferredMaxLayoutWidth = width
        emptyMessage.frame = CGRect(x: 20, y: emptyTitle.frame.maxY + 6, width: width, height: emptyMessage.fittingSize.height)
    }
}

/// 空状态的文字不接收点击和拖放，拖放落到下面的列表上。
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板内的确认条：危险色浅底，文字在上，按钮靠右。
@MainActor
final class LibraryConfirmBanner: NSView {
    private let label: NSTextField
    private let buttons: NSStackView

    init(text: String, buttons: [NSView]) {
        label = NSTextField(wrappingLabelWithString: text)
        self.buttons = NSStackView(views: [NSView()] + buttons)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = Theme.font(.panels, size: 12)
        label.textColor = Theme.text
        self.buttons.spacing = 6
        let stack = NSStackView(views: [label, self.buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            self.buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        let font = Theme.font(.panels, size: 12)
        label.font = font
        for view in buttons.arrangedSubviews {
            (view as? FlatButton)?.applyFont(font)
        }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.dangerSoft.cgColor
    }

    /// 给定宽度下的高度。
    func height(for width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = max(width - 16, 0)
        return fittingSize.height
    }
}

/// 资料库面板的表格：任意位置可点，右键菜单按行给出。
@MainActor
final class LibraryTableView: NSTableView {
    var onContextMenu: ((Int?) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(row >= 0 ? row : nil)
    }
}

/// 行底色：选中项是圆角 selected。
@MainActor
final class LibraryRowView: NSTableRowView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    /// 选中底色很浅，图标和三角保持原色，不换成反白。
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selected.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        Theme.accentSoft.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 4, yRadius: 4).fill()
        Theme.accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6.75, dy: 0.75), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// 资料库面板共用的文字、打开与在 Finder 中显示。
@MainActor
enum LibraryPanels {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    /// “多久前”。
    static func ago(_ date: Date) -> String {
        relative.localizedString(for: min(date, Date()), relativeTo: Date())
    }

    /// 打开这本书，回到上次的页（会话按书记忆恢复）；没有窗口时新开一个。
    static func open(_ book: Location, from owner: ReaderWindowController?) {
        if let owner {
            owner.openBook(book)
        } else if let app = NSApp.delegate as? AppDelegate {
            app.newWindow()?.openBook(book)
        }
    }

    static func reveal(_ book: Location, services: CoreServices) {
        let sources = services.sources
        Task {
            do {
                let lease = try await sources.provider(for: book).fileLease(for: book)
                NSWorkspace.shared.activateFileViewerSelecting([lease.url])
            } catch {
                guard let app = NSApp.delegate as? AppDelegate else { return }
                LibraryActions.showMessage(ErrorText.describe(error), app: app)
            }
        }
    }

    /// 不可用的行：文字变淡，封面去色变淡。
    static func dim(_ labels: [NSTextField], thumb: CALayer?, dimmed: Bool) {
        for label in labels { label.alphaValue = dimmed ? 0.5 : 1 }
        guard let thumb else { return }
        thumb.opacity = dimmed ? 0.4 : 1
        thumb.filters = dimmed ? [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0]) as Any] : nil
    }
}
