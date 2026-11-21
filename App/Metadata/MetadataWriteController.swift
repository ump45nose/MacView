import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVMetadata
import MVServices

/// 评分与标签写入控制器：先乐观更新界面显示，再经 `FileOperationController` 执行 `.setMetadata`，
/// 连续按键改同一张时合并为最后一次；批量写入支持进度与取消，撤销沿用 `FileOperationController` 的 `UndoStep`。
@MainActor
final class MetadataWriteController {
    struct OptimisticOverlay: Equatable {
        var rating: Int?
        var tags: [String]?
        var isWriting: Bool
    }

    struct FailureRecord {
        let reason: String
        let retry: @MainActor () -> Void
    }

    private struct PendingSingle {
        var fields: XMPFields
        var origin: FileOrigin
        var title: String
        var previous: OptimisticOverlay?
    }

    private weak var app: AppDelegate?
    private var overlays: [Location: OptimisticOverlay] = [:]
    private var activeLocations: Set<Location> = []
    private var queuedSingles: [Location: PendingSingle] = [:]
    private var debounceTasks: [Location: Task<Void, Never>] = [:]
    private var failures: [Location: FailureRecord] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var changesTask: Task<Void, Never>?
    private var activePopover: NSPopover?

    init(app: AppDelegate) {
        self.app = app
        observeAppliedChanges()
    }

    deinit {
        debounceTasks.values.forEach { $0.cancel() }
        changesTask?.cancel()
    }

    var pendingCount: Int { overlays.values.filter(\.isWriting).count }
    func overlay(for location: Location) -> OptimisticOverlay? { overlays[location] }
    func failure(for location: Location) -> FailureRecord? { failures[location] }

    func retryFailure(for location: Location) {
        guard let record = failures.removeValue(forKey: location) else { return }
        notifyObservers()
        record.retry()
    }

    @discardableResult
    func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = handler; return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notifyObservers() { observers.values.forEach { $0() } }

    private func observeAppliedChanges() {
        guard let stream = app?.services?.appliedFileChanges() else { return }
        changesTask = Task { [weak self] in
            for await batch in stream {
                guard !Task.isCancelled, let self else { return }
                var changed = false
                for case let .rewritten(entry, _, _) in batch where self.overlays[entry.location]?.isWriting == false {
                    self.overlays.removeValue(forKey: entry.location)
                    changed = true
                }
                if changed { self.notifyObservers() }
            }
        }
    }

    // MARK: 可写性判定

    static func writability(for entry: Entry) -> MetadataWritability {
        if entry.location.layers.count > 1 { return .insideArchive }
        switch entry.kind {
        case .video: return .unsupportedFormat("video")
        case .directory: return .unsupportedFormat("directory")
        case .archive: return .unsupportedFormat("archive")
        case .image, .other: return MetadataFormat.writability(fileName: entry.name, header: nil)
        }
    }

    static func shortReason(for writability: MetadataWritability) -> String { reason(for: writability, detailed: false) }
    static func detailReason(for writability: MetadataWritability) -> String { reason(for: writability, detailed: true) }

    private static func reason(for writability: MetadataWritability, detailed: Bool) -> String {
        switch writability {
        case .writable: return ""
        case .insideArchive: return detailed ? String(localized: "压缩包内的文件只读，不能评分和加标签。") : String(localized: "压缩包内的文件只读")
        case let .unsupportedFormat(f):
            let subject = switch f.lowercased() {
            case "video": String(localized: "视频")
            case "directory": String(localized: "文件夹")
            case "archive": String(localized: "压缩包")
            case "unknown", "": String(localized: "这种文件")
            default: detailed ? f.uppercased() : String(localized: "\(f.uppercased()) 格式")
            }
            return detailed ? String(localized: "\(subject)不能评分和加标签。当前只支持 JPEG、TIFF、HEIC。") : String(localized: "\(subject)不能评分")
        }
    }

    func canEdit(_ origin: FileOrigin) -> Bool {
        app?.services?.fileOperations != nil && !origin.items.isEmpty && origin.items.allSatisfy { Self.writability(for: $0) == .writable }
    }

    @discardableResult
    private func showUnwritableReason(for items: [Entry], in controller: ReaderWindowController?) -> Bool {
        guard let controller, let unwritable = items.first(where: { Self.writability(for: $0) != .writable }) else { return false }
        let reason = Self.shortReason(for: Self.writability(for: unwritable))
        controller.content.statusBar.showMessage(reason)
        controller.viewer.showMetadataToast(text: reason, isSpinning: false)
        return true
    }

