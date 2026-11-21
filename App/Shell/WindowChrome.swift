import AppKit
import MVSettings

/// 阅读窗口顶端 6 pt 的追踪视图：自动隐藏标题栏模式下，指针进入时触发浮出。
@MainActor
private final class TopEdgeTrackingView: NSView {
    var onPointerEnter: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEnter?()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerEnter?()
    }
}

/// 单个阅读窗口的外观控制：标题栏三态（含自动隐藏顶端浮出）、置顶、不透明度、毛玻璃底色与全屏前后状态保存恢复。
@MainActor
final class WindowChrome {
    static let revealEdgeHeight: CGFloat = 6
    static let collapseDelay: Duration = .milliseconds(600)

    private weak var window: NSWindow?
    private let toolbar: NSToolbar
    private unowned let content: ReaderContentView

    private(set) var appearance = WindowAppearance()
    private(set) var isFullScreen = false
    private(set) var isFullScreenSettled = false
    private var isEnteringFullScreen = false
    private var isFrostedBackground = false
    private(set) var isToolbarRevealed = false

    private var topTrackingView: TopEdgeTrackingView?
    private var mouseMoveMonitor: Any?
    private var collapseTask: Task<Void, Never>?
    private var hoverPollTask: Task<Void, Never>?
    private var tabGroupObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?
    private var tabWindowsObservation: NSKeyValueObservation?
    private var tabSelectedObservation: NSKeyValueObservation?
    private var windowObservers: [NSObjectProtocol] = []

    /// 当前是否处于无边框可 ⌘ 拖动状态（全屏时不生效）。
    var isBorderlessActive: Bool {
        !isFullScreen && !isEnteringFullScreen && appearance.titleBar == .borderless
    }

