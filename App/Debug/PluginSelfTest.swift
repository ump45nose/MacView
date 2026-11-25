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

/// 插件宿主 App 接入自检（`-MVPluginSelfTest commands|sources|filters`）。
///
/// 覆盖阶段 2 的检查项 C2.1–C2.14：
/// - `commands`：C2.1、C2.2、C2.3、C2.4、C2.13 及中英文文案；
/// - `sources`（及内部冷重启子模式 `sources-reopen`）：C2.5、C2.6、C2.7、C2.8、C2.8b；
/// - `filters`：C2.9、C2.10、C2.11、C2.11b、C2.11c 与连续视图主区滤镜。
@MainActor
final class PluginSelfTest {
    static let launchKey = "MVPluginSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary: URL
    private let repoRoot: URL
    private weak var keyTarget: NSWindow?

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

    private func copyExamplePlugin(_ id: String, to pluginsDir: URL) throws {
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

    private func makeColorBook(in parent: URL? = nil, name: String, count: Int, size: CGSize) throws -> URL {
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

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        _ = await waitUntil(timeoutMs: 5000) {
            guard let book = controller.session.book else { return false }
            return book.isEnumerated && book.pages.count == expectedCount && book.pages.allSatisfy { $0.metadata != nil }
        }
    }

    private func triggerMenuItem(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private func sendKey(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) async {
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

    private func settle(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func waitUntil(timeoutMs: Int, intervalMs: Int = 40, condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(intervalMs))
        }
        return condition()
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
