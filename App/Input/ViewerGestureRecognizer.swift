import AppKit
import MVCommands
import MVFoundation

/// 查看器非键盘输入的统一识别器：持有当前 `InputBindings`，管理右键手势状态机与浮层更新，
/// 并在未拖动即松开右键时弹出右键菜单；后续扩展点击区域、滚轮与触控板横扫。
@MainActor
final class ViewerGestureRecognizer {
    private static let escapeKeyCode: UInt16 = 53
    private static let minTrailStep: CGFloat = 2

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

    func reset() {
        rightDrag = nil
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