    func handleDisabledCommand(_ id: CommandID, in controller: ReaderWindowController?) -> Bool {
        guard Self.metadataCommands.contains(id), let controller else { return false }
        return showUnwritableReason(for: controller.fileOrigin().items, in: controller)
    }

    private static let metadataCommands: Set<CommandID> = [
        .ratingSet0, .ratingSet1, .ratingSet2, .ratingSet3, .ratingSet4, .ratingSet5, .metadataTagsEdit,
    ]

    // MARK: 评分与标签写入

    func setRating(_ rating: Int, origin: FileOrigin) {
        let clamped = min(max(rating, 0), 5)
        guard canEdit(origin) else { showUnwritableReason(for: origin.items, in: targetController(for: origin)); return }
        let title = clamped == 0 ? String(localized: "清除评分") : String(localized: "评分 \(clamped) 星")
        submitUniform(XMPFields(rating: clamped), title: title, origin: origin)
    }

    func setTags(_ tags: [String], origin: FileOrigin) {
        guard canEdit(origin) else { showUnwritableReason(for: origin.items, in: targetController(for: origin)); return }
        submitUniform(XMPFields(tags: Self.normalizeTags(tags)), title: String(localized: "编辑标签"), origin: origin)
    }

    private func submitUniform(_ fields: XMPFields, title: String, origin: FileOrigin) {
        if origin.items.count == 1 {
            enqueueSingle(entry: origin.items[0], fields: fields, title: title, origin: origin)
        } else {
            let locs = origin.items.map(\.location)
            let map = Dictionary(uniqueKeysWithValues: locs.map { ($0, fields) })
            Task { await executeBatch(operation: .setMetadata(locs, fields), targets: locs, optimisticFields: map, title: title, origin: origin) }
        }
    }

    /// 批量增删单个标签：保留每张图原有标签，合并为单次 FileOperation（一次 ⌘Z 撤回整批）。
    func applyTagToggle(_ tag: String, adding: Bool, perEntryTags: [Location: [String]], origin: FileOrigin) {
        guard canEdit(origin) else { return }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = adding ? String(localized: "添加标签“\(trimmed)”") : String(localized: "移除标签“\(trimmed)”")

        if origin.items.count == 1 {
            let loc = origin.items[0].location
            let updated = Self.toggled(perEntryTags[loc] ?? [], tag: trimmed, adding: adding)
            enqueueSingle(entry: origin.items[0], fields: XMPFields(tags: updated), title: title, origin: origin)
            return
        }

        var groups: [[String]: [Location]] = [:], optimistic: [Location: XMPFields] = [:]
        for entry in origin.items {
            let updated = Self.toggled(perEntryTags[entry.location] ?? [], tag: trimmed, adding: adding)
            groups[updated, default: []].append(entry.location)
            optimistic[entry.location] = XMPFields(tags: updated)
        }
        let ops = groups.map { FileOperation.setMetadata($0.value, XMPFields(tags: $0.key)) }
        let operation: FileOperation = ops.count == 1 ? ops[0] : .sequence(ops)
        Task { await executeBatch(operation: operation, targets: origin.items.map(\.location), optimisticFields: optimistic, title: title, origin: origin) }
    }

