#if DEBUG
import AppKit
import MVFoundation
import MVLayout

/// 停靠框架的自检。拖动手势本身（NSDraggingSession 的鼠标跟踪）无法合成，自检从手势之下的同一条路径驱动：
/// 容器按坐标求放置位置并显示指示（`showDropIndicator`），再经 `beginDrag` → `drop` → `endDrag` 完成放置，
/// 与真实拖放调用的是同一组方法；拖出浮动走 `endDrag(accepted: false)`。
///
/// 启动参数：
/// - `-MVDockSelfTest main|restore|corrupt`，配合 `-MVLayoutFile <临时目录>/layout.json`；
/// - `-MVSelfTestOutput <目录>` 写入窗口图像。
///
/// 三个阶段依次运行（命令见 docs/reports/S1-F2.md）：
/// - main：三个区的各个位置、标签页与上下分割、拖出浮动再拖回、两个窗口、浮动跟随活动窗口、跨窗口移动、全屏自动隐藏；
///   最后改出一份特定布局，写入 `expected.json`，经 `NSApp.terminate` 退出（验证退出前保存）。
/// - restore：重启后布局与 `expected.json` 相同。
/// - corrupt：layout.json 被改坏时用默认布局并显示错误，文件不被覆盖。
@MainActor
final class DockSelfTest {
    static let launchKey = "MVDockSelfTest"

    private let app: AppDelegate
    private let coordinator: DockCoordinator
    private let output: URL?
    private var failures = 0

    static func runIfRequested(app: AppDelegate) {
        guard let phase = UserDefaults.standard.string(forKey: launchKey), let coordinator = app.dock else { return }
        let output = UserDefaults.standard.string(forKey: SelfTest.outputKey).map { URL(fileURLWithPath: $0) }
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let test = DockSelfTest(app: app, coordinator: coordinator, output: output)
        Task {
            print("INFO 停靠自检 \(phase)，App \(NSApp.isActive ? "已激活" : "未激活（屏幕可能已锁定）")")
            switch phase {
            case "main": await test.runMain()
            case "restore": await test.runRestore()
            case "corrupt": await test.runCorrupt()
            default: test.check(false, "未知阶段 \(phase)")
            }
            test.finish(terminate: phase == "main")
        }
    }

    private init(app: AppDelegate, coordinator: DockCoordinator, output: URL?) {
        self.app = app
        self.coordinator = coordinator
        self.output = output
    }

    private var expectedURL: URL {
        coordinator.fileURL.deletingLastPathComponent().appendingPathComponent("expected.json")
    }

    // MARK: main

