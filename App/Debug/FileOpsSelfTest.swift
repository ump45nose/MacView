#if DEBUG
import AppKit
import Carbon.HIToolbox
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
    private static var recoveryRootURL: URL?, recoverySourceURL: URL?, recoveryTargetURL: URL?
    private let app: AppDelegate, log = SelfTestLog(), fm = FileManager.default
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewFileOpsSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var targetWindow: NSWindow?

    static func prepareStartupRecoveryIfNeeded(supportDirectory: URL) async {
        guard UserDefaults.standard.bool(forKey: launchKey), recoveryRootURL == nil else { return }
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
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
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
        window.contentView?.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false); NSApp.sendEvent(event(.leftMouseDown))
        try? await Task.sleep(for: .milliseconds(80))
    }
}
#endif
