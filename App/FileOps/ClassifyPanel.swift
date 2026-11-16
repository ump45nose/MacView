import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVReading
import MVServices
import MVSettings

/// 分类面板的视图设置（存 `layout.json`）：记录已收起子文件夹的目标位置。
struct ClassifyPanelSettings: Codable, Hashable, Sendable { var collapsed: Set<Location> = [] }

@MainActor
private final class ClassifyFieldEditor: NSTextView {
    override func keyDown(with event: NSEvent) {
        if NSApp.isActive { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76: doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case 53: doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case 51: deleteBackward(nil)
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let chars = event.characters, !chars.isEmpty {
                insertText(chars, replacementRange: selectedRange())
            } else { super.keyDown(with: event) }
        }
    }
}

@MainActor
private final class ClassifyTextFieldCell: NSTextFieldCell {
    private let editor: ClassifyFieldEditor = {
        let v = ClassifyFieldEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 20)); v.isFieldEditor = true; return v
    }()
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

@MainActor
final class ClassifyInputField: NSTextField {
    override class var cellClass: AnyClass? { get { ClassifyTextFieldCell.self } set {} }
}

/// 分类面板（设计稿 1）：移动/复制切换、目标与子文件夹列表、1…9/0 编号、新建目标并移入、顶层拖动排序、卷健康度与 Clay 闪烁反馈。
@MainActor
final class ClassifyPanel: NSObject, DockPanel, NSTextFieldDelegate {
    struct Row: Equatable {
        var location: Location, name: String, title: String, whereText: String
        var isSubfolder: Bool, parentLocation: Location?, listsSubfolders: Bool, isExpanded: Bool
        var isNetwork: Bool, isUnavailable: Bool, errorText: String?, keyBadge: String?
    }

    private(set) var settings: ClassifyPanelSettings { didSet { if settings != oldValue { onSettingsChange?() } } }
    var onSettingsChange: (() -> Void)?
    weak var owner: ReaderWindowController?
    let panelView = ClassifyPanelView()
    var view: NSView { panelView }

    private(set) var visibleRows: [Row] = []
    private(set) var selectedLocation: Location?, editingLocation: Location?
    private(set) var newTargetOrigin = FileOrigin()
    private(set) var newTargetError: String?, newTargetRetry: FileOperation?
    private var createdDirectoryLocation: Location?, isSubmittingNewTarget = false
    private var subfoldersByTarget: [Location: [Entry]] = [:], subfolderErrors: [Location: String] = [:]
    private var unhealthyRoots: Set<Location.Root> = [], observedServicesID: ObjectIdentifier?
    private var settingsTask: Task<Void, Never>?, changesTask: Task<Void, Never>?, healthTask: Task<Void, Never>?

    var visibleDestinations: [(location: Location, title: String)] { visibleRows.map { ($0.location, $0.title) } }

    var isArchiveBook: Bool {
        if let book = owner?.session.book, book.location.layers.count > 1 { return true }
        let items = owner?.fileOrigin().items ?? []
        return !items.isEmpty && items.contains { $0.location.layers.count > 1 }
    }

    var canBeginNewTarget: Bool {
        guard let owner, owner.services.fileOperations != nil, selectedLocation != nil, !isArchiveBook else { return false }
        let items = owner.fileOrigin().items
        return !items.isEmpty && items.allSatisfy { $0.location.layers.count == 1 }
    }

    init(_ settings: ClassifyPanelSettings?) {
        self.settings = settings ?? ClassifyPanelSettings(); super.init(); wireView()
    }

    deinit { settingsTask?.cancel(); changesTask?.cancel(); healthTask?.cancel() }

    private func wireView() {
        panelView.modeControl.onSelect = { [weak self] idx in self?.owner?.fileOps.setClassifyMode(idx == 0 ? .move : .copy); self?.refreshState() }
        panelView.addButton.target = self; panelView.addButton.action = #selector(chooseTargetsClicked(_:))
        panelView.emptyAddButton.target = self; panelView.emptyAddButton.action = #selector(chooseTargetsClicked(_:))
        panelView.newTargetButton.target = self; panelView.newTargetButton.action = #selector(newTargetClicked(_:))
        let list = panelView.listView
        list.inputField.delegate = self; list.retryButton.target = self; list.retryButton.action = #selector(retryNewTargetClicked(_:))
        list.onSelect = { [weak self] loc in self?.selectRow(at: loc) }
        list.onDoubleClick = { [weak self] loc in self?.classify(into: loc) }
        list.onToggleCollapse = { [weak self] loc in self?.toggleCollapse(for: loc) }
        list.onMoveTarget = { [weak self] src, dst in self?.moveTarget(src, toTopLevelIndex: dst) }
        list.onContextMenu = { [weak self] row in self?.contextMenu(for: row) }
    }

    func bind(to window: ReaderWindowController?) {
        owner = window; startObservationsIfNeeded()
        Task { @MainActor [weak self] in await self?.reloadAllSubfolders() }
        refreshState()
    }

