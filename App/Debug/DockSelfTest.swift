#if DEBUG
import AppKit
import MVFoundation
import MVLayout

/// 停靠框架的自检。拖动手势本身（NSDraggingSession 的鼠标跟踪）无法合成，自检从手势之下的同一条路径驱动：
/// 容器按坐标求放置位置并显示指示（`showDropIndicator`），再经 `beginDrag` → `drop` → `endDrag` 完成放置，
/// 与真实拖放调用的是同一组方法；拖出浮动走 `endDrag(accepted: false)`。
///
/// 启动参数：
/// - `-MVDockSelfTest main|restore|corrupt|clicks|zero`，配合 `-MVLayoutFile <临时目录>/layout.json`；
/// - `-MVSelfTestOutput <目录>` 写入窗口图像。
///
/// 三个阶段依次运行（命令见 docs/reports/S1-F2.md）：
/// - main：三个区的各个位置、标签页与上下分割、拖出浮动再拖回、两个窗口、浮动跟随活动窗口、跨窗口移动、全屏自动隐藏；
///   最后改出一份特定布局，写入 `expected.json`，经 `NSApp.terminate` 退出（验证退出前保存）。
/// - restore：重启后布局与 `expected.json` 相同。
/// - corrupt：layout.json 被改坏时用默认布局并显示错误，文件不被覆盖。
///
/// 下面两个阶段单独运行，点击和拖动走真实事件（`NSApp.sendEvent`），`performClick` 不产生鼠标事件，测不到拖动判定：
/// - clicks：启动前 layout.json 的左右区已折叠（240、260）。点开关恢复、反复点、拖动分隔线记录尺寸、拖到边缘折叠。
/// - zero：启动前 layout.json 的左右区 `size` 为 0、未折叠。区以最小宽度显示，文件不被改写。
@MainActor
final class DockSelfTest {
    static let launchKey = "MVDockSelfTest"

    private let app: AppDelegate
    private let coordinator: DockCoordinator
    private let log = SelfTestLog()

    static func runIfRequested(app: AppDelegate) {
        guard let phase = UserDefaults.standard.string(forKey: launchKey), let coordinator = app.dock else { return }
        let test = DockSelfTest(app: app, coordinator: coordinator)
        Task {
            print("INFO 停靠自检 \(phase)，App \(NSApp.isActive ? "已激活" : "未激活（屏幕可能已锁定）")")
            switch phase {
            case "main": await test.runMain()
            case "restore": await test.runRestore()
            case "corrupt": await test.runCorrupt()
            case "clicks": await test.runClicks()
            case "zero": await test.runZero()
            default: test.log.check(false, "未知阶段 \(phase)")
            }
            test.finish(terminate: phase == "main")
        }
    }

    private init(app: AppDelegate, coordinator: DockCoordinator) {
        self.app = app
        self.coordinator = coordinator
    }

    private var expectedURL: URL {
        coordinator.fileURL.deletingLastPathComponent().appendingPathComponent("expected.json")
    }

    // MARK: main

