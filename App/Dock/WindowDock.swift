import AppKit
import MVLayout

/// 一个窗口的停靠：本窗口的布局、其中停靠的面板实例，以及显示它们的容器视图。
///
/// - NSSplitView 分出左、中、右三栏，底部区在中间栏下方，中间是主视图。左右区与底部区的尺寸由用户拖动分隔线改变；
///   窗口缩放时只改变主视图。拖到边缘时区折叠。
/// - 拖动面板时整个视图是放置目标：落在区内是区里的位置，落在没有显示的区所在的边缘是那个区。
/// - 全屏时区自动隐藏，鼠标到左、右、下边缘时浮在主视图上，离开后收回。
/// - 界面上的操作都经 `perform` 交给 DockCoordinator 变换布局，再由它调用 `apply`。
@MainActor
final class WindowDock: NSView, NSSplitViewDelegate {
    static let minimumSize: [DockEdge: CGFloat] = [.left: 160, .right: 160, .bottom: 90]
    static let minimumMain = CGSize(width: 240, height: 160)
    /// 没有显示的区在边缘的放置范围。
    static let edgeZone: CGFloat = 48
    /// 全屏时鼠标离边缘多近浮出。
    static let revealDistance: CGFloat = 4

    unowned let coordinator: DockCoordinator
    /// 所在的阅读窗口，由协调者在窗口就绪时设置。
    weak var owner: ReaderWindowController?
    /// 本窗口的停靠区；`floating` 总是空的，浮动面板以 `DockCoordinator.current` 为准。
    private(set) var dockLayout = DockPanels.defaultLayout { didSet { onLayoutChange?() } }
    /// 窗口控制器用它同步工具栏的停靠区开关。
    var onLayoutChange: (() -> Void)?
    private(set) var panels: [PanelID: any DockPanel] = [:]
    private(set) var areas: [DockEdge: DockAreaView] = [:]
    private let mainView: NSView
    private var hosts: [DockEdge: NSView] = [:]
    private let outer = DockSplitView()
    private let center = DockSplitView()
    private let indicator = DropIndicatorView()
    private var problem: DockCoordinator.Problem?
    private var banner: FileErrorBanner?
    private var needsSizes = false
    /// 程序设置分隔线位置时，通知里也带分隔线序号，不能当作用户拖动。
    private var isApplyingSizes = false
    private var dropTarget: DockTarget?
    private(set) var isAutoHiding = false
    private(set) var revealed: Set<DockEdge> = []
    private var monitor: Any?

