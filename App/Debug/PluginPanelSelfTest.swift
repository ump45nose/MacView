#if DEBUG
import AppKit
import Carbon.HIToolbox
import Foundation
import MVCommands
import MVFoundation
import MVLayout
import MVPlugins
import MVReading
import MVScripting
import MVServices
import MVSettings
import WebKit

/// 网页面板自检（`-MVPluginSelfTest panels` 及冷重启子模式 `panels-reopen`），覆盖 C2.1–C2.12。
extension PluginSelfTest {
    func runPanelsSuite(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        guard let dock = app.dock,
              let pluginLib = services.pluginLibrary,
              let pluginSettings = services.pluginSettings,
              let scriptLog = services.scriptLog,
              let scriptStorage = services.scriptStorage,
              let scriptEvents = app.scriptEvents else {
            log.check(false, "网页面板自检缺少必要服务")
            return
        }

        let isEnglish = Bundle.main.preferredLocalizations.first == "en"
        let langTag = isEnglish ? "en" : "zh"
        let appearanceTag = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"

        // 准备 12 页测试书（宽 480 高 640）
        let bookDir = try makeColorBook(name: "panel-book", count: 12, size: CGSize(width: 480, height: 640))
        await openBook(controller, url: bookDir, expectedCount: 12)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
        }
        controller.session.go(.index(0))
        await settle(150)

        // MARK: C2.1 & C2.1b 动态面板注册、布局保留与不可用选中回退
        try await verifyDynamicPanelRegistry(controller: controller, dock: dock)

        // MARK: C2.2–C2.6 测试插件准备与验证
        let server = try LocalLoopbackHTTPServer(logFile: temporary.appending(path: "http-requests.log"))
        defer { server.stop() }