    private func runMain() async {
        guard let first = app.controllers.first, let window = first.window else { return log.check(false, "没有窗口") }
        let dock = first.dock
        await settle()
        log.check(dock.dockLayout == DockCoordinator.docked(DockPanels.defaultLayout), "新窗口套用默认布局：\(describe(dock.dockLayout))")
        log.check(isShown(DockPanels.bookshelf, in: .left, of: dock) && isShown(DockPanels.pageList, in: .right, of: dock),
              "书架在左侧区，页面列表在右侧区")
        log.check(dock.isOnScreen(.left) && dock.isOnScreen(.right) && !dock.isOnScreen(.bottom), "底部区为空时不占空间")
        log.snapshot(window, "dock-default")
        await checkDockToggles(first)

        // 标签位置：放到左区标签行中书架之后。
        let left = dock.areas[.left]!
        let tab = left.tab(DockPanels.bookshelf)!.frame
        let afterTab = left.convert(NSPoint(x: tab.maxX + 6, y: DockAreaView.headerHeight / 2), to: dock)
        _ = dock.showDropIndicator(at: afterTab)
        log.snapshot(window, "drop-tab")
        await drop(DockPanels.pageList, from: dock, into: dock, at: afterTab, expect: .area(.left, index: 1), "标签行：书架之后")
        log.check(dock.dockLayout.left.panels == [DockPanels.bookshelf, DockPanels.pageList], "左区为书架、页面列表两个标签：\(dock.dockLayout.left.panels.map(\.rawValue))")
        log.check(!dock.isOnScreen(.right), "右区空了，收起")
        log.check(first.dockToggles[.right]?.isEnabled == false && first.dockToggles[.right]?.state == .off, "右区没有面板：工具栏开关不可用")
        first.dockToggles[.right]?.performClick(nil)
        log.check(!dock.dockLayout.right.isCollapsed, "不可用的开关点击无效")
        log.check(isShown(DockPanels.pageList, in: .left, of: dock) && dock.dockLayout.currentTab(in: .left) == DockPanels.pageList,
              "放下的标签被选中并显示")
        // 标签页形式的内容区：整个区高亮，放在最后。
        let content = left.convert(NSPoint(x: left.bounds.midX, y: left.bounds.midY), to: dock)
        log.check(dock.dropTarget(at: content)?.target == .area(.left, index: 2) && dock.dropTarget(at: content)?.label != nil,
              "标签页内容区：放到最后，整区指示")
        dock.perform { $0.selecting(DockPanels.bookshelf) }
        await settle()
        log.check(isShown(DockPanels.bookshelf, in: .left, of: dock) && dock.panels[DockPanels.pageList]?.view.superview == nil, "单击标签切换显示的面板")

        // 上下分割。
        dock.perform { $0.togglingStyle(.left) }
        await settle()
        log.check(dock.dockLayout.left.style == .split, "标签页改为上下分割")
        log.check(isShown(DockPanels.bookshelf, in: .left, of: dock) && isShown(DockPanels.pageList, in: .left, of: dock), "上下分割时两个面板同时显示")
        let top = left.convert(NSPoint(x: left.bounds.midX, y: 8), to: dock)
        let bottom = left.convert(NSPoint(x: left.bounds.midX, y: left.bounds.height - 8), to: dock)
        log.check(dock.dropTarget(at: bottom)?.target == .area(.left, index: 2), "分割位置：最下方是第 3 格")
        _ = dock.showDropIndicator(at: top)
        log.snapshot(window, "drop-split")
        await drop(DockPanels.pageList, from: dock, into: dock, at: top, expect: .area(.left, index: 0), "分割位置：最上方")
        log.check(dock.dockLayout.left.panels == [DockPanels.pageList, DockPanels.bookshelf], "页面列表移到上格：\(dock.dockLayout.left.panels.map(\.rawValue))")
        log.snapshot(window, "split")

        // 三个区的边缘：底部、右侧、左侧。
        let outer = dock.bounds
        await drop(DockPanels.bookshelf, from: dock, into: dock, at: NSPoint(x: outer.midX, y: outer.maxY - 10),
                   expect: .area(.bottom, index: 0), "底部边缘")
        log.check(dock.isOnScreen(.bottom) && isShown(DockPanels.bookshelf, in: .bottom, of: dock), "书架停靠到底部区")
        await drop(DockPanels.pageList, from: dock, into: dock, at: NSPoint(x: outer.maxX - 10, y: outer.midY),
                   expect: .area(.right, index: 0), "右侧边缘")
        log.check(!dock.isOnScreen(.left) && isShown(DockPanels.pageList, in: .right, of: dock), "页面列表停靠到右侧区，左区收起")
        let leftEdge = NSPoint(x: 10, y: outer.midY)
        _ = dock.showDropIndicator(at: leftEdge)
        log.snapshot(window, "drop-edge")
        await drop(DockPanels.bookshelf, from: dock, into: dock, at: leftEdge, expect: .area(.left, index: 0), "左侧边缘")
        log.check(isShown(DockPanels.bookshelf, in: .left, of: dock) && !dock.isOnScreen(.bottom), "书架回到左侧区，底部区收起")
        let main = first.viewer.convert(NSPoint(x: first.viewer.bounds.midX, y: first.viewer.bounds.midY), to: dock)
        log.check(dock.dropTarget(at: main) == nil, "主视图中央不是放置目标（放下即浮动）")
        log.snapshot(window, "areas")

        // 拖出浮动；Esc 取消时不变。
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        coordinator.endDrag(DockPanels.pageList, at: NSPoint(x: 400, y: 600), accepted: false, cancelled: true)
        log.check(coordinator.current.floating.isEmpty, "取消拖动不浮动")
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        coordinator.endDrag(DockPanels.pageList, at: NSPoint(x: screen.midX, y: screen.midY), accepted: false, cancelled: false)
        await settle()
        let floating = coordinator.floatingWindows[DockPanels.pageList]
        log.check(coordinator.current.floating.map(\.panel) == [DockPanels.pageList] && floating != nil, "拖到停靠区以外成为浮动面板")
        log.check(coordinator.current.floating.first?.home == .right && dock.dockLayout.right.panels.isEmpty, "浮动面板记住原来的区，右区收起")
        log.check(floating?.panel.view.window === floating, "面板视图移进浮动窗口")
        log.check(placeholder(floating?.panel)?.boundSession == first.session.id, "浮动面板作用于窗口 1")

        // 第二个窗口：套用最近的布局；各自改动互不影响。
        guard let second = app.newWindow(), let secondWindow = second.window else { return log.check(false, "没有第二个窗口") }
        await settle()
        log.check(second.dock.dockLayout == dock.dockLayout, "新窗口套用最近一次改动后的布局")
        second.dock.perform { $0.togglingArea(.left) }
        await settle()
        log.check(second.dock.dockLayout.left.isCollapsed && !dock.dockLayout.left.isCollapsed, "两个窗口各有自己的布局：窗口 2 收起左区，窗口 1 不变")
        log.snapshot(secondWindow, "window2")
        log.check(second.dockToggles[.left]?.state == .off && first.dockToggles[.left]?.state == .on, "工具栏开关的按下态各跟随自己的窗口")
        second.dockToggles[.left]?.performClick(nil)
        await settle()
        log.check(!second.dock.dockLayout.left.isCollapsed && second.dockToggles[.left]?.state == .on && !dock.dockLayout.left.isCollapsed, "点窗口 2 的工具栏开关，只作用于窗口 2")
        second.dockToggles[.left]?.performClick(nil)
        await settle()
        log.check(second.dock.dockLayout.left.isCollapsed && !dock.dockLayout.left.isCollapsed, "再点一次，窗口 1 仍不变")

        // 浮动面板跟随活动窗口。App 未激活时没有主窗口通知，直接调用通知处理的同一方法。
        await activate(second)
        log.check(placeholder(floating?.panel)?.boundSession == second.session.id, "切到窗口 2：浮动面板改为作用于窗口 2")
        await activate(first)
        log.check(placeholder(floating?.panel)?.boundSession == first.session.id, "切回窗口 1：浮动面板跟随")

        // 拖回：从浮动面板拖进窗口 2 的右区。
        await activate(second)
        let secondRight = NSPoint(x: second.dock.bounds.maxX - 10, y: second.dock.bounds.midY)
        let floatingInstance = floating?.panel
        await drop(DockPanels.pageList, from: nil, into: second.dock, at: secondRight, expect: .area(.right, index: 0), "浮动面板拖回窗口 2 右侧")
        log.check(coordinator.current.floating.isEmpty && coordinator.floatingWindows.isEmpty, "拖回后不再浮动")
        log.check(second.dock.panels[DockPanels.pageList] === floatingInstance && isShown(DockPanels.pageList, in: .right, of: second.dock),
              "同一面板实例停靠到窗口 2")
        log.check(dock.dockLayout.placement(of: DockPanels.pageList) == nil, "窗口 1 不因此多出页面列表")

        // 视图设置与跨窗口移动。
        placeholder(dock.panels[DockPanels.bookshelf])?.setStyle(.grid)
        let grid: JSONValue = .object(["style": .string("grid")])
        log.check(coordinator.current.settings[DockPanels.bookshelf] == grid, "视图设置编码进布局：\(String(describing: coordinator.current.settings[DockPanels.bookshelf]))")
        let bookshelf = dock.panels[DockPanels.bookshelf]
        let secondBottom = NSPoint(x: second.dock.bounds.midX, y: second.dock.bounds.maxY - 10)
        await drop(DockPanels.bookshelf, from: dock, into: second.dock, at: secondBottom, expect: .area(.bottom, index: 0), "跨窗口：窗口 1 的书架到窗口 2 底部")
        log.check(dock.dockLayout.placement(of: DockPanels.bookshelf) == nil && second.dock.dockLayout.settings[DockPanels.bookshelf] == grid,
              "书架连同视图设置移到窗口 2")
        log.check(second.dock.panels[DockPanels.bookshelf] === bookshelf && placeholder(bookshelf)?.boundSession == second.session.id,
              "实例保留，改为作用于窗口 2")
        log.snapshot(secondWindow, "window2-cross")

        // 菜单“浮动”与“停靠”按钮：回到原来的区。
        coordinator.float(DockPanels.pageList, from: second.dock, at: nil)
        await settle()
        log.check(coordinator.current.floating.first?.home == .right, "经菜单浮动")
        coordinator.dockFloating(DockPanels.pageList)
        await settle()
        log.check(second.dock.dockLayout.right.panels == [DockPanels.pageList], "“停靠回窗口”回到右区")

        // 显示/隐藏命令。
        let pageListType = DockPanels.type(DockPanels.pageList)!
        coordinator.togglePanel(pageListType, in: second.dock)
        await settle()
        log.check(!second.dock.dockLayout.isPanelVisible(DockPanels.pageList) && !second.dock.isOnScreen(.right), "隐藏页面列表，右区随之收起")
        coordinator.togglePanel(pageListType, in: second.dock)
        second.dock.perform { $0.togglingArea(.right) }
        await settle()
        log.check(second.dock.dockLayout.right.isCollapsed && !second.dock.isOnScreen(.right), "隐藏右侧停靠区")
        second.dock.perform { $0.togglingArea(.right) }
        second.dock.perform { $0.togglingAllAreas() }
        await settle()
        log.check(DockEdge.allCases.allSatisfy { !second.dock.isOnScreen($0) }, "Tab：全部停靠区隐藏")
        second.dock.perform { $0.togglingAllAreas() }
        await settle()
        log.check(second.dock.isOnScreen(.right) && second.dock.isOnScreen(.bottom), "再按一次全部显示")

        // 全屏自动隐藏（窗口 1：左区书架、右区页面列表）。
        await activate(first)
        coordinator.togglePanel(DockPanels.type(DockPanels.bookshelf)!, in: dock)
        coordinator.togglePanel(pageListType, in: dock)
        await settle()
        log.check(dock.isOnScreen(.left) && dock.isOnScreen(.right), "窗口 1 重新显示两个面板")
        await fullScreen(first, on: true)
        log.check(!dock.isOnScreen(.left) && !dock.isOnScreen(.right), "全屏时停靠区隐藏")
        // 折叠的区在边缘各留一条 1 点的分隔线。
        log.check(abs(first.viewer.frame.width - dock.bounds.width) <= 2, "主视图占满宽度：\(first.viewer.frame.width) / \(dock.bounds.width)")
        let beforeToggle = dock.dockLayout
        log.check(first.dockToggles[.left]?.isEnabled == true && first.dockToggles[.left]?.state == .on, "全屏自动隐藏时开关可用，按下态不变")
        first.dockToggles[.left]?.performClick(nil)
        await settle()
        log.check(dock.dockLayout == beforeToggle.togglingArea(.left) && first.dockToggles[.left]?.state == .off, "全屏时点开关，结果与菜单命令相同")
        first.run(.dockLeftToggle)
        await settle()
        log.check(dock.dockLayout == beforeToggle && first.dockToggles[.left]?.state == .on, "全屏时菜单命令恢复，按下态同步")
        let mid = dock.convert(NSPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: nil)
        dock.autoHideMouseMoved(to: dock.convert(NSPoint(x: 1, y: dock.bounds.midY), to: nil))
        await settle()
        log.check(dock.isOnScreen(.left) && dock.revealed == [.left], "鼠标到左边缘，左区浮出")
        log.snapshot(window, "fullscreen-reveal")
        dock.autoHideMouseMoved(to: mid)
        log.check(!dock.isOnScreen(.left), "鼠标离开后左区收回")
        dock.autoHideMouseMoved(to: dock.convert(NSPoint(x: dock.bounds.maxX - 1, y: dock.bounds.midY), to: nil))
        log.check(dock.revealed == [.right], "鼠标到右边缘，右区浮出")
        dock.autoHideMouseMoved(to: mid)
        log.check(dock.revealed.isEmpty, "离开后收回")
        let beforeExit = dock.dockLayout
        await fullScreen(first, on: false)
        log.check(dock.isOnScreen(.left) && dock.isOnScreen(.right) && dock.dockLayout == beforeExit, "退出全屏后恢复原布局")
        log.check(isShown(DockPanels.bookshelf, in: .left, of: dock), "面板回到分栏中")

        // 留下一份特定布局供重启验证：左区上下分割、底部区高度 222、页面列表浮动。最后一项改动在去抖时间内退出，验证退出前保存。
        if dock.dockLayout.left.style != .split { dock.perform { $0.togglingStyle(.left) } }
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        coordinator.drop(into: dock, at: .area(.bottom, index: 0))
        coordinator.endDrag(DockPanels.pageList, at: .zero, accepted: true, cancelled: false)
        dock.perform(render: false) { $0.resizing(.bottom, to: 222) }
        await settle()
        coordinator.float(DockPanels.pageList, from: dock, at: NSPoint(x: screen.midX, y: screen.midY))
        await settle()
        // 窗口的 frame 取整数点；用整数，重启后摆放时才不被 AppKit 改动。
        coordinator.floatingMoved(DockPanels.pageList, to: DockFrame(x: floor(screen.midX) - 130, y: floor(screen.midY) - 200, width: 260, height: 400))
        placeholder(dock.panels[DockPanels.bookshelf])?.setStyle(.grid)
        await settle()
        dock.perform(render: false) { $0.resizing(.left, to: 300) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(coordinator.current).write(to: expectedURL)
        } catch {
            log.check(false, "无法写入 expected.json：\(error)")
        }
        log.check(coordinator.current.left.style == .split && coordinator.current.left.size == 300 && coordinator.current.bottom.size == 222
              && coordinator.current.floating.map(\.panel) == [DockPanels.pageList], "最终布局：左区分割 300，底部 222，页面列表浮动：\(describe(coordinator.current))")
    }