    init(coordinator: DockCoordinator, mainView: NSView) {
        self.coordinator = coordinator
        self.mainView = mainView
        super.init(frame: .zero)
        outer.isVertical = true
        center.isVertical = false
        for split in [outer, center] {
            split.dividerStyle = .thin
            split.delegate = self
        }
        for edge in DockEdge.allCases {
            let host = NSView()
            let area = DockAreaView(edge: edge, dock: self)
            area.autoresizingMask = [.width, .height]
            host.addSubview(area)
            host.isHidden = true
            hosts[edge] = host
            areas[edge] = area
        }
        mainView.translatesAutoresizingMaskIntoConstraints = true
        outer.addSubview(hosts[.left]!)
        outer.addSubview(center)
        outer.addSubview(hosts[.right]!)
        center.addSubview(mainView)
        center.addSubview(hosts[.bottom]!)
        addSubview(outer)
        addSubview(indicator)
        indicator.isHidden = true
        registerForDraggedTypes([.dockPanel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 在本窗口上变换布局。`render` 为 false 时界面已经是这个样子（拖动分隔线、改视图设置）。
    func perform(render: Bool = true, _ transform: (DockLayout) -> DockLayout) {
        coordinator.perform(in: self, render: render, transform)
    }

    // MARK: 布局与面板实例

    /// 换成新的布局：不再停靠的面板交还给协调者，新停靠的面板向它取实例，再摆放各区。
    func apply(_ next: DockLayout, render: Bool) {
        dockLayout = next
        let docked = Set(DockEdge.allCases.flatMap { next[$0].panels })
        for (id, panel) in panels where !docked.contains(id) {
            panels[id] = nil
            coordinator.release(panel, id: id)
        }
        for id in docked where panels[id] == nil {
            panels[id] = coordinator.obtain(id, settings: next.settings(of: id), for: self)
        }
        guard render else { return }
        for edge in DockEdge.allCases {
            areas[edge]!.render()
            if revealed.contains(edge), !next.isShowing(edge) { conceal(edge) }
        }
        updateVisibility()
    }

    /// 窗口关闭：交还所有面板。
    func detach() {
        for (id, panel) in panels { coordinator.release(panel, id: id) }
        panels = [:]
    }

    /// 区是否占据分栏：显示中，并且不在全屏自动隐藏状态。
    private func updateVisibility() {
        for edge in DockEdge.allCases {
            hosts[edge]!.isHidden = isAutoHiding || !dockLayout.isShowing(edge)
        }
        isApplyingSizes = true
        outer.adjustSubviews()
        center.adjustSubviews()
        isApplyingSizes = false
        needsSizes = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = banner?.frame.maxY ?? 0
        outer.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
        if needsSizes, outer.bounds.width > 0 {
            needsSizes = false
            applySizes()
        }
        for edge in revealed {
            areas[edge]!.frame = revealFrame(edge)
        }
    }

    /// 按布局设置分隔线位置；主视图至少保留最小尺寸。
    private func applySizes() {
        isApplyingSizes = true
        defer { isApplyingSizes = false }
        outer.layoutSubtreeIfNeeded()
        let thickness = outer.dividerThickness
        let width = outer.bounds.width
        // 读取时不低于最小尺寸：文件里保存的 0 也能显示，布局本身不改。
        let left = hosts[.left]!.isHidden ? 0 : max(dockLayout.left.size, Self.minimumSize[.left]!)
        let right = hosts[.right]!.isHidden ? 0 : max(dockLayout.right.size, Self.minimumSize[.right]!)
        let room = max(width - Self.minimumMain.width - 2 * thickness, 0)
        let scale = left + right > room && left + right > 0 ? room / (left + right) : 1
        if !hosts[.left]!.isHidden {
            outer.setPosition(floor(left * scale), ofDividerAt: 0)
        }
        if !hosts[.right]!.isHidden {
            outer.setPosition(width - floor(right * scale) - thickness, ofDividerAt: 1)
        }
        if !hosts[.bottom]!.isHidden {
            let height = center.bounds.height
            let bottom = min(max(dockLayout.bottom.size, Self.minimumSize[.bottom]!), max(height - Self.minimumMain.height - thickness, 0))
            center.setPosition(height - floor(bottom) - thickness, ofDividerAt: 0)
        }
    }

    // MARK: 错误提示

    /// 在窗口顶部显示（或去掉）配置文件的错误提示条。
    func showProblem(_ problem: DockCoordinator.Problem?) {
        guard problem != self.problem else { return }
        self.problem = problem
        banner?.removeFromSuperview()
        banner = problem.map { problem in
            FileErrorBanner(title: problem.title, detail: problem.detail, fileURL: coordinator.fileURL) { [weak self] in
                self?.coordinator.dismissProblem()
            }
        }
        if let banner {
            banner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(banner)
            NSLayoutConstraint.activate([
                banner.leadingAnchor.constraint(equalTo: leadingAnchor),
                banner.trailingAnchor.constraint(equalTo: trailingAnchor),
                banner.topAnchor.constraint(equalTo: topAnchor),
            ])
        }
        needsLayout = true
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // 窗口缩放时只改变中间栏（和其中的主视图）。
        view === center || view === mainView
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        hosts.values.contains(subview)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === center { return Self.minimumMain.height }
        if index == 0 { return Self.minimumSize[.left]! }
        let left = hosts[.left]!.isHidden ? 0 : hosts[.left]!.frame.width + outer.dividerThickness
        return left + Self.minimumMain.width
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        let thickness = splitView.dividerThickness
        if splitView === center { return splitView.bounds.height - Self.minimumSize[.bottom]! - thickness }
        if index == 1 { return splitView.bounds.width - Self.minimumSize[.right]! - thickness }
        let right = hosts[.right]!.isHidden ? 0 : hosts[.right]!.frame.width + thickness
        return splitView.bounds.width - right - Self.minimumMain.width - thickness
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // 只记录用户拖动分隔线；程序设置位置时由标志排除。
        guard !isApplyingSizes, !isAutoHiding, DockSplitView.isUserDrag(notification),
              let splitView = notification.object as? NSSplitView else { return }
        let edges: [DockEdge] = splitView === center ? [.bottom] : [.left, .right]
        for edge in edges where dockLayout.isShowing(edge) {
            let host = hosts[edge]!
            if splitView.isSubviewCollapsed(host) {
                perform { $0.settingCollapsed(edge, true) }
            } else {
                let size = Double(edge == .bottom ? host.frame.height : host.frame.width)
                perform(render: false) { $0.resizing(edge, to: size) }
            }
        }
    }

    // MARK: 放置

    /// 本视图坐标中一点对应的放置位置与指示范围。
    func dropTarget(at point: NSPoint) -> (target: DockTarget, indicator: NSRect, label: String?)? {
        for edge in DockEdge.allCases {
            let area = areas[edge]!
            guard isOnScreen(edge) else { continue }
            let frame = area.convert(area.bounds, to: self)
            guard frame.contains(point) else { continue }
            let result = area.dropTarget(at: area.convert(point, from: self))
            return (.area(edge, index: result.index), area.convert(result.indicator, to: self),
                    result.isZone ? Self.dropLabel(edge) : nil)
        }
        let content = outer.frame
        let centerFrame = center.convert(center.bounds, to: self)
        for edge in DockEdge.allCases where !isOnScreen(edge) {
            // 底部区只占中间栏的宽度。
            let span = edge == .bottom
                ? CGRect(x: centerFrame.minX, y: content.minY, width: centerFrame.width, height: content.height)
                : content
            guard Self.strip(edge, Self.edgeZone, of: span).contains(point) else { continue }
            let length = edge == .bottom ? content.height : content.width
            let shown = Self.strip(edge, min(CGFloat(dockLayout[edge].size), length / 3), of: span)
            return (.area(edge, index: dockLayout.visiblePanels(in: edge).count), shown, Self.dropLabel(edge))
        }
        return nil
    }

    /// `rect` 中靠 `edge` 一侧、厚为 `thickness` 的条。
    private static func strip(_ edge: DockEdge, _ thickness: CGFloat, of rect: NSRect) -> NSRect {
        switch edge {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height)
        case .right: CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height)
        case .bottom: CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness)
        }
    }

