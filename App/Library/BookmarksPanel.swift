import AppKit
import MVFoundation
import MVLibraryData
import MVServices

/// 书签面板的视图设置（存 layout.json）：收起的文件夹。
struct BookmarksPanelSettings: Codable, Equatable {
    var collapsed: Set<BookmarkID> = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collapsed = try container.decodeIfPresent(Set<BookmarkID>.self, forKey: .collapsed) ?? []
    }
}

extension NSPasteboard.PasteboardType {
    /// 书签面板内排序：拖动的书签 ID。
    fileprivate static let bookmarkIDs = NSPasteboard.PasteboardType("com.macview.bookmark-ids")
}

/// 书签树的一项。每次读取后重建，展开状态按 ID 恢复。
@MainActor
private final class BookmarkItem: NSObject {
    let id: BookmarkID
    /// 书的位置；文件夹为 nil。
    let location: Location?
    /// 文件夹名；书的自定义显示名（没有时为 nil）。
    let label: String?
    var children: [BookmarkItem] = []
    weak var parent: BookmarkItem?

    init(id: BookmarkID, location: Location?, label: String?) {
        self.id = id
        self.location = location
        self.label = label
    }

    var isFolder: Bool { location == nil }
    /// 显示名：文件夹名，或书的自定义名、原名。
    var title: String { label ?? location?.name ?? "" }
    /// 文件夹里（含子文件夹）的书数。
    var bookCount: Int { children.reduce(0) { $0 + ($1.isFolder ? $1.bookCount : 1) } }
}