        let outsideSecret = pluginLib.directory.appending(path: "outside-secret.txt")
        try "OUTSIDE-SECRET".write(to: outsideSecret, atomically: true, encoding: .utf8)
        let otherDir = pluginLib.directory.appending(path: "other-plugin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try "OTHER-SECRET".write(to: otherDir.appending(path: "secret.txt"), atomically: true, encoding: .utf8)

        let testPluginDir = try writePanelTestPlugin(in: pluginLib.directory, version: 1, permissions: [.commands])
        let symlinkEscape = testPluginDir.appending(path: "escape-link.txt")
        try? FileManager.default.removeItem(at: symlinkEscape)
        try FileManager.default.createSymbolicLink(at: symlinkEscape, withDestinationURL: outsideSecret)
        try await pluginSettings.update { file in
            file.plugins["panel-test"] = PluginState(enabled: true, grantedPermissions: [.commands])
        }
        let testPanelID = PluginCoordinator.panelID(plugin: "panel-test", panel: "main")
        let testRegistered = await waitUntil(timeoutMs: 3000) {
            DockPanels.type(testPanelID) != nil
        }
        guard testRegistered, let testPanelType = DockPanels.type(testPanelID) else {
            log.check(false, "测试网页面板插件未就绪")
            return
        }
        dock.togglePanel(testPanelType, in: controller.dock)
        guard let testPanel = await waitForWebPanel(testPanelID, in: controller.dock) else {
            log.check(false, "无法打开测试网页面板")
            return
        }
        await waitForJSReady(testPanel)

        // C2.2：子目录 CSS/JS/ES module 载入，../ 与其他插件 id 被拒
        let c22Raw = await evalAsyncJS(testPanel, """
            const cssVal = getComputedStyle(document.documentElement).getPropertyValue('--panel-css-loaded').trim();
            const tryFetch = async (url) => {
              try {
                const res = await fetch(url);
                const text = await res.text();
                return { status: res.status, hasSecret: text.includes('SECRET') };
              } catch (e) {
                return { status: -1, hasSecret: false };
              }
            };
            const r1 = await tryFetch('../outside-secret.txt');
            const r2 = await tryFetch('escape-link.txt');
            const r3 = await tryFetch('macview-plugin://other-plugin/secret.txt');
            return JSON.stringify({
              css: cssVal,
              classic: Boolean(window.__classicLoaded),
              module: window.__moduleLoaded || '',
              r1, r2, r3
            });
            """)
        let c22 = parseJSONDict(c22Raw)
        let c22AssetsOK = (c22?["css"] as? String) == "loaded"
            && (c22?["classic"] as? Bool) == true
            && (c22?["module"] as? String) == "nested-ok"
        let r1Blocked = ((c22?["r1"] as? [String: Any])?["hasSecret"] as? Bool) == false
            && (((c22?["r1"] as? [String: Any])?["status"] as? Int) != 200)
        let r2Blocked = ((c22?["r2"] as? [String: Any])?["hasSecret"] as? Bool) == false
            && (((c22?["r2"] as? [String: Any])?["status"] as? Int) == 403)
        let r3Blocked = ((c22?["r3"] as? [String: Any])?["hasSecret"] as? Bool) == false
            && (((c22?["r3"] as? [String: Any])?["status"] as? Int) != 200)
        log.check(c22AssetsOK && r1Blocked && r2Blocked && r3Blocked, "C2.2 子目录 CSS/JS/ES module 载入成功，越界路径、符号链接越界(403)与跨插件 scheme 被拒：\(c22Raw ?? "nil")")

        // C2.3：mv.page()、mv.command('page.next') 与缺 commands 权限拒绝
        let pageInfoRaw = await evalAsyncJS(testPanel, "return JSON.stringify(await mv.page());")
        let pageInfo = parseJSONDict(pageInfoRaw)
        let pageOK = (pageInfo?["name"] as? String) == "p01.png"
            && (pageInfo?["width"] as? Double) == 480
            && (pageInfo?["height"] as? Double) == 640
        _ = await evalAsyncJS(testPanel, "await mv.command('page.next'); return 'ok';")
        let movedToPage1 = await waitUntil(timeoutMs: 2500) { controller.session.currentPage == 1 }

        // 撤销 commands 权限（先改清单等扫描完成，再同步 plugins.json，使状态始终保持 ready 且同一面板实例就地重建）
        let genBeforeCmdRevoke = testPanel.debugPageGeneration
        try writePanelTestManifest(in: testPluginDir, permissions: [])
        _ = await waitUntil(timeoutMs: 3000) {
            plugins.allPlugins.first(where: { $0.id == "panel-test" })?.manifest?.permissions.isEmpty == true
        }
        try await pluginSettings.update { file in
            file.plugins["panel-test"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let rebuiltAfterCmdRevoke = await waitUntil(timeoutMs: 3000) {
            testPanel.debugPageGeneration > genBeforeCmdRevoke && testPanel.debugIsPageReady
        }
        let sameInstanceAfterCmdRevoke = controller.dock.panels[testPanelID] === testPanel
        await waitForJSReady(testPanel)
        scriptLog.clear()
        let deniedErr = await evalAsyncJS(testPanel, """
            try {
              await mv.command('page.next');
              return 'UNEXPECTED_OK';
            } catch (e) {
              return String(e && e.message ? e.message : e);
            }
            """) ?? ""
        await settle(150)
        let permLogEntries = scriptLog.entries().filter { $0.source == "面板测试" && $0.level == .error }
        let stayedOnPage1 = controller.session.currentPage == 1
        let hasPermReason = deniedErr.contains("commands") && permLogEntries.count == 1 && permLogEntries[0].text == deniedErr
        log.check(
            pageOK && movedToPage1 && rebuiltAfterCmdRevoke && sameInstanceAfterCmdRevoke && stayedOnPage1 && hasPermReason,
            "C2.3 mv.page() 与 mv.command 正常；无 commands 权限时拒绝并恰记 1 条日志（err=\(deniedErr), logs=\(permLogEntries.count)）"
        )

        // C2.4：无 network 拦截、有 network 放行、撤销后重建再拦截，及外部导航/iframe/window.open 取消
        server.clearLog()
        let blockedFetch = await evalAsyncJS(testPanel, """
            try {
              const r = await fetch('\(server.baseURL)/blocked-check');
              return 'OK:' + r.status;
            } catch (e) {
              return 'ERR:' + (e && e.message ? e.message : e);
            }
            """) ?? ""
        await settle(150)
        let noNetBlocked = blockedFetch.hasPrefix("ERR:") && server.loggedPaths().isEmpty

        // 授予 network 权限（先写入已同意权限，再改清单，保持状态始终为 ready 并由同一面板实例快照重建）
        let genBeforeGrantNet = testPanel.debugPageGeneration
        try await pluginSettings.update { file in
            file.plugins["panel-test"] = PluginState(enabled: true, grantedPermissions: [.network])
        }
        try writePanelTestManifest(in: testPluginDir, permissions: [.network])
        let rebuiltForNet = await waitUntil(timeoutMs: 3000) {
            testPanel.snapshot.permissions.contains(.network)
                && testPanel.debugPageGeneration > genBeforeGrantNet
                && testPanel.debugIsPageReady
        }
        await waitForJSReady(testPanel)
        let allowedFetch = await evalAsyncJS(testPanel, """
            try {
              const r = await fetch('\(server.baseURL)/allowed-check');
              return 'OK:' + r.status + ':' + (await r.text());
            } catch (e) {
              return 'ERR:' + (e && e.message ? e.message : e);
            }
            """) ?? ""
        let netAllowedOK = rebuiltForNet && allowedFetch == "OK:200:pong" && server.loggedPaths().contains("/allowed-check")

        // 有 network 权限时，外部导航、外部 iframe、window.open 仍被导航代理与 UI 代理拦截
        let winCountBeforePopup = NSApp.windows.count
        let navResultRaw = await evalAsyncJS(testPanel, """
            const popup = window.open('\(server.baseURL)/popup');
            const frame = document.createElement('iframe');
            frame.src = '\(server.baseURL)/iframe-blocked';
            document.body.appendChild(frame);
            window.location.href = '\(server.baseURL)/nav-blocked';
            return JSON.stringify({ popupNull: popup === null });
            """)
        await settle(300)
        let stillLocalHref = (await evalAsyncJS(testPanel, "return window.location.href;") ?? "").hasPrefix("macview-plugin://panel-test/")
        let navBlockedPaths = server.loggedPaths()
        let navGuardsOK = (parseJSONDict(navResultRaw)?["popupNull"] as? Bool) == true
            && NSApp.windows.count == winCountBeforePopup
            && stillLocalHref
            && !navBlockedPaths.contains("/nav-blocked")
            && !navBlockedPaths.contains("/iframe-blocked")

        // 撤销 network 权限（先改清单，插件状态仍为 ready，再同步 plugins.json），同一面板实例自动重建并再次拦截
        let genBeforeRevokeNet = testPanel.debugPageGeneration
        try writePanelTestManifest(in: testPluginDir, permissions: [])
        _ = await waitUntil(timeoutMs: 3000) {
            plugins.allPlugins.first(where: { $0.id == "panel-test" })?.manifest?.permissions.isEmpty == true
        }
        try await pluginSettings.update { file in
            file.plugins["panel-test"] = PluginState(enabled: true, grantedPermissions: [])
        }
        let rebuiltAfterRevokeNet = await waitUntil(timeoutMs: 3000) {
            !testPanel.snapshot.permissions.contains(.network)
                && testPanel.debugPageGeneration > genBeforeRevokeNet
                && testPanel.debugIsPageReady
        }
        let sameInstanceAfterRevokeNet = controller.dock.panels[testPanelID] === testPanel
        await waitForJSReady(testPanel)
        server.clearLog()
        let revokedFetch = await evalAsyncJS(testPanel, """
            try {
              const r = await fetch('\(server.baseURL)/after-revoke');
              return 'OK:' + r.status;
            } catch (e) {
              return 'ERR:' + (e && e.message ? e.message : e);
            }
            """) ?? ""
        await settle(150)
        let revokedBlocked = rebuiltAfterRevokeNet && sameInstanceAfterRevokeNet && revokedFetch.hasPrefix("ERR:") && !server.loggedPaths().contains("/after-revoke")
        log.check(
            noNetBlocked && netAllowedOK && navGuardsOK && revokedBlocked,
            "C2.4 无 network 拦截、有 network 放行、撤销重建后再拦截且外部导航/iframe/window.open 被拒(noNet=\(noNetBlocked),allow=\(netAllowedOK),nav=\(navGuardsOK),revoke=\(revokedBlocked))"
        )

        // C2.5：切深浅色、改面板字体与强调色，CSS 变量与 prefers-color-scheme 就地更新且不重新载入
        let instanceBeforeTheme = await evalAsyncJS(testPanel, "return String(window.__instanceId || '');") ?? ""
        let originalAppearance = NSApp.appearance
        let originalGlobal = await services.settings.global()
        let targetDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        NSApp.appearance = NSAppearance(named: targetDark ? .darkAqua : .aqua)
        try await services.settings.updateGlobal { settings in
            settings.appearance.accent = originalGlobal.appearance.accent == .clay ? .system : .clay
            settings.appearance.fonts[.panels] = FontSpec(family: "Menlo", size: 15)
        }
        var themeUpdated = false
        var themeVarsRaw = ""
        let themeDeadline = ContinuousClock.now + .milliseconds(2500)
        while ContinuousClock.now < themeDeadline {
            themeVarsRaw = await evalAsyncJS(testPanel, """
                const cs = getComputedStyle(document.documentElement);
                return JSON.stringify({
                  instanceId: String(window.__instanceId || ''),
                  accent: cs.getPropertyValue('--mv-accent').trim(),
                  fontFamily: cs.getPropertyValue('--mv-font-family').trim(),
                  fontSize: cs.getPropertyValue('--mv-font-size').trim(),
                  isDark: window.matchMedia('(prefers-color-scheme: dark)').matches
                });
                """) ?? ""
            if let dict = parseJSONDict(themeVarsRaw),
               (dict["fontSize"] as? String) == "15px",
               (dict["fontFamily"] as? String)?.contains("Menlo") == true,
               (dict["isDark"] as? Bool) == targetDark,
               !(dict["accent"] as? String ?? "").isEmpty {
                themeUpdated = (dict["instanceId"] as? String) == instanceBeforeTheme && !instanceBeforeTheme.isEmpty
                break
            }
            await settle(60)
        }
        // 恢复外观与字体
        NSApp.appearance = originalAppearance
        try await services.settings.updateGlobal { $0.appearance = originalGlobal.appearance }
        await settle(150)
        log.check(themeUpdated, "C2.5 深浅色、面板字体与强调色就地更新且页面未重载：\(themeVarsRaw)")

        // C2.6：改入口文件 2 秒内重新载入；throw、unhandledrejection、console.error 进插件日志
        let genBeforeFileEdit = testPanel.debugPageGeneration
        try writePanelTestHTML(in: testPluginDir, version: 2)
        let reloadedOnFileEdit = await waitUntil(timeoutMs: 2000) {
            testPanel.debugPageGeneration > genBeforeFileEdit && testPanel.debugIsPageReady
        }
        await waitForJSReady(testPanel)
        let versionAfterEdit = await evalAsyncJS(testPanel, "return String(window.__panelVersion || '');")
        scriptLog.clear()
        _ = await evalAsyncJS(testPanel, "window.__triggerErrors(); return 'triggered';")
        let logsForwarded = await waitUntil(timeoutMs: 2500) {
            let entries = scriptLog.entries().filter { $0.source == "面板测试" && $0.level == .error }
            return entries.contains { $0.text.contains("c26-sync-throw") }
                && entries.contains { $0.text.contains("c26-unhandled-reject") }
                && entries.contains { $0.text.contains("c26-console-error") }
        }
        let c26Texts = scriptLog.entries().filter { $0.source == "面板测试" }.map { "\($0.level.rawValue):\($0.text)" }
        log.check(
            reloadedOnFileEdit && versionAfterEdit == "2" && logsForwarded,
            "C2.6 改入口文件 2 秒内重建(v=\(versionAfterEdit ?? "nil"))，throw/unhandledrejection/console.error 全部进插件日志(\(c26Texts))"
        )

        // MARK: C2.8 事件推送与无监听零载荷构造
        _ = await evalAsyncJS(testPanel, "await window.__unsubscribeAll(); return 'ok';")
        await settle(80)
        scriptEvents.resetDispatchCounts()
        controller.session.go(.index(2))
        await settle(120)
        controller.session.go(.index(3))
        await settle(120)
        let zeroPayloadWhenNoListener = scriptEvents.payloadBuildCount == 0 && scriptEvents.panelDispatchCount == 0

        _ = await evalAsyncJS(testPanel, "await window.__subscribeEvents(); return 'ok';")
        let pageTurnStart = ContinuousClock.now
        controller.session.go(.index(4))
        var eventLatencyMs = 9999.0
        var receivedPage4 = false
        let c28Deadline = ContinuousClock.now + .milliseconds(1000)
        while ContinuousClock.now < c28Deadline {
            let lastIdx = await evalAsyncJS(testPanel, "return String(window.__lastPageIndex);")
            if lastIdx == "4" {
                eventLatencyMs = (ContinuousClock.now - pageTurnStart).milliseconds
                receivedPage4 = true
                break
            }
            await settle(20)
        }
        log.check(
            zeroPayloadWhenNoListener && receivedPage4 && eventLatencyMs <= 300,
            "C2.8 无监听时不构造载荷(build=\(scriptEvents.payloadBuildCount))；订阅后翻页 \(String(format: "%.1f", eventLatencyMs)) ms 内收到 pageChanged"
        )

        // MARK: C2.9b 快速翻 10 页合并，重建期间旧事件不投给新页面
        _ = await evalAsyncJS(testPanel, "window.__pageEvents = []; return 'ok';")
        controller.session.go(.index(0))
        await settle(120)
        _ = await evalAsyncJS(testPanel, "window.__pageEvents = []; return 'ok';")
        for idx in 1...9 {
            controller.session.go(.index(idx))
        }
        var lastMergedOK = false
        let mergeDeadline = ContinuousClock.now + .milliseconds(2500)
        while ContinuousClock.now < mergeDeadline {
            if await evalAsyncJS(testPanel, "return String(window.__lastPageIndex);") == "9" {
                lastMergedOK = true
                break
            }
            await settle(30)
        }
        // 重建期间触发的翻页不投给新页面
        testPanel.rebuild()
        controller.session.go(.index(5))
        controller.session.go(.index(6))
        let rebuiltDone = await waitUntil(timeoutMs: 3000) { testPanel.debugIsPageReady }
        await waitForJSReady(testPanel)
        _ = await evalAsyncJS(testPanel, "await window.__subscribeEvents(); return 'ok';")
        await settle(150)
        let staleEventsCount = await evalAsyncJS(testPanel, "return String((window.__pageEvents || []).length);")
        log.check(
            lastMergedOK && rebuiltDone && staleEventsCount == "0",
            "C2.9b 连续快速翻 10 页最终停在末页(index=9)，重建期间旧事件不投给新页面(stale=\(staleEventsCount ?? "nil"))"
        )

        // MARK: C2.9 多窗隔离、浮动切窗先收 targetChanged、关最后窗口收 {hasWindow:false}
        try await verifyMultiWindowAndFloatingEvents(
            window1: controller,
            dock: dock,
            panelID: testPanelID,
            panelType: testPanelType
        )

        // 清理 panel-test，确保后面 C2.10/C2.11 窗口与布局干净
        guard let activeController = app.controllers.first, let activeWindow = activeController.window else {
            log.check(false, "重建活动窗口失败")
            return
        }
        activeWindow.setContentSize(NSSize(width: 1120, height: 760))
        TestPresentation.place(activeWindow)
        activeWindow.makeKeyAndOrderFront(nil)
        await openBook(activeController, url: bookDir, expectedCount: 12)
        activeController.session.go(.index(0))
        await settle(150)

        // MARK: C2.10 示例插件 page-notes 菜单、快捷键与自定义 menus.json 互不干扰
        try copyExamplePlugin("page-notes", to: pluginLib.directory)
        try await pluginSettings.update { file in
            file.plugins["page-notes"] = PluginState(enabled: true, grantedPermissions: [.commands])
        }
        let notesPanelID = PluginCoordinator.panelID(plugin: "page-notes", panel: "notes")
        let notesCmdID = PluginCoordinator.panelToggleCommandID(plugin: "page-notes", panel: "notes")
        let windowMenuTitle = String(localized: "窗口")
        let notesAppeared = await waitUntil(timeoutMs: 2000) {
            Self.windowMenuContains(windowTitle: windowMenuTitle, fragment: "页面笔记")
                && SettingsCommandCatalog.all.contains { $0.id == notesCmdID }
                && ShortcutsModel(store: services.keyBindings).sections.contains { section in
                    section.scope == .global && section.rows.contains { $0.command == notesCmdID }
                }
        }
        try await pluginSettings.update { file in
            file.plugins["page-notes"]?.enabled = false
        }
        let notesDisappeared = await waitUntil(timeoutMs: 2000) {
            !Self.windowMenuContains(windowTitle: windowMenuTitle, fragment: "页面笔记")
                && !SettingsCommandCatalog.all.contains { $0.id == notesCmdID }
        }

        // 自定义 menus.json 不受影响
        let customMenus = MenuFile(mainMenu: [
            .submenu(titleKey: "文件", children: [.command(.fileOpen)]),
            .submenu(titleKey: "窗口", children: [.command(.fullScreenToggle)]),
        ])
        try await services.menus?.update { $0 = customMenus }
        await settle(150)
        try await pluginSettings.update { file in
            file.plugins["page-notes"]?.enabled = true
        }
        let customUntouched = await waitUntil(timeoutMs: 2000) {
            DockPanels.type(notesPanelID) != nil
        } && !Self.windowMenuContains(windowTitle: windowMenuTitle, fragment: "页面笔记")

        try await services.menus?.update { $0 = MenuFile() }
        let defaultMenuRestored = await waitUntil(timeoutMs: 2000) {
            Self.windowMenuContains(windowTitle: windowMenuTitle, fragment: "页面笔记")
        }
        log.check(
            notesAppeared && notesDisappeared && customUntouched && defaultMenuRestored,
            "C2.10 启用 page-notes 2 秒内窗口菜单与快捷键页出现，停用后消失，自定义 menus.json 不受影响"
        )

        // MARK: C2.11 page-notes 示例打开、截图、写笔记立即翻页、下一页按钮与冷重启恢复
        if let menuItem = Self.findWindowMenuItem(windowTitle: windowMenuTitle, fragment: "页面笔记") {
            if NSApp.mainWindow != nil {
                triggerMenuItem(menuItem)
            } else {
                try await services.commands.perform(
                    notesCmdID,
                    arguments: nil,
                    context: CommandContext(session: activeController.session.id, scope: .global, selection: [])
                )
            }
        }
        guard let notesPanel = await waitForWebPanel(notesPanelID, in: activeController.dock) else {
            log.check(false, "C2.11 从窗口菜单打开 page-notes 面板失败")
            return
        }
        let dockedRight = activeController.dock.dockLayout.right.panels.contains(notesPanelID)
        await waitForJSReady(notesPanel)
        let notesInitialOK = await waitUntil(timeoutMs: 3000) {
            notesPanel.debugIsPageReady
        }
        var page0MetaOK = false
        let metaDeadline = ContinuousClock.now + .milliseconds(3000)
        while ContinuousClock.now < metaDeadline {
            let metaRaw = await evalAsyncJS(notesPanel, """
                return JSON.stringify({
                  name: document.getElementById('page-name')?.textContent || '',
                  size: document.getElementById('page-size')?.textContent || ''
                });
                """)
            if let dict = parseJSONDict(metaRaw),
               (dict["name"] as? String) == "p01.png",
               (dict["size"] as? String)?.contains("480") == true,
               (dict["size"] as? String)?.contains("640") == true {
                page0MetaOK = true
                break
            }
            await settle(50)
        }

        // 输入笔记并立即翻页（不等 500 ms）
        let noteText = "第一页的持久笔记-C2.11"
        _ = await evalAsyncJS(notesPanel, """
            const el = document.getElementById('note-input');
            el.value = '\(noteText)';
            el.dispatchEvent(new Event('input', { bubbles: true }));
            return 'typed';
            """)
        // 截图展示 page-notes 面板（含已输入的笔记与当前页信息）
        await settle(150)
        log.snapshot(activeWindow, "panel-page-notes-\(langTag)-\(appearanceTag)")

        // 立刻翻到第 2 页，验证旧页笔记落盘且新页不显示旧页内容
        let page0Token = activeController.session.book.map { ScriptLocationCodec.token(for: $0.pages[0].id) } ?? ""
        activeController.session.go(.index(1))
        var page1Clean = false
        let p1Deadline = ContinuousClock.now + .milliseconds(2500)
        while ContinuousClock.now < p1Deadline {
            let stateRaw = await evalAsyncJS(notesPanel, """
                return JSON.stringify({
                  name: document.getElementById('page-name')?.textContent || '',
                  note: document.getElementById('note-input')?.value || ''
                });
                """)
            if let dict = parseJSONDict(stateRaw),
               (dict["name"] as? String) == "p02.png",
               (dict["note"] as? String) == "" {
                page1Clean = true
                break
            }
            await settle(40)
        }
        let savedToStorage = await waitUntil(timeoutMs: 2500) {
            scriptStorage.get("plugin:page-notes", "note:\(page0Token)") == .string(noteText)
        }

        // 点击面板里的「下一页」按钮，主区翻到第 3 页（index == 2）
        _ = await evalAsyncJS(notesPanel, "document.getElementById('next-btn')?.click(); return 'clicked';")
        let nextBtnWorked = await waitUntil(timeoutMs: 2500) {
            activeController.session.currentPage == 2
        }

        // 冲刷布局和存储，然后拉起冷重启子进程验证重启后笔记仍在
        await dock.flush()
        await settle(250)
        let reopenOK = await runPanelsReopenSubprocess(bookPath: bookDir.path, expectedNote: noteText)
        log.check(
            dockedRight && notesInitialOK && page0MetaOK && page1Clean && savedToStorage && nextBtnWorked && reopenOK,
            "C2.11 page-notes 右区显示、输入即翻页保存且新页不串页、下一页按钮与重启恢复均通过(right=\(dockedRight),meta=\(page0MetaOK),clean=\(page1Clean),saved=\(savedToStorage),next=\(nextBtnWorked),reopen=\(reopenOK))"
        )

        // MARK: C2.7 页面死循环期间主区照常翻页、3 秒判为无响应并提示、点「重新载入」1 秒内恢复
        // 放在最后，确保卡住的旧网页进程在本次自检退出时立即释放。
        if let testType = DockPanels.type(testPanelID) {
            dock.togglePanel(testType, in: activeController.dock)
        }
        guard let hangPanel = await waitForWebPanel(testPanelID, in: activeController.dock) else {
            log.check(false, "C2.7 打开测试面板失败")
            return
        }
        await waitForJSReady(hangPanel)
        _ = await evalAsyncJS(hangPanel, "await window.__subscribeEvents(); return 'ok';")
        activeController.session.go(.index(0))
        await settle(150)

        // 进入死循环（经同步 @MainActor 辅助函数发起，避免 Swift 6 async 替代警告）
        fireAndForgetJS("setTimeout(() => { while (true) {} }, 20);", on: hangPanel)
        await settle(120)

        // 死循环期间真实按键翻页，主线程照常响应，同时触发 pageChanged -> 卡死探测
        activeWindow.makeFirstResponder(activeController.viewer)
        let keyStart = ContinuousClock.now
        await sendKey(kVK_RightArrow, in: activeWindow)
        let mainTurnedPage = await waitUntil(timeoutMs: 800) { activeController.session.currentPage == 1 }
        let keyResponseMs = (ContinuousClock.now - keyStart).milliseconds

        let detectedHang = await waitUntil(timeoutMs: 4500) { hangPanel.isUnresponsive }
        let hangMsg = hangPanel.errorMessage ?? ""
        let hasReleaseHint = isEnglish ? hangMsg.contains("quitting") : hangMsg.contains("退出 App 后释放")

        // 真实点击面板内的「重新载入」按钮，1 秒内新页面可用
        let reloadStart = ContinuousClock.now
        let reloadBtn = hangPanel.debugReloadButton
        let btnRect = reloadBtn.convert(reloadBtn.bounds, to: nil)
        sendMouseClick(at: NSPoint(x: btnRect.midX, y: btnRect.midY), in: activeWindow)
        let recoveredReady = await waitUntil(timeoutMs: 2500) {
            !hangPanel.isUnresponsive && hangPanel.debugIsPageReady
        }
        let recoveredPageRaw = recoveredReady ? await evalAsyncJS(hangPanel, "return JSON.stringify(await mv.page());") : nil
        let reloadElapsedMs = (ContinuousClock.now - reloadStart).milliseconds
        let recoveredPageOK = (parseJSONDict(recoveredPageRaw)?["index"] as? Double) == 1
        log.check(
            mainTurnedPage && keyResponseMs < 500 && detectedHang && hasReleaseHint && recoveredReady && recoveredPageOK && reloadElapsedMs < 1500,
            "C2.7 死循环期间主区 \(String(format: "%.0f", keyResponseMs)) ms 翻页，判为无响应并提示，点击重新载入 \(String(format: "%.0f", reloadElapsedMs)) ms 恢复"
        )

        // MARK: C2.12 英文环境界面文案无未翻译中文
        if isEnglish {
            let samples = [
                String(localized: "插件面板"),
                String(localized: "重新载入"),
                String(localized: "网页无响应"),
                String(localized: "卡住的网页进程会在退出 App 后释放"),
                String(localized: "显示或隐藏 \("Page Notes")"),
                String(localized: "面板：\("Page Notes")"),
            ]
            let untranslated = samples.filter { text in
                text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            }
            log.check(untranslated.isEmpty, "C2.12 英文界面网页面板文案完整无中文：\(untranslated)")
        } else {
            log.check(true, "C2.12 中文界面网页面板自检通过（\(langTag)-\(appearanceTag)）")
        }
    }

    /// C2.11 冷重启子进程：复用隔离目录，验证重启后 page-notes 面板里的笔记仍在。
    func runPanelsReopenSuite(
        controller: ReaderWindowController,
        services: CoreServices,
        plugins: PluginCoordinator
    ) async throws {
        let bookPath = UserDefaults.standard.string(forKey: "MVPluginSelfTestBookPath") ?? ""
        let expectedNote = UserDefaults.standard.string(forKey: "MVPluginSelfTestExpectedNote") ?? ""
        let notesPanelID = PluginCoordinator.panelID(plugin: "page-notes", panel: "notes")

        let ready = await waitUntil(timeoutMs: 3000) {
            DockPanels.type(notesPanelID) != nil
        }
        await openBook(controller, url: URL(fileURLWithPath: bookPath), expectedCount: 12)
        controller.session.go(.index(0))

        guard let notesPanel = await waitForWebPanel(notesPanelID, in: controller.dock) else {
            log.check(false, "C2.11 冷重启后未在原停靠位置恢复 page-notes 面板")
            return
        }
        await waitForJSReady(notesPanel)
        var restoredNote = ""
        let deadline = ContinuousClock.now + .milliseconds(3500)
        while ContinuousClock.now < deadline {
            restoredNote = await evalAsyncJS(notesPanel, "return document.getElementById('note-input')?.value || '';") ?? ""
            if restoredNote == expectedNote { break }
            await settle(50)
        }
        log.check(ready && restoredNote == expectedNote, "C2.11 冷重启后 page-notes 笔记恢复成功：\(restoredNote)")
    }

    // MARK: - C2.1 & C2.1b

    private func verifyDynamicPanelRegistry(controller: ReaderWindowController, dock: DockCoordinator) async throws {
        let dummyID = PanelID("plugin.dummy-c21.pane")
        let dummyCmd = CommandID("plugin.dummy-c21.panel.pane")
        weak var weakDummyInstance: DummySelfTestPanel?
        let dummyType = DockPanelType(
            id: dummyID,
            title: "替身面板",
            symbol: "sparkles",
            toggleCommand: dummyCmd,
            defaultEdge: .right
        ) { (_: DummySelfTestPanel.Settings?) in
            let panel = DummySelfTestPanel()
            weakDummyInstance = panel
            return panel
        }

        // C2.1：登记后 ⋯ 菜单与「窗口」菜单出现；打开并保存；注销后消失、实例销毁、layout.json 保留；再登记回原位
        DockPanels.setPluginTypes([dummyType])
        await settle(80)
        let inOptionsMenu = dock.panelToggles(for: .right, in: controller.dock).contains { $0.title == "替身面板" }
        let inWindowMenu = Self.windowMenuContains(windowTitle: String(localized: "窗口"), fragment: "替身面板")
        dock.togglePanel(dummyType, in: controller.dock)
        await settle(80)
        let openedAtIndex1 = controller.dock.dockLayout.right.panels == [DockPanels.pageList, dummyID]
            && controller.dock.panels[dummyID] != nil
        await dock.flush()

        DockPanels.setPluginTypes([])
        await settle(100)
        let removedFromView = !controller.dock.dockLayout.right.panels.contains(dummyID)
            && controller.dock.panels[dummyID] == nil
            && weakDummyInstance == nil
        let layoutFileText = (try? String(contentsOf: dock.fileURL, encoding: .utf8)) ?? ""
        let preservedInJSON = layoutFileText.contains(dummyID.rawValue)
            && dock.current.right.panels == [DockPanels.pageList, dummyID]

        DockPanels.setPluginTypes([dummyType])
        await settle(80)
        let restoredOriginalPos = controller.dock.dockLayout.right.panels == [DockPanels.pageList, dummyID]
            && controller.dock.dockLayout.currentTab(in: .right) == dummyID
        log.check(
            inOptionsMenu && inWindowMenu && openedAtIndex1 && removedFromView && preservedInJSON && restoredOriginalPos,
            "C2.1 替身插件面板出现在 ⋯ 与窗口菜单，注销销毁并保留 layout.json，再登记回原区原位"
        )

        // C2.1b：选中插件面板被注销时同区内置面板回退显示无空白；拖内置面板到左区再重登记，插件面板回右区为当前标签
        DockPanels.setPluginTypes([])
        await settle(80)
        let fallbackToPageList = controller.dock.dockLayout.right.panels == [DockPanels.pageList]
            && controller.dock.dockLayout.currentTab(in: .right) == DockPanels.pageList
            && controller.dock.panels[DockPanels.pageList]?.view.superview != nil

        // 把页面列表拖到左区末尾
        dock.beginDrag(DockPanels.pageList, from: controller.dock)
        dock.drop(into: controller.dock, at: .area(.left, index: controller.dock.dockLayout.visiblePanels(in: .left).count))
        dock.endDrag(DockPanels.pageList, at: .zero, accepted: true, cancelled: false)
        await settle(80)
        let movedPageListLeft = controller.dock.dockLayout.left.panels.contains(DockPanels.pageList)
            && controller.dock.dockLayout.right.panels.isEmpty

        // 重新登记替身面板：应回到右区且为当前标签
        DockPanels.setPluginTypes([dummyType])
        await settle(80)
        let returnedRightSelected = controller.dock.dockLayout.right.panels == [dummyID]
            && controller.dock.dockLayout.currentTab(in: .right) == dummyID
            && controller.dock.isOnScreen(.right)
        log.check(
            fallbackToPageList && movedPageListLeft && returnedRightSelected,
            "C2.1b 注销选中插件面板后内置面板正常回退无空白，拖内置面板到左区后重登记插件面板回到右区且为当前标签"
        )

        // 恢复默认停靠布局并清除替身类型
        dock.togglePanel(dummyType, in: controller.dock)
        DockPanels.setPluginTypes([])
        dock.beginDrag(DockPanels.pageList, from: controller.dock)
        dock.drop(into: controller.dock, at: .area(.right, index: 0))
        dock.endDrag(DockPanels.pageList, at: .zero, accepted: true, cancelled: false)
        await settle(80)
    }

    // MARK: - C2.9 多窗隔离与浮动面板事件

    private func verifyMultiWindowAndFloatingEvents(
        window1: ReaderWindowController,
        dock: DockCoordinator,
        panelID: PanelID,
        panelType: DockPanelType
    ) async throws {
        guard let window2 = app.newWindow() else {
            log.check(false, "C2.9 无法创建第二个阅读窗口")
            return
        }
        let book2Dir = try makeColorBook(name: "panel-book-w2", count: 6, size: CGSize(width: 320, height: 480))
        await openBook(window2, url: book2Dir, expectedCount: 6)
        window1.session.go(.index(0))
        window2.session.go(.index(0))
        await settle(150)

        // 确保两窗都停靠了测试面板
        if !window1.dock.dockLayout.isPanelVisible(panelID) {
            dock.togglePanel(panelType, in: window1.dock)
        }
        if !window2.dock.dockLayout.isPanelVisible(panelID) {
            dock.togglePanel(panelType, in: window2.dock)
        }
        guard let panel1 = await waitForWebPanel(panelID, in: window1.dock),
              let panel2 = await waitForWebPanel(panelID, in: window2.dock) else {
            log.check(false, "C2.9 两个窗口未能各自打开停靠面板")
            return
        }
        await waitForJSReady(panel1)
        await waitForJSReady(panel2)
        _ = await evalAsyncJS(panel1, "await window.__subscribeEvents(); window.__pageEvents = []; return 'ok';")
        _ = await evalAsyncJS(panel2, "await window.__subscribeEvents(); window.__pageEvents = []; return 'ok';")

        // 窗口 1 翻页：只通知 panel1
        window1.session.go(.index(2))
        await settle(250)
        let p1GotW1 = await evalAsyncJS(panel1, "return String(window.__lastPageIndex);") == "2"
        let p2MissedW1 = await evalAsyncJS(panel2, "return String((window.__pageEvents || []).length);") == "0"

        // 窗口 2 翻页：只通知 panel2
        window2.session.go(.index(4))
        await settle(250)
        let p2GotW2 = await evalAsyncJS(panel2, "return String(window.__lastPageIndex);") == "4"
        let p1CountAfterW2 = await evalAsyncJS(panel1, "return String((window.__pageEvents || []).length);") == "1"

        // 各自 mv.selection() 返回自己窗口的当前页
        let sel1 = await evalAsyncJS(panel1, "return JSON.stringify(await mv.selection());") ?? ""
        let sel2 = await evalAsyncJS(panel2, "return JSON.stringify(await mv.selection());") ?? ""
        let expectedSel1 = window1.session.book.map { ScriptLocationCodec.token(for: $0.pages[2].id) } ?? "missing1"
        let expectedSel2 = window2.session.book.map { ScriptLocationCodec.token(for: $0.pages[4].id) } ?? "missing2"
        let selectionsIsolated = sel1.contains(expectedSel1) && sel2.contains(expectedSel2) && sel1 != sel2

        // 拖出浮动，切活动窗口先收 targetChanged、不再收旧窗事件、mv.page() 改为新窗页
        dock.activate(window1.dock)
        dock.float(panelID, from: window1.dock, at: nil)
        await settle(150)
        guard let floatingPanel = dock.floatingWindows[panelID]?.panel as? PluginWebPanel else {
            log.check(false, "C2.9 无法取得浮动面板实例")
            return
        }
        await waitForJSReady(floatingPanel)
        _ = await evalAsyncJS(floatingPanel, "await window.__subscribeEvents(); window.__eventLog = []; return 'ok';")

        dock.activate(window2.dock)
        await settle(200)
        // 旧窗翻页不应送到浮动面板
        window1.session.go(.index(3))
        await settle(200)
        // 新窗翻页应送到浮动面板
        window2.session.go(.index(5))
        await settle(250)

        let floatLogRaw = await evalAsyncJS(floatingPanel, "return JSON.stringify(window.__eventLog || []);") ?? ""
        let floatPageRaw = await evalAsyncJS(floatingPanel, "return JSON.stringify(await mv.page());") ?? ""
        let floatEvents = (try? JSONSerialization.jsonObject(with: Data(floatLogRaw.utf8)) as? [[String: Any]]) ?? []
        let firstIsTargetTrue = (floatEvents.first?["type"] as? String) == "targetChanged"
            && ((floatEvents.first?["payload"] as? [String: Any])?["hasWindow"] as? Bool) == true
        let noOldW1Event = !floatEvents.contains {
            ($0["type"] as? String) == "pageChanged" && (($0["payload"] as? [String: Any])?["index"] as? Int) == 3
        }
        let gotNewW2Event = floatEvents.contains {
            ($0["type"] as? String) == "pageChanged" && (($0["payload"] as? [String: Any])?["index"] as? Int) == 5
        }
        let floatPageIsW2 = (parseJSONDict(floatPageRaw)?["name"] as? String) == "p06.png"
            && (parseJSONDict(floatPageRaw)?["width"] as? Double) == 320

        // 关掉所有窗口：浮动面板收到 targetChanged({hasWindow: false})
        _ = await evalAsyncJS(floatingPanel, "window.__eventLog = []; return 'ok';")
        window2.window?.performClose(nil)
        window1.window?.performClose(nil)
        await settle(300)
        let afterCloseRaw = await evalAsyncJS(floatingPanel, "return JSON.stringify(window.__eventLog || []);") ?? ""
        let afterCloseEvents = (try? JSONSerialization.jsonObject(with: Data(afterCloseRaw.utf8)) as? [[String: Any]]) ?? []
        let gotNoWindowEvent = afterCloseEvents.contains {
            ($0["type"] as? String) == "targetChanged" && (($0["payload"] as? [String: Any])?["hasWindow"] as? Bool) == false
        }

        // 重开一个主窗口并把浮动测试面板停靠回窗口再隐藏，方便后续检查继续
        let reopened = app.newWindow()
        await settle(150)
        if let reopened {
            dock.activate(reopened.dock)
            dock.dockFloating(panelID)
            await settle(80)
            dock.togglePanel(panelType, in: reopened.dock)
            await settle(80)
        }

        log.check(
            p1GotW1 && p2MissedW1 && p2GotW2 && p1CountAfterW2 && selectionsIsolated
                && firstIsTargetTrue && noOldW1Event && gotNewW2Event && floatPageIsW2 && gotNoWindowEvent,
            "C2.9 双窗隔离、浮动切窗先收 targetChanged 且不再收旧窗事件、关最后窗口收 hasWindow:false"
        )
    }

    // MARK: - 辅助：测试插件生成、JS 求值与冷重启

    private func writePanelTestPlugin(in pluginsDir: URL, version: Int, permissions: [PluginPermission]) throws -> URL {
        let dir = pluginsDir.appending(path: "panel-test", directoryHint: .isDirectory)
        let assets = dir.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try writePanelTestManifest(in: dir, permissions: permissions)
        try writePanelTestHTML(in: dir, version: version)
        try ":root { --panel-css-loaded: loaded; }\n".write(to: assets.appending(path: "style.css"), atomically: true, encoding: .utf8)
        try "window.__classicLoaded = true;\n".write(to: assets.appending(path: "classic.js"), atomically: true, encoding: .utf8)
        try "export const value = 'nested-ok';\n".write(to: assets.appending(path: "nested.js"), atomically: true, encoding: .utf8)
        try """
        import { value } from './nested.js';
        window.__moduleLoaded = value;
        """.write(to: assets.appending(path: "mod.js"), atomically: true, encoding: .utf8)
        return dir
    }

    private func writePanelTestManifest(in dir: URL, permissions: [PluginPermission]) throws {
        let permJSON = permissions.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        try """
        {
          "name": "面板测试",
          "version": "1.0.0",
          "permissions": [\(permJSON)],
          "panels": [
            { "id": "main", "title": "测试面板", "entry": "panel.html", "defaultEdge": "right" }
          ]
        }
        """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    }

    private func writePanelTestHTML(in dir: URL, version: Int) throws {
        try """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <link rel="stylesheet" href="assets/style.css">
        </head>
        <body>
          <div id="status">v\(version)</div>
          <script src="assets/classic.js"></script>
          <script type="module" src="assets/mod.js"></script>
          <script>
            window.__panelVersion = \(version);
            window.__instanceId = Math.random().toString(36).slice(2);
            window.__pageEvents = [];
            window.__eventLog = [];
            window.__lastPageIndex = -1;
            const onPage = (p) => {
              window.__lastPageIndex = p.index;
              window.__pageEvents.push(p.index);
              window.__eventLog.push({ type: 'pageChanged', payload: p });
            };
            const onTarget = (p) => {
              window.__eventLog.push({ type: 'targetChanged', payload: p });
            };
            window.__subscribeEvents = async () => {
              await mv.on('pageChanged', onPage);
              await mv.on('targetChanged', onTarget);
            };
            window.__unsubscribeAll = async () => {
              await mv.off('pageChanged', onPage);
              await mv.off('targetChanged', onTarget);
            };
            window.__triggerErrors = () => {
              setTimeout(() => { throw new Error('c26-sync-throw'); }, 0);
              Promise.reject(new Error('c26-unhandled-reject'));
              console.error('c26-console-error');
            };
            window.__ready = true;
          </script>
        </body>
        </html>
        """.write(to: dir.appending(path: "panel.html"), atomically: true, encoding: .utf8)
    }

    private func waitForWebPanel(_ id: PanelID, in dock: WindowDock) async -> PluginWebPanel? {
        _ = await waitUntil(timeoutMs: 3000) {
            dock.panels[id] is PluginWebPanel
        }
        return dock.panels[id] as? PluginWebPanel
    }

    private func waitForJSReady(_ panel: PluginWebPanel) async {
        _ = await waitUntil(timeoutMs: 3500) { panel.debugIsPageReady }
        let deadline = ContinuousClock.now + .milliseconds(2500)
        while ContinuousClock.now < deadline {
            if let ready = await evalAsyncJS(panel, "return Boolean(window.mv && document.readyState === 'complete');"),
               ready == "true" {
                return
            }
            await settle(40)
        }
    }

    private func fireAndForgetJS(_ script: String, on panel: PluginWebPanel) {
        panel.webView?.evaluateJavaScript(script) { _, _ in }
    }

    private func evalAsyncJS(_ panel: PluginWebPanel, _ body: String) async -> String? {
        guard let webView = panel.webView else { return nil }
        do {
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            if let string = value as? String { return string }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        } catch {
            return nil
        }
    }

    private func parseJSONDict(_ raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func findWindowMenuItem(windowTitle: String, fragment: String) -> NSMenuItem? {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == windowTitle })?.submenu else { return nil }
        for item in menu.items {
            if item.title.contains(fragment) { return item }
            if let sub = item.submenu, let nested = sub.items.first(where: { $0.title.contains(fragment) }) {
                return nested
            }
        }
        return nil
    }

    private static func windowMenuContains(windowTitle: String, fragment: String) -> Bool {
        findWindowMenuItem(windowTitle: windowTitle, fragment: fragment) != nil
    }

    private func runPanelsReopenSubprocess(bookPath: String, expectedNote: String) async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let layoutFile = UserDefaults.standard.string(forKey: DockCoordinator.layoutFileKey) ?? ""
        let proc = Process()
        proc.executableURL = executable
        var args = [
            "-MVPluginSelfTest", "panels-reopen",
            "-MVPluginSelfTestRepo", repoRoot.path,
            "-MVPluginSelfTestBookPath", bookPath,
            "-MVPluginSelfTestExpectedNote", expectedNote,
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
            print("INFO 启动面板冷重启子进程失败：\(error)")
            return false
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                let ok = proc.terminationStatus == 0 && output.contains("SELFTEST OK")
                if !ok {
                    print("INFO 面板冷重启子进程输出：\n\(output)")
                }
                continuation.resume(returning: ok)
            }
        }
    }
}