    func addOptions(to menu: NSMenu) {
        let item = MenuAction(String(localized: "清空回收目录…")) { [weak self] in self?.owner?.run(.recycleEmpty) }.item
        item.isEnabled = owner?.services.fileOperations != nil; menu.addItem(item)
    }

    private func startObservationsIfNeeded() {
        guard let services = owner?.services, observedServicesID != ObjectIdentifier(services) else { return }
        observedServicesID = ObjectIdentifier(services)
        settingsTask?.cancel(); changesTask?.cancel(); healthTask?.cancel()
        settingsTask = Task { [weak self] in
            for await change in services.settings.changes() {
                guard !Task.isCancelled, let self, change == .global else { continue }
                await self.reloadAllSubfolders()
            }
        }
        changesTask = Task { [weak self] in
            for await batch in services.appliedFileChanges() {
                guard !Task.isCancelled, let self else { return }
                await self.handleAppliedChanges(batch)
            }
        }
        healthTask = Task { [weak self] in
            for await volumes in services.sources.volumeHealth() {
                guard !Task.isCancelled, let self else { return }
                self.unhealthyRoots = Set(volumes.filter { $0.state != .healthy }.map(\.root)); self.refreshState()
            }
        }
    }

    private func handleAppliedChanges(_ batch: [FileChange]) async {
        var changedParents: Set<Location> = []
        for change in batch {
            switch change {
            case let .added(entry): if let p = entry.location.parent { changedParents.insert(p) }
            case let .removed(loc):
                if let p = loc.parent { changedParents.insert(p) }
                if loc == createdDirectoryLocation { cancelNewTarget() }
            case let .moved(from, toEntry):
                if let p = from.parent { changedParents.insert(p) }
                if let p = toEntry.location.parent { changedParents.insert(p) }
            }
        }
        var needsRefresh = false
        for target in owner?.fileOps.fileSettings.classifyTargets ?? [] where target.listsSubfolders && changedParents.contains(target.location) {
            await reloadSubfolders(for: target.location); needsRefresh = true
        }
        if needsRefresh { refreshState() }
    }

    func reloadAllSubfolders() async {
        guard let owner else { refreshState(); return }
        let ops = await owner.services.settings.global().fileOperations
        for target in ops.classifyTargets where target.listsSubfolders { await reloadSubfolders(for: target.location) }
        await owner.fileOps.reloadSettings(); refreshState()
    }

    func reloadSubfolders(for targetLocation: Location) async {
        guard let services = owner?.services else { return }
        do {
            let provider = try services.sources.provider(for: targetLocation)
            var entries: [Entry] = []
            for try await batch in provider.children(of: targetLocation, priority: .near) {
                entries.append(contentsOf: batch.filter { $0.kind == .directory && ReadingListing.isVisible($0) })
            }
            subfoldersByTarget[targetLocation] = ReadingOrder.sorted(entries, by: SortSpec(key: .name))
            subfolderErrors[targetLocation] = nil
        } catch {
            subfoldersByTarget[targetLocation] = []; subfolderErrors[targetLocation] = ErrorText.describe(error)
        }
    }

    func refreshState() {
        guard let owner else { panelView.showUnsupported(false); return }
        if owner.services.fileOperations == nil { panelView.showUnsupported(true); return }
        panelView.showUnsupported(false)
        let ops = owner.fileOps.fileSettings
        var rows: [Row] = []
        for target in ops.classifyTargets {
            let isExpanded = target.listsSubfolders && !settings.collapsed.contains(target.location)
            let isNet = owner.fileOps.isNetworkVolume(target.location), unavailable = unhealthyRoots.contains(target.location.root)
            rows.append(Row(
                location: target.location, name: target.location.name, title: target.location.name,
                whereText: Self.shortWhere(for: target.location), isSubfolder: false, parentLocation: nil,
                listsSubfolders: target.listsSubfolders, isExpanded: isExpanded, isNetwork: isNet,
                isUnavailable: unavailable, errorText: target.listsSubfolders ? subfolderErrors[target.location] : nil, keyBadge: nil
            ))
            if isExpanded, let children = subfoldersByTarget[target.location] {
                for child in children {
                    rows.append(Row(
                        location: child.location, name: child.name, title: "\(target.location.name) / \(child.name)",
                        whereText: "", isSubfolder: true, parentLocation: target.location, listsSubfolders: false,
                        isExpanded: false, isNetwork: isNet, isUnavailable: unavailable, errorText: nil, keyBadge: nil
                    ))
                }
            }
        }
        for idx in rows.indices where idx < 10 { rows[idx].keyBadge = idx < 9 ? "\(idx + 1)" : "0" }
        visibleRows = rows
        if selectedLocation == nil || !rows.contains(where: { $0.location == selectedLocation }) {
            selectedLocation = rows.first?.location
        }
        if let editing = editingLocation, !rows.contains(where: { $0.location == editing }) {
            restoreViewerFocus(); editingLocation = nil; createdDirectoryLocation = nil; newTargetError = nil; newTargetRetry = nil
        }
        panelView.render(
            mode: ops.classifyMode, rows: rows, selectedLocation: selectedLocation,
            editingLocation: editingLocation, errorText: newTargetError, showsRetry: newTargetRetry != nil,
            isArchive: isArchiveBook, canNewTarget: canBeginNewTarget
        )
    }

