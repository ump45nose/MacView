#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import MVCommands
import MVFoundation
import MVLayout
import MVReading
import MVServices
import MVSettings
import UniformTypeIdentifiers

/// 外观与窗口外观自检（`-MVAppearanceSelfTest chrome` / `restart-verify` / `background`）。
///
/// 覆盖阶段 2 检查项 C2.1–C2.14（含 C2.5b、C2.12b）。
@MainActor
final class AppearanceSelfTest {
    static let launchKey = "MVAppearanceSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary = TestPresentation.scratchDirectory("appearance")

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return }
        let test = AppearanceSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        if TestPresentation.activationAllowed {
            for _ in 0..<30 where !NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard app.services != nil, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "外观自检需要真实服务与主窗口")
            exit(log.summarize())
        }
        switch mode {
        case "chrome":
            await runChromeSuite(controller: controller, window: window)
            try? FileManager.default.removeItem(at: temporary)
            await app.services?.shutdown()
            await runC210RestartSubprocess()
            exit(log.summarize())
        case "restart-verify":
            await runRestartVerify(window: window)
            try? FileManager.default.removeItem(at: temporary)
            await app.services?.shutdown()
            exit(log.summarize())
        case "background":
            await runBackgroundSuite(controller: controller, window: window)
            try? FileManager.default.removeItem(at: temporary)
            await app.services?.shutdown()
            exit(log.summarize())
        case "fonts":
            await runFontsSuite(controller: controller, window: window)
            try? FileManager.default.removeItem(at: temporary)
            await app.services?.shutdown()
            exit(log.summarize())
        default:
            log.check(false, "未知的 -MVAppearanceSelfTest 模式：\(mode)")
            try? FileManager.default.removeItem(at: temporary)
            await app.services?.shutdown()
            exit(log.summarize())
        }
    }

    // MARK: chrome 自检（C2.1–C2.10）

    private func runChromeSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let books = try makeTestBooks()
            // 收起停靠区，避免遮挡，并打开测试书 1（高饱和度纯色页，便于像素检查）。
            controller.dock.perform { $0.togglingAllAreas() }
            window.setContentSize(NSSize(width: 1000, height: 700))
            TestPresentation.place(window)
            window.makeKeyAndOrderFront(nil)
            await openBook(controller, url: books.book1)
            await settle(250)

            await checkC21AutoHideSingleTab(controller: controller, window: window, expectedNextBookName: books.book2.lastPathComponent)
            await checkC22MultiTabModes(controller: controller, window: window)
            await checkC23KeepOnTopToggle(controller: controller, window: window)
            await checkC24KeepOnTopFullScreen(controller: controller, window: window)
            await checkC25OpacityFullScreen(controller: controller, window: window)
            await checkC25bFullScreenChangeAndNewWindows(controller: controller, window: window)
            await checkC26ExternalHotReload(controller: controller, window: window)
            await checkC27BorderlessCommandDrag(controller: controller, window: window)
            await checkC28AppearanceMode(controller: controller, window: window)
            await checkC29AccentColorHotRefresh(controller: controller, window: window, booksRoot: books.root)
            await prepareC210RestartState()
        } catch {
            log.check(false, "外观自检异常：\(error)")
        }
    }

    // MARK: C2.1 自动隐藏（单标签）+ 顶端浮出 + 点击工具栏“下一本” + 收起

    private func checkC21AutoHideSingleTab(controller: ReaderWindowController, window: NSWindow, expectedNextBookName: String) async {
        guard let services = app.services else { return }
        // 确保查看器使用填满缩放，画面铺到顶端，方便验证顶端 40 pt 是画面而非窗口底色。
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.scaleMode = .fill
            $0.allowUpscale = true
        }
        await settle(250)

        let frameBefore = window.frame
        try? await services.settings.updateGlobal { $0.appearance.window.titleBar = .autoHide }
        let collapsed = await waitUntil(timeoutMs: 1500) {
            window.toolbar?.isVisible == false
        }
        await settle(150)

        let buttonsHidden = allStandardButtonsHidden(in: window)
        let viewerRectInWindow = controller.viewer.convert(controller.viewer.bounds, to: nil)
        let contentTop = controller.content.bounds.maxY
        let topAligned = abs(viewerRectInWindow.maxY - contentTop) <= 1.0
        let frameUnchanged = rectsAlmostEqual(window.frame, frameBefore)

        log.check(
            collapsed && buttonsHidden,
            "C2.1 autoHide 收起态：工具栏隐藏=\(window.toolbar?.isVisible == false)，标准按钮隐藏=\(buttonsHidden)"
        )
        log.check(
            topAligned && frameUnchanged,
            "C2.1 单标签查看器顶边(\(String(format: "%.1f", viewerRectInWindow.maxY))) == 内容视图顶边(\(String(format: "%.1f", contentTop)))，frame 不变=\(frameUnchanged)"
        )

        // 截图检查顶端 40 pt（查看器水平中段）是高饱和橙红色画面，而非窗口底色。
        let topHasImage = checkTopBandContainsRedImage(window: window, viewer: controller.viewer)
        log.check(topHasImage, "C2.1 截图顶端 40 pt 内为画面内容而非窗口底色")

        // 光标移到窗口顶端 6 pt 内，验证 1 秒内工具栏浮出、查看器 frame 不变。
        let viewerFrameBeforeHover = controller.viewer.convert(controller.viewer.bounds, to: nil)
        warpCursorToWindow(window, x: window.frame.midX, y: window.frame.maxY - 2)
        let revealed = await waitUntil(timeoutMs: 1000) {
            window.toolbar?.isVisible == true
        }
        await settle(120)
        let viewerFrameDuringHover = controller.viewer.convert(controller.viewer.bounds, to: nil)
        let viewerStable = rectsAlmostEqual(viewerFrameBeforeHover, viewerFrameDuringHover)
        log.check(
            revealed && viewerStable,
            "C2.1 光标移到顶端后 1 秒内工具栏浮出=\(revealed)，查看器 frame 不变=\(viewerStable)"
        )

        // 经 NSApp.sendEvent 点击工具栏上的“下一本”按钮。
        let clickedNext = await clickToolbarButton(identifier: "book.next", in: window)
        let switchedBook = await waitUntil(timeoutMs: 2500) {
            controller.session.book?.location.name == expectedNextBookName
        }
        log.check(
            clickedNext && switchedBook,
            "C2.1 浮出工具栏经 NSApp.sendEvent 点“下一本”生效（找到按钮=\(clickedNext)，当前书=\(controller.session.book?.location.name ?? "nil")）"
        )

        // 光标移开标题栏与工具栏区域，0.6 秒后收起。
        warpCursorToWindow(window, x: window.frame.midX, y: window.frame.midY)
        let collapsedAgain = await waitUntil(timeoutMs: 1600) {
            window.toolbar?.isVisible == false
        }
        log.check(collapsedAgain, "C2.1 光标移开后工具栏收起=\(collapsedAgain)")
    }

    // MARK: C2.2 两标签三态切换 + 标签栏避让 + selectNextTab

    private func checkC22MultiTabModes(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services else { return }
        try? await services.settings.updateGlobal { $0.appearance.window.titleBar = .shown }
        _ = await waitUntil(timeoutMs: 1500) { window.toolbar?.isVisible == true }
        await settle(150)

        guard let second = app.newTab(beside: controller), let secondWindow = second.window else {
            log.check(false, "C2.2 创建第二个标签失败")
            return
        }
        _ = await waitUntil(timeoutMs: 1500) {
            (window.tabGroup?.windows.count ?? 0) == 2
        }
        await settle(150)

        let activeWindow = window.tabGroup?.selectedWindow ?? secondWindow
        let initialFrame = activeWindow.frame
        var allTabsKept = true
        var allFramesKept = true

        // shown → autoHide
        try? await services.settings.updateGlobal { $0.appearance.window.titleBar = .autoHide }
        _ = await waitUntil(timeoutMs: 1500) { activeWindow.toolbar?.isVisible == false }
        await settle(200)
        if (activeWindow.tabGroup?.windows.count ?? 0) != 2 { allTabsKept = false }
        if !rectsAlmostEqual(activeWindow.frame, initialFrame) { allFramesKept = false }

        let activeController = (activeWindow.windowController as? ReaderWindowController) ?? second
        let viewerTopInAutoHide = activeController.viewer.convert(activeController.viewer.bounds, to: nil).maxY
        let tabBarMinY = activeController.chrome.tabBarMinYInWindow()
        let flushToTabBar = tabBarMinY.map { abs(viewerTopInAutoHide - $0) <= 2.0 } ?? false
        log.check(
            flushToTabBar,
            "C2.2 两标签 autoHide 查看器顶边(\(String(format: "%.1f", viewerTopInAutoHide))) 紧贴标签栏底边(\(tabBarMinY.map { String(format: "%.1f", $0) } ?? "nil"))"
        )

        // 在 autoHide 下用 selectNextTab 切标签，确认另一标签窗口同为收起态。
        TestPresentation.activateIfAllowed()
        activeWindow.makeKeyAndOrderFront(nil)
        await settle(100)
        activeWindow.selectNextTab(nil)
        let switchedWindow = await waitUntil(timeoutMs: 1000) {
            let selected = activeWindow.tabGroup?.selectedWindow
            return selected != nil && selected !== activeWindow
        } ? activeWindow.tabGroup?.selectedWindow : activeWindow.tabGroup?.selectedWindow
        await settle(150)
        let switchedCollapsed = switchedWindow != nil
            && switchedWindow !== activeWindow
            && switchedWindow?.toolbar?.isVisible == false
            && allStandardButtonsHidden(in: switchedWindow!)
        log.check(
            switchedCollapsed,
            "C2.2 autoHide 下 selectNextTab 切到另一标签同为收起态（切换成功=\(switchedWindow !== activeWindow)，toolbar隐藏=\(switchedWindow?.toolbar?.isVisible == false)）"
        )

        // autoHide → borderless
        let currentTab = switchedWindow ?? activeWindow
        try? await services.settings.updateGlobal { $0.appearance.window.titleBar = .borderless }
        await settle(200)
        if (currentTab.tabGroup?.windows.count ?? 0) != 2 { allTabsKept = false }
        if !rectsAlmostEqual(currentTab.frame, initialFrame) { allFramesKept = false }
        TestPresentation.activateIfAllowed()
        currentTab.makeKeyAndOrderFront(nil)
        await settle(150)
        let borderlessButtonsHidden = allStandardButtonsHidden(in: currentTab)
        let borderlessCanBeKey = currentTab.canBecomeKey && (!NSApp.isActive || currentTab.isKeyWindow)
        log.check(
            borderlessButtonsHidden && borderlessCanBeKey,
            "C2.2 borderless 三按钮隐藏=\(borderlessButtonsHidden)，可成为 key=\(currentTab.canBecomeKey)，isKeyWindow=\(currentTab.isKeyWindow)（App活跃=\(NSApp.isActive)）"
        )

        // borderless → shown
        try? await services.settings.updateGlobal { $0.appearance.window.titleBar = .shown }
        _ = await waitUntil(timeoutMs: 1500) { currentTab.toolbar?.isVisible == true }
        await settle(200)
        if (currentTab.tabGroup?.windows.count ?? 0) != 2 { allTabsKept = false }
        if !rectsAlmostEqual(currentTab.frame, initialFrame) { allFramesKept = false }
        log.check(
            allTabsKept && allFramesKept,
            "C2.2 两标签三态切换全程保留两个标签=\(allTabsKept)，每步 frame 与初始相同=\(allFramesKept)"
        )

        // 关闭第二个标签，回到单标签。
        secondWindow.close()
        await settle(150)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: C2.3 window.keepOnTop.toggle 命令 + 浮动面板跟随 + 菜单勾选

    private func checkC23KeepOnTopToggle(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services, let dock = app.dock else { return }
        // 打开一个浮动面板以验证跟随置顶。
        dock.perform(in: controller.dock) { layout in
            var next = layout
            if !next.isPanelVisible(DockPanels.info) {
                next = next.togglingPanel(DockPanels.info, defaultEdge: .right)
            }
            return next
        }
        await settle(120)
        dock.float(DockPanels.info, from: controller.dock, at: nil)
        await settle(150)
        guard let floating = dock.floatingWindows[DockPanels.info] else {
            log.check(false, "C2.3 未能创建浮动面板")
            return
        }

        // 在非 global 作用域（.viewer）执行 window.keepOnTop.toggle。
        app.dispatcher?.run(.windowKeepOnTopToggle, in: controller, scope: .viewer)
        let pinned = await waitUntil(timeoutMs: 1500) {
            window.level == .floating
        }
        await settle(120)
        let settingsOn = await services.settings.global().appearance.window.keepOnTop
        let allReadersFloating = app.controllers.allSatisfy { $0.window?.level == .floating }
        let floatingPinned = floating.level.rawValue >= NSWindow.Level.floating.rawValue && !floating.hidesOnDeactivate
        let menuChecked = menuItemState(for: .windowKeepOnTopToggle) == .on
        log.check(
            pinned && settingsOn && allReadersFloating && floatingPinned && menuChecked,
            "C2.3 首次 toggle：settings=\(settingsOn)，阅读窗floating=\(allReadersFloating)，浮动面板跟随=\(floatingPinned)，菜单勾选=\(menuChecked)"
        )

        // 再执行一次全部恢复。
        app.dispatcher?.run(.windowKeepOnTopToggle, in: controller, scope: .textInput)
        let unpinned = await waitUntil(timeoutMs: 1500) {
            window.level == .normal
        }
        await settle(120)
        let settingsOff = await services.settings.global().appearance.window.keepOnTop == false
        let allReadersNormal = app.controllers.allSatisfy { $0.window?.level == .normal }
        let floatingRestored = floating.hidesOnDeactivate == true
        let menuUnchecked = menuItemState(for: .windowKeepOnTopToggle) == .off
        log.check(
            unpinned && settingsOff && allReadersNormal && floatingRestored && menuUnchecked,
            "C2.3 再次 toggle：settings关闭=\(settingsOff)，阅读窗normal=\(allReadersNormal)，浮动面板恢复=\(floatingRestored)，菜单取消勾选=\(menuUnchecked)"
        )
    }

    // MARK: C2.4 置顶时全屏与退出恢复

    private func checkC24KeepOnTopFullScreen(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services else { return }
        try? await services.settings.updateGlobal { $0.appearance.window.keepOnTop = true }
        _ = await waitUntil(timeoutMs: 1500) { window.level == .floating }
        await settle(100)

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let entered = await waitUntil(timeoutMs: 6000) { controller.chrome.isFullScreenSettled }
        await settle(150)

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let exited = await waitUntil(timeoutMs: 6000) { !controller.chrome.isFullScreen && !window.styleMask.contains(.fullScreen) }
        await settle(200)
        let levelRestored = window.level == .floating
        log.check(
            entered && exited && levelRestored,
            "C2.4 置顶时进入全屏=\(entered)，退出全屏=\(exited)，退出后 level 回到 .floating=\(levelRestored)"
        )
    }

    // MARK: C2.5 opacity=0.6 与全屏

    private func checkC25OpacityFullScreen(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.window.keepOnTop = false
            $0.appearance.window.opacity = 0.6
        }
        let applied = await waitUntil(timeoutMs: 1500) {
            self.app.controllers.allSatisfy { abs(($0.window?.alphaValue ?? 0) - 0.6) < 0.01 }
        }
        await settle(100)

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let entered = await waitUntil(timeoutMs: 6000) { controller.chrome.isFullScreenSettled }
        await settle(150)
        let alphaInFullScreen = abs(window.alphaValue - 1.0) < 0.01

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let exited = await waitUntil(timeoutMs: 6000) { !controller.chrome.isFullScreen && !window.styleMask.contains(.fullScreen) }
        await settle(200)
        let alphaAfterExit = abs(window.alphaValue - 0.6) < 0.01

        log.check(
            applied && entered && alphaInFullScreen && exited && alphaAfterExit,
            "C2.5 opacity=0.6 生效=\(applied)，全屏中为1=\(alphaInFullScreen)，退出后恢复0.6=\(alphaAfterExit)"
        )
    }

    // MARK: C2.5b 全屏中修改 keepOnTop/opacity + 新窗口与新浮动面板立即套用

    private func checkC25bFullScreenChangeAndNewWindows(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services, let dock = app.dock else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.window.keepOnTop = false
            $0.appearance.window.opacity = 1.0
        }
        _ = await waitUntil(timeoutMs: 1500) {
            window.level == .normal && abs(window.alphaValue - 1.0) < 0.01
        }

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let entered = await waitUntil(timeoutMs: 6000) { controller.chrome.isFullScreenSettled }
        await settle(150)

        try? await services.settings.updateGlobal {
            $0.appearance.window.keepOnTop = true
            $0.appearance.window.opacity = 0.5
        }
        await settle(250)
        let unchangedInFullScreen = window.level == .normal && abs(window.alphaValue - 1.0) < 0.01

        app.dispatcher?.run(.fullScreenToggle, in: controller, scope: .global)
        let exited = await waitUntil(timeoutMs: 6000) { !controller.chrome.isFullScreen && !window.styleMask.contains(.fullScreen) }
        await settle(200)
        let appliedAfterExit = window.level == .floating && abs(window.alphaValue - 0.5) < 0.01

        // 新开阅读窗口与新浮动面板应立即是当前设置。
        let newWinController = app.newWindow()
        let newWin = newWinController?.window
        let newWinImmediate = newWin?.level == .floating && abs((newWin?.alphaValue ?? 0) - 0.5) < 0.01

        dock.perform(in: controller.dock) { layout in
            var next = layout
            if !next.isPanelVisible(DockPanels.effects) {
                next = next.togglingPanel(DockPanels.effects, defaultEdge: .right)
            }
            return next
        }
        await settle(100)
        dock.float(DockPanels.effects, from: controller.dock, at: nil)
        await settle(120)
        let newFloating = dock.floatingWindows[DockPanels.effects]
        let newFloatingImmediate = newFloating != nil
            && (newFloating?.level.rawValue ?? 0) >= NSWindow.Level.floating.rawValue
            && newFloating?.hidesOnDeactivate == false

        log.check(
            entered && unchangedInFullScreen && exited && appliedAfterExit && newWinImmediate && newFloatingImmediate,
            "C2.5b 全屏中保持normal/1=\(unchangedInFullScreen)，退出后floating/0.5=\(appliedAfterExit)，新窗口立即套用=\(newWinImmediate)，新浮动面板立即套用=\(newFloatingImmediate)"
        )

        newWin?.close()
        await settle(100)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: C2.6 外部修改 settings.json 热重载

    private func checkC26ExternalHotReload(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.window.keepOnTop = false
            $0.appearance.window.opacity = 1.0
        }
        _ = await waitUntil(timeoutMs: 1500) {
            window.level == .normal && abs(window.alphaValue - 1.0) < 0.01
        }
        await settle(100)

        let settingsURL = app.supportDirectory.appending(path: "settings.json")
        do {
            let raw = try Data(contentsOf: settingsURL)
            guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  var value = root["value"] as? [String: Any] else {
                log.check(false, "C2.6 settings.json 结构无效")
                return
            }
            var appearance = (value["appearance"] as? [String: Any]) ?? [:]
            var win = (appearance["window"] as? [String: Any]) ?? [:]
            win["keepOnTop"] = true
            win["opacity"] = 0.75
            appearance["window"] = win
            value["appearance"] = appearance
            root["value"] = value
            let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: settingsURL, options: .atomic)
        } catch {
            log.check(false, "C2.6 外部改写 settings.json 失败：\(error)")
            return
        }

        let reloadedWithin500ms = await waitUntil(timeoutMs: 500) {
            window.level == .floating && abs(window.alphaValue - 0.75) < 0.01
        }
        log.check(
            reloadedWithin500ms,
            "C2.6 外部改 settings.json 后 0.5 秒内热重载生效（level=\(window.level.rawValue)，alpha=\(String(format: "%.2f", window.alphaValue))）"
        )
    }

    // MARK: C2.7 无边框 ⌘ 拖动

    private func checkC27BorderlessCommandDrag(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services, let readerWindow = window as? ReaderWindow else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.window.titleBar = .borderless
            $0.appearance.window.keepOnTop = false
            $0.appearance.window.opacity = 1.0
        }
        let active = await waitUntil(timeoutMs: 1500) {
            controller.chrome.isBorderlessActive
        }
        await settle(150)

        let viewerCenter = controller.viewer.convert(
            NSPoint(x: controller.viewer.bounds.midX, y: controller.viewer.bounds.midY),
            to: nil
        )
        let beforePlain = readerWindow.performDragCallCount
        sendMouseClick(at: viewerCenter, in: window, modifiers: [])
        await settle(80)
        let afterPlain = readerWindow.performDragCallCount

        sendMouseClick(at: viewerCenter, in: window, modifiers: [.command])
        await settle(80)
        let afterCommand = readerWindow.performDragCallCount

        log.check(
            active && afterPlain == beforePlain && afterCommand == beforePlain + 1,
            "C2.7 无边框 ⌘ 拖动：无⌘不调用(\(afterPlain - beforePlain))，带⌘调用 performDrag(\(afterCommand - afterPlain))"
        )
    }

    // MARK: C2.8 外观模式切换（dark / light / system）

    private func checkC28AppearanceMode(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services, let dock = app.dock else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.window.titleBar = .shown
            $0.appearance.mode = .system
        }
        _ = await waitUntil(timeoutMs: 1500) {
            NSApp.appearance == nil && window.toolbar?.isVisible == true
        }
        await settle(150)

        let systemIsDark = isDarkAppearance(NSApp.effectiveAppearance)

        // 确保存在浮动面板与设置窗口，验证所有窗口的 effectiveAppearance 同步切换。
        if dock.floatingWindows[DockPanels.info] == nil {
            dock.perform(in: controller.dock) { layout in
                var next = layout
                if !next.isPanelVisible(DockPanels.info) {
                    next = next.togglingPanel(DockPanels.info, defaultEdge: .right)
                }
                return next
            }
            await settle(100)
            dock.float(DockPanels.info, from: controller.dock, at: nil)
            await settle(120)
        }
        guard let floating = dock.floatingWindows[DockPanels.info],
              let settingsWindow = app.openSettings()?.window else {
            log.check(false, "C2.8 无法打开浮动面板或设置窗口")
            return
        }
        await settle(120)

        // 写 mode=dark：应用、阅读窗口、浮动面板、设置窗口全部为深色。
        try? await services.settings.updateGlobal { $0.appearance.mode = .dark }
        let switchedDark = await waitUntil(timeoutMs: 1500) {
            self.isDarkAppearance(NSApp.effectiveAppearance)
                && self.isDarkAppearance(window.effectiveAppearance)
                && self.isDarkAppearance(floating.effectiveAppearance)
                && self.isDarkAppearance(settingsWindow.effectiveAppearance)
        }
        log.check(
            switchedDark,
            "C2.8 mode=dark：NSApp=\(isDarkAppearance(NSApp.effectiveAppearance))，阅读窗=\(isDarkAppearance(window.effectiveAppearance))，浮动面板=\(isDarkAppearance(floating.effectiveAppearance))，设置窗=\(isDarkAppearance(settingsWindow.effectiveAppearance))"
        )

        // 写 mode=light：全部为浅色。
        try? await services.settings.updateGlobal { $0.appearance.mode = .light }
        let switchedLight = await waitUntil(timeoutMs: 1500) {
            !self.isDarkAppearance(NSApp.effectiveAppearance)
                && !self.isDarkAppearance(window.effectiveAppearance)
                && !self.isDarkAppearance(floating.effectiveAppearance)
                && !self.isDarkAppearance(settingsWindow.effectiveAppearance)
        }
        log.check(
            switchedLight,
            "C2.8 mode=light：四处均切回浅色=\(switchedLight)"
        )

        // 写 mode=system：NSApp.appearance 为 nil，全部跟随系统外观。
        try? await services.settings.updateGlobal { $0.appearance.mode = .system }
        let followedSystem = await waitUntil(timeoutMs: 1500) {
            NSApp.appearance == nil
                && self.isDarkAppearance(NSApp.effectiveAppearance) == systemIsDark
                && self.isDarkAppearance(window.effectiveAppearance) == systemIsDark
                && self.isDarkAppearance(floating.effectiveAppearance) == systemIsDark
                && self.isDarkAppearance(settingsWindow.effectiveAppearance) == systemIsDark
        }
        log.check(
            followedSystem,
            "C2.8 mode=system：NSApp.appearance==nil(\(NSApp.appearance == nil))，四处跟随系统(isDark=\(systemIsDark))=\(followedSystem)"
        )

        settingsWindow.close()
        await settle(100)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: C2.9 强调色热刷新（瀑布流选中环 / 停靠放置指示 / 书架搜索结果高亮）

    private func checkC29AccentColorHotRefresh(controller: ReaderWindowController, window: NSWindow, booksRoot: URL) async {
        guard let services = app.services, let dock = app.dock else { return }

        try? await services.settings.updateGlobal { $0.appearance.accent = .clay }
        _ = await waitUntil(timeoutMs: 1500) { Theme.accentMode == .clay }
        await settle(100)

        // 1. 切换到瀑布流并选中第 0 项。
        controller.session.update { $0.browseMode = .waterfall }
        let canvas = controller.viewer.continuous.canvas
        let waterfallReady = await waitUntil(timeoutMs: 3000) {
            !canvas.items.isEmpty && canvas.tileBorderColor(at: 0) != nil
        }
        canvas.select([0], focus: 0)
        await settle(100)

        // 2. 打开左侧书架，对测试书目录建立索引并搜索 "Book" 以产生高亮结果行。
        dock.perform(in: controller.dock) { layout in
            var next = layout
            if !next.isPanelVisible(DockPanels.bookshelf) {
                next = next.togglingPanel(DockPanels.bookshelf, defaultEdge: .left)
            }
            return next
        }
        let shelfReady = await waitUntil(timeoutMs: 1500) { controller.bookshelfPanel != nil }
        guard waterfallReady, shelfReady, let bookshelf = controller.bookshelfPanel else {
            log.check(false, "C2.9 准备工作失败（瀑布流=\(waterfallReady)，书架=\(shelfReady)）")
            return
        }
        guard let rootLoc = try? await services.sources.location(for: booksRoot) else {
            log.check(false, "C2.9 无法解析测试书根目录 Location")
            return
        }
        bookshelf.startIndexing(folder: rootLoc)
        _ = await waitUntil(timeoutMs: 5000) {
            IndexController.shared.state?.progress.phase == .finished
        }
        bookshelf.searchController.submit(text: "Book")
        let searchReady = await waitUntil(timeoutMs: 3000) {
            bookshelf.searchController.isSearching
                && !bookshelf.searchController.isLoading
                && !bookshelf.searchResultsView.hits.isEmpty
        }
        bookshelf.searchResultsView.table.layoutSubtreeIfNeeded()
        await settle(100)
        guard searchReady else {
            log.check(false, "C2.9 书架搜索未能产生高亮结果")
            return
        }

        // 3. 辅助：发起一次面板拖动并在右侧空白边缘显示放置指示层，读取其图层颜色后结束拖动。
        func sampleDropIndicatorColors() async -> (background: CGColor?, border: CGColor?) {
            dock.beginDrag(DockPanels.info, from: nil)
            let rightEdgePoint = NSPoint(x: max(controller.dock.bounds.width - 10, 10), y: controller.dock.bounds.midY)
            _ = controller.dock.showDropIndicator(at: rightEdgePoint)
            window.displayIfNeeded()
            await settle(60)
            let colors = controller.dock.dropIndicatorLayerColors
            controller.dock.hideDropIndicator()
            dock.endDrag(DockPanels.info, at: .zero, accepted: false, cancelled: true)
            return colors
        }

        // 写 accent=system，不重开窗口，校验三处均为 controlAccentColor（按各自当前外观解析）。
        try? await services.settings.updateGlobal { $0.appearance.accent = .system }
        _ = await waitUntil(timeoutMs: 1500) { Theme.accentMode == .system }
        await settle(150)

        let expectedCanvasSystem = resolvedControlAccent(in: canvas.effectiveAppearance)
        let expectedDockSystem = resolvedControlAccent(in: controller.dock.effectiveAppearance)
        let expectedDockSoftSystem = resolvedControlAccentSoft(in: controller.dock.effectiveAppearance)
        let expectedSearchSoftSystem = resolvedControlAccentSoft(in: bookshelf.searchResultsView.effectiveAppearance)

        let canvasBorderSystem = canvas.tileBorderColor(at: 0).flatMap(srgbColor)
        let dropSystem = await sampleDropIndicatorColors()
        let dropBorderSystem = dropSystem.border.flatMap(srgbColor)
        let dropBgSystem = dropSystem.background.flatMap(srgbColor)
        let searchBgSystem = bookshelf.searchResultsView.highlightedBackgroundColor(at: 0)

        let canvasMatchesSystem = colorsAlmostEqual(canvasBorderSystem, expectedCanvasSystem)
        let dropMatchesSystem = colorsAlmostEqual(dropBorderSystem, expectedDockSystem)
            && colorsAlmostEqual(dropBgSystem, expectedDockSoftSystem)
        let searchMatchesSystem = colorsAlmostEqual(searchBgSystem, expectedSearchSoftSystem)
        log.check(
            canvasMatchesSystem && dropMatchesSystem && searchMatchesSystem,
            "C2.9 accent=system 不重开窗口：瀑布流选中环=\(canvasMatchesSystem)，停靠放置指示=\(dropMatchesSystem)，书架搜索高亮=\(searchMatchesSystem)"
        )

        // 写回 accent=clay，不重开窗口，校验三处回到 Clay。
        try? await services.settings.updateGlobal { $0.appearance.accent = .clay }
        _ = await waitUntil(timeoutMs: 1500) { Theme.accentMode == .clay }
        await settle(150)

        let expectedClay = clayColor(alpha: 1)
        let expectedDockClaySoft = claySoftColor(in: controller.dock.effectiveAppearance)
        let expectedSearchClaySoft = claySoftColor(in: bookshelf.searchResultsView.effectiveAppearance)

        let canvasBorderClay = canvas.tileBorderColor(at: 0).flatMap(srgbColor)
        let dropClay = await sampleDropIndicatorColors()
        let dropBorderClay = dropClay.border.flatMap(srgbColor)
        let dropBgClay = dropClay.background.flatMap(srgbColor)
        let searchBgClay = bookshelf.searchResultsView.highlightedBackgroundColor(at: 0)

        let canvasMatchesClay = colorsAlmostEqual(canvasBorderClay, expectedClay)
        let dropMatchesClay = colorsAlmostEqual(dropBorderClay, expectedClay)
            && colorsAlmostEqual(dropBgClay, expectedDockClaySoft)
        let searchMatchesClay = colorsAlmostEqual(searchBgClay, expectedSearchClaySoft)
        log.check(
            canvasMatchesClay && dropMatchesClay && searchMatchesClay,
            "C2.9 accent=clay 不重开窗口：瀑布流选中环=\(canvasMatchesClay)，停靠放置指示=\(dropMatchesClay)，书架搜索高亮=\(searchMatchesClay)"
        )

        bookshelf.exitSearch()
        await settle(80)
    }

    // MARK: C2.10 跨进程重启后外观与强调色保持

    private func prepareC210RestartState() async {
        guard let services = app.services else { return }
        try? await services.settings.updateGlobal {
            $0.appearance.mode = .dark
            $0.appearance.accent = .system
        }
        _ = await waitUntil(timeoutMs: 1500) {
            self.app.appearance?.current.mode == .dark
                && self.app.appearance?.current.accent == .system
                && Theme.accentMode == .system
        }
        await settle(150)
    }

    private func runC210RestartSubprocess() async {
        guard let executable = Bundle.main.executableURL else {
            log.check(false, "C2.10 找不到当前可执行文件路径")
            return
        }
        let layoutPath = UserDefaults.standard.string(forKey: DockCoordinator.layoutFileKey)
            ?? app.supportDirectory.appending(path: "layout-restart.json").path
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-MVAppearanceSelfTest", "restart-verify",
            "-MVSupportDirectory", app.supportDirectory.path,
            "-MVCacheDirectory", app.cacheDirectory.path,
            "-MVLayoutFile", layoutPath,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            log.check(false, "C2.10 启动重启验证子进程失败：\(error)")
            return
        }
        let result: (status: Int32, output: String) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
        if !result.output.isEmpty {
            print(result.output, terminator: result.output.hasSuffix("\n") ? "" : "\n")
            fflush(stdout)
        }
        log.check(result.status == 0, "C2.10 重启新进程校验外观与强调色保持（exit=\(result.status)）")
    }

    private func runRestartVerify(window: NSWindow) async {
        let applied = await waitUntil(timeoutMs: 2500) {
            self.app.appearance?.hasApplied == true
        }
        await settle(120)
        let modeKept = app.appearance?.current.mode == .dark
        let accentKept = app.appearance?.current.accent == .system && Theme.accentMode == .system
        let appDark = isDarkAppearance(NSApp.effectiveAppearance)
        let windowDark = isDarkAppearance(window.effectiveAppearance)
        let resolvedAccent: NSColor? = {
            var color: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                color = Theme.accent.usingColorSpace(.sRGB)
            }
            return color
        }()
        let accentMatchesSystem = colorsAlmostEqual(resolvedAccent, resolvedControlAccent(in: window.effectiveAppearance))
        log.check(
            applied && modeKept && accentKept && appDark && windowDark && accentMatchesSystem,
            "C2.10 重启后保持：applied=\(applied)，mode=dark(\(modeKept))，accent=system(\(accentKept))，app深色=\(appDark)，窗口深色=\(windowDark)，强调色=系统(\(accentMatchesSystem))"
        )
    }

    // MARK: 辅助方法

    private func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func srgbColor(_ cgColor: CGColor) -> NSColor? {
        NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
    }

    private func resolvedControlAccent(in appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = .controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        }
        return resolved
    }

    private func resolvedControlAccentSoft(in appearance: NSAppearance) -> NSColor {
        let alpha: CGFloat = isDarkAppearance(appearance) ? 0.2 : 0.14
        return resolvedControlAccent(in: appearance).withAlphaComponent(alpha)
    }

    private func clayColor(alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(0xD9) / 255, green: CGFloat(0x77) / 255, blue: CGFloat(0x57) / 255, alpha: alpha)
    }

    private func claySoftColor(in appearance: NSAppearance) -> NSColor {
        clayColor(alpha: isDarkAppearance(appearance) ? 0.2 : 0.14)
    }

    private func colorsAlmostEqual(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.02) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= tolerance
            && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
            && abs(a.alphaComponent - b.alphaComponent) <= tolerance
    }

    private func makeTestBooks() throws -> (root: URL, book1: URL, book2: URL) {
        let root = temporary.appending(path: "books", directoryHint: .isDirectory)
        let book1 = root.appending(path: "Book1", directoryHint: .isDirectory)
        let book2 = root.appending(path: "Book2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: book1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book2, withIntermediateDirectories: true)
        try writeSolidPNG(to: book1.appending(path: "01.png"), r: 235, g: 55, b: 40)
        try writeSolidPNG(to: book2.appending(path: "01.png"), r: 40, g: 140, b: 235)
        return (root, book1, book2)
    }

    private func writeSolidPNG(to url: URL, r: UInt8, g: UInt8, b: UInt8) throws {
        let width = 800
        let height = 800
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r
            pixels[i + 1] = g
            pixels[i + 2] = b
            pixels[i + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "AppearanceSelfTest", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AppearanceSelfTest", code: 2)
        }
    }

    private func openBook(_ controller: ReaderWindowController, url: URL) async {
        controller.open([url])
        _ = await waitUntil(timeoutMs: 3000) {
            controller.session.book?.location.name == url.lastPathComponent && !(controller.session.book?.pages.isEmpty ?? true)
        }
    }

    private func allStandardButtonsHidden(in window: NSWindow) -> Bool {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        return types.allSatisfy { window.standardWindowButton($0)?.isHidden == true }
    }

    private func rectsAlmostEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.size.width - b.size.width) <= tolerance
            && abs(a.size.height - b.size.height) <= tolerance
    }

    private func checkTopBandContainsRedImage(window: NSWindow, viewer: NSView) -> Bool {
        guard let cgImage = log.snapshot(window, "c21-autohide-top", captureImage: true) else { return false }
        guard let rep = NSBitmapImageRep(cgImage: cgImage) as NSBitmapImageRep? else { return false }
        let scaleX = CGFloat(cgImage.width) / max(window.frame.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(window.frame.height, 1)
        let viewerRect = viewer.convert(viewer.bounds, to: nil)
        let sampleX = Int(viewerRect.midX * scaleX)
        let maxY = min(cgImage.height - 1, Int(40 * scaleY))
        guard sampleX >= 0, sampleX < cgImage.width, maxY > 4 else { return false }
        var redHits = 0
        for y in stride(from: 4, through: maxY, by: 2) {
            if let color = rep.colorAt(x: sampleX, y: y)?.usingColorSpace(.sRGB) {
                if color.redComponent > 0.75 && color.greenComponent < 0.45 && color.blueComponent < 0.45 {
                    redHits += 1
                }
            }
        }
        return redHits >= 3
    }

    private func warpCursorToWindow(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 900
        let cgPoint = CGPoint(x: x, y: primaryHeight - y)
        CGWarpMouseCursorPosition(cgPoint)
        // 同步发一个 mouseMoved，确保在合成环境下也能立即刷新追踪区。
        let locationInWindow = NSPoint(x: x - window.frame.minX, y: y - window.frame.minY)
        if let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) {
            NSApp.sendEvent(event)
        }
    }

    private func clickToolbarButton(identifier: String, in window: NSWindow) async -> Bool {
        guard let themeFrame = window.contentView?.superview else { return false }
        let targetTitle = app.catalog.title(of: CommandID(identifier))
        guard let button = findButton(in: themeFrame, matchingTitleOrToolTip: targetTitle) else { return false }
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        sendMouseClick(at: center, in: window, modifiers: [])
        return true
    }

    private func findButton(in view: NSView, matchingTitleOrToolTip title: String) -> NSView? {
        if let control = view as? NSControl {
            if control.toolTip == title || control.accessibilityLabel() == title || control.accessibilityTitle() == title {
                return control
            }
        }
        if view.toolTip == title { return view }
        for subview in view.subviews {
            if let found = findButton(in: subview, matchingTitleOrToolTip: title) {
                return found
            }
        }
        return nil
    }

    private func sendMouseClick(at pointInWindow: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        let now = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: modifiers,
            timestamp: now,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) {
            NSApp.sendEvent(down)
        }
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: modifiers,
            timestamp: now + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) {
            NSApp.sendEvent(up)
        }
    }

    private func menuItemState(for commandID: CommandID) -> NSControl.StateValue? {
        guard let windowsMenu = NSApp.windowsMenu else { return nil }
        windowsMenu.update()
        let expectedTitle = app.catalog.title(of: commandID)
        guard let item = windowsMenu.items.first(where: { $0.title == expectedTitle }) else { return nil }
        return item.state
    }

    private func waitUntil(timeoutMs: Int, condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func settle(_ ms: Int = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: background 自检（C2.11–C2.14）

    private actor AsyncGate {
        private var entered = false
        private var released = false
        private var enterWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            entered = true
            let waiters = enterWaiters
            enterWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if released { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                if entered {
                    continuation.resume()
                } else {
                    enterWaiters.append(continuation)
                }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func runBackgroundSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let fixtures = try await makeBackgroundFixtures()

            window.setContentSize(NSSize(width: 1120, height: 740))
            TestPresentation.place(window)
            window.makeKeyAndOrderFront(nil)

            // 打开右侧效果面板并确保停靠区可见，供 C2.11 / C2.13 / C2.14 检查。
            app.dock?.perform(in: controller.dock) { layout in
                var next = layout
                if !next.isPanelVisible(DockPanels.effects) {
                    next = next.togglingPanel(DockPanels.effects, defaultEdge: .right)
                }
                if !next.isShowing(.right) {
                    next = next.settingCollapsed(.right, false)
                }
                return next.selecting(DockPanels.effects)
            }
            await openBook(controller, url: fixtures.book1)
            controller.session.update {
                $0.browseMode = .paged
                $0.pageMode = .single
                $0.background = .auto
            }
            await settle(250)

            await checkC211FrostedGlass(controller: controller, window: window)
            await checkC212bStaleEdgeColorRejected(controller: controller, window: window, fixtures: fixtures)
            await checkC212ImageEdgeColor(controller: controller, window: window, fixtures: fixtures)
            await checkC213SwatchesProfilesAndSettings(controller: controller, window: window, fixtures: fixtures)
            await checkC214BackgroundLayoutNoTruncation(controller: controller, window: window)
        } catch {
            log.check(false, "背景自检异常：\(error)")
        }
    }

    // MARK: C2.11 毛玻璃

    private func checkC211FrostedGlass(controller: ReaderWindowController, window: NSWindow) async {
        controller.session.update { $0.background = .frostedGlass }
        let frostedOn = await waitUntil(timeoutMs: 1500) {
            !controller.viewer.frostedEffectView.isHidden && !window.isOpaque
        }
        await settle(100)
        window.displayIfNeeded()

        let effectView = controller.viewer.frostedEffectView
        let blendingOK = effectView.blendingMode == .behindWindow
        let dockArea = controller.dock.areas[.right]
        let dockOpaque = (dockArea?.layer?.backgroundColor?.alpha ?? 0) >= 0.99
        let statusOpaque = (controller.content.statusBar.layer?.backgroundColor?.alpha ?? 0) >= 0.99

        log.check(
            frostedOn && blendingOK && !window.isOpaque && dockOpaque && statusOpaque,
            "C2.11 毛玻璃开启：effectVisible=\(!effectView.isHidden)，behindWindow=\(blendingOK)，windowOpaque=\(window.isOpaque)，停靠区不透明=\(dockOpaque)，状态栏不透明=\(statusOpaque)"
        )

        controller.session.update { $0.background = .auto }
        let restored = await waitUntil(timeoutMs: 1500) {
            window.isOpaque && controller.viewer.frostedEffectView.isHidden
        }
        log.check(
            restored && window.isOpaque && controller.viewer.frostedEffectView.isHidden,
            "C2.11 换回自动后恢复：windowOpaque=\(window.isOpaque)，effectHidden=\(controller.viewer.frostedEffectView.isHidden)"
        )
    }

    // MARK: C2.12b 取色进行中切回自动或换书

    private func checkC212bStaleEdgeColorRejected(
        controller: ReaderWindowController,
        window: NSWindow,
        fixtures: (book1: URL, book2: URL)
    ) async {
        ImageEdgeColorCache.shared.removeAll()
        controller.session.go(.index(0))
        controller.session.update { $0.background = .auto }
        await settle(100)

        // 1. 取色进行中切回“自动”：迟到的结果不得改背景。
        let gate1 = AsyncGate()
        controller.viewer.debugEdgeColorFetchHook = { _ in
            await gate1.arriveAndWait()
        }
        controller.session.update { $0.background = .imageColor }
        await gate1.waitUntilEntered()
        controller.session.update { $0.background = .auto }
        await settle(60)
        await gate1.release()
        await settle(180)
        controller.viewer.debugEdgeColorFetchHook = nil

        let expectedCanvas = resolvedThemeColor(Theme.canvas, in: controller.viewer.effectiveAppearance)
        let colorAfterCancel = controller.viewer.layer?.backgroundColor.flatMap(srgbColor)
        let stayedAuto = controller.session.settings.background == .auto
            && colorsAlmostEqual(colorAfterCancel, expectedCanvas, tolerance: 0.03)
        log.check(
            stayedAuto,
            "C2.12b 取色中切回自动：迟到结果未覆盖背景（matchesAuto=\(stayedAuto)）"
        )

        // 2. 取色进行中换书：换书后背景先为“自动”，旧书迟到结果不改新书背景。
        ImageEdgeColorCache.shared.removeAll()
        // 预先把 Book2 默认背景也设为 imageColor（通过全局默认），这样换到 Book2 后立刻进入按图取色流程。
        try? await app.services?.settings.updateGlobal { $0.defaultBook.background = .imageColor }
        await settle(120)

        let book1Gate = AsyncGate()
        let book2Gate = AsyncGate()
        controller.viewer.debugEdgeColorFetchHook = { identity in
            if identity.location.name == "01_white.png" {
                await book1Gate.arriveAndWait()
            } else {
                await book2Gate.arriveAndWait()
            }
        }
        controller.session.go(.index(0))
        controller.session.update { $0.background = .imageColor }
        await book1Gate.waitUntilEntered()

        // 切换到 Book2。
        await openBook(controller, url: fixtures.book2)
        await book2Gate.waitUntilEntered()
        let expectedCanvasBook2 = resolvedThemeColor(Theme.canvas, in: controller.viewer.effectiveAppearance)
        let colorOnNewBookInitial = controller.viewer.layer?.backgroundColor.flatMap(srgbColor)
        let startsAsAuto = controller.viewer.currentEdgeColor == nil
            && colorsAlmostEqual(colorOnNewBookInitial, expectedCanvasBook2, tolerance: 0.03)

        // 放行 Book1 的迟到结果，确认不会覆盖 Book2 的背景。
        await book1Gate.release()
        await settle(180)
        let colorAfterStaleBook1 = controller.viewer.layer?.backgroundColor.flatMap(srgbColor)
        let staleBook1Ignored = controller.viewer.currentEdgeColor == nil
            && colorsAlmostEqual(colorAfterStaleBook1, expectedCanvasBook2, tolerance: 0.03)

        // 放行 Book2 并还原全局默认背景。
        await book2Gate.release()
        controller.viewer.debugEdgeColorFetchHook = nil
        try? await app.services?.settings.updateGlobal { $0.defaultBook.background = .auto }
        await settle(150)

        log.check(
            startsAsAuto && staleBook1Ignored,
            "C2.12b 取色中换书：新书初始为自动(\(startsAsAuto))，旧书迟到结果未覆盖(\(staleBook1Ignored))"
        )

        // 切回 Book1 继续 C2.12。
        await openBook(controller, url: fixtures.book1)
        await settle(120)
    }

    // MARK: C2.12 按图取色

    private func checkC212ImageEdgeColor(
        controller: ReaderWindowController,
        window: NSWindow,
        fixtures: (book1: URL, book2: URL)
    ) async {
        _ = fixtures
        controller.session.update { $0.background = .auto }
        await settle(80)
        ImageEdgeColorCache.shared.removeAll()
        controller.viewer.debugResetEdgeColorCounters()
        controller.session.go(.index(0)) // 01_white.png
        controller.session.update { $0.background = .imageColor }

        let whiteOK = await waitUntil(timeoutMs: 1000) {
            guard let edge = controller.viewer.currentEdgeColor,
                  let layer = controller.viewer.layer?.backgroundColor.flatMap(self.srgbColor) else { return false }
            let layerLum = 0.2126 * layer.redComponent + 0.7152 * layer.greenComponent + 0.0722 * layer.blueComponent
            return edge.luminance > 0.85 && layerLum > 0.85
        }
        log.check(
            whiteOK,
            "C2.12 白底页 1 秒内背景亮度 > 0.85（lum=\(String(format: "%.3f", controller.viewer.currentEdgeColor?.luminance ?? -1))）"
        )

        controller.session.go(.index(1)) // 02_dark.png
        let darkOK = await waitUntil(timeoutMs: 1000) {
            guard let edge = controller.viewer.currentEdgeColor,
                  let layer = controller.viewer.layer?.backgroundColor.flatMap(self.srgbColor) else { return false }
            let layerLum = 0.2126 * layer.redComponent + 0.7152 * layer.greenComponent + 0.0722 * layer.blueComponent
            return edge.luminance < 0.3 && layerLum < 0.3
        }
        let darkColor = controller.viewer.currentEdgeColor
        log.check(
            darkOK,
            "C2.12 深色页 1 秒内背景亮度 < 0.3（lum=\(String(format: "%.3f", darkColor?.luminance ?? -1))）"
        )

        // 翻到视频页：颜色保持不变。
        controller.session.go(.index(2)) // 03_video.mp4
        await settle(250)
        let videoUnchanged = controller.viewer.currentEdgeColor == darkColor
        log.check(videoUnchanged, "C2.12 翻到视频页背景颜色不变=\(videoUnchanged)")

        // 回到已缓存的白底页：命中缓存不再请求缩略图。
        let countBeforeCacheHit = controller.viewer.debugEdgeColorThumbnailCount
        controller.session.go(.index(0)) // 01_white.png
        let cacheHitApplied = await waitUntil(timeoutMs: 1000) {
            (controller.viewer.currentEdgeColor?.luminance ?? 0) > 0.85
        }
        let countAfterCacheHit = controller.viewer.debugEdgeColorThumbnailCount
        log.check(
            cacheHitApplied && countAfterCacheHit == countBeforeCacheHit,
            "C2.12 命中缓存不再请求缩略图（before=\(countBeforeCacheHit)，after=\(countAfterCacheHit)）"
        )

        // 连续快速翻 5 页（index 3...7），最终颜色应对应第 7 页（08_purple.png: 155, 55, 220）。
        for idx in 3...7 {
            controller.session.go(.index(idx))
        }
        let expectedPurple = NSColor(srgbRed: 155 / 255, green: 55 / 255, blue: 220 / 255, alpha: 1)
        let rapidFinalOK = await waitUntil(timeoutMs: 2000) {
            guard let edge = controller.viewer.currentEdgeColor else { return false }
            return self.colorsAlmostEqual(edge.nsColor, expectedPurple, tolerance: 0.08)
        }
        log.check(
            rapidFinalOK,
            "C2.12 连续快速翻 5 页最终颜色对应最后一页（purple=\(rapidFinalOK)，actual=\(String(describing: controller.viewer.currentEdgeColor))）"
        )
        _ = window
    }

    // MARK: C2.13 效果面板 8 色块、显示配置与设置下拉

    private func checkC213SwatchesProfilesAndSettings(
        controller: ReaderWindowController,
        window: NSWindow,
        fixtures: (book1: URL, book2: URL)
    ) async {
        guard let panel = controller.effectsPanel, let services = app.services else {
            log.check(false, "C2.13 效果面板未打开")
            return
        }
        panel.panelView.layoutSubtreeIfNeeded()
        await settle(80)

        var allSwatchesClickedOK = true
        for option in EffectsPanelView.BackgroundOption.allCases {
            guard let swatch = panel.panelView.swatchView(for: option) else {
                allSwatchesClickedOK = false
                continue
            }
            let center = swatch.convert(NSPoint(x: swatch.bounds.midX, y: swatch.bounds.midY), to: nil)
            sendMouseClick(at: center, in: window, modifiers: [])
            let matched = await waitUntil(timeoutMs: 1000) {
                option.matches(controller.session.settings.background)
            }
            if !matched {
                allSwatchesClickedOK = false
            }
            if option == .custom {
                NSColorPanel.shared.close()
            }
        }
        log.check(
            allSwatchesClickedOK && EffectsPanelView.BackgroundOption.allCases.count == 8,
            "C2.13 效果面板 8 个色块点击全部写入书层 background=\(allSwatchesClickedOK)"
        )

        // 选中毛玻璃，存为显示配置，切到另一本书并套用。
        if let frostedSwatch = panel.panelView.swatchView(for: .frostedGlass) {
            let center = frostedSwatch.convert(NSPoint(x: frostedSwatch.bounds.midX, y: frostedSwatch.bounds.midY), to: nil)
            sendMouseClick(at: center, in: window, modifiers: [])
        }
        _ = await waitUntil(timeoutMs: 1000) { controller.session.settings.background == .frostedGlass }

        let profileName = "C2.13-Frosted"
        panel.saveProfile(name: profileName, groups: [.background], from: controller.session.settings)
        let savedProfileReady = await waitUntil(timeoutMs: 1500) {
            panel.profiles.contains { $0.name == profileName }
        }
        let savedProfile = panel.profiles.first { $0.name == profileName }

        await openBook(controller, url: fixtures.book2)
        controller.session.update { $0.background = .auto }
        await settle(100)
        if let savedProfile {
            DisplayProfileHelpers.applyToBook(savedProfile, in: controller)
        }
        let appliedOnBook2 = await waitUntil(timeoutMs: 1000) {
            controller.session.settings.background == .frostedGlass
        }
        if let savedProfile {
            panel.deleteProfile(id: savedProfile.id)
        }
        controller.session.update { $0.background = .auto }
        await settle(100)

        // 核对设置“显示”页默认背景选项与路径规则背景选项包含两项新值。
        let displayValues = OverrideField.backgrounds.map(\.1)
        let displayHasBoth = displayValues.contains(.frostedGlass) && displayValues.contains(.imageColor)
        let pathRuleHasBoth: Bool = {
            guard let field = OverrideField.all.first(where: { $0.id == "background" }),
                  case let .choice(options) = field.control else { return false }
            var sawFrosted = false
            var sawImageColor = false
            for opt in options {
                var probe = BookSettings()
                opt.apply(&probe)
                if probe.background == .frostedGlass { sawFrosted = true }
                if probe.background == .imageColor { sawImageColor = true }
            }
            return sawFrosted && sawImageColor
        }()
        var frostedSample = ResolvedBookSettings.default
        frostedSample.background = .frostedGlass
        var imageColorSample = ResolvedBookSettings.default
        imageColorSample.background = .imageColor
        let summaryOK = DisplayProfileHelpers.summary(of: .background, in: frostedSample) == String(localized: "毛玻璃")
            && DisplayProfileHelpers.summary(of: .background, in: imageColorSample) == String(localized: "按图取色")

        _ = services
        log.check(
            savedProfileReady && appliedOnBook2 && displayHasBoth && pathRuleHasBoth && summaryOK,
            "C2.13 显示配置跨书套用=\(savedProfileReady && appliedOnBook2)，设置显示页含两新值=\(displayHasBoth)，路径规则含两新值=\(pathRuleHasBoth)，摘要正确=\(summaryOK)"
        )
    }

    // MARK: C2.14 浅色/深色、中英文下效果面板背景区无截断

    private func checkC214BackgroundLayoutNoTruncation(controller: ReaderWindowController, window: NSWindow) async {
        guard let panel = controller.effectsPanel else {
            log.check(false, "C2.14 效果面板未打开")
            return
        }
        let panelView = panel.panelView
        let savedAppearance = window.appearance
        let savedTitles: [EffectsPanelView.BackgroundOption: String] = Dictionary(
            uniqueKeysWithValues: EffectsPanelView.BackgroundOption.allCases.compactMap { opt in
                panelView.swatchLabel(for: opt).map { (opt, $0.stringValue) }
            }
        )

        let zhTitles: [EffectsPanelView.BackgroundOption: String] = [
            .auto: "自动", .black: "黑", .gray: "灰", .white: "白",
            .checkerboard: "棋盘格", .frostedGlass: "毛玻璃", .imageColor: "按图取色", .custom: "自定义",
        ]
        let enTitles: [EffectsPanelView.BackgroundOption: String] = [
            .auto: "Auto", .black: "Black", .gray: "Gray", .white: "White",
            .checkerboard: "Checker", .frostedGlass: "Frosted", .imageColor: "From Image", .custom: "Custom",
        ]

        var failures: [String] = []
        for modeName in ["light", "dark"] {
            window.appearance = NSAppearance(named: modeName == "dark" ? .darkAqua : .aqua)
            for (lang, titles) in [("zh", zhTitles), ("en", enTitles)] {
                for (opt, text) in titles {
                    panelView.swatchLabel(for: opt)?.stringValue = text
                }
                panelView.needsLayout = true
                panelView.layoutSubtreeIfNeeded()
                await settle(40)

                for (opt, text) in titles {
                    guard let label = panelView.swatchLabel(for: opt), let font = label.font else {
                        failures.append("\(modeName)/\(lang)/\(opt): missing label")
                        continue
                    }
                    let availableWidth = label.bounds.width
                    let availableHeight = label.bounds.height
                    let attrs: [NSAttributedString.Key: Any] = [.font: font]
                    let singleLineHeight = ceil(("Ag" as NSString).size(withAttributes: attrs).height)
                    // 每个单词宽度不能超过可用宽度，否则会被硬截断。
                    for word in text.split(separator: " ") {
                        let wordWidth = ceil((String(word) as NSString).size(withAttributes: attrs).width)
                        if wordWidth > availableWidth + 1.0 {
                            failures.append("\(modeName)/\(lang)/\(text): wordWidth(\(wordWidth)) > \(availableWidth)")
                        }
                    }
                    let wrapped = (text as NSString).boundingRect(
                        with: NSSize(width: max(availableWidth, 1), height: 200),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attrs
                    )
                    let maxLines = (lang == "en" && opt == .imageColor) ? 2 : 1
                    let maxAllowedHeight = singleLineHeight * CGFloat(maxLines) + 2.0
                    if wrapped.height > maxAllowedHeight || wrapped.height > availableHeight + 2.0 {
                        failures.append("\(modeName)/\(lang)/\(text): wrappedH=\(wrapped.height), availH=\(availableHeight), maxH=\(maxAllowedHeight)")
                    }
                }
            }
        }

        // 还原外观与文案。
        for (opt, text) in savedTitles {
            panelView.swatchLabel(for: opt)?.stringValue = text
        }
        window.appearance = savedAppearance
        panelView.layoutSubtreeIfNeeded()

        log.check(
            failures.isEmpty,
            "C2.14 浅色/深色、中英文效果面板背景区布局无截断（failures=\(failures.joined(separator: "; "))）"
        )
    }

    private func resolvedThemeColor(_ color: NSColor, in appearance: NSAppearance) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return resolved
    }

    private func makeBackgroundFixtures() async throws -> (book1: URL, book2: URL) {
        let root = temporary.appending(path: "bg-books", directoryHint: .isDirectory)
        let book1 = root.appending(path: "BgBook1", directoryHint: .isDirectory)
        let book2 = root.appending(path: "BgBook2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: book1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book2, withIntermediateDirectories: true)

        try writeSolidPNG(to: book1.appending(path: "01_white.png"), r: 250, g: 250, b: 250)
        try writeSolidPNG(to: book1.appending(path: "02_dark.png"), r: 24, g: 24, b: 24)
        try await Self.writeMinimalMP4(to: book1.appending(path: "03_video.mp4"))
        try writeSolidPNG(to: book1.appending(path: "04_red.png"), r: 230, g: 45, b: 45)
        try writeSolidPNG(to: book1.appending(path: "05_green.png"), r: 45, g: 210, b: 70)
        try writeSolidPNG(to: book1.appending(path: "06_blue.png"), r: 40, g: 95, b: 235)
        try writeSolidPNG(to: book1.appending(path: "07_amber.png"), r: 235, g: 170, b: 35)
        try writeSolidPNG(to: book1.appending(path: "08_purple.png"), r: 155, g: 55, b: 220)

        try writeSolidPNG(to: book2.appending(path: "01_cyan.png"), r: 30, g: 200, b: 210)
        return (book1, book2)
    }

    private nonisolated static func writeMinimalMP4(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120,
        ])
        let receiver = writer.inputPixelBufferReceiver(
            for: input,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: 160, height: 120)
            )
        )
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            guard let pool = receiver.pixelBufferPool else {
                throw NSError(domain: "AppearanceSelfTest", code: 11)
            }
            var buffer = try pool.makeMutablePixelBuffer()
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                for plane in planes {
                    plane.bytes.initializeMemory(as: UInt8.self, repeating: UInt8(80 + index * 40))
                }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(index), timescale: 2))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "AppearanceSelfTest", code: 12)
        }
    }

    // MARK: fonts 自检（C3.1–C3.4）

    private struct TextFontSample {
        let label: String
        let font: NSFont
        let readCurrent: () -> NSFont?
    }

    private func runFontsSuite(controller: ReaderWindowController, window: NSWindow) async {
        guard let services = app.services, let dock = app.dock else {
            log.check(false, "fonts 自检需要真实服务与 DockCoordinator")
            return
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            _ = await waitUntil(timeoutMs: 2500) { self.app.appearance?.hasApplied == true }

            // 准备 16 本测试书，确保书架可以滚动并保留选中项与滚动位置。
            let booksRoot = temporary.appending(path: "font-books", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: booksRoot, withIntermediateDirectories: true)
            var firstBookURL: URL!
            for idx in 1...16 {
                let dir = booksRoot.appending(path: String(format: "Book_%02d", idx), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try writeSolidPNG(to: dir.appending(path: "01.png"), r: UInt8(40 + idx * 10), g: 120, b: 200)
                if idx == 1 {
                    try writeSolidPNG(to: dir.appending(path: "02.png"), r: 120, g: 180, b: 90)
                    try writeSolidPNG(to: dir.appending(path: "03.png"), r: 210, g: 90, b: 70)
                    firstBookURL = dir
                }
            }

            window.setContentSize(NSSize(width: 1120, height: 760))
            TestPresentation.place(window)
            window.makeKeyAndOrderFront(nil)
            await openBook(controller, url: firstBookURL)
            await settle(200)

            // 打开 8 个面板：bookshelf / pageList / history / bookmarks / playlist / info / classify / effects。
            let leftPanels: [PanelID] = [DockPanels.bookshelf, DockPanels.pageList, PanelID("history"), PanelID("bookmarks")]
            let rightPanels: [PanelID] = [PanelID("playlist"), DockPanels.info, DockPanels.classify, DockPanels.effects]
            dock.perform(in: controller.dock) { layout in
                var next = layout
                for id in leftPanels where !next.isPanelVisible(id) {
                    next = next.togglingPanel(id, defaultEdge: .left)
                }
                for id in rightPanels where !next.isPanelVisible(id) {
                    next = next.togglingPanel(id, defaultEdge: .right)
                }
                return next
            }
            let allOpened = await waitUntil(timeoutMs: 2500) {
                (leftPanels + rightPanels).allSatisfy { controller.dock.panels[$0] != nil }
            }
            guard allOpened, let bookshelf = controller.bookshelfPanel else {
                log.check(false, "fonts 自检未能打开全部面板")
                return
            }
            // 确保书架内容已加载并处于列表模式，设置非零滚动位置与选中项。
            let shelfLoaded = await waitUntil(timeoutMs: 3000) {
                (bookshelf.collection?.items.count ?? 0) >= 10
            }
            bookshelf.setStyle(.list)
            await settle(150)
            bookshelf.view.layoutSubtreeIfNeeded()
            if let col = bookshelf.collection {
                col.setCurrent(5, reveal: false)
                col.scrollOrigin = NSPoint(x: 0, y: 80)
                await settle(100)
            }
            let shelfSelectionBefore = bookshelf.collection?.selectedIndices ?? []
            let shelfScrollBefore = bookshelf.collection?.scrollOrigin ?? .zero

            // 展开所有面板视图的布局，使表格生成可见行。
            for id in leftPanels + rightPanels {
                if let view = controller.dock.panels[id]?.view {
                    if view.bounds.size == .zero {
                        view.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
                    }
                    view.layoutSubtreeIfNeeded()
                }
            }

            // 显示 HUD、多键提示、瀑布流页码标签以便采样叠加层。
            controller.viewer.hud.isHidden = false
            controller.viewer.hud.refresh()
            controller.viewer.hud.updateZoom(percent: 100)
            controller.pendingView.show(InputRouter.Pending(
                typed: [KeyChord("g", modifiers: [])],
                next: [(chord: KeyChord("g", modifiers: []), title: "第一页")]
            ))
            await settle(120)

            // 记录启动时的基线字体（供 C3.4 对比）。
            let allPanelIDs = leftPanels + rightPanels
            var baselinePanelSamples: [TextFontSample] = []
            for id in allPanelIDs {
                if let view = controller.dock.panels[id]?.view {
                    baselinePanelSamples.append(contentsOf: collectPanelFontSamples(in: view, prefix: id.rawValue))
                }
            }
            let baselineOverlaySamples = collectOverlayFontSamples(controller: controller)
            let baselineMenuFont = viewSubmenu()?.font
            let baselineNestedMenuFonts = collectMenuFonts(under: viewSubmenu())
            let baselineContextMenuFont = buildViewerContextMenu(controller: controller)?.font
            let sortButton = findView(in: bookshelf.view, identifier: "collection.sortButton") as? NSButton
            let baselineSortButtonFont = sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font

            // MARK: C3.1 fonts.panels = {family: "Menlo", size: 16}
            try await services.settings.updateGlobal {
                $0.appearance.fonts[.panels] = FontSpec(family: "Menlo", size: 16)
            }
            _ = await waitUntil(timeoutMs: 1500) { Theme.fonts[.panels]?.family == "Menlo" }
            await settle(150)

            var c31Mismatches: [String] = []
            for sample in baselinePanelSamples {
                guard let current = sample.readCurrent() else { continue }
                let expectedSize = (sample.font.pointSize * (16.0 / 12.0) * 2).rounded() / 2
                let familyOK = current.familyName == "Menlo"
                let sizeOK = abs(current.pointSize - expectedSize) <= 0.5
                if !familyOK || !sizeOK {
                    c31Mismatches.append("\(sample.label): got \(current.familyName ?? "nil") \(current.pointSize), want Menlo \(expectedSize)")
                }
            }
            let shelfSelectionAfter = bookshelf.collection?.selectedIndices ?? []
            let shelfScrollAfter = bookshelf.collection?.scrollOrigin ?? .zero
            let shelfStateKept = shelfSelectionAfter == shelfSelectionBefore
                && abs(shelfScrollAfter.y - shelfScrollBefore.y) <= 1.0

            // 触发书架搜索结果并检查搜索结果视图字体。
            if let rootLoc = try? await services.sources.location(for: booksRoot) {
                bookshelf.startIndexing(folder: rootLoc)
                _ = await waitUntil(timeoutMs: 5000) { IndexController.shared.state?.progress.phase == .finished }
                bookshelf.searchController.submit(text: "Book")
                _ = await waitUntil(timeoutMs: 3000) {
                    bookshelf.searchController.isSearching
                        && !bookshelf.searchController.isLoading
                        && !bookshelf.searchResultsView.hits.isEmpty
                }
                bookshelf.searchResultsView.layoutSubtreeIfNeeded()
                await settle(100)
                let searchSamples = collectPanelFontSamples(in: bookshelf.searchResultsView, prefix: "searchResults")
                for sample in searchSamples where sample.font.familyName != "Menlo" {
                    c31Mismatches.append("\(sample.label): got \(sample.font.familyName ?? "nil") \(sample.font.pointSize)")
                }
                bookshelf.exitSearch()
                await settle(80)
            }

            // 改完后新打开一个面板（新建一个独立 InfoPanel 实例模拟改后新打开），确认同样是 Menlo；同时保留已有面板实例以供 C3.4 对比。
            let freshInfo = InfoPanel(nil)
            let reopenedInfoSamples = collectPanelFontSamples(in: freshInfo.view, prefix: "reopened.info")
            let reopenedInfoOK = !reopenedInfoSamples.isEmpty && reopenedInfoSamples.allSatisfy { $0.font.familyName == "Menlo" }

            // 叠加层与菜单组字体不变。
            let overlaysUnchangedInC31 = baselineOverlaySamples.allSatisfy { $0.readCurrent() == $0.font }
            let menusUnchangedInC31 = viewSubmenu()?.font == baselineMenuFont
                && (sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font) == baselineSortButtonFont

            log.check(
                shelfLoaded && c31Mismatches.isEmpty && shelfStateKept && reopenedInfoOK && overlaysUnchangedInC31 && menusUnchangedInC31,
                "C3.1 fonts.panels=Menlo 16：面板控件(\(baselinePanelSamples.count)项)匹配=\(c31Mismatches.isEmpty)，书架选中与滚动不变=\(shelfStateKept)，新开面板Menlo=\(reopenedInfoOK)，叠加层不变=\(overlaysUnchangedInC31)，菜单不变=\(menusUnchangedInC31)\(c31Mismatches.isEmpty ? "" : "；差异：" + c31Mismatches.prefix(5).joined(separator: "; "))"
            )

            // MARK: C3.2 fonts.overlays = {family: "Menlo", size: 16}
            let panelSnapshotBeforeC32 = baselinePanelSamples.compactMap { s -> (String, NSFont)? in
                s.readCurrent().map { (s.label, $0) }
            }
            let menuFontBeforeC32 = viewSubmenu()?.font
            let sortFontBeforeC32 = sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font

            // 切到瀑布流以激活 ContinuousViewer 的页码标签，再验证 HUD、状态栏、页码标签、多键提示。
            controller.session.update { $0.browseMode = .waterfall }
            _ = await waitUntil(timeoutMs: 2500) { !controller.viewer.continuous.canvas.items.isEmpty }
            await settle(120)
            let continuousOverlaySamples = collectPanelFontSamples(in: controller.viewer.continuous, prefix: "continuous")

            try await services.settings.updateGlobal {
                $0.appearance.fonts[.overlays] = FontSpec(family: "Menlo", size: 16)
            }
            _ = await waitUntil(timeoutMs: 1500) { Theme.fonts[.overlays]?.family == "Menlo" }
            await settle(150)

            var c32Mismatches: [String] = []
            for sample in baselineOverlaySamples + continuousOverlaySamples {
                guard let current = sample.readCurrent() else { continue }
                let expectedSize = (sample.font.pointSize * (16.0 / 12.0) * 2).rounded() / 2
                if current.familyName != "Menlo" || abs(current.pointSize - expectedSize) > 0.5 {
                    c32Mismatches.append("\(sample.label): got \(current.familyName ?? "nil") \(current.pointSize), want Menlo \(expectedSize)")
                }
            }
            let panelsUnchangedInC32 = zip(panelSnapshotBeforeC32, baselinePanelSamples.compactMap { $0.readCurrent() }).allSatisfy { $0.0.1 == $0.1 }
            let menusUnchangedInC32 = viewSubmenu()?.font == menuFontBeforeC32
                && (sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font) == sortFontBeforeC32

            log.check(
                !continuousOverlaySamples.isEmpty && c32Mismatches.isEmpty && panelsUnchangedInC32 && menusUnchangedInC32,
                "C3.2 fonts.overlays=Menlo 16：HUD/状态栏/多键提示/页码标签(\(baselineOverlaySamples.count + continuousOverlaySamples.count)项)匹配=\(c32Mismatches.isEmpty)，面板不变=\(panelsUnchangedInC32)，菜单不变=\(menusUnchangedInC32)\(c32Mismatches.isEmpty ? "" : "；差异：" + c32Mismatches.prefix(5).joined(separator: "; "))"
            )

            // MARK: C3.3 fonts.menus = {family: "Menlo", size: 18}
            let panelSnapshotBeforeC33 = baselinePanelSamples.compactMap { $0.readCurrent() }
            let overlaySnapshotBeforeC33 = baselineOverlaySamples.compactMap { $0.readCurrent() }

            try await services.settings.updateGlobal {
                $0.appearance.fonts[.menus] = FontSpec(family: "Menlo", size: 18)
            }
            _ = await waitUntil(timeoutMs: 1500) { Theme.fonts[.menus]?.family == "Menlo" }
            await settle(150)

            let viewMenuFontsAfter = collectMenuFonts(under: viewSubmenu())
            let viewMenuOK = !viewMenuFontsAfter.isEmpty && viewMenuFontsAfter.allSatisfy { font in
                font?.familyName == "Menlo" && abs((font?.pointSize ?? 0) - 18) <= 0.5
            }
            let contextMenuAfter = buildViewerContextMenu(controller: controller)
            let contextMenuFonts = collectMenuFonts(under: contextMenuAfter)
            let contextMenuOK = !contextMenuFonts.isEmpty && contextMenuFonts.allSatisfy { font in
                font?.familyName == "Menlo" && abs((font?.pointSize ?? 0) - 18) <= 0.5
            }
            let sortFontAfter = sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font
            let sortButtonOK = sortFontAfter?.familyName == "Menlo" && abs((sortFontAfter?.pointSize ?? 0) - 18) <= 0.5
            let searchPopups = [bookshelf.searchBar.ratingButton, bookshelf.searchBar.tagsButton, bookshelf.searchBar.kindButton]
            let searchPopupsOK = searchPopups.allSatisfy { popup in
                popup.font?.familyName == "Menlo" && abs((popup.font?.pointSize ?? 0) - 18) <= 0.5
            }
            let panelsUnchangedInC33 = zip(panelSnapshotBeforeC33, baselinePanelSamples.compactMap { $0.readCurrent() }).allSatisfy(==)
            let overlaysUnchangedInC33 = zip(overlaySnapshotBeforeC33, baselineOverlaySamples.compactMap { $0.readCurrent() }).allSatisfy(==)

            log.check(
                viewMenuOK && contextMenuOK && sortButtonOK && searchPopupsOK && panelsUnchangedInC33 && overlaysUnchangedInC33,
                "C3.3 fonts.menus=Menlo 18：主菜单显示及下级(\(viewMenuFontsAfter.count)个)=\(viewMenuOK)，右键菜单=\(contextMenuOK)，书架排序按钮=\(sortButtonOK)，搜索下拉=\(searchPopupsOK)，面板不变=\(panelsUnchangedInC33)，叠加层不变=\(overlaysUnchangedInC33)"
            )

            // MARK: C3.4 不存在字体族回退系统字体 + 删除 fonts 恢复启动基线
            let bogus = "NonExistentFontFamily_MacView_Test"
            try await services.settings.updateGlobal {
                $0.appearance.fonts = [
                    .panels: FontSpec(family: bogus, size: 12),
                    .overlays: FontSpec(family: bogus, size: 12),
                    .menus: FontSpec(family: bogus, size: nil),
                ]
            }
            _ = await waitUntil(timeoutMs: 1500) { Theme.fonts[.panels]?.family == bogus }
            await settle(150)

            let sysFamily = NSFont.systemFont(ofSize: 12).familyName
            let menuSysFamily = NSFont.menuFont(ofSize: 0).familyName
            let fallbackPanelsOK = Theme.font(.panels, size: 12).familyName == sysFamily
            let fallbackOverlaysOK = Theme.font(.overlays, size: 12).familyName == sysFamily
            let fallbackMenusOK = Theme.font(.menus, size: Theme.defaultSize(.menus)).familyName == menuSysFamily
                && viewSubmenu()?.font?.familyName == menuSysFamily

            try await services.settings.updateGlobal {
                $0.appearance.fonts = [:]
            }
            _ = await waitUntil(timeoutMs: 1500) { Theme.fonts.isEmpty }
            await settle(150)

            var c34PanelMismatches: [String] = []
            var c34CheckedLivePanels = 0
            for sample in baselinePanelSamples {
                guard let current = sample.readCurrent() else { continue }
                c34CheckedLivePanels += 1
                if current != sample.font {
                    c34PanelMismatches.append("\(sample.label): got \(current.fontName) \(current.pointSize), want \(sample.font.fontName) \(sample.font.pointSize)")
                }
            }
            let panelsRestored = c34CheckedLivePanels > 0 && c34PanelMismatches.isEmpty
            let overlaysRestored = baselineOverlaySamples.allSatisfy { $0.readCurrent() == $0.font }
            let nestedRestored = collectMenuFonts(under: viewSubmenu()) == baselineNestedMenuFonts
            let contextRestored = buildViewerContextMenu(controller: controller)?.font == baselineContextMenuFont
            let sortRestored = (sortButton?.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? sortButton?.font) == baselineSortButtonFont

            log.check(
                fallbackPanelsOK && fallbackOverlaysOK && fallbackMenusOK && panelsRestored && overlaysRestored && nestedRestored && contextRestored && sortRestored,
                "C3.4 未知字体回退(panels=\(fallbackPanelsOK), overlays=\(fallbackOverlaysOK), menus=\(fallbackMenusOK))；删 fonts 恢复启动基线(panels=\(panelsRestored)[\(c34CheckedLivePanels)项], overlays=\(overlaysRestored), mainMenu=\(nestedRestored), context=\(contextRestored), sort=\(sortRestored))\(c34PanelMismatches.isEmpty ? "" : "；差异：" + c34PanelMismatches.prefix(5).joined(separator: "; "))"
            )
        } catch {
            log.check(false, "fonts 自检异常：\(error)")
        }
    }

    private func isSerifFont(_ font: NSFont) -> Bool {
        let name = (font.familyName ?? "") + " " + font.fontName
        return name.localizedCaseInsensitiveContains("New York")
            || name.localizedCaseInsensitiveContains("Serif")
            || name.localizedCaseInsensitiveContains("Song")
    }

    private func collectPanelFontSamples(in root: NSView, prefix: String) -> [TextFontSample] {
        var result: [TextFontSample] = []
        func walk(_ view: NSView) {
            if view is NSPopUpButton { return }
            if view.identifier?.rawValue == "collection.sortButton" { return }
            if let field = view as? NSTextField {
                let attrFont = field.attributedStringValue.length > 0
                    ? field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    : nil
                if let font = attrFont ?? field.font, !isSerifFont(font) {
                    let hasAttr = attrFont != nil && field.attributedStringValue.length > 0
                    result.append(TextFontSample(
                        label: "\(prefix).\(type(of: field))(\(field.stringValue.prefix(12)))",
                        font: font,
                        readCurrent: { [weak field] in
                            guard let field else { return nil }
                            if hasAttr, field.attributedStringValue.length > 0,
                               let f = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                                return f
                            }
                            return field.font
                        }
                    ))
                }
            } else if let button = view as? NSButton {
                let isImageOnly = button.imagePosition == .imageOnly
                    || (button.image != nil && (button.title == "Button" || button.title == "按钮" || button.title.isEmpty))
                let hasText = !isImageOnly && (!button.title.isEmpty || button.attributedTitle.length > 0)
                if hasText {
                    let attrFont = button.attributedTitle.length > 0
                        ? button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                        : nil
                    if let font = attrFont ?? button.font, !isSerifFont(font) {
                        let hasAttr = attrFont != nil && button.attributedTitle.length > 0
                        result.append(TextFontSample(
                            label: "\(prefix).\(type(of: button))(\(button.title.prefix(12)))",
                            font: font,
                            readCurrent: { [weak button] in
                                guard let button else { return nil }
                                if hasAttr, button.attributedTitle.length > 0,
                                   let f = button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                                    return f
                                }
                                return button.font
                            }
                        ))
                    }
                }
                return
            }
            if let layer = view.layer {
                walkLayers(layer, prefix: prefix, into: &result)
            }
            for sub in view.subviews {
                walk(sub)
            }
        }
        walk(root)
        return result
    }

    private func walkLayers(_ layer: CALayer, prefix: String, into result: inout [TextFontSample]) {
        if let textLayer = layer as? CATextLayer, let font = textLayer.font as? NSFont {
            let sized = NSFont(descriptor: font.fontDescriptor, size: textLayer.fontSize) ?? font
            result.append(TextFontSample(
                label: "\(prefix).CATextLayer(\(textLayer.name ?? ""))",
                font: sized,
                readCurrent: { [weak textLayer] in
                    guard let textLayer, let f = textLayer.font as? NSFont else { return nil }
                    return NSFont(descriptor: f.fontDescriptor, size: textLayer.fontSize) ?? f
                }
            ))
        }
        for sub in layer.sublayers ?? [] {
            walkLayers(sub, prefix: prefix, into: &result)
        }
    }

    private func collectOverlayFontSamples(controller: ReaderWindowController) -> [TextFontSample] {
        var result: [TextFontSample] = []
        result.append(contentsOf: collectPanelFontSamples(in: controller.viewer.hud, prefix: "hud"))
        result.append(contentsOf: collectPanelFontSamples(in: controller.content.statusBar, prefix: "statusBar"))
        result.append(contentsOf: collectPanelFontSamples(in: controller.pendingView, prefix: "pending"))
        return result
    }

    private func collectCanvasBadgeFonts(in canvas: CanvasView) -> [NSFont] {
        var fonts: [NSFont] = []
        func walk(_ layer: CALayer) {
            if let textLayer = layer as? CATextLayer, textLayer.name == "badge", let font = textLayer.font as? NSFont {
                fonts.append(NSFont(descriptor: font.fontDescriptor, size: textLayer.fontSize) ?? font)
            }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        if let docLayer = canvas.documentView?.layer { walk(docLayer) }
        return fonts
    }

    private func viewSubmenu() -> NSMenu? {
        guard let mainMenu = NSApp.mainMenu else { return nil }
        return mainMenu.items.first { $0.title == String(localized: "显示") || $0.title == "显示" || $0.title == "View" }?.submenu
    }

    private func collectMenuFonts(under menu: NSMenu?) -> [NSFont?] {
        guard let menu else { return [] }
        var out: [NSFont?] = [menu.font]
        for item in menu.items {
            if let sub = item.submenu {
                out.append(contentsOf: collectMenuFonts(under: sub))
            }
        }
        return out
    }

    private func buildViewerContextMenu(controller: ReaderWindowController) -> NSMenu? {
        guard let builder = app.menuBuilder, let provider = app.contextMenuProvider else { return nil }
        let entries = controller.session.book?.pages.prefix(1).map(\.entry) ?? []
        return builder.contextMenu(
            nodes: app.catalog.viewerContextMenu,
            provider: provider,
            target: ContextMenuTarget(window: controller, entries: Array(entries))
        )
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for sub in root.subviews {
            if let found = findView(in: sub, identifier: identifier) { return found }
        }
        return nil
    }
}

private extension EdgeColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Rec. 709 相对亮度（0...1）。
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
#endif
