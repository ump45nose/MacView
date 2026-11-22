import AppKit
import MVFoundation
import MVLibraryData
import MVPipeline
import MVReading
import MVServices
import MVSettings
import Observation

/// 播放列表面板的视图设置（存 layout.json）：显示的列表。
struct PlaylistPanelSettings: Codable, Equatable {
    var selected: UUID?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selected = try container.decodeIfPresent(UUID.self, forKey: .selected)
    }
}

extension NSPasteboard.PasteboardType {
    /// 播放列表面板内排序：拖动的行号，拖动的位置在开始拖动时记下。
    fileprivate static let playlistRows = NSPasteboard.PasteboardType("com.macview.playlist-rows")
}

/// 播放列表：顶部选列表、当书打开；行是序号、缩略图、文件名、来自哪本书。
/// 多选、拖动排序、⌫ 从列表移除；双击从该项开始读；接收页面列表拖入的页。
@MainActor
final class PlaylistPanel: NSObject, DockPanel, PlaylistSelectionSource, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    typealias Settings = PlaylistPanelSettings

    private(set) var settings: PlaylistPanelSettings
    var onSettingsChange: (() -> Void)?
    var view: NSView { host }

    private weak var owner: ReaderWindowController?
    private weak var services: CoreServices?
    private let table = PlaylistTableView()
    private let host: LibraryPanelView
    private let header = PlaylistHeader()
    private let availability = LibraryAvailability()
    private var thumbnails: PlaylistThumbnails?

    private(set) var lists: [PlaylistSummary] = []
    /// 已读到的列表的项，按列表顺序；`itemsList` 是它们所属的列表。
    private(set) var items: [Entry] = []
    private var itemsList: UUID?
    private var loadError: String?
    private var listsLoaded = false
    private var listsToken = 0
    private var itemsToken = 0
    private var observer: Task<Void, Never>?
    private var isConfirmingDelete = false
    /// 新建的列表：读取到后立即进入改名。
    private var pendingRename: UUID?
    /// 正在改名的列表。
    private var renaming: UUID?
    /// 面板内拖动排序的项，开始拖动时记下。
    private var draggedItems: [Location] = []
    /// 窗口里当书打开的正是这个列表时，当前页对应的项。
    private var currentItem: Location?
    private var observedSession: SessionID?

    init(settings: PlaylistPanelSettings?) {
        self.settings = settings ?? PlaylistPanelSettings()
        host = LibraryPanelView(document: table)
        super.init()
        table.headerView = nil
        table.rowHeight = ceil(46 * Theme.fontScale(.panels))
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("playlist"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
        table.registerForDraggedTypes([.playlistRows, .locations])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.onContextMenu = { [weak self] row in self?.contextMenu(row: row) }
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onReturn = { [weak self] in self?.playSelected() }
        header.popup.target = self
        header.popup.action = #selector(listChosen(_:))
        header.play.target = self
        header.play.action = #selector(playPressed(_:))
        header.create.target = self
        header.create.action = #selector(createPressed(_:))
        header.field.delegate = self
        host.setInfo("", accessory: header)
        host.onShow = { [weak self] in self?.availability.recheckAll() }
        host.onScroll = { [weak self] in self?.availability.scrolled() }
        availability.view = host
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
        availability.visibleLocations = { [weak self] in self?.visibleLocations() ?? [] }
        availability.onChange = { [weak self] in self?.availabilityChanged() }
        render()
    }

    @objc private func applyFonts() {
        header.applyFonts()
        let savedOrigin = host.scroll.contentView.bounds.origin
        table.rowHeight = ceil(46 * Theme.fontScale(.panels))
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? PlaylistCell)?.applyFonts()
        }
        host.scroll.contentView.scroll(to: savedOrigin)
        host.scroll.reflectScrolledClipView(host.scroll.contentView)
        host.needsLayout = true
    }

    deinit {
        observer?.cancel()
    }

    func bind(to window: ReaderWindowController?) {
        owner = window
        if window?.session.id != observedSession {
            observedSession = window?.session.id
            observeSession()
        }
        let services = window?.services
        guard services !== self.services else { return }
        self.services = services
        thumbnails = services.map { PlaylistThumbnails(pipeline: $0.pipeline, settings: $0.settings) }
        availability.attach(services)
        observer?.cancel()
        observer = nil
        if let library = services?.library {
            let changes = library.changes()
            observer = Task { [weak self] in
                for await change in changes {
                    guard let self else { return }
                    switch change {
                    case .playlists, .playlistRemoved: reloadLists()
                    case let .items(id): if id == selectedID { reloadItems() }
                    case .relocated: reloadItems()
                    case .history, .bookmarks: break
                    }
                }
            }
        }
        listsLoaded = false
        reloadLists()
    }

    func addOptions(to menu: NSMenu) {
        for item in listMenuItems() { menu.addItem(item) }
    }

    var playlistSelection: (playlist: UUID, items: [Location])? {
        guard let id = itemsList, !table.selectedRowIndexes.isEmpty else { return nil }
        return (id, table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].location : nil })
    }

    /// 显示的列表：设置里记下的；没有记下或它已删除时是最近用的，再没有是第一个。
    private var selectedID: UUID? {
        if let id = settings.selected, lists.contains(where: { $0.id == id }) { return id }
        return LibraryActions.recentPlaylist(in: lists) ?? lists.first?.id
    }

    private var selectedList: PlaylistSummary? { lists.first { $0.id == selectedID } }

    // MARK: 读取

    private func reloadLists() {
        listsToken += 1
        let token = listsToken
        guard let library = services?.library else {
            apply(lists: [], error: nil)
            return
        }
        Task { [weak self] in
            do {
                let lists = try await library.playlists()
                guard let self, token == listsToken else { return }
                apply(lists: lists, error: nil)
            } catch {
                guard let self, token == listsToken else { return }
                apply(lists: [], error: ErrorText.describe(error))
            }
        }
    }

    private func apply(lists: [PlaylistSummary], error: String?) {
        self.lists = lists
        loadError = error
        if error == nil {
            listsLoaded = true
            if let id = settings.selected, !lists.contains(where: { $0.id == id }) {
                settings.selected = nil
                onSettingsChange?()
            }
        }
        if let renaming, !lists.contains(where: { $0.id == renaming }) { endRename(commit: false) }
        if selectedID == nil { isConfirmingDelete = false }
        if selectedID != itemsList {
            items = []
            itemsList = nil
            table.reloadData()
            reloadItems()
        }
        render()
        if let id = pendingRename, id == selectedID {
            pendingRename = nil
            beginRename()
        }
    }

    private func reloadItems() {
        itemsToken += 1
        let token = itemsToken
        guard let library = services?.library, let id = selectedID else {
            apply(items: [], of: nil)
            return
        }
        Task { [weak self] in
            // 列表刚被删除时读不到，随后的列表变化会换到别的列表。
            let entries = (try? await library.items(of: id)) ?? []
            guard let self, token == itemsToken else { return }
            apply(items: entries, of: id)
        }
    }

    private func apply(items entries: [Entry], of list: UUID?) {
        // 面板内排序已先改好顺序，存储的结果相同时不必重建表格。
        if list == itemsList, entries == items {
            render()
            return
        }
        let selected = list == itemsList ? Set(selectedLocations()) : []
        items = entries
        itemsList = list
        availability.retain(Set(entries.map(\.location)))
        table.reloadData()
        if !selected.isEmpty {
            table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].location) }), byExtendingSelection: false)
        }
        updateCurrent()
        render()
    }

    private func render() {
        let list = selectedList
        header.show(
            lists: lists, selected: list?.id, recent: LibraryActions.recentPlaylist(in: lists),
            isEmpty: listsLoaded && lists.isEmpty, isRenaming: renaming != nil
        )
        // 主按钮禁用时系统把文字画成禁用色，在深色底上看不见；只调透明度，空列表时点击不做事。
        header.play.alphaValue = canPlay ? 1 : 0.45
        header.create.isEnabled = services?.library != nil
        host.setBanner(isConfirmingDelete && list != nil ? deleteBanner(list!) : nil)
        if let loadError {
            host.setEmpty(title: String(localized: "读不出播放列表"), message: loadError)
        } else if listsLoaded, lists.isEmpty {
            host.setEmpty(title: String(localized: "还没有播放列表"), message: String(localized: "在页面列表里多选后右键“加到播放列表”，或点上方的“新建播放列表”。"))
        } else if list != nil, itemsList == list?.id, items.isEmpty {
            host.setEmpty(title: String(localized: "列表是空的"), message: String(localized: "在页面列表里多选后右键“加到播放列表”，或直接拖进来。"))
        } else {
            host.setEmpty(title: nil, message: "")
        }
        availability.visibleChanged()
    }

    /// 面板不在窗口里时没有可见行。
    private var visibleRows: Range<Int> {
        guard table.window != nil else { return 0..<0 }
        let range = table.rows(in: table.visibleRect)
        return max(range.location, 0)..<min(range.location + range.length, items.count)
    }

    private func visibleLocations() -> [Location] { visibleRows.map { items[$0].location } }

    private func selectedLocations() -> [Location] {
        table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].location : nil }
    }

    private func refreshVisibleCells() {
        for row in visibleRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistCell { configure(cell, row: row) }
        }
    }

    /// 恢复可用的项之前没取到缩略图的，重新取。
    private func availabilityChanged() {
        for row in visibleRows where availability.state(of: items[row].location) == .available {
            thumbnails?.forgetFailure(items[row].identity)
        }
        refreshVisibleCells()
    }

    // MARK: 当前项

    /// 当书打开的是这个列表时，跟随翻页标出当前项。
    private func observeSession() {
        guard let owner, let id = observedSession else {
            updateCurrent()
            return
        }
        withObservationTracking {
            _ = owner.session.currentFrame
            _ = owner.session.book?.location
            updateCurrent()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeSession()
            }
        }
    }

    private func updateCurrent() {
        var current: Location?
        if let session = owner?.session, let book = session.book, book.location.playlistID != nil,
           book.location.playlistID == itemsList, book.pages.indices.contains(session.currentPage) {
            current = book.pages[session.currentPage].id
        }
        guard current != currentItem else { return }
        currentItem = current
        refreshVisibleCells()
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("playlistCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PlaylistCell ?? {
            let cell = PlaylistCell()
            cell.identifier = id
            return cell
        }()
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LibraryRowView()
    }

    private func configure(_ cell: PlaylistCell, row: Int) {
        guard items.indices.contains(row) else { return }
        let entry = items[row]
        let location = entry.location
        let source: String
        if let book = LibraryActions.containingBook(of: location) {
            source = location.layers.count > 1 ? String(localized: "\(book.name) 内") : book.name
        } else {
            source = ""
        }
        cell.show(
            index: row + 1, isCurrent: location == currentItem, name: entry.name, source: source,
            availability: availability.state(of: location)
        )
        cell.badge.onPress = { [weak self, weak cell] in
            guard let self, let cell else { return }
            showReason(for: location, from: cell.badge)
        }
        loadThumbnail(entry.identity, into: cell)
    }

    /// 只为显示出来的行取缩略图；行被复用时取消。
    private func loadThumbnail(_ identity: ContentIdentity, into cell: PlaylistCell) {
        if cell.identity == identity, cell.hasImage || cell.imageTask != nil { return }
        cell.imageTask?.cancel()
        cell.imageTask = nil
        cell.identity = identity
        guard let thumbnails else {
            cell.setImage(nil)
            return
        }
        if let image = thumbnails.cached(identity) {
            cell.setImage(image)
            return
        }
        cell.setImage(nil)
        guard !thumbnails.failed(identity) else { return }
        let maxPixel = Int(PlaylistCell.thumbSide * (table.window?.backingScaleFactor ?? 2))
        cell.imageTask = Task { [weak cell] in
            let image = await thumbnails.load(identity, maxPixel: maxPixel)
            guard !Task.isCancelled, let cell, cell.identity == identity else { return }
            cell.imageTask = nil
            cell.setImage(image)
        }
    }

    // MARK: 打开

    /// 当书打开这个列表；给出项时从该项开始读，否则回到上次的页。
    private func play(from item: Location?) {
        guard let id = selectedID else { return }
        let book = Location.playlist(id)
        guard let controller = owner ?? (NSApp.delegate as? AppDelegate)?.newWindow() else { return }
        let session = controller.session
        if session.book?.location == book {
            guard let item else { return }
            if let index = session.book?.pages.firstIndex(where: { $0.id == item }) {
                session.go(.index(index))
                return
            }
        }
        Task { await session.open(book, at: item) }
    }

    private var canPlay: Bool { (selectedList?.count ?? 0) > 0 }

    @objc private func playPressed(_ sender: Any?) {
        if canPlay { play(from: nil) }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        playItem(at: row)
    }

    private func playSelected() {
        guard let row = table.selectedRowIndexes.first else { return }
        playItem(at: row)
    }

    /// 不可用的项弹出原因，不打开。
    private func playItem(at row: Int) {
        let location = items[row].location
        if availability.state(of: location)?.isUnavailable == true,
           let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PlaylistCell {
            showReason(for: location, from: cell.badge)
            return
        }
        play(from: location)
    }

    private func showReason(for location: Location, from badge: NSView) {
        guard let state = availability.state(of: location), state.isUnavailable else { return }
        UnavailableReasonPopover.show(
            state, what: String(localized: "原文件"), location: location, relativeTo: badge.bounds, of: badge
        ) { [weak self] in self?.remove([location]) }
    }

    // MARK: 右键与 ⋯ 菜单

    private func listMenuItems() -> [NSMenuItem] {
        let hasLibrary = services?.library != nil
        let create = MenuAction(String(localized: "新建播放列表")) { [weak self] in self?.createList() }.item
        create.isEnabled = hasLibrary
        let rename = MenuAction(String(localized: "重命名当前列表")) { [weak self] in self?.beginRename() }.item
        rename.isEnabled = hasLibrary && selectedList != nil
        let delete = MenuAction(String(localized: "删除当前列表…")) { [weak self] in self?.askToDelete() }.item
        delete.isEnabled = hasLibrary && selectedList != nil
        return [create, rename, delete]
    }

    private func contextMenu(row: Int?) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        defer { Theme.applyMenuFont(to: menu) }
        guard let row, items.indices.contains(row), let app = NSApp.delegate as? AppDelegate else {
            for item in listMenuItems() { menu.addItem(item) }
            return menu
        }
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let targets = selectedLocations()
        let location = items[row].location
        let single = targets.count == 1
        let unavailable = availability.state(of: location)?.isUnavailable == true
        menu.addItem(.sectionHeader(title: single ? items[row].name : String(localized: "已选 \(targets.count) 项")))
        let open = MenuAction(String(localized: "在虚拟书中打开这一项")) { [weak self] in self?.play(from: location) }.item
        open.isEnabled = single && !unavailable
        menu.addItem(open)
        let containing = MenuAction(String(localized: "打开所在的书")) {
            Task { await LibraryActions.openContainingBook(of: location, app: app) }
        }.item
        containing.isEnabled = single && !unavailable
        menu.addItem(containing)
        menu.addItem(.separator())
        let remove = MenuAction(String(localized: "从列表移除")) { [weak self] in self?.remove(targets) }.item
        remove.keyEquivalent = "\u{8}"
        remove.keyEquivalentModifierMask = []
        menu.addItem(remove)
        menu.addItem(.separator())
        let reveal = MenuAction(String(localized: "在 Finder 中显示")) { [weak self] in
            guard let services = self?.services else { return }
            // 压缩包里的页显示压缩包。
            let target = location.layers.count > 1 ? LibraryActions.containingBook(of: location) ?? location : location
            LibraryPanels.reveal(target, services: services)
        }.item
        reveal.isEnabled = single && !unavailable
        menu.addItem(reveal)
        return menu
    }

    // MARK: 修改

    /// ⌫：经“从播放列表移除”命令，与菜单栏同一个处理器；没有窗口时直接移除。
    private func removeSelected() {
        guard playlistSelection != nil else { return }
        if let owner {
            owner.run(.playlistRemoveItem)
        } else {
            remove(selectedLocations())
        }
    }

    /// 只拿掉条目，原文件不动。
    private func remove(_ locations: [Location]) {
        guard let id = itemsList, !locations.isEmpty, let app = NSApp.delegate as? AppDelegate else { return }
        Task { await LibraryActions.removeFromPlaylist(locations, playlist: id, app: app) }
    }

    @objc private func listChosen(_ sender: Any?) {
        guard let id = header.popup.selectedItem?.representedObject as? UUID, id != selectedID else { return }
        endRename(commit: true)
        settings.selected = id
        onSettingsChange?()
        isConfirmingDelete = false
        items = []
        itemsList = nil
        table.reloadData()
        reloadItems()
        render()
    }

    @objc private func createPressed(_ sender: Any?) { createList() }

    /// 新建“新播放列表 N”，显示它并进入改名。
    private func createList() {
        guard let library = services?.library else { return }
        Task { [weak self] in
            do {
                let names = Set(try await library.playlists().map(\.name))
                var number = names.count + 1
                while names.contains(String(localized: "新播放列表 \(number)")) { number += 1 }
                let id = try await library.createPlaylist(named: String(localized: "新播放列表 \(number)"))
                guard let self else { return }
                settings.selected = id
                onSettingsChange?()
                pendingRename = id
                reloadLists()
            } catch {
                self?.showError(error)
            }
        }
    }

    private func askToDelete() {
        guard selectedList != nil else { return }
        isConfirmingDelete = true
        render()
    }

    @objc private func cancelDelete(_ sender: Any?) {
        isConfirmingDelete = false
        render()
    }

    @objc private func confirmDelete(_ sender: Any?) {
        isConfirmingDelete = false
        render()
        guard let library = services?.library, let list = selectedList else { return }
        Task { [weak self] in
            do {
                try await library.deletePlaylist(list.id)
                guard let app = NSApp.delegate as? AppDelegate else { return }
                LibraryActions.showMessage(String(localized: "已删除「\(list.name)」，原文件不动"), app: app)
            } catch {
                self?.showError(error)
            }
        }
    }

    private func deleteBanner(_ list: PlaylistSummary) -> LibraryConfirmBanner {
        let cancel = UnavailableReasonPopover.button(String(localized: "取消"), primary: false)
        cancel.target = self
        cancel.action = #selector(cancelDelete(_:))
        let confirm = FlatButton(font: Theme.font(.panels, size: 12), fill: Theme.raised, foreground: Theme.danger, border: Theme.lineStrong, radius: 5, height: 22, padding: 9)
        confirm.setText(String(localized: "删除"))
        confirm.target = self
        confirm.action = #selector(confirmDelete(_:))
        return LibraryConfirmBanner(
            text: String(localized: "删除播放列表「\(list.name)」（\(list.count) 项）？只删除列表，原文件不动。"),
            buttons: [cancel, confirm]
        )
    }

    private func showError(_ error: any Error) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        LibraryActions.showMessage(ErrorText.describe(error), app: app)
    }

    // MARK: 改名

    private func beginRename() {
        guard let list = selectedList else { return }
        renaming = list.id
        header.field.stringValue = list.name
        render()
        host.window?.makeFirstResponder(header.field)
        header.field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === header.field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === header.field else { return }
        // 点到别处也算确认。
        endRename(commit: true)
    }

    /// 名字为空或没变时不改。
    private func endRename(commit: Bool) {
        guard let id = renaming else { return }
        renaming = nil
        let name = header.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editor = header.field.currentEditor(), host.window?.firstResponder === editor {
            host.window?.makeFirstResponder(table)
        }
        render()
        guard commit, !name.isEmpty, name != lists.first(where: { $0.id == id })?.name, let library = services?.library else { return }
        Task { [weak self] in
            do {
                try await library.renamePlaylist(id, to: name)
            } catch {
                self?.showError(error)
            }
        }
    }

    // MARK: 拖放

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(row), renaming == nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .playlistRows)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedItems = rowIndexes.compactMap { items.indices.contains($0) ? items[$0].location : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedItems = []
    }

    /// 本面板开始的拖动是排序；别处来的只认 `com.macview.locations`。
    private func isReorder(_ info: any NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSTableView) === table && !draggedItems.isEmpty
            && info.draggingPasteboard.availableType(from: [.playlistRows]) != nil
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard services?.library != nil, itemsList != nil, itemsList == selectedID else { return [] }
        let reorder = isReorder(info)
        guard reorder || info.draggingPasteboard.availableType(from: [.locations]) != nil else { return [] }
        if dropOperation == .on {
            // 落在行上：按上下半行放到它前面或后面。
            let point = tableView.convert(info.draggingLocation, from: nil)
            tableView.setDropRow(point.y < tableView.rect(ofRow: row).midY ? row : row + 1, dropOperation: .above)
        }
        return reorder ? .move : .generic
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let library = services?.library, let id = itemsList else { return false }
        let row = min(max(row, 0), items.count)
        if isReorder(info) {
            let moving = draggedItems
            draggedItems = []
            move(moving, to: row, in: id, library: library)
            return true
        }
        let locations = LibraryPasteboard.locations(from: info.draggingPasteboard)
        guard !locations.isEmpty, let app = NSApp.delegate as? AppDelegate else { return false }
        var present = Set(items.map(\.location))
        let added = locations.filter { present.insert($0).inserted }
        let insertAt = row
        let atEnd = row >= items.count
        Task {
            do {
                let entries = try await LibraryActions.entries(for: locations, app: app)
                guard await LibraryActions.addToPlaylist(entries, playlist: id, app: app) else { return }
                // 存储只能加在末尾；放到中间时再移动，失败明确提示。
                if !atEnd, !added.isEmpty { try await library.moveItems(added, in: id, to: insertAt) }
            } catch { LibraryActions.showMessage(ErrorText.describe(error), app: app) }
        }
        return true
    }

    /// 先在面板里改好顺序，再写入存储；写入失败时重新读取。存储按“先移除拖动项再插入”解释序号。
    private func move(_ moving: [Location], to row: Int, in id: UUID, library: any LibraryStore) {
        let set = Set(moving)
        let rows = IndexSet(items.indices.filter { set.contains(items[$0].location) })
        let position = row - rows.count(in: 0..<row)
        let target = IndexSet(position..<position + rows.count)
        guard !rows.isEmpty, rows != target else { return }
        let moved = rows.map { items[$0] }
        var reordered = items
        reordered.remove(atOffsets: rows)
        reordered.insert(contentsOf: moved, at: position)
        items = reordered
        // 行数不变：只重画可见行，不重建表格。
        table.reloadData(forRowIndexes: IndexSet(integersIn: visibleRows), columnIndexes: IndexSet(integer: 0))
        table.selectRowIndexes(target, byExtendingSelection: false)
        updateCurrent()
        availability.visibleChanged()
        let locations = moved.map(\.location)
        Task { [weak self] in
            do {
                try await library.moveItems(locations, in: id, to: position)
            } catch {
                self?.showError(error)
                self?.reloadItems()
            }
        }
    }
}

