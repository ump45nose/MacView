import AppKit
import MVLayout

/// 一个窗口的停靠布局与其中停靠的面板实例。界面上的操作都交给 DockCoordinator 变换布局，再由它调用 `apply`。
@MainActor
final class WindowDock {
    let container: DockContainerView
    unowned let coordinator: DockCoordinator
    private(set) weak var owner: ReaderWindowController?
    /// 本窗口的停靠区；`floating` 总是空的，浮动面板以 `DockCoordinator.current` 为准。
    private(set) var layout: DockLayout
    private(set) var panels: [PanelID: any DockPanel] = [:]
    private var bannerKey: String?

    init(coordinator: DockCoordinator, mainView: NSView) {
        self.coordinator = coordinator
        layout = DockPanels.defaultLayout
        container = DockContainerView(mainView: mainView)
        container.dock = self
    }

    func attach(to owner: ReaderWindowController) {
        self.owner = owner
    }

    /// 换成新的布局：不再停靠的面板交还给协调者，新停靠的面板向它取实例。`render` 为 false 时界面已经是这个样子（拖动分隔线）。
    func apply(_ next: DockLayout, render: Bool) {
        layout = next
        let docked = Set(DockEdge.allCases.flatMap { next[$0].panels })
        for (id, panel) in panels where !docked.contains(id) {
            panels[id] = nil
            coordinator.release(panel, id: id)
        }
        for id in docked where panels[id] == nil {
            guard let panel = coordinator.obtain(id, settings: next.settings(of: id)) else { continue }
            panel.onSettingsChange = { [weak self, weak panel] in
                guard let self, let panel else { return }
                coordinator.perform(in: self, render: false) { $0.settingSettings(panel.encodedSettings(), for: id) }
            }
            panel.bind(to: owner)
            panels[id] = panel
        }
        guard render else {
            container.noteLayout(next)
            return
        }
        var items: [DockEdge: [DockAreaView.Item]] = [:]
        for edge in DockEdge.allCases {
            items[edge] = next.visiblePanels(in: edge).compactMap { id in
                guard let type = DockPanels.type(id), let panel = panels[id] else { return nil }
                return DockAreaView.Item(type: type, view: panel.view)
            }
        }
        container.render(next, items: items)
    }

    /// 窗口关闭：交还所有面板。
    func detach() {
        for (id, panel) in panels { coordinator.release(panel, id: id) }
        panels = [:]
    }

    func showError(_ error: DockCoordinator.Problem?) {
        let key = error.map { $0.title + $0.detail }
        guard key != bannerKey else { return }
        bannerKey = key
        container.setBanner(error.map { error in
            FileErrorBanner(title: error.title, detail: error.detail, fileURL: coordinator.fileURL) { [weak self] in
                self?.coordinator.dismissProblem()
            }
        })
    }

    // MARK: 界面操作

    func select(_ panel: PanelID) {
        coordinator.perform(in: self) { $0.selecting(panel) }
    }

    func toggleStyle(_ edge: DockEdge) {
        coordinator.perform(in: self) { $0.togglingStyle(edge) }
    }

    func toggleArea(_ edge: DockEdge) {
        coordinator.perform(in: self) { $0.togglingArea(edge) }
    }

    func collapse(_ edge: DockEdge) {
        coordinator.perform(in: self) { $0.settingCollapsed(edge, true) }
    }

    func resize(_ edge: DockEdge, to size: Double) {
        coordinator.perform(in: self, render: false) { $0.resizing(edge, to: size) }
    }

    func reweight(_ edge: DockEdge, _ weights: [PanelID: Double]) {
        coordinator.perform(in: self, render: false) { $0.reweighting(edge, weights) }
    }

    var draggedPanel: PanelID? {
        coordinator.drag?.panel
    }

    func beginDrag(_ panel: PanelID) {
        coordinator.beginDrag(panel, from: self)
    }

    func endDrag(_ panel: PanelID, at screenPoint: NSPoint, accepted: Bool, cancelled: Bool) {
        coordinator.endDrag(panel, at: screenPoint, accepted: accepted, cancelled: cancelled)
    }

    func drop(at target: DockTarget) {
        coordinator.drop(into: self, at: target)
    }

    /// 标签的右键菜单：移到其他区、浮动、隐藏。
    func menu(for panel: PanelID) -> NSMenu {
        let menu = NSMenu()
        let current: DockEdge? = if case let .docked(edge, _) = layout.placement(of: panel) { edge } else { nil }
        for edge in DockEdge.allCases where edge != current {
            let title = switch edge {
            case .left: String(localized: "移到左侧")
            case .right: String(localized: "移到右侧")
            case .bottom: String(localized: "移到底部")
            }
            menu.addItem(MenuAction(title) { [weak self] in
                guard let self else { return }
                coordinator.perform(in: self) { $0.moving(panel, to: .area(edge, index: $0.visiblePanels(in: edge).count)) }
            }.item)
        }
        menu.addItem(MenuAction(String(localized: "浮动")) { [weak self] in
            guard let self else { return }
            coordinator.float(panel, from: self, at: nil)
        }.item)
        menu.addItem(.separator())
        menu.addItem(MenuAction(String(localized: "隐藏")) { [weak self] in
            guard let self, let type = DockPanels.type(panel) else { return }
            coordinator.togglePanel(type, in: self)
        }.item)
        return menu
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
