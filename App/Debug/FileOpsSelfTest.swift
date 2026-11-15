#if DEBUG
import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import MVCommands
import MVFoundation
import MVIO
import MVReading
import MVServices

/// 文件操作控制器、撤销重做、进度取消、错误条、永久删除确认与启动恢复的自检（`-MVFileOpsSelfTest YES`）。
@MainActor
final class FileOpsSelfTest {
    static let launchKey = "MVFileOpsSelfTest"
    static var isRequested: Bool {
        guard let raw = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return !["0", "no", "false"].contains(raw.lowercased())
    }
    private static var recoveryRootURL: URL?, recoverySourceURL: URL?, recoveryTargetURL: URL?
    private let app: AppDelegate, log = SelfTestLog(), fm = FileManager.default
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewFileOpsSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var targetWindow: NSWindow?

    static func prepareStartupRecoveryIfNeeded(supportDirectory: URL) async {
        guard isRequested, recoveryRootURL == nil else { return }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewFileOpsRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        UserDefaults.standard.set(true, forKey: "NSAllowMultipleDrags")
        if UserDefaults.standard.string(forKey: SelfTest.outputKey) == nil,
           let raw = UserDefaults.standard.string(forKey: launchKey),
           !["1", "yes", "true"].contains(raw.lowercased()) {
            UserDefaults.standard.set(raw, forKey: SelfTest.outputKey)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("FAIL 文件操作自检总超时（60s）"); fflush(stdout); _Exit(2)
        }
        let test = FileOpsSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) { self.app = app }

