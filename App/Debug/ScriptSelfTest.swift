#if DEBUG
import AppKit
import Carbon.HIToolbox
import Foundation
import MVCommands
import MVFoundation
import MVLibraryData
import MVReading
import MVScripting
import MVServices
import MVSettings

/// 脚本与外部命令自检（`-MVScriptSelfTest commands|events|external|settings`）。
///
/// 覆盖阶段 2 的检查项 C2.1–C2.17、C2.19 及阶段 3 设置「扩展」页检查项 C3.1–C3.6。
/// 需传独立的 `-MVSupportDirectory`、`-MVCacheDirectory`、`-MVLayoutFile`；夹具均写入隔离临时目录并在结束前清理。
@MainActor
final class ScriptSelfTest {
    static let launchKey = "MVScriptSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary: URL
    private weak var keyTarget: NSWindow?

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mode.isEmpty else { return }
        let missing = [AppDelegate.supportDirectoryKey, AppDelegate.cacheDirectoryKey, DockCoordinator.layoutFileKey]
            .filter { UserDefaults.standard.string(forKey: $0) == nil }
        if !missing.isEmpty {
            print("FAIL 脚本自检缺少隔离目录参数：\(missing.map { "-" + $0 }.joined(separator: " "))")
            fflush(stdout)
            exit(64)
        }
        let test = ScriptSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
        self.temporary = TestPresentation.scratchDirectory("script-\(mode)")
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
              let extensions = app.extensions,
              let controller = app.controllers.first,
              let window = controller.window else {
            log.check(false, "脚本自检需要真实服务、扩展管理器与主窗口")
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
                try await runCommandsSuite(controller: controller, window: window, services: services, extensions: extensions)
            case "events":
                try await runEventsSuite(controller: controller, window: window, services: services, extensions: extensions)
            case "external":
                try await runExternalSuite(controller: controller, window: window, services: services, extensions: extensions)
            case "settings":
                try await runSettingsSuite(controller: controller, window: window, services: services, extensions: extensions)
            default:
                log.check(false, "未知的 -MVScriptSelfTest 模式：\(mode)")
            }
        } catch {
            log.check(false, "脚本自检异常（\(mode)）：\(error)")
        }

        services.scriptRuntime?.stopAll()
        try? FileManager.default.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: - commands（C2.1–C2.10, C2.19）

    private func runCommandsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        extensions: ExtensionCommands
    ) async throws {
        guard let library = services.scriptLibrary,
              let storage = services.scriptStorage,
              let runtime = services.scriptRuntime else {
            log.check(false, "脚本服务未初始化")
            return
        }

        let initialReady = await waitUntil(timeoutMs: 3000) {
            extensions.scriptItems.contains { $0.id == "jump-middle" } &&
            extensions.scriptItems.contains { $0.id == "ask-next-book" }
        }
        log.check(initialReady, "初始异步扫描完成并加载内置示例脚本")

        // C2.1：放入、改名、删除后 2 秒内 CommandRegistry 与 SettingsCommandCatalog 同步变化
        let helloURL = library.directory.appending(path: "selftest-hello.js")
        let renamedURL = library.directory.appending(path: "selftest-renamed.js")
        try "// @name 自检你好\nmv.toast('hello');\n".write(to: helloURL, atomically: true, encoding: .utf8)
        let addedOK = await waitUntil(timeoutMs: 2000) {
            services.commands.descriptors().contains { $0.id == CommandID("script.selftest-hello") && $0.verbatimTitle == "自检你好" } &&
            SettingsCommandCatalog.all.contains { $0.id == CommandID("script.selftest-hello") }
        }
        log.check(addedOK, "C2.1 放入脚本后 2 秒内 CommandRegistry 与 SettingsCommandCatalog 同步新增")

        try FileManager.default.moveItem(at: helloURL, to: renamedURL)
        try "// @name 自检已改名\nmv.toast('renamed');\n".write(to: renamedURL, atomically: true, encoding: .utf8)
        let renamedOK = await waitUntil(timeoutMs: 2000) {
            !services.commands.descriptors().contains { $0.id == CommandID("script.selftest-hello") } &&
            services.commands.descriptors().contains { $0.id == CommandID("script.selftest-renamed") && $0.verbatimTitle == "自检已改名" } &&
            SettingsCommandCatalog.all.contains { $0.id == CommandID("script.selftest-renamed") }
        }
        log.check(renamedOK, "C2.1 改名脚本后 2 秒内命令清单同步更新")

        try FileManager.default.removeItem(at: renamedURL)
        let removedOK = await waitUntil(timeoutMs: 2000) {
            !services.commands.descriptors().contains { $0.id == CommandID("script.selftest-renamed") } &&
            !SettingsCommandCatalog.all.contains { $0.id == CommandID("script.selftest-renamed") }
        }
        log.check(removedOK, "C2.1 删除脚本后 2 秒内命令清单同步移除")

        // C2.2：给脚本命令绑 ⌃M 后经真实按键运行，删除脚本后不崩溃
        let hotkeyURL = library.directory.appending(path: "selftest-hotkey.js")
        let hotkeyID = CommandID("script.selftest-hotkey")
        try "// @name 自检热键\nmv.storage.set('hotkeyRan', true);\n".write(to: hotkeyURL, atomically: true, encoding: .utf8)
        let hotkeyRegistered = await waitUntil(timeoutMs: 2000) {
            services.commands.descriptors().contains { $0.id == hotkeyID }
        }
        try await services.keyBindings?.update { file in
            file.bindings.removeAll { $0.command == hotkeyID }
            file.bindings.append(KeyBinding(
                sequence: [KeyChord("m", modifiers: [.control])],
                command: hotkeyID,
                scope: .viewer
            ))
        }
        let bindingLoaded = await waitUntil(timeoutMs: 2000) {
            app.catalog.bindings.contains { $0.command == hotkeyID }
        }
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_M, modifiers: [.control], in: window)
        let hotkeyRan = await waitUntil(timeoutMs: 2500) {
            storage.get(hotkeyID.rawValue, "hotkeyRan") == .bool(true)
        }
        log.check(hotkeyRegistered && bindingLoaded && hotkeyRan, "C2.2 绑定 ⌃M 后经真实按键运行脚本成功")

        try FileManager.default.removeItem(at: hotkeyURL)
        let hotkeyRemoved = await waitUntil(timeoutMs: 2000) {
            !services.commands.descriptors().contains { $0.id == hotkeyID } &&
            !SettingsCommandCatalog.all.contains { $0.id == hotkeyID }
        }
        await sendKey(kVK_ANSI_M, modifiers: [.control], in: window)
        let unknownTitle = SettingsCommandCatalog.title(of: hotkeyID)
        log.check(hotkeyRemoved && unknownTitle == hotkeyID.rawValue, "C2.2 删除脚本后触发旧绑定与查询标题不崩溃：\(unknownTitle)")

        let shortcutsModel = ShortcutsModel(store: services.keyBindings)
        let expectedBinding = KeyBinding(
            sequence: [KeyChord("m", modifiers: [.control])],
            command: hotkeyID,
            scope: .viewer
        )
        let unknownSection = shortcutsModel.sections.last
        let unknownRow = unknownSection?.rows.first { $0.command == hotkeyID }
        let unknownShown = unknownSection?.isUnknown == true &&
            unknownSection?.title == ShortcutsModel.unknownSectionTitle &&
            unknownRow?.isUnknown == true &&
            unknownRow?.title == hotkeyID.rawValue &&
            unknownRow?.bindings == [expectedBinding]
        shortcutsModel.searchText = hotkeyID.rawValue
        let unknownSearchable = shortcutsModel.sections.last?.rows.contains { $0.command == hotkeyID } == true
        shortcutsModel.searchText = ""
        log.check(unknownShown && unknownSearchable, "C2.2 快捷键页末尾出现「未知命令」分组并显示残留绑定与原始 ID")

        if let bindingToRemove = unknownRow?.bindings.first {
            shortcutsModel.removeBinding(bindingToRemove)
        }
        let unknownClearedInModel = !shortcutsModel.sections.contains(where: \.isUnknown)
        let unknownClearedInStore = await waitUntil(timeoutMs: 2000) {
            services.keyBindings?.value().bindings.contains(where: { $0.command == hotkeyID }) == false
        }
        log.check(unknownClearedInModel && unknownClearedInStore, "C2.2 清除未知命令残留绑定后分组自动消失且写回 keybindings.json")

        // C2.3：menus.json 自定义主菜单时不自动出现「脚本」，且命令板含 DynamicMenuID.scripts
        let scriptsMenuTitle = String(localized: "脚本")
        try await services.menus?.update { file in
            file.mainMenu = [
                .submenu(titleKey: "文件", children: [.command(.fileOpen)]),
                .submenu(titleKey: "窗口", children: [.command(.windowNew)]),
            ]
        }
        let customApplied = await waitUntil(timeoutMs: 2000) {
            !(NSApp.mainMenu?.items.map(\.title).contains(scriptsMenuTitle) ?? true)
        }
        let paletteHasScripts = DynamicMenuID.allCases.contains(.scripts) &&
            MenusModel.dynamicTitle(of: .scripts) == scriptsMenuTitle
        log.check(customApplied && paletteHasScripts, "C2.3 自定义主菜单不自动加入「脚本」，命令板含 DynamicMenuID.scripts")

        try await services.menus?.update { $0.mainMenu = nil }
        let defaultRestored = await waitUntil(timeoutMs: 2000) {
            NSApp.mainMenu?.items.map(\.title).contains(scriptsMenuTitle) == true
        }
        log.check(defaultRestored, "C2.3 恢复默认主菜单后「脚本」菜单重新出现")

        // C2.4–C2.6：右键目标与无项禁用、主菜单固定三项仍在
        let bookA = try makeBook(name: "book-a", count: 5)
        await openBook(controller, url: bookA, expectedCount: 5)
        let selScriptURL = library.directory.appending(path: "selftest-selection.js")
        try "// @name 记录选中项\nmv.storage.set('sel', mv.selection());\n".write(to: selScriptURL, atomically: true, encoding: .utf8)
        let selReady = await waitUntil(timeoutMs: 2000) {
            extensions.scriptItems.contains { $0.id == "selftest-selection" }
        }
        log.check(selReady, "辅助选中项脚本就绪")

        let pages = controller.session.book?.pages ?? []
        let threeEntries = Array(pages.prefix(3).map(\.entry))
        if let fileOps = app.fileOps,
           let listMenu = Optional(fileOps.contextMenu(for: FileOrigin(window: controller, items: threeEntries))),
           let scriptsSub = listMenu.items.first(where: { $0.title == scriptsMenuTitle })?.submenu,
           let actionItem = scriptsSub.items.first(where: { $0.title == "记录选中项" }) {
            triggerMenuItem(actionItem)
            let expectedTokens = threeEntries.map { JSONValue.string(ScriptLocationCodec.token(for: $0.location)) }
            let listOK = await waitUntil(timeoutMs: 2500) {
                storage.get("script.selftest-selection", "sel") == .array(expectedTokens)
            }
            log.check(listOK, "C2.4 页面列表右键 3 页运行脚本收到对应 3 页目标")
        } else {
            log.check(false, "C2.4 未找到页面列表右键「脚本」菜单项")
        }

        controller.session.go(.index(1))
        await settle(150)
        if let builder = app.menuBuilder,
           let provider = app.contextMenuProvider,
           pages.indices.contains(1) {
            let viewerMenu = builder.contextMenu(
                nodes: app.catalog.viewerContextMenu,
                provider: provider,
                target: ContextMenuTarget(window: controller, entries: [pages[1].entry])
            )
            if let scriptsSub = viewerMenu.items.first(where: { $0.title == scriptsMenuTitle })?.submenu,
               let actionItem = scriptsSub.items.first(where: { $0.title == "记录选中项" }) {
                triggerMenuItem(actionItem)
                let expected = JSONValue.array([.string(ScriptLocationCodec.token(for: pages[1].id))])
                let viewerOK = await waitUntil(timeoutMs: 2500) {
                    storage.get("script.selftest-selection", "sel") == expected
                }
                log.check(viewerOK, "C2.5 查看器右键运行脚本收到当前页目标")
            } else {
                log.check(false, "C2.5 未找到查看器右键「脚本」菜单项")
            }
        }

        // C2.6：移走全部脚本与外部命令，验证右键子菜单禁用、主菜单固定三项仍在
        let stashDir = temporary.appending(path: "stashed-scripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stashDir, withIntermediateDirectories: true)
        let savedScripts = try moveScripts(from: library.directory, to: stashDir)
        try await services.externalCommands?.update { $0.commands = [] }
        let cleared = await waitUntil(timeoutMs: 2500) {
            extensions.scriptItems.isEmpty && extensions.externalItems.isEmpty
        }
        let listDisabled = app.fileOps?.contextMenu(for: FileOrigin(window: controller, items: Array(threeEntries.prefix(1))))
            .items.first(where: { $0.title == scriptsMenuTitle })?.isEnabled == false
        let viewerDisabled: Bool = {
            guard let builder = app.menuBuilder, let provider = app.contextMenuProvider, let first = pages.first else { return false }
            let menu = builder.contextMenu(
                nodes: app.catalog.viewerContextMenu,
                provider: provider,
                target: ContextMenuTarget(window: controller, entries: [first.entry])
            )
            return menu.items.first(where: { $0.title == scriptsMenuTitle })?.isEnabled == false
        }()
        let mainScriptsTitles = NSApp.mainMenu?.items.first(where: { $0.title == scriptsMenuTitle })?.submenu?.items.map(\.title) ?? []
        let fixedTitles = [CommandID.scriptStopAll, .scriptRevealFolder, .scriptManage].map { app.catalog.title(of: $0) }
        let fixedPresent = fixedTitles.allSatisfy { mainScriptsTitles.contains($0) }
        log.check(cleared && listDisabled && viewerDisabled && fixedPresent, "C2.6 无脚本和外部命令时右键子菜单禁用且主菜单固定三项仍在")

        // 恢复示例脚本（不恢复临时 selftest-selection.js）
        for url in savedScripts where url.lastPathComponent != "selftest-selection.js" {
            let dest = library.directory.appending(path: url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
        _ = await waitUntil(timeoutMs: 2500) { extensions.scriptItems.contains { $0.id == "jump-middle" } }

        // C2.7：“跳到中间页”脚本运行后页码为 ⌊页数/2⌋ + 1（0-based 为 pages.count / 2）
        controller.session.go(.index(0))
        await settle(150)
        try await services.commands.perform(
            CommandID("script.jump-middle"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let expectedZeroBased = pages.count / 2
        let jumped = await waitUntil(timeoutMs: 2500) { controller.session.currentPage == expectedZeroBased }
        log.check(jumped, "C2.7 跳到中间页脚本将 5 页书跳到第 \(controller.session.currentPage + 1) 页（期望 \(expectedZeroBased + 1)）")

        // C2.8：mv.page() 与 mv.book().location 往返 mv.open（本地目录、zip、嵌套 zip、虚拟书）
        let inspectURL = library.directory.appending(path: "selftest-inspect.js")
        let openURL = library.directory.appending(path: "selftest-open.js")
        try """
        // @name 自检探测
        mv.storage.set('book', mv.book());
        mv.storage.set('page', mv.page());
        """.write(to: inspectURL, atomically: true, encoding: .utf8)
        try """
        // @name 自检打开
        mv.open(mv.args.target);
        mv.storage.set('opened', mv.args.target);
        """.write(to: openURL, atomically: true, encoding: .utf8)
        _ = await waitUntil(timeoutMs: 2500) {
            extensions.scriptItems.contains { $0.id == "selftest-inspect" } &&
            extensions.scriptItems.contains { $0.id == "selftest-open" }
        }

        let bookZip = try makeZip(from: bookA, named: "book.zip")
        let nestedZip = try makeNestedZip(innerZip: bookZip, named: "nested.zip")
        let localBookLoc = try await services.sources.location(for: bookA)
        let zipBookLoc = try await services.sources.location(for: bookZip)
        let nestedOuterLoc = try await services.sources.location(for: nestedZip)
        let nestedInnerLoc = nestedOuterLoc.appendingLayer(["book.zip"])
        guard let libraryStore = services.library else {
            log.check(false, "C2.8 资料库服务不可用")
            return
        }
        let playlistID = try await libraryStore.createPlaylist(named: "脚本自检列表")
        let sampleEntries = Array(pages.prefix(2).map(\.entry))
        _ = try await libraryStore.addItems(sampleEntries, to: playlistID)
        let playlistLoc = Location.playlist(playlistID)

        let cases: [(label: String, location: Location, expectPathEqualsLocation: Bool, expectVirtual: Bool)] = [
            ("本机文件夹", localBookLoc, true, false),
            ("zip", zipBookLoc, false, false),
            ("嵌套 zip", nestedInnerLoc, false, false),
            ("虚拟书", playlistLoc, true, true),
        ]
        var capturedTokens: [(String, Location, String)] = []
        for item in cases {
            await openLocation(controller, location: item.location)
            try await storage.remove("script.selftest-inspect", "book")
            try await storage.remove("script.selftest-inspect", "page")
            try await services.commands.perform(
                CommandID("script.selftest-inspect"),
                arguments: nil,
                context: CommandContext(session: controller.session.id, scope: .global, selection: [])
            )
            let got = await waitUntil(timeoutMs: 2500) {
                storage.get("script.selftest-inspect", "book") != .null &&
                storage.get("script.selftest-inspect", "page") != .null
            }
            guard got,
                  case let .object(bookObj) = storage.get("script.selftest-inspect", "book"),
                  case let .object(pageObj) = storage.get("script.selftest-inspect", "page"),
                  case let .string(bookToken) = bookObj["location"],
                  case let .string(pageToken) = pageObj["location"] else {
                log.check(false, "C2.8 \(item.label) 未读到 mv.book()/mv.page()")
                continue
            }
            let pagePath: String? = if case let .string(p) = pageObj["path"] { p } else { nil }
            let isVirtual: Bool = if case let .bool(v) = bookObj["isVirtual"] { v } else { false }
            if item.expectPathEqualsLocation {
                log.check(pagePath == pageToken && isVirtual == item.expectVirtual, "C2.8 \(item.label) mv.page() 返回 location==path（isVirtual=\(isVirtual)）")
            } else {
                log.check(pageToken.hasPrefix("mvloc:") && pagePath == nil, "C2.8 \(item.label) mv.page() 返回 mvloc: 且 path==null")
            }
            capturedTokens.append((item.label, item.location, bookToken))
        }

        let bookB = try makeBook(name: "book-b", count: 3)
        let bookBLoc = try await services.sources.location(for: bookB)
        for (label, expectedLoc, token) in capturedTokens {
            await openLocation(controller, location: bookBLoc)
            try await storage.remove("script.selftest-open", "opened")
            try await services.commands.perform(
                CommandID("script.selftest-open"),
                arguments: ["target": .string(token)],
                context: CommandContext(session: controller.session.id, scope: .global, selection: [])
            )
            let reopened = await waitUntil(timeoutMs: 3000) {
                controller.session.book?.location == expectedLoc && (controller.session.book?.pages.count ?? 0) > 0
            }
            log.check(reopened, "C2.8 mv.open 往返打开\(label)成功")
        }

        // C2.9：mv.confirm 以 sheet 弹出、取消返回 false、等待期间主线程不阻塞、stopAll 关闭 sheet
        let confirmURL = library.directory.appending(path: "selftest-confirm.js")
        try """
        // @name 确认测试
        const ok = mv.confirm('请确认测试');
        mv.storage.set('confirmResult', ok);
        """.write(to: confirmURL, atomically: true, encoding: .utf8)
        _ = await waitUntil(timeoutMs: 2000) { extensions.scriptItems.contains { $0.id == "selftest-confirm" } }

        try await storage.remove("script.selftest-confirm", "confirmResult")
        try await services.commands.perform(
            CommandID("script.selftest-confirm"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let sheetShown = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        var mainTicks = 0
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(30))
            mainTicks += 1
        }
        let clickedCancel = clickSheetButton(in: window, titled: String(localized: "取消"))
        let cancelOK = await waitUntil(timeoutMs: 2500) {
            window.attachedSheet == nil && storage.get("script.selftest-confirm", "confirmResult") == .bool(false)
        }
        log.check(sheetShown && mainTicks == 3 && clickedCancel && cancelOK, "C2.9 mv.confirm 弹 sheet、等待期间主线程响应、取消返回 false")

        try await services.commands.perform(
            CommandID("script.selftest-confirm"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let secondSheet = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        runtime.stopAll()
        let closedByStopAll = await waitUntil(timeoutMs: 2500) { window.attachedSheet == nil }
        log.check(secondSheet && closedByStopAll, "C2.9 确认框打开期间 stopAll 自动关闭 sheet")

        // C2.10：mv.storage 写入落盘，重新加载存储仍可读到
        let storageScriptURL = library.directory.appending(path: "selftest-storage.js")
        try """
        // @name 存储测试
        mv.storage.set('persistKey', { count: 42, label: 'ok' });
        """.write(to: storageScriptURL, atomically: true, encoding: .utf8)
        _ = await waitUntil(timeoutMs: 2000) { extensions.scriptItems.contains { $0.id == "selftest-storage" } }
        try await services.commands.perform(
            CommandID("script.selftest-storage"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [])
        )
        let storageFile = app.supportDirectory.appending(path: "script-storage.json")
        let persisted = await waitUntil(timeoutMs: 2500) {
            FileManager.default.fileExists(atPath: storageFile.path) &&
            storage.get("script.selftest-storage", "persistKey") != .null
        }
        let reloadedStorage = try ScriptStorage(fileURL: storageFile)
        let reloadedVal = reloadedStorage.get("script.selftest-storage", "persistKey")
        log.check(persisted && reloadedVal == .object(["count": .number(42), "label": .string("ok")]), "C2.10 mv.storage 写入落盘且重新加载后可读到")

        // C2.19：菜单项与新增字符串非空、英文环境下无未翻译中文
        checkLocalization(window: window, controller: controller, scriptsMenuTitle: scriptsMenuTitle, fixedTitles: fixedTitles)
    }

    // MARK: - events（C2.11, C2.12, C2.13, C2.13a）

    private func runEventsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        extensions: ExtensionCommands
    ) async throws {
        guard let library = services.scriptLibrary,
              let storage = services.scriptStorage,
              let scriptEvents = app.scriptEvents else {
            log.check(false, "事件自检缺少必要服务")
            return
        }

        _ = await waitUntil(timeoutMs: 3000) { extensions.scriptItems.contains { $0.id == "ask-next-book" } }

        let shelfDir = temporary.appending(path: "shelf", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shelfDir, withIntermediateDirectories: true)
        let book1 = try makeBook(in: shelfDir, name: "01-book", count: 4)
        let book2 = try makeBook(in: shelfDir, name: "02-book", count: 4)
        let book1Loc = try await services.sources.location(for: book1)
        let book2Loc = try await services.sources.location(for: book2)

        // C2.12 & C2.11（无 pageEnd 脚本时）：清空所有脚本后翻页 dispatchCount == 0，末页按 → 位置不变
        let stashDir = temporary.appending(path: "event-stash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stashDir, withIntermediateDirectories: true)
        let saved = try moveScripts(from: library.directory, to: stashDir)
        let emptyReady = await waitUntil(timeoutMs: 2500) { extensions.scriptItems.isEmpty }
        await openBook(controller, url: book1, expectedCount: 4)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
        }
        await settle(150)
        window.makeFirstResponder(controller.viewer)
        scriptEvents.resetDispatchCounts()
        for _ in 0..<4 {
            await sendKey(kVK_RightArrow, in: window)
        }
        await settle(200)
        log.check(emptyReady && scriptEvents.dispatchCount == 0, "C2.12 无事件脚本时翻页路径 dispatchCount == 0（实际 \(scriptEvents.dispatchCount)）")
        log.check(controller.session.book?.location == book1Loc && controller.session.currentPage == 3, "C2.11 无 pageEnd 脚本时末页再按 → 位置不变")

        // C2.11：放回 ask-next-book.js 并加反向脚本，测单页/双页的末页 → 与首页 ←
        if let askNext = saved.first(where: { $0.lastPathComponent == "ask-next-book.js" }) {
            try FileManager.default.moveItem(at: askNext, to: library.directory.appending(path: "ask-next-book.js"))
        }
        let askPrevURL = library.directory.appending(path: "ask-prev-book.js")
        try """
        // @name 首页询问上一本
        // @event pageEnd
        if (mv.event && mv.event.direction === 'backward' && mv.confirm('打开上一本？')) {
            mv.command('book.previous');
        }
        """.write(to: askPrevURL, atomically: true, encoding: .utf8)
        let pageEndReady = await waitUntil(timeoutMs: 2500) {
            extensions.scriptItems.contains { $0.id == "ask-next-book" } &&
            extensions.scriptItems.contains { $0.id == "ask-prev-book" }
        }
        log.check(pageEndReady, "C2.11 pageEnd 脚本就绪")

        // 单页末页 → 触发确认并打开 02-book
        controller.session.go(.last)
        await settle(150)
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_RightArrow, in: window)
        let singleForwardSheet = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        let singleForwardClicked = clickSheetButton(in: window, titled: String(localized: "确定"))
        let movedToBook2Single = await waitUntil(timeoutMs: 3000) { controller.session.book?.location == book2Loc }
        log.check(singleForwardSheet && singleForwardClicked && movedToBook2Single, "C2.11 单页末页按 → 弹确认并打开下一本")

        // 单页首页 ← 触发确认并切回 01-book
        controller.session.go(.first)
        await settle(150)
        window.makeFirstResponder(controller.viewer)
        let onBook2BeforeSingleBack = controller.session.book?.location == book2Loc
        await sendKey(kVK_LeftArrow, in: window)
        let singleBackwardSheet = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        let singleBackwardClicked = clickSheetButton(in: window, titled: String(localized: "确定"))
        let movedToBook1Single = await waitUntil(timeoutMs: 3000) { controller.session.book?.location == book1Loc }
        log.check(onBook2BeforeSingleBack && singleBackwardSheet && singleBackwardClicked && movedToBook1Single, "C2.11 单页首页按 ← 弹确认并打开上一本")

        // 双页模式末页 → 与首页 ←
        controller.session.update {
            $0.pageMode = .double
            $0.firstPageSingle = false
            $0.direction = .leftToRight
        }
        await settle(200)
        controller.session.go(.last)
        await settle(150)
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_RightArrow, in: window)
        let doubleForwardSheet = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        let doubleForwardClicked = clickSheetButton(in: window, titled: String(localized: "确定"))
        let movedToBook2Double = await waitUntil(timeoutMs: 3000) { controller.session.book?.location == book2Loc }
        log.check(doubleForwardSheet && doubleForwardClicked && movedToBook2Double, "C2.11 双页末页按 → 弹确认并打开下一本")

        controller.session.go(.first)
        await settle(150)
        window.makeFirstResponder(controller.viewer)
        let onBook2BeforeDoubleBack = controller.session.book?.location == book2Loc
        await sendKey(kVK_LeftArrow, in: window)
        let doubleBackwardSheet = await waitUntil(timeoutMs: 2500) { window.attachedSheet != nil }
        let doubleBackwardClicked = clickSheetButton(in: window, titled: String(localized: "确定"))
        let movedToBook1Double = await waitUntil(timeoutMs: 3000) { controller.session.book?.location == book1Loc }
        log.check(onBook2BeforeDoubleBack && doubleBackwardSheet && doubleBackwardClicked && movedToBook1Double, "C2.11 双页首页按 ← 弹确认并打开上一本")

        // C2.13：阻塞 300 ms 的 pageChanged 脚本不拖慢已预载页上屏（≤ 1 帧）
        try? FileManager.default.removeItem(at: library.directory.appending(path: "ask-next-book.js"))
        try? FileManager.default.removeItem(at: askPrevURL)
        let slowURL = library.directory.appending(path: "slow-page-changed.js")
        try """
        // @name 慢速翻页事件
        // @event pageChanged
        const t0 = Date.now();
        while (Date.now() - t0 < 300) {}
        mv.storage.set('slowPage', mv.event.index);
        """.write(to: slowURL, atomically: true, encoding: .utf8)
        _ = await waitUntil(timeoutMs: 2500) { extensions.scriptItems.map(\.id) == ["slow-page-changed"] }

        let perfBook = try makeBook(name: "perf-book", count: 16, size: CGSize(width: 1200, height: 1800))
        await openBook(controller, url: perfBook, expectedCount: 16)
        controller.session.update { $0.pageMode = .single; $0.browseMode = .paged }
        controller.session.go(.index(4))
        try? await Task.sleep(for: .seconds(2))
        let paged = controller.viewer.paged
        let budget = 1000.0 / Double(window.screen?.maximumFramesPerSecond ?? 120)
        var durations: [Double] = []
        for _ in 0..<5 {
            controller.session.go(.nextFrame)
            for _ in 0..<40 where paged.lastDisplay?.page != controller.session.currentPage {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if let record = paged.lastDisplay, record.page == controller.session.currentPage {
                durations.append(record.duration.milliseconds)
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        let slowRan = await waitUntil(timeoutMs: 2500) { storage.get("script.slow-page-changed", "slowPage") != .null }
        print("INFO 含 300ms pageChanged 脚本预载翻页：\(durations.map { String(format: "%.2f", $0) }) ms，一帧 \(String(format: "%.2f", budget)) ms")
        log.check(
            slowRan && durations.count == 5 && durations.allSatisfy { $0 <= budget },
            "C2.13 阻塞 300 ms 的 pageChanged 脚本下已预载翻页仍 ≤ 1 帧（max=\(String(format: "%.2f", durations.max() ?? -1)) ms ≤ \(String(format: "%.2f", budget)) ms）"
        )
        try? FileManager.default.removeItem(at: slowURL)

        // C2.13a：脚本运行期间关窗后 mv.page() 抛“窗口已关闭”不落到别的窗口；运行期间改选中项 mv.selection() 保持触发快照
        let closeScriptURL = library.directory.appending(path: "close-window.js")
        let snapScriptURL = library.directory.appending(path: "selection-snapshot.js")
        try """
        // @name 关窗隔离
        const t0 = Date.now();
        while (Date.now() - t0 < 350) {}
        try {
            mv.page();
            mv.storage.set('closedErr', 'NO_ERROR');
        } catch (e) {
            mv.storage.set('closedErr', String(e));
        }
        """.write(to: closeScriptURL, atomically: true, encoding: .utf8)
        try """
        // @name 选中快照
        const before = mv.selection();
        const t0 = Date.now();
        while (Date.now() - t0 < 350) {}
        const after = mv.selection();
        mv.storage.set('snapBefore', before);
        mv.storage.set('snapAfter', after);
        """.write(to: snapScriptURL, atomically: true, encoding: .utf8)
        _ = await waitUntil(timeoutMs: 2500) {
            extensions.scriptItems.contains { $0.id == "close-window" } &&
            extensions.scriptItems.contains { $0.id == "selection-snapshot" }
        }

        if let second = app.newWindow() {
            await openBook(second, url: book1, expectedCount: 4)
            let secondSessionID = second.session.id
            try await services.commands.perform(
                CommandID("script.close-window"),
                arguments: nil,
                context: CommandContext(session: secondSessionID, scope: .global, selection: [])
            )
            try? await Task.sleep(for: .milliseconds(100))
            second.window?.close()
            let expectedClosedText = ScriptHostError.windowClosed.errorDescription ?? "窗口已关闭"
            let closedOK = await waitUntil(timeoutMs: 2500) {
                if case let .string(msg) = storage.get("script.close-window", "closedErr") {
                    return msg.contains(expectedClosedText)
                }
                return false
            }
            log.check(closedOK, "C2.13a 关窗后 mv.page() 抛“\(expectedClosedText)”且不落到别的窗口")
        } else {
            log.check(false, "C2.13a 无法创建第二个窗口")
        }

        await openBook(controller, url: book1, expectedCount: 4)
        let book1Pages = controller.session.book?.pages ?? []
        let initialSelection = Array(book1Pages.prefix(2).map(\.id))
        let expectedSnap = JSONValue.array(initialSelection.map { .string(ScriptLocationCodec.token(for: $0)) })
        try await services.commands.perform(
            CommandID("script.selection-snapshot"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: initialSelection)
        )
        try? await Task.sleep(for: .milliseconds(100))
        controller.session.go(.index(3))
        if let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel {
            pageList.collection?.setCurrent(3, reveal: false)
        }
        let snapOK = await waitUntil(timeoutMs: 2500) {
            storage.get("script.selection-snapshot", "snapBefore") == expectedSnap &&
            storage.get("script.selection-snapshot", "snapAfter") == expectedSnap
        }
        log.check(snapOK, "C2.13a 脚本运行期间改变选中项后 mv.selection() 仍是触发时快照")
    }

    // MARK: - external（C2.14–C2.17）

    private func runExternalSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        extensions: ExtensionCommands
    ) async throws {
        guard let scriptLog = services.scriptLog,
              let externalStore = services.externalCommands else {
            log.check(false, "外部命令自检缺少必要服务")
            return
        }

        // 准备普通书（含空格、中文、单引号文件名）与 zip 书
        let specialDir = temporary.appending(path: "ext-book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: specialDir, withIntermediateDirectories: true)
        let specialName = "测试 图'片 01.png"
        try writePNG(to: specialDir.appending(path: specialName), size: CGSize(width: 320, height: 240), hue: 0.1)
        try writePNG(to: specialDir.appending(path: "p02.png"), size: CGSize(width: 320, height: 240), hue: 0.4)
        try writePNG(to: specialDir.appending(path: "p03.png"), size: CGSize(width: 320, height: 240), hue: 0.7)

        let zipSrc = try makeBook(name: "ext-zip-src", count: 2, size: CGSize(width: 200, height: 200))
        let zipFile = try makeZip(from: zipSrc, named: "ext-book.zip")

        // C2.14：注入 applicationOpener 替身，测试普通 3 页和 zip 内 2 页
        var capturedURLs: [URL] = []
        var capturedAppURL: URL?
        let originalOpener = extensions.applicationOpener
        extensions.applicationOpener = { urls, appURL in
            capturedURLs = urls
            capturedAppURL = appURL
        }
        defer { extensions.applicationOpener = originalOpener }

        let previewCmd = ExternalCommand(
            id: "preview",
            name: "用预览打开",
            kind: .application,
            program: "/System/Applications/Preview.app",
            arguments: "{files}"
        )

        await openBook(controller, url: specialDir, expectedCount: 3)
        let normalPages = controller.session.book?.pages ?? []
        let normalRes = await extensions.runExternal(previewCmd, target: ScriptTarget(window: controller, locations: normalPages.map(\.id)))
        let normalFilesExist = capturedURLs.count == 3 && capturedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        log.check(
            normalRes == .succeeded(output: nil) && capturedAppURL?.path == "/System/Applications/Preview.app" && normalFilesExist,
            "C2.14 应用类外部命令对 3 页调用收到 3 个真实存在的文件 URL"
        )

        capturedURLs = []
        capturedAppURL = nil
        await openBook(controller, url: zipFile, expectedCount: 2)
        let zipPages = controller.session.book?.pages ?? []
        let zipRes = await extensions.runExternal(previewCmd, target: ScriptTarget(window: controller, locations: zipPages.map(\.id)))
        let zipFilesExist = capturedURLs.count == 2 && capturedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        log.check(
            zipRes == .succeeded(output: nil) && zipFilesExist,
            "C2.14 应用类外部命令对 zip 内页解出并收到真实存在的文件 URL"
        )

        // C2.15：Shell 类 sips -g pixelWidth {file} 对含空格、中文、单引号图片执行
        await openBook(controller, url: specialDir, expectedCount: 3)
        guard let specialPage = controller.session.book?.pages.first(where: { $0.entry.name == specialName }) else {
            log.check(false, "C2.15 未找到特殊文件名图片")
            return
        }
        scriptLog.clear()
        let sipsCmd = ExternalCommand(
            id: "sips-width",
            name: "查看宽度",
            kind: .shell,
            program: nil,
            arguments: "/usr/bin/sips -g pixelWidth {file}",
            showOutput: true
        )
        let sipsRes = await extensions.runExternal(sipsCmd, target: ScriptTarget(window: controller, locations: [specialPage.id]))
        let logHasWidth = scriptLog.entries().contains { $0.source == "查看宽度" && $0.text.contains("pixelWidth: 320") }
        let statusMsg = controller.content.statusBar.message ?? ""
        log.check(
            { if case .succeeded = sipsRes { return true }; return false }() && logHasWidth && statusMsg.contains("320"),
            "C2.15 Shell 类 sips 对特殊文件名执行成功，scriptLog 含宽度且状态栏显示最后一行（\(statusMsg)）"
        )

        // C2.16：程序不存在时状态栏显示失败原因
        let missingCmd = ExternalCommand(
            id: "missing-bin",
            name: "不存在的程序",
            kind: .program,
            program: "/nonexistent/macview-missing-tool",
            arguments: "{file}"
        )
        let missingRes = await extensions.runExternal(missingCmd, target: ScriptTarget(window: controller, locations: [specialPage.id]))
        let failStatus = controller.content.statusBar.message ?? ""
        log.check(
            { if case .failed = missingRes { return true }; return false }() && failStatus.contains("不存在的程序"),
            "C2.16 程序不存在时状态栏显示失败原因（\(failStatus)）"
        )

        // C2.17：external-commands.json 写坏时 fileProblems 出现错误提示，原外部命令仍可运行
        let echoCmd = ExternalCommand(
            id: "echo-alive",
            name: "存活回显",
            kind: .program,
            program: "/bin/echo",
            arguments: "external-still-alive",
            showOutput: true
        )
        try await externalStore.update { $0.commands = [echoCmd] }
        let echoRegistered = await waitUntil(timeoutMs: 2500) {
            extensions.externalItems.contains { $0.id == "echo-alive" }
        }

        let extFileURL = app.supportDirectory.appending(path: "external-commands.json")
        try "{ broken json".write(to: extFileURL, atomically: true, encoding: .utf8)
        let problemAppeared = await waitUntil(timeoutMs: 3000) {
            app.fileProblems.contains { $0.file == "external-commands.json" }
        }
        scriptLog.clear()
        try await services.commands.perform(
            CommandID("external.echo-alive"),
            arguments: nil,
            context: CommandContext(session: controller.session.id, scope: .global, selection: [specialPage.id])
        )
        let stillRunnable = scriptLog.entries().contains { $0.text.contains("external-still-alive") } &&
            (controller.content.statusBar.message?.contains("external-still-alive") == true)
        log.check(
            echoRegistered && problemAppeared && stillRunnable,
            "C2.17 external-commands.json 写坏时 fileProblems 报文件错误，原外部命令仍可运行"
        )

        // 恢复合法文件，确认错误条消失
        try await externalStore.update { $0.commands = [] }
        let problemCleared = await waitUntil(timeoutMs: 3000) {
            !app.fileProblems.contains { $0.file == "external-commands.json" }
        }
        log.check(problemCleared, "C2.17 external-commands.json 恢复合法后文件错误提示消失")
    }

    // MARK: - settings（C3.1–C3.6）

    private func runSettingsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        extensions: ExtensionCommands
    ) async throws {
        guard let library = services.scriptLibrary,
              let externalStore = services.externalCommands else {
            log.check(false, "扩展设置页自检缺少必要服务")
            return
        }

        _ = await waitUntil(timeoutMs: 3000) {
            extensions.scriptItems.contains { $0.id == "jump-middle" } &&
            extensions.scriptItems.contains { $0.id == "ask-next-book" }
        }
        try await externalStore.update { $0.commands = [] }

        // 打开一本 3 页测试书，供外部命令读取当前页及 C3.3 验证主窗口可操作。
        let bookURL = try makeBook(name: "settings-book", count: 3, size: CGSize(width: 400, height: 600))
        await openBook(controller, url: bookURL, expectedCount: 3)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
        }
        controller.session.go(.index(0))
        await settle(150)

        // MARK: C3.6 主菜单「脚本 › 管理脚本与外部命令…」打开设置并定位到「扩展」页
        let scriptsMenuTitle = String(localized: "脚本")
        let manageTitle = app.catalog.title(of: .scriptManage)
        let openedViaMenu: Bool = {
            guard let scriptsMenu = openMainScriptsMenu(titled: scriptsMenuTitle),
                  let manageItem = scriptsMenu.items.first(where: { $0.title == manageTitle }) else {
                return false
            }
            triggerMenuItem(manageItem)
            return true
        }()
        let settingsOpened = await waitUntil(timeoutMs: 2500) {
            guard let controller = self.activeSettingsController(),
                  let win = controller.window else { return false }
            return win.isVisible && controller.state.page == .extensions
        }
        guard let settingsController = activeSettingsController(),
              let settingsWindow = settingsController.window else {
            log.check(false, "C3.6 主菜单打开设置窗口失败（触发菜单=\(openedViaMenu)）")
            return
        }
        settingsWindow.setContentSize(NSSize(width: 680, height: 740))
        TestPresentation.place(settingsWindow)
        settingsWindow.makeKeyAndOrderFront(nil)
        await settle(250)
        let addBtnVisible = findAXElement(in: settingsWindow, identifier: "settings.extensions.external.add") != nil
        log.check(
            openedViaMenu && settingsOpened && addBtnVisible,
            "C3.6 主菜单「\(scriptsMenuTitle) › \(manageTitle)」打开设置并定位到扩展页"
        )

        let extModel = settingsController.state.model.extensions

        // MARK: C3.1 放入脚本后 2 秒内出现在列表
        let helloURL = library.directory.appending(path: "selftest-ui-hello.js")
        try """
        // @name UI自检问候
        // @summary 输出日志
        console.log('ui-hello-log');
        """.write(to: helloURL, atomically: true, encoding: .utf8)
        let readyText = String(localized: "就绪")
        let c31OK = await waitUntil(timeoutMs: 2000) {
            extModel.scripts.contains { $0.id == "selftest-ui-hello" && $0.problem == nil } &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-ui-hello") != nil &&
            self.axText(identifier: "settings.extensions.script.selftest-ui-hello.status", in: settingsWindow).contains(readyText)
        }
        log.check(c31OK, "C3.1 放入脚本后 2 秒内出现在扩展页列表且状态就绪")

        // MARK: C3.2 语法错误的脚本标红并显示行号，修好保存后变回就绪
        let syntaxURL = library.directory.appending(path: "selftest-syntax.js")
        try """
        // @name 语法错误测试
        const a = 1;
        function broken( {
        """.write(to: syntaxURL, atomically: true, encoding: .utf8)
        let syntaxErrorTitle = String(localized: "语法错误")
        let syntaxDetected = await waitUntil(timeoutMs: 2000) {
            guard let info = extModel.scripts.first(where: { $0.id == "selftest-syntax" }),
                  let line = info.problem?.line else { return false }
            let statusText = self.axText(identifier: "settings.extensions.script.selftest-syntax.status", in: settingsWindow)
            let rowText = self.axText(identifier: "settings.extensions.script.selftest-syntax", in: settingsWindow)
            return statusText.contains(syntaxErrorTitle) && rowText.contains("\(line)")
        }
        await settle(150)
        let syntaxRedPixels = countDangerPixels(inAXIdentifier: "settings.extensions.script.selftest-syntax", in: settingsWindow)
        let syntaxHasRed = syntaxRedPixels > 0

        try """
        // @name 语法错误测试
        const a = 1;
        console.log('syntax-fixed');
        """.write(to: syntaxURL, atomically: true, encoding: .utf8)
        let syntaxFixed = await waitUntil(timeoutMs: 2000) {
            extModel.scripts.first(where: { $0.id == "selftest-syntax" })?.problem == nil &&
            self.axText(identifier: "settings.extensions.script.selftest-syntax.status", in: settingsWindow).contains(readyText) &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-syntax.run") != nil
        }
        log.check(
            syntaxDetected && syntaxHasRed && syntaxFixed,
            "C3.2 语法错误脚本显示行号与标红(redPx=\(syntaxRedPixels))，修好保存后变回就绪"
        )
        try? FileManager.default.removeItem(at: syntaxURL)
        _ = await waitUntil(timeoutMs: 2000) { !extModel.scripts.contains { $0.id == "selftest-syntax" } }

        // MARK: C3.3 运行死循环脚本行内显示“运行中”，点停止 1 秒内变回就绪，期间设置窗与主窗均可操作
        let loopURL = library.directory.appending(path: "selftest-loop.js")
        try """
        // @name 死循环测试
        while (true) {
            mv.page();
        }
        """.write(to: loopURL, atomically: true, encoding: .utf8)
        let loopListed = await waitUntil(timeoutMs: 2000) {
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-loop.run") != nil
        }
        await settle(100)
        let clickedRunLoop = await clickAX(identifier: "settings.extensions.script.selftest-loop.run", in: settingsWindow)
        let runningPrefix = String(localized: "运行中 \("")").trimmingCharacters(in: .whitespaces)
        let loopRunning = await waitUntil(timeoutMs: 2000) {
            if case .running = extModel.runStates["selftest-loop"] {
                let status = self.axText(identifier: "settings.extensions.script.selftest-loop.status", in: settingsWindow)
                return status.contains(runningPrefix) &&
                    self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-loop.stop") != nil
            }
            return false
        }

        // 运行期间操作主窗口（翻页）与设置窗口（真实点击切页签再切回）
        let pageBefore = controller.session.currentPage
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.viewer)
        await settle(80)
        await sendKey(kVK_RightArrow, in: window)
        let mainWindowResponsive = await waitUntil(timeoutMs: 1200) {
            controller.session.currentPage != pageBefore
        }

        settingsWindow.makeKeyAndOrderFront(nil)
        await settle(80)
        let clickedBrowseTab = await clickAX(identifier: "settings.tab.browse", in: settingsWindow)
        let switchedToBrowse = await waitUntil(timeoutMs: 1200) { settingsController.state.page == .browse }
        let clickedExtTab = await clickAX(identifier: "settings.tab.extensions", in: settingsWindow)
        let switchedBackToExt = await waitUntil(timeoutMs: 1200) {
            settingsController.state.page == .extensions &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-loop.stop") != nil
        }
        let settingsWindowResponsive = clickedBrowseTab && switchedToBrowse && clickedExtTab && switchedBackToExt

        // 真实点击行内停止按钮，验证 1 秒内变回就绪
        let stopStarted = ContinuousClock.now
        let clickedStopLoop = await clickAX(identifier: "settings.extensions.script.selftest-loop.stop", in: settingsWindow)
        let stoppedWithin1s = await waitUntil(timeoutMs: 1000, intervalMs: 25) {
            let state = extModel.runStates["selftest-loop"] ?? .idle
            guard case .idle = state else { return false }
            return self.axText(identifier: "settings.extensions.script.selftest-loop.status", in: settingsWindow).contains(readyText) &&
                self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-loop.run") != nil
        }
        let stopElapsedMs = (ContinuousClock.now - stopStarted).milliseconds
        log.check(
            loopListed && clickedRunLoop && loopRunning && mainWindowResponsive && settingsWindowResponsive && clickedStopLoop && stoppedWithin1s && stopElapsedMs <= 1000,
            "C3.3 死循环运行中显示(listed=\(loopListed),clickedRun=\(clickedRunLoop),running=\(loopRunning))且主窗(\(mainWindowResponsive))/设置窗(\(settingsWindowResponsive))可操作，点停止(\(clickedStopLoop)) \(Int(stopElapsedMs))ms 内变回就绪(\(stoppedWithin1s))"
        )
        try? FileManager.default.removeItem(at: loopURL)
        _ = await waitUntil(timeoutMs: 2000) { !extModel.scripts.contains { $0.id == "selftest-loop" } }

        // MARK: C3.4 外部命令新建、编辑、删除写回 JSON 与主菜单同步；JSON 写坏错误横幅与恢复
        let extFileURL = app.supportDirectory.appending(path: "external-commands.json")
        let commandSynced: (String, Bool) -> Bool = { title, present in
            let inFile = (try? String(contentsOf: extFileURL, encoding: .utf8))?.contains(title) == true
            let inMenu = self.openMainScriptsMenu(titled: scriptsMenuTitle)?.items.contains { $0.title == title } == true
            return inFile == present && inMenu == present
        }
        func runSteps(_ steps: [@MainActor () async -> Bool]) async -> Bool {
            for step in steps where await !step() { return false }
            return true
        }

        let createdOK = await runSteps([
            { await self.clickAX(identifier: "settings.extensions.external.add", in: settingsWindow) },
            { await self.waitUntil(timeoutMs: 1500) { self.findAXElement(in: settingsWindow, identifier: "settings.extensions.form.name") != nil } },
            { await self.typeIntoAXField(identifier: "settings.extensions.form.name", text: "查看宽度", in: settingsWindow) },
            { await self.typeIntoAXField(identifier: "settings.extensions.form.arguments", text: "/usr/bin/sips -g pixelWidth {file}", in: settingsWindow) },
            { await self.clickAX(identifier: "settings.extensions.form.showOutput", in: settingsWindow) },
            { await self.settle(80); return await self.clickAX(identifier: "settings.extensions.form.save", in: settingsWindow) },
            {
                await self.waitUntil(timeoutMs: 2500) {
                    self.findAXElement(in: settingsWindow, identifier: "settings.extensions.form") == nil &&
                    extModel.externalCommands.contains { $0.name == "查看宽度" && $0.showOutput } &&
                    commandSynced("查看宽度", true)
                }
            },
        ])
        let createdID = extModel.externalCommands.first(where: { $0.name == "查看宽度" })?.id ?? ""

        // 编辑外部命令名称
        let editedOK = await runSteps([
            { !createdID.isEmpty },
            { await self.clickAX(identifier: "settings.extensions.external.\(createdID).edit", in: settingsWindow) },
            { await self.waitUntil(timeoutMs: 1500) { self.findAXElement(in: settingsWindow, identifier: "settings.extensions.form.name") != nil } },
            { await self.typeIntoAXField(identifier: "settings.extensions.form.name", text: "查看图片宽度", in: settingsWindow) },
            { await self.settle(80); return await self.clickAX(identifier: "settings.extensions.form.save", in: settingsWindow) },
            {
                await self.waitUntil(timeoutMs: 2500) {
                    self.findAXElement(in: settingsWindow, identifier: "settings.extensions.form") == nil &&
                    extModel.externalCommands.contains { $0.id == createdID && $0.name == "查看图片宽度" } &&
                    commandSynced("查看图片宽度", true)
                }
            },
        ])

        // 外部把 external-commands.json 写坏，验证错误横幅出现；写回合法 JSON，横幅消失
        let validJSONData = (try? Data(contentsOf: extFileURL)) ?? Data()
        try Data("{ broken json".utf8).write(to: extFileURL, options: .atomic)
        let bannerAppeared = await waitUntil(timeoutMs: 3000) {
            extModel.externalCommandsProblem != nil &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.jsonError") != nil
        }
        // 解析器原文自带句末标点，横幅文案不能再叠一个
        let bannerText = axText(identifier: "settings.extensions.jsonError", in: settingsWindow)
        let bannerPunctuationOK = !["。。", ".。", "。.", ".."].contains { bannerText.contains($0) }
        try validJSONData.write(to: extFileURL, options: .atomic)
        let bannerCleared = await waitUntil(timeoutMs: 3000) {
            extModel.externalCommandsProblem == nil &&
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.jsonError") == nil
        }

        // MARK: C3.5 输出区显示 console.log 与外部命令输出，错误行为 danger 色
        if !extModel.logEntries.isEmpty {
            _ = await clickAX(identifier: "settings.extensions.log.clear", in: settingsWindow)
            _ = await waitUntil(timeoutMs: 1500) { extModel.logEntries.isEmpty }
        }
        // 先跑 console.log 脚本和外部命令，确认 info 输出出现且此时输出区无 danger 红色像素
        let ranHello = await clickAX(identifier: "settings.extensions.script.selftest-ui-hello.run", in: settingsWindow)
        let infoLogOK = await waitUntil(timeoutMs: 2500) {
            extModel.logEntries.contains { $0.level == .info && $0.text.contains("ui-hello-log") }
        }
        let triggeredExtFromMenu: Bool = {
            guard let menu = openMainScriptsMenu(titled: scriptsMenuTitle),
                  let item = menu.items.first(where: { $0.title == "查看图片宽度" }) else { return false }
            triggerMenuItem(item)
            return true
        }()
        let extLogOK = await waitUntil(timeoutMs: 3000) {
            extModel.logEntries.contains { $0.source == "查看图片宽度" && $0.text.contains("pixelWidth: 400") }
        }
        await settle(150)
        let redBeforeError = countDangerPixels(inAXIdentifier: "settings.extensions.log", in: settingsWindow)

        // 再写并运行一个 console.error 脚本，确认错误行出现且输出区出现 danger 色像素
        let errScriptURL = library.directory.appending(path: "selftest-error-log.js")
        try """
        // @name 错误输出测试
        console.error('selftest-danger-line');
        """.write(to: errScriptURL, atomically: true, encoding: .utf8)
        let errScriptListed = await waitUntil(timeoutMs: 2000) {
            self.findAXElement(in: settingsWindow, identifier: "settings.extensions.script.selftest-error-log.run") != nil
        }
        let ranErrorScript = errScriptListed ? await clickAX(identifier: "settings.extensions.script.selftest-error-log.run", in: settingsWindow) : false
        let errLogOK = await waitUntil(timeoutMs: 2500) {
            extModel.logEntries.contains { $0.level == .error && $0.text.contains("selftest-danger-line") }
        }
        await settle(250)
        await scrollAXIntoView(identifier: "settings.extensions.log", in: settingsWindow)
        await settle(150)
        let logAXText = axText(identifier: "settings.extensions.log", in: settingsWindow)
        let logShowsAll = logAXText.contains("ui-hello-log") && logAXText.contains("pixelWidth: 400") && logAXText.contains("selftest-danger-line")
        let redAfterError = countDangerPixels(inAXIdentifier: "settings.extensions.log", in: settingsWindow)
        let dangerColored = redAfterError > redBeforeError && redAfterError > 0
        log.check(
            ranHello && infoLogOK && triggeredExtFromMenu && extLogOK && ranErrorScript && errLogOK && logShowsAll && dangerColored,
            "C3.5 输出区显示 console.log、外部命令输出与错误行，错误行为 danger 色(redPx: \(redBeforeError)->\(redAfterError))"
        )

        // 输出整页截图到 -MVSelfTestOutput（此时三节内容饱满：脚本、外部命令、含 info/error 的输出区）
        try? FileManager.default.removeItem(at: errScriptURL)
        _ = await waitUntil(timeoutMs: 2000) { !extModel.scripts.contains { $0.id == "selftest-error-log" } }
        scrollOuterToTop(in: settingsWindow)
        await settle(200)
        let langTag = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true ? "en" : "zh"
        let appearanceTag = settingsWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        log.snapshot(settingsWindow, "extensions-\(langTag)-\(appearanceTag)")

        // 完成 C3.4 删除外部命令验证
        let deletedOK = await runSteps([
            { !createdID.isEmpty },
            { await self.clickAX(identifier: "settings.extensions.external.\(createdID).delete", in: settingsWindow) },
            { await self.waitUntil(timeoutMs: 1500) { self.findAXElement(in: settingsWindow, identifier: "settings.extensions.external.\(createdID).confirmDelete") != nil } },
            { await self.clickAX(identifier: "settings.extensions.external.\(createdID).confirmDelete", in: settingsWindow) },
            {
                await self.waitUntil(timeoutMs: 2500) {
                    !extModel.externalCommands.contains { $0.id == createdID } &&
                    commandSynced("查看图片宽度", false)
                }
            },
        ])
        log.check(
            createdOK && editedOK && bannerAppeared && bannerPunctuationOK && bannerCleared && deletedOK,
            "C3.4 外部命令(create=\(createdOK),edit=\(editedOK),banner=\(bannerAppeared)/\(bannerCleared),bannerText=\(bannerText),delete=\(deletedOK))"
        )

        try? FileManager.default.removeItem(at: helloURL)
        settingsWindow.close()
    }

    // MARK: - 本地化与截断检查（C2.19）

    private func checkLocalization(
        window: NSWindow,
        controller: ReaderWindowController,
        scriptsMenuTitle: String,
        fixedTitles: [String]
    ) {
        let isEnglish = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
        let allTitles = [scriptsMenuTitle] + fixedTitles + [
            ShortcutsModel.unknownSectionTitle,
            String(localized: "清除绑定"),
            ScriptHostError.windowClosed.errorDescription ?? "",
            ScriptHostError.noWindow.errorDescription ?? "",
            ScriptHostError.noBook.errorDescription ?? "",
        ]
        let nonEmpty = allTitles.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isEnglish {
            let untranslated = allTitles.filter(Self.containsCJK)
            log.check(nonEmpty && untranslated.isEmpty, "C2.19 英文模式下脚本菜单与新增字符串无未翻译中文：\(untranslated)")
        } else {
            log.check(nonEmpty, "C2.19 中文模式下脚本菜单与固定三项标题完整：\(fixedTitles.joined(separator: " / "))")
        }
        controller.content.statusBar.showMessage(String(localized: "\("Test") 失败：\("reason")"))
        window.contentView?.layoutSubtreeIfNeeded()
        let statusOK = !(controller.content.statusBar.message?.isEmpty ?? true)
        if isEnglish {
            let msg = controller.content.statusBar.message ?? ""
            log.check(statusOK && !Self.containsCJK(msg), "C2.19 英文模式下状态栏失败提示已翻译：\(msg)")
        } else {
            log.check(statusOK, "C2.19 状态栏提示正常显示")
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    // MARK: - 夹具与辅助工具

    private func makeBook(in parent: URL? = nil, name: String, count: Int, size: CGSize = CGSize(width: 400, height: 600)) throws -> URL {
        let dir = (parent ?? temporary).appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<count {
            let hue = CGFloat(index) / CGFloat(max(count, 1))
            try writePNG(to: dir.appending(path: String(format: "p%03d.png", index + 1)), size: size, hue: hue)
        }
        return dir
    }

    private func writePNG(to url: URL, size: CGSize, hue: CGFloat) throws {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.88, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    private func makeZip(from directory: URL, named name: String) throws -> URL {
        let zipURL = temporary.appending(path: name)
        try? FileManager.default.removeItem(at: zipURL)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", zipURL.path] + files
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zipURL
    }

    private func makeNestedZip(innerZip: URL, named name: String) throws -> URL {
        let stage = temporary.appending(path: "nested-stage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: innerZip, to: stage.appending(path: innerZip.lastPathComponent))
        return try makeZip(from: stage, named: name)
    }

    private func moveScripts(from source: URL, to destination: URL) throws -> [URL] {
        var moved: [URL] = []
        let items = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.pathExtension.lowercased() == "js" {
            let dest = destination.appending(path: item.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: item, to: dest)
            moved.append(dest)
        }
        return moved
    }

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        _ = await waitUntil(timeoutMs: 6000) {
            guard let book = controller.session.book else { return false }
            return book.isEnumerated && book.pages.count == expectedCount && book.pages.allSatisfy { $0.metadata != nil }
        }
    }

    private func openLocation(_ controller: ReaderWindowController, location: Location) async {
        await controller.session.open(location, at: nil)
        _ = await waitUntil(timeoutMs: 6000) {
            guard let book = controller.session.book else { return false }
            return book.location == location && book.isEnumerated && !book.pages.isEmpty
        }
    }

    private func triggerMenuItem(_ item: NSMenuItem) {
        if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    @discardableResult
    private func clickSheetButton(in window: NSWindow, titled title: String) -> Bool {
        guard let sheet = window.attachedSheet, let contentView = sheet.contentView else { return false }
        let buttons = collectButtons(in: contentView)
        guard let target = buttons.first(where: { $0.title == title }) else { return false }
        target.performClick(nil)
        return true
    }

    private func collectButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = view as? NSButton { result.append(button) }
        for subview in view.subviews { result.append(contentsOf: collectButtons(in: subview)) }
        return result
    }

    private func sendKey(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = [], in targetWindow: NSWindow) async {
        let window = NSApp.keyWindow ?? targetWindow
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
            } else if !window.performKeyEquivalent(with: event), NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func settle(_ ms: Int = 200) async {
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

    // MARK: - 设置页真实事件与 AX 辅助

    private func openMainScriptsMenu(titled title: String) -> NSMenu? {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == title }),
              let submenu = item.submenu else { return nil }
        submenu.delegate?.menuWillOpen?(submenu)
        submenu.update()
        return submenu
    }

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

    private func scrollOuterToTop(in window: NSWindow) {
        guard let sv = outerScrollView(in: window), let doc = sv.documentView else { return }
        let topY = doc.isFlipped ? 0 : max(0, doc.bounds.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: topY))
        sv.reflectScrolledClipView(sv.contentView)
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
        sendMouseClick(at: NSPoint(x: rect.midX, y: rect.midY), in: window, modifiers: [])
        return true
    }

    private func typeIntoAXField(identifier: String, text: String, in window: NSWindow) async -> Bool {
        await scrollAXIntoView(identifier: identifier, in: window)
        guard let el = findAXElement(in: window, identifier: identifier),
              let rect = axFrameInWindow(el, window: window) else { return false }
        sendMouseClick(at: NSPoint(x: rect.midX, y: rect.midY), in: window, modifiers: [])
        await settle(80)
        guard let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.count))
        return true
    }

    private var nextMouseEventNumber = 1

    private func sendMouseClick(at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags) {
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
        guard let image = frameView.renderedImage() else {
            return 0
        }
        let scaleX = CGFloat(image.width) / max(frameView.bounds.width, 1)
        let scaleY = CGFloat(image.height) / max(frameView.bounds.height, 1)
        let rectInFrame = frameView.convert(rectInWindow, from: nil)
        // CGImage 原点在左上角，NSView 默认原点在左下角
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
            // Theme.danger（浅色 #A33B2A / 深色 #F09C8B）在中性暖灰底色上显著偏红
            if (r - b) >= 0.14 && (r - g) >= 0.09 {
                count += 1
            }
        }
        return count
    }
}
#endif
