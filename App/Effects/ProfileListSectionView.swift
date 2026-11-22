import AppKit
import MVSettings

/// 显示配置段：配置列表（名称、组标签、⌃n、行尾 ⋯ 菜单、拖动排序）、空状态与底栏按钮。
@MainActor
final class ProfileListSectionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("io.github.ump45nose.MacView.displayProfileRow")
    private static var rowHeight: CGFloat { ceil(46 * Theme.fontScale(.panels)) }

    var onApplyToBook: ((DisplayProfile) -> Void)?
    var onApplyToGlobal: ((DisplayProfile) -> Void)?
    var onSaveAsPathRule: ((DisplayProfile, NSView) -> Void)?
    var onUpdateWithCurrent: ((DisplayProfile) -> Void)?
    var onRename: ((DisplayProfile) -> Void)?
    var onDelete: ((DisplayProfile) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onOpenSave: ((NSView) -> Void)?

    private(set) var profiles: [DisplayProfile] = []
    private var hasBook = false
    private var isVirtualBook = false
    private var selectedID: UUID?

    private let listBox = RoundedBoxView()
    let tableView = NSTableView()
    private var tableHeightConstraint: NSLayoutConstraint?

    private let titleLabel = NSTextField(labelWithString: String(localized: "显示配置"))
    private let hintLabel = NSTextField(labelWithString: String(localized: "套用默认写入当前书"))
    private let emptyBox = RoundedBoxView()
    private let emptyTitle = NSTextField(labelWithString: String(localized: "还没有显示配置"))
    private let emptyBody = NSTextField(wrappingLabelWithString: String(localized: "把现在的浏览方式、缩放、效果和背景存成一个配置，以后一键或按 ⌃1 套用。"))

    let applyButton = FlatButton(
        font: Theme.font(.panels, size: 12, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 6, height: 24, padding: 10
    )
    let saveButton = FlatButton(
        font: Theme.font(.panels, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10
    )
    let emptySaveButton = FlatButton(
        font: Theme.font(.panels, size: 12, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 6, height: 24, padding: 10
    )
    private let dragHint = NSTextField(labelWithString: String(localized: "拖动排序"))
    private let normalFooter = NSStackView()
    private let emptyFooter = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        titleLabel.font = Theme.font(.panels, size: 12, weight: .semibold)
        let smallFont = Theme.font(.panels, size: 11)
        hintLabel.font = smallFont
        dragHint.font = smallFont
        emptyBody.font = Theme.font(.panels, size: 12)
        let semibold12 = Theme.font(.panels, size: 12, weight: .semibold)
        applyButton.applyFont(semibold12)
        emptySaveButton.applyFont(semibold12)
        saveButton.applyFont(Theme.font(.panels, size: 12))
        tableView.rowHeight = Self.rowHeight
        tableHeightConstraint?.constant = max(CGFloat(profiles.count) * Self.rowHeight, 1)
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? ProfileRowCellView)?.applyFonts()
        }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedProfile: DisplayProfile? {
        if let selectedID, let found = profiles.first(where: { $0.id == selectedID }) { return found }
        return profiles.first
    }

    func update(profiles: [DisplayProfile], hasBook: Bool, isVirtualBook: Bool) {
        self.profiles = profiles
        self.hasBook = hasBook
        self.isVirtualBook = isVirtualBook

        if let selectedID, !profiles.contains(where: { $0.id == selectedID }) {
            self.selectedID = profiles.first?.id
        } else if self.selectedID == nil {
            self.selectedID = profiles.first?.id
        }

        let isEmpty = profiles.isEmpty
        listBox.isHidden = isEmpty
        normalFooter.isHidden = isEmpty
        emptyBox.isHidden = !isEmpty
        emptyFooter.isHidden = !isEmpty

        tableHeightConstraint?.constant = max(CGFloat(profiles.count) * Self.rowHeight, 1)
        tableView.reloadData()
        if let selectedID, let idx = profiles.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }

        applyButton.isEnabled = hasBook && selectedProfile != nil
        saveButton.isEnabled = hasBook
        emptySaveButton.isEnabled = hasBook
    }

    func selectProfile(at index: Int) {
        guard profiles.indices.contains(index) else { return }
        selectedID = profiles[index].id
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        applyButton.isEnabled = hasBook && selectedProfile != nil
    }

    func rowMenu(for index: Int, anchor: NSView) -> NSMenu? {
        guard profiles.indices.contains(index) else { return nil }
        let profile = profiles[index]
        let menu = NSMenu()
        menu.autoenablesItems = false

        let applyBook = NSMenuItem(title: String(localized: "套用到当前书"), action: #selector(menuApplyBook(_:)), keyEquivalent: "")
        applyBook.target = self
        applyBook.representedObject = profile.id
        applyBook.isEnabled = hasBook
        menu.addItem(applyBook)

        let applyGlobal = NSMenuItem(title: String(localized: "套用到全局默认"), action: #selector(menuApplyGlobal(_:)), keyEquivalent: "")
        applyGlobal.target = self
        applyGlobal.representedObject = profile.id
        applyGlobal.isEnabled = true
        menu.addItem(applyGlobal)

        let saveRule = NSMenuItem(title: String(localized: "存为路径规则…"), action: #selector(menuSavePathRule(_:)), keyEquivalent: "")
        saveRule.target = self
        saveRule.representedObject = RowMenuAnchor(id: profile.id, view: anchor)
        saveRule.isEnabled = hasBook && !isVirtualBook
        menu.addItem(saveRule)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: String(localized: "用当前值更新"), action: #selector(menuUpdateCurrent(_:)), keyEquivalent: "")
        updateItem.target = self
        updateItem.representedObject = profile.id
        updateItem.isEnabled = hasBook
        menu.addItem(updateItem)

        let renameItem = NSMenuItem(title: String(localized: "重命名…"), action: #selector(menuRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = profile.id
        renameItem.isEnabled = true
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: String(localized: "删除"), action: #selector(menuDelete(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = profile.id
        deleteItem.isEnabled = true
        menu.addItem(deleteItem)
        Theme.applyMenuFont(to: menu)
        return menu
    }

    private func buildUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        titleLabel.font = Theme.font(.panels, size: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        hintLabel.font = Theme.font(.panels, size: 11)
        hintLabel.textColor = Theme.text2
        hintLabel.lineBreakMode = .byTruncatingTail

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [titleLabel, hintLabel, headerSpacer])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        stack.addArrangedSubview(header)

        // 配置列表
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.translatesAutoresizingMaskIntoConstraints = false

        listBox.addSubview(tableView)
        let heightConstraint = tableView.heightAnchor.constraint(equalToConstant: 1)
        tableHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: listBox.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: listBox.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            heightConstraint,
        ])
        stack.addArrangedSubview(listBox)

        // 空状态
        emptyTitle.font = Theme.serif(14, weight: .medium)
        emptyTitle.textColor = Theme.text
        emptyTitle.alignment = .center
        emptyBody.font = Theme.font(.panels, size: 12)
        emptyBody.textColor = Theme.text2
        emptyBody.alignment = .center
        let emptyStack = NSStackView(views: [emptyTitle, emptyBody])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 4
        emptyStack.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyBox.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            emptyStack.leadingAnchor.constraint(equalTo: emptyBox.leadingAnchor),
            emptyStack.trailingAnchor.constraint(equalTo: emptyBox.trailingAnchor),
            emptyStack.topAnchor.constraint(equalTo: emptyBox.topAnchor),
            emptyStack.bottomAnchor.constraint(equalTo: emptyBox.bottomAnchor),
        ])
        stack.addArrangedSubview(emptyBox)

        // 有配置时的底栏
        applyButton.setText(String(localized: "套用"))
        applyButton.target = self
        applyButton.action = #selector(applyClicked(_:))
        saveButton.setText(String(localized: "存为配置…"))
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))
        dragHint.font = Theme.font(.panels, size: 11)
        dragHint.textColor = Theme.text2
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        normalFooter.orientation = .horizontal
        normalFooter.alignment = .centerY
        normalFooter.spacing = 6
        normalFooter.setViews([applyButton, saveButton, spacer, dragHint], in: .leading)
        stack.addArrangedSubview(normalFooter)

        // 空状态底栏
        emptySaveButton.setText(String(localized: "存为配置…"))
        emptySaveButton.target = self
        emptySaveButton.action = #selector(saveClicked(_:))
        emptyFooter.orientation = .horizontal
        emptyFooter.alignment = .centerY
        emptyFooter.setViews([emptySaveButton], in: .leading)
        stack.addArrangedSubview(emptyFooter)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]
        let cell = ProfileRowCellView()
        cell.configure(
            profile: profile,
            slot: row < 9 ? row + 1 : nil,
            isSelected: profile.id == selectedID,
            showsDivider: row < profiles.count - 1
        )
        cell.onMore = { [weak self] anchor in
            guard let self else { return }
            self.selectProfile(at: row)
            if let menu = self.rowMenu(for: row, anchor: anchor) {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if profiles.indices.contains(row) {
            selectedID = profiles[row].id
        }
        for idx in profiles.indices {
            if let cell = tableView.view(atColumn: 0, row: idx, makeIfNecessary: false) as? ProfileRowCellView {
                cell.setSelected(profiles[idx].id == selectedID)
            }
        }
        applyButton.isEnabled = hasBook && selectedProfile != nil
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, info.draggingSource as? NSTableView === tableView else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: Self.dragType),
              let sourceRow = Int(str),
              profiles.indices.contains(sourceRow) else { return false }
        let destination = row > sourceRow ? row - 1 : row
        guard destination != sourceRow, destination >= 0, destination < profiles.count else { return false }
        onReorder?(sourceRow, destination)
        return true
    }

    // MARK: Actions

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard hasBook, profiles.indices.contains(row) else { return }
        onApplyToBook?(profiles[row])
    }

    @objc private func applyClicked(_ sender: Any?) {
        guard hasBook, let profile = selectedProfile else { return }
        onApplyToBook?(profile)
    }

    @objc private func saveClicked(_ sender: NSView) {
        guard hasBook else { return }
        onOpenSave?(sender)
    }

    private func profile(from sender: NSMenuItem) -> DisplayProfile? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return profiles.first { $0.id == id }
    }

    @objc private func menuApplyBook(_ sender: NSMenuItem) {
        if let profile = profile(from: sender) { onApplyToBook?(profile) }
    }

    @objc private func menuApplyGlobal(_ sender: NSMenuItem) {
        if let profile = profile(from: sender) { onApplyToGlobal?(profile) }
    }

    @objc private func menuSavePathRule(_ sender: NSMenuItem) {
        guard let anchor = sender.representedObject as? RowMenuAnchor,
              let profile = profiles.first(where: { $0.id == anchor.id }) else { return }
        onSaveAsPathRule?(profile, anchor.view)
    }

    @objc private func menuUpdateCurrent(_ sender: NSMenuItem) {
        if let profile = profile(from: sender) { onUpdateWithCurrent?(profile) }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        if let profile = profile(from: sender) { onRename?(profile) }
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        if let profile = profile(from: sender) { onDelete?(profile) }
    }
}

@MainActor
private final class RowMenuAnchor: NSObject {
    let id: UUID
    let view: NSView
    init(id: UUID, view: NSView) {
        self.id = id
        self.view = view
    }
}

@MainActor
private final class RoundedBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.raised.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}

@MainActor
private final class ProfileRowCellView: NSView {
    var onMore: ((NSView) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let chipsStack = NSStackView()
    private let shortcutBadge = KeyBadgeView(text: "")
    private let moreButton = NSButton()
    private let divider = CALayer()
    private var isSelectedRow = false
    private var showsDivider = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(divider)

        nameLabel.font = Theme.font(.panels, size: 12.5, weight: .medium)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chipsStack.orientation = .horizontal
        chipsStack.alignment = .centerY
        chipsStack.spacing = 4

        let leftStack = NSStackView(views: [nameLabel, chipsStack])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: String(localized: "更多操作"))
        moreButton.isBordered = false
        moreButton.contentTintColor = Theme.text2
        moreButton.target = self
        moreButton.action = #selector(moreClicked(_:))
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [leftStack, shortcutBadge, moreButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            moreButton.widthAnchor.constraint(equalToConstant: 22),
            moreButton.heightAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(profile: DisplayProfile, slot: Int?, isSelected: Bool, showsDivider: Bool) {
        nameLabel.stringValue = profile.name
        chipsStack.arrangedSubviews.forEach {
            chipsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for group in DisplayProfileHelpers.orderedGroups where profile.groups.contains(group) {
            chipsStack.addArrangedSubview(GroupChipView(text: shortChipTitle(for: group)))
        }
        shortcutBadge.setText(slot.map { "⌃\($0)" } ?? "")
        self.showsDivider = showsDivider
        setSelected(isSelected)
    }

    func setSelected(_ selected: Bool) {
        isSelectedRow = selected
        needsDisplay = true
    }

    func applyFonts() {
        nameLabel.font = Theme.font(.panels, size: 12.5, weight: .medium)
        shortcutBadge.applyFonts()
        for view in chipsStack.arrangedSubviews {
            (view as? GroupChipView)?.applyFonts()
        }
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isSelectedRow ? Theme.selected.cgColor : NSColor.clear.cgColor
        divider.backgroundColor = Theme.line.cgColor
        divider.isHidden = !showsDivider
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        CATransaction.commit()
    }

    @objc private func moreClicked(_ sender: NSButton) {
        onMore?(sender)
    }

    private func shortChipTitle(for group: DisplayProfileGroup) -> String {
        switch group {
        case .layout: String(localized: "浏览")
        case .scale: String(localized: "缩放")
        case .effects: String(localized: "效果")
        case .background: String(localized: "背景")
        }
    }
}

@MainActor
private final class GroupChipView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        label.stringValue = text
        label.font = Theme.font(.panels, size: 10)
        label.textColor = Theme.text2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 0.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -0.5),
        ])
    }

    func applyFonts() {
        label.font = Theme.font(.panels, size: 10)
        invalidateIntrinsicContentSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.well.cgColor
        layer?.borderColor = Theme.line.cgColor
    }
}
