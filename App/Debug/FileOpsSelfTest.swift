#if DEBUG
import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVReading
import MVServices
import MVSettings

/// 文件操作控制器、撤销重做、进度取消、错误条、永久删除确认与启动恢复的自检（`-MVFileOpsSelfTest YES`）。
/// 网络卷验收（`~/MacViewBench/fileops-a`，用独立的 support/cache/layout 目录）：先 `net-kill`（S2、S5、S6，最后在 S7 的跨卷移动中自杀），再用同一 support 目录 `net-verify`（S7 恢复、S12、S9、清理）。
@MainActor
final class FileOpsSelfTest {
    static let launchKey = "MVFileOpsSelfTest"
    private static let networkModes: Set = ["net-kill", "net-verify", "net-skip", "net-recovery-kill", "net-recovery-verify", "net-pending"]
    static var mode: String { UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
    static var isRequested: Bool { !mode.isEmpty && !["0", "no", "false"].contains(mode) }
    private static var recoveryRootURL: URL?, recoverySourceURL: URL?, recoveryTargetURL: URL?
    private let app: AppDelegate, log = SelfTestLog(), fm = FileManager.default
    private let temporary = TestPresentation.scratchDirectory("fileops")
    private var targetWindow: NSWindow?

    static func prepareStartupRecoveryIfNeeded(supportDirectory: URL) async {
        guard isRequested, !networkModes.contains(mode), recoveryRootURL == nil else { return }
        let root = TestPresentation.scratchDirectory("fileops-recovery")
        let srcURL = root.appending(path: "recover-src.dat"), dstURL = root.appending(path: "recover-dst.dat"), tmpURL = root.appending(path: ".recover-dst.dat.macview-part")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let payload = Data("macview-startup-recovery-payload".utf8)
            try payload.write(to: srcURL); try payload.write(to: dstURL)
            let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
            let registry = FileSourceRegistry(scheduler: scheduler)
            let src = try await registry.location(for: srcURL), dst = try await registry.location(for: dstURL), tmp = try await registry.location(for: tmpURL)
            scheduler.shutdown()
            func encode(_ loc: Location) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(loc)) }
            let journal: [String: Any] = ["version": 1, "transfers": [["id": UUID().uuidString, "source": try encode(src), "target": try encode(dst), "temporary": try encode(tmp)]]]
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: journal).write(to: supportDirectory.appending(path: "transfers.json"))
            recoveryRootURL = root; recoverySourceURL = srcURL; recoveryTargetURL = dstURL
        } catch { print("FAIL 构造启动恢复记录失败：\(error)") }
    }

    static func runIfRequested(app: AppDelegate) {
        guard isRequested else { return }
        UserDefaults.standard.register(defaults: ["NSAllowMultipleDrags": true])   // 只在本次运行生效，不写持久偏好
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            print("FAIL 文件操作自检总超时（240s）"); fflush(stdout); _Exit(2)
        }
        let test = FileOpsSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) { self.app = app }

    private func run() async {
        TestPresentation.activateIfAllowed()
        // 要求前台时等 App 真正进入前台：系统拒绝激活时表单按钮收不到合成点击，不在这种半激活状态下跑检查。
        if TestPresentation.activationAllowed {
            await until("App 进入前台") { NSApp.isActive }
            guard NSApp.isActive else { exit(log.summarize()) }
        }
        guard let services = app.services, let fileOps = app.fileOps, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "文件操作自检需要真实服务、控制器和窗口"); exit(log.summarize())
        }
        targetWindow = window; window.setContentSize(NSSize(width: 1200, height: 800))
        do {
            switch Self.mode {
            case "net-kill": try await runNetworkKill(controller: controller, window: window, services: services, fileOps: fileOps)
            case "net-verify": try await runNetworkVerify(controller: controller, window: window, services: services, fileOps: fileOps)
            case "net-skip": try await runNetworkSkip(controller: controller, window: window, services: services, fileOps: fileOps)
            case "net-recovery-kill": try await runNetworkRecoveryKill(controller: controller, services: services, fileOps: fileOps)
            case "net-recovery-verify": try await runNetworkRecoveryVerify(controller: controller)
            case "net-pending": await runNetworkPending(controller: controller, services: services)
            case "focus": try await runFocusChecks(controller: controller, window: window, services: services, fileOps: fileOps)
            default: try await runChecks(controller: controller, window: window, services: services, fileOps: fileOps)
            }
        }
        catch { log.check(false, "文件操作自检异常：\(error)") }
        try? fm.removeItem(at: temporary)
        if let recoveryRoot = Self.recoveryRootURL { try? fm.removeItem(at: recoveryRoot) }
        await services.shutdown()
        exit(log.summarize())
    }

    private func runChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        let msg = controller.content.statusBar.message ?? ""
        log.check(msg == String(localized: "上次中断的 \(1) 次移动已完成"), "C2.5 启动恢复后状态栏显示完成提示：\(msg)")
        if let src = Self.recoverySourceURL, let dst = Self.recoveryTargetURL {
            log.check(!exists(src) && exists(dst), "C2.5 启动恢复完成了未完成的移动并清理源文件")
        }

        let (bookDir, targetDir) = try makePair("c21", "book", "target")
        for index in 1...3 { try writePNG(to: bookDir.appending(path: String(format: "%03d.png", index)), hue: CGFloat(index) * 0.2) }
        controller.open([bookDir])
        await until("打开测试书") { controller.session.book?.isEnumerated == true && controller.session.book?.pages.count == 3 }
        window.makeFirstResponder(controller.viewer); await settle()
        let book001 = bookDir.appending(path: "001.png"), target001 = targetDir.appending(path: "001.png")
        let targetLoc = try await services.sources.location(for: targetDir)
        guard let page1 = controller.session.book?.pages.first?.entry else { return log.check(false, "找不到第一页条目") }

        let moveRes = await fileOps.perform(.transfer([page1.location], into: targetLoc, mode: .move, conflict: .appendNumber), title: "移动“001.png”", origin: FileOrigin(window: controller, items: [page1]))
        log.check(moveRes?.changes.count == 1 && moveRes?.failures.isEmpty == true, "C2.1 移动 001.png 成功")
        log.check(!exists(book001) && exists(target001), "C2.1 移动后文件在目标目录")
        let undoTitle = editMenu(action: #selector(ReaderWindow.undo(_:))).title
        log.check(undoTitle.contains(String(localized: "撤销")) && undoTitle.contains("移动“001.png”"), "C2.1 撤销菜单标题写明操作和对象：\(undoTitle)")
        for round in 1...2 {
            await sendKey(kVK_ANSI_Z, [.command])
            await until("第 \(round) 轮 ⌘Z 完成") { !fileOps.isBusy && self.exists(book001) }
            log.check(exists(book001) && !exists(target001), "C2.1 第 \(round) 轮 ⌘Z 后文件系统回到操作前")
            let redoTitle = editMenu(action: #selector(ReaderWindow.redo(_:))).title
            log.check(redoTitle.contains(String(localized: "重做")) && redoTitle.contains("移动“001.png”"), "C2.1 第 \(round) 轮 ⌘Z 后重做菜单标题写明操作和对象：\(redoTitle)")
            await sendKey(kVK_ANSI_Z, [.command, .shift])
            await until("第 \(round) 轮 ⇧⌘Z 完成") { !fileOps.isBusy && self.exists(target001) }
            log.check(!exists(book001) && exists(target001), "C2.1 第 \(round) 轮 ⇧⌘Z 后文件系统回到操作后")
        }

        await sendKey(kVK_ANSI_G, [.command]); await settle()
        let editor = controller.content.statusBar.jumpField.currentEditor() as? NSTextView
        log.check(window.firstResponder is NSTextView && controller.windowWillReturnUndoManager(window) === controller.textUndoManager, "C2.2 焦点在文本框时返回文本 UndoManager")
        let initialText = editor?.string ?? ""
        if let editor, editor.shouldChangeText(in: NSRange(location: 0, length: (editor.string as NSString).length), replacementString: "3") {
            editor.replaceCharacters(in: NSRange(location: 0, length: (editor.string as NSString).length), with: "3"); editor.didChangeText()
        }
        await settle()
        log.check(editor?.string == "3" && editor?.undoManager !== fileOps.undoManager && editor?.undoManager?.canUndo == true, "C2.2 文本框输入后可撤销文本且不与文件操作共用 UndoManager")
        await sendKey(kVK_ANSI_Z, [.command]); await settle(); await sendKey(kVK_ANSI_Z, [.command]); await settle()
        log.check(editor?.string == initialText && exists(target001) && fileOps.undoManager.canUndo, "C2.2 文本框中按 ⌘Z 只撤销文本，文件操作未撤销")
        if NSApp.isActive { await sendKey(kVK_Escape) } else { editor?.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_Z, [.command])
        await until("恢复 001.png") { !fileOps.isBusy && self.exists(book001) }

        let (src23, dst23) = try makePair("c23", "src", "dst")
        var slowLocs: [Location] = []
        for index in 1...6 {
            let url = src23.appending(path: String(format: "slow-%02d.png", index))
            try writePNG(to: url, hue: CGFloat(index) * 0.12)
            slowLocs.append(try await services.sources.location(for: url))
        }
        let dst23Loc = try await services.sources.location(for: dst23)
        services.fileOperations?.setStepDelay(.milliseconds(350))
        let opTask = Task { await fileOps.perform(.transfer(slowLocs, into: dst23Loc, mode: .move, conflict: .appendNumber), title: "移动 6 项", origin: FileOrigin(window: controller)) }
        await until("超过 1 秒后状态栏显示进度") { controller.content.statusBar.isShowingProgress }
        let progressText = controller.content.statusBar.progressText ?? ""
        log.check(controller.content.statusBar.isShowingProgress && progressText.contains("移动 6 项"), "C2.3 超过 1 秒的操作在状态栏显示进度：\(progressText)")
        log.snapshot(window, "fileops-progress")
        await click(controller.content.statusBar.cancelProgressButton, in: window)
        let cancelRes = await opTask.value
        services.fileOperations?.setStepDelay(nil); await settle()
        let doneCount = cancelRes?.changes.count ?? 0
        let dstItems = (try? fm.contentsOfDirectory(atPath: dst23.path)) ?? [], srcItems = (try? fm.contentsOfDirectory(atPath: src23.path)) ?? []
        log.check(!controller.content.statusBar.isShowingProgress, "C2.3 取消后状态栏收起进度")
        log.check(doneCount >= 1 && doneCount < 6 && dstItems.count == doneCount && srcItems.count == 6 - doneCount, "C2.3 取消后已完成 \(doneCount) 项保留，未完成留在源目录")
        log.check(!(dstItems + srcItems).contains { $0.contains(".macview-part") }, "C2.3 取消后没有残留临时项")
        await sendKey(kVK_ANSI_Z, [.command])
        await until("取消后的已完成项撤销") { !fileOps.isBusy && ((try? self.fm.contentsOfDirectory(atPath: src23.path).count) == 6) }
        log.check((try? fm.contentsOfDirectory(atPath: src23.path).count) == 6 && (try? fm.contentsOfDirectory(atPath: dst23.path).count) == 0, "C2.3 取消后已完成的项可撤销回到原位")

        let (src24, dst24) = try makePair("c24", "src", "dst")
        let okURL = src24.appending(path: "ok.png"), missingURL = src24.appending(path: "missing.png")
        try writePNG(to: okURL, hue: 0.3)
        let src24Loc = try await services.sources.location(for: src24), dst24Loc = try await services.sources.location(for: dst24)
        let failRes = await fileOps.perform(.transfer([src24Loc.appending("ok.png"), src24Loc.appending("missing.png")], into: dst24Loc, mode: .move, conflict: .appendNumber), title: "移动到“dst”", origin: FileOrigin(window: controller))
        log.check(failRes?.changes.count == 1 && failRes?.failures.count == 1, "C2.4 部分失败返回 1 项完成、1 项失败")
        guard let banner = controller.content.fileOperationBanner, let retryButton = banner.retryButton else { return log.check(false, "C2.4 失败后未显示错误条或重试按钮") }
        let bannerText = collectText(in: banner)
        let expectedBanner = String(localized: "\("移动到“dst”")：\(2) 项中 \(1) 项没有完成")
        log.check(bannerText.contains("missing.png") && bannerText.contains(expectedBanner), "C2.4 错误条列出失败文件名与原因：\(bannerText)")
        log.snapshot(window, "fileops-banner")
        try writePNG(to: missingURL, hue: 0.6)
        await click(retryButton, in: window)
        await until("重试失败项完成") { !fileOps.isBusy && self.exists(dst24.appending(path: "missing.png")) }
        log.check(controller.content.fileOperationBanner == nil && exists(dst24.appending(path: "ok.png")) && exists(dst24.appending(path: "missing.png")), "C2.4 点击“重试”只重做失败项并收起错误条")
        _ = await fileOps.perform(.transfer([src24Loc.appending("ghost.png")], into: dst24Loc, mode: .move, conflict: .appendNumber), title: "移动到“dst”", origin: FileOrigin(window: controller))
        guard let secondBanner = controller.content.fileOperationBanner else { return log.check(false, "C2.4 第二次失败未显示错误条") }
        await click(secondBanner.closeButton, in: window); await settle()
        log.check(controller.content.fileOperationBanner == nil, "C2.4 点击关闭后错误条消失")

        let (src24b, dst24b) = try makePair("c24b", "src", "dst")
        let fileURL = src24b.appending(path: "occupied.png"), movedURL = dst24b.appending(path: "occupied.png")
        try writePNG(to: fileURL, hue: 0.5)
        let originalBytes = try Data(contentsOf: fileURL)
        let fileLoc = try await services.sources.location(for: fileURL), dst24bLoc = try await services.sources.location(for: dst24b)
        _ = await fileOps.perform(.transfer([fileLoc], into: dst24bLoc, mode: .move, conflict: .appendNumber), title: "移动“occupied.png”", origin: FileOrigin(window: controller))
        let occupantBytes = Data("occupant-do-not-overwrite".utf8)
        try occupantBytes.write(to: fileURL)
        await sendKey(kVK_ANSI_Z, [.command])
        await until("原位置被占用的撤销执行完") { !fileOps.isBusy && controller.content.fileOperationBanner != nil }
        log.check((try? Data(contentsOf: fileURL)) == occupantBytes && exists(movedURL), "C2.4b 撤销时原位置已被占用，报错且不覆盖已有文件")
        guard let conflictBanner = controller.content.fileOperationBanner, let conflictRetry = conflictBanner.retryButton else { return log.check(false, "C2.4b 撤销冲突未显示带重试的错误条") }
        try fm.removeItem(at: fileURL)
        await click(conflictRetry, in: window)
        await until("腾出位置后重试完成") { !fileOps.isBusy && self.exists(fileURL) && !self.exists(movedURL) }
        log.check((try? Data(contentsOf: fileURL)) == originalBytes && !exists(movedURL), "C2.4b 腾出位置后点错误条“重试”恢复原文件")

        services.fileOperations?.setStepDelay(.milliseconds(500))
        let firstTask = Task { await fileOps.perform(.transfer([fileLoc], into: dst24bLoc, mode: .move, conflict: .appendNumber), title: "移动“occupied.png”", origin: FileOrigin(window: controller)) }
        await until("队列进入执行中") { fileOps.isBusy }
        let duplicateResult = await fileOps.perform(.transfer([fileLoc], into: dst24bLoc, mode: .move, conflict: .appendNumber), title: "移动“occupied.png”", origin: FileOrigin(window: controller))
        let duplicateMessage = controller.content.statusBar.message ?? ""
        log.check(duplicateResult == nil && duplicateMessage == String(localized: "这一项正在处理"), "C2.4b 连续提交同一项只执行一次，状态栏提示“这一项正在处理”：\(duplicateMessage)")
        let undoEnabled = editMenu(action: #selector(ReaderWindow.undo(_:))).enabled, redoEnabled = editMenu(action: #selector(ReaderWindow.redo(_:))).enabled
        let cmdEnabled = app.dispatcher?.isEnabled(.editUndo, in: controller, scope: .viewer) ?? true
        log.check(!undoEnabled && !redoEnabled && !cmdEnabled, "C2.4b 队列里有操作时撤销和重做不可用")
        await sendKey(kVK_ANSI_Z, [.command])
        let busyUndoMessage = controller.content.statusBar.message ?? ""
        log.check(busyUndoMessage == String(localized: "文件操作完成后才能撤销"), "C2.4b 队列忙时按 ⌘Z 状态栏提示“文件操作完成后才能撤销”：\(busyUndoMessage)")
        _ = await firstTask.value; services.fileOperations?.setStepDelay(nil); await settle()

        let root24c = temporary.appending(path: "c24c", directoryHint: .isDirectory)
        try fm.createDirectory(at: root24c, withIntermediateDirectories: true)
        let tempFileURL = root24c.appending(path: "temp-permanent.png")
        try writePNG(to: tempFileURL, hue: 0.8)
        let tempLoc = try await services.sources.location(for: tempFileURL)
        let previousUndoName = fileOps.undoManager.undoActionName
        let injected = FileOperationResult(failures: [FileFailure(location: tempLoc, error: FileOpsError.recycleUnavailable(String(localized: "没有写入权限")))])
        fileOps.handleResult(injected, operation: .delete([tempLoc]), title: "删除“temp-permanent.png”", origin: FileOrigin(window: controller))
        await settle()
        guard let sheet1 = window.attachedSheet as? PermanentDeleteSheet else { return log.check(false, "C2.4c 遇到 recycleUnavailable 未弹出永久删除确认表单") }
        await until("永久删除取消表单获得焦点") { sheet1.isVisible && NSApp.keyWindow === sheet1 }
        guard sheet1.isVisible && NSApp.keyWindow === sheet1 else { return }
        log.snapshot(sheet1, "fileops-permanent-delete")
        await click(sheet1.cancelButton, in: sheet1)
        await until("取消表单收起") { window.attachedSheet == nil }
        log.check(exists(tempFileURL), "C2.4c 取消永久删除时文件保持原状")
        fileOps.handleResult(injected, operation: .delete([tempLoc]), title: "删除“temp-permanent.png”", origin: FileOrigin(window: controller))
        await settle()
        guard let sheet2 = window.attachedSheet as? PermanentDeleteSheet else { return log.check(false, "C2.4c 第二次未弹出永久删除确认表单") }
        await until("永久删除确认表单获得焦点") { sheet2.isVisible && NSApp.keyWindow === sheet2 }
        guard sheet2.isVisible && NSApp.keyWindow === sheet2 else { return }
        await click(sheet2.confirmButton, in: sheet2)
        await until("确认永久删除完成") { window.attachedSheet == nil && !fileOps.isBusy && !self.exists(tempFileURL) }
        log.check(!exists(tempFileURL) && fileOps.undoManager.undoActionName == previousUndoName, "C2.4c 确认后临时文件被永久删除且不进入撤销历史")
        try await runCommandChecks(controller: controller, window: window, services: services, fileOps: fileOps, bookDir: bookDir, targetDir: targetDir, targetLoc: targetLoc)
    }

    /// 单独复验首次永久删除表单及分类新目录的焦点与真实事件路径。
    private func runFocusChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        let (book, target) = try makePair("focus", "book", "target")
        let image = book.appending(path: "001.png"), disposable = book.appending(path: "disposable.png")
        try writePNG(to: image, hue: 0.2); try writePNG(to: disposable, hue: 0.5)
        let location = try await services.sources.location(for: disposable)
        let failure = FileOperationResult(failures: [FileFailure(location: location, error: FileOpsError.recycleUnavailable(String(localized: "没有写入权限")))])
        fileOps.handleResult(failure, operation: .delete([location]), title: "删除测试文件", origin: FileOrigin(window: controller))
        await until("首次永久删除表单获得焦点") { window.attachedSheet is PermanentDeleteSheet && NSApp.keyWindow === window.attachedSheet }
        guard let cancelSheet = window.attachedSheet as? PermanentDeleteSheet, NSApp.keyWindow === cancelSheet else { return }
        log.snapshot(cancelSheet, "focus-permanent-cancel")
        await click(cancelSheet.cancelButton, in: cancelSheet)
        await until("取消首次永久删除表单") { window.attachedSheet == nil }
        log.check(window.attachedSheet == nil && exists(disposable), "首次永久删除表单在前台接收取消事件，源文件保留")
        fileOps.handleResult(failure, operation: .delete([location]), title: "删除测试文件", origin: FileOrigin(window: controller))
        await until("再次永久删除表单获得焦点") { window.attachedSheet is PermanentDeleteSheet && NSApp.keyWindow === window.attachedSheet }
        guard let confirmSheet = window.attachedSheet as? PermanentDeleteSheet, NSApp.keyWindow === confirmSheet else { return }
        await click(confirmSheet.confirmButton, in: confirmSheet)
        await until("确认永久删除表单") { window.attachedSheet == nil && !fileOps.isBusy && !self.exists(disposable) }
        log.check(window.attachedSheet == nil && !exists(disposable), "再次表单接收确认事件并删除测试文件")

        guard let list = (controller.dock.panels[DockPanels.pageList] as? PageListPanel)?.collection else { return log.check(false, "找不到页面列表") }
        await openBook(book, pages: 1, controller: controller, listView: list)
        window.makeFirstResponder(controller.viewer); await sendKey(kVK_ANSI_3, [.command, .option])
        await until("分类面板打开") { controller.classifyPanel != nil }
        guard let panel = controller.classifyPanel else { return log.check(false, "分类面板未打开") }
        await panel.addTargetURLs([target], listsSubfolders: true)
        await until("分类目标显示") { panel.visibleRows.first?.location.name == target.lastPathComponent }
        panel.selectRow(at: panel.visibleRows.first?.location)
        await click(panel.panelView.newTargetButton, in: window)
        await until("分类输入框获得焦点") { panel.editingLocation != nil && window.firstResponder is NSTextView }
        guard panel.editingLocation != nil, window.firstResponder is NSTextView else { return }
        panel.panelView.listView.setInputText("新目录"); await sendKey(kVK_Return)
        let moved = target.appending(path: "新目录/001.png")
        await until("分类目标刷新") { !fileOps.isBusy && self.exists(moved) && panel.editingLocation == nil && panel.selectedLocation?.name == "新目录" && panel.visibleRows.contains(where: { $0.name == "新目录" }) }
        log.check(exists(moved) && !exists(image) && panel.selectedLocation?.name == "新目录", "分类输入框接收回车，新目录和移动结果已在面板显示")
        log.snapshot(window, "focus-classify")
    }

    private func runCommandChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController, bookDir: URL, targetDir: URL, targetLoc: Location) async throws {
        guard let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel, let listView = pageList.collection,
              let bookshelf = controller.dock.panels[DockPanels.bookshelf] as? BookshelfPanel, let shelfView = bookshelf.collection else {
            return log.check(false, "找不到页面列表或书架面板")
        }
        try? fm.removeItem(at: targetDir.appending(path: "001.png"))
        controller.open([bookDir])
        await until("重新打开测试书") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 3 && listView.items.count == 3 }
        let book001 = bookDir.appending(path: "001.png"), book002 = bookDir.appending(path: "002.png"), book099 = bookDir.appending(path: "099.png")
        let bytes001 = try Data(contentsOf: book001), bytes002 = try Data(contentsOf: book002)

        // C2.6：重命名冲突报错且不改文件，改新名成功并按排序更新，⌘Z 恢复原名。
        listView.selectRows(IndexSet(integer: 1)); window.makeFirstResponder(listView); await settle()
        fileOps.presentRename(origin: controller.fileOrigin()); await settle()
        guard let renameSheet = window.attachedSheet as? RenameSheet else { return log.check(false, "C2.6 未弹出重命名表单") }
        log.check(renameSheet.textField.currentEditor()?.selectedRange == NSRange(location: 0, length: 3) && !renameSheet.confirmButton.isEnabled, "C2.6 初始选中扩展名前主体且未改动时按钮不可用")
        log.snapshot(renameSheet, "fileops-rename-normal")
        renameSheet.setInputText("001.png")
        await click(renameSheet.confirmButton, in: renameSheet)
        await until("重名错误显示") { !renameSheet.errorRow.isHidden }
        let existingName = "001.png"
        log.check(renameSheet.errorLabel.stringValue == String(localized: "这个文件夹里已有“\(existingName)”。") && !renameSheet.confirmButton.isEnabled, "C2.6 重名显示表单内红字错误且按钮禁用：\(renameSheet.errorLabel.stringValue)")
        log.check((try? Data(contentsOf: book001)) == bytes001 && (try? Data(contentsOf: book002)) == bytes002 && controller.content.fileOperationBanner == nil, "C2.6 重名时两个文件不变且不弹顶部错误条")
        log.snapshot(renameSheet, "fileops-rename-conflict")
        renameSheet.setInputText("099.png")
        log.check(renameSheet.errorRow.isHidden && renameSheet.confirmButton.isEnabled, "C2.6 改动名字后红字消失且按钮可用")
        await click(renameSheet.confirmButton, in: renameSheet)
        await until("重命名 099.png 完成") { window.attachedSheet == nil && !fileOps.isBusy && self.exists(book099) && listView.items.map(\.name) == ["001.png", "003.png", "099.png"] }
        log.check(!exists(book002) && exists(book099) && listView.items.map(\.name) == ["001.png", "003.png", "099.png"], "C2.6 改成新名字成功且列表按排序更新：\(listView.items.map(\.name))")
        window.makeFirstResponder(controller.viewer); await sendKey(kVK_ANSI_Z, [.command])
        await until("⌘Z 恢复 002.png") { !fileOps.isBusy && self.exists(book002) && listView.items.map(\.name) == ["001.png", "002.png", "003.png"] }
        log.check(exists(book002) && !exists(book099) && listView.items.map(\.name) == ["001.png", "002.png", "003.png"], "C2.6 ⌘Z 恢复原名与列表顺序")

        // C2.7：复制图片写 URL + 原文件图片数据；复制路径得到完整 POSIX 路径；压缩包内复制路径得到压缩包路径。
        controller.session.go(.index(0)); window.makeFirstResponder(controller.viewer); await settle()
        await fileOps.copyItems(origin: controller.fileOrigin())
        let pb = NSPasteboard.general, copiedURLs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        log.check(copiedURLs?.first?.standardizedFileURL == book001.standardizedFileURL && pb.data(forType: .png) == bytes001, "C2.7 复制单张图片后剪贴板同时有文件 URL 与原图数据")
        await fileOps.copyPaths(origin: controller.fileOrigin())
        log.check(pb.string(forType: .string) == book001.path(percentEncoded: false), "C2.7 复制路径得到完整 POSIX 路径：\(pb.string(forType: .string) ?? "")")

        let zipURL = temporary.appending(path: "c27-archive.zip"), ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); ditto.arguments = ["-c", "-k", bookDir.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit(); let zipBytes = try Data(contentsOf: zipURL)
        controller.open([zipURL])
        await until("打开压缩包书") { controller.session.book?.location.name == "c27-archive.zip" && controller.session.book?.pages.count == 3 }
        window.makeFirstResponder(controller.viewer); await settle()
        await fileOps.copyPaths(origin: controller.fileOrigin())
        log.check(pb.string(forType: .string) == zipURL.path(percentEncoded: false), "C2.7 压缩包内的页复制路径得到压缩包路径：\(pb.string(forType: .string) ?? "")")

        // C2.8：压缩包书里删除、重命名、移动到、复制到灰掉，文件不变。
        let ctx = listView.contextMenu(forItemAt: 0)
        func itemEnabled(_ menu: NSMenu?, _ title: String) -> Bool? { menu?.items.first { $0.title == title }?.isEnabled }
        log.check(itemEnabled(ctx, String(localized: "删除")) == false && itemEnabled(ctx, String(localized: "重命名…")) == false && itemEnabled(ctx, String(localized: "移动到")) == false && itemEnabled(ctx, String(localized: "复制到")) == false, "C2.8 压缩包右键菜单中删除、重命名、移动到、复制到灰掉")
        log.check(itemEnabled(ctx, String(localized: "复制")) == true && itemEnabled(ctx, String(localized: "复制路径")) == true && itemEnabled(ctx, String(localized: "在 Finder 中显示")) == true && itemEnabled(ctx, String(localized: "用指定应用打开")) == true, "C2.8 压缩包右键菜单中复制、复制路径、在 Finder 中显示、用指定应用打开可用")
        await sendKey(kVK_Delete, [.command]); await settle()
        log.check((try? Data(contentsOf: zipURL)) == zipBytes && controller.session.book?.pages.count == 3, "C2.8 压缩包内按 ⌘⌫ 不修改文件")

        // C2.9：双页显示时，查看器里的文件命令只作用于主页。
        controller.open([bookDir])
        await until("回到文件夹书") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 3 }
        controller.session.update { $0.browseMode = .paged; $0.pageMode = .double; $0.firstPageSingle = false; $0.widePage = .asIs }
        await until("进入双页模式") { controller.session.frames.first?.elements.count == 2 }
        window.makeFirstResponder(controller.viewer); await settle(); let spreadOrigin = controller.fileOrigin()
        log.check(controller.session.frames.first?.elements.count == 2 && spreadOrigin.items.map(\.name) == ["001.png"], "C2.9 双页显示时查看器作用对象只取主页：\(spreadOrigin.items.map(\.name))")
        await fileOps.transfer(origin: spreadOrigin, into: targetLoc, mode: .move)
        log.check(!exists(book001) && exists(book002) && exists(targetDir.appending(path: "001.png")), "C2.9 双页下移动只移走主页 001.png，副页 002.png 保留")
        await sendKey(kVK_ANSI_Z, [.command]); await until("双页移动撤销恢复") { !fileOps.isBusy && self.exists(book001) }
        controller.session.update { $0.pageMode = .single }; await settle()

        // C2.10：“用指定应用打开”由文件类型得到，不读文件（不存在的路径也能列出应用）。
        let ghostEntry = Entry(identity: ContentIdentity(location: targetLoc.appending("ghost-nonexistent.png"), size: 128, modificationNanos: 0), name: "ghost-nonexistent.png", kind: .image)
        let apps = FileOperationController.applicationsForOpening([ghostEntry]), openWithMenu = NSMenu()
        let openWithEnabled = fileOps.populateOpenWithMenu(openWithMenu, origin: FileOrigin(window: controller, items: [ghostEntry]))
        log.check(!exists(targetDir.appending(path: "ghost-nonexistent.png")) && openWithEnabled && (apps.defaultApp != nil || !apps.others.isEmpty) && openWithMenu.items.count >= 2, "C2.10 不存在的路径按扩展名列出可打开应用（共 \(openWithMenu.items.count) 项）且不触发文件读取")

        // C2.10a：两个窗口打开同一本书，移动当前页后两边都去掉，撤销后两边都回来且当前页不跳。
        guard let second = app.newWindow(), let secondWindow = second.window else { return log.check(false, "C2.10a 无法新建第二个窗口") }
        second.open([bookDir])
        await until("第二窗口打开同一本书") { second.session.book?.location.name == "book" && second.session.book?.pages.count == 3 }
        controller.session.go(.index(0)); second.session.go(.index(0)); await settle()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(controller.viewer)
        await fileOps.transfer(origin: controller.fileOrigin(), into: targetLoc, mode: .move)
        await until("两窗口都去掉 001.png") { controller.session.book?.pages.map(\.entry.name) == ["002.png", "003.png"] && second.session.book?.pages.map(\.entry.name) == ["002.png", "003.png"] }
        log.check(controller.session.book?.pages.count == 2 && second.session.book?.pages.count == 2, "C2.10a 一个窗口移动当前页后两个窗口都去掉这一页")
        await sendKey(kVK_ANSI_Z, [.command])
        await until("撤销后两窗口都恢复 3 页") { !fileOps.isBusy && controller.session.book?.pages.count == 3 && second.session.book?.pages.count == 3 }
        let secondPageName = second.session.book.flatMap { $0.pages.indices.contains(second.session.currentPage) ? $0.pages[second.session.currentPage].entry.name : nil }
        log.check(controller.session.book?.pages.map(\.entry.name) == ["001.png", "002.png", "003.png"] && secondPageName == "002.png", "C2.10a 撤销后两边都恢复 3 页且当前页保持在 002.png 不跳：\(secondPageName ?? "")")
        secondWindow.close(); targetWindow = window; window.makeKeyAndOrderFront(nil); await settle()

        // C2.10b：当前书改名后在新位置继续且页码不变、书架刷新；当前书移到另一文件夹后打开书架下一本且书架刷新。
        let (shelfDir, outDir) = try makePair("c210b", "shelf", "out")
        let bookADir = shelfDir.appending(path: "bookA", directoryHint: .isDirectory), bookBDir = shelfDir.appending(path: "bookB", directoryHint: .isDirectory)
        try fm.createDirectory(at: bookADir, withIntermediateDirectories: true); try fm.createDirectory(at: bookBDir, withIntermediateDirectories: true)
        for index in 1...3 {
            try writePNG(to: bookADir.appending(path: String(format: "%03d.png", index)), hue: CGFloat(index) * 0.15)
            try writePNG(to: bookBDir.appending(path: String(format: "%03d.png", index)), hue: CGFloat(index) * 0.25)
        }
        controller.open([bookADir])
        await until("打开 bookA 且书架列出两本书") { controller.session.book?.location.name == "bookA" && controller.session.book?.isEnumerated == true && controller.session.book?.pages.count == 3 && shelfView.items.map(\.name) == ["bookA", "bookB"] }
        controller.session.go(.index(1)); await settle()
        let bookALoc = try await services.sources.location(for: bookADir), outLoc = try await services.sources.location(for: outDir)
        let bookAEntry = Entry(identity: ContentIdentity(location: bookALoc, size: 0, modificationNanos: 0), name: "bookA", kind: .directory)
        _ = await fileOps.perform(.rename(bookALoc, to: "bookA-renamed"), title: "重命名“bookA”", origin: FileOrigin(window: controller, items: [bookAEntry]))
        await until("bookA 改名后会话与书架刷新") { controller.session.book?.location.name == "bookA-renamed" && controller.session.book?.isEnumerated == true && controller.session.currentPage == 1 && shelfView.items.map(\.name) == ["bookA-renamed", "bookB"] }
        log.check(controller.session.book?.location.name == "bookA-renamed" && controller.session.currentPage == 1 && shelfView.items.map(\.name) == ["bookA-renamed", "bookB"], "C2.10b 当前书改名后在新位置继续、页码不变且书架刷新")
        let renamedLoc = try await services.sources.location(for: shelfDir.appending(path: "bookA-renamed"))
        let renamedEntry = Entry(identity: ContentIdentity(location: renamedLoc, size: 0, modificationNanos: 0), name: "bookA-renamed", kind: .directory)
        await fileOps.transfer(origin: FileOrigin(window: controller, items: [renamedEntry]), into: outLoc, mode: .move)
        await until("当前书移走后打开下一本 bookB 且书架刷新") { controller.session.book?.location.name == "bookB" && controller.session.book?.pages.count == 3 && shelfView.items.map(\.name) == ["bookB"] }
        log.check(controller.session.book?.location.name == "bookB" && shelfView.items.map(\.name) == ["bookB"], "C2.10b 把当前书移到另一个文件夹后打开书架下一本且书架刷新")

        // C2.10c：表格多选右键规则，以及重命名表单打开后改变列表选中项，提交时仍改原来那一项。
        pageList.setStyle(.table); await settle()
        listView.selectRows(IndexSet([0, 2]))
        log.check(itemEnabled(listView.contextMenu(forItemAt: 2), String(localized: "重命名…")) == false && itemEnabled(listView.contextMenu(forItemAt: 1), String(localized: "重命名…")) == true, "C2.10c 右键已选中项取全部多选（重命名灰掉），右键未选中项只取该项（重命名可用）")
        listView.selectRows(IndexSet(integer: 0)); window.makeFirstResponder(listView); await settle()
        fileOps.presentRename(origin: controller.fileOrigin()); await settle()
        guard let snapSheet = window.attachedSheet as? RenameSheet else { return log.check(false, "C2.10c 未弹出重命名表单") }
        listView.selectRows(IndexSet(integer: 1)); await settle()
        snapSheet.setInputText("001-snap.png")
        await click(snapSheet.confirmButton, in: snapSheet)
        await until("快照重命名完成") { window.attachedSheet == nil && !fileOps.isBusy && self.exists(bookBDir.appending(path: "001-snap.png")) }
        log.check(exists(bookBDir.appending(path: "001-snap.png")) && exists(bookBDir.appending(path: "002.png")) && !exists(bookBDir.appending(path: "001.png")), "C2.10c 重命名表单打开后改变页面列表选中项，提交时仍修改原快照项 001.png")

        try await runClassifyChecks(controller: controller, window: window, services: services, fileOps: fileOps, zipURL: zipURL, zipBytes: zipBytes)
        try await runDragChecks(controller: controller, window: window, services: services, fileOps: fileOps, pageList: pageList, listView: listView, bookshelf: bookshelf, shelfView: shelfView, bookDir: bookDir, zipURL: zipURL, zipBytes: zipBytes)
    }

    private func runDragChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController, pageList: PageListPanel, listView: CollectionView, bookshelf: BookshelfPanel, shelfView: CollectionView, bookDir: URL, zipURL: URL, zipBytes: Data) async throws {
        let dropRoot = temporary.appending(path: "c211-drop", directoryHint: .isDirectory)
        let dropNormalDir = dropRoot.appending(path: "normal", directoryHint: .isDirectory)
        let dropMultiDir = dropRoot.appending(path: "multi", directoryHint: .isDirectory)
        let dropSingleDir = dropRoot.appending(path: "single", directoryHint: .isDirectory)
        let dropArchiveDir = dropRoot.appending(path: "archive", directoryHint: .isDirectory)
        for dir in [dropNormalDir, dropMultiDir, dropSingleDir, dropArchiveDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let dropTarget = SelfTestDropTargetView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(dropTarget)
        defer { dropTarget.removeFromSuperview() }

        controller.open([bookDir])
        await until("C2.11 打开文件夹书") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 3 && listView.items.count == 3 && shelfView.items.contains(where: { $0.name == "book" }) }
        let book001 = bookDir.appending(path: "001.png"), book002 = bookDir.appending(path: "002.png"), book003 = bookDir.appending(path: "003.png")
        let hash001 = try sha256(of: book001), hash002 = try sha256(of: book002), hash003 = try sha256(of: book003)
        let undoBeforeDrag = fileOps.undoManager.undoActionName

        // 列表模式拖出普通文件：真实拖动事件产生 NSDraggingSession 并将文件 URL 写入拖动粘贴板，放置目标视图接收后得到完整文件且 SHA-256 一致。
        pageList.setStyle(.list); await settle()
        listView.selectRows(IndexSet(integer: 0))
        await dragItem(at: 0, in: listView, window: window)
        let droppedNormal = try await dropTarget.receiveDrop(from: listView, into: dropNormalDir)
        let droppedNormal001 = dropNormalDir.appending(path: "001.png")
        log.check(droppedNormal.map(\.lastPathComponent) == ["001.png"] && exists(droppedNormal001) && (try? sha256(of: droppedNormal001)) == hash001, "C2.11 普通文件经真实拖动事件拖到放置目标目录，文件完整且 SHA-256 与源文件一致")

        // 网格/瀑布流模式及选中项拖出规则：拖动选中项内的一项拖出全部选中项，拖动未选中项只拖出该项；书架同样可拖出。
        pageList.setStyle(.grid); await settle()
        await until("页面列表网格排好") { listView.canvas.placedCount == 3 }
        listView.selectRows(IndexSet([0, 2]))
        await dragItem(at: 2, in: listView, window: window)
        let droppedMulti = try await dropTarget.receiveDrop(from: listView, into: dropMultiDir)
        log.check(droppedMulti.map(\.lastPathComponent) == ["001.png", "003.png"] && (try? sha256(of: dropMultiDir.appending(path: "001.png"))) == hash001 && (try? sha256(of: dropMultiDir.appending(path: "003.png"))) == hash003, "C2.11 拖动选中项内的一项拖出全部选中项（001.png、003.png）且 SHA-256 一致")
        listView.selectRows(IndexSet([0, 2]))
        await dragItem(at: 1, in: listView, window: window)
        let droppedSingle = try await dropTarget.receiveDrop(from: listView, into: dropSingleDir)
        log.check(droppedSingle.map(\.lastPathComponent) == ["002.png"] && (try? sha256(of: dropSingleDir.appending(path: "002.png"))) == hash002, "C2.11 拖动未选中项只拖出该项（002.png）且 SHA-256 一致")

        bookshelf.setStyle(.table); await settle()
        await dragItem(at: 0, in: shelfView, window: window)
        let shelfTableURLs = shelfView.lastDragSession?.session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        bookshelf.setStyle(.masonry); await settle()
        await until("书架瀑布流排好") { shelfView.canvas.placedCount >= 1 }
        await dragItem(at: 0, in: shelfView, window: window)
        let shelfDraggedURLs = shelfView.lastDragSession?.session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        log.check(shelfTableURLs?.first?.standardizedFileURL == bookDir.standardizedFileURL && shelfDraggedURLs?.first?.standardizedFileURL == bookDir.standardizedFileURL, "C2.11 书架详情与瀑布流模式经真实拖动事件写出书目录 URL")
        bookshelf.setStyle(.list)

        // 压缩包内的页拖出：使用 NSFilePromiseProvider，文件名用原名，后台队列经 fileLease 解出并复制，完成后释放租约，SHA-256 一致。
        controller.open([zipURL])
        await until("C2.11 打开压缩包书") { controller.session.book?.location.name == "c27-archive.zip" && controller.session.book?.pages.count == 3 && listView.items.count == 3 }
        pageList.setStyle(.masonry); await settle()
        await until("压缩包页面列表瀑布流排好") { listView.canvas.placedCount == 3 }
        listView.selectRows(IndexSet(integer: 0))
        await dragItem(at: 0, in: listView, window: window)
        let receivers = listView.lastDragSession?.session.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
        let promiseDelegate = (listView.lastDragSession?.writers.first as? NSFilePromiseProvider)?.delegate as? FilePromiseDelegate
        log.check(receivers?.count == 1 && promiseDelegate != nil, "C2.11 压缩包内的页拖动时向粘贴板提供 NSFilePromiseProvider")
        let droppedArchive = try await dropTarget.receiveDrop(from: listView, into: dropArchiveDir)
        let droppedArchive001 = dropArchiveDir.appending(path: "001.png")
        guard let archivePageLoc = controller.session.book?.pages.first?.entry.location else { return log.check(false, "C2.11 找不到压缩包第一页位置") }
        let extractedLease = try await services.sources.provider(for: archivePageLoc).fileLease(for: archivePageLoc)
        let extractedHash = try sha256(of: extractedLease.url)
        log.check(droppedArchive.map(\.lastPathComponent) == ["001.png"] && exists(droppedArchive001) && (try? sha256(of: droppedArchive001)) == extractedHash && extractedHash == hash001, "C2.11 压缩包内的页经 NSFilePromiseProvider 拖出到放置目标目录，文件名为原名且与解出文件 SHA-256 哈希一致")
        log.check(promiseDelegate?.hasActiveLease == false, "C2.11 压缩包文件承诺完成后已释放 fileLease 租约")
        log.check(!fileOps.isBusy && fileOps.undoManager.undoActionName == undoBeforeDrag && exists(book001) && (try? Data(contentsOf: zipURL)) == zipBytes, "C2.11 拖出不经 FileOperationController、不进撤销历史、不修改源")
        pageList.setStyle(.list); await settle()
    }

    private func runClassifyChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController, zipURL: URL, zipBytes: Data) async throws {
        let root = temporary.appending(path: "c212", directoryHint: .isDirectory)
        let bookDir = root.appending(path: "book", directoryHint: .isDirectory), favDir = root.appending(path: "精选", directoryHint: .isDirectory)
        let editDir = root.appending(path: "待修", directoryHint: .isDirectory), landDir = favDir.appending(path: "A-风景", directoryHint: .isDirectory), portDir = favDir.appending(path: "B-人像", directoryHint: .isDirectory)
        for dir in [bookDir, favDir, editDir, landDir, portDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for index in 1...4 { try writePNG(to: bookDir.appending(path: String(format: "%03d.png", index)), hue: CGFloat(index) * 0.18) }

        controller.open([bookDir])
        await until("C2.12 打开测试书") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 4 }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_3, [.command, .option])
        await until("打开分类面板") { controller.classifyPanel != nil }
        guard let panel = controller.classifyPanel else { return log.check(false, "C2.12 无法打开分类面板") }
        let listView = panel.panelView.listView
        await settle(); log.snapshot(window, "classify-panel-empty")
        await panel.addTargetURLs([favDir], listsSubfolders: true)
        await until("列出精选子文件夹") { panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像"] }
        log.check(panel.visibleRows.map(\.keyBadge) == ["1", "2", "3"], "C2.12 开启列出子文件夹的目标展开并按顺序编号 1、2、3")

        // C2.12（S4）：按数字键移动两页 → 切到复制按一次 → 切回移动并用“新建目标并移入”分类一页 → 连续 ⌘Z 撤销全部 → 连续 ⇧⌘Z 重做全部。
        let p1 = bookDir.appending(path: "001.png"), p2 = bookDir.appending(path: "002.png"), p3 = bookDir.appending(path: "003.png"), p4 = bookDir.appending(path: "004.png")
        let landP1 = landDir.appending(path: "001.png"), portP2 = portDir.appending(path: "002.png"), landP3 = landDir.appending(path: "003.png")
        let nightDir = favDir.appending(path: "C-夜景", directoryHint: .isDirectory), nightP3 = nightDir.appending(path: "003.png")
        await sendKey(kVK_ANSI_2)
        await until("按键 2 移动 001.png 到 A-风景") { !fileOps.isBusy && self.exists(landP1) && controller.session.book?.pages.count == 3 }
        log.check(!exists(p1) && exists(landP1) && listView.flashedLocation?.name == "A-风景", "C2.12 按 2 把 001.png 移入“A-风景”且对应行闪烁 Clay")
        await sendKey(kVK_ANSI_3)
        await until("按键 3 移动 002.png 到 B-人像") { !fileOps.isBusy && self.exists(portP2) && controller.session.book?.pages.count == 2 }
        log.check(!exists(p2) && exists(portP2), "C2.12 按 3 把 002.png 移入“B-人像”")

        fileOps.setClassifyMode(.copy, announceIn: controller); panel.refreshState(); await settle()
        await sendKey(kVK_ANSI_2)
        await until("复制模式下按 2 复制 003.png 到 A-风景") { !fileOps.isBusy && self.exists(landP3) }
        log.check(exists(p3) && exists(landP3) && controller.session.book?.pages.count == 2, "C2.12 复制模式下按 2 复制 003.png 到“A-风景”且源文件保留")

        fileOps.setClassifyMode(.move, announceIn: controller); panel.selectRow(at: panel.visibleRows.first?.location); await settle()
        await click(panel.panelView.newTargetButton, in: window)
        await until("出现新建目标输入框") { panel.editingLocation != nil && window.firstResponder is NSTextView }
        guard panel.editingLocation != nil, window.firstResponder is NSTextView else { return }
        listView.setInputText("C-夜景"); await sendKey(kVK_Return)
        await until("新建“C-夜景”并移入 003.png 完成") {
            !fileOps.isBusy && self.exists(nightP3) && panel.editingLocation == nil && panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像", "C-夜景"] && panel.selectedLocation?.name == "C-夜景"
        }
        log.check(!exists(p3) && exists(nightP3) && panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像", "C-夜景"] && panel.selectedLocation?.name == "C-夜景", "C2.12 新建目标并移入创建“C-夜景”子文件夹、移入 003.png 并选中新子文件夹：\(panel.visibleRows.map(\.name))")
        log.snapshot(window, "classify-panel")

        for step in 1...4 { await sendKey(kVK_ANSI_Z, [.command]); await until("C2.12 第 \(step) 次 ⌘Z 完成") { !fileOps.isBusy } }
        await until("4 次 ⌘Z 后子文件夹列表恢复") { panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像"] && controller.session.book?.pages.count == 4 }
        log.check(exists(p1) && exists(p2) && exists(p3) && !exists(landP1) && !exists(portP2) && !exists(landP3) && !exists(nightDir) && panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像"], "C2.12 连续 4 次 ⌘Z 撤销全部后文件系统与面板子文件夹列表完全回到初始状态")

        for step in 1...4 { await sendKey(kVK_ANSI_Z, [.command, .shift]); await until("C2.12 第 \(step) 次 ⇧⌘Z 完成") { !fileOps.isBusy } }
        await until("4 次 ⇧⌘Z 后子文件夹列表恢复 C-夜景") { panel.visibleRows.map(\.name) == ["精选", "A-风景", "B-人像", "C-夜景"] && controller.session.book?.pages.count == 1 }
        log.check(!exists(p1) && !exists(p2) && !exists(p3) && exists(landP1) && exists(portP2) && exists(landP3) && exists(nightP3), "C2.12 连续 4 次 ⇧⌘Z 重做全部后文件与新建子文件夹全部恢复")

        // C2.13：焦点在名称输入框时数字键输入文字；面板关闭后数字键恢复为缩放。
        window.makeFirstResponder(controller.viewer); panel.selectRow(at: panel.visibleRows.first?.location); await settle()
        await click(panel.panelView.newTargetButton, in: window)
        await until("C2.13 输入框获得焦点") { window.firstResponder is NSTextView }
        await sendKey(kVK_ANSI_1)
        log.check(listView.inputField.stringValue == "1" && exists(p4), "C2.13 焦点在名称输入框时按数字键 1 输入文字而不触发分类：\(listView.inputField.stringValue)")
        await sendKey(kVK_Escape)
        await until("Esc 取消输入框") { panel.editingLocation == nil && !(window.firstResponder is NSTextView) }
        await sendKey(kVK_ANSI_3, [.command, .option])
        await until("关闭分类面板") { controller.classifyPanel == nil }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_1)
        await until("面板关闭后按 1 切换为 100% 缩放") { controller.session.settings.scaleMode == .original }
        log.check(controller.session.settings.scaleMode == .original && exists(p4), "C2.13 面板关闭后数字键 1 恢复为 100% 缩放且不移动文件")
        await sendKey(kVK_ANSI_0); await settle()

        // C2.14：展开子文件夹后编号顺延；拖动顶层行后编号随之变化，settings.json 里的目标顺序一致。
        await sendKey(kVK_ANSI_3, [.command, .option])
        await until("重新打开分类面板") { controller.classifyPanel != nil }
        guard let panel2 = controller.classifyPanel else { return log.check(false, "C2.14 无法重新打开分类面板") }
        let listView2 = panel2.panelView.listView
        await panel2.addTargetURLs([editDir], listsSubfolders: false)
        await until("添加待修目标") { panel2.visibleRows.last?.name == "待修" }
        guard let favLoc = panel2.visibleRows.first?.location else { return }
        panel2.toggleCollapse(for: favLoc); await settle()
        log.check(panel2.visibleRows.map { "\($0.keyBadge ?? ""):\($0.name)" } == ["1:精选", "2:待修"], "C2.14 收起子文件夹时顶层编号为 1:精选、2:待修")
        panel2.toggleCollapse(for: favLoc); await settle()
        log.check(panel2.visibleRows.map { "\($0.keyBadge ?? ""):\($0.name)" } == ["1:精选", "2:A-风景", "3:B-人像", "4:C-夜景", "5:待修"], "C2.14 展开子文件夹后编号顺延为 1…5：\(panel2.visibleRows.map { "\($0.keyBadge ?? ""):\($0.name)" })")
        let moveMenu = NSMenu()
        _ = fileOps.populateTransferMenu(moveMenu, origin: controller.fileOrigin(), mode: .move)
        snapshotContextMenu(fileOps.contextMenu(for: controller.fileOrigin()), submenuTitle: "移动到", in: window)
        log.check(moveMenu.items.prefix(5).map(\.title) == ["1  精选", "2  精选 / A-风景", "3  精选 / B-人像", "4  精选 / C-夜景", "5  待修"], "C2.14 右键“移动到”菜单与分类面板可见目标及编号一致")
        await dragClassifyRow(fromIndex: 4, toY: 2, in: listView2, window: window)
        await until("拖动待修到顶部") { panel2.visibleRows.first?.name == "待修" }
        let persistedNames = await services.settings.global().fileOperations.classifyTargets.map(\.location.name)
        log.check(panel2.visibleRows.prefix(2).map { "\($0.keyBadge ?? ""):\($0.name)" } == ["1:待修", "2:精选"] && persistedNames == ["待修", "精选"], "C2.14 拖动顶层行后编号更新且 settings.json 目标顺序一致：\(persistedNames)")

        // C2.15：单击行不移动文件，双击行与按对应数字键效果相同。
        await clickClassifyRow(at: 0, clickCount: 1, in: listView2, window: window)
        log.check(panel2.selectedLocation?.name == "待修" && exists(p4) && !exists(editDir.appending(path: "004.png")), "C2.15 单击行只选中目标而不移动文件")
        await clickClassifyRow(at: 0, clickCount: 2, in: listView2, window: window)
        await until("双击待修行移动 004.png") { !fileOps.isBusy && self.exists(editDir.appending(path: "004.png")) }
        log.check(!exists(p4) && exists(editDir.appending(path: "004.png")), "C2.15 双击行将当前页移动到该目标（与按对应数字键相同）")
        await sendKey(kVK_ANSI_Z, [.command])
        await until("撤销双击移动恢复 004.png") { !fileOps.isBusy && self.exists(p4) }

        // C2.15a：压缩包书里按数字键，状态栏提示“压缩包内的项不能移动”，文件不变（对应 S10）。
        controller.open([zipURL])
        await until("C2.15a 打开压缩包书") { controller.session.book?.location.name == "c27-archive.zip" && controller.session.book?.pages.count == 3 }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_1)
        let archiveMsg = controller.content.statusBar.message ?? ""
        log.check(archiveMsg == String(localized: "压缩包内的项不能移动") && (try? Data(contentsOf: zipURL)) == zipBytes && !panel2.panelView.newTargetButton.isEnabled, "C2.15a 压缩包书里按数字键提示“压缩包内的项不能移动”且文件不变：\(archiveMsg)")
        log.snapshot(window, "classify-panel-archive")

        // C2.15b：面板浮动时，按数字键作用于它绑定的窗口的当前页；名称输入框拿到焦点后，回车仍放入输入框出现时的那一页。
        let p5 = bookDir.appending(path: "005.png"); try writePNG(to: p5, hue: 0.9)
        controller.open([bookDir])
        await until("恢复文件夹书含 004/005") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 2 }
        controller.dock.perform { $0.moving(DockPanels.classify, to: .floating(DockFrame(x: 140, y: 140, width: 260, height: 420))) }
        await until("分类面板转为浮动") { controller.dock.coordinator.floatingWindows[DockPanels.classify] != nil }
        guard let floatingWin = controller.dock.coordinator.floatingWindows[DockPanels.classify],
              let floatingPanel = floatingWin.panel as? ClassifyPanel,
              let second = app.newWindow(), let secondWindow = second.window else { return log.check(false, "C2.15b 无法准备浮动面板或第二窗口") }
        second.open([bookDir])
        await until("第二窗口打开 book") { second.session.book?.location.name == "book" && second.session.book?.pages.count == 2 }
        second.session.go(.index(0)); await settle()
        targetWindow = secondWindow; secondWindow.makeKeyAndOrderFront(nil); secondWindow.makeFirstResponder(second.viewer)
        controller.dock.coordinator.activate(second.dock); await settle()
        log.check(floatingPanel.owner === second, "C2.15b 浮动分类面板随活动窗口绑定到第二窗口")
        await sendKey(kVK_ANSI_1)
        await until("浮动面板按 1 移动第二窗口当前页 004.png") { !fileOps.isBusy && self.exists(editDir.appending(path: "004.png")) }
        log.check(!exists(p4) && exists(editDir.appending(path: "004.png")), "C2.15b 浮动面板按数字键作用于绑定窗口的当前页")
        await sendKey(kVK_ANSI_Z, [.command])
        await until("撤销恢复 004.png") { !fileOps.isBusy && self.exists(p4) && second.session.book?.pages.count == 2 }
        second.session.go(.index(0)); await settle()
        floatingPanel.selectRow(at: floatingPanel.visibleRows.first?.location)
        await click(floatingPanel.panelView.newTargetButton, in: floatingWin)
        await until("浮动面板输入框出现并锁定快照") { floatingPanel.editingLocation != nil && floatingPanel.newTargetOrigin.items.map(\.name) == ["004.png"] }
        second.session.go(.index(1)); await settle()
        floatingPanel.panelView.listView.setInputText("浮动快照"); await sendKey(kVK_Return)
        let floatSnapFile = editDir.appending(path: "浮动快照/004.png")
        await until("浮动面板回车完成新建并移入") { !fileOps.isBusy && self.exists(floatSnapFile) }
        log.check(exists(floatSnapFile) && !exists(p4) && exists(p5), "C2.15b 浮动面板输入框出现后翻到 005.png，回车仍放入快照时的 004.png")
        targetWindow = secondWindow; secondWindow.makeKeyAndOrderFront(nil); secondWindow.makeFirstResponder(second.viewer)
        await sendKey(kVK_ANSI_Z, [.command])
        await until("撤销浮动新建恢复 004.png") { !fileOps.isBusy && self.exists(p4) && !self.exists(editDir.appending(path: "浮动快照")) }
        secondWindow.close(); targetWindow = window; window.makeKeyAndOrderFront(nil)
        controller.dock.coordinator.activate(controller.dock); controller.dock.coordinator.dockFloating(DockPanels.classify)
        window.makeFirstResponder(controller.viewer); await settle()

        // C2.15c：新建目标并移入时目录建好、传输失败（自检里事先删掉源文件），输入框下显示原因；撤销后新文件夹被删除。
        guard let dockedPanel = controller.classifyPanel else { return log.check(false, "C2.15c 找不到停靠分类面板") }
        let dockedList = dockedPanel.panelView.listView
        controller.session.go(.index(0)); await settle()
        dockedPanel.selectRow(at: dockedPanel.visibleRows.first?.location)
        await click(dockedPanel.panelView.newTargetButton, in: window)
        await until("C2.15c 输入框出现") { dockedPanel.editingLocation != nil }
        try fm.removeItem(at: p4)
        let partialDir = editDir.appending(path: "半途失败", directoryHint: .isDirectory)
        dockedList.setInputText("半途失败"); await sendKey(kVK_Return)
        await until("C2.15c 目录建好但传输失败显示原因") { !fileOps.isBusy && !dockedList.errorLabel.isHidden }
        log.check(exists(partialDir) && dockedPanel.editingLocation != nil && !dockedList.errorLabel.stringValue.isEmpty && !dockedList.retryButton.isHidden, "C2.15c 目录已建好而传输失败时保留输入框、下方显示原因并提供重试：\(dockedList.errorLabel.stringValue)")
        window.makeFirstResponder(controller.viewer); await sendKey(kVK_ANSI_Z, [.command])
        await until("C2.15c ⌘Z 删除已建的新文件夹") { !fileOps.isBusy && !self.exists(partialDir) }
        log.check(!exists(partialDir) && dockedPanel.editingLocation == nil, "C2.15c 撤销后已创建的新文件夹被删除且输入框收起")
        await sendKey(kVK_ANSI_3, [.command, .option]); await settle()

        // C2.16：设置自检——切换重名处理后 settings.json 的 fileOperations.nameConflict 随之改变，重新打开设置窗口显示一致。
        guard let settings = app.openSettings(), let settingsWin = settings.window else { return log.check(false, "C2.16 无法打开设置窗口") }
        await settings.state.model.loadAll()
        settings.state.page = .files; await settle()
        log.check(SettingsPage.allCases == [.browse, .display, .cache, .rules, .files, .shortcuts, .pointer, .menus, .appearance, .extensions] && settings.state.page.title == String(localized: "文件"), "C2.16 设置窗口包含当前顺序的十页及“文件”页")
        log.snapshot(settingsWin, "settings-files-appendNumber")
        let settingsFile = app.supportDirectory.appending(path: "settings.json")
        global(settings.state.model, \.fileOperations.nameConflict).wrappedValue = .skip
        await until("C2.16 nameConflict=skip 写入 settings.json") {
            ((try? String(contentsOf: settingsFile, encoding: .utf8))?.contains("\"skip\"") == true) && fileOps.fileSettings.nameConflict == .skip
        }
        await settle(); log.snapshot(settingsWin, "settings-files-skip")
        settingsWin.close()
        let reopenedSettings = SettingsWindowController(store: services.settings, sources: services.sources, supportDirectory: app.supportDirectory, cacheDirectory: app.cacheDirectory)
        reopenedSettings.show(); reopenedSettings.state.page = .files
        await until("C2.16 重开设置窗口读取 skip") { reopenedSettings.state.model.global.fileOperations.nameConflict == .skip }
        log.check(reopenedSettings.state.model.global.fileOperations.nameConflict == .skip && fileOps.fileSettings.nameConflict == .skip, "C2.16 切换重名处理为“跳过”后 settings.json 与重新打开的设置窗口显示一致")
        reopenedSettings.window?.close()
        _ = app.openSettings()
        global(settings.state.model, \.fileOperations.nameConflict).wrappedValue = .appendNumber
        await until("C2.16 nameConflict=appendNumber 写入 settings.json") {
            ((try? String(contentsOf: settingsFile, encoding: .utf8))?.contains("\"appendNumber\"") == true) && fileOps.fileSettings.nameConflict == .appendNumber
        }
        settingsWin.close(); targetWindow = window; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(controller.viewer); await settle()

        // C2.17：清空回收目录——没有回收目录时提示“没有回收目录”；有回收目录时列表显示的卷与删除批次数一致，勾选后二次确认清空。
        let (volADir, volBDir) = try makePair("c217", "Photos", "Archive")
        let volALoc = try await services.sources.location(for: volADir), volBLoc = try await services.sources.location(for: volBDir)
        fileOps.customRecycleRoots = [volALoc, volBLoc]
        defer { fileOps.customRecycleRoots = nil }
        controller.run(.recycleEmpty)
        await until("C2.17 无回收目录状态栏提示") { controller.content.statusBar.message == String(localized: "没有回收目录") }
        log.check(controller.content.statusBar.message == String(localized: "没有回收目录") && window.attachedSheet == nil, "C2.17 没有回收目录时状态栏提示“没有回收目录”且不弹表单")

        let trashA = volADir.appending(path: ".macview-trash", directoryHint: .isDirectory)
        let trashB = volBDir.appending(path: ".macview-trash", directoryHint: .isDirectory)
        for batch in ["20261116-010000-0001", "20261116-010001-0002"] {
            let dir = trashA.appending(path: batch, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try writePNG(to: dir.appending(path: "deleted.png"), hue: 0.2)
        }
        let batchB = trashB.appending(path: "20261116-010002-0001", directoryHint: .isDirectory)
        try fm.createDirectory(at: batchB, withIntermediateDirectories: true)
        try writePNG(to: batchB.appending(path: "deleted.png"), hue: 0.5)

        let undoBeforeRecycle = fileOps.undoManager.undoActionName
        controller.run(.recycleEmpty)
        await until("C2.17 弹出清空回收目录选卷表单") { window.attachedSheet is EmptyRecycleBinsSheet }
        guard let recycleSheet = window.attachedSheet as? EmptyRecycleBinsSheet else { return log.check(false, "C2.17 未弹出清空回收目录表单") }
        log.check(recycleSheet.items.map { "\($0.volumeName):\($0.batchCount)" } == ["Photos:2", "Archive:1"] && recycleSheet.items.allSatisfy(\.isSelected) && recycleSheet.emptyButton.isEnabled, "C2.17 列表显示的卷与删除批次数一致（Photos:2、Archive:1）且默认全选")
        log.snapshot(recycleSheet, "fileops-recycle-list")
        await click(recycleSheet.rowButtons[0], in: recycleSheet)
        await click(recycleSheet.rowButtons[1], in: recycleSheet)
        log.check(!recycleSheet.emptyButton.isEnabled && !recycleSheet.revealButton.isEnabled, "C2.17 没有勾选任何卷时“清空…”与“在 Finder 中显示”按钮不可用")
        await click(recycleSheet.rowButtons[0], in: recycleSheet)
        log.check(recycleSheet.items.map(\.isSelected) == [true, false] && recycleSheet.emptyButton.isEnabled, "C2.17 勾选 Photos 后“清空…”可用")
        await click(recycleSheet.emptyButton, in: recycleSheet)
        await until("C2.17 弹出清空回收目录二次确认表单") { window.attachedSheet is PermanentDeleteSheet }
        guard let confirmRecycle = window.attachedSheet as? PermanentDeleteSheet else { return log.check(false, "C2.17 未弹出二次确认表单") }
        let volumeName = "Photos", totalBatches = 2
        log.check(confirmRecycle.headingLabel.stringValue == String(localized: "永久删除“\(volumeName)”回收目录里的内容？") && confirmRecycle.detailLabel.stringValue == String(localized: "共 \(totalBatches) 次删除。清空后不能撤销。"), "C2.17 二次确认显示卷名与删除批次总数：\(confirmRecycle.headingLabel.stringValue) / \(confirmRecycle.detailLabel.stringValue)")
        log.snapshot(confirmRecycle, "fileops-recycle-confirm")
        await click(confirmRecycle.confirmButton, in: confirmRecycle)
        await until("C2.17 确认后清空 Photos 回收目录") { window.attachedSheet == nil && !fileOps.isBusy && !self.exists(trashA) }
        log.check(!exists(trashA) && exists(trashB) && fileOps.undoManager.undoActionName == undoBeforeRecycle, "C2.17 确认后永久删除所选卷的回收目录、未选卷保留且不登记撤销")
    }

    /// 右键菜单在无头自检里画不出来：按真实 `NSMenu` 的项（标题、可用状态、快捷键、子菜单）画到窗口图像上，只作截图对照。
    private func snapshotContextMenu(_ menu: NSMenu, submenuTitle: String, in window: NSWindow) {
        guard let output = log.output, let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let base = view.renderedImage() else { return }
        let image = NSImage(cgImage: base, size: view.bounds.size)
        image.lockFocusFlipped(true)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let subY = Self.drawMenu(menu, at: NSPoint(x: 340, y: 180), width: 220, highlight: submenuTitle)
            if let sub = menu.items.first(where: { $0.title == submenuTitle })?.submenu { _ = Self.drawMenu(sub, at: NSPoint(x: 558, y: subY), width: 200, highlight: nil) }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: output.appending(path: "fileops-context-menu.png"))
        }
    }

    private static func drawMenu(_ menu: NSMenu, at origin: NSPoint, width: CGFloat, highlight: String?) -> CGFloat {
        let height = menu.items.reduce(CGFloat(10)) { $0 + ($1.isSeparatorItem ? 11 : 22) }
        let box = NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y, width: width, height: height), xRadius: 9, yRadius: 9)
        Theme.raised.setFill(); box.fill(); Theme.lineStrong.setStroke(); box.lineWidth = 0.5; box.stroke()
        var y = origin.y + 5, highlightY = origin.y
        for item in menu.items {
            if item.isSeparatorItem { Theme.lineStrong.setFill(); NSRect(x: origin.x + 12, y: y + 5, width: width - 24, height: 0.5).fill(); y += 11; continue }
            let row = NSRect(x: origin.x + 5, y: y, width: width - 10, height: 22), isHighlighted = item.title == highlight
            if isHighlighted { highlightY = y - 5; NSColor.selectedContentBackgroundColor.setFill(); NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill() }
            let color = isHighlighted ? NSColor.white : (item.isEnabled ? Theme.text : Theme.text2.withAlphaComponent(0.6))
            (item.title as NSString).draw(at: NSPoint(x: row.minX + 9, y: y + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color])
            let modifiers = [(NSEvent.ModifierFlags.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { item.keyEquivalentModifierMask.contains($0.0) }.map(\.1).joined()
            let key = ["\u{08}", "\u{7f}"].contains(item.keyEquivalent) ? "⌫" : item.keyEquivalent.uppercased()
            let right = item.submenu != nil ? "›" : (item.keyEquivalent.isEmpty ? "" : modifiers + key) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color.withAlphaComponent(0.75)]
            right.draw(at: NSPoint(x: row.maxX - right.size(withAttributes: attributes).width - 9, y: y + 3), withAttributes: attributes)
            y += 22
        }
        return highlightY
    }

    // MARK: 网络卷验收

    /// 网络卷上的测试项都以这个前缀命名，`.macview-trash` 由 S2 自己建、自己清空；本机测试项放在 support 目录里。
    private static let netPrefix = "macview-selftest-"
    private var netA: URL {
        if let path = UserDefaults.standard.string(forKey: "MVFileOpsNetworkRoot"), !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return fm.homeDirectoryForCurrentUser.appending(path: "MacViewBench/fileops-a", directoryHint: .isDirectory)
    }
    private var netLocal: URL { app.supportDirectory.appending(path: "selftest-local", directoryHint: .isDirectory) }
    private func netItems() -> [String] { ((try? fm.contentsOfDirectory(atPath: netA.path)) ?? []).filter { $0.hasPrefix(Self.netPrefix) || $0.hasPrefix("._\(Self.netPrefix)") || $0.hasSuffix(".macview-trash") } }

    /// S6 单独运行；以控制器收到的 perform 结果结束，保留逐项失败供排查。
    private func runNetworkSkip(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        guard let listView = (controller.dock.panels[DockPanels.pageList] as? PageListPanel)?.collection else { return log.check(false, "找不到页面列表") }
        var fs = statfs()
        let ready = statfs(netA.path, &fs) == 0 && (fs.f_flags & UInt32(MNT_LOCAL)) == 0 && netItems().isEmpty
        log.check(ready, "独立网络卷已挂载且无旧测试项：\(netItems())"); guard ready else { return }
        try? await services.settings.updateGlobal {
            $0.prefetch.currentBookPages = false; $0.prefetch.viewerDecodeFrames = 0; $0.prefetch.viewerReadAheadPages = 0
            $0.prefetch.neighborBooks = 0; $0.prefetch.shelfCovers = false; $0.fileOperations.nameConflict = .skip
        }
        await fileOps.reloadSettings()
        await sendKey(kVK_ANSI_3, [.command, .option]); await until("打开分类面板") { controller.classifyPanel != nil }
        controller.dock.perform { $0.togglingStyle(.right) }
        let book = netA.appending(path: "\(Self.netPrefix)s6", directoryHint: .isDirectory)
        let target = netLocal.appending(path: "s6-target", directoryHint: .isDirectory)
        try fm.createDirectory(at: book, withIntermediateDirectories: true); try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: target.appending(path: "001.png"))
        var expected: [String: (hash: String, date: Date?)] = [:]
        for index in 1...20 {
            let name = String(format: "%03d.png", index), url = book.appending(path: name)
            try writePNG(to: url, hue: CGFloat(index) / 22)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))], ofItemAtPath: url.path)
            if index > 1 { expected[name] = (try sha256(of: url), modificationDate(url)) }
        }
        await fileOps.setClassifyTargets([ClassifyTarget(location: try await services.sources.location(for: target), listsSubfolders: false)])
        controller.classifyPanel?.refreshState()
        await openBook(book, pages: 20, controller: controller, listView: listView)
        listView.selectRows(IndexSet(integersIn: 0..<20)); window.makeFirstResponder(listView); await settle()
        let completed = fileOps.debugCompletedOperations
        await sendKey(kVK_ANSI_1)
        while fileOps.debugCompletedOperations == completed { try await Task.sleep(for: .milliseconds(25)) }
        guard let result = fileOps.debugLastResult else { return log.check(false, "分类操作没有返回结果") }
        let failures = result.failures.map { "\($0.location.name): \($0.error)" }
        print("S6 perform changes=\(result.changes.count) skipped=\(result.skipped.map(\.name)) failures=\(failures)")
        let arrived = expected.allSatisfy { name, value in (try? sha256(of: target.appending(path: name))) == value.hash && modificationDate(target.appending(path: name)) == value.date }
        let sources = ((try? fm.contentsOfDirectory(atPath: book.path)) ?? []).filter { !$0.hasPrefix(".") }
        let message = controller.content.statusBar.message ?? ""
        log.check(result.changes.count == 19 && result.skipped.map(\.name) == ["001.png"] && result.failures.isEmpty,
                  "S6 perform 结果：完成 \(result.changes.count)，跳过 \(result.skipped.map(\.name))，失败 \(failures)")
        log.check(arrived && sources == ["001.png"] && (try? Data(contentsOf: target.appending(path: "001.png"))) == Data("existing".utf8),
                  "S6 19 项哈希与时间一致、源剩 \(sources)、旧目标不变")
        log.check(message == "已移动 19 项到“s6-target”，跳过 1 项（目标里已有同名项）", "S6 状态栏：\(message)")
    }

    private func runNetworkKill(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        guard let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel, let listView = pageList.collection,
              let bookshelf = controller.dock.panels[DockPanels.bookshelf] as? BookshelfPanel, let shelfView = bookshelf.collection else { return log.check(false, "找不到页面列表或书架面板") }
        var fs = statfs()
        let ready = statfs(netA.path, &fs) == 0 && (fs.f_flags & UInt32(MNT_LOCAL)) == 0 && netItems().isEmpty
        log.check(ready, "网络卷 fileops-a 已挂载且没有上次留下的测试项：\(netItems())"); guard ready else { return }
        try? fm.removeItem(at: netLocal); try fm.createDirectory(at: netLocal, withIntermediateDirectories: true)
        // 关掉预读，S5 期间的接口流量只来自这次移动。
        try? await services.settings.updateGlobal { $0.prefetch.currentBookPages = false; $0.prefetch.viewerDecodeFrames = 0; $0.prefetch.viewerReadAheadPages = 0; $0.prefetch.neighborBooks = 0; $0.prefetch.shelfCovers = false }
        pageList.setStyle(.table)

        // C2.18（S2）
        let s2Book = netA.appending(path: "\(Self.netPrefix)s2", directoryHint: .isDirectory), s2Page = s2Book.appending(path: "001.png"), trash = netA.appending(path: ".macview-trash", directoryHint: .isDirectory)
        try fm.createDirectory(at: s2Book, withIntermediateDirectories: true)
        try writePNG(to: s2Page, hue: 0.1); try writePNG(to: s2Book.appending(path: "002.png"), hue: 0.3)
        await openBook(s2Book, pages: 2, controller: controller, listView: listView)
        window.makeFirstResponder(controller.viewer); await settle(); await sendKey(kVK_Delete, [.command])
        await until("C2.18 删除网络卷上的 001.png") { !fileOps.isBusy && !self.exists(s2Page) && listView.items.map(\.name) == ["002.png"] }
        let batches = ((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).filter { !$0.hasPrefix(".") }
        log.check(batches.count == 1 && exists(trash.appending(path: "\(batches[0])/001.png")), "C2.18 S2 删除的页进入 .macview-trash/<批次>/001.png：\(batches)")
        bookshelf.sortChanged()   // 重新列出书架所在的卷根目录，此时回收目录已存在
        await until("C2.18 书架重新列出卷根目录") { shelfView.items.map(\.name).contains(s2Book.lastPathComponent) }
        log.check(!(shelfView.items + listView.items).contains { $0.name == ".macview-trash" }, "C2.18 S2 书架和页面列表看不到回收目录")
        await sendKey(kVK_ANSI_Z, [.command])
        await until("C2.18 ⌘Z 恢复 001.png") { !fileOps.isBusy && self.exists(s2Page) && listView.items.map(\.name) == ["001.png", "002.png"] }
        log.check(exists(s2Page) && listView.items.map(\.name) == ["001.png", "002.png"], "C2.18 S2 ⌘Z 后文件回到原处")
        controller.run(.recycleEmpty)
        await until("C2.18 弹出清空回收目录表单") { window.attachedSheet is EmptyRecycleBinsSheet }
        guard let recycleSheet = window.attachedSheet as? EmptyRecycleBinsSheet else { return log.check(false, "C2.18 未弹出清空回收目录表单") }
        let rows = recycleSheet.items.map { "\($0.mountPath):\($0.batchCount)" }, ours = recycleSheet.items.firstIndex { URL(fileURLWithPath: $0.mountPath).standardized.path == netA.standardized.path }
        log.check(ours.map { recycleSheet.items[$0].batchCount } == 1, "C2.18 S2 清空回收目录列出网络卷 A（1 次删除）：\(rows)"); guard let ours else { return }
        for index in recycleSheet.items.indices where index != ours { await click(recycleSheet.rowButtons[index], in: recycleSheet) }   // 只清空测试卷
        await click(recycleSheet.emptyButton, in: recycleSheet)
        await until("C2.18 弹出清空二次确认") { window.attachedSheet is PermanentDeleteSheet }
        guard let confirm = window.attachedSheet as? PermanentDeleteSheet else { return log.check(false, "C2.18 未弹出二次确认表单") }
        await click(confirm.confirmButton, in: confirm)
        await until("C2.18 清空网络卷 A 的回收目录") { window.attachedSheet == nil && !fileOps.isBusy && !self.exists(trash) }
        log.check(!exists(trash), "C2.18 S2 确认后网络卷 A 的回收目录已清空")

        // C2.19（S5）：经分类面板在网络卷 A 内移动 500 MB 文件。
        await sendKey(kVK_ANSI_3, [.command, .option]); await until("C2.19 打开分类面板") { controller.classifyPanel != nil }
        controller.dock.perform { $0.togglingStyle(.right) }   // 右侧区改为并排，页面列表和分类面板同时可见，列表才能拿到焦点
        let s5Book = netA.appending(path: "\(Self.netPrefix)s5", directoryHint: .isDirectory), s5Target = netA.appending(path: "\(Self.netPrefix)s5-target", directoryHint: .isDirectory)
        let s5Large = s5Book.appending(path: "002-500mb.png"), s5Moved = s5Target.appending(path: "002-500mb.png")
        try fm.createDirectory(at: s5Book, withIntermediateDirectories: true); try fm.createDirectory(at: s5Target, withIntermediateDirectories: true)
        try writePNG(to: s5Book.appending(path: "001.png"), hue: 0.2); try writePNG(to: s5Large, hue: 0.4); try writePattern(to: s5Large, totalBytes: 500_000_000, seed: 17)
        await fileOps.setClassifyTargets([ClassifyTarget(location: try await services.sources.location(for: s5Target), listsSubfolders: false)]); controller.classifyPanel?.refreshState()
        await openBook(s5Book, pages: 2, controller: controller, listView: listView)
        await until("C2.19 后台读取结束") { (services.sources as? FileSourceRegistry)?.currentVolumeHealth().allSatisfy { $0.inFlight == 0 } == true }
        listView.selectRows(IndexSet(integer: 1)); window.makeFirstResponder(listView); await settle()
        let bytesBefore = Self.interfaceBytes(), start = ContinuousClock.now
        await sendKey(kVK_ANSI_1); await until("C2.19 S5 移动 500 MB 文件") { !fileOps.isBusy && self.exists(s5Moved) }
        let seconds = start.duration(to: .now) / .seconds(1), bytesAfter = Self.interfaceBytes()
        let traffic = bytesAfter.reduce(UInt64(0)) { total, item in total + UInt64(item.value &- (bytesBefore[item.key] ?? item.value)) }
        log.check(seconds < 1 && !exists(s5Large) && traffic < 5_000_000, "C2.19 S5 网络卷 A 内移动 500 MB 用时 \(String(format: "%.3f", seconds)) s，期间各接口收发共 \(traffic) B")

        // C2.19（S6）：20 张图片从网络卷 A 分类到本机目标，其中 1 张重名；先加序号，再跳过。
        let s6Book = netA.appending(path: "\(Self.netPrefix)s6", directoryHint: .isDirectory), s6Target = netLocal.appending(path: "s6-target", directoryHint: .isDirectory)
        await fileOps.setClassifyTargets([ClassifyTarget(location: try await services.sources.location(for: s6Target), listsSubfolders: false)]); controller.classifyPanel?.refreshState()
        for skip in [false, true] {
            try? fm.removeItem(at: s6Book); try? fm.removeItem(at: s6Target)
            try fm.createDirectory(at: s6Book, withIntermediateDirectories: true); try fm.createDirectory(at: s6Target, withIntermediateDirectories: true)
            try Data("existing".utf8).write(to: s6Target.appending(path: "001.png"))
            var expected: [String: (hash: String, date: Date?)] = [:]
            for index in 1...20 {
                let name = String(format: "%03d.png", index), url = s6Book.appending(path: name)
                try writePNG(to: url, hue: CGFloat(index) / 22); try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))], ofItemAtPath: url.path)
                expected[index == 1 && !skip ? "001 (2).png" : name] = (try sha256(of: url), modificationDate(url))
            }
            if skip { expected["001.png"] = nil }
            await openBook(s6Book, pages: 20, controller: controller, listView: listView)
            listView.selectRows(IndexSet(integersIn: 0..<20)); window.makeFirstResponder(listView); await settle()
            let completed = fileOps.debugCompletedOperations
            await sendKey(kVK_ANSI_1)
            while fileOps.debugCompletedOperations == completed { try await Task.sleep(for: .milliseconds(25)) }
            guard let result = fileOps.debugLastResult else { return log.check(false, "C2.19 S6 未返回结果") }
            let arrived = expected.allSatisfy { name, value in (try? sha256(of: s6Target.appending(path: name))) == value.hash && modificationDate(s6Target.appending(path: name)) == value.date }
            let sources = ((try? fm.contentsOfDirectory(atPath: s6Book.path)) ?? []).filter { !$0.hasPrefix(".") }, message = controller.content.statusBar.message ?? ""
            let expectedMessage = skip ? "已移动 19 项到“s6-target”，跳过 1 项（目标里已有同名项）" : "已移动 20 项到“s6-target”"
            let valid = result.changes.count == (skip ? 19 : 20) && result.skipped.count == (skip ? 1 : 0) && result.failures.isEmpty && arrived && sources == (skip ? ["001.png"] : []) && (try? Data(contentsOf: s6Target.appending(path: "001.png"))) == Data("existing".utf8) && message == expectedMessage
            log.check(valid, "C2.19 S6 \(skip ? "跳过" : "加序号")：perform 完成 \(result.changes.count)、跳过 \(result.skipped.map(\.name))、失败 \(result.failures.map { "\($0.location.name): \($0.error)" })；源剩 \(sources)，状态栏：\(message)")
            guard valid else { return }
            if !skip { try await services.settings.updateGlobal { $0.fileOperations.nameConflict = .skip }; await until("C2.19 重名处理改为跳过") { fileOps.fileSettings.nameConflict == .skip } }
        }

        try await runNetworkRecoveryKill(controller: controller, services: services, fileOps: fileOps)
    }

    private struct RecoveryJournal: Decodable {
        struct Record: Decodable { let id: UUID, source: Location, target: Location, temporary: Location }
        let version: Int, transfers: [Record]
    }

    // C2.20（S7）：先核实记录和实际复制字节，前置不成立绝不强杀。
    private func runNetworkRecoveryKill(controller: ReaderWindowController, services: CoreServices, fileOps: FileOperationController) async throws {
        let s7Book = netA.appending(path: "\(Self.netPrefix)s7", directoryHint: .isDirectory), s7Target = netLocal.appending(path: "s7-target", directoryHint: .isDirectory), s7Source = s7Book.appending(path: "large-1gb.bin")
        try fm.createDirectory(at: s7Book, withIntermediateDirectories: true); try fm.createDirectory(at: s7Target, withIntermediateDirectories: true)
        guard fm.createFile(atPath: s7Source.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        try writePattern(to: s7Source, totalBytes: 1_000_000_000, seed: 91)
        try sha256(of: s7Source).write(to: netLocal.appending(path: "s7-hash.txt"), atomically: true, encoding: .utf8)
        let sourceLocation = try await services.sources.location(for: s7Source), sourceEntry = try await services.sources.provider(for: sourceLocation).entry(at: sourceLocation)
        let targetLocation = try await services.sources.location(for: s7Target.appending(path: "large-1gb.bin"))
        let move = FileOperation.transfer([sourceLocation], into: try await services.sources.location(for: s7Target), mode: .move, conflict: .appendNumber)
        Task { _ = await fileOps.perform(move, title: "移动“large-1gb.bin”", origin: FileOrigin(window: controller, items: [sourceEntry])) }
        func validatedPart() -> (String, Int)? {
            guard let data = try? Data(contentsOf: app.supportDirectory.appending(path: "transfers.json")),
                  let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: data), journal.version == 1,
                  let record = journal.transfers.first(where: { $0.source == sourceLocation && $0.target == targetLocation }),
                  record.temporary.parent == targetLocation.parent,
                  record.temporary.name.hasSuffix(".macview-part"),
                  let size = (try? fm.attributesOfItem(atPath: s7Target.appending(path: record.temporary.name).path)[.size]) as? Int,
                  size > 32 << 20 else { return nil }
            return (record.temporary.name, size)
        }
        await until("C2.20 跨卷移动已记录并复制了一部分") {
            controller.content.statusBar.isShowingProgress && validatedPart() != nil
        }
        guard controller.content.statusBar.isShowingProgress, let (part, size) = validatedPart() else {
            log.check(false, "C2.20 强杀前置不成立：记录、匹配临时项或 32 MiB 复制量未确认；停止强杀链")
            fileOps.cancelCurrentOperation(); return
        }
        log.check(true, "C2.20 已读到匹配的持久记录及临时项 \(part)，实际大小 \(size) B；对 pid=\(getpid()) 执行 kill -9")
        fflush(stdout); kill(getpid(), SIGKILL)
    }

    private func runNetworkRecoveryVerify(controller: ReaderWindowController) async throws {
        let target = netLocal.appending(path: "s7-target", directoryHint: .isDirectory)
        let moved = target.appending(path: "large-1gb.bin")
        let source = netA.appending(path: "\(Self.netPrefix)s7/large-1gb.bin")
        let expected = (try? String(contentsOf: netLocal.appending(path: "s7-hash.txt"), encoding: .utf8)) ?? ""
        let hash = (try? sha256(of: moved)) ?? ""
        let names = ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).filter { !$0.hasPrefix("._") }
        let data = try? Data(contentsOf: app.supportDirectory.appending(path: "transfers.json"))
        let journal = data.flatMap { try? JSONDecoder().decode(RecoveryJournal.self, from: $0) }
        let message = controller.content.statusBar.message ?? ""
        log.check(message == "上次中断的 1 次移动已完成", "C2.20 恢复提示：\(message)")
        log.check(names == ["large-1gb.bin"] && !exists(source) && journal?.transfers.isEmpty == true && !hash.isEmpty && hash == expected,
                  "C2.20 SHA-256 一致、源删除、临时项及记录清空：目标 \(names)，记录 \(journal?.transfers.count.description ?? "不可读")")
    }

    private func runNetworkPending(controller: ReaderWindowController, services: CoreServices) async {
        guard let report = await services.interruptedTransfersReport(), let item = report.pendingItems.first,
              let banner = controller.content.fileOperationBanner else {
            return log.check(false, "恢复等待时缺少逐项原因或界面提示")
        }
        let text = collectText(in: banner)
        let unavailable: Bool = if case .volumeUnavailable = item.reason { true } else { false }
        log.check(report.pending == 1 && item.phase == .source && unavailable && text.contains(item.source.name)
                  && text.contains(String(localized: "检查源文件")) && text.contains(String(localized: "所在的卷不可用")),
                  "恢复等待保留源文件和具体阶段、卷不可用原因：\(text)")
        if let window = controller.window { log.snapshot(window, "fileops-recovery-pending") }
    }

    private func openBook(_ url: URL, pages: Int, controller: ReaderWindowController, listView: CollectionView) async {
        controller.open([url])
        await until("打开 \(url.lastPathComponent)") { controller.session.book?.location.name == url.lastPathComponent && controller.session.book?.isEnumerated == true && listView.items.count == pages }
    }

    /// 重启后的一步：S7 恢复结果、S12，再做会切走前台的 S9（Finder、预览），最后清理。
    private func runNetworkVerify(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        guard let listView = (controller.dock.panels[DockPanels.pageList] as? PageListPanel)?.collection else { return log.check(false, "找不到页面列表") }
        let s7Target = netLocal.appending(path: "s7-target", directoryHint: .isDirectory), s7Moved = s7Target.appending(path: "large-1gb.bin")
        let expectedHash = (try? String(contentsOf: netLocal.appending(path: "s7-hash.txt"), encoding: .utf8)) ?? "", hash = (try? sha256(of: s7Moved)) ?? ""
        let message = controller.content.statusBar.message ?? "", targetItems = (try? fm.contentsOfDirectory(atPath: s7Target.path)) ?? []
        let journal = (try? JSONSerialization.jsonObject(with: Data(contentsOf: app.supportDirectory.appending(path: "transfers.json"))) as? [String: Any])?["transfers"] as? [Any]
        log.check(message == "上次中断的 1 次移动已完成", "C2.20 S7 重启后状态栏提示：\(message)")
        log.check(targetItems == ["large-1gb.bin"] && !exists(netA.appending(path: "\(Self.netPrefix)s7/large-1gb.bin")) && journal?.isEmpty != false && !hash.isEmpty && hash == expectedHash,
                  "C2.20 S7 目标只有正式文件、源已删除、移动记录已清空、SHA-256 一致：\(targetItems) \(hash)")
        let undo = editMenu(action: #selector(ReaderWindow.undo(_:)))
        log.check(!fileOps.undoManager.canUndo && !undo.enabled, "C2.23 S12 重新启动后撤销菜单不可用：\(undo.title)")

        let s6Target = netLocal.appending(path: "s6-target", directoryHint: .isDirectory)
        // C2.21（S9）：普通页和压缩包内的页各做一次“在 Finder 中显示”和用“预览”打开。
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app"), previewWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").isEmpty
        let s9Zip = netLocal.appending(path: "s9.zip"), ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); ditto.arguments = ["-c", "-k", s6Target.path, s9Zip.path]; try ditto.run(); ditto.waitUntilExit()
        let extractDir = app.cacheDirectory.appending(path: "extract", directoryHint: .isDirectory)
        for url in [s6Target, s9Zip] {
            await openBook(url, pages: 20, controller: controller, listView: listView)
            controller.session.go(.index(1)); window.makeFirstResponder(controller.viewer); await settle()
            let origin = controller.fileOrigin(), extractedBefore = (try? fm.contentsOfDirectory(atPath: extractDir.path)) ?? []
            let revealed = origin.items.first.map { FileOperationController.outerFileLocation(of: $0.location) }, expected = try await services.sources.location(for: url == s9Zip ? s9Zip : s6Target.appending(path: "002.png"))
            await fileOps.revealInFinder(origin: origin); fileOps.openWithApplication(preview, origin: origin)
            await until("C2.21 预览打开 \(url.lastPathComponent)") { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").isEmpty && (url != s9Zip || ((try? self.fm.contentsOfDirectory(atPath: extractDir.path)) ?? []).count > extractedBefore.count) }
            log.check(revealed == expected, "C2.21 S9 \(url == s9Zip ? "压缩包内的页定位到所在压缩包并解出后交给预览" : "普通页定位到 002.png 并交给预览")（Finder 选中与预览窗口由用户目视确认）")
        }
        if !previewWasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").forEach { $0.terminate() } }

        await services.shutdown()
        for name in netItems() { try? fm.removeItem(at: netA.appending(path: name)) }
        try? fm.removeItem(at: netLocal)
        log.check(netItems().isEmpty, "清理后网络卷 A 上没有测试项：\(netItems())")
    }

    private func writePattern(to url: URL, totalBytes: Int, seed: UInt8) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        var remaining = max(0, totalBytes - Int(try handle.seekToEnd()))
        let block = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
        while remaining > 0 { let count = min(remaining, block.count); try autoreleasepool { try handle.write(contentsOf: block.prefix(count)) }; remaining -= count }
        try handle.synchronize()   // 写回完成后再计时，网络卷上未写回的数据会拖慢随后的改名
    }

    private func modificationDate(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// 各非回环接口收发字节数之和（32 位计数，按接口分开以便回绕时相减）。
    private static func interfaceBytes() -> [String: UInt32] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: UInt32] = [:]
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) where item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) && item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
            guard let data = item.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            result[String(cString: item.pointee.ifa_name)] = data.ifi_ibytes &+ data.ifi_obytes
        }
        return result
    }

    private func clickClassifyRow(at index: Int, clickCount: Int, in listView: ClassifyListView, window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let point = listView.rowPointInWindow(index) else { return }
        for currentClick in 1...clickCount {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: currentClick, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func dragClassifyRow(fromIndex: Int, toY: CGFloat, in listView: ClassifyListView, window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let start = listView.rowPointInWindow(fromIndex) else { return }
        let end = listView.convert(NSPoint(x: 40, y: toY), to: nil)
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.sendEvent(event(.leftMouseDown, at: start)); NSApp.sendEvent(event(.leftMouseDragged, at: end)); NSApp.sendEvent(event(.leftMouseUp, at: end))
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        // 每块放进自动释放池：主线程上读 1 GB 时不让读出的块堆到下一次事件循环才释放。
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try handle.read(upToCount: 4 << 20), !data.isEmpty else { return false }
            hash.update(data: data); return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func dragItem(at index: Int, in view: CollectionView, window: NSWindow) async {
        view.clearLastDragSession()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let start = view.itemPointInWindow(index) else { return }
        let end = NSPoint(x: start.x + 24, y: start.y + 24)
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        if view.style.usesCanvas {
            NSApp.sendEvent(event(.leftMouseDown, at: start))
            NSApp.sendEvent(event(.leftMouseDragged, at: end))
            NSApp.sendEvent(event(.leftMouseUp, at: end))
        } else {
            NSApp.postEvent(event(.leftMouseDragged, at: end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, at: end), atStart: false)
            NSApp.sendEvent(event(.leftMouseDown, at: start))
        }
        while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
    private func collectText(in view: NSView) -> String { (view as? NSTextField)?.stringValue ?? view.subviews.map { collectText(in: $0) }.filter { !$0.isEmpty }.joined(separator: " ") }
    private func until(_ description: String, condition: () -> Bool) async {
        for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(25)) }
        log.check(condition(), "等待超时：\(description)")
    }
    private func makePair(_ group: String, _ a: String, _ b: String) throws -> (URL, URL) {
        let root = temporary.appending(path: group, directoryHint: .isDirectory)
        let first = root.appending(path: a, directoryHint: .isDirectory), second = root.appending(path: b, directoryHint: .isDirectory)
        try fm.createDirectory(at: first, withIntermediateDirectories: true); try fm.createDirectory(at: second, withIntermediateDirectories: true)
        return (first, second)
    }
    private func writePNG(to url: URL, width: Int = 200, height: Int = 160, hue: CGFloat) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    }
    private func editMenu(action: Selector) -> (title: String, enabled: Bool) {
        guard let editMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == String(localized: "编辑") }) else { return ("", false) }
        editMenu.update()
        guard let item = editMenu.items.first(where: { $0.action == action }) else { return ("", false) }
        return (item.title, (targetWindow as? ReaderWindow)?.validateMenuItem(item) ?? item.isEnabled)
    }
    private func sendKey(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) async {
        guard let window = NSApp.keyWindow ?? targetWindow else { return }
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            if NSApp.keyWindow != nil { NSApp.sendEvent(event) }
            else if event.type == .keyUp || (!window.performKeyEquivalent(with: event) && NSApp.mainMenu?.performKeyEquivalent(with: event) != true) { window.sendEvent(event) }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    private func click(_ button: NSButton, in window: NSWindow) async {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false); NSApp.sendEvent(event(.leftMouseDown))
        try? await Task.sleep(for: .milliseconds(80))
    }
}

extension NSButton {
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 自检用的放置目标视图：登记接收文件 URL 与文件承诺，把真实拖动会话中的普通文件或 `NSFilePromiseProvider` 写入临时目标目录。
@MainActor
private final class SelfTestDropTargetView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    func receiveDrop(from view: CollectionView, into destination: URL) async throws -> [URL] {
        guard let (session, writers) = view.lastDragSession else { return [] }
        var written: [URL] = []
        if let urls = session.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for src in urls {
                let dst = destination.appending(path: src.lastPathComponent)
                if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                try FileManager.default.copyItem(at: src, to: dst)
                written.append(dst)
            }
        }
        for case let provider as NSFilePromiseProvider in writers {
            guard let delegate = provider.delegate as? FilePromiseDelegate else { continue }
            let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
            let queue = delegate.operationQueue(for: provider)
            let dst = destination.appending(path: name)
            nonisolated(unsafe) let unsafeProvider = provider
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.addOperation {
                    delegate.filePromiseProvider(unsafeProvider, writePromiseTo: dst) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
            written.append(dst)
        }
        return written
    }
}
#endif
