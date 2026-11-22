import AppKit
import MVCache

/// 书架顶部搜索栏：NSSearchField（保留最近 10 个搜索词）＋ 评分、标签、类型三个弹出筛选按钮。
@MainActor
final class SearchBar: NSView, NSSearchFieldDelegate, NSMenuDelegate {
    let searchField = NSSearchField()
    let ratingButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let tagsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let kindButton = NSPopUpButton(frame: .zero, pullsDown: true)

    var onSubmit: ((String) -> Void)?
    var onClearText: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFilterChange: (() -> Void)?
    var tagSuggestionsProvider: (() async -> [String])?

    private(set) var minimumRating: Int?
    private(set) var selectedTags: [String] = []
    private(set) var selectedKinds: Set<SearchKind> = []

    private let bottomLine = CALayer()
    private var cachedTags: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.addSublayer(bottomLine)
        searchField.controlSize = .small; searchField.font = Theme.font(.panels, size: 12)
        searchField.placeholderString = String(localized: "搜索文件名…")
        searchField.sendsSearchStringImmediately = false; searchField.sendsWholeSearchString = true; searchField.maximumRecents = 10
        searchField.delegate = self; searchField.target = self; searchField.action = #selector(searchFieldAction(_:))
        searchField.searchMenuTemplate = makeRecentsMenu()

        let menuFont = Theme.font(.menus, size: Theme.defaultSize(.menus))
        for button in [ratingButton, tagsButton, kindButton] {
            button.controlSize = .small; button.font = menuFont; button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = false; button.menu?.delegate = self
            if let menu = button.menu { Theme.applyMenuFont(to: menu) }
        }
        rebuildMenus()
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)

        let filters = NSStackView(views: [ratingButton, tagsButton, kindButton]); filters.spacing = 4
        let stack = NSStackView(views: [searchField, filters])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ground.cgColor; bottomLine.backgroundColor = Theme.line.cgColor }
    override func layout() { super.layout(); bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5) }

    @objc private func applyFonts() {
        searchField.font = Theme.font(.panels, size: 12)
        let menuFont = Theme.font(.menus, size: Theme.defaultSize(.menus))
        for button in [ratingButton, tagsButton, kindButton] {
            button.font = menuFont
            if let menu = button.menu { Theme.applyMenuFont(to: menu) }
        }
        if let menu = searchField.searchMenuTemplate { Theme.applyMenuFont(to: menu) }
        needsLayout = true
    }

    func focusSearchField() { window?.makeFirstResponder(searchField); searchField.currentEditor()?.selectAll(nil) }
    func setQueryText(_ text: String) { searchField.stringValue = text }
    func setMinimumRating(_ rating: Int?) { guard minimumRating != rating else { return }; minimumRating = rating; rebuildMenus(); onFilterChange?() }
    func setSelectedTags(_ tags: [String]) { guard selectedTags != tags else { return }; selectedTags = tags; rebuildMenus(); onFilterChange?() }
    func setSelectedKinds(_ kinds: Set<SearchKind>) { guard selectedKinds != kinds else { return }; selectedKinds = kinds; rebuildMenus(); onFilterChange?() }
    func reset() { searchField.stringValue = ""; minimumRating = nil; selectedTags = []; selectedKinds = []; rebuildMenus() }

    private func makeRecentsMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "最近搜索"))
        let items: [(String, Int)] = [
            (String(localized: "最近搜索"), NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag),
            ("-", NSSearchField.recentsTitleMenuItemTag), (String(localized: "清除最近搜索"), NSSearchField.clearRecentsMenuItemTag),
            (String(localized: "没有最近搜索"), NSSearchField.noRecentsMenuItemTag),
        ]
        for (title, tag) in items {
            let item = title == "-" ? NSMenuItem.separator() : NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag; menu.addItem(item)
        }
        Theme.applyMenuFont(to: menu)
        return menu
    }

    private func submitCurrentText() {
        let text = searchField.stringValue, trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var recents = searchField.recentSearches
            recents.removeAll { $0 == trimmed }; recents.insert(trimmed, at: 0)
            searchField.recentSearches = Array(recents.prefix(10))
        }
        onSubmit?(text)
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        if sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onClearText?() } else { submitCurrentText() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submitCurrentText(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tagsButton.menu else { return }
        rebuildTagsMenu(menu)
        let provider = tagSuggestionsProvider
        Task { @MainActor [weak self, weak menu] in
            let tags = await provider?() ?? []
            guard let self, let menu, tags != self.cachedTags else { return }
            self.cachedTags = tags; self.rebuildTagsMenu(menu)
        }
    }

    private func rebuildMenus() {
        if let menu = ratingButton.menu {
            menu.removeAllItems()
            let title = switch minimumRating { case nil: String(localized: "评分：不限"); case 0: String(localized: "未评分"); case 5: String(localized: "★ 5"); case let v?: String(localized: "★ \(v) 以上") }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            func add(_ label: String, _ value: Int?) {
                let item = MenuAction(label) { [weak self] in self?.setMinimumRating(value) }.item
                item.state = minimumRating == value ? .on : .off; menu.addItem(item)
            }
            add(String(localized: "不限"), nil); menu.addItem(.separator())
            for star in 1...4 { add(String(localized: "★ \(star) 以上"), star) }
            add(String(localized: "★ 5"), 5); menu.addItem(.separator()); add(String(localized: "未评分"), 0)
        }
        if let menu = tagsButton.menu { rebuildTagsMenu(menu) }
        if let menu = kindButton.menu {
            menu.removeAllItems()
            let options: [(String, String, Set<SearchKind>)] = [
                (String(localized: "类型：全部"), String(localized: "全部"), []), (String(localized: "类型：图片"), String(localized: "图片"), [.image]),
                (String(localized: "类型：视频"), String(localized: "视频"), [.video]), (String(localized: "类型：压缩包"), String(localized: "压缩包"), [.archive]),
            ]
            menu.addItem(withTitle: options.first { $0.2 == selectedKinds }?.0 ?? String(localized: "类型：已选"), action: nil, keyEquivalent: "")
            for (_, label, kinds) in options {
                let item = MenuAction(label) { [weak self] in self?.setSelectedKinds(kinds) }.item
                item.state = selectedKinds == kinds ? .on : .off; menu.addItem(item)
            }
        }
    }

    private func rebuildTagsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = selectedTags.isEmpty ? String(localized: "标签：全部")
            : selectedTags.count == 1 ? String(localized: "标签：\(selectedTags[0])")
            : String(localized: "标签：\(selectedTags[0]) +\(selectedTags.count - 1)")
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if !selectedTags.isEmpty {
            menu.addItem(MenuAction(String(localized: "清除标签")) { [weak self] in self?.setSelectedTags([]) }.item)
            menu.addItem(.separator())
        }
        var seen: Set<String> = []
        let all = (selectedTags + cachedTags).filter { seen.insert($0).inserted }
        if all.isEmpty {
            let empty = NSMenuItem(title: String(localized: "暂无已索引标签"), action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty)
        } else {
            for tag in all {
                let item = MenuAction(tag) { [weak self] in
                    guard let self else { return }
                    var next = self.selectedTags
                    if let idx = next.firstIndex(of: tag) { next.remove(at: idx) } else { next.append(tag) }
                    self.setSelectedTags(next)
                }.item
                item.state = selectedTags.contains(tag) ? .on : .off; menu.addItem(item)
            }
        }
    }
}
