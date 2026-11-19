import AppKit
import MVFoundation
import MVIO
import MVLayout
import MVMetadata
import MVReading
import MVServices
import Observation

struct InfoPanelSettings: Codable, Equatable {}

/// 停靠面板“信息”：显示当前页的评分与标签、文件、图像、拍摄四组字段（值可选中复制）；
/// 翻页去抖 150 ms 后经 `CoreServices.metadataDetails(for:)` 直接读文件头，不用缓存。
@MainActor
final class InfoPanel: DockPanel {
    typealias Settings = InfoPanelSettings

    private(set) var settings: InfoPanelSettings
    var onSettingsChange: (() -> Void)?
    private(set) weak var owner: ReaderWindowController?
    let panelView = InfoPanelView()
    var view: NSView { panelView }

    private(set) var currentEntry: Entry?
    private(set) var details: ImageDetails?
    private(set) var unwritableReason: String?

    private var observedSession: SessionID?
    private var debounceTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var writerObserverID: UUID?
    private weak var observedWriter: MetadataWriteController?
    private var lastLoadedLocation: Location?

    var displayedRating: Int {
        guard let loc = currentEntry?.location else { return 0 }
        return owner?.metadataWriter?.overlay(for: loc)?.rating ?? details?.fields?.rating ?? 0
    }

    var displayedTags: [String] {
        guard let loc = currentEntry?.location else { return [] }
        return owner?.metadataWriter?.overlay(for: loc)?.tags ?? details?.fields?.tags ?? []
    }

    var isWriting: Bool {
        currentEntry.map { owner?.metadataWriter?.overlay(for: $0.location)?.isWriting == true } ?? false
    }

    init(_ settings: InfoPanelSettings?) {
        self.settings = settings ?? InfoPanelSettings()
        panelView.onWindowChange = { [weak self] in
            if self?.panelView.window != nil { self?.scheduleReload(immediate: true) }
        }
        panelView.onRate = { [weak self] rating in self?.rateCurrent(rating) }
        panelView.onAddTag = { [weak self] anchor in self?.openTagEditor(from: anchor) }
        panelView.onRemoveTag = { [weak self] tag in self?.removeTag(tag) }
        panelView.onRetry = { [weak self] in
            if let loc = self?.currentEntry?.location { self?.owner?.metadataWriter?.retryFailure(for: loc) }
        }
    }

    deinit {
        debounceTask?.cancel(); changesTask?.cancel()
        if let id = writerObserverID, let writer = observedWriter { Task { @MainActor in writer.removeObserver(id) } }
    }

    func bind(to window: ReaderWindowController?) {
        guard window !== owner else { return }
        if let id = writerObserverID, let writer = observedWriter {
            writer.removeObserver(id); writerObserverID = nil; observedWriter = nil
        }
        owner = window; observedSession = window?.session.id
        if let writer = window?.metadataWriter {
            observedWriter = writer
            writerObserverID = writer.addObserver { [weak self] in self?.renderMetadataSection() }
        }
        observeFileChanges(); observeSession()
    }

    func addOptions(to menu: NSMenu) {}

    private func observeSession() {
        guard let owner, let id = observedSession else { updateCurrentEntry(nil, pagePixelSize: nil); return }
        let (entry, pixelSize) = withObservationTracking { () -> (Entry?, PixelSize?) in
            // `currentPage` 本身不被观察；页变化时 `currentFrame` 随之变化。
            _ = owner.session.currentFrame
            guard let pages = owner.session.book?.pages, pages.indices.contains(owner.session.currentPage) else { return (nil, nil) }
            let page = pages[owner.session.currentPage]
            return (page.entry, page.metadata?.pixelSize)
        } onChange: { [weak self] in
            Task { @MainActor in guard let self, self.observedSession == id else { return }; self.observeSession() }
        }
        updateCurrentEntry(entry, pagePixelSize: pixelSize)
    }

    private func observeFileChanges() {
        changesTask?.cancel()
        guard let stream = owner?.services.appliedFileChanges() else { return }
        changesTask = Task { [weak self] in
            for await batch in stream {
                guard !Task.isCancelled, let self, let loc = self.currentEntry?.location else { continue }
                if batch.contains(where: { if case let .rewritten(e, _, _) = $0 { e.location == loc } else { false } }) {
                    self.scheduleReload(immediate: true)
                }
            }
        }
    }

