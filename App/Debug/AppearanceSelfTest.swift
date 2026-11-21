#if DEBUG
import AppKit
import CoreGraphics
import ImageIO
import MVCommands
import MVFoundation
import MVLayout
import MVReading
import MVServices
import MVSettings
import UniformTypeIdentifiers

/// 外观与窗口外观自检（`-MVAppearanceSelfTest chrome`）。
///
/// 覆盖 W2.1 检查项 C2.1–C2.7（含 C2.5b）。
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
        default:
            log.check(false, "未知的 -MVAppearanceSelfTest 模式：\(mode)")
        }
        try? FileManager.default.removeItem(at: temporary)
        await app.services?.shutdown()
        exit(log.summarize())
    }

    // MARK: chrome 自检（C2.1–C2.7）

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

    // MARK: 辅助方法

    private func makeTestBooks() throws -> (book1: URL, book2: URL) {
        let root = temporary.appending(path: "books", directoryHint: .isDirectory)
        let book1 = root.appending(path: "Book1", directoryHint: .isDirectory)
        let book2 = root.appending(path: "Book2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: book1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book2, withIntermediateDirectories: true)
        try writeSolidPNG(to: book1.appending(path: "01.png"), r: 235, g: 55, b: 40)
        try writeSolidPNG(to: book2.appending(path: "01.png"), r: 40, g: 140, b: 235)
        return (book1, book2)
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
}
#endif