/// 书签：可多级文件夹的树。单击书打开并回到上次的页；双击或右键改显示名；拖动排序、拖进文件夹；接收书架拖入。
@MainActor
final class BookmarksPanel: NSObject, DockPanel, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    typealias Settings = BookmarksPanelSettings

    private(set) var settings: BookmarksPanelSettings
    var onSettingsChange: (() -> Void)?
    var view: NSView { host }

    private weak var owner: ReaderWindowController?
    private weak var services: CoreServices?
    private let outline = LibraryOutlineView()
    private let host: LibraryPanelView
    private let addFolderButton = UnavailableReasonPopover.button(String(localized: "＋ 文件夹"), primary: false)
    private let availability = LibraryAvailability()

    private var roots: [BookmarkItem] = []
    private var items: [BookmarkID: BookmarkItem] = [:]
    private var loadError: String?
    private var reloadToken = 0
    private var observer: Task<Void, Never>?
    /// 正在改名的项与输入框；改名期间的重新读取推迟到结束后。
    private var editing: (id: BookmarkID, field: NSTextField)?
    private var needsReload = false
    /// 新建的文件夹：读取到后立即进入改名。
    private var pendingRename: BookmarkID?
    /// 程序恢复展开状态时不记入设置。
    private var isRestoringExpansion = false

    init(settings: BookmarksPanelSettings?) {
        self.settings = settings ?? BookmarksPanelSettings()
        host = LibraryPanelView(document: outline)
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmarks"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.registerForDraggedTypes([.bookmarkIDs, .locations])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.onContextMenu = { [weak self] row in self?.contextMenu(row: row) }
        addFolderButton.target = self
        addFolderButton.action = #selector(addFolderPressed(_:))
        host.setInfo(String(localized: "书签"), accessory: addFolderButton)
        host.onShow = { [weak self] in self?.availability.recheckAll() }
        host.onScroll = { [weak self] in self?.availability.visibleChanged() }
        availability.view = host
        availability.visibleLocations = { [weak self] in self?.visibleLocations() ?? [] }
        availability.onChange = { [weak self] in self?.refreshVisibleCells() }
        render()
    }

    deinit { observer?.cancel() }

    func bind(to window: ReaderWindowController?) {
        owner = window
        let services = window?.services
        guard services !== self.services else { return }
        self.services = services
        availability.attach(services)
        observer?.cancel()
        observer = nil
        if let library = services?.library {
            let changes = library.changes()
            observer = Task { [weak self] in
                for await change in changes where change == .bookmarks || change == .relocated {
                    guard let self else { return }
                    reload()
                }
            }
        }
        reload()
    }

    func addOptions(to menu: NSMenu) {
        let item = MenuAction(String(localized: "新建文件夹")) { [weak self] in self?.newFolder(in: nil) }.item
        item.isEnabled = services?.library != nil
        menu.addItem(item)
    }

    // MARK: 读取

    private func reload() {
        guard editing == nil else {
            needsReload = true
            return
        }
        needsReload = false
        reloadToken += 1
        let token = reloadToken
        guard let library = services?.library else {
            apply([], error: nil)
            return
        }
        Task { [weak self] in
            do {
                let nodes = try await library.bookmarks()
                guard let self, token == reloadToken else { return }
                apply(nodes, error: nil)
            } catch {
                guard let self, token == reloadToken else { return }
                apply([], error: ErrorText.describe(error))
            }
        }
    }

    private func apply(_ nodes: [BookmarkNode], error: String?) {
        guard editing == nil else {
            needsReload = true
            return
        }
        let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? BookmarkItem)?.id })
        items = [:]
        roots = nodes.map { build($0, parent: nil) }
        loadError = error
        let folders = Set(items.values.filter(\.isFolder).map(\.id))
        if !settings.collapsed.isSubset(of: folders), error == nil {
            settings.collapsed.formIntersection(folders)
            onSettingsChange?()
        }
        availability.retain(Set(items.values.compactMap(\.location)))
        outline.reloadData()
        restoreExpansion(roots)
        let rows = selected.compactMap { items[$0].map(outline.row(forItem:)) }.filter { $0 >= 0 }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        render()
        if let id = pendingRename, let item = items[id] {
            pendingRename = nil
            beginRename(item)
        }
    }

    private func build(_ node: BookmarkNode, parent: BookmarkItem?) -> BookmarkItem {
        let item: BookmarkItem
        switch node {
        case let .folder(id, name, children):
            item = BookmarkItem(id: id, location: nil, label: name)
            item.children = children.map { build($0, parent: item) }
        case let .book(id, location, label):
            item = BookmarkItem(id: id, location: location, label: label?.isEmpty == true ? nil : label)
        }
        item.parent = parent
        items[item.id] = item
        return item
    }

    private func restoreExpansion(_ level: [BookmarkItem]) {
        let outer = isRestoringExpansion
        isRestoringExpansion = true
        defer { isRestoringExpansion = outer }
        for item in level where item.isFolder && !settings.collapsed.contains(item.id) {
            outline.expandItem(item)
            restoreExpansion(item.children)
        }
    }

    private func render() {
        if let loadError {
            host.setEmpty(title: String(localized: "读不出书签"), message: loadError)
        } else if roots.isEmpty {
            host.setEmpty(title: String(localized: "还没有书签"), message: String(localized: "按 ⌘D 收藏当前书，或从书架拖进来。"))
        } else {
            host.setEmpty(title: nil, message: "")
        }
        addFolderButton.isEnabled = services?.library != nil
        availability.visibleChanged()
    }

    private func visibleLocations() -> [Location] {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<range.location + range.length).compactMap { (outline.item(atRow: $0) as? BookmarkItem)?.location }
    }

    private func refreshVisibleCells() {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<range.location + range.length {
            guard let item = outline.item(atRow: row) as? BookmarkItem,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCell,
                  editing?.id != item.id else { continue }
            configure(cell, item: item)
        }
    }

    // MARK: 大纲

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BookmarkItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? BookmarkItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BookmarkItem)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? BookmarkItem)?.isFolder == true ? 28 : 40
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        LibraryRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? BookmarkItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("bookmarkCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? BookmarkCell ?? {
            let cell = BookmarkCell()
            cell.identifier = id
            return cell
        }()
        configure(cell, item: item)
        return cell
    }

    private func configure(_ cell: BookmarkCell, item: BookmarkItem) {
        if let location = item.location {
            let detail = item.label != nil ? String(localized: "原名：\(location.name)") : location.parent?.displayPath ?? ""
            let isArchive = if case .archive = EntryKind(fileName: location.name) { true } else { false }
            cell.showBook(title: item.title, detail: detail, isArchive: isArchive, availability: availability.state(of: location))
            cell.badge.onPress = { [weak self, weak cell] in
                guard let self, let cell else { return }
                showReason(for: item, from: cell.badge)
            }
        } else {
            cell.showFolder(title: item.title, count: item.bookCount)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion, let item = notification.userInfo?["NSObject"] as? BookmarkItem else { return }
        if settings.collapsed.remove(item.id) != nil { onSettingsChange?() }
        // 子文件夹按各自记下的状态展开。
        restoreExpansion(item.children)
        availability.visibleChanged()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion, let item = notification.userInfo?["NSObject"] as? BookmarkItem else { return }
        if settings.collapsed.insert(item.id).inserted { onSettingsChange?() }
        availability.visibleChanged()
    }

    // MARK: 点击

    @objc private func rowClicked(_ sender: Any?) {
        guard editing == nil, let item = outline.item(atRow: outline.clickedRow) as? BookmarkItem, let location = item.location,
              NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true else { return }
        if availability.state(of: location)?.isUnavailable == true,
           let cell = outline.view(atColumn: 0, row: outline.clickedRow, makeIfNecessary: false) as? BookmarkCell {
            showReason(for: item, from: cell.badge)
            return
        }
        LibraryPanels.open(location, from: owner)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.clickedRow) as? BookmarkItem else { return }
        beginRename(item)
    }

    @objc private func addFolderPressed(_ sender: Any?) {
        newFolder(in: nil)
    }

    private func showReason(for item: BookmarkItem, from badge: NSView) {
        guard let location = item.location, let state = availability.state(of: location), state.isUnavailable else { return }
        let id = item.id
        UnavailableReasonPopover.show(
            state, what: String(localized: "这本书"), location: location, relativeTo: badge.bounds, of: badge
        ) { [weak self] in self?.remove([id]) }
    }

    // MARK: 右键菜单

    private func contextMenu(row: Int?) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let row, let item = outline.item(atRow: row) as? BookmarkItem else {
            menu.addItem(MenuAction(String(localized: "新建文件夹")) { [weak self] in self?.newFolder(in: nil) }.item)
            return menu
        }
        if let location = item.location {
            let unavailable = availability.state(of: location)?.isUnavailable == true
            let open = MenuAction(String(localized: "打开")) { [weak self] in LibraryPanels.open(location, from: self?.owner) }.item
            open.isEnabled = !unavailable
            menu.addItem(open)
            menu.addItem(MenuAction(String(localized: "重命名")) { [weak self] in self?.beginRename(item) }.item)
            if item.label != nil {
                menu.addItem(MenuAction(String(localized: "恢复原名")) { [weak self] in self?.rename(item.id, to: nil) }.item)
            }
            menu.addItem(MenuAction(String(localized: "新建文件夹")) { [weak self] in self?.newFolder(in: item.parent) }.item)
            menu.addItem(.separator())
            let reveal = MenuAction(String(localized: "在 Finder 中显示")) { [weak self] in
                guard let services = self?.services else { return }
                LibraryPanels.reveal(location, services: services)
            }.item
            reveal.isEnabled = !unavailable
            menu.addItem(reveal)
        } else {
            menu.addItem(MenuAction(String(localized: "重命名")) { [weak self] in self?.beginRename(item) }.item)
            menu.addItem(MenuAction(String(localized: "新建文件夹")) { [weak self] in self?.newFolder(in: item) }.item)
        }
        menu.addItem(.separator())
        // 右键的行在选中项里且选中了多项时，移除全部选中项。
        let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? BookmarkItem }
        let targets = selected.count > 1 && selected.contains(item) ? selected : [item]
        let title = if targets.count > 1 {
            String(localized: "移除选中的 \(targets.count) 项")
        } else if item.isFolder {
            String(localized: "移除文件夹（含 \(item.bookCount) 条）")
        } else {
            String(localized: "从书签中移除")
        }
        let ids = targets.map(\.id)
        menu.addItem(MenuAction(title) { [weak self] in self?.remove(ids) }.item)
        return menu
    }

    // MARK: 修改

    private func newFolder(in parent: BookmarkItem?) {
        guard let library = services?.library else { return }
        let parentID = parent?.id
        Task { [weak self] in
            do {
                let id = try await library.addBookmarkFolder(named: String(localized: "新文件夹"), into: parentID, at: nil)
                guard let self else { return }
                if let parentID, settings.collapsed.remove(parentID) != nil { onSettingsChange?() }
                pendingRename = id
                reload()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func remove(_ ids: [BookmarkID]) {
        guard let library = services?.library else { return }
        Task { [weak self] in
            do {
                try await library.removeBookmarks(ids)
            } catch {
                self?.showError(error)
            }
        }
    }

    /// 书：nil 恢复原名；文件夹：新名字。
    private func rename(_ id: BookmarkID, to name: String?) {
        guard let library = services?.library else { return }
        Task { [weak self] in
            do {
                try await library.renameBookmark(id, to: name)
            } catch {
                self?.showError(error)
            }
        }
    }

    private func showError(_ error: any Error) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        LibraryActions.showMessage(ErrorText.describe(error), app: app)
    }

    // MARK: 改名

    private func beginRename(_ item: BookmarkItem) {
        finishRename(commit: true)
        // 收起的祖先先展开，行才存在。
        var ancestors: [BookmarkItem] = []
        var parent = item.parent
        while let current = parent {
            ancestors.insert(current, at: 0)
            parent = current.parent
        }
        for ancestor in ancestors { outline.expandItem(ancestor) }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.scrollRowToVisible(row)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? BookmarkCell else { return }
        let field = cell.name
        field.stringValue = item.title
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = Theme.raised
        field.delegate = self
        editing = (item.id, field)
        outline.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editing?.field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRename(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === editing?.field else { return }
        // 点到别处也算确认。
        finishRename(commit: true)
    }

    /// 结束改名。书的名字为空或与原名相同时恢复原名；文件夹的名字为空时不改。
    private func finishRename(commit: Bool) {
        guard let current = editing else { return }
        editing = nil
        let field = current.field
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        if let editor = field.currentEditor(), outline.window?.firstResponder === editor {
            outline.window?.makeFirstResponder(outline)
        }
        if commit, let item = items[current.id] {
            if let location = item.location {
                let label = value.isEmpty || value == location.name ? nil : value
                if label != item.label { rename(item.id, to: label) }
            } else if !value.isEmpty, value != item.label {
                rename(item.id, to: value)
            }
        }
        if needsReload {
            reload()
        } else if let item = items[current.id] {
            let row = outline.row(forItem: item)
            if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? BookmarkCell { configure(cell, item: item) }
        }
    }

    // MARK: 拖放

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard editing == nil, let item = item as? BookmarkItem else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(item.id.raw.uuidString, forType: .bookmarkIDs)
        return writer
    }

    private func draggedIDs(_ info: any NSDraggingInfo) -> [BookmarkID] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: .bookmarkIDs).flatMap(UUID.init(uuidString:)).map { BookmarkID(raw: $0) }
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard services?.library != nil else { return [] }
        let ids = draggedIDs(info)
        guard !ids.isEmpty || info.draggingPasteboard.availableType(from: [.locations]) != nil else { return [] }
        var target = item as? BookmarkItem
        if let book = target, !book.isFolder {
            // 落在书上：按上下半行放到它前面或后面。
            let siblings = book.parent?.children ?? roots
            let position = siblings.firstIndex(of: book) ?? siblings.count
            let rect = outlineView.rect(ofRow: outlineView.row(forItem: book))
            let point = outlineView.convert(info.draggingLocation, from: nil)
            target = book.parent
            outlineView.setDropItem(target, dropChildIndex: point.y < rect.midY ? position : position + 1)
        }
        guard !ids.isEmpty else { return .generic }
        // 文件夹不能放进自己或自己下面。
        let moving = Set(ids)
        var ancestor = target
        while let current = ancestor {
            if moving.contains(current.id) { return [] }
            ancestor = current.parent
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let library = services?.library else { return false }
        let folder = item as? BookmarkItem
        let siblings = folder?.children ?? roots
        if let folder, settings.collapsed.remove(folder.id) != nil { onSettingsChange?() }
        let ids = draggedIDs(info)
        if !ids.isEmpty {
            // 存储按“先移除拖动项再插入”解释序号。
            let moving = Set(ids)
            let end = index < 0 ? siblings.count : min(index, siblings.count)
            let position = siblings[..<end].filter { !moving.contains($0.id) }.count
            Task { [weak self] in
                do {
                    try await library.moveBookmarks(ids, into: folder?.id, at: position)
                } catch {
                    self?.showError(error)
                }
            }
            return true
        }
        let books = LibraryPasteboard.locations(from: info.draggingPasteboard)
        guard !books.isEmpty, let app = NSApp.delegate as? AppDelegate else { return false }
        let folderID = folder?.id
        Task { await LibraryActions.addBookmarks(books, into: folderID, at: index < 0 ? nil : index, app: app) }
        return true
    }
}

