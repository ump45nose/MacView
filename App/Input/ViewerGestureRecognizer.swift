import AppKit
import MVCommands
import MVFoundation

/// 查看器非键盘输入的统一识别器：持有当前 `InputBindings`，管理右键手势状态机与浮层更新，
/// 并在未拖动即松开右键时弹出右键菜单；同时分派点击区域、滚轮动作与触控板手势。
@MainActor
final class ViewerGestureRecognizer {
    enum WheelDispatchResult {
        /// 按现有标准滚动/翻页行为处理。
        case standard
        /// 按给定倍率缩放。
        case zoom(Double)
        /// 已由识别器处理（执行了命令、触发了横扫或绑定为 `.none`）。
        case handled
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let minTrailStep: CGFloat = 2
    private static let wheelCommandThreshold: CGFloat = 40
    private static let rotationThreshold: CGFloat = 25

    private struct RightDragState {
        var tracker: MouseGestureTracker
        var trailPoints: [CGPoint]
        weak var sourceView: NSView?
        var menuProvider: (NSEvent) -> NSMenu?
        var isCancelled = false
    }

    private unowned let trailView: GestureTrailView
    private var rightDrag: RightDragState?
    private var escapeMonitor: Any?
    private var wheelCommandAccumulator: CGFloat = 0
    private var isTrackingSwipe = false
    private var swipeTriggered = false
    private var rotationAccumulator: CGFloat = 0
    private var rotationTriggered = false

    /// 动态提供当前生效的非键盘绑定（随 `keybindings.json` 变更自动更新）。
    var inputBindingsProvider: (() -> InputBindings)?
    /// 将命令 ID 解析为用于轨迹浮层显示的本地化标题。
    var commandTitleProvider: ((CommandID) -> String)?
    /// 经命令分发器执行识别出的命令。
    var onCommand: ((CommandID, [String: JSONValue]?) -> Void)?

    #if DEBUG
    /// 自检用：拦截右键菜单弹出（返回 true 表示已拦截，不进入模态菜单追踪循环）。
    var onPresentContextMenu: ((NSMenu, NSEvent, NSView) -> Bool)?
    #endif

    init(trailView: GestureTrailView) {
        self.trailView = trailView
    }

    var inputBindings: InputBindings {
        inputBindingsProvider?() ?? InputBindings.effective(user: KeyBindingsFile())
    }

    var isTrackingRightGesture: Bool {
        rightDrag != nil
    }

    // MARK: - 右键手势

    func rightMouseDown(_ event: NSEvent, in sourceView: NSView, menuProvider: @escaping (NSEvent) -> NSMenu?) {
        reset()
        let localPoint = trailView.convert(event.locationInWindow, from: nil)
        rightDrag = RightDragState(
            tracker: MouseGestureTracker(origin: event.locationInWindow),
            trailPoints: [localPoint],
            sourceView: sourceView,
            menuProvider: menuProvider
        )
        installEscapeMonitor()
    }

    @discardableResult
    func rightMouseDragged(_ event: NSEvent) -> Bool {
        guard var state = rightDrag else { return false }
        if state.isCancelled { return true }

        state.tracker.add(event.locationInWindow)
        let localPoint = trailView.convert(event.locationInWindow, from: nil)
        if let last = state.trailPoints.last {
            if hypot(localPoint.x - last.x, localPoint.y - last.y) >= Self.minTrailStep {
                state.trailPoints.append(localPoint)
            }
        } else {
            state.trailPoints.append(localPoint)
        }
        rightDrag = state

        if state.tracker.hasMoved {
            let resolved = inputBindings.command(forGesture: state.tracker.directions)
            let title = resolved.map { commandTitleProvider?($0.0) ?? $0.0.rawValue }
            trailView.update(points: state.trailPoints, directions: state.tracker.directions, commandTitle: title)
        }
        return true
    }

    @discardableResult
    func rightMouseUp(_ event: NSEvent) -> Bool {
        guard let state = rightDrag else { return false }
        rightDrag = nil
        removeEscapeMonitor()
        trailView.clear()

        if state.isCancelled {
            return true
        }
        if state.tracker.hasMoved {
            if let (command, arguments) = inputBindings.command(forGesture: state.tracker.directions) {
                onCommand?(command, arguments)
            }
            return true
        }
        if let view = state.sourceView, let menu = state.menuProvider(event) {
            presentContextMenu(menu, event: event, in: view)
        }
        return true
    }

    /// 右键拖动过程中按 Esc 取消本次手势：隐藏浮层、不执行命令、不弹右键菜单。
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard rightDrag != nil, event.keyCode == Self.escapeKeyCode else { return false }
        cancelRightGesture()
        return true
    }

    func cancelRightGesture() {
        guard rightDrag != nil else { return }
        rightDrag?.isCancelled = true
        removeEscapeMonitor()
        trailView.clear()
    }

    // MARK: - 点击区域

    static func clickZone(at x: CGFloat, width: CGFloat) -> ClickZone? {
        guard width > 0 else { return nil }
        let fraction = x / width
        if fraction < 1.0 / 3.0 {
            return .left
        } else if fraction < 2.0 / 3.0 {
            return .center
        } else {
            return .right
        }
    }

    @discardableResult
    func handleClickZone(at point: CGPoint, in width: CGFloat) -> Bool {
        guard let zone = Self.clickZone(at: point.x, width: width),
              let (command, arguments) = inputBindings.command(for: zone) else {
            return false
        }
        onCommand?(command, arguments)
        return true
    }

    // MARK: - 滚轮与触控板横扫