    init(window: NSWindow, toolbar: NSToolbar, content: ReaderContentView) {
        self.window = window
        self.toolbar = toolbar
        self.content = content

        tabGroupObservation = window.observe(\.tabGroup, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.observeTabGroup(window.tabGroup)
            }
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWindowLayoutOrActivation()
                }
            }
        }
    }

    isolated deinit {
        collapseTask?.cancel()
        hoverPollTask?.cancel()
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func apply(_ appearance: WindowAppearance, animated: Bool) {
        self.appearance = appearance
        if isFullScreen || isEnteringFullScreen {
            return
        }
        applyEffectiveState(animated: animated)
    }

    /// 查看器背景是否为毛玻璃（决定窗口是否不透明与透明底色）。
    func setFrostedBackground(_ on: Bool) {
        isFrostedBackground = on
        applyWindowBackground()
    }

    // MARK: 全屏生命周期

    /// 即将调用 `toggleFullScreen` 前准备：若要进入全屏，先把置顶临时降回 `.normal` 并恢复不透明度为 1。
    func prepareForFullScreenToggle() {
        guard let window, !isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        isEnteringFullScreen = true
        window.level = .normal
        window.alphaValue = 1
    }

    func willEnterFullScreen() {
        isEnteringFullScreen = false
        isFullScreen = true
        isFullScreenSettled = false
        cancelAutoHideTimers()
        isToolbarRevealed = false
        removeTopTracking()
        guard let window else { return }
        window.level = .normal
        window.alphaValue = 1
        window.styleMask.remove(.fullSizeContentView)
        toolbar.isVisible = true
        setStandardButtonsHidden(false)
        content.setTopInset(0)
        applyWindowBackground()
    }

    func didEnterFullScreen() {
        isFullScreen = true
        isFullScreenSettled = true
    }

    func didFailToEnterFullScreen() {
        isEnteringFullScreen = false
        isFullScreen = false
        isFullScreenSettled = false
        applyEffectiveState(animated: false)
    }

    func willExitFullScreen() {
        isFullScreenSettled = false
    }

    func didExitFullScreen() {
        isEnteringFullScreen = false
        isFullScreen = false
        isFullScreenSettled = false
        applyEffectiveState(animated: false)
    }

    // MARK: 核心套用

    private func applyEffectiveState(animated: Bool) {
        guard let window else { return }
        let savedFrame = window.frame

        window.level = appearance.keepOnTop ? .floating : .normal
        window.alphaValue = CGFloat(min(max(appearance.opacity, 0.3), 1.0))
        applyWindowBackground()

        switch appearance.titleBar {
        case .shown:
            cancelAutoHideTimers()
            isToolbarRevealed = false
            removeTopTracking()
            if window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            toolbar.isVisible = true
            setStandardButtonsHidden(false)
            content.setTopInset(0)

        case .autoHide:
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            if !isToolbarRevealed {
                toolbar.isVisible = false
                setStandardButtonsHidden(true)
            }
            installTopTracking()
            updateTopInset()

        case .borderless:
            cancelAutoHideTimers()
            isToolbarRevealed = false
            removeTopTracking()
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            toolbar.isVisible = false
            setStandardButtonsHidden(true)
            updateTopInset()
        }

        if window.frame != savedFrame {
            window.setFrame(savedFrame, display: true)
        }
        updateTopInset()
        _ = animated
    }

    private func applyWindowBackground() {
        guard let window else { return }
        if isFrostedBackground && !isFullScreen {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = Theme.ground
        }
    }

    private func setStandardButtonsHidden(_ hidden: Bool) {
        guard let window else { return }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
    }

    // MARK: 标签栏避让

    private func observeTabGroup(_ group: NSWindowTabGroup?) {
        tabBarVisibleObservation = group?.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleTabGroupRefresh() }
        }
        tabWindowsObservation = group?.observe(\.windows, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleTabGroupRefresh() }
        }
        tabSelectedObservation = group?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleTabGroupRefresh() }
        }
        scheduleTabGroupRefresh()
    }

    private func scheduleTabGroupRefresh() {
        handleWindowLayoutOrActivation()
        Task { @MainActor [weak self] in
            self?.handleWindowLayoutOrActivation()
        }
    }

    private func handleWindowLayoutOrActivation() {
        guard !isFullScreen, !isEnteringFullScreen else { return }
        if appearance.titleBar == .borderless || (appearance.titleBar == .autoHide && !isToolbarRevealed) {
            if toolbar.isVisible {
                let savedFrame = window?.frame
                toolbar.isVisible = false
                if let savedFrame, let window, window.frame != savedFrame {
                    window.setFrame(savedFrame, display: true)
                }
            }
            setStandardButtonsHidden(true)
        }
        updateTopInset()
    }

    private func updateTopInset() {
        guard let window else { return }
        guard !isFullScreen, !isEnteringFullScreen, appearance.titleBar != .shown else {
            content.setTopInset(0)
            return
        }
        // 工具栏浮出期间保持查看器位置不变（浮出是覆盖）。
        if isToolbarRevealed {
            return
        }
        let hasTabBar = (window.tabGroup?.windows.count ?? 0) > 1
        guard hasTabBar else {
            content.setTopInset(0)
            return
        }
        let topInset: CGFloat
        if let minY = tabBarMinYInWindow() {
            topInset = max(0, content.bounds.height - minY)
        } else {
            topInset = max(0, content.bounds.height - window.contentLayoutRect.maxY)
        }
        content.setTopInset(topInset)
    }

    /// 查找系统标签栏视图在窗口坐标系中的底边 Y（用于精确避让与自检验证）。
    func tabBarMinYInWindow() -> CGFloat? {
        guard let themeFrame = window?.contentView?.superview else { return nil }
        guard let tabBar = Self.findTabBarView(in: themeFrame) else { return nil }
        return tabBar.convert(tabBar.bounds, to: nil).minY
    }

    private static func findTabBarView(in view: NSView) -> NSView? {
        let name = NSStringFromClass(type(of: view))
        if name.contains("TabBar"), !view.isHidden, view.frame.height > 0 {
            return view
        }
        for subview in view.subviews {
            if let found = findTabBarView(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: 自动隐藏顶端浮出

    private func installTopTracking() {
        if let existing = topTrackingView {
            content.addSubview(existing, positioned: .above, relativeTo: nil)
        } else {
            let tracking = TopEdgeTrackingView()
            tracking.translatesAutoresizingMaskIntoConstraints = false
            tracking.onPointerEnter = { [weak self] in
                self?.revealToolbar()
            }
            content.addSubview(tracking)
            NSLayoutConstraint.activate([
                tracking.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tracking.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                tracking.topAnchor.constraint(equalTo: content.topAnchor),
                tracking.heightAnchor.constraint(equalToConstant: Self.revealEdgeHeight),
            ])
            topTrackingView = tracking
        }
        if mouseMoveMonitor == nil {
            mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleLocalMouseMoved(event)
                }
                return event
            }
        }
    }

    private func handleLocalMouseMoved(_ event: NSEvent) {
        guard let window, window.isVisible, event.window === window else { return }
        guard !isFullScreen, !isEnteringFullScreen, appearance.titleBar == .autoHide else { return }
        let y = event.locationInWindow.y
        if y >= content.bounds.height - Self.revealEdgeHeight && y <= content.bounds.height + 2 {
            revealToolbar()
        }
    }

    private func removeTopTracking() {
        topTrackingView?.removeFromSuperview()
        topTrackingView = nil
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
    }

    private func cancelAutoHideTimers() {
        collapseTask?.cancel()
        collapseTask = nil
        hoverPollTask?.cancel()
        hoverPollTask = nil
    }

    private func revealToolbar() {
        guard !isFullScreen, !isEnteringFullScreen, appearance.titleBar == .autoHide, let window else { return }
        collapseTask?.cancel()
        collapseTask = nil
        if !isToolbarRevealed {
            isToolbarRevealed = true
            let savedFrame = window.frame
            toolbar.isVisible = true
            setStandardButtonsHidden(false)
            if window.frame != savedFrame {
                window.setFrame(savedFrame, display: true)
            }
        }
        startHoverPolling()
    }

    private func startHoverPolling() {
        guard hoverPollTask == nil else { return }
        hoverPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, self.isToolbarRevealed else { return }
                if self.isPointerInsideRevealZone() || self.isInteractingWithToolbar() {
                    self.collapseTask?.cancel()
                    self.collapseTask = nil
                } else if self.collapseTask == nil {
                    self.scheduleCollapse()
                }
            }
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled, let self else { return }
            if !self.isPointerInsideRevealZone() && !self.isInteractingWithToolbar() {
                self.collapseToolbar()
            } else {
                self.collapseTask = nil
            }
        }
    }

    private func collapseToolbar() {
        cancelAutoHideTimers()
        guard isToolbarRevealed, let window else { return }
        isToolbarRevealed = false
        guard !isFullScreen, !isEnteringFullScreen, appearance.titleBar == .autoHide else { return }
        let savedFrame = window.frame
        toolbar.isVisible = false
        setStandardButtonsHidden(true)
        if window.frame != savedFrame {
            window.setFrame(savedFrame, display: true)
        }
        updateTopInset()
    }

    private func isInteractingWithToolbar() -> Bool {
        guard let window else { return false }
        if NSEvent.pressedMouseButtons != 0 { return true }
        if window.attachedSheet != nil { return true }
        if let children = window.childWindows, !children.isEmpty { return true }
        return false
    }

    private func isPointerInsideRevealZone() -> Bool {
        guard let window, window.isVisible else { return false }
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let layoutMaxY = window.contentLayoutRect.maxY
        let zoneMinY = min(frame.maxY - Self.revealEdgeHeight, frame.minY + layoutMaxY)
        let zone = NSRect(x: frame.minX, y: zoneMinY, width: frame.width, height: frame.maxY - zoneMinY + 2)
        return zone.contains(mouse)
    }
}
