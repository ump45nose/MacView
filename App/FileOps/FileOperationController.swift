import AppKit
import Darwin
import MVCommands
import MVFoundation
import MVIO
import MVReading
import MVServices
import MVSettings
import Synchronization
import UniformTypeIdentifiers

/// 命令开始时取的快照：来源窗口和作用对象。
struct FileOrigin { weak var window: ReaderWindowController?; var items: [Entry] = [] }

@MainActor
private final class UndoStep: NSObject {
    var operation: FileOperation, title: String, origin: FileOrigin
    init(operation: FileOperation, title: String, origin: FileOrigin) {
        self.operation = operation; self.title = title; self.origin = origin
    }
}

/// 全 App 共用的文件操作控制器：先进先出队列、防重复提交、撤销与重做、进度、状态栏结果、错误条与永久删除确认。
@MainActor
final class FileOperationController {
    private struct QueueItem {
        var operation: FileOperation, title: String, origin: FileOrigin, locations: Set<Location>
        var reportsFailures: Bool, undoStep: UndoStep? = nil, isUndo: Bool? = nil
        var continuation: CheckedContinuation<FileOperationResult?, Never>? = nil
    }

    let undoManager = UndoManager()
    private(set) var fileSettings = FileOperationSettings.default
    private(set) var classifyDestinations: [Location] = []
    private weak var app: AppDelegate?, progressController: ReaderWindowController?
    private var queue: [QueueItem] = [], isExecuting = false, activeLocations: Set<Location> = []
    private var currentTask: Task<FileOperationResult, Never>?, latestProgress = FileProgress(), showingProgress = false
    private var refreshProgressDisplay: (() -> Void)?
    private var settingsTask: Task<Void, Never>?, changesTask: Task<Void, Never>?
    private var pasteboardLeases: [FileLease] = [], openWithLeases: [FileLease] = []
    private var activePromiseDelegates: [FilePromiseDelegate] = []
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.ump45nose.MacView.file-promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    var isBusy: Bool { isExecuting || !queue.isEmpty }
    init(app: AppDelegate) {
        self.app = app; undoManager.groupsByEvent = false
        observeSettings()
    }

    func perform(_ operation: FileOperation, title: String, origin: FileOrigin, reportsFailures: Bool = true) async -> FileOperationResult? {
        guard app?.services?.fileOperations != nil else { return nil }
        let locations = Self.locations(of: operation, origin: origin)
        if !locations.isDisjoint(with: activeLocations) {
            targetController(for: origin)?.content.statusBar.showMessage(String(localized: "这一项正在处理"))
            return nil
        }
        activeLocations.formUnion(locations)
        return await withCheckedContinuation { continuation in
            enqueue(QueueItem(operation: operation, title: title, origin: origin, locations: locations, reportsFailures: reportsFailures, continuation: continuation))
        }
    }

    func cancelCurrentOperation() { currentTask?.cancel() }

    private func enqueue(_ item: QueueItem) {
        queue.append(item); refreshProgressDisplay?()
        guard !isExecuting else { return }
        isExecuting = true
        Task { while !queue.isEmpty { await executeItem(queue.removeFirst()) }; isExecuting = false }
    }