    private func updateCurrentEntry(_ entry: Entry?, pagePixelSize: PixelSize?) {
        let changed = entry?.location != currentEntry?.location
        currentEntry = entry
        if changed { details = nil; lastLoadedLocation = nil }
        renderAll(fallbackPixelSize: pagePixelSize)
        if changed { scheduleReload(immediate: false) }
    }

    private func scheduleReload(immediate: Bool) {
        debounceTask?.cancel()
        guard panelView.window != nil, let entry = currentEntry, let services = owner?.services else { return }
        if !immediate && lastLoadedLocation == entry.location { return }
        let targetLocation = entry.location
        debounceTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let self else { return }
            let loaded = try? await services.metadataDetails(for: entry)
            guard !Task.isCancelled, self.currentEntry?.location == targetLocation else { return }
            self.details = loaded; self.lastLoadedLocation = targetLocation
            let fallback = self.owner?.session.book?.pages.first { $0.entry.location == targetLocation }?.metadata?.pixelSize
            self.renderAll(fallbackPixelSize: fallback)
        }
    }

    private func renderAll(fallbackPixelSize: PixelSize? = nil) {
        guard let entry = currentEntry else { unwritableReason = nil; panelView.showEmpty(); return }
        renderMetadataSection()
        let size = details?.pixelSize ?? fallbackPixelSize
        let formatParts = [details?.format, details?.colorSpace].compactMap { $0 }.filter { !$0.isEmpty }
        panelView.setFields([
            .name: entry.name,
            .location: entry.location.parent?.displayPath ?? entry.location.root.displayName,
            .size: entry.identity.size > 0 ? ByteCountFormatter.string(fromByteCount: entry.identity.size, countStyle: .file) : "—",
            .modified: Self.formatTimestamp(nanos: entry.identity.modificationNanos),
            .dimensions: size.map { "\($0.width) × \($0.height)" } ?? "—",
            .format: formatParts.isEmpty ? "—" : formatParts.joined(separator: " · "),
            .camera: Self.formatCamera(make: details?.cameraMake, model: details?.cameraModel),
            .lens: details?.lens ?? "—",
            .focal: details?.focalLength.map { $0.rounded() == $0 ? "\(Int($0)) mm" : String(format: "%.1f mm", $0) } ?? "—",
            .aperture: details?.aperture.map { $0.rounded() == $0 ? "ƒ/\(Int($0))" : String(format: "ƒ/%.1f", $0) } ?? "—",
            .exposure: details?.exposureTime.map(Self.formatExposure) ?? "—",
            .iso: details?.iso.map(String.init) ?? "—",
            .captured: details?.capturedAt.map { Self.dateFormatter.string(from: $0) } ?? "—",
            .gps: (details?.latitude != nil && details?.longitude != nil) ? String(format: "%.5f, %.5f", details!.latitude!, details!.longitude!) : "—",
        ])
    }

    private func renderMetadataSection() {
        guard let entry = currentEntry else { return }
        let writability = MetadataWriteController.writability(for: entry)
        if writability == .writable {
            unwritableReason = nil
            panelView.showWritableMetadata(rating: displayedRating, tags: displayedTags, isWriting: isWriting, failureReason: owner?.metadataWriter?.failure(for: entry.location)?.reason)
        } else {
            let reason = MetadataWriteController.detailReason(for: writability)
            unwritableReason = reason
            panelView.showUnwritableNote(reason)
        }
    }

    private func rateCurrent(_ rating: Int) {
        guard let owner, let entry = currentEntry, let writer = owner.metadataWriter else { return }
        writer.setRating(rating == displayedRating ? 0 : rating, origin: FileOrigin(window: owner, items: [entry]))
    }

    private func openTagEditor(from anchor: NSView) {
        guard let owner, let entry = currentEntry else { return }
        owner.metadataWriter?.presentTagEditor(origin: FileOrigin(window: owner, items: [entry]), relativeTo: anchor)
    }

    private func removeTag(_ tag: String) {
        guard let owner, let entry = currentEntry else { return }
        owner.metadataWriter?.setTags(displayedTags.filter { $0 != tag }, origin: FileOrigin(window: owner, items: [entry]))
    }

    private static let dateFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    private static func formatTimestamp(nanos: Int64) -> String {
        nanos > 0 ? dateFormatter.string(from: Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)) : "—"
    }

    private static func formatCamera(make: String?, model: String?) -> String {
        let mk = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let md = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mk.isEmpty && md.isEmpty { return "—" }
        if md.isEmpty { return mk }
        return (mk.isEmpty || md.localizedCaseInsensitiveContains(mk)) ? md : "\(mk) \(md)"
    }

    private static func formatExposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 1 { return "1/\(max(1, Int((1.0 / seconds).rounded()))) s" }
        return seconds.rounded() == seconds ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}

