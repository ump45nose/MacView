import AppKit
import MVFoundation
import MVLayout
import MVSettings
import os

/// 全应用的停靠协调者：保存 layout.json、管理共享的浮动面板、在窗口之间移动面板。
///
/// - 每个窗口有自己的停靠区（`WindowDock.dockLayout`）；浮动面板全应用共享，作用于当前活动窗口。
/// - `current` 是最近一次改动后的完整布局：新窗口套用它的停靠区，它也是去抖后写进 layout.json 的内容。
/// - 变换都经 `perform` 或 `commit`：先算出新布局，再让涉及的窗口和浮动面板跟上。
///   面板离开一处时实例先放进 `pool`，同一轮里移到别处时取回，视图和状态保留。
@MainActor
final class DockCoordinator {
    struct Problem: Equatable {
        var title: String
        var detail: String
    }

    static let layoutFileKey = "MVLayoutFile"
    static let saveDelay: Duration = .milliseconds(500)

    let fileURL: URL
    private let store: JSONDocumentStore<DockLayout>?
    private(set) var current: DockLayout
    private(set) var docks: [WindowDock] = []
    private(set) weak var active: WindowDock?
    private(set) var floatingWindows: [PanelID: FloatingPanelWindow] = [:]
    private(set) var drag: (panel: PanelID, source: WindowDock?)?
    private(set) var problem: Problem? {
        didSet { docks.forEach { $0.showProblem(problem) } }
    }
    private var pool: [PanelID: any DockPanel] = [:]
    private var saveTask: Task<Void, Never>?
    private var observeTask: Task<Void, Never>?
    private let logger = Logger(category: "dock")