// MARK: - 缩略图

/// 按身份缓存的缩略图；额度跟随设置里的缩略图内存预算。取不到的记下，不再重试。
@MainActor
private final class PlaylistThumbnails {
    private let pipeline: any ImagePipeline
    private let cache = NSCache<NSString, Box>()
    private var failures: Set<String> = []

    private final class Box {
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

    func failed(_ identity: ContentIdentity) -> Bool { failures.contains(identity.cacheKey) }

    func forgetFailure(_ identity: ContentIdentity) { failures.remove(identity.cacheKey) }

    func load(_ identity: ContentIdentity, maxPixel: Int) async -> CGImage? {
        do {
            let image = try await pipeline.thumbnail(for: identity, maxPixel: maxPixel, priority: .visible).image
            cache.setObject(Box(image), forKey: identity.cacheKey as NSString, cost: image.bytesPerRow * image.height)
            return image
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { failures.insert(identity.cacheKey) }
            return nil
        }
    }
}

// MARK: - 顶部

/// 顶部：选列表的弹出按钮（项数，最近用的标“最近用”）与“▶ 当书打开”；没有列表时是“新建播放列表”；改名时弹出按钮换成输入框。
/// 放在面板外框的信息行里，占满整行。
@MainActor
private final class PlaylistHeader: NSView {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let play = UnavailableReasonPopover.button(String(localized: "▶ 当书打开"), primary: true)
    let create = UnavailableReasonPopover.button(String(localized: "新建播放列表"), primary: true)
    let field = NSTextField(string: "")