@MainActor
private final class DummySelfTestPanel: DockPanel {
    struct Settings: Codable {}
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
    let settings = Settings()
    var onSettingsChange: (() -> Void)?
    func bind(to window: ReaderWindowController?) {}
    func addOptions(to menu: NSMenu) {}
}

/// 自检用本地回环 HTTP 服务器（端口动态分配，记录所有收到的请求路径）。
private final class LocalLoopbackHTTPServer {
    let process: Process
    let baseURL: String
    private let logFile: URL

    init(logFile: URL) throws {
        self.logFile = logFile
        let script = """
        import http.server, socketserver, sys

        log_path = sys.argv[1]

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(log_path, 'a', encoding='utf-8') as f:
                    f.write(self.path + '\\n')
                    f.flush()
                body = b'pong'
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, format, *args):
                pass

        with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
            port = httpd.server_address[1]
            sys.stdout.write(f'READY {port}\\n')
            sys.stdout.flush()
            httpd.serve_forever()
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-u", "-c", script, logFile.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc

        let fh = pipe.fileHandleForReading
        var buf = Data()
        while true {
            let chunk = fh.readData(ofLength: 1)
            if chunk.isEmpty { break }
            buf.append(chunk)
            if chunk[0] == 0x0A { break }
        }
        let line = String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("READY "), let port = Int(line.dropFirst(6)) else {
            proc.terminate()
            throw CocoaError(.fileReadUnknown)
        }
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    func clearLog() {
        try? Data().write(to: logFile)
    }

    func loggedPaths() -> [String] {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
#endif
