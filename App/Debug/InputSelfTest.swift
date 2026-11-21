#if DEBUG
import AppKit
import Carbon.HIToolbox
import MVCommands
import MVFoundation
import MVLayout
import MVReading
import MVSettings

/// 查看器输入与自定义自检（`-MVInputSelfTest viewer`）。
///
/// 覆盖 C2.1（右键手势与右键菜单共存）、C2.2（点击区域、滚轮分派、自定义滚轮绑定与原有滚轮行为）、C2.3（`menus.json` 驱动主菜单、右键菜单热重载与损坏文件提示）与 C2.4（模型驱动工具栏与命名布局方案）。
@MainActor
final class InputSelfTest {
    static let launchKey = "MVInputSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary = TestPresentation.scratchDirectory("input")
    private var eventNumber = 1

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return }
        let test = InputSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        guard app.services != nil, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "输入自检需要真实服务与主窗口")
            exit(log.summarize())
        }
        TestPresentation.place(window)
        window.orderFrontRegardless()
        switch mode {
        case "viewer":
            await runViewerSuite(controller: controller, window: window)
        case "settings":
            await runSettingsSuite(controller: controller, window: window)
        default:
            log.check(false, "未知的 -MVInputSelfTest 模式：\(mode)")
            exit(log.summarize())
        }
        try? FileManager.default.removeItem(at: temporary)
        await app.services?.shutdown()
        exit(log.summarize())
    }

    // MARK: C2.1 查看器右键手势与右键菜单共存

    private func runViewerSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            window.setContentSize(NSSize(width: 1100, height: 760))
            let book = try makeBook(count: 6)
            await openBook(controller, url: book, expectedCount: 6)
            window.makeFirstResponder(controller.viewer)
            controller.session.update {
                $0.browseMode = .paged
                $0.pageMode = .single
                $0.direction = .leftToRight
                $0.scaleMode = .fitWindow
            }
            await settle()

            try await checkRightGestureTurnPage(controller, window: window)
            await checkRightClickContextMenu(controller, window: window)
            await checkRightGestureCancelWithEscape(controller, window: window)
            await checkLeftDragPanAndDragOut(controller, window: window)
            await checkContinuousModeRightGestureAndMenu(controller, window: window)
            await checkClickZonesAndDragExclusion(controller, window: window)
            try await checkWheelDispatchAndCustomBinding(controller, window: window)
            try await checkMenusCustomizationAndReload(controller, window: window)
            try await checkToolbarAndLayoutSchemes(controller, window: window)
        } catch {
            log.check(false, "输入自检异常：\(error)")
        }
    }

    private func checkRightGestureTurnPage(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)

        // 左开模式下，先翻到第 2 帧（index 1），向右拖再向左拖验证 frame.left 换算为上一帧。
        controller.session.go(.index(1))
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.1 初始位于第 2 帧：\(controller.session.currentFrame)")

        let stepsLeft = [
            NSPoint(x: center.x - 15, y: center.y),
            NSPoint(x: center.x - 40, y: center.y),
            NSPoint(x: center.x - 75, y: center.y),
        ]
        sendMouse(.rightMouseDown, at: center, in: window)
        for point in stepsLeft {
            sendMouse(.rightMouseDragged, at: point, in: window)
        }
        log.check(!viewer.gestureTrailView.isHidden, "C2.1 右键向左拖动超过阈值后显示轨迹浮层")
        log.check(viewer.gestureTrailView.displayedDirections == [.left], "C2.1 轨迹浮层方向序列为 ←：\(viewer.gestureTrailView.displayedDirections)")
        log.check(
            viewer.gestureTrailView.displayedCommandTitle == app.catalog.title(of: .frameLeft),
            "C2.1 轨迹浮层显示命令标题“\(viewer.gestureTrailView.displayedCommandTitle ?? "nil")”"
        )
        sendMouse(.rightMouseUp, at: stepsLeft.last!, in: window)
        await settle()
        log.check(viewer.gestureTrailView.isHidden, "C2.1 松开右键后隐藏轨迹浮层")
        log.check(controller.session.currentFrame == 0, "C2.1 左开模式下 ← 手势执行 frame.left 翻回第 1 帧：\(controller.session.currentFrame)")

        // 右开模式下，从第 1 帧向左拖（←）执行 frame.left 应翻到下一帧（index 1）。
        controller.session.update { $0.direction = .rightToLeft }
        await settle()
        sendRightDrag(from: center, to: NSPoint(x: center.x - 80, y: center.y), in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.1 右开模式下 ← 手势执行 frame.left 翻到下一帧：\(controller.session.currentFrame)")

        controller.session.update { $0.direction = .leftToRight }
        await settle()
    }

    private func checkRightClickContextMenu(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)
        var presentedMenu: NSMenu?
        viewer.gestureRecognizer.onPresentContextMenu = { menu, _, _ in
            presentedMenu = menu
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        let beforeFrame = controller.session.currentFrame
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseUp, at: center, in: window)
        await settle()

        let titles = presentedMenu?.items.map(\.title) ?? []
        log.check(presentedMenu != nil, "C2.1 右键原地松开触发查看器右键菜单")
        log.check(
            titles.contains(String(localized: "复制")) && titles.contains(String(localized: "在 Finder 中显示")),
            "C2.1 右键菜单包含预期视图条目：\(titles.filter { !$0.isEmpty }.joined(separator: "、"))"
        )
        log.check(controller.session.currentFrame == beforeFrame, "C2.1 右键原地松开不触发翻页")
    }

    private func checkRightGestureCancelWithEscape(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)
        controller.session.go(.index(2))
        await settle()
        let beforeFrame = controller.session.currentFrame

        var presentedMenu = false
        viewer.gestureRecognizer.onPresentContextMenu = { _, _, _ in
            presentedMenu = true
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        let dragged = NSPoint(x: center.x - 80, y: center.y)
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseDragged, at: NSPoint(x: center.x - 40, y: center.y), in: window)
        sendMouse(.rightMouseDragged, at: dragged, in: window)
        log.check(!viewer.gestureTrailView.isHidden, "C2.1 Esc 取消前轨迹浮层已显示")

        sendEscapeKey(in: window)
        log.check(viewer.gestureTrailView.isHidden, "C2.1 按 Esc 后立即隐藏轨迹浮层")

        sendMouse(.rightMouseUp, at: dragged, in: window)
        await settle()

        log.check(controller.session.currentFrame == beforeFrame, "C2.1 Esc 取消后不执行翻页命令：\(controller.session.currentFrame)")
        log.check(!presentedMenu, "C2.1 Esc 取消后不弹出右键菜单")
    }

    private func checkLeftDragPanAndDragOut(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let paged = viewer.paged
        let center = windowCenter(of: paged)

        // 1. 放大后左键拖动平移。
        paged.zoom(by: 4.0)
        await settle()
        let beforeOffset = paged.transform.offset
        let dragID = nextEventNumber()
        sendMouse(.leftMouseDown, at: center, in: window, eventNumber: dragID)
        sendMouse(.leftMouseDragged, at: NSPoint(x: center.x + 60, y: center.y + 40), in: window, eventNumber: dragID)
        sendMouse(.leftMouseUp, at: NSPoint(x: center.x + 60, y: center.y + 40), in: window, eventNumber: dragID)
        await settle()
        log.check(paged.transform.offset != beforeOffset, "C2.1 左键拖动平移保持正常：\(beforeOffset) → \(paged.transform.offset)")
        log.check(viewer.gestureTrailView.isHidden, "C2.1 左键拖动不显示右键手势浮层")

        // 2. 适合窗口时左键拖出入口保持正常（命中页且可生成拖出粘贴板写入器）。
        paged.resetTransform()
        await settle()
        let pagePoint = paged.convert(center, from: nil)
        let hitPage = paged.page(at: pagePoint)
        let hasWriter: Bool = if let hitPage, let pages = controller.session.book?.pages, pages.indices.contains(hitPage) {
            app.fileOps?.pasteboardWriter(for: pages[hitPage].entry, in: controller) != nil
        } else {
            false
        }
        log.check(hitPage != nil && hasWriter, "C2.1 适合窗口下左键拖出入口保持正常（页 \(hitPage.map(String.init) ?? "nil")）")
    }

    private func checkContinuousModeRightGestureAndMenu(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        controller.session.update {
            $0.browseMode = .verticalStrip
            $0.direction = .leftToRight
        }
        await settle()
        controller.session.go(.index(2))
        await settle()

        let center = windowCenter(of: viewer.continuous.canvas)
        var presentedMenu: NSMenu?
        viewer.gestureRecognizer.onPresentContextMenu = { menu, _, _ in
            presentedMenu = menu
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        // 连续模式右键原地松开弹菜单。
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseUp, at: center, in: window)
        await settle()
        log.check(presentedMenu != nil, "C2.1 连续模式下右键原地松开触发右键菜单")

        // 连续模式右键向左拖动执行 frame.left。
        let beforeFrame = controller.session.currentFrame
        sendRightDrag(from: center, to: NSPoint(x: center.x - 80, y: center.y), in: window)
        await settle()
        log.check(controller.session.currentFrame == max(0, beforeFrame - 1), "C2.1 连续模式下 ← 手势执行 frame.left：\(beforeFrame) → \(controller.session.currentFrame)")

        controller.session.update { $0.browseMode = .paged }
        await settle()
    }

    // MARK: C2.2 点击区域、滚轮分派与自定义滚轮绑定

    private func checkClickZonesAndDragExclusion(_ controller: ReaderWindowController, window: NSWindow) async {
        let paged = controller.viewer.paged
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.scaleMode = .fitWindow
        }
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()

        let leftPoint = windowPoint(in: paged, xFraction: 1.0 / 6.0, yFraction: 0.5)
        let centerPoint = windowPoint(in: paged, xFraction: 0.5, yFraction: 0.5)
        let rightPoint = windowPoint(in: paged, xFraction: 5.0 / 6.0, yFraction: 0.5)

        // 1. 从左往右：单击右区域翻下一帧，单击左区域翻上一帧。
        sendLeftClick(at: rightPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 左开模式单击右区域翻到下一帧：\(controller.session.currentFrame)")

        sendLeftClick(at: leftPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 左开模式单击左区域翻到上一帧：\(controller.session.currentFrame)")

        // 2. 单击中间区域（默认未绑定）无动作。
        sendLeftClick(at: centerPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 单击中间区域（默认未绑定）不翻页：\(controller.session.currentFrame)")

        // 3. 从右往左：单击左区域翻下一帧，单击右区域翻上一帧。
        controller.session.update { $0.direction = .rightToLeft }
        await settle()
        sendLeftClick(at: leftPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 右开模式单击左区域翻到下一帧：\(controller.session.currentFrame)")

        sendLeftClick(at: rightPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 右开模式单击右区域翻到上一帧：\(controller.session.currentFrame)")

        controller.session.update { $0.direction = .leftToRight }
        await settle()

        // 4. 放大后在右区域拖动平移（位移 >= 4 pt），应平移且不触发点击区域翻页。
        paged.zoom(by: 4.0)
        await settle()
        let beforeFrame = controller.session.currentFrame
        let beforeOffset = paged.transform.offset
        let dragID = nextEventNumber()
        let dragEnd = NSPoint(x: rightPoint.x - 24, y: rightPoint.y + 12)
        sendMouse(.leftMouseDown, at: rightPoint, in: window, eventNumber: dragID)
        sendMouse(.leftMouseDragged, at: dragEnd, in: window, eventNumber: dragID)
        sendMouse(.leftMouseUp, at: dragEnd, in: window, eventNumber: dragID)
        await settle()
        log.check(paged.transform.offset != beforeOffset, "C2.2 放大后拖动平移生效：\(beforeOffset) → \(paged.transform.offset)")
        log.check(controller.session.currentFrame == beforeFrame, "C2.2 位移 >= 4 pt 的拖动平移不触发点击区域：\(controller.session.currentFrame)")

        paged.resetTransform()
        await settle()
    }

    private func checkWheelDispatchAndCustomBinding(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let paged = controller.viewer.paged
        let center = windowCenter(of: paged)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.scaleMode = .fitWindow
        }
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()

        // 1. ⌘ + 滚轮触发缩放，且不翻页。
        let zoomBefore = paged.transform.zoom
        let frameBeforeZoom = controller.session.currentFrame
        sendMouseWheel(at: center, in: window, deltaY: 4, modifiers: .maskCommand)
        await settle()
        log.check(paged.transform.zoom > zoomBefore, "C2.2 ⌘ + 滚轮向上触发放大：\(zoomBefore) → \(paged.transform.zoom)")
        log.check(controller.session.currentFrame == frameBeforeZoom, "C2.2 ⌘ + 滚轮缩放不触发翻页：\(controller.session.currentFrame)")

        let zoomedLevel = paged.transform.zoom
        sendMouseWheel(at: center, in: window, deltaY: -2, modifiers: .maskCommand)
        await settle()
        log.check(paged.transform.zoom < zoomedLevel, "C2.2 ⌘ + 滚轮向下触发缩小：\(zoomedLevel) → \(paged.transform.zoom)")

        // 2. 临时写入 keybindings.json 绑定 ⌥ + 滚轮到命令，验证执行后恢复。
        let url = app.supportDirectory.appending(path: "keybindings.json")
        let previousData = try? Data(contentsOf: url)
        let optionWheel = WheelBinding(
            device: .mouse,
            modifiers: .option,
            action: .commands(up: .framePrevious, down: .frameNext)
        )
        let customFile = KeyBindingsFile(bindings: [], wheel: [optionWheel])
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(customFile))
        let encoded = try JSONSerialization.data(withJSONObject: ["version": 1, "value": value])

        do {
            try encoded.write(to: url, options: .atomic)
            for _ in 0..<100 where app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) != optionWheel.action {
                try? await Task.sleep(for: .milliseconds(20))
            }
            log.check(
                app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) == optionWheel.action,
                "C2.2 临时写入 keybindings.json 生效 ⌥ + 滚轮命令绑定"
            )

            // 在放大状态下发 ⌥ + 滚轮向下，确认直接执行 frame.next 而非平移。
            paged.zoom(by: 3.0)
            await settle()
            let frameBeforeOption = controller.session.currentFrame
            sendMouseWheel(at: center, in: window, deltaY: -1, modifiers: .maskAlternate)
            await settle()
            log.check(
                controller.session.currentFrame == frameBeforeOption + 1,
                "C2.2 ⌥ + 滚轮向下执行自定义命令 frame.next：\(frameBeforeOption) → \(controller.session.currentFrame)"
            )

            sendMouseWheel(at: center, in: window, deltaY: 1, modifiers: .maskAlternate)
            await settle()
            log.check(
                controller.session.currentFrame == frameBeforeOption,
                "C2.2 ⌥ + 滚轮向上执行自定义命令 frame.previous：\(controller.session.currentFrame)"
            )
        } catch {
            restoreKeyBindings(at: url, previousData: previousData)
            throw error
        }

        restoreKeyBindings(at: url, previousData: previousData)
        for _ in 0..<100 where app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) != .standard {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(
            app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) == .standard,
            "C2.2 恢复 keybindings.json 后 ⌥ + 滚轮回到默认行为"
        )

        // 3. 未改绑定时滚轮翻页与平移和改动前一致。
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()
        sendMouseWheel(at: center, in: window, deltaY: -1)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 未改绑定适合窗口下鼠标滚轮向下翻到下一帧：\(controller.session.currentFrame)")

        sendMouseWheel(at: center, in: window, deltaY: 1)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 未改绑定适合窗口下鼠标滚轮向上翻到上一帧：\(controller.session.currentFrame)")

        paged.zoom(by: 4.0)
        await settle()
        let panFrameBefore = controller.session.currentFrame
        let panOffsetBefore = paged.transform.offset
        sendMouseWheel(at: center, in: window, deltaY: -2)
        await settle()
        log.check(paged.transform.offset != panOffsetBefore, "C2.2 未改绑定放大后鼠标滚轮平移：\(panOffsetBefore) → \(paged.transform.offset)")
        log.check(controller.session.currentFrame == panFrameBefore, "C2.2 未改绑定放大后鼠标滚轮平移不翻页：\(controller.session.currentFrame)")

        paged.resetTransform()
        await settle()
    }

    private func restoreKeyBindings(at url: URL, previousData: Data?) {
        if let previousData {
            try? previousData.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: C2.3 menus.json 驱动主菜单、查看器右键菜单与损坏提示

    private func checkMenusCustomizationAndReload(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let paged = controller.viewer.paged
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.scaleMode = .fitWindow
        }
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()

        let menusURL = app.supportDirectory.appending(path: "menus.json")
        let previousData = try? Data(contentsOf: menusURL)
        defer { restoreKeyBindings(at: menusURL, previousData: previousData) }

        if previousData != nil {
            try? FileManager.default.removeItem(at: menusURL)
            for _ in 0..<100 where app.catalog.viewerContextMenu != CoreCommands.defaultViewerContextMenu {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        // 1. 无 menus.json 时，主菜单顶层与子菜单条目、以及查看器右键菜单逐项与改动前一致。
        let topTitles = NSApp.mainMenu?.items.map(\.title) ?? []
        let expectedTopTitles = [
            ProcessInfo.processInfo.processName,
            String(localized: "文件"),
            String(localized: "编辑"),
            String(localized: "显示"),
            String(localized: "图像"),
            String(localized: "翻页"),
            String(localized: "书"),
            String(localized: "调试"),
            String(localized: "窗口"),
        ]
        log.check(topTitles == expectedTopTitles, "C2.3 无 menus.json 时主菜单顶层顺序一致：\(topTitles.joined(separator: "、"))")

        let fileSubmenuTitles = menuTitles(of: NSApp.mainMenu?.item(withTitle: String(localized: "文件"))?.submenu)
        let expectedFileTitles = [
            String(localized: "打开文件夹或压缩包…"), "-",
            String(localized: "复制"), String(localized: "复制路径"), String(localized: "在 Finder 中显示"), String(localized: "用指定应用打开"), "-",
            String(localized: "移动到"), String(localized: "复制到"), String(localized: "重命名…"), String(localized: "删除"), "-",
            String(localized: "为此文件夹建立索引"), String(localized: "清空回收目录…"), "-",
            String(localized: "新建窗口"), String(localized: "新建标签页"), "-",
            String(localized: "重试失败的项"), String(localized: "设置…"), "-",
            String(localized: "关闭"),
        ]
        log.check(fileSubmenuTitles == expectedFileTitles, "C2.3 无 menus.json 时“文件”子菜单条目与顺序一致")

        let imageSubmenu = NSApp.mainMenu?.item(withTitle: String(localized: "图像"))?.submenu
        let imageSubmenuTitles = menuTitles(of: imageSubmenu)
        log.check(
            imageSubmenuTitles == [String(localized: "评分"), String(localized: "编辑标签…")],
            "C2.3 无 menus.json 时“图像”子菜单条目与顺序一致：\(imageSubmenuTitles.joined(separator: "、"))"
        )

        let viewSubmenu = NSApp.mainMenu?.item(withTitle: String(localized: "显示"))?.submenu
        log.check(
            viewSubmenu?.item(withTitle: String(localized: "套用显示配置"))?.submenu != nil,
            "C2.3 无 menus.json 时“显示”子菜单包含“套用显示配置”动态子菜单"
        )

        let windowSubmenuTitles = menuTitles(of: NSApp.mainMenu?.item(withTitle: String(localized: "窗口"))?.submenu)
        let expectedWindowTitles = [
            String(localized: "最小化"), String(localized: "缩放"), "-",
            String(localized: "切换全屏幕"), "-",
            String(localized: "保存为布局方案…"), String(localized: "布局方案"), "-",
            String(localized: "前置全部窗口"),
        ]
        log.check(
            Array(windowSubmenuTitles.prefix(expectedWindowTitles.count)) == expectedWindowTitles,
            "C2.3 无 menus.json 时“窗口”子菜单条目与顺序一致：\(windowSubmenuTitles.joined(separator: "、"))"
        )

        let defaultContextMenu = await presentViewerContextMenu(controller, window: window)
        let defaultContextTitles = menuTitles(of: defaultContextMenu)
        let expectedDefaultContextTitles = [
            String(localized: "加到播放列表"), "-",
            String(localized: "评分"), String(localized: "编辑标签…"), "-",
            String(localized: "复制"), String(localized: "复制路径"), String(localized: "在 Finder 中显示"), String(localized: "用指定应用打开"), "-",
            String(localized: "移动到"), String(localized: "复制到"), String(localized: "重命名…"), String(localized: "移到废纸篓"),
        ]
        log.check(
            defaultContextTitles == expectedDefaultContextTitles,
            "C2.3 无 menus.json 时查看器右键菜单条目与顺序逐项一致：\(defaultContextTitles.joined(separator: "、"))"
        )

        // 2. 写入改过的 menus.json：修改查看器右键菜单树（增删、调序、含通用命令），验证自动重载与通用命令携带点中项执行。
        let customCommandID = CommandID("selftest.context.selection")
        var capturedSelection: [Location] = []
        app.services?.commands.register(
            CommandDescriptor(id: customCommandID, title: "自检点中项命令", category: "selftest"),
            isEnabled: { context in !context.selection.isEmpty }
        ) { context, _ in
            capturedSelection = context.selection
        }

        let customViewerMenu: [MenuNode] = [
            .command(.fileCopyPath),
            .command(customCommandID),
            .separator,
            .command(.frameNext),
            .dynamic(.rating),
            .command(.fileReveal),
        ]
        let customMenuFile = MenuFile(viewerContextMenu: customViewerMenu)
        let encodedValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(customMenuFile))
        let encodedDoc = try JSONSerialization.data(withJSONObject: ["version": 1, "value": encodedValue])
        try encodedDoc.write(to: menusURL, options: .atomic)

        for _ in 0..<100 where app.catalog.viewerContextMenu != customViewerMenu {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(app.catalog.viewerContextMenu == customViewerMenu, "C2.3 写入自定义 menus.json 后自动重载生效")

        let expectedEntry = controller.session.book?.pages[controller.session.currentPage].entry
        let customContextMenu = await presentViewerContextMenu(controller, window: window)
        let customContextTitles = menuTitles(of: customContextMenu)
        let expectedCustomTitles = [
            String(localized: "复制路径"),
            customCommandID.rawValue,
            "-",
            app.catalog.title(of: .frameNext),
            String(localized: "评分"),
            String(localized: "在 Finder 中显示"),
        ]
        log.check(
            customContextTitles == expectedCustomTitles,
            "C2.3 自定义查看器右键菜单条目与顺序生效：\(customContextTitles.joined(separator: "、"))"
        )

        if let genericItem = customContextMenu?.item(withTitle: customCommandID.rawValue),
           let action = genericItem.action {
            log.check(genericItem.isEnabled, "C2.3 通用命令菜单项可用")
            NSApp.sendAction(action, to: genericItem.target, from: genericItem)
            for _ in 0..<50 where capturedSelection.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        log.check(
            expectedEntry != nil && capturedSelection == [expectedEntry!.location],
            "C2.3 点击右键菜单通用命令带上点中项执行：\(capturedSelection.map(\.name).joined(separator: "、"))"
        )

        let beforeFrame = controller.session.currentFrame
        if let nextItem = customContextMenu?.item(withTitle: app.catalog.title(of: .frameNext)),
           let action = nextItem.action {
            NSApp.sendAction(action, to: nextItem.target, from: nextItem)
            await settle()
        }
        log.check(controller.session.currentFrame == beforeFrame + 1, "C2.3 点击右键菜单内置通用命令 frame.next 生效：\(beforeFrame) → \(controller.session.currentFrame)")

        // 3. 写入损坏的 menus.json，验证保留上一份有效配置并显示“文件问题”提示与“打开文件”入口；删除后自动恢复。
        try Data("{ invalid json".utf8).write(to: menusURL, options: .atomic)
        for _ in 0..<100 where !app.fileProblems.contains(where: { $0.file == "menus.json" }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let problem = app.fileProblems.first { $0.file == "menus.json" }
        let banner = controller.content.fileErrorBanners["menus.json"]
        let hasOpenFileButton = banner.map { hasButton(titled: String(localized: "打开文件"), in: $0) } ?? false
        log.check(problem != nil && problem?.url == menusURL, "C2.3 损坏 menus.json 记录文件问题提示")
        log.check(banner != nil && hasOpenFileButton, "C2.3 损坏 menus.json 显示顶部错误横幅及“打开文件”入口")

        let retainedMenu = await presentViewerContextMenu(controller, window: window)
        log.check(
            menuTitles(of: retainedMenu) == expectedCustomTitles,
            "C2.3 menus.json 损坏时保留上一份有效查看器右键菜单配置"
        )

        try? FileManager.default.removeItem(at: menusURL)
        for _ in 0..<100 where app.fileProblems.contains(where: { $0.file == "menus.json" }) || app.catalog.viewerContextMenu != CoreCommands.defaultViewerContextMenu {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(
            !app.fileProblems.contains(where: { $0.file == "menus.json" }) && controller.content.fileErrorBanners["menus.json"] == nil,
            "C2.3 删除损坏 menus.json 后文件问题提示自动消失"
        )
        let recoveredMenu = await presentViewerContextMenu(controller, window: window)
        log.check(
            menuTitles(of: recoveredMenu) == expectedDefaultContextTitles,
            "C2.3 删除损坏 menus.json 后自动恢复默认查看器右键菜单"
        )
    }

    // MARK: C2.4 模型驱动工具栏与命名布局方案

    private func checkToolbarAndLayoutSchemes(_ controller: ReaderWindowController, window: NSWindow) async throws {
        guard let toolbar = window.toolbar, let services = app.services, let dock = app.dock else {
            log.check(false, "C2.4 缺少工具栏、核心服务或停靠协调者")
            return
        }

        // 1. 工具栏：autosavesConfiguration == false、允许列表包含带 symbol 的通用命令、增删写回 menus.json 且保留其他字段、新窗口顺序一致。
        log.check(toolbar.autosavesConfiguration == false, "C2.4 工具栏 autosavesConfiguration 为 false")

        let allowed = controller.toolbarAllowedItemIdentifiers(toolbar)
        let zoomInID = NSToolbarItem.Identifier(CommandID.zoomIn.rawValue)
        log.check(
            allowed.contains(zoomInID) && allowed.contains(.space) && allowed.contains(.flexibleSpace),
            "C2.4 toolbarAllowedItemIdentifiers 包含带 symbol 的通用命令与空格"
        )

        let menusURL = app.supportDirectory.appending(path: "menus.json")
        let previousMenusData = try? Data(contentsOf: menusURL)
        defer { restoreKeyBindings(at: menusURL, previousData: previousMenusData) }

        // 先写入包含自定义 viewerContextMenu 的 menus.json，验证工具栏写回时保留其他字段。
        let preservedContextMenu: [MenuNode] = [.command(.fileCopy), .command(.fileReveal)]
        try await services.menus?.update {
            $0.viewerContextMenu = preservedContextMenu
            $0.toolbar = nil
        }
        for _ in 0..<100 where app.catalog.viewerContextMenu != preservedContextMenu {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // 插入带 symbol 的通用命令 zoom.in，并移除现有条目 effects.toggle。
        toolbar.insertItem(withItemIdentifier: zoomInID, at: 0)
        if let effectsIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == NSToolbarItem.Identifier(CommandID.effectsToggle.rawValue) }) {
            toolbar.removeItem(at: effectsIndex)
        }

        let zoomItem = toolbar.items.first { $0.itemIdentifier == zoomInID }
        log.check(
            zoomItem != nil && zoomItem?.label == app.catalog.title(of: .zoomIn)
                && zoomItem?.toolTip == app.catalog.title(of: .zoomIn) && zoomItem?.image != nil,
            "C2.4 带 symbol 的通用命令生成工具栏按钮（标题、tooltip、图标齐备）"
        )

        let expectedToolbar = ReaderWindowController.toolbarItemIDs(of: toolbar)
        for _ in 0..<100 where services.menus?.value().toolbar != expectedToolbar {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let savedMenus = services.menus?.value()
        log.check(
            savedMenus?.toolbar == expectedToolbar,
            "C2.4 工具栏增删后同步写回 menus.json（共 \(expectedToolbar.count) 项）"
        )
        log.check(
            savedMenus?.viewerContextMenu == preservedContextMenu,
            "C2.4 工具栏写回 menus.json 时保留 viewerContextMenu 等其他字段"
        )

        // 重新打开一个新窗口，验证新窗口工具栏顺序与 menus.json 一致。
        let secondController = app.newWindow()
        await settle()
        let secondToolbarIDs = secondController?.window?.toolbar.map(ReaderWindowController.toolbarItemIDs(of:)) ?? []
        log.check(
            secondToolbarIDs == expectedToolbar,
            "C2.4 新窗口工具栏条目顺序与 menus.json 一致"
        )
        secondController?.window?.close()
        await settle()

        // 2. 布局方案：两种停靠布局分别保存为命名方案，验证持久化、layout.scheme.apply 套用与 layout.json 更新，以及主菜单动态子菜单。
        let schemesURL = dock.schemesFileURL
        let previousSchemesData = try? Data(contentsOf: schemesURL)
        defer { restoreKeyBindings(at: schemesURL, previousData: previousSchemesData) }

        let context = CommandContext(session: controller.session.id, scope: .global)

        // 状态 A：左侧展开、右侧隐藏。
        controller.dock.perform { layout in
            var next = layout
            next.left.isCollapsed = false
            next.right.isCollapsed = true
            return next
        }
        await settle()
        let layoutA = controller.dock.dockLayout
        try await services.commands.perform(.layoutSchemeSave, arguments: ["name": .string("方案A")], context: context)

        // 状态 B：左侧隐藏、右侧展开。
        controller.dock.perform { layout in
            var next = layout
            next.left.isCollapsed = true
            next.right.isCollapsed = false
            return next
        }
        await settle()
        let layoutB = controller.dock.dockLayout
        try await services.commands.perform(.layoutSchemeSave, arguments: ["name": .string("方案B")], context: context)

        let schemesDiskData = try? Data(contentsOf: schemesURL)
        let savedNames = dock.schemes.map(\.name)
        log.check(
            schemesDiskData != nil && savedNames.contains("方案A") && savedNames.contains("方案B"),
            "C2.4 layout-schemes.json 已持久化两个命名方案：\(savedNames.joined(separator: "、"))"
        )

        // 验证主菜单“窗口”下的“布局方案”动态子菜单包含已保存方案。
        let windowSubmenu = NSApp.mainMenu?.item(withTitle: String(localized: "窗口"))?.submenu
        windowSubmenu?.update()
        let schemesSubmenu = windowSubmenu?.item(withTitle: String(localized: "布局方案"))?.submenu
        let schemesMenuTitles = menuTitles(of: schemesSubmenu)
        log.check(
            schemesMenuTitles.contains("方案A") && schemesMenuTitles.contains("方案B"),
            "C2.4 主菜单“窗口 → 布局方案”动态子菜单包含已保存方案：\(schemesMenuTitles.joined(separator: "、"))"
        )

        // 套用“方案A”，验证窗口停靠区状态与 layout.json 同步更新。
        try await services.commands.perform(.layoutSchemeApply, arguments: ["name": .string("方案A")], context: context)
        await settle()
        log.check(
            controller.dock.dockLayout.left.isCollapsed == layoutA.left.isCollapsed
                && controller.dock.dockLayout.right.isCollapsed == layoutA.right.isCollapsed,
            "C2.4 layout.scheme.apply 套用方案A 后窗口停靠区状态一致"
        )

        let persistedLayoutA: DockLayout? = {
            guard let data = try? Data(contentsOf: dock.fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["value"],
                  let valueData = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(DockLayout.self, from: valueData)
        }()
        log.check(
            persistedLayoutA != nil
                && persistedLayoutA?.left.isCollapsed == layoutA.left.isCollapsed
                && persistedLayoutA?.right.isCollapsed == layoutA.right.isCollapsed,
            "C2.4 套用方案A 后 layout.json 已同步持久化"
        )

        // 再套用“方案B”，验证状态可来回切换。
        try await services.commands.perform(.layoutSchemeApply, arguments: ["name": .string("方案B")], context: context)
        await settle()
        log.check(
            controller.dock.dockLayout.left.isCollapsed == layoutB.left.isCollapsed
                && controller.dock.dockLayout.right.isCollapsed == layoutB.right.isCollapsed,
            "C2.4 layout.scheme.apply 套用方案B 后窗口停靠区状态一致"
        )
    }

    // MARK: C3.1 设置窗口 · 快捷键页

    private func runSettingsSuite(controller: ReaderWindowController, window: NSWindow) async {
        let keyBindingsURL = app.supportDirectory.appending(path: "keybindings.json")
        let previousData = try? Data(contentsOf: keyBindingsURL)
        defer { restoreKeyBindings(at: keyBindingsURL, previousData: previousData) }

        guard let settings = app.openSettings(), let settingsWindow = settings.window else {
            log.check(false, "C3.1 打不开设置窗口")
            return
        }
        settings.state.page = .shortcuts
        TestPresentation.place(settingsWindow)
        settingsWindow.makeKeyAndOrderFront(nil)
        await settle()

        let shortcuts = settings.state.model.shortcuts
        log.check(settings.state.page == .shortcuts, "C3.1 设置窗口已切换到快捷键页")
        log.check(
            shortcuts.sections.contains(where: { $0.scope == .viewer }) && shortcuts.sections.contains(where: { $0.scope == .global }),
            "C3.1 快捷键页按作用域分组展示命令（共 \(shortcuts.sections.count) 组）"
        )

        // 搜索过滤验证（按 ID 与按键显示文本）。
        shortcuts.searchText = "page.first"
        log.check(
            shortcuts.sections.flatMap(\.rows).contains(where: { $0.command == .pageFirst })
                && !shortcuts.sections.flatMap(\.rows).contains(where: { $0.command == .frameNext }),
            "C3.1 搜索支持按命令 ID 过滤"
        )
        shortcuts.searchText = ""

        // 1. 录制多键序列（k l），验证写入 keybindings.json 且被 InputRouter 正确解析。
        let multiSequence = [KeyChord("k"), KeyChord("l")]
        let expectedMultiBinding = KeyBinding(sequence: multiSequence, command: .pageModeToggle, scope: .viewer)
        shortcuts.startRecording(command: .pageModeToggle, scope: .viewer)
        await settle()
        sendKey(kVK_ANSI_K, in: settingsWindow)
        sendKey(kVK_ANSI_L, in: settingsWindow)
        sendEscapeKey(in: settingsWindow)

        for _ in 0..<100 where !app.catalog.bindings.contains(expectedMultiBinding) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(app.catalog.bindings.contains(expectedMultiBinding), "C3.1 录制多键序列 k l 后立即重载生效")

        let persistedAfterMulti = readStoredKeyBindings(at: keyBindingsURL)
        log.check(
            persistedAfterMulti?.bindings.contains(expectedMultiBinding) == true,
            "C3.1 多键序列 k l 已持久化写入 keybindings.json"
        )

        // 用真实 InputRouter 验证新绑定的多键序列可正确解析。
        let router = InputRouter(catalog: app.catalog)
        var routedCommand: CommandID?
        router.onCommand = { id, _, _ in routedCommand = id }
        window.makeFirstResponder(controller.viewer)
        if let kEvent = makeKeyDownEvent(kVK_ANSI_K, in: window),
           let lEvent = makeKeyDownEvent(kVK_ANSI_L, in: window) {
            let firstHandled = router.handle(kEvent, in: window)
            let pendingAfterFirst = router.pending?.typed == [KeyChord("k")]
            let secondHandled = router.handle(lEvent, in: window)
            log.check(
                firstHandled && pendingAfterFirst && secondHandled && routedCommand == .pageModeToggle,
                "C3.1 InputRouter 正确解析录制的多键序列 k l → \(routedCommand?.rawValue ?? "nil")"
            )
        } else {
            log.check(false, "C3.1 无法构造测试按键事件")
        }

        // 2. 录制已被其他命令占用的按键（z 默认属于 magnifierToggle），验证冲突提示并执行“替换”。
        let conflictBindingForTarget = KeyBinding(sequence: [KeyChord("z")], command: .effectsToggle, scope: .viewer)
        let originalMagnifierBinding = KeyBinding(sequence: [KeyChord("z")], command: .magnifierToggle, scope: .viewer)
        shortcuts.searchText = "effects.toggle"
        shortcuts.startRecording(command: .effectsToggle, scope: .viewer)
        await settle()
        sendKey(kVK_ANSI_Z, in: settingsWindow)
        sendEscapeKey(in: settingsWindow)
        await settle()

        let hasConflict = shortcuts.pendingConflict?.target == ShortcutsModel.RowID(command: .effectsToggle, scope: .viewer)
            && shortcuts.pendingConflict?.conflicts.contains(originalMagnifierBinding) == true
        log.check(hasConflict, "C3.1 录制已被占用的按键 z 时检测到冲突（与放大镜冲突）")
        log.snapshot(settingsWindow, "shortcuts-conflict")

        shortcuts.resolveConflictByReplacing()
        shortcuts.searchText = ""
        for _ in 0..<100 where !app.catalog.bindings.contains(conflictBindingForTarget) || app.catalog.bindings.contains(originalMagnifierBinding) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(
            app.catalog.bindings.contains(conflictBindingForTarget) && !app.catalog.bindings.contains(originalMagnifierBinding),
            "C3.1 执行“替换”后放大镜失去 z 且效果开关获得 z"
        )

        // 3. 执行单项恢复默认与全部恢复默认，验证回到原始默认键。
        let defaultEffectsBinding = KeyBinding(sequence: [KeyChord("e")], command: .effectsToggle, scope: .viewer)
        shortcuts.resetCommand(.effectsToggle, scope: .viewer)
        for _ in 0..<100 where !app.catalog.bindings.contains(defaultEffectsBinding) || app.catalog.bindings.contains(conflictBindingForTarget) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(
            app.catalog.bindings.contains(defaultEffectsBinding)
                && !app.catalog.bindings.contains(conflictBindingForTarget)
                && app.catalog.bindings.contains(expectedMultiBinding),
            "C3.1 单项恢复默认使效果开关回到 e，且保留其他命令的自定义多键序列"
        )

        shortcuts.resetAll()
        let defaultBindings = CommandCatalog().bindings
        for _ in 0..<100 where app.catalog.bindings != defaultBindings {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let persistedAfterReset = readStoredKeyBindings(at: keyBindingsURL)
        log.check(
            app.catalog.bindings == defaultBindings
                && app.catalog.bindings.contains(originalMagnifierBinding)
                && persistedAfterReset?.bindings.isEmpty == true,
            "C3.1 全部恢复默认后回到原始默认键并清空 keybindings.json 的键盘覆盖"
        )
        log.snapshot(settingsWindow, "shortcuts-default")
        settingsWindow.close()
    }

    private func readStoredKeyBindings(at url: URL) -> KeyBindingsFile? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"],
              let valueData = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(KeyBindingsFile.self, from: valueData)
    }

    private func makeKeyDownEvent(_ keyCode: Int, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else { return nil }
        cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
        return NSEvent(cgEvent: cgEvent)
    }

    private func sendKey(_ keyCode: Int, flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
        guard let event = makeKeyDownEvent(keyCode, flags: flags, in: window) else { return }
        if NSApp.keyWindow === window {
            NSApp.sendEvent(event)
        } else if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
    }

    private func presentViewerContextMenu(_ controller: ReaderWindowController, window: NSWindow) async -> NSMenu? {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)
        var presentedMenu: NSMenu?
        viewer.gestureRecognizer.onPresentContextMenu = { menu, _, _ in
            presentedMenu = menu
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseUp, at: center, in: window)
        await settle()
        return presentedMenu
    }

    private func menuTitles(of menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func hasButton(titled title: String, in root: NSView) -> Bool {
        if let button = root as? NSButton, button.title == title || button.attributedTitle.string == title {
            return true
        }
        return root.subviews.contains { hasButton(titled: title, in: $0) }
    }

    // MARK: 夹具与事件工具

    private func makeBook(count: Int) throws -> URL {
        let directory = temporary.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            let hue = CGFloat(index) / CGFloat(max(count, 1))
            let url = directory.appending(path: String(format: "p%02d.png", index + 1))
            guard let context = CGContext(
                data: nil, width: 800, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
            guard let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url)
        }
        return directory
    }

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        for _ in 0..<300 {
            if let book = controller.session.book, book.location.name == url.lastPathComponent,
               book.pages.count == expectedCount, book.pages.allSatisfy({ $0.metadata != nil }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await settle()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func windowCenter(of view: NSView) -> NSPoint {
        windowPoint(in: view, xFraction: 0.5, yFraction: 0.5)
    }

    private func windowPoint(in view: NSView, xFraction: CGFloat, yFraction: CGFloat) -> NSPoint {
        let local = NSPoint(
            x: view.bounds.minX + view.bounds.width * xFraction,
            y: view.bounds.minY + view.bounds.height * yFraction
        )
        return view.convert(local, to: nil)
    }

    private func sendLeftClick(at point: NSPoint, in window: NSWindow) {
        let number = nextEventNumber()
        sendMouse(.leftMouseDown, at: point, in: window, eventNumber: number)
        sendMouse(.leftMouseUp, at: point, in: window, eventNumber: number)
    }

    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map {
            unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
        }
    }()

    private func sendMouseWheel(
        at point: NSPoint,
        in window: NSWindow,
        deltaY: Int32,
        deltaX: Int32 = 0,
        modifiers: CGEventFlags = []
    ) {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        cg.flags = modifiers
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        if let field = CGEventField(rawValue: 51) {
            cg.setIntegerValueField(field, value: Int64(window.windowNumber))
        }
        Self.setWindowLocation?(cg, CGPoint(x: point.x, y: window.frame.height - point.y))
        if let event = NSEvent(cgEvent: cg) {
            NSApp.sendEvent(event)
        }
    }

    private func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, eventNumber customNumber: Int? = nil) {
        let number = customNumber ?? nextEventNumber()
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: isUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
    }

    private func sendRightDrag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int = 4) {
        let number = nextEventNumber()
        sendMouse(.rightMouseDown, at: start, in: window, eventNumber: number)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            sendMouse(.rightMouseDragged, at: point, in: window, eventNumber: number)
        }
        sendMouse(.rightMouseUp, at: end, in: window, eventNumber: number)
    }

    private func sendEscapeKey(in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        if NSApp.isActive {
            NSApp.sendEvent(event)
        } else {
            window.sendEvent(event)
        }
    }
}
#endif
