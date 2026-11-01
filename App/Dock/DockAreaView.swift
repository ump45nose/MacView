import AppKit
import MVLayout

/// 细分隔线用设计稿的 line 色。
@MainActor
final class DockSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.line }

    /// 尺寸变化是否来自用户拖动（或双击）分隔线。通知里的分隔线序号不够：
    /// 分栏自己调整、程序设置位置时也会带上，所以还要求当前事件是这个窗口里的鼠标事件，且不在窗口缩放中。
    static func isUserDrag(_ notification: Notification) -> Bool {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil, let split = notification.object as? NSSplitView,
              !split.inLiveResize, let event = NSApp.currentEvent, event.window === split.window else { return false }
        return [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type)
    }
}

/// 一个停靠区的面板栈：标签页形式是一行标签加当前面板；上下分割时每个面板一格，各有标题。
///
/// 标签页行（或分割的第一格标题）右侧是两个按钮：标签页与上下分割互换、隐藏停靠区。
/// 面板视图由 WindowDock 持有，这里只摆放；同一视图移到别处时 AppKit 会把它从这里摘下。
@MainActor
final class DockAreaView: NSView, NSSplitViewDelegate {
    static let headerHeight: CGFloat = 30
    static let partHeaderHeight: CGFloat = 26

    struct Item {
        var type: DockPanelType
        var view: NSView
    }

    let edge: DockEdge
    weak var dock: WindowDock?
    private(set) var style: DockStackStyle = .tabs
    private(set) var items: [Item] = []
    private(set) var current: PanelID?
    private var weights: [PanelID: Double] = [:]
    private var tabs: [PanelID: DockTabView] = [:]
    private let split = DockSplitView()
    private var parts: [DockPartView] = []
    private let controls = NSStackView()
    private let styleButton: NSButton
    private let hideButton: NSButton
    private let headerLine = CALayer()
    private var needsWeights = false
    /// 程序设置分隔线位置时，通知里也带分隔线序号，不能当作用户拖动。
    private var isApplyingWeights = false

    init(edge: DockEdge) {
        self.edge = edge
        styleButton = Self.button(symbol: "rectangle.split.1x2")
        let hideSymbol = switch edge {
        case .left: "sidebar.left"
        case .right: "sidebar.right"
        case .bottom: "rectangle.bottomthird.inset.filled"
        }
        hideButton = Self.button(symbol: hideSymbol)
        hideButton.toolTip = String(localized: "隐藏停靠区")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(headerLine)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.autoresizingMask = [.width, .height]
        controls.orientation = .horizontal
        controls.spacing = 2
        controls.setViews([styleButton, hideButton], in: .trailing)
        styleButton.target = self
        styleButton.action = #selector(toggleStyle(_:))
        hideButton.target = self
        hideButton.action = #selector(hide(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func button(symbol: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = Theme.text2
        button.frame.size = CGSize(width: 22, height: 22)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        headerLine.backgroundColor = Theme.line.cgColor
    }

    func tab(_ panel: PanelID) -> DockTabView? {
        tabs[panel]
    }

    /// 摆放可见的面板。`current` 是标签页形式下显示的面板。
    func render(_ items: [Item], style: DockStackStyle, current: PanelID?, weights: [PanelID: Double]) {
        self.items = items
        self.style = style
        self.current = current
        self.weights = weights
        let ids = Set(items.map(\.type.id))
        tabs = tabs.filter { ids.contains($0.key) }
        for item in items where tabs[item.type.id] == nil {
            tabs[item.type.id] = makeTab(item.type)
        }
        let label = style == .tabs ? String(localized: "改为上下分割") : String(localized: "改为标签页")
        styleButton.toolTip = label
        styleButton.setAccessibilityLabel(label)
        styleButton.image = NSImage(systemSymbolName: style == .tabs ? "rectangle.split.1x2" : "rectangle.stack", accessibilityDescription: label)
        hideButton.setAccessibilityLabel(hideButton.toolTip)
        setAccessibilityLabel(Self.name(of: edge))

        subviews.forEach { $0.removeFromSuperview() }
        split.subviews.forEach { $0.removeFromSuperview() }
        parts = []
        switch style {
        case .tabs:
            headerLine.isHidden = false
            for item in items {
                let tab = tabs[item.type.id]!
                tab.isSelected = item.type.id == current
                addSubview(tab)
            }
            addSubview(controls)
            if let item = items.first(where: { $0.type.id == current }) {
                item.view.autoresizingMask = [.width, .height]
                addSubview(item.view)
            }
        case .split:
            headerLine.isHidden = true
            split.frame = bounds
            addSubview(split)
            for (index, item) in items.enumerated() {
                let tab = tabs[item.type.id]!
                tab.isSelected = false
                let part = DockPartView(tab: tab, content: item.view, controls: index == 0 ? controls : nil)
                parts.append(part)
                split.addSubview(part)
            }
            needsWeights = true
        }
        needsLayout = true
    }