    private func run() async {
        TestPresentation.activateIfAllowed()
        guard let services = app.services, let fileOps = app.fileOps, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "文件操作自检需要真实服务、控制器和窗口"); exit(log.summarize())
        }
        targetWindow = window; window.setContentSize(NSSize(width: 1200, height: 800))
        do { try await runChecks(controller: controller, window: window, services: services, fileOps: fileOps) }
        catch { log.check(false, "文件操作自检异常：\(error)") }
        try? fm.removeItem(at: temporary)
        if let recoveryRoot = Self.recoveryRootURL { try? fm.removeItem(at: recoveryRoot) }
        await services.shutdown()
        exit(log.summarize())
    }

    private func runChecks(controller: ReaderWindowController, window: NSWindow, services: CoreServices, fileOps: FileOperationController) async throws {
        let msg = controller.content.statusBar.message ?? ""
        log.check(msg == "上次中断的 1 次移动已完成", "C2.5 启动恢复后状态栏显示完成提示：\(msg)")
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
        log.check(undoTitle.contains("撤销") && undoTitle.contains("移动“001.png”"), "C2.1 撤销菜单标题写明操作和对象：\(undoTitle)")
        for round in 1...2 {
            await sendKey(kVK_ANSI_Z, [.command])
            await until("第 \(round) 轮 ⌘Z 完成") { !fileOps.isBusy && self.exists(book001) }
            log.check(exists(book001) && !exists(target001), "C2.1 第 \(round) 轮 ⌘Z 后文件系统回到操作前")
            let redoTitle = editMenu(action: #selector(ReaderWindow.redo(_:))).title
            log.check(redoTitle.contains("重做") && redoTitle.contains("移动“001.png”"), "C2.1 第 \(round) 轮 ⌘Z 后重做菜单标题写明操作和对象：\(redoTitle)")
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
        log.check(bannerText.contains("missing.png") && bannerText.contains("2 项中 1 项没有完成"), "C2.4 错误条列出失败文件名与原因：\(bannerText)")
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
        log.snapshot(sheet1, "fileops-permanent-delete")
        await click(sheet1.cancelButton, in: sheet1)
        await until("取消表单收起") { window.attachedSheet == nil }
        log.check(exists(tempFileURL), "C2.4c 取消永久删除时文件保持原状")
        fileOps.handleResult(injected, operation: .delete([tempLoc]), title: "删除“temp-permanent.png”", origin: FileOrigin(window: controller))
        await settle()
        guard let sheet2 = window.attachedSheet as? PermanentDeleteSheet else { return log.check(false, "C2.4c 第二次未弹出永久删除确认表单") }
        await click(sheet2.confirmButton, in: sheet2)
        await until("确认永久删除完成") { window.attachedSheet == nil && !fileOps.isBusy && !self.exists(tempFileURL) }
        log.check(!exists(tempFileURL) && fileOps.undoManager.undoActionName == previousUndoName, "C2.4c 确认后临时文件被永久删除且不进入撤销历史")
        try await runCommandChecks(controller: controller, window: window, services: services, fileOps: fileOps, bookDir: bookDir, targetDir: targetDir, targetLoc: targetLoc)
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
        renameSheet.setInputText("001.png")
        await click(renameSheet.confirmButton, in: renameSheet)
        await until("重名错误显示") { !renameSheet.errorRow.isHidden }
        log.check(renameSheet.errorLabel.stringValue == "这个文件夹里已有“001.png”。" && !renameSheet.confirmButton.isEnabled, "C2.6 重名显示表单内红字错误且按钮禁用：\(renameSheet.errorLabel.stringValue)")
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
        log.check(itemEnabled(ctx, "删除") == false && itemEnabled(ctx, "重命名…") == false && itemEnabled(ctx, "移动到") == false && itemEnabled(ctx, "复制到") == false, "C2.8 压缩包右键菜单中删除、重命名、移动到、复制到灰掉")
        log.check(itemEnabled(ctx, "复制") == true && itemEnabled(ctx, "复制路径") == true && itemEnabled(ctx, "在 Finder 中显示") == true && itemEnabled(ctx, "用指定应用打开") == true, "C2.8 压缩包右键菜单中复制、复制路径、在 Finder 中显示、用指定应用打开可用")
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
        await until("打开 bookA 且书架列出两本书") { controller.session.book?.location.name == "bookA" && controller.session.book?.pages.count == 3 && shelfView.items.map(\.name) == ["bookA", "bookB"] }
        controller.session.go(.index(1)); await settle()
        let bookALoc = try await services.sources.location(for: bookADir), outLoc = try await services.sources.location(for: outDir)
        let bookAEntry = Entry(identity: ContentIdentity(location: bookALoc, size: 0, modificationNanos: 0), name: "bookA", kind: .directory)
        _ = await fileOps.perform(.rename(bookALoc, to: "bookA-renamed"), title: "重命名“bookA”", origin: FileOrigin(window: controller, items: [bookAEntry]))
        await until("bookA 改名后会话与书架刷新") { controller.session.book?.location.name == "bookA-renamed" && shelfView.items.map(\.name) == ["bookA-renamed", "bookB"] }
        log.check(controller.session.book?.location.name == "bookA-renamed" && controller.session.currentPage == 1 && shelfView.items.map(\.name) == ["bookA-renamed", "bookB"], "C2.10b 当前书改名后在新位置继续、页码不变且书架刷新")
        let renamedLoc = try await services.sources.location(for: shelfDir.appending(path: "bookA-renamed"))
        let renamedEntry = Entry(identity: ContentIdentity(location: renamedLoc, size: 0, modificationNanos: 0), name: "bookA-renamed", kind: .directory)
        await fileOps.transfer(origin: FileOrigin(window: controller, items: [renamedEntry]), into: outLoc, mode: .move)
        await until("当前书移走后打开下一本 bookB 且书架刷新") { controller.session.book?.location.name == "bookB" && controller.session.book?.pages.count == 3 && shelfView.items.map(\.name) == ["bookB"] }
        log.check(controller.session.book?.location.name == "bookB" && shelfView.items.map(\.name) == ["bookB"], "C2.10b 把当前书移到另一个文件夹后打开书架下一本且书架刷新")

        // C2.10c：表格多选右键规则，以及重命名表单打开后改变列表选中项，提交时仍改原来那一项。
        pageList.setStyle(.table); await settle()
        listView.selectRows(IndexSet([0, 2]))
        log.check(itemEnabled(listView.contextMenu(forItemAt: 2), "重命名…") == false && itemEnabled(listView.contextMenu(forItemAt: 1), "重命名…") == true, "C2.10c 右键已选中项取全部多选（重命名灰掉），右键未选中项只取该项（重命名可用）")
        listView.selectRows(IndexSet(integer: 0)); window.makeFirstResponder(listView); await settle()
        fileOps.presentRename(origin: controller.fileOrigin()); await settle()
        guard let snapSheet = window.attachedSheet as? RenameSheet else { return log.check(false, "C2.10c 未弹出重命名表单") }
        listView.selectRows(IndexSet(integer: 1)); await settle()
        snapSheet.setInputText("001-snap.png")
        await click(snapSheet.confirmButton, in: snapSheet)
        await until("快照重命名完成") { window.attachedSheet == nil && !fileOps.isBusy && self.exists(bookBDir.appending(path: "001-snap.png")) }
        log.check(exists(bookBDir.appending(path: "001-snap.png")) && exists(bookBDir.appending(path: "002.png")) && !exists(bookBDir.appending(path: "001.png")), "C2.10c 重命名表单打开后改变页面列表选中项，提交时仍修改原快照项 001.png")

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
        await until("C2.11 打开文件夹书") { controller.session.book?.location.name == "book" && controller.session.book?.pages.count == 3 && listView.items.count == 3 }
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

    private func sha256(of url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
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
            NSApp.postEvent(event(.leftMouseUp, at: end), atStart: false)
            NSApp.sendEvent(event(.leftMouseDragged, at: end))
        } else {
            NSApp.postEvent(event(.leftMouseDragged, at: end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, at: end), atStart: false)
            NSApp.sendEvent(event(.leftMouseDown, at: start))
        }
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
        window.makeKey()
        window.contentView?.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false); NSApp.sendEvent(event(.leftMouseDown))
        try? await Task.sleep(for: .milliseconds(80))
    }
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