// MARK: - 行

/// 书签的一行。文件夹：图标、名称、书数；书：图标、显示名、第二行原名或所在路径，不可用时变灰并显示右侧标记。
@MainActor
private final class BookmarkCell: NSView {
    private let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    let badge = UnavailableBadge()
    private var isFolder = false

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Theme.text2
        name.font = .systemFont(ofSize: 13)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.cell?.isScrollable = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = Theme.text2
        detail.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: 11)
        count.textColor = Theme.text2
        for view in [icon, name, detail, count, badge] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 改名时输入框接收点击；不改名时只有标记接收，其余交给大纲（它接受第一次点击）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if name.isEditable { return super.hitTest(point) }
        return badge.isHidden ? nil : badge.hitTest(convert(point, from: superview))
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
        var right = bounds.width - 10
        if !badge.isHidden {
            badge.frame = CGRect(x: right - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
            right = badge.frame.minX - 4
        }
        if !count.isHidden {
            let width = count.intrinsicContentSize.width
            count.frame = CGRect(x: right - width, y: (bounds.height - 15) / 2, width: width, height: 15)
            right = count.frame.minX - 6
        }
        let x = icon.frame.maxX + 6
        let width = max(right - x, 0)
        if isFolder {
            name.frame = CGRect(x: x, y: (bounds.height - 18) / 2, width: width, height: 18)
        } else {
            let top = (bounds.height - 33) / 2
            name.frame = CGRect(x: x, y: top, width: width, height: 18)
            detail.frame = CGRect(x: x, y: top + 18, width: width, height: 15)
        }
    }

    func showFolder(title: String, count: Int) {
        isFolder = true
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        name.stringValue = title
        detail.isHidden = true
        self.count.isHidden = false
        self.count.stringValue = "\(count)"
        badge.show(nil)
        LibraryPanels.dim([name], thumb: nil, dimmed: false)
        icon.alphaValue = 1
        needsLayout = true
    }

    func showBook(title: String, detail: String, isArchive: Bool, availability: Availability?) {
        isFolder = false
        icon.image = NSImage(systemSymbolName: isArchive ? "doc.zipper" : "folder", accessibilityDescription: nil)
        name.stringValue = title
        self.detail.stringValue = detail
        self.detail.isHidden = false
        count.isHidden = true
        badge.show(availability)
        let dimmed = availability?.isUnavailable == true
        LibraryPanels.dim([name, self.detail], thumb: nil, dimmed: dimmed)
        icon.alphaValue = dimmed ? 0.4 : 1
        needsLayout = true
    }
}

/// 书签的大纲视图：任意位置可点，右键菜单按行给出。
@MainActor
private final class LibraryOutlineView: NSOutlineView {
    var onContextMenu: ((Int?) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(row >= 0 ? row : nil)
    }
}