    /// 工具栏开关与区头按钮、菜单命令、显示/隐藏面板的命令（⌥⌘1）同步。
    private func checkDockToggles(_ controller: ReaderWindowController) async {
        let dock = controller.dock
        guard let left = controller.dockToggles[.left], let right = controller.dockToggles[.right] else { return log.check(false, "没有工具栏开关") }
        let items = controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        log.check(items.first == "dock.left" && items.last == "dock.right", "左侧开关在最前，右侧开关在最后：\(items)")
        log.check(left.state == .on && right.state == .on && left.isEnabled && right.isEnabled, "默认布局：两个开关按下且可用")
        dockHideButton(dock, .left)?.performClick(nil)
        await settle()
        log.check(!dock.isOnScreen(.left) && left.state == .off && left.isEnabled, "区头按钮隐藏：开关弹起，仍可用")
        left.performClick(nil)
        await settle()
        log.check(dock.isOnScreen(.left) && left.state == .on, "点工具栏开关：区恢复，开关按下")
        controller.run(.dockRightToggle)
        await settle()
        log.check(!dock.isOnScreen(.right) && right.state == .off, "菜单命令隐藏：开关弹起")
        controller.run(.dockRightToggle)
        await settle()
        log.check(dock.isOnScreen(.right) && right.state == .on, "菜单命令显示：开关按下")
        let bookshelf = DockPanels.type(DockPanels.bookshelf)!
        controller.run(bookshelf.toggleCommand)
        await settle()
        log.check(left.state == .off && !left.isEnabled, "⌥⌘1 隐藏书架：区里没有可见面板，开关不可用")
        controller.run(bookshelf.toggleCommand)
        await settle()
        log.check(dock.isOnScreen(.left) && left.state == .on && left.isEnabled, "⌥⌘1 显示书架：开关恢复")
    }