    private static func shortWhere(for location: Location) -> String {
        switch location.root {
        case .local:
            guard let layers = location.layers.first, layers.count > 1 else { return "/" }
            let parentPath = "/" + layers.dropLast().joined(separator: "/"), home = NSHomeDirectory()
            if parentPath == home { return "~" }
            if parentPath.hasPrefix(home + "/") { return "~" + String(parentPath.dropFirst(home.count)) }
            return layers.dropLast().last ?? "/"
        case let .network(_, _, share): return location.parent?.name.isEmpty == false ? (location.parent?.name ?? share) : share
        case let .plugin(id): return location.parent?.name ?? id
        }
    }

    @objc private func chooseTargetsClicked(_ sender: Any?) {
        guard let owner, let window = view.window ?? owner.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.canCreateDirectories = true
        panel.prompt = String(localized: "添加")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty, let self else { return }
            Task { @MainActor in await self.addTargetURLs(panel.urls) }
        }
    }

    func addTargetURLs(_ urls: [URL], listsSubfolders: Bool = false) async {
        guard let owner else { return }
        var locations: [Location] = []
        for url in urls { if let loc = try? await owner.services.sources.location(for: url) { locations.append(loc) } }
        await addTargets(locations, listsSubfolders: listsSubfolders)
    }

    func addTargets(_ locations: [Location], listsSubfolders: Bool = false) async {
        guard let owner else { return }
        var targets = owner.fileOps.fileSettings.classifyTargets
        for loc in locations where !targets.contains(where: { $0.location == loc }) {
            targets.append(ClassifyTarget(location: loc, listsSubfolders: listsSubfolders))
            if listsSubfolders { await reloadSubfolders(for: loc) }
        }
        if selectedLocation == nil { selectedLocation = targets.first?.location }
        await owner.fileOps.setClassifyTargets(targets); refreshState()
    }

    func setListsSubfolders(_ enabled: Bool, for location: Location) async {
        guard let owner else { return }
        var targets = owner.fileOps.fileSettings.classifyTargets
        guard let index = targets.firstIndex(where: { $0.location == location }) else { return }
        targets[index].listsSubfolders = enabled
        if enabled { settings.collapsed.remove(location); await reloadSubfolders(for: location) }
        await owner.fileOps.setClassifyTargets(targets); refreshState()
    }

    func removeTarget(_ location: Location) {
        guard let owner else { return }
        var targets = owner.fileOps.fileSettings.classifyTargets
        targets.removeAll { $0.location == location }; settings.collapsed.remove(location)
        subfoldersByTarget[location] = nil; subfolderErrors[location] = nil
        Task { @MainActor in await owner.fileOps.setClassifyTargets(targets); self.refreshState() }
    }

    func toggleCollapse(for location: Location) {
        if settings.collapsed.contains(location) { settings.collapsed.remove(location) } else { settings.collapsed.insert(location) }
        refreshState()
    }

    func selectRow(at location: Location?) { selectedLocation = location; refreshState() }

    func moveTarget(_ source: Location, toTopLevelIndex destinationIndex: Int) {
        guard let owner else { return }
        var targets = owner.fileOps.fileSettings.classifyTargets
        guard let fromIndex = targets.firstIndex(where: { $0.location == source }) else { return }
        let item = targets.remove(at: fromIndex)
        let clamped = min(max(0, destinationIndex > fromIndex ? destinationIndex - 1 : destinationIndex), targets.count)
        guard clamped != fromIndex else { return }
        targets.insert(item, at: clamped)
        Task { @MainActor in await owner.fileOps.setClassifyTargets(targets); self.refreshState() }
    }

    func contextMenu(for row: Row) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        if !row.isSubfolder {
            let subItem = MenuAction(String(localized: "列出子文件夹")) { [weak self] in
                Task { @MainActor in await self?.setListsSubfolders(!row.listsSubfolders, for: row.location) }
            }.item
            subItem.state = row.listsSubfolders ? .on : .off; menu.addItem(subItem)
        }
        menu.addItem(MenuAction(String(localized: "在 Finder 中显示")) { [weak self] in
            guard let self, let owner = self.owner else { return }
            let entry = Entry(identity: ContentIdentity(location: row.location, size: 0, modificationNanos: 0), name: row.name, kind: .directory)
            Task { @MainActor in await owner.fileOps.revealInFinder(origin: FileOrigin(window: owner, items: [entry])) }
        }.item)
        if !row.isSubfolder {
            menu.addItem(.separator())
            menu.addItem(MenuAction(String(localized: "移除目标")) { [weak self] in self?.removeTarget(row.location) }.item)
        }
        return menu
    }

    func classify(atVisibleIndex index: Int) {
        guard let owner else { return }
        if isArchiveBook { owner.content.statusBar.showMessage(String(localized: "压缩包内的项不能移动")); return }
        if visibleRows.isEmpty { owner.content.statusBar.showMessage(String(localized: "还没有目标文件夹")); return }
        guard visibleRows.indices.contains(index) else { return }
        classify(into: visibleRows[index].location)
    }

    func classify(into location: Location) {
        guard let owner, let row = visibleRows.first(where: { $0.location == location }) else { return }
        if row.isUnavailable { owner.content.statusBar.showMessage(String(localized: "卷不可用")); return }
        if isArchiveBook { owner.content.statusBar.showMessage(String(localized: "压缩包内的项不能移动")); return }
        let origin = owner.fileOrigin()
        guard !origin.items.isEmpty else { return }
        if origin.items.contains(where: { $0.location.layers.count > 1 }) {
            owner.content.statusBar.showMessage(String(localized: "压缩包内的项不能移动")); return
        }
        let mode = owner.fileOps.fileSettings.classifyMode, conflict = owner.fileOps.fileSettings.nameConflict
        let verb = mode == .move ? String(localized: "移动") : String(localized: "复制")
        let title = origin.items.count == 1 ? "\(verb)“\(origin.items[0].name)”" : String(localized: "\(verb) \(origin.items.count) 项")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await owner.fileOps.perform(
                .transfer(origin.items.map(\.location), into: row.location, mode: mode, conflict: conflict),
                title: title, origin: origin
            )
            if let result, !result.changes.isEmpty { self.panelView.listView.flash(row.location) }
        }
    }

    @objc private func newTargetClicked(_ sender: Any?) { beginNewTarget() }

    func beginNewTarget() {
        guard canBeginNewTarget, let parent = selectedLocation, let owner else { return }
        newTargetOrigin = owner.fileOrigin()
        editingLocation = parent; createdDirectoryLocation = nil; newTargetError = nil; newTargetRetry = nil
        panelView.listView.inputField.isEditable = true; panelView.listView.inputField.stringValue = ""
        refreshState(); panelView.listView.focusInputField()
    }

    func cancelNewTarget() {
        guard editingLocation != nil else { return }
        restoreViewerFocus()
        editingLocation = nil; createdDirectoryLocation = nil; newTargetError = nil; newTargetRetry = nil
        panelView.listView.inputField.stringValue = ""; refreshState()
    }

    @objc private func retryNewTargetClicked(_ sender: Any?) { Task { @MainActor in await retryNewTarget() } }

    func retryNewTarget() async {
        guard !isSubmittingNewTarget, let retry = newTargetRetry, let parent = editingLocation, let owner else { return }
        let raw = panelView.listView.inputField.currentEditor()?.string ?? panelView.listView.inputField.stringValue
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = createdDirectoryLocation ?? parent.appending(name), mode = owner.fileOps.fileSettings.classifyMode
        let title = mode == .move ? String(localized: "新建“\(newFolder.name)”并移入") : String(localized: "新建“\(newFolder.name)”并复制进去")
        isSubmittingNewTarget = true
        let result = await owner.fileOps.perform(retry, title: title, origin: newTargetOrigin, reportsFailures: false)
        isSubmittingNewTarget = false
        await handleNewTargetResult(result, parent: parent, newFolder: newFolder)
    }

    func submitNewTarget() async {
        guard !isSubmittingNewTarget, let parent = editingLocation, let owner else { return }
        let raw = panelView.listView.inputField.currentEditor()?.string ?? panelView.listView.inputField.stringValue
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let newFolder = parent.appending(name)
        if createdDirectoryLocation == newFolder, newTargetRetry != nil { await retryNewTarget(); return }
        let mode = owner.fileOps.fileSettings.classifyMode, conflict = owner.fileOps.fileSettings.nameConflict
        let title = mode == .move ? String(localized: "新建“\(name)”并移入") : String(localized: "新建“\(name)”并复制进去")
        let operation: FileOperation = .sequence([
            .makeDirectory(in: parent, name: name),
            .transfer(newTargetOrigin.items.map(\.location), into: newFolder, mode: mode, conflict: conflict),
        ])
        isSubmittingNewTarget = true
        let result = await owner.fileOps.perform(operation, title: title, origin: newTargetOrigin, reportsFailures: false)
        isSubmittingNewTarget = false
        await handleNewTargetResult(result, parent: parent, newFolder: newFolder)
    }

    private func handleNewTargetResult(_ result: FileOperationResult?, parent: Location, newFolder: Location) async {
        guard let result, let owner else { return }
        if let failure = result.failures.first {
            if result.changes.contains(where: { if case let .added(e) = $0 { e.location == newFolder } else { false } }) {
                createdDirectoryLocation = newFolder
            }
            newTargetRetry = result.retry
            newTargetError = if case IOError.alreadyExists = failure.error { String(localized: "这个文件夹里已有“\(newFolder.name)”。") }
            else { ErrorText.describe(failure.error) }
            if createdDirectoryLocation != nil {
                restoreViewerFocus()
                if owner.fileOps.fileSettings.classifyTargets.contains(where: { $0.location == parent && $0.listsSubfolders }) {
                    settings.collapsed.remove(parent); await reloadSubfolders(for: parent)
                }
                panelView.listView.inputField.isEditable = false; refreshState()
            } else {
                panelView.listView.inputField.isEditable = true; refreshState(); panelView.listView.focusInputField()
            }
            return
        }
        restoreViewerFocus()
        editingLocation = nil; createdDirectoryLocation = nil; newTargetError = nil; newTargetRetry = nil
        panelView.listView.inputField.stringValue = ""
        let parentListsSubfolders = owner.fileOps.fileSettings.classifyTargets.contains { $0.location == parent && $0.listsSubfolders }
        if parentListsSubfolders {
            settings.collapsed.remove(parent); await reloadSubfolders(for: parent); selectedLocation = newFolder
        }
        await owner.fileOps.reloadSettings(); refreshState()
        panelView.listView.flash(parentListsSubfolders ? newFolder : parent)
    }

    private func restoreViewerFocus() {
        view.window?.endEditing(for: nil)
        guard let owner, let window = owner.window else { return }
        if view.window !== window { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(owner.viewer)
    }

    func controlTextDidChange(_ obj: Notification) {
        if newTargetError != nil, createdDirectoryLocation == nil { newTargetError = nil; newTargetRetry = nil; refreshState() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { Task { @MainActor in await submitNewTarget() }; return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelNewTarget(); return true }
        return false
    }
}

/// 分类面板主视图：顶部移动/复制与“+”按钮、中间滚动列表或空状态、底部“新建目标并移入”与提示。
@MainActor
final class ClassifyPanelView: NSView {
    static let topBarHeight: CGFloat = 34, footerHeight: CGFloat = 62

    let modeControl = BrowseModeControl(labels: [String(localized: "移动"), String(localized: "复制")])
    let addButton = NSButton(), scrollView = NSScrollView(), listView = ClassifyListView(), emptyView = NSView()
    let emptyTitleLabel = NSTextField(labelWithString: String(localized: "还没有目标文件夹"))
    let emptyHintLabel = NSTextField(wrappingLabelWithString: "")
    let emptyAddButton = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let unsupportedLabel = NSTextField(labelWithString: String(localized: "当前服务不支持文件操作"))
    let newTargetButton = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 28, padding: 11)
    let hintLabel = NSTextField(labelWithString: "")
    private let topBar = NSView(), footer = NSView(), topLine = CALayer(), bottomLine = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(String(localized: "分类"))
        Self.disableFirstResponder(in: modeControl)
        addButton.isBordered = false; addButton.refusesFirstResponder = true
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "添加目标…"))
        addButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        addButton.contentTintColor = Theme.text2; addButton.toolTip = String(localized: "添加目标…")
        topBar.wantsLayer = true; topBar.layer?.addSublayer(topLine); topBar.addSubview(modeControl); topBar.addSubview(addButton)
        scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true; scrollView.documentView = listView
        emptyTitleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold); emptyTitleLabel.textColor = Theme.text; emptyTitleLabel.alignment = .center
        emptyHintLabel.font = .systemFont(ofSize: 12); emptyHintLabel.textColor = Theme.text2; emptyHintLabel.alignment = .center
        emptyAddButton.setText(String(localized: "添加目标…")); emptyAddButton.refusesFirstResponder = true
        emptyView.addSubview(emptyTitleLabel); emptyView.addSubview(emptyHintLabel); emptyView.addSubview(emptyAddButton)
        unsupportedLabel.font = .systemFont(ofSize: 12); unsupportedLabel.textColor = Theme.text2; unsupportedLabel.alignment = .center; unsupportedLabel.isHidden = true
        footer.wantsLayer = true; footer.layer?.addSublayer(bottomLine); newTargetButton.refusesFirstResponder = true
        hintLabel.font = .systemFont(ofSize: 11); hintLabel.textColor = Theme.text2; hintLabel.alignment = .center; hintLabel.lineBreakMode = .byTruncatingTail
        footer.addSubview(newTargetButton); footer.addSubview(hintLabel)
        addSubview(topBar); addSubview(scrollView); addSubview(emptyView); addSubview(footer); addSubview(unsupportedLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true; layout() }
    private static func disableFirstResponder(in view: NSView) { (view as? NSControl)?.refusesFirstResponder = true; view.subviews.forEach(disableFirstResponder(in:)) }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor; topLine.backgroundColor = Theme.line.cgColor; bottomLine.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, modeSize = modeControl.fittingSize
        topBar.frame = NSRect(x: 0, y: 0, width: w, height: Self.topBarHeight)
        modeControl.frame = NSRect(x: 8, y: floor((Self.topBarHeight - modeSize.height) / 2), width: modeSize.width, height: modeSize.height)
        addButton.frame = NSRect(x: max(8, w - 32), y: 5, width: 24, height: 24)
        topLine.frame = CGRect(x: 0, y: Self.topBarHeight - 0.5, width: w, height: 0.5)
        let footY = max(Self.topBarHeight, h - Self.footerHeight)
        footer.frame = NSRect(x: 0, y: footY, width: w, height: Self.footerHeight)
        bottomLine.frame = CGRect(x: 0, y: 0, width: w, height: 0.5)
        newTargetButton.frame = NSRect(x: 8, y: 8, width: max(60, w - 16), height: 28)
        hintLabel.frame = NSRect(x: 8, y: 40, width: max(60, w - 16), height: 16)
        let bodyHeight = max(0, (footer.isHidden ? h : footY) - Self.topBarHeight)
        scrollView.frame = NSRect(x: 0, y: Self.topBarHeight, width: w, height: bodyHeight); emptyView.frame = scrollView.frame
        let midY = max(20, floor(bodyHeight / 2) - 36), addBtnSize = emptyAddButton.intrinsicContentSize
        emptyTitleLabel.frame = NSRect(x: 12, y: midY, width: max(40, w - 24), height: 18)
        emptyHintLabel.frame = NSRect(x: 12, y: midY + 24, width: max(40, w - 24), height: 34)
        emptyAddButton.frame = NSRect(x: floor((w - addBtnSize.width) / 2), y: midY + 64, width: addBtnSize.width, height: addBtnSize.height)
        unsupportedLabel.frame = NSRect(x: 12, y: floor(h / 2) - 10, width: max(40, w - 24), height: 20)
        listView.updateLayout(in: scrollView.contentSize.width)
    }

    func showUnsupported(_ unsupported: Bool) {
        unsupportedLabel.isHidden = !unsupported; topBar.isHidden = unsupported; scrollView.isHidden = unsupported
        emptyView.isHidden = true; footer.isHidden = unsupported; needsLayout = true
    }

    func render(
        mode: TransferMode, rows: [ClassifyPanel.Row], selectedLocation: Location?,
        editingLocation: Location?, errorText: String?, showsRetry: Bool, isArchive: Bool, canNewTarget: Bool
    ) {
        modeControl.selected = mode == .move ? 0 : 1
        let isEmpty = rows.isEmpty, verb = mode == .move ? String(localized: "移动") : String(localized: "复制")
        emptyView.isHidden = !isEmpty; scrollView.isHidden = isEmpty; footer.isHidden = isEmpty
        emptyHintLabel.stringValue = String(localized: "添加后，面板打开时按 1–0\n把当前页\(verb)过去")
        newTargetButton.setText(mode == .move ? String(localized: "+ 新建目标并移入") : String(localized: "+ 新建目标并复制进去"))
        newTargetButton.isEnabled = canNewTarget
        hintLabel.stringValue = isArchive ? String(localized: "压缩包内的项不能移动或复制到目标") : String(localized: "按 1–0 把当前页\(verb)到对应目标")
        listView.alphaValue = isArchive ? 0.45 : 1.0
        listView.apply(rows: rows, selectedLocation: selectedLocation, editingLocation: editingLocation, errorText: errorText, showsRetry: showsRetry, width: scrollView.contentSize.width)
        needsLayout = true; layout()
    }
}

