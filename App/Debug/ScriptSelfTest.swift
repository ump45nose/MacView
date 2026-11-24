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

/// 脚本与外部命令自检（`-MVScriptSelfTest commands|events|external`）。
///
/// 覆盖阶段 2 的检查项 C2.1–C2.17（不依赖设置「扩展」页的部分）及 C2.19 中英文无未翻译与截断检查。
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
            !services.commands.descriptors().contains { $0.id == hotkeyID }
        }
        await sendKey(kVK_ANSI_M, modifiers: [.control], in: window)
        let unknownTitle = SettingsCommandCatalog.title(of: hotkeyID)
        log.check(hotkeyRemoved && unknownTitle == hotkeyID.rawValue, "C2.2 删除脚本后触发旧绑定与查询标题不崩溃：\(unknownTitle)")
        try await services.keyBindings?.update { $0.bindings.removeAll { $0.command == hotkeyID } }

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

    // MARK: - 本地化与截断检查（C2.19）

    private func checkLocalization(
        window: NSWindow,
        controller: ReaderWindowController,
        scriptsMenuTitle: String,
        fixedTitles: [String]
    ) {
        let isEnglish = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
        let allTitles = [scriptsMenuTitle] + fixedTitles + [
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
}
#endif