    private func makeTab(_ type: DockPanelType) -> DockTabView {
        let tab = DockTabView(type: type)
        let panel = type.id
        tab.onSelect = { [weak self] in self?.dock?.select(panel) }
        tab.onDragBegan = { [weak self] in self?.dock?.beginDrag(panel) }
        tab.onDragEnded = { [weak self] point, accepted, cancelled in
            self?.dock?.endDrag(panel, at: point, accepted: accepted, cancelled: cancelled)
        }
        tab.contextMenu = { [weak self] in self?.dock?.menu(for: panel) }
        return tab
    }

    override func layout() {
        super.layout()
        switch style {
        case .tabs:
            let height = Self.headerHeight
            controls.frame = CGRect(x: bounds.width - 52, y: (height - 22) / 2, width: 48, height: 22)
            // 标签放不下时等分可用宽度。
            let available = max(bounds.width - 60 - 8, 0)
            let wanted = items.map { tabs[$0.type.id]!.fittingWidth }
            let total = wanted.reduce(0, +) + CGFloat(max(items.count - 1, 0)) * 2
            let scale = total > available && total > 0 ? available / total : 1
            var x: CGFloat = 8
            for (item, width) in zip(items, wanted) {
                let tab = tabs[item.type.id]!
                tab.frame = CGRect(x: x, y: 4, width: floor(width * scale), height: 22)
                x = tab.frame.maxX + 2
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            headerLine.frame = CGRect(x: 0, y: height - 0.5, width: bounds.width, height: 0.5)
            CATransaction.commit()
            if let item = items.first(where: { $0.type.id == current }) {
                item.view.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
            }
        case .split:
            split.frame = bounds
            if needsWeights, bounds.height > 0 {
                needsWeights = false
                applyWeights()
            }
        }
    }

    /// 按比例设置各格的高度。
    private func applyWeights() {
        isApplyingWeights = true
        defer { isApplyingWeights = false }
        guard parts.count > 1 else { return }
        split.adjustSubviews()
        let values = items.map { weights[$0.type.id] ?? 1 }
        let sum = values.reduce(0, +)
        let available = split.bounds.height - split.dividerThickness * CGFloat(parts.count - 1)
        var position: CGFloat = 0
        for index in 0..<(parts.count - 1) {
            position += available * values[index] / sum
            split.setPosition(position, ofDividerAt: index)
            position += split.dividerThickness
        }
    }

    // MARK: 放置

    /// 放到区内某一点时的位置（可见面板中的序号）与指示：标签行上是标签之间的竖线，
    /// 标签页形式的内容区是整个区（放在最后），上下分割时是格与格之间的横线。
    func dropTarget(at point: NSPoint) -> (index: Int, indicator: NSRect, isZone: Bool) {
        switch style {
        case .tabs:
            guard point.y < Self.headerHeight else { return (items.count, bounds, true) }
            let frames = items.map { tabs[$0.type.id]!.frame }
            let index = frames.filter { $0.midX < point.x }.count
            let x = index < frames.count ? frames[index].minX - 2 : (frames.last?.maxX ?? 8) + 1
            return (index, CGRect(x: x, y: 4, width: 2, height: 22), false)
        case .split:
            let frames = parts.map(\.frame)
            let index = frames.filter { $0.midY < point.y }.count
            let y = index < frames.count ? frames[index].minY : (frames.last?.maxY ?? 0)
            return (index, CGRect(x: 0, y: min(max(y - 2, 0), bounds.height - 4), width: bounds.width, height: 4), false)
        }
    }

    static func name(of edge: DockEdge) -> String {
        switch edge {
        case .left: String(localized: "左侧停靠区")
        case .right: String(localized: "右侧停靠区")
        case .bottom: String(localized: "底部停靠区")
        }
    }

    // MARK: 动作

    @objc private func toggleStyle(_ sender: Any?) {
        dock?.toggleStyle(edge)
    }

    @objc private func hide(_ sender: Any?) {
        dock?.toggleArea(edge)
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.subviews[dividerIndex].frame.minY + Self.partHeaderHeight + 40
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.subviews[dividerIndex + 1].frame.maxY - Self.partHeaderHeight - 40 - splitView.dividerThickness
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // 只记录用户拖动分隔线；程序设置位置时由标志排除。
        guard !isApplyingWeights, DockSplitView.isUserDrag(notification) else { return }
        var values: [PanelID: Double] = [:]
        for (item, part) in zip(items, parts) {
            values[item.type.id] = Double(part.frame.height)
        }
        weights.merge(values) { _, new in new }
        dock?.reweight(edge, values)
    }
}

/// 上下分割中的一格：标题（可拖动的标签）加面板内容；第一格的标题右侧放停靠区的按钮。
@MainActor
private final class DockPartView: NSView {
    private let tab: DockTabView
    private let content: NSView
    private let controls: NSView?
    private let line = CALayer()

    init(tab: DockTabView, content: NSView, controls: NSView?) {
        self.tab = tab
        self.content = content
        self.controls = controls
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        addSubview(tab)
        addSubview(content)
        if let controls { addSubview(controls) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        line.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        let height = DockAreaView.partHeaderHeight
        tab.frame = CGRect(x: 6, y: 2, width: min(tab.fittingWidth, bounds.width - 64), height: 22)
        controls?.frame = CGRect(x: bounds.width - 52, y: 2, width: 48, height: 22)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = CGRect(x: 0, y: height - 0.5, width: bounds.width, height: 0.5)
        CATransaction.commit()
        content.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}