    private func runMain() async {
        guard let first = app.controllers.first, let window = first.window else { return check(false, "没有窗口") }
        let dock = first.dock
        let container = dock.container
        await settle()
        check(dock.layout == docked(DockPanels.defaultLayout), "新窗口套用默认布局：\(describe(dock.layout))")
        check(isShown(DockPanels.bookshelf, in: .left, of: dock) && isShown(DockPanels.pageList, in: .right, of: dock),
              "书架在左侧区，页面列表在右侧区")
        check(container.isOnScreen(.left) && container.isOnScreen(.right) && !container.isOnScreen(.bottom), "底部区为空时不占空间")
        snapshot(window, "dock-default")

        // 标签位置：放到左区标签行中书架之后。
        let left = container.areas[.left]!
        let tab = left.tab(DockPanels.bookshelf)!.frame
        let afterTab = left.convert(NSPoint(x: tab.maxX + 6, y: DockAreaView.headerHeight / 2), to: container)
        _ = container.showDropIndicator(at: afterTab)
        snapshot(window, "drop-tab")
        await drop(DockPanels.pageList, from: dock, into: dock, at: afterTab, expect: .area(.left, index: 1), "标签行：书架之后")
        check(dock.layout.left.panels == [DockPanels.bookshelf, DockPanels.pageList], "左区为书架、页面列表两个标签：\(dock.layout.left.panels.map(\.rawValue))")
        check(!container.isOnScreen(.right), "右区空了，收起")
        check(isShown(DockPanels.pageList, in: .left, of: dock) && dock.layout.currentTab(in: .left) == DockPanels.pageList,
              "放下的标签被选中并显示")
        // 标签页形式的内容区：整个区高亮，放在最后。
        let content = left.convert(NSPoint(x: left.bounds.midX, y: left.bounds.midY), to: container)
        check(container.dropTarget(at: content)?.target == .area(.left, index: 2) && container.dropTarget(at: content)?.label != nil,
              "标签页内容区：放到最后，整区指示")
        dock.select(DockPanels.bookshelf)
        await settle()
        check(isShown(DockPanels.bookshelf, in: .left, of: dock) && dock.panels[DockPanels.pageList]?.view.superview == nil, "单击标签切换显示的面板")

        // 上下分割。
        dock.toggleStyle(.left)
        await settle()
        check(dock.layout.left.style == .split, "标签页改为上下分割")
        check(isShown(DockPanels.bookshelf, in: .left, of: dock) && isShown(DockPanels.pageList, in: .left, of: dock), "上下分割时两个面板同时显示")
        let top = left.convert(NSPoint(x: left.bounds.midX, y: 8), to: container)
        let bottom = left.convert(NSPoint(x: left.bounds.midX, y: left.bounds.height - 8), to: container)
        check(container.dropTarget(at: bottom)?.target == .area(.left, index: 2), "分割位置：最下方是第 3 格")
        _ = container.showDropIndicator(at: top)
        snapshot(window, "drop-split")
        await drop(DockPanels.pageList, from: dock, into: dock, at: top, expect: .area(.left, index: 0), "分割位置：最上方")
        check(dock.layout.left.panels == [DockPanels.pageList, DockPanels.bookshelf], "页面列表移到上格：\(dock.layout.left.panels.map(\.rawValue))")
        snapshot(window, "split")

        // 三个区的边缘：底部、右侧、左侧。
        let outer = container.bounds
        await drop(DockPanels.bookshelf, from: dock, into: dock, at: NSPoint(x: outer.midX, y: outer.maxY - 10),
                   expect: .area(.bottom, index: 0), "底部边缘")
        check(container.isOnScreen(.bottom) && isShown(DockPanels.bookshelf, in: .bottom, of: dock), "书架停靠到底部区")
        await drop(DockPanels.pageList, from: dock, into: dock, at: NSPoint(x: outer.maxX - 10, y: outer.midY),
                   expect: .area(.right, index: 0), "右侧边缘")
        check(!container.isOnScreen(.left) && isShown(DockPanels.pageList, in: .right, of: dock), "页面列表停靠到右侧区，左区收起")
        let leftEdge = NSPoint(x: 10, y: outer.midY)
        _ = container.showDropIndicator(at: leftEdge)
        snapshot(window, "drop-edge")
        await drop(DockPanels.bookshelf, from: dock, into: dock, at: leftEdge, expect: .area(.left, index: 0), "左侧边缘")
        check(isShown(DockPanels.bookshelf, in: .left, of: dock) && !container.isOnScreen(.bottom), "书架回到左侧区，底部区收起")
        let main = first.pageView.convert(NSPoint(x: first.pageView.bounds.midX, y: first.pageView.bounds.midY), to: container)
        check(container.dropTarget(at: main) == nil, "主视图中央不是放置目标（放下即浮动）")
        snapshot(window, "areas")

        // 拖出浮动；Esc 取消时不变。
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        coordinator.endDrag(DockPanels.pageList, at: NSPoint(x: 400, y: 600), accepted: false, cancelled: true)
        check(coordinator.current.floating.isEmpty, "取消拖动不浮动")
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        coordinator.endDrag(DockPanels.pageList, at: NSPoint(x: screen.midX, y: screen.midY), accepted: false, cancelled: false)
        await settle()
        let floating = coordinator.floatingWindows[DockPanels.pageList]
        check(coordinator.current.floating.map(\.panel) == [DockPanels.pageList] && floating != nil, "拖到停靠区以外成为浮动面板")
        check(coordinator.current.floating.first?.home == .right && dock.layout.right.panels.isEmpty, "浮动面板记住原来的区，右区收起")
        check(floating?.panel.view.window === floating, "面板视图移进浮动窗口")
        check(placeholder(floating?.panel)?.boundSession == first.session.id, "浮动面板作用于窗口 1")

        // 第二个窗口：套用最近的布局；各自改动互不影响。
        guard let second = app.newWindow(), let secondWindow = second.window else { return check(false, "没有第二个窗口") }
        await settle()
        check(second.dock.layout == dock.layout, "新窗口套用最近一次改动后的布局")
        second.dock.toggleArea(.left)
        await settle()
        check(second.dock.layout.left.isCollapsed && !dock.layout.left.isCollapsed, "两个窗口各有自己的布局：窗口 2 收起左区，窗口 1 不变")
        snapshot(secondWindow, "window2")

        // 浮动面板跟随活动窗口。App 未激活时没有主窗口通知，直接调用通知处理的同一方法。
        await activate(second)
        check(placeholder(floating?.panel)?.boundSession == second.session.id, "切到窗口 2：浮动面板改为作用于窗口 2")
        await activate(first)
        check(placeholder(floating?.panel)?.boundSession == first.session.id, "切回窗口 1：浮动面板跟随")

        // 拖回：从浮动面板拖进窗口 2 的右区。
        await activate(second)
        let secondRight = NSPoint(x: second.dock.container.bounds.maxX - 10, y: second.dock.container.bounds.midY)
        let floatingInstance = floating?.panel
        await drop(DockPanels.pageList, from: nil, into: second.dock, at: secondRight, expect: .area(.right, index: 0), "浮动面板拖回窗口 2 右侧")
        check(coordinator.current.floating.isEmpty && coordinator.floatingWindows.isEmpty, "拖回后不再浮动")
        check(second.dock.panels[DockPanels.pageList] === floatingInstance && isShown(DockPanels.pageList, in: .right, of: second.dock),
              "同一面板实例停靠到窗口 2")
        check(dock.layout.placement(of: DockPanels.pageList) == nil, "窗口 1 不因此多出页面列表")

        // 视图设置与跨窗口移动。
        placeholder(dock.panels[DockPanels.bookshelf])?.setStyle(.grid)
        let grid: JSONValue = .object(["style": .string("grid")])
        check(coordinator.current.settings[DockPanels.bookshelf] == grid, "视图设置编码进布局：\(String(describing: coordinator.current.settings[DockPanels.bookshelf]))")
        let bookshelf = dock.panels[DockPanels.bookshelf]
        let secondBottom = NSPoint(x: second.dock.container.bounds.midX, y: second.dock.container.bounds.maxY - 10)
        await drop(DockPanels.bookshelf, from: dock, into: second.dock, at: secondBottom, expect: .area(.bottom, index: 0), "跨窗口：窗口 1 的书架到窗口 2 底部")
        check(dock.layout.placement(of: DockPanels.bookshelf) == nil && second.dock.layout.settings[DockPanels.bookshelf] == grid,
              "书架连同视图设置移到窗口 2")
        check(second.dock.panels[DockPanels.bookshelf] === bookshelf && placeholder(bookshelf)?.boundSession == second.session.id,
              "实例保留，改为作用于窗口 2")
        snapshot(secondWindow, "window2-cross")

        // 菜单“浮动”与“停靠”按钮：回到原来的区。
        coordinator.float(DockPanels.pageList, from: second.dock, at: nil)
        await settle()
        check(coordinator.current.floating.first?.home == .right, "经菜单浮动")
        coordinator.dockFloating(DockPanels.pageList, to: nil)
        await settle()
        check(second.dock.layout.right.panels == [DockPanels.pageList], "“停靠回窗口”回到右区")

        // 显示/隐藏命令。
        let pageListType = DockPanels.type(DockPanels.pageList)!
        coordinator.togglePanel(pageListType, in: second.dock)
        await settle()
        check(!second.dock.layout.isPanelVisible(DockPanels.pageList) && !second.dock.container.isOnScreen(.right), "隐藏页面列表，右区随之收起")
        coordinator.togglePanel(pageListType, in: second.dock)
        coordinator.toggleArea(.right, in: second.dock)
        await settle()
        check(second.dock.layout.right.isCollapsed && !second.dock.container.isOnScreen(.right), "隐藏右侧停靠区")
        coordinator.toggleArea(.right, in: second.dock)
        coordinator.toggleAllAreas(in: second.dock)
        await settle()
        check(DockEdge.allCases.allSatisfy { !second.dock.container.isOnScreen($0) }, "Tab：全部停靠区隐藏")
        coordinator.toggleAllAreas(in: second.dock)
        await settle()
        check(second.dock.container.isOnScreen(.right) && second.dock.container.isOnScreen(.bottom), "再按一次全部显示")

        // 全屏自动隐藏（窗口 1：左区书架、右区页面列表）。
        await activate(first)
        coordinator.togglePanel(DockPanels.type(DockPanels.bookshelf)!, in: dock)
        coordinator.togglePanel(pageListType, in: dock)
        await settle()
        check(container.isOnScreen(.left) && container.isOnScreen(.right), "窗口 1 重新显示两个面板")
        await fullScreen(first, container: container, on: true)
        check(!container.isOnScreen(.left) && !container.isOnScreen(.right), "全屏时停靠区隐藏")
        // 折叠的区在边缘各留一条 1 点的分隔线。
        check(abs(first.pageView.frame.width - container.bounds.width) <= 2, "主视图占满宽度：\(first.pageView.frame.width) / \(container.bounds.width)")
        let mid = container.convert(NSPoint(x: container.bounds.midX, y: container.bounds.midY), to: nil)
        container.autoHideMouseMoved(to: container.convert(NSPoint(x: 1, y: container.bounds.midY), to: nil))
        await settle()
        check(container.isOnScreen(.left) && container.revealed == [.left], "鼠标到左边缘，左区浮出")
        snapshot(window, "fullscreen-reveal")
        container.autoHideMouseMoved(to: mid)
        check(!container.isOnScreen(.left), "鼠标离开后左区收回")
        container.autoHideMouseMoved(to: container.convert(NSPoint(x: container.bounds.maxX - 1, y: container.bounds.midY), to: nil))
        check(container.revealed == [.right], "鼠标到右边缘，右区浮出")
        container.autoHideMouseMoved(to: mid)
        check(container.revealed.isEmpty, "离开后收回")
        let beforeExit = dock.layout
        await fullScreen(first, container: container, on: false)
        check(container.isOnScreen(.left) && container.isOnScreen(.right) && dock.layout == beforeExit, "退出全屏后恢复原布局")
        check(isShown(DockPanels.bookshelf, in: .left, of: dock), "面板回到分栏中")

        // 留下一份特定布局供重启验证：左区上下分割、底部区高度 222、页面列表浮动。最后一项改动在去抖时间内退出，验证退出前保存。
        if dock.layout.left.style != .split { dock.toggleStyle(.left) }
        coordinator.beginDrag(DockPanels.pageList, from: dock)
        dock.drop(at: .area(.bottom, index: 0))
        coordinator.endDrag(DockPanels.pageList, at: .zero, accepted: true, cancelled: false)
        dock.resize(.bottom, to: 222)
        await settle()
        coordinator.float(DockPanels.pageList, from: dock, at: NSPoint(x: screen.midX, y: screen.midY))
        await settle()
        // 窗口的 frame 取整数点；用整数，重启后摆放时才不被 AppKit 改动。
        coordinator.floatingMoved(DockPanels.pageList, to: DockFrame(x: floor(screen.midX) - 130, y: floor(screen.midY) - 200, width: 260, height: 400))
        placeholder(dock.panels[DockPanels.bookshelf])?.setStyle(.grid)
        await settle()
        dock.resize(.left, to: 300)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(coordinator.current).write(to: expectedURL)
        } catch {
            check(false, "无法写入 expected.json：\(error)")
        }
        check(coordinator.current.left.style == .split && coordinator.current.left.size == 300 && coordinator.current.bottom.size == 222
              && coordinator.current.floating.map(\.panel) == [DockPanels.pageList], "最终布局：左区分割 300，底部 222，页面列表浮动：\(describe(coordinator.current))")
    }

    // MARK: restore

    private func runRestore() async {
        guard let first = app.controllers.first, let window = first.window else { return check(false, "没有窗口") }
        await settle()
        guard let data = try? Data(contentsOf: expectedURL), let expected = try? JSONDecoder().decode(DockLayout.self, from: data) else {
            return check(false, "读不到 expected.json")
        }
        check(coordinator.problem == nil, "没有错误提示")
        check(coordinator.current == expected, "layout.json 与退出前的布局相同")
        check(first.dock.layout == docked(expected), "窗口套用恢复的布局")
        let floating = coordinator.floatingWindows[DockPanels.pageList]
        let frame = expected.floating.first?.frame
        check(floating != nil && frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } == floating?.frame,
              "浮动面板恢复到原位置：\(String(describing: floating?.frame))")
        check(placeholder(first.dock.panels[DockPanels.bookshelf])?.settings.style == .grid, "书架的视图设置恢复为网格")
        check(first.dock.container.isOnScreen(.left) && abs(first.dock.container.areas[.left]!.frame.width - 300) < 1,
              "左区宽度恢复为 300：\(first.dock.container.areas[.left]!.frame.width)")
        snapshot(window, "restored")
    }

    // MARK: corrupt

    private func runCorrupt() async {
        guard let first = app.controllers.first, let window = first.window else { return check(false, "没有窗口") }
        let original = try? Data(contentsOf: coordinator.fileURL)
        for _ in 0..<40 where coordinator.problem == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await settle()
        check(coordinator.problem != nil, "显示错误：\(coordinator.problem.map { "\($0.title) / \($0.detail)" } ?? "nil")")
        check(first.dock.layout == docked(DockPanels.defaultLayout), "用默认布局打开")
        let banner = first.dock.container.subviews.compactMap { $0 as? FileErrorBanner }.first
        let left = first.dock.container.areas[.left]!
        check(banner != nil && banner!.frame.height > 0 && left.convert(left.bounds, to: first.dock.container).minY >= banner!.frame.maxY - 1,
              "窗口顶部显示错误提示条")
        snapshot(window, "corrupt")
        try? await Task.sleep(for: DockCoordinator.saveDelay + .milliseconds(300))
        check(original != nil && (try? Data(contentsOf: coordinator.fileURL)) == original, "没有改动布局时不覆盖改坏的文件")
    }

    // MARK: 工具

    private func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(message)")
    }

    private func finish(terminate: Bool) {
        print("SELFTEST \(failures == 0 ? "OK" : "FAILED \(failures)")")
        fflush(stdout)
        if terminate, failures == 0 {
            // 经 run loop 的定时器退出，与菜单的“退出”一样不在主队列的任务里：
            // applicationShouldTerminate 返回 terminateLater 后，保存布局的任务要在主队列上运行。
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } else {
            exit(Int32(failures))
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

    private func docked(_ layout: DockLayout) -> DockLayout {
        var layout = layout
        layout.floating = []
        return layout
    }

    private func placeholder(_ panel: (any DockPanel)?) -> PlaceholderPanel? {
        panel as? PlaceholderPanel
    }

    /// 面板视图在某个区里，并且在窗口中。
    private func isShown(_ panel: PanelID, in edge: DockEdge, of dock: WindowDock) -> Bool {
        guard let view = dock.panels[panel]?.view, view.window != nil else { return false }
        return view.isDescendant(of: dock.container.areas[edge]!) && dock.container.isOnScreen(edge)
    }

    /// 按容器坐标求放置位置（与拖动经过时相同），核对后放下。
    private func drop(_ panel: PanelID, from source: WindowDock?, into target: WindowDock, at point: NSPoint,
                      expect: DockTarget, _ message: String) async {
        let resolved = target.container.showDropIndicator(at: point)
        check(resolved == expect, "放置位置 \(message)：\(String(describing: resolved))")
        guard let resolved else { return }
        coordinator.beginDrag(panel, from: source)
        target.drop(at: resolved)
        coordinator.endDrag(panel, at: .zero, accepted: true, cancelled: false)
        target.container.hideDropIndicator()
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
    private func fullScreen(_ controller: ReaderWindowController, container: DockContainerView, on: Bool) async {
        guard let window = controller.window else { return }
        // App 未激活（屏幕锁定）时全屏过渡会停在半途：只发出 willEnter 通知，不完成。
        if NSApp.isActive, window.styleMask.contains(.fullScreen) != on {
            window.toggleFullScreen(nil)
            for _ in 0..<80 where window.styleMask.contains(.fullScreen) != on {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await settle()
        }
        if container.isAutoHiding != on {
            print("SKIP 真实全屏\(on ? "进入" : "退出")（App 未激活或切换未生效），改为直接调用窗口通知处理中的 setAutoHide")
            container.setAutoHide(on)
            await settle()
        }
    }

    private func snapshot(_ window: NSWindow, _ name: String) {
        guard let output else { return }
        SelfTest.snapshot(window, to: output.appendingPathComponent("\(name).png"))
    }
}
#endif