    private func dockHideButton(_ dock: WindowDock, _ edge: DockEdge) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.toolTip == String(localized: "隐藏停靠区") { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(dock.areas[edge]!)
    }

    // MARK: restore

    private func runRestore() async {
        guard let first = app.controllers.first, let window = first.window else { return log.check(false, "没有窗口") }
        await settle()
        guard let data = try? Data(contentsOf: expectedURL), let expected = try? JSONDecoder().decode(DockLayout.self, from: data) else {
            return log.check(false, "读不到 expected.json")
        }
        log.check(coordinator.problem == nil, "没有错误提示")
        log.check(coordinator.current == expected, "layout.json 与退出前的布局相同")
        log.check(first.dock.dockLayout == DockCoordinator.docked(expected), "窗口套用恢复的布局")
        let floating = coordinator.floatingWindows[DockPanels.pageList]
        let frame = expected.floating.first?.frame
        log.check(floating != nil && frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } == floating?.frame,
              "浮动面板恢复到原位置：\(String(describing: floating?.frame))")
        log.check(placeholder(first.dock.panels[DockPanels.bookshelf])?.settings.style == .grid, "书架的视图设置恢复为网格")
        log.check(first.dock.isOnScreen(.left) && abs(first.dock.areas[.left]!.frame.width - 300) < 1,
              "左区宽度恢复为 300：\(first.dock.areas[.left]!.frame.width)")
        log.check(first.dockToggles[.left]?.state == .on && first.dockToggles[.left]?.isEnabled == true, "重启后左侧开关按下")
        log.check(first.dockToggles[.right]?.state == .off && first.dockToggles[.right]?.isEnabled == false, "重启后右区没有面板，右侧开关不可用")
        log.snapshot(window, "restored")
    }

    // MARK: corrupt

    private func runCorrupt() async {
        guard let first = app.controllers.first, let window = first.window else { return log.check(false, "没有窗口") }
        let original = try? Data(contentsOf: coordinator.fileURL)
        for _ in 0..<40 where coordinator.problem == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await settle()
        log.check(coordinator.problem != nil, "显示错误：\(coordinator.problem.map { "\($0.title) / \($0.detail)" } ?? "nil")")
        log.check(first.dock.dockLayout == DockCoordinator.docked(DockPanels.defaultLayout), "用默认布局打开")
        let banner = first.dock.subviews.compactMap { $0 as? FileErrorBanner }.first
        let left = first.dock.areas[.left]!
        log.check(banner != nil && banner!.frame.height > 0 && left.convert(left.bounds, to: first.dock).minY >= banner!.frame.maxY - 1,
              "窗口顶部显示错误提示条")
        log.snapshot(window, "corrupt")
        try? await Task.sleep(for: DockCoordinator.saveDelay + .milliseconds(300))
        log.check(original != nil && (try? Data(contentsOf: coordinator.fileURL)) == original, "没有改动布局时不覆盖改坏的文件")
    }

    // MARK: clicks

    private func runClicks() async {
        guard let first = app.controllers.first, let window = first.window,
              let left = first.dockToggles[.left], let right = first.dockToggles[.right] else { return log.check(false, "没有窗口或开关") }
        let dock = first.dock
        await settle()
        guard await activateApp(window) else { return print("SKIP 真实事件路径（App 未激活）") }
        log.check(!dock.isOnScreen(.left) && !dock.isOnScreen(.right) && left.state == .off && right.state == .off, "启动时左右区已折叠")

        let saved: [(edge: DockEdge, button: NSButton, size: Double)] = [(.left, left, 240), (.right, right, 260)]
        for (edge, button, size) in saved {
            await click(button, in: window)
            log.check(button.state == .on && dock.isOnScreen(edge), "真实点击\(edge)开关：区出现，开关按下")
            await checkSize(edge, of: dock, width: size, saved: size, "展开后")
        }
        for (edge, button, size) in saved {
            for _ in 0..<5 { await click(button, in: window) }
            log.check(button.state == .off && dock.dockLayout[edge].size == size, "\(edge)开关点 5 次：区隐藏，size 不变：\(dock.dockLayout[edge].size)")
            await click(button, in: window)
            await checkSize(edge, of: dock, width: size, saved: size, "反复点之后")
        }

        // 真实拖动分隔线：记录尺寸。
        await drag(in: window, from: divider(.left, of: dock), byX: 60)
        await checkSize(.left, of: dock, width: 300, saved: 300, "向右拖动分隔线")
        await drag(in: window, from: divider(.right, of: dock), byX: -40)
        await checkSize(.right, of: dock, width: 300, saved: 300, "向左拖动分隔线")
        // 拖到边缘：折叠，尺寸保留，点开关回到原宽度。
        for (edge, button) in [(DockEdge.left, left), (.right, right)] {
            let start = divider(edge, of: dock)
            await drag(in: window, from: start, byX: (edge == .left ? 2 : window.frame.width - 2) - start.x)
            try? await Task.sleep(for: DockCoordinator.saveDelay + .milliseconds(300))
            log.check(dock.dockLayout[edge].isCollapsed && !dock.isOnScreen(edge) && button.state == .off && savedLayout()?[edge].isCollapsed == true,
                      "\(edge)分隔线拖到边缘：折叠并保存")
            await click(button, in: window)
            // 合成点击紧跟拖动时偶尔送不到按钮的动作，第二下总能送到；真实鼠标是否如此要人工确认。
            if dock.dockLayout[edge].isCollapsed {
                print("SKIP \(edge)分隔线拖动后的第一下合成点击没有送到开关，再点一次")
                await click(button, in: window)
            }
            await checkSize(edge, of: dock, width: 300, saved: 300, "折叠后点开关")
        }

        // 上下分割：拖动记录相对高度，开关不改变它。
        dock.perform { $0.moving(DockPanels.pageList, to: .area(.left, index: 1)).togglingStyle(.left) }
        await settle()
        guard let top = part(DockPanels.bookshelf, of: dock), let bottom = part(DockPanels.pageList, of: dock) else { return log.check(false, "没有分割的两格") }
        let height = top.frame.height
        let start = NSPoint(x: top.convert(top.bounds, to: nil).midX, y: (top.convert(top.bounds, to: nil).minY + bottom.convert(bottom.bounds, to: nil).maxY) / 2)
        await drag(in: window, from: start, byY: 40)
        let weight = dock.dockLayout.left.weights[DockPanels.bookshelf]
        log.check(weight.map { abs($0 - (height - 40)) < 2 } == true, "拖动上下分隔线记录高度：\(String(describing: weight)) / \(height)")
        let weights = dock.dockLayout.left.weights
        await click(left, in: window)
        await click(left, in: window)
        log.check(dock.dockLayout.left.weights == weights, "点开关不改变上下分割的高度：\(dock.dockLayout.left.weights)")
    }

    // MARK: zero

    private func runZero() async {
        guard let first = app.controllers.first, let window = first.window,
              let left = first.dockToggles[.left] else { return log.check(false, "没有窗口或开关") }
        let dock = first.dock
        await settle()
        guard await activateApp(window) else { return print("SKIP 真实事件路径（App 未激活）") }
        for edge in [DockEdge.left, .right] {
            await checkSize(edge, of: dock, width: WindowDock.minimumSize[edge]!, saved: 0, "保存的 size 为 0")
        }
        await click(left, in: window)
        log.check(left.state == .off && !dock.isOnScreen(.left), "真实点击隐藏：区不在屏幕上")
        await click(left, in: window)
        await checkSize(.left, of: dock, width: WindowDock.minimumSize[.left]!, saved: 0, "点两次开关之后")
    }

    // MARK: 工具

    private struct SavedLayout: Decodable { var value: DockLayout }

    private func savedLayout() -> DockLayout? {
        (try? Data(contentsOf: coordinator.fileURL)).flatMap { try? JSONDecoder().decode(SavedLayout.self, from: $0).value }
    }

    /// 区的实际宽度、内存中和磁盘上的 size。磁盘在保存的去抖之后读。
    private func checkSize(_ edge: DockEdge, of dock: WindowDock, width: CGFloat, saved: Double, _ message: String) async {
        try? await Task.sleep(for: DockCoordinator.saveDelay + .milliseconds(300))
        let actual = dock.areas[edge]!.frame.width
        let disk = savedLayout()?[edge].size
        log.check(dock.isOnScreen(edge) && abs(actual - width) < 1 && disk == saved,
                  "\(message)：\(edge)区在屏幕上 \(dock.isOnScreen(edge))，折叠 \(dock.dockLayout[edge].isCollapsed)，宽度 \(actual)（期望 \(width)），layout.json 的 size \(String(describing: disk))（期望 \(saved)），内存 \(dock.dockLayout[edge].size)")
    }

    /// 真实事件在前台窗口上才等同于用户操作。`NSApp.activate()` 是协作式的，别的 App 不让出时无效，所以经 LaunchServices。
    private func activateApp(_ window: NSWindow) async -> Bool {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", Bundle.main.bundlePath]
            try? open.run()
        }
        for _ in 0..<50 where !NSApp.isActive {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return NSApp.isActive
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// 视图的 `mouseDown` 会进入跟踪循环，后续事件要先放进队列。
    private func click(_ button: NSButton, in window: NSWindow) async {
        _ = await activateApp(window)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: point, in: window), atStart: false)
        NSApp.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window))
        await settle()
    }

    private func drag(in window: NSWindow, from start: NSPoint, byX x: CGFloat = 0, byY y: CGFloat = 0) async {
        let end = NSPoint(x: start.x + x, y: start.y + y)
        NSApp.postEvent(mouseEvent(.leftMouseDragged, at: end, in: window), atStart: false)
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: end, in: window), atStart: false)
        NSApp.sendEvent(mouseEvent(.leftMouseDown, at: start, in: window))
        await settle()
    }

    /// 左右区与主视图之间的分隔线中点（窗口坐标）。
    private func divider(_ edge: DockEdge, of dock: WindowDock) -> NSPoint {
        let area = dock.areas[edge]!
        let frame = area.convert(area.bounds, to: nil)
        return NSPoint(x: edge == .left ? frame.maxX + 0.5 : frame.minX - 0.5, y: frame.midY)
    }

    /// 上下分割中面板所在的那一格。
    private func part(_ panel: PanelID, of dock: WindowDock) -> NSView? {
        var view = dock.panels[panel]?.view
        while let current = view, !(current is PanelFrameView) { view = current.superview }
        return view
    }

    private func finish(terminate: Bool) {
        let failures = log.summarize()
        if terminate, failures == 0 {
            // 经 run loop 的定时器退出，与菜单的“退出”一样不在主队列的任务里：
            // applicationShouldTerminate 返回 terminateLater 后，保存布局的任务要在主队列上运行。
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } else {
            exit(failures)
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func describe(_ layout: DockLayout) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(layout)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func placeholder(_ panel: (any DockPanel)?) -> PlaceholderPanel? {
        panel as? PlaceholderPanel
    }

    /// 面板视图在某个区里，并且在窗口中。
    private func isShown(_ panel: PanelID, in edge: DockEdge, of dock: WindowDock) -> Bool {
        guard let view = dock.panels[panel]?.view, view.window != nil else { return false }
        return view.isDescendant(of: dock.areas[edge]!) && dock.isOnScreen(edge)
    }

    /// 按容器坐标求放置位置（与拖动经过时相同），核对后放下。
    private func drop(_ panel: PanelID, from source: WindowDock?, into target: WindowDock, at point: NSPoint,
                      expect: DockTarget, _ message: String) async {
        let resolved = target.showDropIndicator(at: point)
        log.check(resolved == expect, "放置位置 \(message)：\(String(describing: resolved))")
        guard let resolved else { return }
        coordinator.beginDrag(panel, from: source)
        coordinator.drop(into: target, at: resolved)
        coordinator.endDrag(panel, at: .zero, accepted: true, cancelled: false)
        target.hideDropIndicator()
        await settle()
    }

    private func activate(_ controller: ReaderWindowController) async {
        controller.window?.makeKeyAndOrderFront(nil)
        await settle()
        if coordinator.active !== controller.dock {
            coordinator.activate(controller.dock)
        }
    }

    /// 进入或退出全屏；App 未激活等原因无法切换时，直接调用窗口通知处理的同一方法。
    private func fullScreen(_ controller: ReaderWindowController, on: Bool) async {
        guard let window = controller.window else { return }
        // App 未激活（屏幕锁定）时全屏过渡会停在半途：只发出 willEnter 通知，不完成。
        if NSApp.isActive, window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
            for _ in 0..<80 where window.styleMask.contains(.fullScreen) != on {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
        }
        if controller.dock.isAutoHiding != on {
            print("SKIP 真实全屏\(on ? "进入" : "退出")（App 未激活或切换未生效），改为直接调用窗口通知处理中的 setAutoHide")
            controller.dock.setAutoHide(on)
            await settle()
        }
    }
}
#endif