    func handleScrollWheel(_ event: NSEvent, canSwipeHorizontally: Bool) -> WheelDispatchResult {
        let device: WheelDevice = event.hasPreciseScrollingDeltas ? .trackpad : .mouse
        let modifiers = KeyMapping.modifiers(for: event.modifierFlags)
        let action = inputBindings.wheelAction(device: device, modifiers: modifiers)

        switch action {
        case .none:
            wheelCommandAccumulator = 0
            return .handled
        case .zoom:
            guard event.momentumPhase.isEmpty else { return .handled }
            let delta = Double(event.scrollingDeltaY)
            guard delta != 0 else { return .handled }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.005 : 0.1
            let factor = min(max(exp(delta * sensitivity), 0.5), 2.0)
            return .zoom(factor)
        case let .commands(up, down):
            guard event.momentumPhase.isEmpty else { return .handled }
            if event.hasPreciseScrollingDeltas {
                if event.phase == .began {
                    wheelCommandAccumulator = 0
                }
                wheelCommandAccumulator += event.scrollingDeltaY
                if abs(wheelCommandAccumulator) >= Self.wheelCommandThreshold {
                    let command = wheelCommandAccumulator > 0 ? up : down
                    wheelCommandAccumulator = 0
                    onCommand?(command, nil)
                } else if event.phase.isEmpty, event.scrollingDeltaY != 0 {
                    let command = event.scrollingDeltaY > 0 ? up : down
                    wheelCommandAccumulator = 0
                    onCommand?(command, nil)
                }
                if event.phase == .ended || event.phase == .cancelled {
                    wheelCommandAccumulator = 0
                }
            } else if event.scrollingDeltaY != 0 {
                let command = event.scrollingDeltaY > 0 ? up : down
                onCommand?(command, nil)
            }
            return .handled
        case .standard:
            if canSwipeHorizontally,
               event.hasPreciseScrollingDeltas,
               event.phase == .began,
               event.momentumPhase.isEmpty,
               !isTrackingSwipe,
               NSEvent.isSwipeTrackingFromScrollEventsEnabled,
               abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                let allowLeft = inputBindings.command(for: .swipeLeft) != nil
                let allowRight = inputBindings.command(for: .swipeRight) != nil
                if allowLeft || allowRight {
                    beginHorizontalSwipe(with: event, allowLeft: allowLeft, allowRight: allowRight)
                    return .handled
                }
            }
            if isTrackingSwipe {
                return .handled
            }
            return .standard
        }
    }

    private func beginHorizontalSwipe(with event: NSEvent, allowLeft: Bool, allowRight: Bool) {
        isTrackingSwipe = true
        swipeTriggered = false
        let minThreshold: CGFloat = allowRight ? -1 : 0
        let maxThreshold: CGFloat = allowLeft ? 1 : 0
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: minThreshold,
            max: maxThreshold
        ) { [weak self] gestureAmount, phase, isComplete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if phase == .ended, !self.swipeTriggered {
                    if gestureAmount > 0, allowLeft, let (command, arguments) = self.inputBindings.command(for: .swipeLeft) {
                        self.swipeTriggered = true
                        self.onCommand?(command, arguments)
                    } else if gestureAmount < 0, allowRight, let (command, arguments) = self.inputBindings.command(for: .swipeRight) {
                        self.swipeTriggered = true
                        self.onCommand?(command, arguments)
                    }
                }
                if isComplete || phase == .cancelled {
                    self.isTrackingSwipe = false
                    self.swipeTriggered = false
                }
            }
        }
    }

    // MARK: - 触控板双指轻点与旋转

    @discardableResult
    func handleSmartMagnify(_ event: NSEvent) -> Bool {
        guard let (command, arguments) = inputBindings.command(for: .doubleTap) else { return false }
        onCommand?(command, arguments)
        return true
    }

    @discardableResult
    func handleRotate(_ event: NSEvent) -> Bool {
        let hasLeft = inputBindings.command(for: .rotateLeft) != nil
        let hasRight = inputBindings.command(for: .rotateRight) != nil
        guard hasLeft || hasRight else { return false }

        if event.phase == .began {
            rotationAccumulator = 0
            rotationTriggered = false
            return true
        }
        if event.phase == .ended || event.phase == .cancelled {
            rotationAccumulator = 0
            rotationTriggered = false
            return true
        }

        if event.phase.isEmpty {
            let angle = CGFloat(event.rotation)
            if abs(angle) >= Self.rotationThreshold {
                let input: TrackpadInput = angle > 0 ? .rotateLeft : .rotateRight
                if let (command, arguments) = inputBindings.command(for: input) {
                    onCommand?(command, arguments)
                }
            }
            return true
        }

        rotationAccumulator += CGFloat(event.rotation)
        if !rotationTriggered, abs(rotationAccumulator) >= Self.rotationThreshold {
            let input: TrackpadInput = rotationAccumulator > 0 ? .rotateLeft : .rotateRight
            rotationTriggered = true
            if let (command, arguments) = inputBindings.command(for: input) {
                onCommand?(command, arguments)
            }
        }
        return true
    }

    func reset() {
        rightDrag = nil
        wheelCommandAccumulator = 0
        isTrackingSwipe = false
        swipeTriggered = false
        rotationAccumulator = 0
        rotationTriggered = false
        removeEscapeMonitor()
        trailView.clear()
    }

    private func presentContextMenu(_ menu: NSMenu, event: NSEvent, in view: NSView) {
        #if DEBUG
        if onPresentContextMenu?(menu, event, view) == true {
            return
        }
        #endif
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            let handled = MainActor.assumeIsolated {
                guard let self, self.rightDrag != nil else { return false }
                self.cancelRightGesture()
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
