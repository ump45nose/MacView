#if DEBUG
import AppKit
import Carbon.HIToolbox
import CryptoKit
import Darwin
import IOSurface
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVLibraryData
import MVPlugins
import MVReading
import MVScripting
import MVServices
import MVSettings
import WebKit

/// 用户数据导出／导入自检（`-MVDataTransferSelfTest dialogs|export|import-verify|revert-verify|fresh|fresh-verify|errors|rollback|rollback-verify`）。
@MainActor
final class DataTransferSelfTest {
    static let launchKey = "MVDataTransferSelfTest"
    private static let archiveKey = "MVDataTransferArchive"
    private static let booksKey = "MVDataTransferBooks"
    private static let repoKey = "MVDataTransferRepo"
    private static let webdavURLKey = "MVDataTransferWebDAVURL"
    private static let oldPIDKey = "MVDataTransferOldPID"
    private static let stateFileKey = "MVDataTransferStateFile"
    private static let doneFileKey = "MVDataTransferDoneFile"

    nonisolated private static let expectedSettingMaxDecode = 6144
    nonisolated private static let mutatedSettingMaxDecode = 4096
    nonisolated private static let expectedBookmarkFolder = "精选画集"
    nonisolated private static let expectedPlaylistName = "收藏页列表"
    nonisolated private static let expectedProfileName = "导入测试配置"
    nonisolated private static let expectedPathRuleName = "导入路径规则"
    nonisolated private static let expectedSchemeName = "导入布局方案"
    nonisolated private static let expectedScriptName = "dt-hello.js"
    nonisolated private static let expectedExtCmdID = "ext.dt.echo"
    nonisolated private static let expectedExtCmdName = "导出自检命令"
    nonisolated private static let expectedWebDAVSourceName = "自检网盘"
    nonisolated private static let expectedNoteText = "导出导入自检笔记内容"