// MARK: 视图

@MainActor
final class InfoPanelView: NSView {
    enum FieldKey: Hashable {
        case name, location, size, modified, dimensions, format
        case camera, lens, focal, aperture, exposure, iso, captured, gps
    }

    var onWindowChange: (() -> Void)?
    var onRate: ((Int) -> Void)?
    var onAddTag: ((NSView) -> Void)?
    var onRemoveTag: ((String) -> Void)?
    var onRetry: (() -> Void)?

    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "没有选中的图片"))
    private let metaSection = NSStackView()
    private var starButtons: [NSButton] = []
    private let writingRow = NSStackView()
    private let writingSpinner = NSProgressIndicator()
    private let tagsContainer = NSStackView()
    private let addTagButton = NSButton()
    private let noteBox = NSView(), noteLabel = NSTextField(wrappingLabelWithString: "")
    private let errorBox = NSView(), errorLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = FlatButton(font: .systemFont(ofSize: 11.5), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 5, height: 22, padding: 10)
    private var fieldViews: [FieldKey: NSTextField] = [:]
    private var currentTags: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        noteBox.layer?.backgroundColor = Theme.well.cgColor
        errorBox.layer?.backgroundColor = Theme.dangerSoft.cgColor
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?() }

    private func buildUI() {
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = Theme.text2; emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false; addSubview(emptyLabel)

        let contentStack = NSStackView()
        contentStack.orientation = .vertical; contentStack.alignment = .leading; contentStack.spacing = 4
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 14, right: 12)

        contentStack.addArrangedSubview(Self.groupHeader(String(localized: "评分与标签")))
        metaSection.orientation = .vertical; metaSection.alignment = .leading; metaSection.spacing = 6

        let starsRow = NSStackView(); starsRow.spacing = 2
        for i in 1...5 {
            let btn = NSButton(title: "★", target: self, action: #selector(starClicked(_:)))
            btn.tag = i; btn.isBordered = false; btn.font = .systemFont(ofSize: 15)
            btn.setAccessibilityLabel(String(localized: "\(i) 星"))
            starButtons.append(btn); starsRow.addArrangedSubview(btn)
        }
        metaSection.addArrangedSubview(Self.kvRow(String(localized: "评分"), view: starsRow))

        writingSpinner.style = .spinning; writingSpinner.controlSize = .mini
        let writingText = NSTextField(labelWithString: String(localized: "正在写入…"))
        writingText.font = .systemFont(ofSize: 11); writingText.textColor = Theme.text2
        writingRow.spacing = 6; writingRow.alignment = .centerY
        writingRow.addArrangedSubview(writingSpinner); writingRow.addArrangedSubview(writingText); writingRow.isHidden = true
        metaSection.addArrangedSubview(Self.kvRow("", view: writingRow))

        tagsContainer.orientation = .vertical; tagsContainer.alignment = .leading; tagsContainer.spacing = 4
        addTagButton.title = String(localized: "+ 标签"); addTagButton.isBordered = false
        addTagButton.font = .systemFont(ofSize: 11); addTagButton.contentTintColor = Theme.text2
        addTagButton.target = self; addTagButton.action = #selector(addTagClicked(_:))
        metaSection.addArrangedSubview(Self.kvRow(String(localized: "标签"), view: tagsContainer))

        errorBox.wantsLayer = true; errorBox.layer?.cornerRadius = 6
        errorLabel.font = .systemFont(ofSize: 11.5); errorLabel.textColor = Theme.danger
        retryButton.setText(String(localized: "重试")); retryButton.target = self; retryButton.action = #selector(retryClicked(_:))
        let errStack = NSStackView(views: [errorLabel, retryButton])
        errStack.orientation = .vertical; errStack.alignment = .leading; errStack.spacing = 6
        errStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        Self.pin(errStack, inside: errorBox); errorBox.isHidden = true
        metaSection.addArrangedSubview(errorBox)

        noteBox.wantsLayer = true; noteBox.layer?.cornerRadius = 6
        noteLabel.font = .systemFont(ofSize: 11.5); noteLabel.textColor = Theme.text2
        Self.pin(noteLabel, inside: noteBox, inset: 8); noteBox.isHidden = true
        contentStack.addArrangedSubview(metaSection); contentStack.addArrangedSubview(noteBox)

        let groups: [(String, [(FieldKey, String)])] = [
            (String(localized: "文件"), [(.name, String(localized: "名称")), (.location, String(localized: "位置")), (.size, String(localized: "大小")), (.modified, String(localized: "修改时间"))]),
            (String(localized: "图像"), [(.dimensions, String(localized: "尺寸")), (.format, String(localized: "格式"))]),
            (String(localized: "拍摄"), [
                (.camera, String(localized: "相机")), (.lens, String(localized: "镜头")), (.focal, String(localized: "焦距")), (.aperture, String(localized: "光圈")),
                (.exposure, String(localized: "快门")), (.iso, String(localized: "ISO")), (.captured, String(localized: "拍摄时间")), (.gps, String(localized: "GPS")),
            ]),
        ]
        for (title, rows) in groups {
            contentStack.addArrangedSubview(Self.groupHeader(title))
            for (key, label) in rows {
                let field = Self.valueField()
                fieldViews[key] = field
                contentStack.addArrangedSubview(Self.kvRow(label, view: field))
            }
        }

        let docView = FlippedDocumentView()
        Self.pin(contentStack, inside: docView)
        scroll.documentView = docView; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        Self.pin(scroll, inside: self)

        docView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            noteBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            errorBox.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            metaSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showEmpty()
    }

    func showEmpty() { scroll.isHidden = true; emptyLabel.isHidden = false }

    func showWritableMetadata(rating: Int, tags: [String], isWriting: Bool, failureReason: String?) {
        scroll.isHidden = false; emptyLabel.isHidden = true; metaSection.isHidden = false; noteBox.isHidden = true
        for (idx, btn) in starButtons.enumerated() {
            btn.attributedTitle = NSAttributedString(string: "★", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: idx < rating ? Theme.star : Theme.lineStrong])
        }
        writingRow.isHidden = !isWriting
        if isWriting { writingSpinner.startAnimation(nil) } else { writingSpinner.stopAnimation(nil) }
        errorBox.isHidden = failureReason == nil
        if let failureReason { errorLabel.stringValue = failureReason }
        rebuildTags(tags)
    }

    func showUnwritableNote(_ reason: String) {
        scroll.isHidden = false; emptyLabel.isHidden = true; metaSection.isHidden = true; noteBox.isHidden = false
        noteLabel.stringValue = reason
    }

    func setFields(_ values: [FieldKey: String]) {
        for (key, value) in values { fieldViews[key]?.stringValue = value }
    }

    private func rebuildTags(_ tags: [String]) {
        currentTags = tags
        tagsContainer.arrangedSubviews.forEach { tagsContainer.removeArrangedSubview($0); $0.removeFromSuperview() }
        if !tags.isEmpty {
            let chipRow = NSStackView(); chipRow.orientation = .horizontal; chipRow.spacing = 4; chipRow.alignment = .centerY
            for (index, tag) in tags.enumerated() {
                let chip = FlatButton(font: .systemFont(ofSize: 11), fill: Theme.well, foreground: Theme.text2, border: Theme.line, radius: 4, height: 20, padding: 6)
                chip.setText("\(tag) ×"); chip.tag = index; chip.toolTip = String(localized: "点击移除“\(tag)”")
                chip.target = self; chip.action = #selector(tagChipClicked(_:))
                chipRow.addArrangedSubview(chip)
            }
            tagsContainer.addArrangedSubview(chipRow)
        }
        tagsContainer.addArrangedSubview(addTagButton)
    }

    @objc private func starClicked(_ sender: NSButton) { onRate?(sender.tag) }
    @objc private func addTagClicked(_ sender: NSButton) { onAddTag?(sender) }
    @objc private func retryClicked(_ sender: Any?) { onRetry?() }
    @objc private func tagChipClicked(_ sender: NSButton) {
        if currentTags.indices.contains(sender.tag) { onRemoveTag?(currentTags[sender.tag]) }
    }

    private static func groupHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = Theme.text2
        return label
    }

    private static func valueField() -> NSTextField {
        let field = NSTextField(labelWithString: "—")
        field.font = .systemFont(ofSize: 12); field.textColor = Theme.text
        field.isSelectable = true; field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        field.lineBreakMode = .byTruncatingMiddle; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func kvRow(_ key: String, view: NSView) -> NSStackView {
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 12); keyLabel.textColor = Theme.text2
        keyLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [keyLabel, view])
        row.orientation = .horizontal; row.alignment = .firstBaseline; row.spacing = 6
        return row
    }

    private static func pin(_ child: NSView, inside parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
}

private final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }
