import AppKit
import MVCache
import MVCommands
import MVFoundation
import MVLibraryData
import MVPipeline
import MVServices

/// 书架搜索模式下的结果视图：范围与已索引数、结果列表、空状态与建立索引按钮、底栏计数。
@MainActor
final class BookshelfSearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = SearchResultsTableView()
    let scopeLabel = NSTextField(labelWithString: "")
    let footerLabel = NSTextField(labelWithString: "")
    let indexEmptyButton = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.primary, foreground: Theme.onPrimary, radius: 6, height: 26, padding: 12)

    var onActivate: ((SearchHit) -> Void)?
    var onCancelSearch: (() -> Void)?
    var onIndexScope: (() -> Void)?
    var onContextMenu: (([SearchHit]) -> NSMenu?)?
    var onStatusMessage: ((String) -> Void)?

    private weak var services: CoreServices?
    private weak var writer: MetadataWriteController?
    private var writerObserverID: UUID?
    private let scroll = NSScrollView()
    private let emptyContainer = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptySubtitle = NSTextField(wrappingLabelWithString: "")
    private let availability = LibraryAvailability()
    private let thumbCache = NSCache<NSString, SearchThumbBox>()
    private var thumbTasks: [String: Task<Void, Never>] = [:]

    private(set) var hits: [SearchHit] = []
    private var terms: [String] = []
    private var scope: Location?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for label in [scopeLabel, footerLabel] {
            label.font = .systemFont(ofSize: 11); label.textColor = Theme.text2
            label.lineBreakMode = label === scopeLabel ? .byTruncatingMiddle : .byTruncatingTail
            addSubview(label)
        }
        table.headerView = nil; table.rowHeight = 50; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchResult"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(rowClicked(_:))
        table.onReturn = { [weak self] in guard let self, table.selectedRow >= 0 else { return }; activateRow(table.selectedRow) }
        table.onEscape = { [weak self] in self?.onCancelSearch?() }
        table.onContextMenu = { [weak self] row in self?.contextMenu(row: row) }

        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)

        emptyTitle.font = Theme.serif(15); emptyTitle.textColor = Theme.text; emptyTitle.alignment = .center
        emptySubtitle.font = .systemFont(ofSize: 12); emptySubtitle.textColor = Theme.text2; emptySubtitle.alignment = .center
        indexEmptyButton.setText(String(localized: "为此文件夹建立索引"))
        indexEmptyButton.target = self; indexEmptyButton.action = #selector(indexButtonPressed(_:))
        emptyContainer.orientation = .vertical; emptyContainer.alignment = .centerX; emptyContainer.spacing = 8
        for v in [emptyTitle, emptySubtitle, indexEmptyButton] as [NSView] { emptyContainer.addArrangedSubview(v) }
        emptyContainer.isHidden = true; addSubview(emptyContainer)

        availability.view = self
        availability.visibleLocations = { [weak self] in self?.visibleRows.map { self!.hits[$0].entry.location } ?? [] }
        availability.onChange = { [weak self] in self?.refreshVisibleCells() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit {
        thumbTasks.values.forEach { $0.cancel() }
        if let id = writerObserverID, let writer { Task { @MainActor in writer.removeObserver(id) } }
    }
    nonisolated override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ground.cgColor }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { availability.recheckAll(); loadVisibleThumbnails() } }

    func attach(_ services: CoreServices?, writer: MetadataWriteController? = nil) {
        if writer !== self.writer {
            if let id = writerObserverID, let prev = self.writer { prev.removeObserver(id); writerObserverID = nil }
            self.writer = writer
            if let writer {
                writerObserverID = writer.addObserver { [weak self] in self?.refreshVisibleCells() }
            }
        }
        guard services !== self.services else { return }
        self.services = services; availability.attach(services)
        if let settings = services?.settings { followThumbnailMemoryBudget(thumbCache, settings: settings) }
    }

    func update(queryText: String, terms: [String], scope: Location?, result: SearchResult?, isLoading: Bool, error: String?) {
        self.terms = terms; self.scope = scope; self.hits = result?.hits ?? []
        let indexed = result?.indexedCount ?? 0, truncated = result?.truncated ?? false
        availability.retain(Set(hits.map(\.entry.location)))
        scopeLabel.stringValue = scope.map {
            let name = $0.name.isEmpty ? $0.description : $0.name
            return String(localized: "在“\(name)”及子文件夹中 · 已索引 \(indexed.formatted()) 项")
        } ?? String(localized: "未打开文件夹")
        if let error {
            emptyTitle.stringValue = String(localized: "搜索失败"); emptySubtitle.stringValue = error
            indexEmptyButton.isHidden = true; emptyContainer.isHidden = false; scroll.isHidden = true
        } else if !isLoading && hits.isEmpty {
            let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyTitle.stringValue = q.isEmpty ? String(localized: "没有符合条件的项") : String(localized: "没有找到“\(q)”")
            emptySubtitle.stringValue = String(localized: "只搜索已索引的文件。")
            indexEmptyButton.isHidden = scope == nil; emptyContainer.isHidden = false; scroll.isHidden = true
        } else {
            emptyContainer.isHidden = true; scroll.isHidden = false
        }
        footerLabel.textColor = truncated && !isLoading ? Theme.text : Theme.text2
        footerLabel.stringValue = isLoading ? String(localized: "正在搜索…")
            : truncated ? String(localized: "只显示前 5000 条 · Esc 回到文件夹")
            : String(localized: "\(hits.count.formatted()) 项 · 只显示已索引的文件 · Esc 回到文件夹")
        table.reloadData()
        if !hits.isEmpty { table.scrollRowToVisible(0) }
        availability.visibleChanged(); loadVisibleThumbnails(); needsLayout = true
    }

    var selectedHits: [SearchHit] { table.selectedRowIndexes.compactMap { hits.indices.contains($0) ? hits[$0] : nil } }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, bar: CGFloat = 26, listH = max(h - bar * 2, 0), ew = max(w - 32, 0)
        scopeLabel.frame = CGRect(x: 10, y: 5, width: max(w - 20, 0), height: 15)
        scroll.frame = CGRect(x: 0, y: bar, width: w, height: listH)
        footerLabel.frame = CGRect(x: 10, y: h - bar + 5, width: max(w - 20, 0), height: 15)
        emptySubtitle.preferredMaxLayoutWidth = ew
        let es = emptyContainer.fittingSize
        emptyContainer.frame = CGRect(x: 16, y: bar + max(24, (listH - es.height) / 2 - 10), width: ew, height: es.height)
    }

    private var visibleRows: Range<Int> {
        let r = table.rows(in: table.visibleRect)
        return r.length > 0 ? max(r.location, 0)..<min(r.location + r.length, hits.count) : 0..<min(hits.count, 20)
    }

    @objc private func boundsChanged(_ notification: Notification) { availability.scrolled(); loadVisibleThumbnails() }

    private func loadVisibleThumbnails() {
        guard let pipeline = services?.pipeline, window != nil else { return }
        let maxPixel = Int(36 * (window?.backingScaleFactor ?? 2))
        for row in visibleRows {
            let entry = hits[row].entry
            guard entry.kind == .image || entry.kind == .video else { continue }
            let key = entry.identity.cacheKey
            guard thumbCache.object(forKey: key as NSString) == nil, thumbTasks[key] == nil else { continue }
            thumbTasks[key] = Task { [weak self] in
                defer { self?.thumbTasks[key] = nil }
                guard let result = try? await pipeline.thumbnail(for: entry.identity, maxPixel: maxPixel, priority: .visible), !Task.isCancelled, let self else { return }
                self.thumbCache.setObject(SearchThumbBox(result.image), forKey: key as NSString, cost: result.image.bytesPerRow * result.image.height)
                self.refreshVisibleCells()
            }
        }
    }

    private func refreshVisibleCells() {
        for row in visibleRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SearchResultCell { configure(cell, row: row) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LibraryRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("searchResultCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SearchResultCell ?? { let c = SearchResultCell(); c.identifier = id; return c }()
        configure(cell, row: row); return cell
    }

    private func configure(_ cell: SearchResultCell, row: Int) {
        guard hits.indices.contains(row) else { return }
        let hit = hits[row], state = availability.state(of: hit.entry.location)
        let overlay = writer?.overlay(for: hit.entry.location)
        let effectiveRating = overlay?.rating ?? hit.rating
        let effectiveTags = overlay?.tags ?? (hit.tags ?? [])
        cell.show(hit: hit, terms: terms, rating: effectiveRating, tags: effectiveTags, isWriting: overlay?.isWriting == true,
                  relativeFolder: Self.relativeParentPath(of: hit.entry.location, under: scope),
                  thumbnail: thumbCache.object(forKey: hit.entry.identity.cacheKey as NSString)?.image, availability: state)
        cell.badge.onPress = { [weak self] in self?.presentUnavailable(for: hit) }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard hits.indices.contains(row), NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true else { return }
        activateRow(row)
    }

    private func activateRow(_ row: Int) {
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        if availability.state(of: hit.entry.location)?.isUnavailable == true { presentUnavailable(for: hit); return }
        onActivate?(hit)
    }

    private func presentUnavailable(for hit: SearchHit) {
        guard let state = availability.state(of: hit.entry.location), state.isUnavailable else { return }
        onStatusMessage?(state == .missing ? String(localized: "找不到这个文件") : String(localized: "网络卷没有连接"))
    }

    private func contextMenu(row: Int?) -> NSMenu? {
        guard let row, hits.indices.contains(row) else { return nil }
        let rows = table.selectedRowIndexes.contains(row) ? Array(table.selectedRowIndexes) : [row]
        return onContextMenu?(rows.compactMap { hits.indices.contains($0) ? hits[$0] : nil })
    }

    @objc private func indexButtonPressed(_ sender: Any?) { onIndexScope?() }

    private static func relativeParentPath(of location: Location, under scope: Location?) -> String {
        guard let parent = location.parent else { return "" }
        guard let scope else { return parent.displayPath }
        let p = parent.description, s = scope.description
        if p == s { return "" }
        let prefix = s.hasSuffix("/") ? s : s + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : parent.name
    }
}

@MainActor
final class SearchResultsTableView: NSTableView, InputScoped {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onContextMenu: ((Int?) -> NSMenu?)?
    var inputScope: InputScope { .list }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, event.specialKey == .carriageReturn || event.specialKey == .enter { onReturn?(); return }
        if mods.isEmpty, event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return onContextMenu?(row >= 0 ? row : nil)
    }
}