    /// `~/Library/Application Support/MacView/layout.json`；自检用 `-MVLayoutFile <路径>` 换成临时文件。
    static func defaultFileURL() -> URL {
        if let path = UserDefaults.standard.string(forKey: layoutFileKey) { return URL(fileURLWithPath: path) }
        return URL.applicationSupportDirectory.appending(path: "MacView/layout.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let known = Set(DockPanels.all.map(\.id))
        do {
            let store = try JSONDocumentStore(fileURL: fileURL, version: 1, defaultValue: DockPanels.defaultLayout)
            self.store = store
            // 解析失败时 store 给出默认值，错误经 changes 报告。
            current = store.value().sanitized(knownPanels: known)
        } catch {
            store = nil
            current = DockPanels.defaultLayout
            problem = Problem(
                title: String(localized: "无法打开 layout.json"),
                detail: ErrorText.describe(error) + "\n" + String(localized: "停靠布局不会保存。")
            )
        }
        observeTask = Task { [weak self, store = self.store] in
            guard let store else { return }
            for await change in store.changes() {
                self?.documentChanged(change)
            }
        }
    }

    private func documentChanged(_ change: DocumentChange) {
        switch change {
        case let .fileError(message):
            logger.error("layout.json：\(message, privacy: .public)")
            problem = Problem(
                title: String(localized: "layout.json 无法解析，已改用默认布局"),
                detail: message + "\n" + String(localized: "调整布局后会覆盖这个文件。")
            )
        case .reloaded:
            // 文件已可用（本程序写入或外部修好）。外部修改不套用到已打开的窗口，新窗口会读到它。
            problem = nil
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: 窗口

    /// 窗口就绪：套用默认布局（`current` 的停靠区）。
    func attach(_ dock: WindowDock, to owner: ReaderWindowController) {
        dock.owner = owner
        docks.append(dock)
        dock.showProblem(problem)
        commit([(dock, current)], current: current, save: false)
        if active == nil { activate(dock) }
    }

    /// 恢复会话：这个窗口用保存的布局，浮动面板不动。
    func restore(_ dock: WindowDock, layout: DockLayout) {
        let known = Set(DockPanels.all.map(\.id))
        commit([(dock, layout.sanitized(knownPanels: known).adoptingFloating(of: current))], current: current, save: false)
    }

    func detach(_ dock: WindowDock) {
        docks.removeAll { $0 === dock }
        dock.detach()
        pool.removeAll()
        if active === dock || active == nil {
            active = nil
            if let next = docks.last { activate(next) } else { syncFloating() }
        }
    }

    /// 活动窗口改变：浮动面板改为作用于它。
    func activate(_ dock: WindowDock) {
        active = dock
        for window in floatingWindows.values { window.panel.bind(to: dock.owner) }
        syncFloating()
    }

    // MARK: 变换

    /// 在一个窗口（nil 时只涉及浮动面板）上变换布局。
    func perform(in dock: WindowDock?, render: Bool = true, _ transform: (DockLayout) -> DockLayout) {
        let base = layout(of: dock)
        let next = transform(base)
        guard next != base else { return }
        commit(dock.map { [($0, next)] } ?? [], current: next, render: render)
    }

    /// 让各窗口与浮动面板跟上新布局，并去抖保存。`updates` 中的窗口按顺序套用（跨窗口移动时先源后目标）。
    private func commit(_ updates: [(WindowDock, DockLayout)], current next: DockLayout, render: Bool = true, save: Bool = true) {
        let floatingChanged = next.floating.map(\.panel) != current.floating.map(\.panel)
        current = next
        let floating = Set(next.floating.map(\.panel))
        for (id, window) in floatingWindows where !floating.contains(id) {
            floatingWindows[id] = nil
            pool[id] = window.panel
            window.dismiss()
        }
        for (dock, layout) in updates {
            dock.apply(Self.docked(layout), render: render)
        }
        if floatingChanged {
            for dock in docks where !updates.contains(where: { $0.0 === dock }) {
                let adopted = Self.docked(dock.dockLayout.adoptingFloating(of: next))
                if adopted != dock.dockLayout { dock.apply(adopted, render: true) }
            }
        }
        syncFloating()
        pool.removeAll()
        if save { scheduleSave() }
    }

    /// 窗口（nil 时为最近一次改动后）的停靠区，加上共享的浮动面板。
    private func layout(of dock: WindowDock?) -> DockLayout {
        var layout = dock?.dockLayout ?? current
        layout.floating = current.floating
        return layout
    }

    /// 去掉浮动面板，即窗口自己的停靠区。
    static func docked(_ layout: DockLayout) -> DockLayout {
        var layout = layout
        layout.floating = []
        return layout
    }

    // MARK: 面板实例

    func release(_ panel: any DockPanel, id: PanelID) {
        if pool[id] == nil { pool[id] = panel }
    }

    /// 本轮中刚离开别处的实例，或者按视图设置新建；设置无法解码时用默认设置，并显示错误。
    /// 面板作用于 `dock`，nil 时是浮动面板，作用于活动窗口；视图设置的改动记进同一处。
    func obtain(_ id: PanelID, settings: JSONValue?, for dock: WindowDock?) -> (any DockPanel)? {
        guard let type = DockPanels.type(id) else { return nil }
        let panel: any DockPanel
        if let pooled = pool.removeValue(forKey: id) {
            panel = pooled
        } else {
            let made = type.instantiate(settings)
            panel = made.panel
            if let error = made.error {
                logger.error("面板 \(id.rawValue, privacy: .public) 的视图设置无效：\(String(describing: error), privacy: .public)")
                problem = Problem(
                    title: String(localized: "layout.json 中“\(type.title)”的视图设置无效"),
                    detail: String(describing: error) + "\n" + String(localized: "已改用默认设置。")
                )
            }
        }
        panel.onSettingsChange = { [weak self, weak dock, weak panel] in
            guard let self, let panel else { return }
            perform(in: dock, render: false) { $0.settingSettings(panel.encodedSettings(), for: id) }
        }
        panel.bind(to: (dock ?? active)?.owner)
        return panel
    }

    // MARK: 浮动面板

    private func syncFloating() {
        for item in current.floating {
            let window: FloatingPanelWindow
            if let existing = floatingWindows[item.panel] {
                window = existing
            } else {
                guard let type = DockPanels.type(item.panel), let panel = obtain(item.panel, settings: item.settings, for: nil) else { continue }
                window = FloatingPanelWindow(type: type, panel: panel, coordinator: self)
                floatingWindows[item.panel] = window
            }
            window.place(item.frame)
            let visible = !item.isHidden && active != nil
            if visible, !window.isVisible { window.orderFront(nil) }
            if !visible, window.isVisible { window.orderOut(nil) }
        }
    }

    func floatingMoved(_ panel: PanelID, to frame: DockFrame) {
        perform(in: nil, render: false) { $0.movingFloating(panel, to: frame) }
    }

    /// 浮动面板停靠回活动窗口中原来的区。
    func dockFloating(_ panel: PanelID) {
        guard let dock = active else { return }
        perform(in: dock) { $0.docking(panel) }
    }

    /// 停靠的面板拖出或经菜单成为浮动面板。`screenPoint` 是放下的位置，nil 时放在原来的区旁边。
    func float(_ panel: PanelID, from dock: WindowDock, at screenPoint: NSPoint?) {
        guard case let .docked(edge, _) = dock.dockLayout.placement(of: panel) else { return }
        let area = dock.dockLayout[edge]
        let size = edge == .bottom
            ? CGSize(width: 420, height: max(area.size, 200) + 28)
            : CGSize(width: max(area.size, 220), height: 400)
        let origin: CGPoint
        if let screenPoint {
            origin = CGPoint(x: screenPoint.x - 40, y: screenPoint.y - size.height + 14)
        } else {
            let view = dock.areas[edge]!
            let screen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
            origin = CGPoint(x: screen.minX + 40, y: screen.maxY - size.height - 40)
        }
        let frame = DockFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
        perform(in: dock) { $0.moving(panel, to: .floating(frame)) }
    }

    // MARK: 拖放

    func beginDrag(_ panel: PanelID, from dock: WindowDock?) {
        drag = (panel, dock)
    }

    /// 放进某个窗口的停靠区。来源是另一个窗口时，面板连同视图设置和实例从源窗口移过来；
    /// 目标窗口原来也停靠着它时，原来的实例让位（先摘下，再放入源窗口的实例）。
    func drop(into target: WindowDock, at destination: DockTarget) {
        guard let (panel, source) = drag else { return }
        guard let source, source !== target else {
            perform(in: target) { $0.moving(panel, to: destination) }
            return
        }
        let sourceLayout = layout(of: source)
        let targetLayout = layout(of: target)
        let inserted = targetLayout.inserting(panel, at: destination, settings: sourceLayout.settings(of: panel))
        commit([(source, sourceLayout.removing(panel)), (target, targetLayout.removing(panel)), (target, inserted)], current: inserted)
    }

    /// 拖动结束而没有停靠区接收：停靠的面板变成浮动面板，浮动面板移到放下的位置。
    func endDrag(_ panel: PanelID, at screenPoint: NSPoint, accepted: Bool, cancelled: Bool) {
        defer { drag = nil }
        guard let drag, drag.panel == panel, !accepted, !cancelled else { return }
        if let source = drag.source {
            float(panel, from: source, at: screenPoint)
        } else if case let .floating(index) = current.placement(of: panel) {
            var frame = current.floating[index].frame
            (frame.x, frame.y) = (screenPoint.x - 40, screenPoint.y - frame.height + 14)
            perform(in: nil) { $0.movingFloating(panel, to: frame) }
        }
    }

    // MARK: 命令与菜单

    /// 停靠的面板在所在窗口中切换；浮动面板全应用切换（也是浮动面板的关闭按钮：隐藏，位置保留）。
    func togglePanel(_ type: DockPanelType, in dock: WindowDock?) {
        if case .floating = current.placement(of: type.id) {
            perform(in: nil) { $0.togglingPanel(type.id, defaultEdge: type.defaultEdge) }
        } else if let dock {
            perform(in: dock) { $0.togglingPanel(type.id, defaultEdge: type.defaultEdge) }
        }
    }

    /// 标签的右键菜单。停靠的面板（`dock` 是所在窗口）：移到其他区、浮动、隐藏；浮动面板：停靠到活动窗口的各区、隐藏。
    func menu(for panel: PanelID, in dock: WindowDock?) -> NSMenu {
        let menu = NSMenu()
        let current: DockEdge? = if case let .docked(edge, _) = dock?.dockLayout.placement(of: panel) { edge } else { nil }
        for edge in DockEdge.allCases where edge != current {
            let title = switch (edge, dock == nil) {
            case (.left, false): String(localized: "移到左侧")
            case (.right, false): String(localized: "移到右侧")
            case (.bottom, false): String(localized: "移到底部")
            case (.left, true): String(localized: "停靠到左侧")
            case (.right, true): String(localized: "停靠到右侧")
            case (.bottom, true): String(localized: "停靠到底部")
            }
            menu.addItem(MenuAction(title) { [weak self, weak dock] in
                guard let self, let target = dock ?? active else { return }
                perform(in: target) { $0.moving(panel, to: .area(edge, index: $0.visiblePanels(in: edge).count)) }
            }.item)
        }
        if let dock {
            menu.addItem(MenuAction(String(localized: "浮动")) { [weak self, weak dock] in
                guard let self, let dock else { return }
                float(panel, from: dock, at: nil)
            }.item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(String(localized: "隐藏")) { [weak self, weak dock] in
            guard let self, let type = DockPanels.type(panel) else { return }
            togglePanel(type, in: dock)
        }.item)
        return menu
    }

    // MARK: 保存

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            await write()
        }
    }

    /// 退出前调用：有待保存的改动时立即写入。
    func flush() async {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        await write()
    }

    private func write() async {
        guard let store else { return }
        let value = current
        do {
            try await store.update { $0 = value }
        } catch {
            logger.error("无法保存 layout.json：\(String(describing: error), privacy: .public)")
            problem = Problem(title: String(localized: "无法保存 layout.json"), detail: ErrorText.describe(error))
        }
    }
}

/// 用闭包作动作的菜单项；菜单项持有它。
@MainActor
final class MenuAction: NSObject {
    private let action: () -> Void
    let item: NSMenuItem

    init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        super.init()
        item.target = self
        item.representedObject = self
    }

    @objc private func run(_ sender: Any?) {
        action()
    }
}
