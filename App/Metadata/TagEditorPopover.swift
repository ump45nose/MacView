import AppKit
import MVCache
import MVFoundation
import MVMetadata
import MVServices

/// ⌥T 弹出的标签编辑弹层：输入框 + 已有标签建议（来自 `SearchCatalog.tagSuggestions`），
/// 回车新建或切换标签，多选时作用于全部选中项。
@MainActor
final class TagEditorPopover: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case existing(tag: String, state: TagPresence)
        case create(tag: String)
    }

    private enum TagPresence {
        case none, some, all
    }

    let textField = NSTextField(string: "")
    let tableView = NSTableView()
    var onClose: (() -> Void)?

    private let entries: [Entry]
    private let services: CoreServices
    private weak var writer: MetadataWriteController?
    private let origin: FileOrigin

    private var perEntryTags: [Location: [String]] = [:]
    private var suggestions: [String] = []
    private var rows: [Row] = []
    private var loadTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    init(entries: [Entry], services: CoreServices, writer: MetadataWriteController, origin: FileOrigin) {
        self.entries = entries
        self.services = services
        self.writer = writer
        self.origin = origin
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit {
        loadTask?.cancel()
        suggestTask?.cancel()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 256, height: 248))
        let title = NSTextField(labelWithString: String(localized: "标签 · \(entries.count) 张"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Theme.text

        textField.placeholderString = String(localized: "输入标签，回车新建或切换")
        textField.font = .systemFont(ofSize: 12)
        textField.controlSize = .regular
        textField.delegate = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let cancelBtn = FlatButton(font: .systemFont(ofSize: 11.5), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 5, height: 24, padding: 10)
        cancelBtn.setText(String(localized: "取消"))
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelPressed(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelBtn])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [title, textField, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            textField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 144),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textField)
        loadCurrentTags()
        refreshSuggestions(prefix: "")
    }

    private func loadCurrentTags() {
        loadTask?.cancel()
        let entries = self.entries
        let services = self.services
        // 先填乐观值
        for entry in entries {
            if let tags = writer?.overlay(for: entry.location)?.tags {
                perEntryTags[entry.location] = tags
            }
        }
        rebuildRows()
        loadTask = Task { [weak self] in
            var loaded: [Location: [String]] = [:]
            for entry in entries {
                if Task.isCancelled { return }
                if let details = try? await services.metadataDetails(for: entry) {
                    loaded[entry.location] = details.fields?.tags ?? []
                }
            }
            guard !Task.isCancelled, let self else { return }
            for (loc, tags) in loaded where self.writer?.overlay(for: loc)?.tags == nil {
                self.perEntryTags[loc] = tags
            }
            self.rebuildRows()
        }
    }

    private func refreshSuggestions(prefix: String) {
        suggestTask?.cancel()
        let catalog = services.search
        suggestTask = Task { [weak self] in
            let list = (try? await catalog?.tagSuggestions(prefix: prefix, limit: 30)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.suggestions = list
            self.rebuildRows()
        }
    }

    private func presence(of tag: String) -> TagPresence {
        guard !entries.isEmpty else { return .none }
        var count = 0
        for entry in entries where (perEntryTags[entry.location] ?? []).contains(tag) {
            count += 1
        }
        if count == 0 { return .none }
        return count == entries.count ? .all : .some
    }

    private func rebuildRows() {
        let query = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        var list: [Row] = []

        // 优先展示当前选中项已有的标签（与输入匹配时）
        let currentTags = entries.flatMap { perEntryTags[$0.location] ?? [] }
        for tag in currentTags + suggestions {
            guard seen.insert(tag).inserted else { continue }
            if !query.isEmpty && !tag.localizedCaseInsensitiveContains(query) { continue }
            list.append(.existing(tag: tag, state: presence(of: tag)))
        }
        if !query.isEmpty, !seen.contains(query) {
            list.append(.create(tag: query))
        }
        rows = list
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let query = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildRows()
        refreshSuggestions(prefix: query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(delta: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(delta: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0 ? 0 : min(max(current + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func commitSelection() {
        let query = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if tableView.selectedRow >= 0, rows.indices.contains(tableView.selectedRow) {
            apply(row: rows[tableView.selectedRow])
        } else if !query.isEmpty {
            apply(row: .create(tag: query))
        }
    }

    private func apply(row: Row) {
        guard let writer else { return }
        switch row {
        case let .existing(tag, state):
            let adding = state != .all
            writer.applyTagToggle(tag, adding: adding, perEntryTags: perEntryTags, origin: origin)
        case let .create(tag):
            writer.applyTagToggle(tag, adding: true, perEntryTags: perEntryTags, origin: origin)
        }
        onClose?()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        apply(row: rows[row])
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onClose?()
    }

    // MARK: NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("tagSuggestionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let v = NSTableCellView()
            v.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            v.textField = label
            v.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        }()
        guard let label = cell.textField, rows.indices.contains(row) else { return cell }
        switch rows[row] {
        case let .existing(tag, state):
            let prefix = switch state {
            case .all: "✓ "
            case .some: "– "
            case .none: "   "
            }
            label.stringValue = prefix + tag
            label.textColor = Theme.text
        case let .create(tag):
            label.stringValue = String(localized: "回车新建“\(tag)”")
            label.textColor = Theme.text2
        }
        return cell
    }
}