    private func registerStep(_ step: UndoStep) {
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: step) { [weak self, step] _ in
            MainActor.assumeIsolated {
                guard let self, self.app?.services?.fileOperations != nil else { return }
                let isUndo = self.undoManager.isUndoing; self.registerStep(step)
                let locs = Self.locations(of: step.operation, origin: step.origin)
                self.activeLocations.formUnion(locs)
                self.enqueue(QueueItem(operation: step.operation, title: step.title, origin: step.origin, locations: locs, reportsFailures: true, undoStep: step, isUndo: isUndo))
            }
        }
        undoManager.setActionName(step.title)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func executeItem(_ item: QueueItem) async {
        guard let service = app?.services?.fileOperations else {
            activeLocations.subtract(item.locations); item.continuation?.resume(returning: nil); return
        }
        latestProgress = FileProgress(totalItems: max(1, item.locations.count))
        showingProgress = false; progressController = targetController(for: item.origin)
        refreshProgressDisplay = { [weak self] in
            guard let self, self.showingProgress else { return }
            let controller = self.progressController ?? self.targetController(for: item.origin)
            self.progressController = controller
            let (text, fraction) = self.progressSummary(title: item.title, operation: item.operation, progress: self.latestProgress)
            controller?.content.statusBar.showProgress(text, fraction: fraction) { [weak self] in self?.cancelCurrentOperation() }
        }
        let delayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.showingProgress = true; self.refreshProgressDisplay?()
        }
        let task = Task { [weak self] in
            await service.perform(item.operation) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestProgress = progress; if self.showingProgress { self.refreshProgressDisplay?() }
                }
            }
        }
        currentTask = task
        let result = await task.value
        delayTask.cancel(); currentTask = nil; refreshProgressDisplay = nil
        if showingProgress { progressController?.content.statusBar.hideProgress(); showingProgress = false }
        progressController = nil; activeLocations.subtract(item.locations)

        if let step = item.undoStep {
            if let nextInverse = result.inverse { step.operation = nextInverse }
            else if !result.failures.isEmpty { undoManager.removeAllActions(withTarget: step) }
        } else if let inverse = result.inverse {
            registerStep(UndoStep(operation: inverse, title: item.title, origin: item.origin))
        }
        handleResult(result, operation: item.operation, title: item.title, origin: item.origin, reportsFailures: item.reportsFailures, isUndo: item.isUndo)
        item.continuation?.resume(returning: result)
    }

    func handleResult(_ result: FileOperationResult, operation: FileOperation, title: String, origin: FileOrigin, reportsFailures: Bool = true, isUndo: Bool? = nil) {
        guard let controller = targetController(for: origin) else { return }
        var recycleLocations: [Location] = [], recycleReason: String?, otherFailures: [FileFailure] = []
        for failure in result.failures {
            if case let FileOpsError.recycleUnavailable(reason) = failure.error {
                recycleLocations.append(failure.location); if recycleReason == nil { recycleReason = reason }
            } else { otherFailures.append(failure) }
        }
        if !recycleLocations.isEmpty, let window = controller.window {
            let sheet = PermanentDeleteSheet(count: recycleLocations.count, volumeName: recycleLocations[0].root.displayName, reason: recycleReason ?? String(localized: "没有写入权限")) { [weak self] confirmed in
                guard confirmed, let self else { return }
                let deleteTitle = recycleLocations.count == 1 ? String(localized: "永久删除“\(recycleLocations[0].name)”") : String(localized: "永久删除 \(recycleLocations.count) 项")
                Task { @MainActor in _ = await self.perform(.deletePermanently(recycleLocations), title: deleteTitle, origin: origin) }
            }
            window.beginSheet(sheet)
        }
        if !otherFailures.isEmpty {
            guard reportsFailures else { return }
            let total = result.changes.count + result.skipped.count + result.failures.count
            let bannerTitle = total > otherFailures.count
                ? String(localized: "\(title)：\(total) 项中 \(otherFailures.count) 项没有完成")
                : String(localized: "\(title)：\(otherFailures.count) 项没有完成")
            let onRetry: (() -> Void)? = result.retry.map { retry in
                { [weak self, weak controller] in
                    controller?.content.setFileOperationBanner(nil)
                    Task { @MainActor in _ = await self?.perform(retry, title: title, origin: origin) }
                }
            }
            controller.content.setFileOperationBanner(FileOperationBanner(title: bannerTitle, failures: otherFailures, onRetry: onRetry) { [weak controller] in
                controller?.content.setFileOperationBanner(nil)
            })
            if !result.changes.isEmpty {
                controller.content.statusBar.showMessage(String(localized: "\(title)：\(result.changes.count) 项完成，\(otherFailures.count) 项没有完成"))
            }
            return
        }
        if recycleLocations.isEmpty, (!result.changes.isEmpty || !result.skipped.isEmpty) {
            controller.content.statusBar.showMessage(Self.completionMessage(operation: operation, title: title, result: result, isUndo: isUndo))
        }
    }

    func presentStartupRecovery() async {
        guard let report = await app?.services?.interruptedTransfersReport(),
              report.completed > 0 || report.pending > 0 || report.failed > 0,
              let controller = targetController(for: FileOrigin()) else { return }
        var messages: [String] = []
        if report.completed > 0 { messages.append(String(localized: "上次中断的 \(report.completed) 次移动已完成")) }
        if report.pending > 0 { messages.append(String(localized: "\(report.pending) 次等目标卷连接后，下次启动时继续")) }
        if !messages.isEmpty { controller.content.statusBar.showMessage(messages.joined(separator: "；")) }
        if report.failed > 0 {
            controller.content.setFileOperationBanner(FileOperationBanner(title: String(localized: "上次中断的移动有 \(report.failed) 项没有完成"), failures: [], onRetry: nil) { [weak controller] in
                controller?.content.setFileOperationBanner(nil)
            })
        }
    }

    private func targetController(for origin: FileOrigin) -> ReaderWindowController? {
        if let window = origin.window, app?.controllers.contains(where: { $0 === window }) == true { return window }
        return app?.mainController ?? app?.controllers.first
    }

    private func progressSummary(title: String, operation: FileOperation, progress p: FileProgress) -> (String, Double) {
        func usesBytes(_ op: FileOperation) -> Bool {
            switch op {
            case let .transfer(_, _, mode, _): mode == .copy || (p.completedBytes > 0 && p.completedItems == 0)
            case let .sequence(ops): ops.contains(where: usesBytes)
            default: p.completedBytes > 0 && p.completedItems == 0
            }
        }
        let showsBytes = p.totalBytes > 0 && usesBytes(operation)
        let fraction = showsBytes ? Double(p.completedBytes) / Double(p.totalBytes) : (p.totalItems > 0 ? Double(p.completedItems) / Double(p.totalItems) : 0)
        var text = p.totalItems > 0 ? String(localized: "\(title) \(p.completedItems) / \(p.totalItems) 项") : title
        if showsBytes { text += " · \(ByteCountFormatter.string(fromByteCount: p.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .file))" }
        if !queue.isEmpty { text += String(localized: " · 等 \(queue.count) 项操作") }
        return (text, fraction)
    }

    private static func completionMessage(operation: FileOperation, title: String, result: FileOperationResult, isUndo: Bool?) -> String {
        if let isUndo { return isUndo ? String(localized: "已撤销\(title)") : String(localized: "已重做\(title)") }
        let skip = result.skipped.isEmpty ? "" : String(localized: "，跳过 \(result.skipped.count) 项（目标里已有同名项）")
        if case let .transfer(sources, folder, mode, _) = operation {
            let verb = mode == .move ? String(localized: "已移动") : String(localized: "已复制")
            return result.changes.count == 1 && sources.count == 1 && result.skipped.isEmpty
                ? "\(verb) \(sources[0].name) → \(folder.name)"
                : String(localized: "\(verb) \(result.changes.count) 项到“\(folder.name)”") + skip
        }
        return String(localized: "已\(title)") + skip
    }

    private static func locations(of operation: FileOperation, origin: FileOrigin) -> Set<Location> {
        var set = Set(origin.items.map(\.location))
        func collect(_ op: FileOperation) {
            switch op {
            case let .delete(locs), let .deletePermanently(locs), let .transfer(locs, _, _, _): set.formUnion(locs)
            case let .rename(loc, _), let .removeEmptyDirectory(loc): set.insert(loc)
            case let .relocate(items): set.formUnion(items.map(\.source))
            case .makeDirectory: break
            case let .sequence(ops): ops.forEach(collect)
            }
        }
        collect(operation); return set
    }

    // MARK: 设置与分类目标

    private func observeSettings() {
        guard let services = app?.services else { return }
        settingsTask = Task { [weak self] in
            await self?.reloadSettings()
            for await change in services.settings.changes() {
                guard !Task.isCancelled, let self else { return }
                if change == .global { await self.reloadSettings() }
            }
        }
        changesTask = Task { [weak self] in
            for await _ in services.appliedFileChanges() {
                guard !Task.isCancelled, let self else { return }
                await self.reloadSettings()
            }
        }
    }

    func reloadSettings() async {
        guard let services = app?.services else { return }
        let ops = await services.settings.global().fileOperations
        fileSettings = ops
        var destinations: [Location] = []
        for target in ops.classifyTargets {
            destinations.append(target.location)
            guard target.listsSubfolders, let provider = try? services.sources.provider(for: target.location) else { continue }
            var subfolders: [Entry] = []
            try? await { for try await batch in provider.children(of: target.location, priority: .near) { subfolders.append(contentsOf: batch.filter { $0.kind == .directory }) } }()
            destinations.append(contentsOf: ReadingOrder.sorted(subfolders, by: SortSpec(key: .name)).map(\.location))
        }
        classifyDestinations = destinations
    }

    // MARK: 命令与菜单

    func canRead(_ origin: FileOrigin) -> Bool { app?.services?.fileOperations != nil && !origin.items.isEmpty }
    func canModify(_ origin: FileOrigin) -> Bool { canRead(origin) && origin.items.allSatisfy { $0.location.layers.count == 1 } }
    func canRename(_ origin: FileOrigin) -> Bool { canModify(origin) && origin.items.count == 1 }

    func isNetworkVolume(_ location: Location) -> Bool {
        if case .network = location.root { return true }
        return (try? (app?.services?.sources as? FileSourceRegistry)?.fileSystem.isNetworkVolume(location)) == true
    }

    func deleteTitle(for origin: FileOrigin) -> String {
        if origin.items.contains(where: { $0.location.layers.count > 1 }) { return String(localized: "删除") }
        if let first = origin.items.first, isNetworkVolume(first.location) { return String(localized: "移到回收目录") }
        return String(localized: "移到废纸篓")
    }

    func delete(origin: FileOrigin) async {
        guard canModify(origin) else { return }
        let verb = deleteTitle(for: origin)
        let title = origin.items.count == 1 ? "\(verb)“\(origin.items[0].name)”" : String(localized: "\(verb) \(origin.items.count) 项")
        _ = await perform(.delete(origin.items.map(\.location)), title: title, origin: origin)
    }

    func presentRename(origin: FileOrigin) {
        guard canRename(origin), let window = targetController(for: origin)?.window, window.attachedSheet == nil else { return }
        let sheet = RenameSheet(entry: origin.items[0], origin: origin, fileOps: self)
        window.beginSheet(sheet); sheet.selectInitialRange()
    }

    func transfer(origin: FileOrigin, into destination: Location, mode: TransferMode) async {
        guard canModify(origin) else { return }
        let verb = mode == .move ? String(localized: "移动") : String(localized: "复制")
        let title = origin.items.count == 1 ? "\(verb)“\(origin.items[0].name)”" : String(localized: "\(verb) \(origin.items.count) 项")
        _ = await perform(.transfer(origin.items.map(\.location), into: destination, mode: mode, conflict: fileSettings.nameConflict), title: title, origin: origin)
    }

    func chooseFolderAndTransfer(origin: FileOrigin, mode: TransferMode) {
        guard canModify(origin), let window = targetController(for: origin)?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = mode == .move ? String(localized: "移动") : String(localized: "复制")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, let services = self.app?.services else { return }
            Task { @MainActor in
                if let location = try? await services.sources.location(for: url) { await self.transfer(origin: origin, into: location, mode: mode) }
            }
        }
    }

    private func resolveLeases(for locations: [Location], in services: CoreServices) async throws -> [FileLease] {
        var leases: [FileLease] = []
        for loc in locations { leases.append(try await services.sources.provider(for: loc).fileLease(for: loc)) }
        return leases
    }

    func copyItems(origin: FileOrigin) async {
        guard canRead(origin), let services = app?.services else { return }
        do {
            let leases = try await resolveLeases(for: origin.items.map(\.location), in: services)
            var imagePayload: (Data, NSPasteboard.PasteboardType)?
            if origin.items.count == 1, origin.items[0].kind == .image {
                let item = origin.items[0], handle = try await services.sources.provider(for: item.location).open(item.location)
                let data = try await handle.read(0..<handle.identity.size, priority: .visible, group: nil)
                imagePayload = (data, NSPasteboard.PasteboardType(Self.contentType(for: item).identifier))
            }
            pasteboardLeases = leases
            let pb = NSPasteboard.general; pb.clearContents()
            pb.writeObjects(leases.map { $0.url as NSURL })
            if let (data, pbType) = imagePayload { pb.setData(data, forType: pbType) }
        } catch { targetController(for: origin)?.content.statusBar.showMessage(ErrorText.describe(error)) }
    }

    func copyPaths(origin: FileOrigin) async {
        guard canRead(origin), let services = app?.services else { return }
        do {
            let leases = try await resolveLeases(for: origin.items.map { Self.outerFileLocation(of: $0.location) }, in: services)
            let pb = NSPasteboard.general; pb.clearContents()
            pb.setString(leases.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n"), forType: .string)
        } catch { targetController(for: origin)?.content.statusBar.showMessage(ErrorText.describe(error)) }
    }

    func revealInFinder(origin: FileOrigin) async {
        guard canRead(origin), let services = app?.services else { return }
        do {
            let leases = try await resolveLeases(for: origin.items.map { Self.outerFileLocation(of: $0.location) }, in: services)
            NSWorkspace.shared.activateFileViewerSelecting(leases.map(\.url))
        } catch { targetController(for: origin)?.content.statusBar.showMessage(ErrorText.describe(error)) }
    }

    static func outerFileLocation(of location: Location) -> Location {
        location.layers.count > 1 ? Location(root: location.root, layers: [location.layers[0]]) : location
    }

    static func contentType(for entry: Entry) -> UTType {
        if entry.kind == .directory { return .folder }
        let ext = (entry.name as NSString).pathExtension
        return (!ext.isEmpty ? UTType(filenameExtension: ext) : nil) ?? .data
    }

    static func applicationsForOpening(_ entries: [Entry]) -> (defaultApp: URL?, others: [URL]) {
        guard let first = entries.first else { return (nil, []) }
        let type = contentType(for: first), ws = NSWorkspace.shared, selfURL = Bundle.main.bundleURL.standardizedFileURL
        let rawDefault = ws.urlForApplication(toOpen: type)
        let defaultApp = rawDefault?.standardizedFileURL == selfURL ? nil : rawDefault
        var seen: Set<URL> = [selfURL]
        if let defaultApp { seen.insert(defaultApp.standardizedFileURL) }
        return (defaultApp, ws.urlsForApplications(toOpen: type).filter { seen.insert($0.standardizedFileURL).inserted })
    }

    func openWithApplication(_ appURL: URL, origin: FileOrigin) {
        guard canRead(origin), let services = app?.services else { return }
        Task { @MainActor in
            do {
                let leases = try await resolveLeases(for: origin.items.map(\.location), in: services)
                openWithLeases.append(contentsOf: leases)
                _ = try await NSWorkspace.shared.open(leases.map(\.url), withApplicationAt: appURL, configuration: .init())
            } catch { targetController(for: origin)?.content.statusBar.showMessage(ErrorText.describe(error)) }
        }
    }

    func chooseApplicationAndOpen(origin: FileOrigin) {
        guard canRead(origin), let window = targetController(for: origin)?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.openWithApplication(url, origin: origin) }
        }
    }

    @discardableResult
    func populateOpenWithMenu(_ menu: NSMenu, origin: FileOrigin) -> Bool {
        menu.removeAllItems()
        guard canRead(origin) else { return false }
        let (defaultApp, others) = Self.applicationsForOpening(origin.items)
        func appItem(_ url: URL, isDefault: Bool) -> NSMenuItem {
            let name = url.deletingPathExtension().lastPathComponent
            let item = MenuAction(isDefault ? String(localized: "\(name)（默认）") : name) { [weak self] in self?.openWithApplication(url, origin: origin) }.item
            let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 16, height: 16); item.image = icon
            return item
        }
        if let defaultApp {
            menu.addItem(appItem(defaultApp, isDefault: true))
            if !others.isEmpty { menu.addItem(.separator()) }
        }
        others.forEach { menu.addItem(appItem($0, isDefault: false)) }
        if defaultApp != nil || !others.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction(String(localized: "其他…")) { [weak self] in self?.chooseApplicationAndOpen(origin: origin) }.item)
        return true
    }

    @discardableResult
    func populateTransferMenu(_ menu: NSMenu, origin: FileOrigin, mode: TransferMode) -> Bool {
        menu.removeAllItems()
        guard canModify(origin) else { return false }
        for (index, destination) in classifyDestinations.enumerated() {
            let prefix = index < 9 ? "\(index + 1)  " : (index == 9 ? "0  " : "")
            menu.addItem(MenuAction(prefix + destination.name) { [weak self] in
                Task { @MainActor in await self?.transfer(origin: origin, into: destination, mode: mode) }
            }.item)
        }
        if !classifyDestinations.isEmpty { menu.addItem(.separator()) }
        menu.addItem(MenuAction(String(localized: "选择文件夹…")) { [weak self] in self?.chooseFolderAndTransfer(origin: origin, mode: mode) }.item)
        return true
    }

    func contextMenu(for origin: FileOrigin) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; let catalog = app?.catalog
        func cmdItem(_ id: CommandID, title: String? = nil, enabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
            let item = MenuAction(title ?? catalog?.title(of: id) ?? id.rawValue, action: action).item
            item.isEnabled = enabled
            if let chord = catalog?.menuBinding(for: id)?.sequence.first, let eq = KeyMapping.menuKeyEquivalent(for: chord) {
                item.keyEquivalent = eq.key; item.keyEquivalentModifierMask = eq.mask
            }
            return item
        }
        func subItem(_ title: String, enabled: Bool, build: (NSMenu) -> Void) -> NSMenuItem {
            let sub = NSMenu(title: title); if enabled { build(sub) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: ""); holder.submenu = sub; holder.isEnabled = enabled
            return holder
        }
        let readable = canRead(origin), modifiable = canModify(origin)
        menu.addItem(cmdItem(.fileCopy, enabled: readable) { [weak self] in Task { await self?.copyItems(origin: origin) } })
        menu.addItem(cmdItem(.fileCopyPath, enabled: readable) { [weak self] in Task { await self?.copyPaths(origin: origin) } })
        menu.addItem(cmdItem(.fileReveal, enabled: readable) { [weak self] in Task { await self?.revealInFinder(origin: origin) } })
        menu.addItem(subItem(String(localized: "用指定应用打开"), enabled: readable) { _ = populateOpenWithMenu($0, origin: origin) })
        menu.addItem(.separator())
        menu.addItem(subItem(String(localized: "移动到"), enabled: modifiable) { _ = populateTransferMenu($0, origin: origin, mode: .move) })
        menu.addItem(subItem(String(localized: "复制到"), enabled: modifiable) { _ = populateTransferMenu($0, origin: origin, mode: .copy) })
        menu.addItem(cmdItem(.fileRename, title: String(localized: "重命名…"), enabled: canRename(origin)) { [weak self] in self?.presentRename(origin: origin) })
        menu.addItem(cmdItem(.fileDelete, title: deleteTitle(for: origin), enabled: modifiable) { [weak self] in Task { await self?.delete(origin: origin) } })
        return menu
    }

    // MARK: 拖出

    func pasteboardWriter(forItemAt index: Int, in collectionView: CollectionView) -> (any NSPasteboardWriting)? {
        guard let panel = collectionPanel(for: collectionView), let entry = panel.entries(at: [index]).first else { return nil }
        return pasteboardWriter(for: entry)
    }

    func pasteboardWriter(for entry: Entry) -> (any NSPasteboardWriting)? {
        guard let services = app?.services, services.fileOperations != nil else { return nil }
        if entry.location.layers.count == 1 { return Self.fileURL(for: entry).map { $0 as NSURL } }
        let delegate = FilePromiseDelegate(entry: entry, sources: services.sources, queue: promiseQueue)
        let provider = NSFilePromiseProvider(fileType: Self.contentType(for: entry).identifier, delegate: delegate)
        provider.userInfo = delegate; activePromiseDelegates.append(delegate)
        return provider
    }

    func dragSessionEnded(operation: NSDragOperation) {
        if operation == [] { activePromiseDelegates.forEach { $0.releaseLease() } }
        activePromiseDelegates.removeAll()
    }

    private func collectionPanel(for collectionView: CollectionView) -> CollectionPanel? {
        guard let app else { return nil }
        let panels = app.controllers.flatMap { $0.dock.panels.values } + (app.dock?.floatingWindows.values.map(\.panel) ?? [])
        for case let panel as CollectionPanel in panels where panel.collection === collectionView { return panel }
        return nil
    }

    static func fileURL(for entry: Entry) -> URL? {
        guard entry.location.layers.count == 1, let components = entry.location.layers.first else { return nil }
        let path: String
        switch entry.location.root {
        case .local: path = "/" + components.joined(separator: "/")
        case .network:
            guard let mount = mountPoint(for: entry.location.root) else { return nil }
            let base = mount == "/" ? "" : mount
            path = components.isEmpty && !base.isEmpty ? base : base + "/" + components.joined(separator: "/")
        case .plugin: return nil
        }
        return URL(filePath: path, directoryHint: entry.kind == .directory ? .isDirectory : .notDirectory)
    }

    private static func mountPoint(for root: Location.Root) -> String? {
        guard case let .network(scheme, host, share) = root else { return nil }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        var buffer = Array(repeating: Darwin.statfs(), count: Int(count) + 4)
        let filled = buffer.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT) }
        guard filled > 0 else { return nil }
        for var info in buffer.prefix(Int(filled)) {
            let fs = withUnsafeBytes(of: &info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let src = withUnsafeBytes(of: &info.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let mnt = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if scheme == "smb", fs == "smbfs", (src.removingPercentEncoding ?? src).lowercased().hasSuffix("/\(host)/\(share)".lowercased()) { return mnt }
            if scheme == "nfs", fs == "nfs", src.lowercased().hasPrefix("\(host):".lowercased()), src.hasSuffix(share) { return mnt }
        }
        return nil
    }
}

