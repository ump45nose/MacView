import AppKit
import MVLayout

/// 浮动面板：全应用共享的 NSPanel，作用于当前活动窗口。
///
/// 标题条上是面板的标签和“停靠”按钮：拖动标签可以放进任一窗口的停靠区，放在别处则移动面板；
/// 标题条其余部分照常拖动窗口。关闭按钮隐藏面板，位置保留。
@MainActor
final class FloatingPanelWindow: NSPanel, NSWindowDelegate {
    static let headerHeight: CGFloat = 30

    let type: DockPanelType
    let panel: any DockPanel
    let panelTab: DockTabView
    private unowned let coordinator: DockCoordinator

    init(type: DockPanelType, panel: any DockPanel, coordinator: DockCoordinator) {
        self.type = type
        self.panel = panel
        self.coordinator = coordinator
        panelTab = DockTabView(type: type)
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
        panelTab.isSelected = true
        panelTab.onDragBegan = { [unowned coordinator] in coordinator.beginDrag(id, from: nil) }
        panelTab.onDragEnded = { [unowned coordinator] point, accepted, cancelled in
            coordinator.endDrag(id, at: point, accepted: accepted, cancelled: cancelled)
        }
        panelTab.contextMenu = { [weak self] in self?.makeMenu() }
        let dockButton = NSButton(
            image: NSImage(systemSymbolName: "rectangle.portrait.and.arrow.forward", accessibilityDescription: nil) ?? NSImage(),
            target: self, action: #selector(dockBack(_:))
        )
        dockButton.isBordered = false
        dockButton.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        dockButton.contentTintColor = Theme.text2
        dockButton.toolTip = String(localized: "停靠回窗口")
        dockButton.setAccessibilityLabel(dockButton.toolTip)
        contentView = FloatingContentView(tab: panelTab, button: dockButton, content: panel.view)
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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let id = type.id
        for edge in DockEdge.allCases {
            let title = switch edge {
            case .left: String(localized: "停靠到左侧")
            case .right: String(localized: "停靠到右侧")
            case .bottom: String(localized: "停靠到底部")
            }
            menu.addItem(MenuAction(title) { [unowned coordinator] in coordinator.dockFloating(id, to: edge) }.item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(String(localized: "隐藏")) { [unowned coordinator] in coordinator.closeFloating(id) }.item)
        return menu
    }

    @objc private func dockBack(_ sender: Any?) {
        coordinator.dockFloating(type.id, to: nil)
    }

    private var dockFrame: DockFrame {
        DockFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        coordinator.closeFloating(type.id)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        coordinator.floatingMoved(type.id, to: dockFrame)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        coordinator.floatingMoved(type.id, to: dockFrame)
    }
}

/// 浮动面板的内容：标题条（关闭按钮右侧是标签，右端是“停靠”按钮）加面板视图。
@MainActor
private final class FloatingContentView: NSView {
    private let tab: DockTabView
    private let button: NSButton
    private let content: NSView
    private let line = CALayer()

    init(tab: DockTabView, button: NSButton, content: NSView) {
        self.tab = tab
        self.button = button
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        addSubview(tab)
        addSubview(button)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        line.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        let height = FloatingPanelWindow.headerHeight
        let width = min(tab.fittingWidth, bounds.width - 60)
        tab.frame = CGRect(x: (bounds.width - width) / 2, y: (height - 22) / 2, width: width, height: 22)
        button.frame = CGRect(x: bounds.width - 30, y: (height - 22) / 2, width: 22, height: 22)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = CGRect(x: 0, y: height - 0.5, width: bounds.width, height: 0.5)
        CATransaction.commit()
        content.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}