    private struct SharedState: Codable {
        var webdavSourceID: UUID = UUID()
        var localBookAPath: String = ""
        var localBookBPath: String = ""
        var preRollbackHashes: [String: String]?
        var accumulatedLog: [String] = []
        var priorFailures: Int = 0
    }

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private var logLines: [String] = []
    private var localFailures = 0
    private var eventNumber = 1

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mode.isEmpty else { return }
        let test = DataTransferSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
    }

    private func record(_ condition: Bool, _ message: String) {
        if !condition { localFailures += 1 }
        log.check(condition, message)
        logLines.append("\(condition ? "PASS" : "FAIL") \(message)")
    }

    private func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        TestPresentation.activateIfAllowed()
        if TestPresentation.activationAllowed {
            for _ in 0..<30 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let services = app.services, let dt = app.dataTransfer else {
            record(false, "数据迁移自检需要真实服务与 DataTransferController")
            finishAndExit()
            return
        }
        if let window = app.controllers.first?.window {
            TestPresentation.place(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        do {
            switch mode {
            case "dialogs": try await runDialogs(dt: dt); return
            case "dialogs-restarted": await runDialogsRestarted(dt: dt)
            case "export": try await runExport(services: services, dt: dt); return
            case "import-verify": try await runImportVerify(services: services, dt: dt); return
            case "revert-verify": try await runRevertVerify(services: services, dt: dt)
            case "fresh": try await runFresh(dt: dt); return
            case "fresh-verify": try await runFreshVerify(services: services, dt: dt)
            case "errors": try await runErrors(dt: dt)
            case "rollback": try await runRollback(dt: dt); return
            case "rollback-verify": try await runRollbackVerify(dt: dt)
            default: record(false, "未知模式：\(mode)")
            }
        } catch {
            record(false, "模式 \(mode) 抛出异常：\(error)")
        }
        finishAndExit()
    }

    private func finishAndExit() {
        var state = loadState()
        let priorFailures = state?.priorFailures ?? 0
        if var s = state {
            s.accumulatedLog.append(contentsOf: logLines)
            s.priorFailures = priorFailures + localFailures
            try? saveState(s)
            state = s
        }
        if priorFailures > 0 {
            log.check(false, "前序接力进程存在 \(priorFailures) 项失败")
        }
        let totalFailures = priorFailures + Int(log.summarize()) - (priorFailures > 0 ? 1 : 0)
        if let donePath = UserDefaults.standard.string(forKey: Self.doneFileKey) {
            let summary = "SELFTEST \(totalFailures == 0 ? "OK" : "FAILED \(totalFailures)") commit=\(BuildIdentity.commit ?? "无") cdhash=\(BuildIdentity.cdhash ?? "无")"
            let lines = (state?.accumulatedLog ?? logLines) + [summary]
            try? lines.joined(separator: "\n").write(toFile: donePath, atomically: true, encoding: .utf8)
        }
        exit(Int32(totalFailures))
    }

    private func relayArgs(nextMode: String) -> [String] {
        var args = [
            "-\(Self.launchKey)", nextMode,
            "-\(Self.oldPIDKey)", String(getpid()),
            "-\(AppDelegate.supportDirectoryKey)", app.supportDirectory.path,
            "-\(AppDelegate.cacheDirectoryKey)", app.cacheDirectory.path,
            "-\(DockCoordinator.layoutFileKey)", DockCoordinator.defaultFileURL().path,
        ]
        for key in [Self.archiveKey, Self.booksKey, Self.repoKey, Self.webdavURLKey, Self.stateFileKey, Self.doneFileKey, SelfTest.outputKey, "MVAppearance"] {
            if let value = UserDefaults.standard.string(forKey: key) { args += ["-\(key)", value] }
        }
        if TestPresentation.activationAllowed { args += ["-\(TestPresentation.activateKey)", "YES"] }
        if let first = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first {
            args += ["-AppleLanguages", "(\(first))"]
        }
        return args
    }

    private func persistLogsBeforeRelaunch() {
        if var state = loadState() {
            state.accumulatedLog.append(contentsOf: logLines)
            state.priorFailures += localFailures
            try? saveState(state)
            logLines.removeAll()
            localFailures = 0
        }
    }

    private func triggerImportAndRelaunch(dt: DataTransferController, archive: URL, nextMode: String, label: String) async {
        persistLogsBeforeRelaunch()
        dt.debugOpenSource = { archive }
        dt.debugRelaunchArguments = { [weak self] in self?.relayArgs(nextMode: nextMode) ?? [] }
        dt.debugOnSheetPresented = { tag, _, alert in
            guard tag == "import-confirm", let alert else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                alert.buttons.dropFirst().first?.performClick(nil)
            }
        }
        dt.importUserData()
        try? await Task.sleep(for: .seconds(15))
        record(false, "\(label) 导入后超时未退出重启")
        finishAndExit()
    }

    @discardableResult
    private func dismissImportDoneAlert(dt: DataTransferController, snapshotName: String? = nil) async -> (shown: Bool, text: String) {
        let shown = await waitUntil(timeoutMs: 5000) { dt.debugActiveAlert?.tag == "import-done" }
        var text = ""
        if let alert = dt.debugActiveAlert?.alert {
            await settle(250)
            text = allText(in: alert)
            if let snapshotName { snapshotSheet(alert.window, snapshotName) }
            alert.buttons.first?.performClick(nil)
            _ = await waitUntil(timeoutMs: 3000) { dt.debugActiveAlert == nil }
        }
        return (shown, text)
    }

    // MARK: - C2.11 dialogs（真实面板、真实确认框、真实 NSApp.sendEvent）

    private func runDialogs(dt: DataTransferController) async throws {
        guard let window = app.controllers.first?.window,
              let exportItem = findFileMenuItem(command: .dataExport),
              let importItem = findFileMenuItem(command: .dataImport) else {
            record(false, "C2.11 缺少主窗口或「文件」菜单项")
            finishAndExit()
            return
        }
        let archiveURL = try ensureSampleArchiveForDialogs()

        // 1. 菜单打开真实 NSSavePanel，检查默认名、忙碌期间禁用与拒绝重入
        var savePanelRef: NSSavePanel?
        dt.debugOnSheetPresented = { tag, sheet, _ in if tag == "save-panel" { savePanelRef = sheet as? NSSavePanel } }
        triggerMenuItem(exportItem)
        let saveAppeared = await waitUntil(timeoutMs: 4000) { savePanelRef != nil || window.attachedSheet is NSSavePanel }
        let savePanel = savePanelRef ?? (window.attachedSheet as? NSSavePanel)
        let actualName = savePanel?.nameFieldStringValue ?? ""
        record(saveAppeared && actualName == DataTransferController.defaultExportFileName(), "C2.11 真实存储面板打开且默认名正确：\(actualName)")

        validateFileMenu()
        let disabledWhileSave = !exportItem.isEnabled && !importItem.isEnabled && dt.isBusy
        dt.exportUserData(); dt.importUserData(); await settle(150)
        record(disabledWhileSave && window.attachedSheet === savePanel, "C2.11 存储面板期间两项禁用且再次触发被拒绝")
        if let savePanel {
            sendKey(kVK_Escape, chars: "\u{1b}", to: savePanel)
            if !(await waitUntil(timeoutMs: 1200) { !dt.isBusy }) { savePanel.cancel(nil) }
        }
        record(await waitUntil(timeoutMs: 3000) { !dt.isBusy && window.attachedSheet == nil }, "C2.11 存储面板取消后恢复空闲")

        // 2. 菜单打开真实 NSOpenPanel，核对单选 .macviewdata、忙碌禁用与拒绝重入
        dt.debugOpenPanelInitialDirectory = archiveURL.deletingLastPathComponent()
        var openPanelRef: NSOpenPanel?
        dt.debugOnSheetPresented = { tag, sheet, _ in if tag == "open-panel" { openPanelRef = sheet as? NSOpenPanel } }
        triggerMenuItem(importItem)
        let openAppeared = await waitUntil(timeoutMs: 4000) { openPanelRef != nil || window.attachedSheet is NSOpenPanel }
        let openPanel = openPanelRef ?? (window.attachedSheet as? NSOpenPanel)
        validateFileMenu()
        let disabledWhileOpen = !exportItem.isEnabled && !importItem.isEnabled && dt.isBusy
        dt.exportUserData(); dt.importUserData(); await settle(150)
        let openConfigOK = openPanel?.allowsMultipleSelection == false && openPanel?.canChooseFiles == true
            && openPanel?.canChooseDirectories == false && openPanel?.allowedContentTypes.isEmpty == false
        record(openAppeared && openConfigOK && disabledWhileOpen && window.attachedSheet === openPanel,
               "C2.11 真实打开面板仅允许单选 .macviewdata，且期间两项禁用、拒绝重入")
        openPanel?.cancel(nil)
        _ = await waitUntil(timeoutMs: 3000) { !dt.isBusy && window.attachedSheet == nil }

        // 3. 真实确认框（事件走 NSApp.sendEvent）：按回车等于「取消」，删暂存不重启
        //    （NSOpenPanel 为系统 XPC NSRemoteView，进程内合成事件无法操作远端文件列表，此处提供文件 URL 进入真实确认框。）
        dt.debugOpenSource = { archiveURL }
        var confirmAlertRef: NSAlert?
        dt.debugOnSheetPresented = { tag, _, alert in if tag == "import-confirm" { confirmAlertRef = alert } }
        var relaunchCalls = 0
        dt.debugInterceptRelaunch = { _ in relaunchCalls += 1; return true }
        triggerMenuItem(importItem)
        let confirmAppeared1 = await waitUntil(timeoutMs: 6000) { confirmAlertRef != nil }
        validateFileMenu()
        let disabledWhileConfirm = !exportItem.isEnabled && !importItem.isEnabled && dt.isBusy
        dt.exportUserData(); dt.importUserData()
        record(confirmAppeared1 && disabledWhileConfirm, "C2.11 真实确认框弹出，期间两项禁用、拒绝重入")
        if let alert = confirmAlertRef {
            await settle(200)
            let isDefaultCancel = alert.window.defaultButtonCell === alert.buttons.first?.cell
                && alert.buttons.first?.title == String(localized: "取消")
                && (alert.buttons.dropFirst().first?.keyEquivalent ?? "") == ""
            sendKey(kVK_Return, chars: "\r", to: alert.window)
            if !(await waitUntil(timeoutMs: 1200) { !dt.isBusy }), !NSApp.isActive, isDefaultCancel {
                (alert.window.defaultButtonCell?.controlView as? NSButton)?.performClick(nil)
            }
        }
        let cancelledClean = await waitUntil(timeoutMs: 4000) { !dt.isBusy && window.attachedSheet == nil }
        let stagingDeleted = !FileManager.default.fileExists(atPath: app.supportDirectory.appending(path: ".import-staging").path)
        record(cancelledClean && stagingDeleted && relaunchCalls == 0, "C2.11 确认框按回车等于「取消」，暂存目录被删、不重启(active=\(NSApp.isActive))")

        // 4. 再次打开真实确认框并经 NSApp.sendEvent 点击「导入并重启」→ 触发真实重启
        confirmAlertRef = nil
        dt.debugInterceptRelaunch = nil
        try saveState(SharedState())
        dt.debugRelaunchArguments = { [weak self] in self?.relayArgs(nextMode: "dialogs-restarted") ?? [] }
        triggerMenuItem(importItem)
        record(await waitUntil(timeoutMs: 6000) { confirmAlertRef != nil }, "C2.11 第二次打开真实确认框准备点击「导入并重启」")
        persistLogsBeforeRelaunch()
        if let alert = confirmAlertRef, alert.buttons.count >= 2 {
            await settle(200)
            clickButton(alert.buttons[1], in: alert.window)
            try? await Task.sleep(for: .seconds(10))
            record(false, "C2.11 点击「导入并重启」后超时未退出")
        } else {
            record(false, "C2.11 找不到确认框「导入并重启」按钮")
        }
        finishAndExit()
    }

    private func runDialogsRestarted(dt: DataTransferController) async {
        let oldPID = pid_t(UserDefaults.standard.integer(forKey: Self.oldPIDKey))
        record(oldPID > 0 && kill(oldPID, 0) == -1 && errno == ESRCH, "C2.11 点「导入并重启」后真正重启，旧进程 pid=\(oldPID) 已退出")
        await dismissImportDoneAlert(dt: dt)
    }

    // MARK: - export（C2.1, C2.2, C2.3, C2.4 发起）

    private func runExport(services: CoreServices, dt: DataTransferController) async throws {
        guard let first = app.controllers.first, first.window != nil else {
            record(false, "缺少主窗口"); finishAndExit(); return
        }
        let titles = fileMenuItemTitles()
        let menuOrderOK: Bool = {
            guard let r = titles.firstIndex(of: app.catalog.title(of: .recycleEmpty)),
                  let e = titles.firstIndex(of: app.catalog.title(of: .dataExport)),
                  let i = titles.firstIndex(of: app.catalog.title(of: .dataImport)) else { return false }
            return e == r + 2 && i == e + 1 && titles[r + 1] == "-"
        }()
        record(menuOrderOK, "C2.1 「文件」菜单在「清空回收目录…」后含分隔线与导出／导入两项")

        // 构造完整的 16 项用户数据（C2.5 全量）
        let booksRoot = booksDirectory()
        let bookA = try makeBook(in: booksRoot, name: "book-a", count: 5)
        let bookB = try makeBook(in: booksRoot, name: "book-b", count: 4)
        let bookALoc = try await services.sources.location(for: bookA)
        let bookBLoc = try await services.sources.location(for: bookB)
        let missingLoc = Location(root: bookALoc.root, layers: [["Users", "nonexistent-macview-origin", "MissingBook"]])

        first.open([bookA])
        _ = await waitUntil(timeoutMs: 6000) { first.session.book?.isEnumerated == true && !first.session.frames.isEmpty }
        first.session.go(.index(2))
        _ = await waitUntil(timeoutMs: 4000) { first.session.currentPage == 2 }
        if let tab = app.newTab(beside: first) {
            tab.open([bookB])
            _ = await waitUntil(timeoutMs: 6000) { tab.session.book?.isEnumerated == true && !tab.session.frames.isEmpty }
            tab.session.go(.index(1))
            _ = await waitUntil(timeoutMs: 4000) { tab.session.currentPage == 1 }
        }
        first.window?.tabGroup?.selectedWindow = first.window
        first.window?.makeKeyAndOrderFront(nil)

        if let library = services.library {
            let folderID = try await library.addBookmarkFolder(named: Self.expectedBookmarkFolder, into: nil, at: nil)
            _ = try await library.addBookmarks([bookALoc, missingLoc], into: folderID, at: nil)
            let playlistID = try await library.createPlaylist(named: Self.expectedPlaylistName)
            if let page0 = first.session.book?.pages.first { _ = try await library.addItems([page0.entry], to: playlistID) }
            try await library.recordOpened(bookALoc, at: Date())
            try await library.recordOpened(bookBLoc, at: Date())
        }
        try await services.settings.updateGlobal { $0.maxDecodeLongSide = Self.expectedSettingMaxDecode }
        try await services.keyBindings?.update {
            $0.bindings.append(KeyBinding(sequence: [KeyChord("k", modifiers: [.command, .option])], command: .pageJump, scope: .viewer))
        }
        try await services.menus?.update { $0.viewerContextMenu = [.command(.playlistAddCurrent), .command(.pageJump)] }
        try await services.settings.updateProfiles {
            $0.append(DisplayProfile(name: Self.expectedProfileName, settings: BookSettings(direction: .rightToLeft)))
        }
        try await services.settings.updatePathRules {
            $0.append(PathRule(name: Self.expectedPathRuleName, prefix: bookALoc, settings: BookSettings(pageMode: .double)))
        }
        try await app.dock?.saveScheme(named: Self.expectedSchemeName, from: first.dock)

        if let scriptsDir = services.scriptLibrary?.directory {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
            let script = "// @name 导出自检脚本\n// @command dt.hello\nmv.toast(\"hello\");\n"
            try Data(script.utf8).write(to: scriptsDir.appending(path: Self.expectedScriptName), options: .atomic)
        }
        try await services.externalCommands?.update {
            $0.commands.append(ExternalCommand(id: Self.expectedExtCmdID, name: Self.expectedExtCmdName, kind: .shell, arguments: "echo ok"))
        }

        let webdavSourceID = UUID()
        if let pluginLib = services.pluginLibrary, let pluginSettings = services.pluginSettings, let pluginSecrets = services.pluginSecrets {
            try copyExamplePlugin("page-notes", to: pluginLib.directory)
            try copyExamplePlugin("webdav", to: pluginLib.directory)
            let davURL = UserDefaults.standard.string(forKey: Self.webdavURLKey) ?? "http://127.0.0.1:8080/"
            try await pluginSecrets.set(["password": "davpass"], for: webdavSourceID)
            try await pluginSettings.update { file in
                file.plugins["page-notes"] = PluginState(enabled: true, grantedPermissions: [.commands])
                file.plugins["webdav"] = PluginState(enabled: true, grantedPermissions: [])
                file.sources = [SourceInstance(id: webdavSourceID, plugin: "webdav", type: "webdav", name: Self.expectedWebDAVSourceName, values: ["url": davURL, "user": "davuser"])]
            }
            let notesPanelID = PluginCoordinator.panelID(plugin: "page-notes", panel: "notes")
            _ = await waitUntil(timeoutMs: 5000) {
                DockPanels.type(notesPanelID) != nil && app.plugins?.enabledPlugins.contains(where: { $0.id == "webdav" }) == true
            }
            app.dock?.togglePanel(DockPanels.type(notesPanelID)!, in: first.dock)
            if let notesPanel = await waitForWebPanel(notesPanelID, in: first.dock) {
                _ = await waitUntil(timeoutMs: 4000) { notesPanel.debugIsPageReady }
                if let page = first.session.book?.pages[safe: first.session.currentPage] {
                    try await services.scriptStorage?.set("plugin:page-notes", "note:\(ScriptLocationCodec.token(for: page.id))", .string(Self.expectedNoteText))
                }
            }
        }
        await settle(400)

        // C2.2: 导出（进度表单、主线程计时器、两项禁用、③ 密码警示 + 截图、0600）
        let archiveURL = archiveFileURL()
        dt.debugSaveDestination = { archiveURL }
        var mainTimerTicks = 0, progressVisible = false, menuDisabled = false
        dt.debugBeforeExportArchive = { [weak self] in
            guard let self else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { mainTimerTicks += 1 } }
            RunLoop.main.add(timer, forMode: .common)
            progressVisible = dt.debugProgressWindow?.isVisible == true
            self.validateFileMenu()
            menuDisabled = self.findFileMenuItem(command: .dataExport)?.isEnabled == false
                && self.findFileMenuItem(command: .dataImport)?.isEnabled == false && dt.isBusy
            try? await Task.sleep(for: .milliseconds(120))
            timer.invalidate()
        }
        var exportDoneText = ""
        dt.debugOnSheetPresented = { [weak self] tag, sheet, alert in
            guard let self, tag == "export-done", let alert else { return }
            Task { @MainActor in
                await self.settle(200)
                exportDoneText = self.allText(in: alert)
                self.snapshotSheet(sheet, "03-export-done-\(self.variantTag)")
                alert.buttons.first?.performClick(nil)
            }
        }
        dt.exportUserData()
        let exportOK = await waitUntil(timeoutMs: 15000) { !dt.isBusy && FileManager.default.fileExists(atPath: archiveURL.path) }
        dt.debugBeforeExportArchive = nil; dt.debugOnSheetPresented = nil
        let mode0600 = posixPermissions(of: archiveURL) == 0o600
        let hasPwdWarn = exportDoneText.contains("来源密码") || exportDoneText.localizedCaseInsensitiveContains("source passwords")
        record(menuDisabled, "C2.1 导出进行中两项菜单禁用")
        record(exportOK && progressVisible && mainTimerTicks >= 3 && hasPwdWarn && mode0600,
               "C2.2 导出完成：进度表单可见(\(progressVisible))、主线程计时器触发(\(mainTimerTicks))、含密码警示(\(hasPwdWarn))、权限0600(\(mode0600))")

        // 修改本机设置，供 C2.3 / C2.5 / C2.7 对照
        try await services.settings.updateGlobal { $0.maxDecodeLongSide = Self.mutatedSettingMaxDecode }
        await settle(200)

        // C2.3: 导入确认框 + 取消删暂存不改数据
        dt.debugOpenSource = { archiveURL }
        var confirmText = "", defaultIsCancel = false
        dt.debugOnSheetPresented = { [weak self] tag, sheet, alert in
            guard let self, tag == "import-confirm", let alert else { return }
            Task { @MainActor in
                await self.settle(200)
                confirmText = self.allText(in: alert)
                let firstTitle = alert.buttons.first?.title ?? ""
                let k0 = alert.buttons.first?.keyEquivalent ?? ""
                let k1 = alert.buttons.dropFirst().first?.keyEquivalent ?? ""
                defaultIsCancel = firstTitle == String(localized: "取消") && alert.window.defaultButtonCell === alert.buttons.first?.cell && (k0 == "\r" || !NSApp.isActive) && k1 == ""
                self.snapshotSheet(sheet, "05-import-confirm-\(self.variantTag)")
                alert.buttons.first?.performClick(nil)
            }
        }
        dt.importUserData()
        _ = await waitUntil(timeoutMs: 10000) { !dt.isBusy }
        dt.debugOnSheetPresented = nil
        let stagingGone = !FileManager.default.fileExists(atPath: app.supportDirectory.appending(path: ".import-staging").path)
        let unchanged = await services.settings.global().maxDecodeLongSide == Self.mutatedSettingMaxDecode
        let metaOK = confirmText.contains("MacView") && confirmText.contains("before-import.macviewdata")
            && (confirmText.contains("历史") || confirmText.contains("history"))
            && (confirmText.contains("书签") || confirmText.contains("bookmark"))
            && (confirmText.contains("播放列表") || confirmText.contains("playlist"))
            && (confirmText.contains("脚本") || confirmText.contains("script"))
            && (confirmText.contains("插件") || confirmText.contains("plug-in"))
        record(metaOK && defaultIsCancel && stagingGone && unchanged,
               "C2.3 导入确认框含元数据与5项数量、默认按钮为取消(\(defaultIsCancel))，取消后暂存已删(\(stagingGone))且数据不变")

        try saveState(SharedState(webdavSourceID: webdavSourceID, localBookAPath: bookA.path, localBookBPath: bookB.path))
        await triggerImportAndRelaunch(dt: dt, archive: archiveURL, nextMode: "import-verify", label: "C2.4")
    }

    // MARK: - import-verify（C2.4, C2.5, C2.7 发起）& revert-verify（C2.7）

    private func runImportVerify(services: CoreServices, dt: DataTransferController) async throws {
        guard let state = loadState() else { record(false, "import-verify 缺少状态文件"); finishAndExit(); return }
        let oldPID = pid_t(UserDefaults.standard.integer(forKey: Self.oldPIDKey))
        record(oldPID > 0 && kill(oldPID, 0) == -1 && errno == ESRCH,
               "C2.4 旧进程(pid=\(oldPID))已退出后新进程才经 LaunchServices 启动(active=\(NSApp.isActive))")
        let done = await dismissImportDoneAlert(dt: dt, snapshotName: "07-import-done-\(variantTag)")
        record(done.shown && done.text.contains("before-import.macviewdata"), "C2.5 重启后显示 ⑦ 导入完成提示与备份路径")

        try await verifyFullRestoredDataset(services: services, state: state, checkMissingBookmarkDimmed: false, label: "C2.5")

        let backupURL = UserDataArchive.backupURL(for: DataTransferController.locations(supportDirectory: app.supportDirectory))
        record(FileManager.default.fileExists(atPath: backupURL.path), "C2.7 自动备份文件存在")
        await triggerImportAndRelaunch(dt: dt, archive: backupURL, nextMode: "revert-verify", label: "C2.7")
    }

    private func runRevertVerify(services: CoreServices, dt: DataTransferController) async throws {
        await dismissImportDoneAlert(dt: dt)
        let maxDecode = await services.settings.global().maxDecodeLongSide
        record(maxDecode == Self.mutatedSettingMaxDecode, "C2.7 导入自动备份后回到导入前状态(maxDecodeLongSide=\(maxDecode))")
    }

    // MARK: - fresh / fresh-verify（C2.6）

    private func runFresh(dt: DataTransferController) async throws {
        let archiveURL = archiveFileURL()
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            record(false, "C2.6 找不到导出文件 \(archiveURL.path)"); finishAndExit(); return
        }
        await triggerImportAndRelaunch(dt: dt, archive: archiveURL, nextMode: "fresh-verify", label: "C2.6")
    }

    private func runFreshVerify(services: CoreServices, dt: DataTransferController) async throws {
        guard let state = loadState() else { record(false, "fresh-verify 缺少状态文件"); return }
        await dismissImportDoneAlert(dt: dt)
        try await verifyFullRestoredDataset(services: services, state: state, checkMissingBookmarkDimmed: true, label: "C2.6")
    }

    // MARK: - errors（C2.8）& rollback（C2.9）

    private func runErrors(dt: DataTransferController) async throws {
        let scratch = TestPresentation.scratchDirectory("dt-errors")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let notArchive = scratch.appending(path: "old-backup.macviewdata")
        try createZip(files: ["readme.txt": Data("hello".utf8)], to: notArchive)
        let damaged = scratch.appending(path: "damaged.macviewdata")
        let damagedManifest = #"{"format":1,"appVersion":"0.1.0","appBuild":"1","createdAt":"2026-11-25T12:00:00Z","host":"MacPro","summary":{"history":0,"bookmarks":0,"playlists":0,"scripts":0,"plugins":0},"items":["library.sqlite"]}"#
        try createZip(files: ["manifest.json": Data(damagedManifest.utf8), "data/library.sqlite": Data("not-a-sqlite".utf8)], to: damaged)
        let newer = scratch.appending(path: "newer.macviewdata")
        let newerManifest = #"{"format":2,"appVersion":"9.0.0","appBuild":"9","createdAt":"2026-11-25T12:00:00Z","host":"MacPro","summary":{"history":0,"bookmarks":0,"playlists":0,"scripts":0,"plugins":0},"items":[]}"#
        try createZip(files: ["manifest.json": Data(newerManifest.utf8)], to: newer)

        for c in app.controllers { await c.session.flush() }
        await app.flushSessionStore(); await app.dock?.flush(); try? await app.services?.flushPersistentState()
        let beforeHashes = try directoryHashes(of: app.supportDirectory)
        var relaunched = false
        dt.debugInterceptRelaunch = { _ in relaunched = true; return true }

        for testCase in [
            (url: notArchive, shot: "06-import-error-not-archive", zh: "不是 MacView 导出的数据文件", en: "isn’t a MacView data file"),
            (url: damaged, shot: "06-import-error-damaged", zh: "library.sqlite", en: "library.sqlite"),
            (url: newer, shot: "06-import-error-newer", zh: "数据格式 2", en: "data format 2"),
        ] {
            var alertText = ""
            dt.debugOpenSource = { testCase.url }
            dt.debugOnSheetPresented = { [weak self] tag, sheet, alert in
                guard let self, tag == "import-error", let alert else { return }
                Task { @MainActor in
                    await self.settle(200)
                    alertText = self.allText(in: alert)
                    self.snapshotSheet(sheet, "\(testCase.shot)-\(self.variantTag)")
                    alert.buttons.first?.performClick(nil)
                }
            }
            dt.importUserData()
            _ = await waitUntil(timeoutMs: 8000) { !dt.isBusy }
            record(alertText.contains(testCase.zh) || alertText.contains(testCase.en),
                   "C2.8 坏文件 \(testCase.url.lastPathComponent) 显示对应原因：\(alertText.replacingOccurrences(of: "\n", with: " "))")
        }
        let afterHashes = try directoryHashes(of: app.supportDirectory)
        record(!relaunched && beforeHashes == afterHashes, "C2.8 三种坏文件均不重启且数据目录逐文件哈希不变")
    }

    private func runRollback(dt: DataTransferController) async throws {
        let archiveURL = archiveFileURL()
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            record(false, "C2.9 找不到有效归档 \(archiveURL.path)"); finishAndExit(); return
        }
        try await app.services?.settings.updateGlobal { $0.maxDecodeLongSide = 7777 }
        for c in app.controllers { await c.session.flush() }
        await app.flushSessionStore(); await app.dock?.flush(); try? await app.services?.flushPersistentState()
        try saveState(SharedState(preRollbackHashes: try directoryHashes(of: app.supportDirectory)))

        let locations = DataTransferController.locations(supportDirectory: app.supportDirectory)
        let staged = try await UserDataArchive.stage(archiveURL, for: locations, appValidators: DataTransferController.appValidators)
        try UserDataArchive.commitStaged(staged, for: locations)
        try FileManager.default.removeItem(at: app.supportDirectory.appending(path: ".import-staging/data/library.sqlite"))
        try AppRelauncher.relaunch(arguments: relayArgs(nextMode: "rollback-verify"))
        try? await Task.sleep(for: .seconds(15))
        record(false, "C2.9 注入失败重启超时")
        finishAndExit()
    }

    private func runRollbackVerify(dt: DataTransferController) async throws {
        guard let expectedHashes = loadState()?.preRollbackHashes else { record(false, "C2.9 缺少回滚前哈希快照"); return }
        let shown = await waitUntil(timeoutMs: 5000) { dt.debugActiveAlert?.tag == "import-rolled-back" }
        var text = ""
        if let alert = dt.debugActiveAlert?.alert {
            await settle(250)
            text = allText(in: alert)
            snapshotSheet(alert.window, "08-import-rolled-back-\(variantTag)")
            alert.buttons.first?.performClick(nil)
        }
        let maxDecode = await app.services?.settings.global().maxDecodeLongSide
        let settingsMatch = expectedHashes["settings.json"] == (try directoryHashes(of: app.supportDirectory))["settings.json"]
        record(shown && (text.contains("导入没有完成") || text.contains("Import Didn’t Finish")), "C2.9 替换失败重启后显示 ⑧ 提示")
        record(maxDecode == 7777 && settingsMatch, "C2.9 回滚后本机数据与导入前一致(maxDecode=\(maxDecode ?? -1), settingsHashMatch=\(settingsMatch))")
    }

    // MARK: - 公共核对（C2.5 & C2.6）

    private func verifyFullRestoredDataset(services: CoreServices, state: SharedState, checkMissingBookmarkDimmed: Bool, label: String) async throws {
        let bookALoc = try await services.sources.location(for: URL(fileURLWithPath: state.localBookAPath))
        let missingLoc = Location(root: bookALoc.root, layers: [["Users", "nonexistent-macview-origin", "MissingBook"]])

        let tabsOK = await waitUntil(timeoutMs: 8000) {
            app.controllers.count == 2
                && app.controllers.contains(where: { $0.session.book?.location.name == "book-a" && $0.session.currentPage == 2 })
                && app.controllers.contains(where: { $0.session.book?.location.name == "book-b" && $0.session.currentPage == 1 })
        }
        record(tabsOK, "\(label) 窗口、标签与书记忆页码一致")

        if let library = services.library {
            let folderFound = try await library.bookmarks().contains { node in
                if case let .folder(_, name, children) = node, name == Self.expectedBookmarkFolder {
                    return children.contains { if case let .book(_, loc, _) = $0 { loc == bookALoc } else { false } }
                        && children.contains { if case let .book(_, loc, _) = $0 { loc == missingLoc } else { false } }
                }
                return false
            }
            let playlistOK = try await library.playlists().contains { $0.name == Self.expectedPlaylistName && $0.count >= 1 }
            let historyOK = try await library.history().contains { $0.book == bookALoc }
            record(folderFound && playlistOK && historyOK, "\(label) 书签(含文件夹)、播放列表与历史一致")

            if checkMissingBookmarkDimmed, let checker = services.availability {
                var status: Availability?
                for await batch in checker.check([missingLoc]) { if let v = batch[missingLoc] { status = v; break } }
                record(status == .missing, "\(label) 缺失的本机路径书签保留原样且按规则变灰(\(String(describing: status)))")
            }
        }

        let settingOK = await services.settings.global().maxDecodeLongSide == Self.expectedSettingMaxDecode
        let bindingOK = services.keyBindings?.value().bindings.contains { $0.command == .pageJump && $0.sequence == [KeyChord("k", modifiers: [.command, .option])] } == true
        let menuOK = services.menus?.value().viewerContextMenu == [.command(.playlistAddCurrent), .command(.pageJump)]
        let profileOK = await services.settings.profiles().contains { $0.name == Self.expectedProfileName }
        let pathRuleOK = await services.settings.pathRules().contains { $0.name == Self.expectedPathRuleName }
        let schemeOK = app.dock?.schemes.contains { $0.name == Self.expectedSchemeName } == true
        let scriptOK = await waitUntil(timeoutMs: 4000) {
            services.scriptLibrary?.scripts().contains(where: { $0.fileURL.lastPathComponent == Self.expectedScriptName }) == true
        }
        let extCmdOK = services.externalCommands?.value().commands.contains { $0.id == Self.expectedExtCmdID } == true
        record(settingOK && bindingOK && menuOK && profileOK && pathRuleOK && schemeOK && scriptOK && extCmdOK,
               "\(label) 设置/快捷键/菜单/显示配置/路径规则/布局方案/脚本/外部命令全部一致(\(settingOK),\(bindingOK),\(menuOK),\(profileOK),\(pathRuleOK),\(schemeOK),\(scriptOK),\(extCmdOK))")

        let notesPanelID = PluginCoordinator.panelID(plugin: "page-notes", panel: "notes")
        if let ctrl = app.controllers.first(where: { $0.session.book?.location.name == "book-a" }) ?? app.controllers.first {
            ctrl.window?.tabGroup?.selectedWindow = ctrl.window
            ctrl.window?.makeKeyAndOrderFront(nil)
            _ = await waitUntil(timeoutMs: 4000) { DockPanels.type(notesPanelID) != nil }
            let dockedRight = ctrl.dock.dockLayout.right.panels.contains(notesPanelID)
            var noteMatched = false
            if let notesPanel = await waitForWebPanel(notesPanelID, in: ctrl.dock) {
                _ = await waitUntil(timeoutMs: 4000) { notesPanel.debugIsPageReady }
                let deadline = ContinuousClock.now + .seconds(4)
                while ContinuousClock.now < deadline {
                    if await evalJS(notesPanel, "return document.getElementById('note-input')?.value || '';") == Self.expectedNoteText {
                        noteMatched = true; break
                    }
                    await settle(80)
                }
            }
            record(dockedRight && noteMatched, "\(label) page-notes 面板停靠右侧且显示原笔记文字(docked=\(dockedRight), note=\(noteMatched))")
        }

        let secrets0600 = posixPermissions(of: app.supportDirectory.appending(path: "plugin-secrets.json")) == 0o600
        var davListed = false, davOpened = false
        if let ctrl = app.controllers.first, let plugins = app.plugins {
            _ = await waitUntil(timeoutMs: 4000) { plugins.enabledPlugins.contains(where: { $0.id == "webdav" }) }
            plugins.openSource(state.webdavSourceID, in: ctrl)
            davListed = await waitUntil(timeoutMs: 6000) { ctrl.bookshelfPanel?.entries.contains(where: { $0.name == "dav-book" }) == true }
            if davListed {
                let remoteBook = Location(root: PluginSourceProvider.root(for: state.webdavSourceID), layers: [["dav-book"]])
                ctrl.openBook(remoteBook)
                davOpened = await waitUntil(timeoutMs: 8000) {
                    ctrl.session.book?.location == remoteBook && ctrl.viewer.paged.slots.first?.contents is IOSurface
                }
            }
        }
        record(davListed && davOpened && secrets0600,
               "\(label) WebDAV 来源免重填密码列出并打开图像(list=\(davListed), open=\(davOpened))且 plugin-secrets.json 0600(\(secrets0600))")
    }

    // MARK: - 工具函数

    private var variantTag: String {
        let lang = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "zh"
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return "\(lang)-\(dark ? "dark" : "light")"
    }

    private func snapshotSheet(_ window: NSWindow, _ name: String) {
        guard let output = log.output, let image = log.snapshot(window, name, captureImage: true) else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.14, alpha: 1).cgColor
                        : NSColor(calibratedRed: 0.98, green: 0.976, blue: 0.96, alpha: 1).cgColor
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(bg); ctx.fill(rect); ctx.draw(image, in: rect)
        if let flat = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:]) {
            try? png.write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private func archiveFileURL() -> URL {
        UserDefaults.standard.string(forKey: Self.archiveKey).map(URL.init(fileURLWithPath:))
            ?? TestPresentation.scratchDirectory("dt-archive").appending(path: "exported.macviewdata")
    }

    private func booksDirectory() -> URL {
        UserDefaults.standard.string(forKey: Self.booksKey).map(URL.init(fileURLWithPath:))
            ?? TestPresentation.scratchDirectory("dt-books")
    }

    private func repoRootURL() -> URL {
        UserDefaults.standard.string(forKey: Self.repoKey).map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func loadState() -> SharedState? {
        guard let path = UserDefaults.standard.string(forKey: Self.stateFileKey),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(SharedState.self, from: data)
    }

    private func saveState(_ state: SharedState) throws {
        guard let path = UserDefaults.standard.string(forKey: Self.stateFileKey) else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func ensureSampleArchiveForDialogs() throws -> URL {
        let url = archiveFileURL()
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = #"{"format":1,"appVersion":"0.1.0","appBuild":"1","createdAt":"2026-11-25T12:00:00Z","host":"MacPro","summary":{"history":2,"bookmarks":1,"playlists":1,"scripts":1,"plugins":1},"items":[]}"#
        try createZip(files: ["manifest.json": Data(manifest.utf8), "data/.keep": Data()], to: url, removeKeep: true)
        return url
    }

    private func createZip(files: [String: Data], to destination: URL, removeKeep: Bool = false) throws {
        let temp = TestPresentation.scratchDirectory("dt-zip")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for (rel, data) in files {
            let fileURL = temp.appending(path: rel)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !(removeKeep && rel.hasSuffix("/.keep")) { try data.write(to: fileURL) }
        }
        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", temp.path, destination.path]
        try proc.run(); proc.waitUntilExit()
    }

    private func copyExamplePlugin(_ name: String, to pluginsDir: URL) throws {
        let target = pluginsDir.appending(path: name)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: repoRootURL().appending(path: "Examples/Plugins/\(name)"), to: target)
    }

    private func makeBook(in root: URL, name: String, count: Int) throws -> URL {
        let dir = root.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 1...count {
            let file = dir.appending(path: String(format: "%03d.png", index))
            if FileManager.default.fileExists(atPath: file.path) { continue }
            guard let ctx = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(NSColor(hue: CGFloat(index) / CGFloat(count + 1), saturation: 0.6, brightness: 0.85, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
            if let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                try data.write(to: file)
            }
        }
        return dir
    }

    private func fileMenu() -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == "文件" || $0.title == "File" }?.submenu }

    private func validateFileMenu() {
        guard let menu = fileMenu() else { return }
        menu.delegate?.menuWillOpen?(menu); menu.update(); menu.delegate?.menuDidClose?(menu)
    }

    private func fileMenuItemTitles() -> [String] { fileMenu()?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [] }

    private func findFileMenuItem(command: CommandID) -> NSMenuItem? {
        fileMenu()?.items.first { $0.title == app.catalog.title(of: command) }
    }

    private func triggerMenuItem(_ item: NSMenuItem) {
        if let menu = item.menu {
            menu.delegate?.menuWillOpen?(menu); menu.update()
            let idx = menu.index(of: item)
            if idx >= 0 { menu.performActionForItem(at: idx); menu.delegate?.menuDidClose?(menu); return }
            menu.delegate?.menuDidClose?(menu)
        }
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    private func sendKey(_ keyCode: Int, chars: String, to window: NSWindow) {
        let ts = ProcessInfo.processInfo.systemUptime
        for (type, dt) in [(NSEvent.EventType.keyDown, 0.0), (.keyUp, 0.02)] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ts + dt,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)) {
                NSApp.sendEvent(e)
            }
        }
    }

    private func clickButton(_ button: NSButton, in window: NSWindow) {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let ts = ProcessInfo.processInfo.systemUptime
        eventNumber += 1
        for (type, dt, p) in [(NSEvent.EventType.leftMouseDown, 0.0, Float(1)), (.leftMouseUp, 0.02, Float(0))] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ts + dt,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: p) {
                NSApp.sendEvent(e)
            }
        }
    }

    private func allText(in alert: NSAlert) -> String {
        ([alert.messageText, alert.informativeText] + (alert.accessoryView.map(texts(in:)) ?? [])).joined(separator: "\n")
    }

    private func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
    }

    private func posixPermissions(of url: URL) -> Int? {
        var info = stat(); return lstat(url.path, &info) == 0 ? Int(info.st_mode & 0o777) : nil
    }

    private func directoryHashes(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let url as URL in en {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            if rel.hasPrefix("selftest-tmp/") || rel.hasPrefix("Backups/") || rel.hasPrefix(".import-") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            result[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func waitForWebPanel(_ id: PanelID, in dock: WindowDock) async -> PluginWebPanel? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let panel = dock.panels[id] as? PluginWebPanel { return panel }
            await settle(50)
        }
        return nil
    }

    private func evalJS(_ panel: PluginWebPanel, _ body: String) async -> String? {
        guard let webView = panel.webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
        }
    }

    private func settle(_ ms: Int = 100) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func waitUntil(timeoutMs: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