/// 分类面板的自定义行列表视图：自绘行、数字键徽章、展开三角、就地新建输入框、双击分类与顶层拖动重排。
@MainActor
final class ClassifyListView: NSView {
    static let rowHeight: CGFloat = 28
    private static let badgeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), detailFont = NSFont.systemFont(ofSize: 11), nameFont = NSFont.systemFont(ofSize: 12.5)
    private static func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    private static let folderImage = symbol("folder", 12), globeImage = symbol("globe", 10)
    private static let expandedImage = symbol("chevron.down", 9, .semibold), collapsedImage = symbol("chevron.right", 9, .semibold)
    /// 行文字的属性按（字体、颜色、透明度）建一次后复用，绘制时不再每行新建字体和字典。
    private static var attributeCache: [String: [NSAttributedString.Key: Any]] = [:]
    private static func attributes(_ name: String, _ font: NSFont, _ color: NSColor, alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        let key = "\(name)-\(alpha)"
        if let cached = attributeCache[key] { return cached }
        let made: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(alpha)]
        attributeCache[key] = made
        return made
    }

    private(set) var rows: [ClassifyPanel.Row] = []
    private(set) var selectedLocation: Location?, editingLocation: Location?, flashedLocation: Location?
    private(set) var flashAlpha: CGFloat = 0
    private var flashTask: Task<Void, Never>?

    let editorContainer = NSView(), inputBox = NSView(), inputField = ClassifyInputField(string: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let retryButton = FlatButton(font: .systemFont(ofSize: 11.5), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10)

    var onSelect: ((Location) -> Void)?, onDoubleClick: ((Location) -> Void)?
    var onToggleCollapse: ((Location) -> Void)?, onMoveTarget: ((Location, Int) -> Void)?
    var onContextMenu: ((ClassifyPanel.Row) -> NSMenu?)?

    private var dragSourceLocation: Location?, dragStartPoint = NSPoint.zero
    private var isDraggingRow = false, dragDropTopIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        inputBox.wantsLayer = true; inputBox.layer?.cornerRadius = 5; inputBox.layer?.borderWidth = 1
        inputField.isBordered = false; inputField.drawsBackground = false; inputField.focusRingType = .none
        inputField.font = .systemFont(ofSize: 12); inputField.textColor = Theme.text
        inputField.placeholderString = String(localized: "新文件夹名称"); inputBox.addSubview(inputField)
        errorLabel.font = .systemFont(ofSize: 11.5); errorLabel.textColor = Theme.danger
        retryButton.setText(String(localized: "重试")); retryButton.refusesFirstResponder = true
        editorContainer.addSubview(inputBox); editorContainer.addSubview(errorLabel); editorContainer.addSubview(retryButton)
        editorContainer.isHidden = true; addSubview(editorContainer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(rows: [ClassifyPanel.Row], selectedLocation: Location?, editingLocation: Location?, errorText: String?, showsRetry: Bool, width: CGFloat) {
        self.rows = rows; self.selectedLocation = selectedLocation; self.editingLocation = editingLocation
        errorLabel.stringValue = errorText ?? ""; errorLabel.isHidden = (errorText ?? "").isEmpty; retryButton.isHidden = !showsRetry
        effectiveAppearance.performAsCurrentDrawingAppearance {
            inputBox.layer?.backgroundColor = Theme.well.cgColor
            inputBox.layer?.borderColor = (errorLabel.isHidden ? Theme.accent : Theme.danger).cgColor
        }
        updateLayout(in: width); needsDisplay = true
    }

    func updateLayout(in width: CGFloat) {
        let w = max(width, bounds.width, 180)
        var y: CGFloat = 4, editorPlaced = false
        for row in rows {
            y += Self.rowHeight
            if row.location == editingLocation {
                editorPlaced = true
                let indent: CGFloat = 8 + CGFloat(row.isSubfolder ? 2 : 1) * 18, boxWidth = max(80, w - indent - 12)
                inputBox.frame = NSRect(x: indent + 18, y: 3, width: boxWidth - 18, height: 22)
                inputField.frame = NSRect(x: 6, y: 2, width: max(40, inputBox.bounds.width - 12), height: 18)
                var ey: CGFloat = 28
                if !errorLabel.isHidden { errorLabel.frame = NSRect(x: indent + 18, y: ey, width: boxWidth - 18, height: 18); ey += 20 }
                if !retryButton.isHidden {
                    let size = retryButton.intrinsicContentSize
                    retryButton.frame = NSRect(x: indent + 18, y: ey, width: size.width, height: size.height); ey += size.height + 4
                }
                editorContainer.frame = NSRect(x: 0, y: y, width: w, height: ey); editorContainer.isHidden = false; y += ey
            }
        }
        if !editorPlaced {
            if !editorContainer.isHidden { window?.endEditing(for: nil) }
            editorContainer.isHidden = true
        }
        frame = NSRect(x: 0, y: 0, width: w, height: max(y + 4, superview?.bounds.height ?? 0))
    }

    func focusInputField() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        if window is FloatingPanelWindow { window.makeKeyAndOrderFront(nil) }
        if window.firstResponder !== inputField.currentEditor() { window.endEditing(for: nil) }
        _ = window.makeFirstResponder(inputField)
    }

    func setInputText(_ text: String) {
        inputField.stringValue = text; focusInputField()
        if let editor = inputField.currentEditor() as? NSTextView {
            editor.string = text; editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func flash(_ location: Location) {
        flashTask?.cancel(); flashedLocation = location; flashAlpha = 1.0; needsDisplay = true
        flashTask = Task { @MainActor [weak self] in
            for step in 1...14 {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.flashAlpha = CGFloat(14 - step) / 14; self.needsDisplay = true
            }
            guard !Task.isCancelled, let self else { return }
            self.flashedLocation = nil; self.flashAlpha = 0; self.needsDisplay = true
        }
    }

    func rowFrame(at index: Int) -> NSRect {
        guard rows.indices.contains(index) else { return .zero }
        var y: CGFloat = 4
        for i in 0..<index {
            y += Self.rowHeight
            if rows[i].location == editingLocation, !editorContainer.isHidden { y += editorContainer.frame.height }
        }
        return NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
    }

    func rowIndex(at y: CGFloat) -> Int? { rows.indices.first { rowFrame(at: $0).contains(NSPoint(x: 10, y: y)) } }

    func rowPointInWindow(_ index: Int) -> NSPoint? {
        guard rows.indices.contains(index) else { return nil }
        let rect = rowFrame(at: index)
        return convert(NSPoint(x: min(80, rect.midX), y: rect.midY), to: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in rows.indices {
            let row = rows[index], rect = rowFrame(at: index), rowAlpha: CGFloat = row.isUnavailable ? 0.45 : 1.0
            let bgRect = rect.insetBy(dx: 4, dy: 1)
            if row.location == selectedLocation {
                Theme.selected.withAlphaComponent(Theme.selected.alphaComponent * rowAlpha).setFill()
                NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()
            }
            if row.location == flashedLocation, flashAlpha > 0 {
                Theme.accentSoft.withAlphaComponent(flashAlpha).setFill()
                NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()
                Theme.accent.withAlphaComponent(flashAlpha).setStroke()
                let strokePath = NSBezierPath(roundedRect: bgRect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
                strokePath.lineWidth = 1.5; strokePath.stroke()
            }
            let indent: CGFloat = 8 + (row.isSubfolder ? 18 : 0), badgeRect = NSRect(x: indent, y: rect.minY + 5, width: 18, height: 18)
            if let key = row.keyBadge {
                Theme.well.withAlphaComponent(rowAlpha).setFill()
                let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
                badgePath.fill(); Theme.lineStrong.withAlphaComponent(rowAlpha).setStroke(); badgePath.lineWidth = 0.5; badgePath.stroke()
                let attrs = Self.attributes("badge", Self.badgeFont, Theme.text2, alpha: rowAlpha)
                let size = (key as NSString).size(withAttributes: attrs)
                (key as NSString).draw(at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2), withAttributes: attrs)
            }
            if !row.isSubfolder, row.listsSubfolders,
               let img = row.isExpanded ? Self.expandedImage : Self.collapsedImage {
                img.draw(in: NSRect(x: indent + 21, y: rect.minY + 9, width: 10, height: 10), from: .zero, operation: .sourceOver, fraction: rowAlpha * 0.7, respectFlipped: true, hints: nil)
            }
            if let folderImg = Self.folderImage {
                folderImg.draw(in: NSRect(x: indent + 34, y: rect.minY + 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: rowAlpha * 0.75, respectFlipped: true, hints: nil)
            }
            var rightEdge = rect.maxX - 10
            if !row.isSubfolder, row.isNetwork,
               let netImg = Self.globeImage {
                rightEdge -= 12
                netImg.draw(in: NSRect(x: rightEdge, y: rect.minY + 8, width: 11, height: 11), from: .zero, operation: .sourceOver, fraction: rowAlpha * 0.65, respectFlipped: true, hints: nil)
                rightEdge -= 4
            }
            let detail = row.errorText ?? (row.isSubfolder ? "" : row.whereText)
            if !detail.isEmpty {
                let detailAttrs = Self.attributes("detail", Self.detailFont, Theme.text2, alpha: rowAlpha * (row.errorText != nil ? 1.0 : 0.7))
                let detailStr = detail as NSString, drawW = min(detailStr.size(withAttributes: detailAttrs).width, max(36, min(110, rect.width * 0.42)))
                rightEdge -= drawW
                detailStr.draw(with: NSRect(x: rightEdge, y: rect.minY + 6, width: drawW, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: detailAttrs)
                rightEdge -= 6
            }
            let nameX = indent + 52, nameW = max(24, rightEdge - nameX)
            let nameAttrs = row.isSubfolder ? Self.attributes("subfolder", Self.nameFont, Theme.text2, alpha: rowAlpha) : Self.attributes("name", Self.nameFont, Theme.text, alpha: rowAlpha)
            (row.name as NSString).draw(with: NSRect(x: nameX, y: rect.minY + 5, width: nameW, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttrs)
        }
        if !editorContainer.isHidden, let folderImg = Self.folderImage {
            folderImg.draw(in: NSRect(x: inputBox.frame.minX - 16, y: editorContainer.frame.minY + 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
        }
        if isDraggingRow, let dropIdx = dragDropTopIndex {
            let topIndices = rows.indices.filter { !rows[$0].isSubfolder }
            let lineY: CGFloat = if dropIdx < topIndices.count { rowFrame(at: topIndices[dropIdx]).minY }
            else if let lastIdx = rows.indices.last { rowFrame(at: lastIdx).maxY }
            else { 4 }
            Theme.accent.setFill(); NSRect(x: 8, y: lineY - 1, width: max(0, bounds.width - 16), height: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragSourceLocation = nil; isDraggingRow = false; dragDropTopIndex = nil
        guard let index = rowIndex(at: point.y) else { return }
        let row = rows[index], indent: CGFloat = 8 + (row.isSubfolder ? 18 : 0)
        if !row.isSubfolder, row.listsSubfolders, (indent + 18...indent + 34).contains(point.x) { onToggleCollapse?(row.location); return }
        onSelect?(row.location)
        if event.clickCount == 2 { onDoubleClick?(row.location); return }
        if event.clickCount == 1, !row.isSubfolder { dragSourceLocation = row.location; dragStartPoint = point }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSourceLocation != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingRow, hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y) >= 4 { isDraggingRow = true }
        guard isDraggingRow else { return }
        let topIndices = rows.indices.filter { !rows[$0].isSubfolder }
        var slot = topIndices.count
        for (topSlot, rowIdx) in topIndices.enumerated() where point.y < rowFrame(at: rowIdx).midY { slot = topSlot; break }
        dragDropTopIndex = slot; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragSourceLocation = nil; isDraggingRow = false; dragDropTopIndex = nil; needsDisplay = true }
        if isDraggingRow, let source = dragSourceLocation, let slot = dragDropTopIndex { onMoveTarget?(source, slot) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y) else { return nil }
        return onContextMenu?(rows[index])
    }
}
