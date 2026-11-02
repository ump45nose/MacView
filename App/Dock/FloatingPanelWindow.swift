import AppKit
import MVLayout

/// 浮动面板：全应用共享的 NSPanel，作用于当前活动窗口。
///
/// 标题条上是面板的标签和“停靠”按钮：拖动标签可以放进任一窗口的停靠区，放在别处则移动面板；
/// 标题条其余部分照常拖动窗口。关闭按钮隐藏面板，位置保留。
@MainActor
final class FloatingPanelWindow: NSPanel, NSWindowDelegate {
    let type: DockPanelType
    let panel: any DockPanel
    private unowned let coordinator: DockCoordinator

    init(type: DockPanelType, panel: any DockPanel, coordinator: DockCoordinator) {
        self.type = type
        self.panel = panel
        self.coordinator = coordinator
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        title = type.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        // 也能浮在全屏窗口之上。
        collectionBehavior = [.fullScreenAuxiliary]
        minSize = NSSize(width: 200, height: 160)
        backgroundColor = Theme.ground
        delegate = self

        let id = type.id
        let tab = DockTabView(type: type)
        tab.isSelected = true
        tab.onDragBegan = { [unowned coordinator] in coordinator.beginDrag(id, from: nil) }
        tab.onDragEnded = { [unowned coordinator] point, accepted, cancelled in
            coordinator.endDrag(id, at: point, accepted: accepted, cancelled: cancelled)
        }
        tab.contextMenu = { [unowned coordinator] in coordinator.menu(for: id, in: nil) }
        let dockButton = NSButton(
            image: NSImage(systemSymbolName: "rectangle.portrait.and.arrow.forward", accessibilityDescription: nil) ?? NSImage(),
            target: self, action: #selector(dockBack(_:))
        )
        dockButton.isBordered = false
        dockButton.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        dockButton.contentTintColor = Theme.text2
        dockButton.toolTip = String(localized: "停靠回窗口")
        dockButton.setAccessibilityLabel(dockButton.toolTip)
        dockButton.frame.size = CGSize(width: 22, height: 22)
        contentView = PanelFrameView(tab: tab, content: panel.view, accessory: dockButton, isFloating: true)
    }

    /// 按布局中的 frame 摆放；与当前位置相同时不动。
    func place(_ frame: DockFrame) {
        let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if self.frame != rect { setFrame(rect, display: true) }
    }

    /// 不再浮动：摘下面板视图后关闭。
    func dismiss() {
        panel.view.removeFromSuperview()
        delegate = nil
        close()
    }

    @objc private func dockBack(_ sender: Any?) {
        coordinator.dockFloating(type.id)
    }

    private var dockFrame: DockFrame {
        DockFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator.togglePanel(type, in: nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        coordinator.floatingMoved(type.id, to: dockFrame)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        coordinator.floatingMoved(type.id, to: dockFrame)
    }
}