    /// 区是否在屏幕上：在分栏中显示，或者全屏时浮出。
    func isOnScreen(_ edge: DockEdge) -> Bool {
        revealed.contains(edge) || (!isAutoHiding && !hosts[edge]!.isHidden)
    }

    private static func dropLabel(_ edge: DockEdge) -> String {
        switch edge {
        case .left: String(localized: "放到左侧")
        case .right: String(localized: "放到右侧")
        case .bottom: String(localized: "放到底部")
        }
    }

    /// 显示放置指示；自检也用它。
    @discardableResult
    func showDropIndicator(at point: NSPoint) -> DockTarget? {
        guard let result = dropTarget(at: point) else {
            hideDropIndicator()
            return nil
        }
        indicator.show(result.indicator, label: result.label)
        dropTarget = result.target
        return result.target
    }

    func hideDropIndicator() {
        indicator.isHidden = true
        dropTarget = nil
    }

    private func dragOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard coordinator.drag != nil else { return [] }
        return showDropIndicator(at: convert(sender.draggingLocation, from: nil)) == nil ? [] : .move
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hideDropIndicator()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let target = dropTarget else { return false }
        hideDropIndicator()
        coordinator.drop(into: self, at: target)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        hideDropIndicator()
    }

    // MARK: 全屏自动隐藏

    func setAutoHide(_ enabled: Bool) {
        guard enabled != isAutoHiding else { return }
        isAutoHiding = enabled
        if enabled {
            window?.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                if let self, event.window === self.window { self.autoHideMouseMoved(to: event.locationInWindow) }
                return event
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            revealed.forEach(conceal)
        }
        updateVisibility()
    }

    /// 全屏时鼠标移动（窗口坐标）：到边缘时浮出对应的区，离开浮出的区后收回。
    func autoHideMouseMoved(to windowPoint: NSPoint) {
        guard isAutoHiding else { return }
        let point = convert(windowPoint, from: nil)
        for edge in revealed where !concealRegion(edge).contains(point) && NSEvent.pressedMouseButtons == 0 {
            conceal(edge)
        }
        for edge in DockEdge.allCases where dockLayout.isShowing(edge) && !revealed.contains(edge) {
            let near = switch edge {
            case .left: point.x <= Self.revealDistance
            case .right: point.x >= bounds.width - Self.revealDistance
            // 底边是窗口底边（状态栏下沿），不是本视图的底边。
            case .bottom: windowPoint.y <= Self.revealDistance
            }
            if near { reveal(edge) }
        }
    }

    private func revealFrame(_ edge: DockEdge) -> NSRect {
        let content = outer.frame
        let length = edge == .bottom ? content.height : content.width
        return Self.strip(edge, min(CGFloat(dockLayout[edge].size), length / 2), of: content)
    }

    /// 浮出的区连同它到窗口边缘的部分，外加一点余量；鼠标离开这里才收回。
    private func concealRegion(_ edge: DockEdge) -> NSRect {
        let frame = revealFrame(edge).insetBy(dx: -16, dy: -16)
        let far: CGFloat = 1_000_000
        switch edge {
        case .left: return CGRect(x: -far, y: frame.minY, width: frame.maxX + far, height: frame.height)
        case .right: return CGRect(x: frame.minX, y: frame.minY, width: far, height: frame.height)
        case .bottom: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: far)
        }
    }

    private func reveal(_ edge: DockEdge) {
        let area = areas[edge]!
        revealed.insert(edge)
        area.autoresizingMask = []
        addSubview(area, positioned: .below, relativeTo: indicator)
        area.frame = revealFrame(edge)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        area.shadow = shadow
    }

    private func conceal(_ edge: DockEdge) {
        let area = areas[edge]!
        let host = hosts[edge]!
        revealed.remove(edge)
        area.shadow = nil
        host.addSubview(area)
        area.frame = host.bounds
        area.autoresizingMask = [.width, .height]
    }
}

/// 放置指示：区或边缘是浅 Clay 底加描边和文字，标签与分割位置是一条 Clay 色的线。不接收鼠标。
@MainActor
private final class DropIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isZone = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Theme.text
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ frame: NSRect, label text: String?) {
        isZone = text != nil
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        self.frame = frame
        isHidden = false
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 4, y: (bounds.height - height) / 2, width: max(bounds.width - 8, 0), height: height)
    }

    override func updateLayer() {
        layer?.cornerRadius = isZone ? 6 : 1
        layer?.backgroundColor = (isZone ? Theme.accentSoft : Theme.accent).cgColor
        layer?.borderWidth = isZone ? 1.5 : 0
        layer?.borderColor = Theme.accent.cgColor
    }
}
