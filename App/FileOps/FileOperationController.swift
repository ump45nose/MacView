import AppKit
import MVFoundation
import MVServices

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
    private weak var app: AppDelegate?, progressController: ReaderWindowController?
    private var queue: [QueueItem] = [], isExecuting = false, activeLocations: Set<Location> = []
    private var currentTask: Task<FileOperationResult, Never>?, latestProgress = FileProgress(), showingProgress = false
    private var refreshProgressDisplay: (() -> Void)?

    var isBusy: Bool { isExecuting || !queue.isEmpty }
    init(app: AppDelegate) { self.app = app; undoManager.groupsByEvent = false }

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
}