    init() {
        super.init(frame: .zero)
        popup.controlSize = .small
        popup.font = Theme.font(.menus, size: Theme.defaultSize(.menus))
        field.font = Theme.font(.panels, size: 12)
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        for view in [popup, play, create, field] as [NSView] { addSubview(view) }
    }

    func applyFonts() {
        popup.font = Theme.font(.menus, size: Theme.defaultSize(.menus))
        if let menu = popup.menu { Theme.applyMenuFont(to: menu) }
        let panelFont = Theme.font(.panels, size: 12)
        field.font = panelFont
        play.applyFont(panelFont)
        create.applyFont(panelFont)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var isFlipped: Bool { true }

    /// 外框按它的宽度排信息行：占满面板宽度减去两侧边距。
    override var fittingSize: NSSize {
        NSSize(width: max((superview?.bounds.width ?? 0) - 20, 0), height: 24)
    }

    override func layout() {
        super.layout()
        if !create.isHidden {
            let size = create.intrinsicContentSize
            create.frame = CGRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            return
        }
        let size = play.intrinsicContentSize
        play.frame = CGRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let left = CGRect(x: 0, y: 0, width: max(play.frame.minX - 6, 0), height: bounds.height)
        let popupHeight = popup.fittingSize.height
        popup.frame = CGRect(x: left.minX, y: (bounds.height - popupHeight) / 2, width: left.width, height: popupHeight)
        let fieldHeight: CGFloat = 22
        field.frame = CGRect(x: left.minX, y: (bounds.height - fieldHeight) / 2, width: left.width, height: fieldHeight)
    }

    func show(lists: [PlaylistSummary], selected: UUID?, recent: UUID?, isEmpty empty: Bool, isRenaming: Bool) {
        create.isHidden = !empty
        play.isHidden = empty
        popup.isHidden = empty || isRenaming
        field.isHidden = empty || !isRenaming
        let menu = NSMenu()
        for list in lists {
            var title = String(localized: "\(list.name)（\(list.count)）")
            if list.id == recent { title += String(localized: " · 最近用") }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = list.id
            menu.addItem(item)
        }
        Theme.applyMenuFont(to: menu)
        popup.menu = menu
        if let index = lists.firstIndex(where: { $0.id == selected }) { popup.selectItem(at: index) }
        needsLayout = true
    }
}

// MARK: - 行

/// 一行：序号（当书打开时当前项带“▸”）、缩略图、文件名、来自哪本书；不可用时变灰并显示右侧标记。
@MainActor
private final class PlaylistCell: NSView {
    static let thumbSide: CGFloat = 36
    private let index = NSTextField(labelWithString: "")
    private let thumb = CALayer()
    private let name = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    let badge = UnavailableBadge()
    var identity: ContentIdentity?
    var imageTask: Task<Void, Never>?
    private(set) var hasImage = false
    private var isDimmed = false
    private var isCurrentRow = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        thumb.cornerRadius = 3
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspectFill
        thumb.actions = ["contents": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(thumb)
        index.alignment = .right
        name.font = Theme.font(.panels, size: 13)
        name.textColor = Theme.text
        source.font = Theme.font(.panels, size: 11)
        source.textColor = Theme.text2
        for label in [index, name, source] {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(badge)
    }

    func applyFonts() {
        index.font = Theme.font(.panels, size: 11, weight: isCurrentRow ? .semibold : .regular, monospacedDigits: true)
        name.font = Theme.font(.panels, size: 13)
        source.font = Theme.font(.panels, size: 11)
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

    /// 只有标记接收点击，其余交给表格。
    override func hitTest(_ point: NSPoint) -> NSView? {
        badge.isHidden ? nil : badge.hitTest(convert(point, from: superview))
    }

    override func layout() {
        super.layout()
        index.frame = CGRect(x: 6, y: (bounds.height - 15) / 2, width: 32, height: 15)
        let side = Self.thumbSide
        let thumbFrame = CGRect(x: index.frame.maxX + 6, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = thumbFrame
        CATransaction.commit()
        badge.frame = CGRect(x: bounds.width - 10 - 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let x = thumbFrame.maxX + 8
        let width = max((badge.isHidden ? bounds.width - 10 : badge.frame.minX - 4) - x, 0)
        let top = (bounds.height - 32) / 2
        name.frame = CGRect(x: x, y: top, width: width, height: 17)
        source.frame = CGRect(x: x, y: top + 17, width: width, height: 15)
    }

    func show(index number: Int, isCurrent: Bool, name: String, source: String, availability: Availability?) {
        isCurrentRow = isCurrent
        index.stringValue = isCurrent ? "▸\(number)" : "\(number)"
        index.font = Theme.font(.panels, size: 11, weight: isCurrent ? .semibold : .regular, monospacedDigits: true)
        index.textColor = isCurrent ? Theme.text : Theme.text2
        self.name.stringValue = name
        self.source.stringValue = source
        badge.show(availability)
        let dimmed = availability?.isUnavailable == true
        if dimmed != isDimmed {
            isDimmed = dimmed
            LibraryPanels.dim([self.name, self.source], thumb: thumb, dimmed: dimmed)
        }
        needsLayout = true
    }

    func setImage(_ image: CGImage?) {
        thumb.contents = image
        hasImage = image != nil
    }
}

/// 播放列表的表格：任意位置可点，右键菜单按行给出；⌫ 从列表移除，回车从选中项开始读。
@MainActor
private final class PlaylistTableView: NSTableView {
    var onContextMenu: ((Int?) -> NSMenu?)?
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 与书架表格相同，明确走 mouseDown 的 AppKit 跟踪入口。
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch event.specialKey {
        case .delete?, .deleteForward?:
            if plain { onDelete?() } else { super.keyDown(with: event) }
        case .carriageReturn?, .enter?:
            if plain { onReturn?() } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(row >= 0 ? row : nil)
    }
}