/// 压缩包内条目的拖出文件承诺：放下时在后台操作队列上经 `fileLease` 解出并复制到目标 URL，完成或取消时释放租约。
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private struct State { var lease: FileLease?; var task: Task<Void, Never>? }
    let entry: Entry
    private let sources: any SourceRegistry, queue: OperationQueue, state = Mutex(State())
    var hasActiveLease: Bool { state.withLock { $0.lease != nil } }

    init(entry: Entry, sources: any SourceRegistry, queue: OperationQueue) {
        self.entry = entry; self.sources = sources; self.queue = queue
    }
    deinit { releaseLease() }

    func releaseLease() {
        let task = state.withLock { state -> Task<Void, Never>? in
            defer { state.task = nil; state.lease = nil }
            return state.task
        }
        task?.cancel()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let entry = self.entry, sources = self.sources, semaphore = DispatchSemaphore(value: 0)
        let resultBox = Mutex<Result<FileLease, any Error>?>(nil)
        let task = Task(priority: .userInitiated) { [weak self] in
            defer { semaphore.signal() }
            do {
                let lease = try await sources.provider(for: entry.location).fileLease(for: entry.location)
                self?.state.withLock { $0.lease = lease }
                resultBox.withLock { $0 = .success(lease) }
            } catch { resultBox.withLock { $0 = .failure(error) } }
        }
        state.withLock { $0.task = task }
        semaphore.wait()
        defer { state.withLock { $0.lease = nil; $0.task = nil } }
        do {
            guard let result = resultBox.withLock({ $0 }) else { throw CancellationError() }
            let lease = try result.get()
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: lease.url, to: url)
            withExtendedLifetime(lease) {}
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}
