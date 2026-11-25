#if DEBUG
import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import IOSurface
import MVCommands
import MVFoundation
import MVIO
import MVLibraryData
import MVPipeline
import MVPlugins
import MVReading
import MVScripting
import MVServices
import MVSettings
import UniformTypeIdentifiers

/// 插件宿主 App 接入自检（`-MVPluginSelfTest commands|sources|filters|settings`）。
///
/// 覆盖阶段 2 与阶段 3 的检查项 C2.1–C2.14、C3.1–C3.12：
/// - `commands`：C2.1、C2.2、C2.3、C2.4、C2.13 及中英文文案；
/// - `sources`（及内部冷重启子模式 `sources-reopen`）：C2.5、C2.6、C2.7、C2.8、C2.8b；
/// - `filters`：C2.9、C2.10、C2.11、C2.11b、C2.11c 与连续视图主区滤镜；
/// - `settings`：C3.1–C3.12（扩展页插件一节、权限确认、来源编辑、效果面板插件滤镜与截图）。
@MainActor
final class PluginSelfTest {
    static let launchKey = "MVPluginSelfTest"

    let app: AppDelegate
    private let mode: String
    let log = SelfTestLog()
    let temporary: URL
    let repoRoot: URL
    weak var keyTarget: NSWindow?

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mode.isEmpty else { return }
        let test = PluginSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
        self.temporary = TestPresentation.scratchDirectory("plugin-\(mode)")
        if let override = UserDefaults.standard.string(forKey: "MVPluginSelfTestRepo") {
            self.repoRoot = URL(fileURLWithPath: override)
        } else {
            self.repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }

    private func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        TestPresentation.activateIfAllowed()
        if TestPresentation.activationAllowed {
            for _ in 0..<30 where !NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let services = app.services,
              let plugins = app.plugins,
              let controller = app.controllers.first,
              let window = controller.window else {
            log.check(false, "插件自检需要真实服务、插件协调器与主窗口")
            exit(log.summarize())
        }
        keyTarget = window
        window.setContentSize(NSSize(width: 1120, height: 760))
        TestPresentation.place(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            switch mode {
            case "commands":
                try await runCommandsSuite(controller: controller, window: window, services: services, plugins: plugins)
            case "sources":
                try await runSourcesSuite(controller: controller, window: window, services: services, plugins: plugins)
            case "sources-reopen":
                try await runSourcesReopenSuite(controller: controller, services: services, plugins: plugins)
            case "filters":
                try await runFiltersSuite(controller: controller, window: window, services: services, plugins: plugins)
            case "settings":
                try await runSettingsSuite(controller: controller, window: window, services: services, plugins: plugins)
            case "panels":
                try await runPanelsSuite(controller: controller, window: window, services: services, plugins: plugins)
            case "panels-reopen":
                try await runPanelsReopenSuite(controller: controller, services: services, plugins: plugins)
            default:
                log.check(false, "未知的 -MVPluginSelfTest 模式：\(mode)")
            }
        } catch {
            log.check(false, "插件自检异常（\(mode)）：\(error)")
        }

        try? FileManager.default.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: - commands（C2.1–C2.4, C2.13）

    private func runCommandsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let pluginLib = services.pluginLibrary,
              let pluginSettings = services.pluginSettings,
              let scriptLog = services.scriptLog,
              let scriptStorage = services.scriptStorage,
              let scriptEvents = app.scriptEvents else {
            log.check(false, "插件服务未初始化")
            return
        }

        // C2.13：App 包内打包了 Resources/PluginSupport/python/macview_plugin.py
        let pyHelper = Bundle.main.resourceURL?.appending(path: "PluginSupport/python/macview_plugin.py")
        let bundledOK = pyHelper.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        log.check(bundledOK, "C2.13 App 包内存在 Resources/PluginSupport/python/macview_plugin.py")

        // 准备 12 页测试书
        let bookDir = try makeColorBook(name: "cmd-book", count: 12, size: CGSize(width: 400, height: 600))
        await openBook(controller, url: bookDir, expectedCount: 12)
        controller.session.go(.index(0))
        await settle(150)

        // C2.1：启用 random-page 示例，命令出现在 CommandRegistry 与「脚本」菜单子菜单，绑快捷键后真实按键执行跳页
        try copyExamplePlugin("random-page", to: pluginLib.directory)
        try await pluginSettings.update { file in
            file.plugins["random-page"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let randomCmdID = CommandID("plugin.random-page.random")
        let scriptsMenuTitle = String(localized: "脚本")
        let randomRegistered = await waitUntil(timeoutMs: 3000) {
            services.commands.descriptors().contains {
                $0.id == randomCmdID && $0.category == "随机跳页" && $0.verbatimTitle == "随机跳页"
            } &&
            SettingsCommandCatalog.all.contains { $0.id == randomCmdID } &&
            Self.scriptsMenuContainsPluginCommand(scriptsTitle: scriptsMenuTitle, pluginName: "随机跳页", commandTitle: "随机跳页")
        }
        log.check(randomRegistered, "C2.1 启用 random-page 后命令出现在 descriptors() 与「脚本」子菜单")

        let shortcutBinding = KeyBinding(
            sequence: [KeyChord("p", modifiers: [.control])],
            command: randomCmdID,
            scope: .viewer
        )
        try await services.keyBindings?.update { file in
            file.bindings.removeAll { $0.command == randomCmdID }
            file.bindings.append(shortcutBinding)
        }
        let bindingLoaded = await waitUntil(timeoutMs: 2500) {
            app.catalog.bindings.contains(shortcutBinding)
        }
        window.makeFirstResponder(controller.viewer)
        var pageChanged = false
        for _ in 0..<5 {
            let before = controller.session.currentPage
            await sendKey(kVK_ANSI_P, modifiers: [.control], in: window)
            if await waitUntil(timeoutMs: 3000, condition: { controller.session.currentPage != before }) {
                pageChanged = true
                break
            }
        }
        log.check(bindingLoaded && pageChanged, "C2.1 绑定 ⌃P 后真实按键执行 random-page，页码变为 \(controller.session.currentPage + 1)")

        // C2.2：自检测试 JS 插件缺 commands 权限时 mv.command 报错进输出区；同意后可用
        let permDir = pluginLib.directory.appending(path: "perm-test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: permDir, withIntermediateDirectories: true)
        let permManifestWithout = """
        {
          "name": "权限测试",
          "version": "1.0",
          "runtime": { "js": "main.js" },
          "permissions": [],
          "commands": [{ "id": "next", "title": "尝试翻页" }]
        }
        """
        let permJS = """
        plugin.commands["next"] = () => {
          mv.command("frame.next");
        };
        """
        try permManifestWithout.write(to: permDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try permJS.write(to: permDir.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try await pluginSettings.update { file in
            file.plugins["perm-test"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let permCmdID = CommandID("plugin.perm-test.next")
        let permReady = await waitUntil(timeoutMs: 3000) {
            services.commands.descriptors().contains { $0.id == permCmdID }
        }
        controller.session.go(.index(0))
        await settle(150)
        scriptLog.clear()
        try await services.commands.perform(
            permCmdID,
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let deniedLogged = await waitUntil(timeoutMs: 2500) {
            scriptLog.entries().contains { $0.source == "权限测试" && $0.level == .error && $0.text.contains("commands") }
        }
        let pageStayedZero = controller.session.currentPage == 0
        log.check(permReady && deniedLogged && pageStayedZero, "C2.2 缺 commands 权限时 mv.command 报错进输出区且未翻页")

        // 清单加 commands 权限并同意后可用
        let permManifestWith = """
        {
          "name": "权限测试",
          "version": "1.0",
          "runtime": { "js": "main.js" },
          "permissions": ["commands"],
          "commands": [{ "id": "next", "title": "尝试翻页" }]
        }
        """
        try permManifestWith.write(to: permDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try await pluginSettings.update { file in
            file.plugins["perm-test"] = PluginState(enabled: true, grantedPermissions: [.commands])
        }
        let permReloaded = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "perm-test" && $0.manifest?.permissions == [.commands] } &&
            services.commands.descriptors().contains { $0.id == permCmdID }
        }
        try await services.commands.perform(
            permCmdID,
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let allowedMoved = await waitUntil(timeoutMs: 2500) {
            controller.session.currentPage == 1
        }
        log.check(permReloaded && allowedMoved, "C2.2 同意 commands 权限后 mv.command 执行翻页成功")

        // C2.3：停用 random-page 后命令从菜单与 descriptors() 消失，绑定进「未知命令」；重新启用后恢复
        try await pluginSettings.update { file in
            file.plugins["random-page"]?.enabled = false
        }
        let disabledOK = await waitUntil(timeoutMs: 3000) {
            !services.commands.descriptors().contains { $0.id == randomCmdID } &&
            !SettingsCommandCatalog.all.contains { $0.id == randomCmdID } &&
            !Self.scriptsMenuContainsPluginCommand(scriptsTitle: scriptsMenuTitle, pluginName: "随机跳页", commandTitle: "随机跳页")
        }
        let shortcutsAfterDisable = ShortcutsModel(store: services.keyBindings)
        let unknownSection = shortcutsAfterDisable.sections.last
        let unknownHasBinding = unknownSection?.isUnknown == true &&
            unknownSection?.rows.contains { $0.command == randomCmdID && $0.bindings == [shortcutBinding] } == true
        log.check(disabledOK && unknownHasBinding, "C2.3 停用插件后命令从菜单与 descriptors() 消失，绑定进入「未知命令」分组")

        try await pluginSettings.update { file in
            file.plugins["random-page"]?.enabled = true
        }
        let reenabledOK = await waitUntil(timeoutMs: 3000) {
            services.commands.descriptors().contains { $0.id == randomCmdID } &&
            Self.scriptsMenuContainsPluginCommand(scriptsTitle: scriptsMenuTitle, pluginName: "随机跳页", commandTitle: "随机跳页")
        }
        let shortcutsAfterReenable = ShortcutsModel(store: services.keyBindings)
        let restoredBinding = !shortcutsAfterReenable.sections.contains(where: { $0.isUnknown && $0.rows.contains { $0.command == randomCmdID } }) &&
            shortcutsAfterReenable.effectiveBindings.contains(shortcutBinding)
        log.check(reenabledOK && restoredBinding, "C2.3 重新启用插件后命令与快捷键绑定自动恢复")

        // C2.4：无插件订阅 pageChanged 时不调用 dispatch；订阅后翻页收到事件
        scriptEvents.resetDispatchCounts()
        controller.session.go(.index(2))
        await settle(150)
        controller.session.go(.index(3))
        await settle(150)
        let zeroWhenUnsubscribed = services.pluginHost?.hasSubscribers(for: .pageChanged) == false && scriptEvents.pluginDispatchCount == 0
        log.check(zeroWhenUnsubscribed, "C2.4 无插件订阅 pageChanged 时不调用 PluginHost.dispatch（count=\(scriptEvents.pluginDispatchCount)）")

        let eventDir = pluginLib.directory.appending(path: "event-test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: eventDir, withIntermediateDirectories: true)
        try """
        {
          "name": "事件测试",
          "version": "1.0",
          "runtime": { "js": "main.js" },
          "permissions": [],
          "events": ["pageChanged"]
        }
        """.write(to: eventDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        plugin.onEvent = (name, payload) => {
          if (name === "pageChanged") {
            mv.storage.set("lastIndex", payload.index);
          }
        };
        """.write(to: eventDir.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try await pluginSettings.update { file in
            file.plugins["event-test"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let eventPluginReady = await waitUntil(timeoutMs: 3000) {
            services.pluginHost?.hasSubscribers(for: .pageChanged) == true
        }
        scriptEvents.resetDispatchCounts()
        controller.session.go(.index(5))
        let eventReceived = await waitUntil(timeoutMs: 3000) {
            scriptStorage.get("plugin:event-test", "lastIndex") == .number(5)
        }
        log.check(eventPluginReady && scriptEvents.pluginDispatchCount >= 1 && eventReceived, "C2.4 订阅 pageChanged 的插件在翻页时收到事件（index=5）")

        // 核对改名与中英文文案（C2.14）
        let manageTitle = app.catalog.title(of: .scriptManage)
        let sourcesMenu = NSMenu()
        plugins.populateSourcesMenu(sourcesMenu)
        let manageSourcesTitle = sourcesMenu.items.last?.title ?? ""
        let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == String(localized: "文件") })?.submenu
        let openSourceTitle = fileMenu?.items.first(where: { $0.title == String(localized: "打开来源") })?.title ?? ""
        let isEnglish = Bundle.main.preferredLocalizations.first == "en"
        if isEnglish {
            let noChinese = [manageTitle, manageSourcesTitle, openSourceTitle].allSatisfy { text in
                !text.isEmpty && !text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            }
            log.check(
                noChinese && manageTitle.contains("Plugins") && openSourceTitle == "Open Source" && manageSourcesTitle.contains("Manage Sources"),
                "C2.14 英文环境菜单文案完整无中文：\(manageTitle) / \(openSourceTitle) / \(manageSourcesTitle)"
            )
        } else {
            log.check(
                manageTitle == "管理脚本、外部命令与插件…" && openSourceTitle == "打开来源" && manageSourcesTitle == "管理来源…",
                "C2.14 中文环境菜单文案完整：\(manageTitle) / \(openSourceTitle) / \(manageSourcesTitle)"
            )
        }
    }

    // MARK: - sources（C2.5–C2.8b）

    private func runSourcesSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let pluginLib = services.pluginLibrary,
              let pluginSettings = services.pluginSettings,
              let pluginSecrets = services.pluginSecrets,
              let libraryStore = services.library else {
            log.check(false, "来源自检缺少必要服务")
            return
        }

        // 准备 WebDAV 目录：两个子目录书 + 一个远端 zip
        let davRoot = temporary.appending(path: "dav-root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: davRoot, withIntermediateDirectories: true)
        _ = try makeColorBook(in: davRoot, name: "book-alpha", count: 3, size: CGSize(width: 480, height: 640))
        _ = try makeColorBook(in: davRoot, name: "book-beta", count: 3, size: CGSize(width: 480, height: 640))
        let zipSrc = try makeColorBook(name: "zip-src", count: 2, size: CGSize(width: 360, height: 480))
        _ = try makeZip(from: zipSrc, to: davRoot.appending(path: "remote-pack.zip"))

        try copyExamplePlugin("webdav", to: pluginLib.directory)

        let server = try WebDAVServerHandle(
            scriptURL: repoRoot.appending(path: "scripts/webdav-test-server.py"),
            root: davRoot,
            port: 0,
            user: "davuser",
            password: "davpass"
        )
        defer { server.stop() }
        let serverPort = server.port
        let serverBaseURL = server.baseURL
        let sourceID = UUID()
        let sourceName = "测试网盘"

        try await pluginSecrets.set(["password": "davpass"], for: sourceID)
        try await pluginSettings.update { file in
            file.plugins["webdav"] = PluginState(enabled: true, grantedPermissions: [])
            file.sources = [
                SourceInstance(
                    id: sourceID,
                    plugin: "webdav",
                    type: "webdav",
                    name: sourceName,
                    values: ["url": serverBaseURL, "user": "davuser"]
                ),
            ]
        }
        let webdavReady = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "webdav" } &&
            plugins.sourceName(for: PluginSourceProvider.root(for: sourceID)) == sourceName
        }
        log.check(webdavReady, "WebDAV 示例插件与来源实例就绪")

        // C2.8b：「打开来源」列出实例与「管理来源…」，点「管理来源…」打开扩展页并带 settings.extensions.plugins
        let sourcesMenu = NSMenu()
        plugins.populateSourcesMenu(sourcesMenu)
        let hasInstanceItem = sourcesMenu.items.contains { $0.title.contains(sourceName) && $0.title.contains("WebDAV") }
        let manageItem = sourcesMenu.items.last
        if let manageItem { triggerMenuItem(manageItem) }
        await settle(250)
        let settingsController = app.openSettings()
        let navigatedOK = settingsController?.state.page == .extensions &&
            settingsController?.state.scrollTarget?.section == "settings.extensions.plugins"
        settingsController?.window?.close()
        log.check(hasInstanceItem && navigatedOK, "C2.8b 「打开来源」列出来源实例，点击「管理来源…」打开扩展页并带上 settings.extensions.plugins")

        // C2.5：从「打开来源」打开，书架列出远端目录与 zip；打开书翻页与缩略图可用；远端 zip 可打开
        plugins.openSource(sourceID, in: controller)
        let shelfListed = await waitUntil(timeoutMs: 5000) {
            guard let names = controller.bookshelfPanel?.entries.map(\.name) else { return false }
            return names.contains("book-alpha") && names.contains("book-beta") && names.contains("remote-pack.zip")
        }
        let shelfRoot = PluginSourceProvider.root(for: sourceID)
        let shelfBreadcrumb = controller.bookshelfPanel?.currentDirectory?.displayBreadcrumb ?? ""
        log.check(shelfListed && shelfBreadcrumb == sourceName, "C2.5 打开来源后书架列出远端目录与 zip，路径栏显示「\(shelfBreadcrumb)」")

        let alphaLoc = Location(root: shelfRoot, layers: [["book-alpha"]])
        controller.openBook(alphaLoc)
        let alphaLoaded = await waitUntil(timeoutMs: 5000) {
            controller.session.book?.location == alphaLoc && controller.session.book?.pages.count == 3
        }
        let page0Rendered = await waitUntil(timeoutMs: 5000) {
            controller.viewer.paged.slots.first?.contents is IOSurface
        }
        controller.session.go(.nextFrame)
        let page1Rendered = await waitUntil(timeoutMs: 5000) {
            controller.session.currentPage == 1 && controller.viewer.paged.slots.first?.contents is IOSurface
        }
        var thumbOK = false
        if let page0 = controller.session.book?.pages.first {
            let thumb = try await services.pipeline.thumbnail(for: page0.entry.identity, maxPixel: 256, priority: .visible)
            thumbOK = thumb.surface != nil
        }
        log.check(alphaLoaded && page0Rendered && page1Rendered && thumbOK, "C2.5 远端书翻页、显示图与缩略图均可用")

        let zipLoc = Location(root: shelfRoot, layers: [["remote-pack.zip"]])
        controller.openBook(zipLoc)
        let zipLoaded = await waitUntil(timeoutMs: 5000) {
            controller.session.book?.location == zipLoc &&
            controller.session.book?.pages.count == 2 &&
            controller.viewer.paged.slots.first?.contents is IOSurface
        }
        log.check(zipLoaded, "C2.5 远端目录里的 zip 压缩包打开并渲染成功")

        // C2.6：加书签、冲刷落盘、冷重启子进程从书签打开成功，书签与历史显示来源名称
        _ = try await libraryStore.addBookmarks([alphaLoc], into: nil, at: nil)
        await controller.session.flush()
        let displayPathOK = alphaLoc.parent?.displayPath == sourceName && alphaLoc.root.displayName == sourceName
        let reopenOK = await runReopenSubprocess(expectedLocation: alphaLoc, expectedSourceName: sourceName)
        log.check(displayPathOK && reopenOK, "C2.6 加书签后冷重启 App 从书签打开成功，书签与历史显示来源名称「\(sourceName)」")

        // C2.7：停掉测试服务后刷新书架与翻到未缓存页，出现错误与重试，主线程无 > 100 ms 卡顿；恢复后重试成功
        server.stop()
        let stallProbe = MainThreadStallProbe()
        let stallTimer = Timer(timeInterval: 0.016, repeats: true) { _ in
            MainActor.assumeIsolated { stallProbe.tick() }
        }
        RunLoop.main.add(stallTimer, forMode: .common)

        controller.bookshelfPanel?.refreshDirectory()
        let shelfErrored = await waitUntil(timeoutMs: 8000) {
            controller.bookshelfPanel?.hasLoadError == true &&
            controller.bookshelfPanel?.collection?.onRetryMessage != nil
        }
        let betaLoc = Location(root: shelfRoot, layers: [["book-beta"]])
        controller.openBook(betaLoc)
        let viewerErrored = await waitUntil(timeoutMs: 8000) {
            controller.session.loadError != nil
        }
        stallTimer.invalidate()
        let maxStallMs = stallProbe.maxStallMs
        log.check(shelfErrored && viewerErrored && maxStallMs < 100, "C2.7 停服后书架与未缓存页报错并提供重试，主线程最大间隔 \(String(format: "%.1f", maxStallMs)) ms < 100 ms")

        // 重启同端口 WebDAV 服务后重试成功
        let restartedServer = try WebDAVServerHandle(
            scriptURL: repoRoot.appending(path: "scripts/webdav-test-server.py"),
            root: davRoot,
            port: serverPort,
            user: "davuser",
            password: "davpass"
        )
        defer { restartedServer.stop() }
        controller.bookshelfPanel?.refreshDirectory()
        controller.viewer.retryFailed()
        let recovered = await waitUntil(timeoutMs: 6000) {
            controller.bookshelfPanel?.hasLoadError == false &&
            (controller.bookshelfPanel?.entries.count ?? 0) >= 3 &&
            controller.session.loadError == nil &&
            controller.session.book?.pages.count == 3
        }
        log.check(recovered, "C2.7 恢复服务后书架与查看器重试成功")

        // C2.8：停用插件后打开来源提示「插件未启用」；重新启用后能再打开
        try await pluginSettings.update { file in
            file.plugins["webdav"]?.enabled = false
        }
        let webdavDisabled = await waitUntil(timeoutMs: 3000) {
            !plugins.enabledPlugins.contains { $0.id == "webdav" }
        }
        plugins.openSource(sourceID, in: controller)
        let disabledExpected = String(localized: "插件未启用")
        let disabledPromptOK = await waitUntil(timeoutMs: 4000) {
            guard let err = controller.session.loadError else { return false }
            return ErrorText.describe(err) == disabledExpected
        }
        log.check(webdavDisabled && disabledPromptOK, "C2.8 停用插件后打开来源提示「\(disabledExpected)」")

        try await pluginSettings.update { file in
            file.plugins["webdav"]?.enabled = true
        }
        let webdavReenabled = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "webdav" }
        }
        controller.reopenBook()
        let reopenedAfterEnable = await waitUntil(timeoutMs: 5000) {
            controller.bookshelfPanel?.hasLoadError == false &&
            (controller.bookshelfPanel?.entries.map(\.name).contains("book-alpha") == true)
        }
        log.check(webdavReenabled && reopenedAfterEnable, "C2.8 重新启用插件后重试成功打开来源")
    }

    /// C2.6 冷重启子进程：复用隔离目录，读取持久化书签与历史并从书签重新打开远端书。
    private func runSourcesReopenSuite(
        controller: ReaderWindowController,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let libraryStore = services.library else {
            log.check(false, "冷重启子进程缺少资料库")
            return
        }
        let ready = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "webdav" }
        }
        let bookmarks = try await libraryStore.bookmarks()
        let history = try await libraryStore.history()
        var bookmarkedLoc: Location?
        for node in bookmarks {
            if case let .book(_, loc, _) = node { bookmarkedLoc = loc; break }
        }
        guard let target = bookmarkedLoc else {
            log.check(false, "冷重启后未找到书签")
            return
        }
        let expectedName = UserDefaults.standard.string(forKey: "MVPluginSelfTestExpectedSource") ?? ""
        let bookmarkPath = target.parent?.displayPath ?? ""
        let historyHasSource = history.contains { $0.book.root == target.root && $0.book.parent?.displayPath == expectedName }
        LibraryPanels.open(target, from: controller)
        let opened = await waitUntil(timeoutMs: 6000) {
            controller.session.book?.location == target &&
            controller.session.book?.pages.count == 3 &&
            controller.viewer.paged.slots.first?.contents is IOSurface
        }
        log.check(ready && bookmarkPath == expectedName && historyHasSource && opened, "C2.6 子进程冷重启后书签/历史显示「\(bookmarkPath)」并成功打开")
    }

    // MARK: - filters（C2.9–C2.11c）

    private func runFiltersSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let pluginLib = services.pluginLibrary,
              let pluginSettings = services.pluginSettings,
              let scriptLog = services.scriptLog else {
            log.check(false, "滤镜自检缺少必要服务")
            return
        }

        try copyExamplePlugin("grayscale", to: pluginLib.directory)
        try writeSlowAndTestFilterPlugin(in: pluginLib.directory)
        try await pluginSettings.update { file in
            file.plugins["grayscale"] = PluginState(enabled: true, grantedPermissions: [])
            file.plugins["test-filter"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let pluginsReady = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "grayscale" } &&
            plugins.enabledPlugins.contains { $0.id == "test-filter" }
        }
        log.check(pluginsReady, "灰度滤镜与测试滤镜插件就绪")

        // 准备 4 页高饱和纯色 PNG 书（便于像素检测彩色 vs 灰度）
        let bookDir = try makeColorBook(name: "filter-book", count: 4, size: CGSize(width: 480, height: 640))
        await openBook(controller, url: bookDir, expectedCount: 4)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.effects = .empty
        }
        controller.session.go(.index(0))
        let page0Color = await waitUntil(timeoutMs: 4000) {
            guard let contents = controller.viewer.paged.slots.first?.contents else { return false }
            return Self.isGrayscale(contents) == false
        }
        log.check(page0Color, "C2.9 初始打开第 1 页显示彩色原图")

        // C2.9：打开灰度滤镜，第 1 页变灰；翻到第 2 页变灰（预热）；翻回第 1 页立即为灰（缓存命中）
        let grayEffect = Effect.plugin(PluginFilterEffect(plugin: "grayscale", filter: "grayscale", parameters: [:], enabled: true))
        controller.session.update { $0.effects = EffectChain(effects: [grayEffect]) }
        let page0Gray = await waitUntil(timeoutMs: 8000) {
            guard let slot = controller.viewer.paged.slots.first, slot.isShowingFiltered, let c = slot.contents else { return false }
            return Self.isGrayscale(c) == true
        }
        let idleAfterGray = controller.pluginFilterActivity.states["grayscale.grayscale"] == .idle
        // 等前后 1 帧预热有足够时间跑完
        try? await Task.sleep(for: .milliseconds(900))
        controller.session.go(.index(1))
        let page1Gray = await waitUntil(timeoutMs: 5000) {
            guard let slot = controller.viewer.paged.slots.first, slot.element.page == 1, slot.isShowingFiltered, let c = slot.contents else { return false }
            return Self.isGrayscale(c) == true
        }
        let turnBackStart = ContinuousClock.now
        controller.session.go(.index(0))
        let page0CachedGray = await waitUntil(timeoutMs: 3000) {
            guard let slot = controller.viewer.paged.slots.first, slot.element.page == 0, slot.isShowingFiltered, let c = slot.contents else { return false }
            return Self.isGrayscale(c) == true
        }
        let cacheHitMs = (ContinuousClock.now - turnBackStart).milliseconds
        log.check(page0Gray && idleAfterGray && page1Gray && page0CachedGray && cacheHitMs < 400, "C2.9 灰度滤镜处理、下一页预热与翻回缓存命中均通过（翻回用时 \(String(format: "%.1f", cacheHitMs)) ms）")

        // C2.10 & C2.11c（running / idle）：慢滤镜处理中 activity == .running 且状态栏显示处理中；关闭立即恢复原图且插件日志记录取消
        scriptLog.clear()
        let slowEffect = Effect.plugin(PluginFilterEffect(plugin: "test-filter", filter: "slow", parameters: [:], enabled: true))
        controller.session.update { $0.effects = EffectChain(effects: [slowEffect]) }
        let sawRunning = await waitUntil(timeoutMs: 4000) {
            controller.pluginFilterActivity.states["test-filter.slow"] == .running &&
            controller.content.statusBar.filterStatusText != nil &&
            scriptLog.entries().contains { $0.source == "测试滤镜" && $0.text.contains("started slow filter") }
        }
        let runningStatusText = controller.content.statusBar.filterStatusText ?? ""
        // 立刻关闭滤镜，应立刻恢复原图并在途请求被取消
        let disableStart = ContinuousClock.now
        controller.session.update { $0.effects = .empty }
        let restoredImmediately = await waitUntil(timeoutMs: 500) {
            controller.viewer.paged.slots.first?.isShowingFiltered == false &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == false) &&
            controller.pluginFilterActivity.states.isEmpty &&
            controller.content.statusBar.filterStatusText == nil
        }
        let restoreMs = (ContinuousClock.now - disableStart).milliseconds
        let cancelLogged = await waitUntil(timeoutMs: 3000) {
            scriptLog.entries().contains { $0.source == "测试滤镜" && $0.text.contains("cancelled") }
        }
        log.check(
            sawRunning && restoredImmediately && restoreMs < 150 && cancelLogged,
            "C2.10/C2.11c 运行态显示「\(runningStatusText)」，关闭 \(String(format: "%.1f", restoreMs)) ms 恢复原图且插件日志含取消（saw=\(sawRunning) rest=\(restoredImmediately) cancel=\(cancelLogged)）"
        )

        // C2.11c（failed）：失败时 activity == .failed，原图保留且错误进输出区
        scriptLog.clear()
        let failEffect = Effect.plugin(PluginFilterEffect(plugin: "test-filter", filter: "fail", parameters: [:], enabled: true))
        controller.session.update { $0.effects = EffectChain(effects: [failEffect]) }
        let sawFailed = await waitUntil(timeoutMs: 4000) {
            if case .failed = controller.pluginFilterActivity.states["test-filter.fail"] { return true }
            return false
        }
        let originalPreserved = controller.viewer.paged.slots.first?.isShowingFiltered == false &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == false)
        let failLogged = scriptLog.entries().contains { $0.level == .error && $0.source == "测试滤镜" }
        log.check(sawFailed && originalPreserved && failLogged, "C2.11c 滤镜失败时 PluginFilterActivity 为 failed、保留原图并写入输出区")

        // C2.11：停用插件后滤镜跳过、调色仍生效；重新启用后当前页重新处理并变灰
        var colorAdjust = ColorAdjust.identity
        colorAdjust.brightness = 0.25
        controller.session.update { $0.effects = EffectChain(effects: [.colorAdjust(colorAdjust), grayEffect]) }
        let comboGray = await waitUntil(timeoutMs: 5000) {
            controller.viewer.paged.slots.first?.isShowingFiltered == true &&
            controller.viewer.effectFilterCount > 0
        }
        try await pluginSettings.update { file in
            file.plugins["grayscale"]?.enabled = false
        }
        let skippedAfterDisable = await waitUntil(timeoutMs: 3000) {
            controller.viewer.paged.slots.first?.isShowingFiltered == false &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == false) &&
            controller.viewer.effectFilterCount > 0
        }
        try await pluginSettings.update { file in
            file.plugins["grayscale"]?.enabled = true
        }
        let reappliedAfterEnable = await waitUntil(timeoutMs: 6000) {
            controller.viewer.paged.slots.first?.isShowingFiltered == true &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == true)
        }
        log.check(comboGray && skippedAfterDisable && reappliedAfterEnable, "C2.11 停用插件跳过滤镜并保持调色生效，重启用后当前页重新变灰")

        // C2.11b：动图页与视频页开着插件滤镜时不调插件、不报错
        let mediaBook = temporary.appending(path: "media-book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaBook, withIntermediateDirectories: true)
        try writeAnimatedGIF(to: mediaBook.appending(path: "01-anim.gif"), size: CGSize(width: 120, height: 120))
        try writeOrCopyVideo(to: mediaBook.appending(path: "02-clip.mp4"))
        await openBook(controller, url: mediaBook, expectedCount: 2)
        scriptLog.clear()
        let probeEffect = Effect.plugin(PluginFilterEffect(plugin: "test-filter", filter: "probe", parameters: [:], enabled: true))
        controller.session.update { $0.effects = EffectChain(effects: [probeEffect]) }
        controller.session.go(.index(0))
        await settle(500)
        let gifNoErr = controller.session.loadError == nil && controller.viewer.paged.slots.first?.failure == nil
        controller.session.go(.index(1))
        await settle(500)
        let videoNoErr = controller.session.loadError == nil && controller.viewer.paged.slots.first?.failure == nil
        let zeroCallsOnMedia = !scriptLog.entries().contains { $0.text.contains("probe-invoked") }
        log.check(gifNoErr && videoNoErr && zeroCallsOnMedia, "C2.11b 动图页与视频页开着插件滤镜时不调用插件且不报错")

        // 连续视图（verticalStrip）验证：打开灰度滤镜可见页变灰，关闭恢复原图
        await openBook(controller, url: bookDir, expectedCount: 4)
        controller.session.update {
            $0.browseMode = .verticalStrip
            $0.effects = EffectChain(effects: [grayEffect])
        }
        let stripGray = await waitUntil(timeoutMs: 6000) {
            guard let contents = controller.viewer.continuous.canvas.cachedContents(at: 0) else { return false }
            return Self.isGrayscale(contents) == true
        }
        controller.session.update { $0.effects = .empty }
        let stripRestored = await waitUntil(timeoutMs: 3000) {
            guard let contents = controller.viewer.continuous.canvas.cachedContents(at: 0) else { return false }
            return Self.isGrayscale(contents) == false
        }
        log.check(stripGray && stripRestored, "连续视图主区插件滤镜生效且关闭后立即恢复原图")
    }

    // MARK: - 辅助：冷重启子进程

    private func runReopenSubprocess(expectedLocation: Location, expectedSourceName: String) async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let layoutFile = UserDefaults.standard.string(forKey: DockCoordinator.layoutFileKey) ?? ""
        let proc = Process()
        proc.executableURL = executable
        var args = [
            "-MVPluginSelfTest", "sources-reopen",
            "-MVPluginSelfTestRepo", repoRoot.path,
            "-MVPluginSelfTestExpectedSource", expectedSourceName,
            "-MVSupportDirectory", app.supportDirectory.path,
            "-MVCacheDirectory", app.cacheDirectory.path,
            "-MVLayoutFile", layoutFile,
        ]
        if let lang = Bundle.main.preferredLocalizations.first {
            args += ["-AppleLanguages", "(\(lang))"]
        }
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            print("INFO 启动冷重启子进程失败：\(error)")
            return false
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                let ok = proc.terminationStatus == 0 && output.contains("SELFTEST OK")
                if !ok {
                    print("INFO 冷重启子进程输出：\n\(output)")
                }
                continuation.resume(returning: ok)
            }
        }
    }

    // MARK: - 辅助：插件、夹具与像素检测

    func copyExamplePlugin(_ id: String, to pluginsDir: URL) throws {
        let src = repoRoot.appending(path: "Examples/Plugins/\(id)", directoryHint: .isDirectory)
        let dst = pluginsDir.appending(path: id, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
    }

    private func writeSlowAndTestFilterPlugin(in pluginsDir: URL) throws {
        let dir = pluginsDir.appending(path: "test-filter", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "name": "测试滤镜",
          "version": "1.0",
          "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
          "permissions": [],
          "filters": [
            { "id": "slow", "name": "慢滤镜", "parameters": [] },
            { "id": "fail", "name": "失败滤镜", "parameters": [] },
            { "id": "probe", "name": "探测滤镜", "parameters": [] }
          ]
        }
        """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)

        let py = """
        import json, shutil, sys, threading, time

        write_lock = threading.Lock()
        cancelled = set()

        def send(obj):
            with write_lock:
                sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\\n")
                sys.stdout.flush()

        def log(msg, level="info"):
            send({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": msg}})

        def handle(msg):
            req_id = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                return
            if method == "filter.apply":
                flt = params.get("filter")
                if flt == "probe":
                    log("probe-invoked")
                    shutil.copyfile(params["input"], params["output"])
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    return
                if flt == "fail":
                    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32000, "message": "simulated filter failure"}})
                    return
                if flt == "slow":
                    log("started slow filter")
                    for _ in range(80):
                        if req_id in cancelled:
                            log("cancelled slow filter")
                            send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32800, "message": "cancelled"}})
                            return
                        time.sleep(0.05)
                    shutil.copyfile(params["input"], params["output"])
                    send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    return
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})

        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get("method")
            if method == "shutdown":
                break
            if method == "$/cancelRequest":
                cid = (msg.get("params") or {}).get("id")
                if cid is not None:
                    cancelled.add(cid)
                continue
            threading.Thread(target=handle, args=(msg,), daemon=True).start()
        """
        try py.write(to: dir.appending(path: "main.py"), atomically: true, encoding: .utf8)
    }

    func makeColorBook(in parent: URL? = nil, name: String, count: Int, size: CGSize) throws -> URL {
        let dir = (parent ?? temporary).appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let colors: [NSColor] = [
            NSColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1),
            NSColor(srgbRed: 0.15, green: 0.85, blue: 0.2, alpha: 1),
            NSColor(srgbRed: 0.15, green: 0.25, blue: 0.9, alpha: 1),
            NSColor(srgbRed: 0.9, green: 0.75, blue: 0.1, alpha: 1),
        ]
        for i in 0..<count {
            let color = colors[i % colors.count]
            try writePNG(to: dir.appending(path: String(format: "p%02d.png", i + 1)), size: size, color: color)
        }
        return dir
    }

    private func writePNG(to url: URL, size: CGSize, color: NSColor) throws {
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        guard let img = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private func writeAnimatedGIF(to url: URL, size: CGSize) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
        for color in [NSColor.red, NSColor.blue] {
            guard let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let img = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func writeOrCopyVideo(to url: URL) throws {
        let videoFixtures = repoRoot.appending(path: "Fixtures/local/generated/video", directoryHint: .isDirectory)
        if let items = try? FileManager.default.contentsOfDirectory(at: videoFixtures, includingPropertiesForKeys: nil),
           let existing = items.first(where: { $0.pathExtension.lowercased() == "mp4" }) {
            try FileManager.default.copyItem(at: existing, to: url)
            return
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func makeZip(from directory: URL, to destination: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = directory
        proc.arguments = ["-qr", destination.path, "."]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    private static func isGrayscale(_ contents: Any) -> Bool? {
        if let surface = contents as? IOSurface {
            surface.lock(options: .readOnly, seed: nil)
            defer { surface.unlock(options: .readOnly, seed: nil) }
            let w = IOSurfaceGetWidth(surface)
            let h = IOSurfaceGetHeight(surface)
            let bpr = IOSurfaceGetBytesPerRow(surface)
            guard w > 0, h > 0 else { return nil }
            let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            let x = w / 2
            let y = h / 2
            let offset = y * bpr + x * 4
            let b = Int(base[offset])
            let g = Int(base[offset + 1])
            let r = Int(base[offset + 2])
            let spread = max(abs(r - g), abs(r - b), abs(g - b))
            return spread <= 6
        }
        return nil
    }

    private static func scriptsMenuContainsPluginCommand(scriptsTitle: String, pluginName: String, commandTitle: String) -> Bool {
        guard let scriptsMenu = NSApp.mainMenu?.items.first(where: { $0.title == scriptsTitle })?.submenu,
              let pluginSub = scriptsMenu.items.first(where: { $0.title == pluginName })?.submenu else {
            return false
        }
        return pluginSub.items.contains { $0.title == commandTitle }
    }

    func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        _ = await waitUntil(timeoutMs: 5000) {
            guard let book = controller.session.book else { return false }
            return book.isEnumerated && book.pages.count == expectedCount && book.pages.allSatisfy { $0.metadata != nil }
        }
    }

    func triggerMenuItem(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func sendKey(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) async {
        var cgFlags = CGEventFlags()
        if modifiers.contains(.command) { cgFlags.insert(.maskCommand) }
        if modifiers.contains(.option) { cgFlags.insert(.maskAlternate) }
        if modifiers.contains(.control) { cgFlags.insert(.maskControl) }
        if modifiers.contains(.shift) { cgFlags.insert(.maskShift) }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            if NSApp.keyWindow != nil {
                NSApp.sendEvent(event)
            } else if event.type == .keyUp {
                window.sendEvent(event)
            } else {
                if !window.performKeyEquivalent(with: event), NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                    window.sendEvent(event)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    func settle(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    func waitUntil(timeoutMs: Int, intervalMs: Int = 40, condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return condition()
    }

    // MARK: - settings（C3.1–C3.12）

    private func runSettingsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let pluginLib = services.pluginLibrary,
              let pluginSettings = services.pluginSettings,
              let pluginSecrets = services.pluginSecrets else {
            log.check(false, "插件界面自检缺少必要服务")
            return
        }

        let isEnglish = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
        let langTag = isEnglish ? "en" : "zh"
        let appearanceTag = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"

        // 准备 4 页高饱和纯色书，供 C3.3 主窗响应与 C3.9–C3.11 效果面板验证。
        let bookDir = try makeColorBook(name: "settings-filter-book", count: 4, size: CGSize(width: 480, height: 640))
        await openBook(controller, url: bookDir, expectedCount: 4)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.effects = .empty
        }
        controller.session.go(.index(0))
        await settle(200)

        // MARK: C3.4 「管理来源…」打开扩展页并定位到插件一节
        let sourcesMenu = NSMenu()
        plugins.populateSourcesMenu(sourcesMenu)
        if let manageItem = sourcesMenu.items.last {
            triggerMenuItem(manageItem)
        }
        let settingsOpened = await waitUntil(timeoutMs: 3000) {
            guard let sc = self.activeSettingsController(), let win = sc.window else { return false }
            return win.isVisible &&
                sc.state.page == .extensions &&
                sc.state.scrollTarget?.section == "settings.extensions.plugins"
        }
        guard let settingsController = activeSettingsController(),
              let settingsWindow = settingsController.window else {
            log.check(false, "C3.4 「管理来源…」打开设置窗口失败")
            return
        }
        settingsWindow.setContentSize(NSSize(width: 680, height: 740))
        TestPresentation.place(settingsWindow)
        settingsWindow.makeKeyAndOrderFront(nil)
        await settle(300)
        let pluginsSectionVisible = isAXVisibleInScrollView(identifier: "settings.extensions.plugins", in: settingsWindow)
        log.check(settingsOpened && pluginsSectionVisible, "C3.4 「管理来源…」打开扩展页并定位到插件一节(opened=\(settingsOpened),visible=\(pluginsSectionVisible))")

        let extModel = settingsController.state.model.extensions

        // 验证最小宽度 640 下 10 页签仍单行居中且不截断
        settingsWindow.setContentSize(NSSize(width: 640, height: 740))
        await settle(150)
        let tabFrames = SettingsPage.allCases.compactMap { page -> NSRect? in
            guard let el = findAXElement(in: settingsWindow, identifier: "settings.tab.\(page.rawValue)") else { return nil }
            return axFrameInWindow(el, window: settingsWindow)
        }
        let tabsSingleRow = tabFrames.count == SettingsPage.allCases.count &&
            tabFrames.allSatisfy { abs($0.midY - tabFrames[0].midY) < 4 && $0.minX >= 0 && $0.maxX <= 640 }
        settingsWindow.setContentSize(NSSize(width: 680, height: 740))
        await settle(150)
        log.check(tabsSingleRow, "C3.12 640 宽度下 10 个设置页签单行完整显示(count=\(tabFrames.count))")

        // MARK: C3.1 往插件目录拷入示例插件，2 秒内出现在列表，状态「未启用」
        try copyExamplePlugin("webdav", to: pluginLib.directory)
        let disabledText = String(localized: "未启用")
        let c31OK = await waitUntil(timeoutMs: 2000) {
            extModel.plugins.contains { $0.id == "webdav" } &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.webdav") != nil &&
            self.axText(identifier: "settings.extensions.plugin.webdav.status", in: settingsWindow).contains(disabledText)
        }
        log.check(c31OK, "C3.1 拷入 WebDAV 示例插件 2 秒内出现在列表且状态「\(disabledText)」")

        // MARK: C3.2 清单写坏的插件行显示文件、行列、原因、标红且无开关
        let brokenDir = pluginLib.directory.appending(path: "broken-manifest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        try """
        {
          "name": "坏清单",
          "version": "1.0"
        }
        """.write(to: brokenDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let manifestErrTitle = String(localized: "清单错误")
        let c32Detected = await waitUntil(timeoutMs: 2000) {
            guard let info = extModel.plugins.first(where: { $0.id == "broken-manifest" }),
                  let prob = info.problem,
                  let line = prob.line,
                  let col = prob.column else { return false }
            let rowText = self.axText(identifier: "settings.extensions.plugin.broken-manifest", in: settingsWindow)
            let statusText = self.axText(identifier: "settings.extensions.plugin.broken-manifest.status", in: settingsWindow)
            let noSwitch = self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.broken-manifest.toggle") == nil
            return statusText.contains(manifestErrTitle) &&
                rowText.contains("manifest.json") &&
                rowText.contains("\(line)") &&
                rowText.contains("\(col)") &&
                rowText.contains("runtime") &&
                noSwitch
        }
        await scrollAXIntoView(identifier: "settings.extensions.plugin.broken-manifest", in: settingsWindow)
        await settle(150)
        let brokenRedPx = countDangerPixels(inAXIdentifier: "settings.extensions.plugin.broken-manifest", in: settingsWindow)
        log.check(c32Detected && brokenRedPx > 0, "C3.2 坏清单插件行显示 manifest.json、行列与原因，标红(redPx=\(brokenRedPx))且无开关")
        // 原因来自 Core，英文界面下整行不能夹中文
        let brokenRowText = axText(identifier: "settings.extensions.plugin.broken-manifest", in: settingsWindow)
        let brokenRowHasCJK = brokenRowText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        log.check(!isEnglish || !brokenRowHasCJK, "C3.2b 英文界面坏清单原因为英文(rowText=\(brokenRowText))")

        // MARK: C3.5 打开 WebDAV 开关弹出「运行外部程序（完全信任）」，取消回关闭，启用变就绪
        let readyText = String(localized: "就绪")
        let fullTrustTitle = String(localized: "运行外部程序（完全信任）")
        let clickedWebdav1 = await clickAX(identifier: "settings.extensions.plugin.webdav.toggle", in: settingsWindow)
        let processSheetAppeared = await waitUntil(timeoutMs: 2000) {
            guard let sheet = settingsWindow.attachedSheet else { return false }
            return self.axText(identifier: "settings.plugins.consent", in: sheet).contains(fullTrustTitle)
        }
        if let sheet = settingsWindow.attachedSheet {
            await settle(150)
            log.snapshot(sheet, "plugins-consent-process-\(langTag)-\(appearanceTag)")
            _ = await clickAX(identifier: "settings.plugins.consent.cancel", in: sheet)
        }
        let cancelledStaysOff = await waitUntil(timeoutMs: 2000) {
            settingsWindow.attachedSheet == nil &&
            extModel.pluginStatus(for: extModel.plugins.first { $0.id == "webdav" }!) == .disabled &&
            self.axText(identifier: "settings.extensions.plugin.webdav.status", in: settingsWindow).contains(disabledText)
        }

        let clickedWebdav2 = await clickAX(identifier: "settings.extensions.plugin.webdav.toggle", in: settingsWindow)
        let processSheetAgain = await waitUntil(timeoutMs: 2000) { settingsWindow.attachedSheet != nil }
        if let sheet = settingsWindow.attachedSheet {
            _ = await clickAX(identifier: "settings.plugins.consent.enable", in: sheet)
        }
        let webdavEnabledReady = await waitUntil(timeoutMs: 2500) {
            settingsWindow.attachedSheet == nil &&
            self.axText(identifier: "settings.extensions.plugin.webdav.status", in: settingsWindow).contains(readyText) &&
            pluginSettings.value().plugins["webdav"]?.enabled == true
        }
        log.check(
            clickedWebdav1 && processSheetAppeared && cancelledStaysOff && clickedWebdav2 && processSheetAgain && webdavEnabledReady,
            "C3.5 WebDAV 权限表单列出「\(fullTrustTitle)」，取消保持未启用，启用后变为就绪"
        )

        // MARK: C3.6 Wikimedia 只列「访问网络」；含 commands 的测试 JS 插件列出「执行 MacView 命令」
        try copyExamplePlugin("wikimedia-commons", to: pluginLib.directory)
        let cmdPermDir = pluginLib.directory.appending(path: "cmd-perm-ui", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cmdPermDir, withIntermediateDirectories: true)
        try """
        {
          "name": "命令权限示例",
          "version": "1.0",
          "description": "测试命令权限确认与变更",
          "runtime": { "js": "main.js" },
          "permissions": ["commands"],
          "commands": [{ "id": "noop", "title": "测试命令" }]
        }
        """.write(to: cmdPermDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "plugin.commands.noop = () => {};\n".write(to: cmdPermDir.appending(path: "main.js"), atomically: true, encoding: .utf8)

        let jsPluginsListed = await waitUntil(timeoutMs: 2500) {
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.wikimedia-commons.toggle") != nil &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.cmd-perm-ui.toggle") != nil
        }
        let networkPermTitle = String(localized: "访问网络")
        let commandsPermTitle = String(localized: "执行 MacView 命令")

        _ = await clickAX(identifier: "settings.extensions.plugin.wikimedia-commons.toggle", in: settingsWindow)
        let wikiSheetOK = await waitUntil(timeoutMs: 2000) {
            guard let sheet = settingsWindow.attachedSheet else { return false }
            let text = self.axText(identifier: "settings.plugins.consent", in: sheet)
            return text.contains(networkPermTitle) && !text.contains(commandsPermTitle)
        }
        if let sheet = settingsWindow.attachedSheet {
            _ = await clickAX(identifier: "settings.plugins.consent.cancel", in: sheet)
            _ = await waitUntil(timeoutMs: 1500) { settingsWindow.attachedSheet == nil }
        }

        _ = await clickAX(identifier: "settings.extensions.plugin.cmd-perm-ui.toggle", in: settingsWindow)
        let cmdSheetOK = await waitUntil(timeoutMs: 2000) {
            guard let sheet = settingsWindow.attachedSheet else { return false }
            let text = self.axText(identifier: "settings.plugins.consent", in: sheet)
            return text.contains(commandsPermTitle) && !text.contains(networkPermTitle)
        }
        if let sheet = settingsWindow.attachedSheet {
            _ = await clickAX(identifier: "settings.plugins.consent.enable", in: sheet)
            _ = await waitUntil(timeoutMs: 2000) {
                settingsWindow.attachedSheet == nil &&
                self.axText(identifier: "settings.extensions.plugin.cmd-perm-ui.status", in: settingsWindow).contains(readyText)
            }
        }
        log.check(jsPluginsListed && wikiSheetOK && cmdSheetOK, "C3.6 Wikimedia 仅列「\(networkPermTitle)」，测试插件列出「\(commandsPermTitle)」")

        // MARK: C3.7 清单新增权限后状态为「权限有变」，「查看…」同意后恢复
        try """
        {
          "name": "命令权限示例",
          "version": "1.1",
          "description": "测试命令权限确认与变更",
          "runtime": { "js": "main.js" },
          "permissions": ["network", "commands"],
          "commands": [{ "id": "noop", "title": "测试命令" }]
        }
        """.write(to: cmdPermDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let needsConsentText = String(localized: "权限有变，需重新同意")
        let needsConsentDetected = await waitUntil(timeoutMs: 2500) {
            self.axText(identifier: "settings.extensions.plugin.cmd-perm-ui.status", in: settingsWindow).contains(needsConsentText) &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.cmd-perm-ui.review") != nil
        }
        _ = await clickAX(identifier: "settings.extensions.plugin.cmd-perm-ui.review", in: settingsWindow)
        let reviewSheetShowsBoth = await waitUntil(timeoutMs: 2000) {
            guard let sheet = settingsWindow.attachedSheet else { return false }
            let text = self.axText(identifier: "settings.plugins.consent", in: sheet)
            return text.contains(networkPermTitle) && text.contains(commandsPermTitle)
        }
        if let sheet = settingsWindow.attachedSheet {
            await settle(150)
            log.snapshot(sheet, "plugins-consent-js-\(langTag)-\(appearanceTag)")
            _ = await clickAX(identifier: "settings.plugins.consent.enable", in: sheet)
        }
        let recoveredReady = await waitUntil(timeoutMs: 2500) {
            settingsWindow.attachedSheet == nil &&
            self.axText(identifier: "settings.extensions.plugin.cmd-perm-ui.status", in: settingsWindow).contains(readyText) &&
            Set(pluginSettings.value().plugins["cmd-perm-ui"]?.grantedPermissions ?? []) == [.network, .commands]
        }
        log.check(needsConsentDetected && reviewSheetShowsBoth && recoveredReady, "C3.7 清单新增权限后显示「\(needsConsentText)」，点「查看…」同意后恢复就绪")

        // MARK: C3.3 运行中显示计时与「停止」，点停止 1 秒内回到就绪，期间窗口可操作
        let loopDir = pluginLib.directory.appending(path: "loop-ui-test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loopDir, withIntermediateDirectories: true)
        try """
        {
          "name": "死循环插件",
          "version": "1.0",
          "runtime": { "js": "main.js" },
          "permissions": [],
          "commands": [{ "id": "spin", "title": "死循环" }]
        }
        """.write(to: loopDir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "plugin.commands.spin = () => { while (true) {} };\n".write(to: loopDir.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try await pluginSettings.update { file in
            file.plugins["loop-ui-test"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let loopCmdID = PluginCoordinator.commandID(plugin: "loop-ui-test", command: "spin")
        let loopReady = await waitUntil(timeoutMs: 2500) {
            services.commands.descriptors().contains { $0.id == loopCmdID } &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.loop-ui-test") != nil
        }
        let spinTask = Task {
            try? await services.commands.perform(
                loopCmdID,
                arguments: nil,
                context: CommandContext(session: controller.session.id, scope: .global, selection: [])
            )
        }
        let runningPrefix = String(localized: "运行中 \("")").trimmingCharacters(in: .whitespaces)
        let loopRunning = await waitUntil(timeoutMs: 2500) {
            let status = self.axText(identifier: "settings.extensions.plugin.loop-ui-test.status", in: settingsWindow)
            return status.contains(runningPrefix) &&
                self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.loop-ui-test.stop") != nil
        }

        // 运行期间验证主窗口与设置窗口均可操作
        let pageBefore = controller.session.currentPage
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.viewer)
        await settle(80)
        await sendKey(kVK_RightArrow, in: window)
        let mainWindowResponsive = await waitUntil(timeoutMs: 1200) { controller.session.currentPage != pageBefore }

        settingsWindow.makeKeyAndOrderFront(nil)
        await settle(80)
        let clickedBrowse = await clickAX(identifier: "settings.tab.browse", in: settingsWindow)
        let switchedBrowse = await waitUntil(timeoutMs: 1200) { settingsController.state.page == .browse }
        let clickedExt = await clickAX(identifier: "settings.tab.extensions", in: settingsWindow)
        let switchedExt = await waitUntil(timeoutMs: 1500) {
            settingsController.state.page == .extensions &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.loop-ui-test.stop") != nil
        }

        let stopStart = ContinuousClock.now
        let clickedStop = await clickAX(identifier: "settings.extensions.plugin.loop-ui-test.stop", in: settingsWindow)
        let stoppedWithin1s = await waitUntil(timeoutMs: 1000, intervalMs: 25) {
            self.axText(identifier: "settings.extensions.plugin.loop-ui-test.status", in: settingsWindow).contains(readyText) &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.plugin.loop-ui-test.stop") == nil
        }
        let stopElapsedMs = (ContinuousClock.now - stopStart).milliseconds
        _ = await spinTask.value
        log.check(
            loopReady && loopRunning && mainWindowResponsive && clickedBrowse && switchedBrowse && clickedExt && switchedExt && clickedStop && stoppedWithin1s && stopElapsedMs <= 1000,
            "C3.3 死循环插件显示运行中与停止，期间主窗/设置窗可操作，点停止 \(Int(stopElapsedMs)) ms 回到就绪"
        )
        try? FileManager.default.removeItem(at: loopDir)
        _ = await waitUntil(timeoutMs: 2000) { !extModel.plugins.contains { $0.id == "loop-ui-test" } }

        // MARK: C3.8 添加 WebDAV 来源（plugins.json 无密码、secrets 600）、编辑留空不改、删除同时删密码
        let clickedAddSource = await clickAX(identifier: "settings.extensions.plugin.webdav.addSource", in: settingsWindow)
        let sourceSheetOpened = await waitUntil(timeoutMs: 2000) {
            guard let sheet = settingsWindow.attachedSheet else { return false }
            return self.findAXElement(in: sheet, identifier: "settings.plugins.sourceForm.name") != nil
        }
        var addedOK = false
        var secretsPerm600 = false
        var noPasswordInSettingsJSON = false
        var sourceID: UUID?
        if let sheet = settingsWindow.attachedSheet {
            let typedName = await typeIntoAXField(identifier: "settings.plugins.sourceForm.name", text: "家里 NAS", in: sheet)
            let typedURL = await typeIntoAXField(identifier: "settings.plugins.sourceForm.field.url", text: "https://nas.local:5006/dav", in: sheet)
            let typedUser = await typeIntoAXField(identifier: "settings.plugins.sourceForm.field.user", text: "yuwk", in: sheet)
            let typedPass = await typeIntoAXField(identifier: "settings.plugins.sourceForm.field.password", text: "s3cr3t-pass", in: sheet)
            await settle(150)
            log.snapshot(sheet, "plugins-source-form-\(langTag)-\(appearanceTag)")
            let clickedSave = await clickAX(identifier: "settings.plugins.sourceForm.save", in: sheet)
            let saved = await waitUntil(timeoutMs: 2500) {
                settingsWindow.attachedSheet == nil &&
                pluginSettings.value().sources.contains { $0.name == "家里 NAS" }
            }
            sourceID = pluginSettings.value().sources.first(where: { $0.name == "家里 NAS" })?.id
            addedOK = typedName && typedURL && typedUser && typedPass && clickedSave && saved && sourceID != nil
        }

        let pluginsJSONPath = app.supportDirectory.appending(path: "plugins.json")
        let secretsJSONPath = app.supportDirectory.appending(path: "plugin-secrets.json")
        if let jsonText = try? String(contentsOf: pluginsJSONPath, encoding: .utf8) {
            noPasswordInSettingsJSON = jsonText.contains("家里 NAS") && !jsonText.contains("s3cr3t-pass")
        }
        var st = stat()
        if stat(secretsJSONPath.path, &st) == 0 {
            secretsPerm600 = (st.st_mode & 0o777) == 0o600
        }
        let secretStored = sourceID.map { pluginSecrets.values(for: $0)["password"] == "s3cr3t-pass" } ?? false

        // 此时插件一节内容饱满（WebDAV 就绪+来源、Wikimedia 未启用、命令权限示例就绪、坏清单标红），截取整页插件一节截图
        await scrollAXIntoView(identifier: "settings.extensions.plugins", in: settingsWindow)
        await settle(200)
        log.snapshot(settingsWindow, "plugins-section-\(langTag)-\(appearanceTag)")

        // 编辑来源：密码不回显、留空保存后密码不变
        var editKeptSecret = false
        var deletedBoth = false
        if let id = sourceID {
            let idStr = id.uuidString
            let clickedEdit = await clickAX(identifier: "settings.extensions.source.\(idStr).edit", in: settingsWindow)
            let editSheetOpened = await waitUntil(timeoutMs: 2000) { settingsWindow.attachedSheet != nil }
            if let sheet = settingsWindow.attachedSheet {
                let passNotEchoed = !axText(identifier: "settings.plugins.sourceForm.field.password", in: sheet).contains("s3cr3t-pass")
                let renamed = await typeIntoAXField(identifier: "settings.plugins.sourceForm.name", text: "家里 NAS 2", in: sheet)
                let savedEdit = await clickAX(identifier: "settings.plugins.sourceForm.save", in: sheet)
                let editDone = await waitUntil(timeoutMs: 2500) {
                    settingsWindow.attachedSheet == nil &&
                    pluginSettings.value().sources.contains { $0.id == id && $0.name == "家里 NAS 2" }
                }
                editKeptSecret = clickedEdit && editSheetOpened && passNotEchoed && renamed && savedEdit && editDone &&
                    pluginSecrets.values(for: id)["password"] == "s3cr3t-pass"
            }

            // 删除来源后密码也一并删除
            let clickedDel = await clickAX(identifier: "settings.extensions.source.\(idStr).delete", in: settingsWindow)
            let confirmReady = await waitUntil(timeoutMs: 1500) {
                self.findAXElement(in: settingsWindow, identifier: "settings.extensions.source.\(idStr).confirmDelete") != nil
            }
            let clickedConfirm = await clickAX(identifier: "settings.extensions.source.\(idStr).confirmDelete", in: settingsWindow)
            let removed = await waitUntil(timeoutMs: 2500) {
                !pluginSettings.value().sources.contains { $0.id == id } &&
                pluginSecrets.values(for: id).isEmpty
            }
            deletedBoth = clickedDel && confirmReady && clickedConfirm && removed
        }
        log.check(
            clickedAddSource && sourceSheetOpened && addedOK && noPasswordInSettingsJSON && secretsPerm600 && secretStored && editKeptSecret && deletedBoth,
            "C3.8 添加来源无明文密码(noPlain=\(noPasswordInSettingsJSON),600=\(secretsPerm600),secret=\(secretStored))、编辑留空保留密码(\(editKeptSecret))、删除同步删密码(\(deletedBoth))"
        )
        settingsWindow.close()

        // MARK: C3.9–C3.11 效果面板「插件滤镜」一节
        try copyExamplePlugin("grayscale", to: pluginLib.directory)
        try writeParamAndSlowFilterPlugin(in: pluginLib.directory)
        try await pluginSettings.update { file in
            file.plugins["grayscale"] = PluginState(enabled: true, grantedPermissions: [])
            file.plugins["param-filter"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let filterPluginsReady = await waitUntil(timeoutMs: 3000) {
            plugins.enabledPlugins.contains { $0.id == "grayscale" } &&
            plugins.enabledPlugins.contains { $0.id == "param-filter" }
        }

        window.makeKeyAndOrderFront(nil)
        controller.session.go(.index(0))
        controller.run(.effectsPanelToggle)
        await settle(250)
        guard let effectsPanel = controller.effectsPanel else {
            log.check(false, "C3.9 打开效果面板失败")
            return
        }
        let section = effectsPanel.panelView.pluginFiltersSection
        let sectionVisible = await waitUntil(timeoutMs: 2500) {
            !section.isHidden && section.switchControl(plugin: "grayscale", filter: "grayscale") != nil
        }

        // C3.9：真实点击打开「灰度」-> 原图先显后变灰；再开慢滤镜 -> 行内出现「处理中」随后消失
        let page0InitiallyColor = await waitUntil(timeoutMs: 3000) {
            controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == false
        }
        if let graySwitch = section.switchControl(plugin: "grayscale", filter: "grayscale") {
            clickNSView(graySwitch, in: window)
        }
        let becameGray = await waitUntil(timeoutMs: 8000) {
            guard let slot = controller.viewer.paged.slots.first, slot.isShowingFiltered, let c = slot.contents else { return false }
            return Self.isGrayscale(c) == true
        }

        let processingWord = String(localized: "处理中")
        if let slowSwitch = section.switchControl(plugin: "param-filter", filter: "slow") {
            clickNSView(slowSwitch, in: window)
        }
        let sawProcessing = await waitUntil(timeoutMs: 3500) {
            section.statusText(plugin: "param-filter", filter: "slow").contains(processingWord)
        }
        if let slowSwitch = section.switchControl(plugin: "param-filter", filter: "slow") {
            clickNSView(slowSwitch, in: window)
        }
        let processingCleared = await waitUntil(timeoutMs: 2500) {
            section.statusText(plugin: "param-filter", filter: "slow").isEmpty
        }
        log.check(
            filterPluginsReady && sectionVisible && page0InitiallyColor && becameGray && sawProcessing && processingCleared,
            "C3.9 效果面板打开灰度后原图变灰(\(page0InitiallyColor)->\(becameGray))，慢滤镜行内出现「\(processingWord)」(\(sawProcessing))随后消失(\(processingCleared))"
        )

        // 验证参数控件（number / bool / choice）
        if let tuneSwitch = section.switchControl(plugin: "param-filter", filter: "tune") {
            clickNSView(tuneSwitch, in: window)
        }
        let paramsShown = await waitUntil(timeoutMs: 2000) {
            section.parameterControl(plugin: "param-filter", filter: "tune", key: "strength") != nil &&
            section.parameterControl(plugin: "param-filter", filter: "tune", key: "preserve") != nil &&
            section.parameterControl(plugin: "param-filter", filter: "tune", key: "scale") != nil
        }
        log.check(paramsShown, "C3.9 展开带参数滤镜后显示 number/bool/choice 参数控件")

        // C3.11：保存显示配置再套用，插件滤镜条目随之恢复
        if let tuneSwitch = section.switchControl(plugin: "param-filter", filter: "tune") {
            clickNSView(tuneSwitch, in: window)
            await settle(150)
        }
        effectsPanel.saveProfile(name: "插件灰度配置", groups: [.effects], from: controller.session.settings)
        let profileSaved = await waitUntil(timeoutMs: 2500) {
            effectsPanel.profiles.contains { $0.name == "插件灰度配置" }
        }
        if let graySwitch = section.switchControl(plugin: "grayscale", filter: "grayscale") {
            clickNSView(graySwitch, in: window)
        }
        let restoredColor = await waitUntil(timeoutMs: 3000) {
            controller.viewer.paged.slots.first?.isShowingFiltered == false &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == false)
        }
        if let savedProfile = effectsPanel.profiles.first(where: { $0.name == "插件灰度配置" }) {
            DisplayProfileHelpers.applyToBook(savedProfile, in: controller)
        }
        let restoredGrayFromProfile = await waitUntil(timeoutMs: 6000) {
            controller.session.settings.effects.effects.contains {
                if case let .plugin(f) = $0 { return f.plugin == "grayscale" && f.filter == "grayscale" && f.enabled }
                return false
            } &&
            controller.viewer.paged.slots.first?.isShowingFiltered == true &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == true)
        }
        log.check(profileSaved && restoredColor && restoredGrayFromProfile, "C3.11 显示配置保存再套用后插件滤镜条目与灰度画面恢复")

        // C3.10：停用插件后灰显「插件未启用」，调色仍可用；截图效果面板；重启用后恢复
        if let tuneSwitch = section.switchControl(plugin: "param-filter", filter: "tune") {
            clickNSView(tuneSwitch, in: window)
            await settle(150)
        }
        try await pluginSettings.update { file in
            file.plugins["grayscale"]?.enabled = false
        }
        let disabledSubtitle = String(localized: "插件未启用")
        let grayDimmed = await waitUntil(timeoutMs: 3000) {
            section.isRowDimmed(plugin: "grayscale", filter: "grayscale") &&
            section.subtitleText(plugin: "grayscale", filter: "grayscale") == disabledSubtitle &&
            section.switchControl(plugin: "grayscale", filter: "grayscale")?.isEnabled == true
        }
        // 调色滑块仍可用
        if let brightnessSlider = effectsPanel.panelView.slider(for: .brightness) {
            let pt = brightnessSlider.convert(NSPoint(x: brightnessSlider.bounds.minX + brightnessSlider.bounds.width * 0.72, y: brightnessSlider.bounds.midY), to: nil)
            sendMouseClick(at: pt, in: window)
        }
        let colorAdjustStillWorks = await waitUntil(timeoutMs: 2000) {
            abs(controller.session.settings.effects.colorAdjust.brightness) > 0.05 &&
            controller.viewer.effectFilterCount > 0
        }

        // 截取效果面板截图（包含调色 + 参数化插件滤镜 + 灰显不可用插件滤镜）
        await settle(250)
        log.snapshot(window, "effects-plugin-filters-\(langTag)-\(appearanceTag)")

        // 重启用灰度插件 -> 行恢复可用，灰度生效
        try await pluginSettings.update { file in
            file.plugins["grayscale"]?.enabled = true
        }
        let grayRecovered = await waitUntil(timeoutMs: 6000) {
            !section.isRowDimmed(plugin: "grayscale", filter: "grayscale") &&
            section.subtitleText(plugin: "grayscale", filter: "grayscale") == "grayscale" &&
            controller.viewer.paged.slots.first?.isShowingFiltered == true &&
            (controller.viewer.paged.slots.first?.contents.flatMap(Self.isGrayscale) == true)
        }
        // 停用 param-filter 后点开关关掉不可用条目 -> 从效果链移除
        try await pluginSettings.update { file in
            file.plugins["param-filter"]?.enabled = false
        }
        let tuneDimmed = await waitUntil(timeoutMs: 2500) {
            section.isRowDimmed(plugin: "param-filter", filter: "tune")
        }
        if let tuneSwitch = section.switchControl(plugin: "param-filter", filter: "tune") {
            clickNSView(tuneSwitch, in: window)
        }
        let unavailableRemoved = await waitUntil(timeoutMs: 2500) {
            !controller.session.settings.effects.effects.contains {
                if case let .plugin(f) = $0 { return f.plugin == "param-filter" && f.filter == "tune" }
                return false
            }
        }
        log.check(
            grayDimmed && colorAdjustStillWorks && grayRecovered && tuneDimmed && unavailableRemoved,
            "C3.10 停用插件后灰显「\(disabledSubtitle)」且调色可用，重启用恢复，不可用条目可关掉移除"
        )

        // C3.12：英文文案无未翻译中文
        if isEnglish {
            let localizedSamples = [
                String(localized: "插件"),
                String(localized: "一个文件夹一个插件，放进插件目录后自动加载"),
                String(localized: "未启用"),
                String(localized: "清单错误"),
                String(localized: "权限有变，需重新同意"),
                String(localized: "查看…"),
                String(localized: "访问网络"),
                String(localized: "执行 MacView 命令"),
                String(localized: "运行外部程序（完全信任）"),
                String(localized: "＋ 添加来源"),
                String(localized: "编辑来源"),
                String(localized: "密码不写进 plugins.json。"),
                String(localized: "插件滤镜"),
                String(localized: "处理中"),
                String(localized: "失败"),
                String(localized: "插件未启用"),
            ]
            let untranslated = localizedSamples.filter { text in
                text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            }
            log.check(untranslated.isEmpty, "C3.12 英文界面文案完整无遗漏中文：\(untranslated)")
        } else {
            log.check(true, "C3.12 中文界面自检与截图完成")
        }
    }

    private func writeParamAndSlowFilterPlugin(in pluginsDir: URL) throws {
        let dir = pluginsDir.appending(path: "param-filter", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "name": "参数滤镜",
          "version": "1.0",
          "runtime": { "process": { "command": "/usr/bin/python3", "args": ["main.py"] } },
          "permissions": [],
          "filters": [
            {
              "id": "tune",
              "name": "超分",
              "parameters": [
                { "key": "scale", "label": "倍数", "type": "choice", "options": ["2×", "4×"], "default": "2×" },
                { "key": "strength", "label": "强度", "type": "number", "min": 0, "max": 1, "step": 0.1, "default": 0.5 },
                { "key": "preserve", "label": "保细节", "type": "bool", "default": true }
              ]
            },
            {
              "id": "slow",
              "name": "慢滤镜",
              "parameters": []
            }
          ]
        }
        """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)

        let py = """
        import json, shutil, sys, threading, time

        write_lock = threading.Lock()
        cancelled = set()

        def send(obj):
            with write_lock:
                sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\\n")
                sys.stdout.flush()

        def handle(msg):
            req_id = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                return
            if method == "filter.apply":
                flt = params.get("filter")
                if flt == "slow":
                    for _ in range(60):
                        if req_id in cancelled:
                            send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32800, "message": "cancelled"}})
                            return
                        time.sleep(0.05)
                shutil.copyfile(params["input"], params["output"])
                send({"jsonrpc": "2.0", "id": req_id, "result": {}})
                return
            send({"jsonrpc": "2.0", "id": req_id, "result": {}})

        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get("method")
            if method == "shutdown":
                break
            if method == "$/cancelRequest":
                cid = (msg.get("params") or {}).get("id")
                if cid is not None:
                    cancelled.add(cid)
                continue
            threading.Thread(target=handle, args=(msg,), daemon=True).start()
        """
        try py.write(to: dir.appending(path: "main.py"), atomically: true, encoding: .utf8)
    }

    // MARK: - 设置页与面板真实事件 / AX 辅助

    private func activeSettingsController() -> SettingsWindowController? {
        NSApp.windows.compactMap { $0.windowController as? SettingsWindowController }.first
    }

    private func axPerform(_ selector: Selector, on object: AnyObject) -> Any? {
        guard let obj = object as? NSObject, obj.responds(to: selector) else { return nil }
        return obj.perform(selector)?.takeUnretainedValue()
    }

    private func findAXElements(in root: AnyObject, identifier: String) -> [AnyObject] {
        var matches: [AnyObject] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: AnyObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            let matched: Bool = {
                if let id = axPerform(#selector(NSAccessibilityProtocol.accessibilityIdentifier), on: node) as? String, id == identifier { return true }
                if let view = node as? NSView, view.accessibilityIdentifier() == identifier { return true }
                return false
            }()
            if matched { matches.append(node) }
            if let win = node as? NSWindow, let content = win.contentView {
                walk(content)
            }
            if let axChildren = axPerform(#selector(NSAccessibilityProtocol.accessibilityChildren), on: node) as? [AnyObject] {
                for child in axChildren { walk(child) }
            }
            if let view = node as? NSView {
                for sub in view.subviews { walk(sub) }
            }
        }
        walk(root)
        return matches
    }

    private func findAXElement(in root: AnyObject, identifier: String) -> AnyObject? {
        findAXElements(in: root, identifier: identifier).first
    }

    private func axFrameInWindow(_ element: AnyObject, window: NSWindow) -> NSRect? {
        if let view = element as? NSView {
            return view.convert(view.bounds, to: nil)
        }
        if let proto = element as? NSAccessibilityProtocol {
            let screenFrame = proto.accessibilityFrame()
            if !screenFrame.isEmpty {
                return window.convertFromScreen(screenFrame)
            }
        }
        if let axEl = element as? NSAccessibilityElementProtocol {
            let screenFrame = axEl.accessibilityFrame()
            if !screenFrame.isEmpty {
                return window.convertFromScreen(screenFrame)
            }
        }
        return nil
    }

    private func axText(identifier: String, in window: NSWindow) -> String {
        let elements = findAXElements(in: window, identifier: identifier)
        guard !elements.isEmpty else { return "" }
        var pieces: [String] = []
        var visited = Set<ObjectIdentifier>()
        for element in elements {
            collectAXText(from: element, visited: &visited, into: &pieces)
        }
        return pieces.joined(separator: " ")
    }

    private func collectAXText(from element: AnyObject, visited: inout Set<ObjectIdentifier>, into out: inout [String]) {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return }
        if let value = axPerform(#selector(NSAccessibilityProtocol.accessibilityValue), on: element) as? String, !value.isEmpty {
            out.append(value)
        }
        if let title = axPerform(#selector(NSAccessibilityProtocol.accessibilityTitle), on: element) as? String, !title.isEmpty {
            out.append(title)
        }
        if let label = axPerform(#selector(NSAccessibilityProtocol.accessibilityLabel), on: element) as? String, !label.isEmpty {
            out.append(label)
        }
        if let children = axPerform(#selector(NSAccessibilityProtocol.accessibilityChildren), on: element) as? [AnyObject] {
            for child in children { collectAXText(from: child, visited: &visited, into: &out) }
        }
        if let view = element as? NSView {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field.stringValue) }
            if let textView = view as? NSTextView, !textView.string.isEmpty { out.append(textView.string) }
            for sub in view.subviews { collectAXText(from: sub, visited: &visited, into: &out) }
        }
    }

    private func outerScrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        var all: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let sv = view as? NSScrollView { all.append(sv) }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return all.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private func isAXVisibleInScrollView(identifier: String, in window: NSWindow) -> Bool {
        guard let sv = outerScrollView(in: window),
              let el = findAXElement(in: window, identifier: identifier),
              let rectInWindow = axFrameInWindow(el, window: window) else { return false }
        let svRect = sv.convert(sv.bounds, to: nil)
        return svRect.intersects(rectInWindow)
    }

    private func scrollAXIntoView(identifier: String, in window: NSWindow) async {
        guard !identifier.hasPrefix("settings.tab."),
              let sv = outerScrollView(in: window),
              let doc = sv.documentView,
              let el = findAXElement(in: window, identifier: identifier),
              let rectInWindow = axFrameInWindow(el, window: window) else { return }
        let svRectInWindow = sv.convert(sv.bounds, to: nil)
        if svRectInWindow.insetBy(dx: 0, dy: 8).contains(NSPoint(x: rectInWindow.midX, y: rectInWindow.midY)) {
            return
        }
        let rectInDoc = doc.convert(rectInWindow, from: nil)
        doc.scrollToVisible(rectInDoc.insetBy(dx: 0, dy: -24))
        sv.reflectScrolledClipView(sv.contentView)
        await settle(80)
    }

    private func clickAX(identifier: String, in window: NSWindow) async -> Bool {
        await scrollAXIntoView(identifier: identifier, in: window)
        guard let el = findAXElement(in: window, identifier: identifier),
              let rect = axFrameInWindow(el, window: window) else { return false }
        sendMouseClick(at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        return true
    }

    private func typeIntoAXField(identifier: String, text: String, in window: NSWindow) async -> Bool {
        await scrollAXIntoView(identifier: identifier, in: window)
        guard let el = findAXElement(in: window, identifier: identifier),
              let rect = axFrameInWindow(el, window: window) else { return false }
        sendMouseClick(at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        await settle(80)
        guard let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.count))
        return true
    }

    private func clickNSView(_ view: NSView, in window: NSWindow) {
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -16))
        let rect = view.convert(view.bounds, to: nil)
        sendMouseClick(at: NSPoint(x: rect.midX, y: rect.midY), in: window)
    }

    private var nextMouseEventNumber = 1

    func sendMouseClick(at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let now = ProcessInfo.processInfo.systemUptime
        let downNo = nextMouseEventNumber
        nextMouseEventNumber += 1
        let upNo = nextMouseEventNumber
        nextMouseEventNumber += 1
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: modifiers,
            timestamp: now, windowNumber: window.windowNumber, context: nil,
            eventNumber: downNo, clickCount: 1, pressure: 1
        ) {
            NSApp.sendEvent(down)
        }
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: modifiers,
            timestamp: now + 0.02, windowNumber: window.windowNumber, context: nil,
            eventNumber: upNo, clickCount: 1, pressure: 0
        ) {
            NSApp.sendEvent(up)
        }
    }

    private func countDangerPixels(inAXIdentifier identifier: String, in window: NSWindow) -> Int {
        guard let el = findAXElement(in: window, identifier: identifier),
              let rectInWindow = axFrameInWindow(el, window: window),
              let frameView = window.contentView?.superview else {
            return 0
        }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let image = frameView.renderedImage() else { return 0 }
        let scaleX = CGFloat(image.width) / max(frameView.bounds.width, 1)
        let scaleY = CGFloat(image.height) / max(frameView.bounds.height, 1)
        let rectInFrame = frameView.convert(rectInWindow, from: nil)
        let topY = frameView.isFlipped ? rectInFrame.minY : (frameView.bounds.height - rectInFrame.maxY)
        let crop = CGRect(
            x: max(0, floor(rectInFrame.minX * scaleX)),
            y: max(0, floor(topY * scaleY)),
            width: max(1, ceil(rectInFrame.width * scaleX)),
            height: max(1, ceil(rectInFrame.height * scaleY))
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let subImage = image.cropping(to: crop) else { return 0 }
        let width = subImage.width
        let height = subImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &rgba, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(subImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = Double(rgba[i]) / 255.0
            let g = Double(rgba[i + 1]) / 255.0
            let b = Double(rgba[i + 2]) / 255.0
            if (r - b) >= 0.14 && (r - g) >= 0.09 {
                count += 1
            }
        }
        return count
    }
}

/// 自检内托管的只读 WebDAV 测试服务进程。
private final class WebDAVServerHandle {
    let process: Process
    let baseURL: String
    let port: Int

    init(scriptURL: URL, root: URL, port: Int, user: String, password: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [
            scriptURL.path,
            "--root", root.path,
            "--port", String(port),
            "--user", user,
            "--password", password,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc

        // 逐字节读到首行 READY http://127.0.0.1:<port>/
        let fh = pipe.fileHandleForReading
        var buf = Data()
        while true {
            let chunk = fh.readData(ofLength: 1)
            if chunk.isEmpty { break }
            buf.append(chunk)
            if chunk[0] == 0x0A { break }
        }
        let line = String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("READY "),
              let url = URL(string: String(line.dropFirst(6))),
              let actualPort = url.port else {
            proc.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        self.baseURL = url.absoluteString
        self.port = actualPort
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

@MainActor
private final class MainThreadStallProbe {
    private var lastTick = ContinuousClock.now
    private(set) var maxStallMs = 0.0

    func tick() {
        let now = ContinuousClock.now
        let gap = (now - lastTick).milliseconds
        if gap > maxStallMs { maxStallMs = gap }
        lastTick = now
    }
}
#endif