@MainActor
private final class SearchResultCell: NSView {
    private static let starColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0xE3 / 255, green: 0x9A / 255, blue: 0x77 / 255, alpha: 1)
        : NSColor(srgbRed: 0xC2 / 255, green: 0x64 / 255, blue: 0x3F / 255, alpha: 1) }

    private let thumb = CALayer()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    let badge = UnavailableBadge()
    private var isDimmed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layerUsesCoreImageFilters = true
        thumb.cornerRadius = 4; thumb.masksToBounds = true; thumb.contentsGravity = .resizeAspectFill
        thumb.actions = ["contents": NSNull(), "opacity": NSNull()]; layer?.addSublayer(thumb)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular); icon.contentTintColor = Theme.text2
        nameLabel.lineBreakMode = .byTruncatingMiddle; metaLabel.lineBreakMode = .byTruncatingTail
        for v in [icon, nameLabel, metaLabel, badge] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    nonisolated override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { thumb.backgroundColor = Theme.well.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { badge.isHidden ? nil : badge.hitTest(convert(point, from: superview)) }

    override func layout() {
        super.layout()
        let tf = CGRect(x: 10, y: (bounds.height - 36) / 2, width: 36, height: 36)
        CATransaction.begin(); CATransaction.setDisableActions(true); thumb.frame = tf; CATransaction.commit()
        icon.frame = tf; badge.frame = CGRect(x: bounds.width - 28, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let x = tf.maxX + 8, w = max((badge.isHidden ? bounds.width - 10 : badge.frame.minX - 4) - x, 0)
        nameLabel.frame = CGRect(x: x, y: 7, width: w, height: 18); metaLabel.frame = CGRect(x: x, y: 27, width: w, height: 16)
    }

    func show(hit: SearchHit, terms: [String], rating: Int?, tags: [String], isWriting: Bool, relativeFolder: String, thumbnail: CGImage?, availability: Availability?) {
        nameLabel.attributedStringValue = Self.highlightedName(hit.entry.name, terms: terms)
        metaLabel.attributedStringValue = Self.metaString(rating: rating, tags: tags, isWriting: isWriting, relativeFolder: relativeFolder, availability: availability)
        thumb.contents = thumbnail; icon.isHidden = thumbnail != nil
        if thumbnail == nil {
            let sym = switch hit.entry.kind { case .directory: "folder.fill"; case .archive: "doc.zipper"; case .video: "film"; case .image: "photo"; case .other: "doc" }
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        }
        badge.show(availability)
        let dimmed = availability?.isUnavailable == true
        if dimmed != isDimmed { isDimmed = dimmed; LibraryPanels.dim([nameLabel, metaLabel], thumb: thumb, dimmed: dimmed); icon.alphaValue = dimmed ? 0.45 : 1 }
        needsLayout = true
    }

    private static func highlightedName(_ name: String, terms: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: Theme.text])
        let ns = name as NSString
        for term in terms where !term.isEmpty {
            var pos = 0
            while pos < ns.length {
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: pos, length: ns.length - pos))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.addAttributes([.font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .backgroundColor: Theme.accentSoft], range: r)
                pos = r.location + r.length
            }
        }
        return out
    }

    private static func metaString(rating: Int?, tags: [String], isWriting: Bool, relativeFolder: String, availability: Availability?) -> NSAttributedString {
        let out = NSMutableAttributedString(), font = NSFont.systemFont(ofSize: 11)
        func sep() { if out.length > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: font])) } }
        if let r = rating, r > 0 {
            let c = min(max(r, 1), 5)
            out.append(NSAttributedString(string: String(repeating: "★", count: c), attributes: [.font: font, .foregroundColor: starColor]))
            if c < 5 { out.append(NSAttributedString(string: String(repeating: "★", count: 5 - c), attributes: [.font: font, .foregroundColor: Theme.lineStrong])) }
        }
        if isWriting {
            sep(); out.append(NSAttributedString(string: String(localized: "正在写入…"), attributes: [.font: font, .foregroundColor: Theme.text2]))
        }
        for tag in tags.prefix(3) {
            sep(); out.append(NSAttributedString(string: " \(tag) ", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Theme.text2, .backgroundColor: Theme.well]))
        }
        if case .volumeUnavailable = availability {
            sep(); out.append(NSAttributedString(string: String(localized: "⚠ 网络卷没有连接"), attributes: [.font: font, .foregroundColor: Theme.text2]))
        } else if !relativeFolder.isEmpty {
            sep(); out.append(NSAttributedString(string: relativeFolder, attributes: [.font: font, .foregroundColor: Theme.text2]))
        }
        return out
    }
}

private final class SearchThumbBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