    private func enqueueSingle(entry: Entry, fields: XMPFields, title: String, origin: FileOrigin) {
        let loc = entry.location
        let previous = queuedSingles[loc]?.previous ?? overlays[loc]
        failures.removeValue(forKey: loc)
        applyOptimistic(fields, to: loc, isWriting: true)
        notifyObservers()
        showWritingToast(fields: fields, in: origin.window)

        var merged = queuedSingles[loc]?.fields ?? XMPFields()
        if let r = fields.rating { merged.rating = r }
        if let t = fields.tags { merged.tags = t }
        queuedSingles[loc] = PendingSingle(fields: merged, origin: origin, title: title, previous: previous)

        guard !activeLocations.contains(loc) else { return }
        debounceTasks[loc]?.cancel()
        debounceTasks[loc] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.debounceTasks.removeValue(forKey: loc)
            await self.drainSingle(loc)
        }
    }

    private func drainSingle(_ loc: Location) async {
        guard !activeLocations.contains(loc) else { return }
        activeLocations.insert(loc)
        defer { activeLocations.remove(loc) }

        while let next = queuedSingles.removeValue(forKey: loc) {
            guard let fileOps = app?.fileOps else {
                overlays.removeValue(forKey: loc); notifyObservers(); return
            }
            let result = await fileOps.perform(.setMetadata([loc], next.fields), title: next.title, origin: next.origin, reportsFailures: false)
            if queuedSingles[loc] != nil { continue }
            handleCompletion(result: result, targets: [loc], fieldsByLocation: [loc: next.fields], previousOverlays: [loc: next.previous], title: next.title, origin: next.origin)
        }
    }

    private func executeBatch(operation: FileOperation, targets: [Location], optimisticFields: [Location: XMPFields], title: String, origin: FileOrigin) async {
        guard let fileOps = app?.fileOps else { return }
        let controller = targetController(for: origin)
        var previousOverlays: [Location: OptimisticOverlay?] = [:]
        for loc in targets {
            previousOverlays[loc] = overlays[loc]
            failures.removeValue(forKey: loc)
            if let fields = optimisticFields[loc] { applyOptimistic(fields, to: loc, isWriting: true) }
        }
        notifyObservers()

        if targets.count > 1 {
            controller?.viewer.showMetadataToast(text: String(localized: "正在\(title)（\(targets.count) 项）…"), isSpinning: true, autoHideAfter: nil)
        }
        let result = await fileOps.perform(operation, title: title, origin: origin, reportsFailures: false, immediateProgress: targets.count > 1)
        handleCompletion(result: result, targets: targets, fieldsByLocation: optimisticFields, previousOverlays: previousOverlays, title: title, origin: origin)
    }

    private func handleCompletion(
        result: FileOperationResult?, targets: [Location], fieldsByLocation: [Location: XMPFields],
        previousOverlays: [Location: OptimisticOverlay?], title: String, origin: FileOrigin
    ) {
        let controller = targetController(for: origin)
        guard let result else {
            targets.forEach { rollback($0, previous: previousOverlays[$0] ?? nil) }
            controller?.viewer.hideMetadataToast(); notifyObservers(); return
        }
        let failedMap = Dictionary(result.failures.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        let succeededLocs = Set(result.changes.compactMap { if case let .rewritten(entry, _, _) = $0 { entry.location } else { nil } })

        for loc in targets {
            if let failure = failedMap[loc] {
                rollback(loc, previous: previousOverlays[loc] ?? nil)
                if let retryFields = fieldsByLocation[loc], let entry = origin.items.first(where: { $0.location == loc }) {
                    failures[loc] = FailureRecord(reason: ErrorText.describe(failure.error)) { [weak self] in
                        self?.enqueueSingle(entry: entry, fields: retryFields, title: title, origin: FileOrigin(window: origin.window, items: [entry]))
                    }
                }
            } else if succeededLocs.contains(loc) {
                overlays[loc]?.isWriting = false
            } else {
                rollback(loc, previous: previousOverlays[loc] ?? nil)
            }
        }
        notifyObservers()

        if !result.failures.isEmpty {
            let bannerTitle = targets.count > result.failures.count
                ? String(localized: "\(title)：\(targets.count) 项中 \(result.failures.count) 项写入失败")
                : String(localized: "\(title)失败")
            let failedLocs = result.failures.map(\.location)
            let onRetry: (() -> Void)? = result.retry.map { op in
                { [weak self, weak controller] in
                    controller?.content.setFileOperationBanner(nil)
                    guard let self else { return }
                    let retryOrigin = FileOrigin(window: controller, items: origin.items.filter { failedLocs.contains($0.location) })
                    let retryFields = Dictionary(uniqueKeysWithValues: failedLocs.compactMap { loc in fieldsByLocation[loc].map { (loc, $0) } })
                    Task { await self.executeBatch(operation: op, targets: failedLocs, optimisticFields: retryFields, title: title, origin: retryOrigin) }
                }
            }
            controller?.content.setFileOperationBanner(FileOperationBanner(title: bannerTitle, failures: result.failures, onRetry: onRetry) { [weak controller] in
                controller?.content.setFileOperationBanner(nil)
            })
            controller?.viewer.hideMetadataToast()
        } else if !succeededLocs.isEmpty {
            if targets.count == 1, let fields = fieldsByLocation[targets[0]] {
                showDoneToast(fields: fields, in: controller)
            } else {
                controller?.viewer.showMetadataToast(text: String(localized: "已写入（\(succeededLocs.count) 项）"), isSpinning: false)
            }
        } else {
            controller?.viewer.hideMetadataToast()
        }
    }

    private func applyOptimistic(_ fields: XMPFields, to location: Location, isWriting: Bool) {
        var current = overlays[location] ?? OptimisticOverlay(rating: nil, tags: nil, isWriting: isWriting)
        if let r = fields.rating { current.rating = r }
        if let t = fields.tags { current.tags = t }
        current.isWriting = isWriting
        overlays[location] = current
    }

    private func rollback(_ location: Location, previous: OptimisticOverlay?) {
        if let previous, !previous.isWriting { overlays[location] = previous } else { overlays.removeValue(forKey: location) }
    }

    private func showWritingToast(fields: XMPFields, in controller: ReaderWindowController?) {
        let text = fields.rating.map { $0 == 0 ? String(localized: "正在清除评分…") : String(localized: "正在写入 \($0) 星…") } ?? String(localized: "正在写入标签…")
        controller?.viewer.showMetadataToast(text: text, isSpinning: true, autoHideAfter: nil)
    }

    private func showDoneToast(fields: XMPFields, in controller: ReaderWindowController?) {
        if let rating = fields.rating {
            controller?.viewer.showMetadataToast(stars: rating, text: String(localized: "已写入"), isSpinning: false)
        } else {
            controller?.viewer.showMetadataToast(text: String(localized: "已写入标签"), isSpinning: false)
        }
    }

    private func targetController(for origin: FileOrigin) -> ReaderWindowController? {
        if let window = origin.window, app?.controllers.contains(where: { $0 === window }) == true { return window }
        return app?.mainController ?? app?.controllers.first
    }

    // MARK: 标签弹窗与右键菜单

    func presentTagEditor(origin: FileOrigin, relativeTo anchor: NSView? = nil) {
        guard canEdit(origin) else { showUnwritableReason(for: origin.items, in: targetController(for: origin)); return }
        guard let controller = targetController(for: origin), let services = app?.services else { return }
        activePopover?.close()
        let editor = TagEditorPopover(entries: origin.items, services: services, writer: self, origin: origin)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        editor.onClose = { [weak popover] in popover?.performClose(nil) }
        activePopover = popover

        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            let host = controller.viewer
            let rect = NSRect(x: host.bounds.midX - 1, y: max(host.bounds.minY + 80, host.bounds.midY - 60), width: 2, height: 2)
            popover.show(relativeTo: rect, of: host, preferredEdge: .maxY)
        }
    }

    func registerContextMenuProviders(in provider: ContextMenuProvider) {
        provider.register(dynamic: .rating) { [weak self] target in
            self?.ratingMenuItem(for: target.origin)
        }
        provider.register(command: .metadataTagsEdit) { [weak self] target in
            self?.editTagsMenuItem(for: target.origin)
        }
    }

    func ratingMenuItem(for origin: FileOrigin) -> NSMenuItem {
        let enabled = canEdit(origin)
        let ratingSub = NSMenu(title: String(localized: "评分"))
        ratingSub.autoenablesItems = false
        let items: [(CommandID, Int, String)] = [
            (.ratingSet0, 0, String(localized: "清除评分")), (.ratingSet1, 1, String(localized: "1 星")),
            (.ratingSet2, 2, String(localized: "2 星")), (.ratingSet3, 3, String(localized: "3 星")),
            (.ratingSet4, 4, String(localized: "4 星")), (.ratingSet5, 5, String(localized: "5 星")),
        ]
        for (id, value, title) in items {
            let item = MenuAction(title) { [weak self] in self?.setRating(value, origin: origin) }.item
            item.isEnabled = enabled
            applyShortcut(id, to: item)
            ratingSub.addItem(item)
        }
        let ratingHolder = NSMenuItem(title: String(localized: "评分"), action: nil, keyEquivalent: "")
        ratingHolder.submenu = ratingSub; ratingHolder.isEnabled = enabled
        return ratingHolder
    }

    func editTagsMenuItem(for origin: FileOrigin) -> NSMenuItem {
        let enabled = canEdit(origin)
        let tagItem = MenuAction(String(localized: "编辑标签…")) { [weak self] in self?.presentTagEditor(origin: origin) }.item
        tagItem.isEnabled = enabled
        applyShortcut(.metadataTagsEdit, to: tagItem)
        return tagItem
    }

    func contextMenuItems(for origin: FileOrigin) -> [NSMenuItem] {
        [ratingMenuItem(for: origin), editTagsMenuItem(for: origin)]
    }

    private func applyShortcut(_ id: CommandID, to item: NSMenuItem) {
        if let chord = app?.catalog.menuBinding(for: id)?.sequence.first, let eq = KeyMapping.menuKeyEquivalent(for: chord) {
            item.keyEquivalent = eq.key; item.keyEquivalentModifierMask = eq.mask
        }
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func toggled(_ tags: [String], tag: String, adding: Bool) -> [String] {
        var next = tags
        if adding { if !next.contains(tag) { next.append(tag) } } else { next.removeAll { $0 == tag } }
        return normalizeTags(next)
    }
}
