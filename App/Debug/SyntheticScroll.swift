#if DEBUG
import AppKit

/// 合成带相位的触控板滚动：began、changed、ended。自检和调试接口共用。
@MainActor
enum SyntheticScroll {
    /// 响应式滚动在 began 之后直接从窗口服务器取事件，收不到 `sendEvent` 发来的 changed。自检和调试接口运行时画布要关掉它。
    /// 每次读取启动参数，避免类型第一次被用到时还没写上 `MVDebugSocket` 就把开关冻住。
    nonisolated static var isInUse: Bool {
        UserDefaults.standard.bool(forKey: "MVViewerSelfTest") || UserDefaults.standard.string(forKey: "MVDebugSocket") != nil
    }

    /// `point` 是窗口坐标；`dx`、`dy` 是总位移（点），负的 `dy` 向下滚。
    static func events(at point: NSPoint, in window: NSWindow, dx: Double, dy: Double, steps: Int) -> [NSEvent] {
        let count = max(steps, 1)
        var result: [NSEvent] = []
        for index in 0..<count {
            let phase = index == 0 ? CGScrollPhase.began : .changed
            if let event = event(at: point, in: window, dx: dx / Double(count), dy: dy / Double(count), phase: phase) { result.append(event) }
        }
        if let event = event(at: point, in: window, dx: 0, dy: 0, phase: .ended) { result.append(event) }
        return result
    }

    static func event(at point: NSPoint, in window: NSWindow, dx: Double, dy: Double, phase: CGScrollPhase) -> NSEvent? {
        make(at: point, in: window, dx: dx, dy: dy, phase: phase)
    }

    /// CoreGraphics 没有公开的 `CGEventSetWindowLocation`：带窗口号的事件从这里取窗口内的位置。只在 Debug 构建中使用。
    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map { unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self) }
    }()

    private static func make(at point: NSPoint, in window: NSWindow, dx: Double, dy: Double, phase: CGScrollPhase) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        // 51 是事件记录里的窗口号；NSEvent(cgEvent:) 只有带上它才知道事件属于哪个窗口。
        if let field = CGEventField(rawValue: 51) { cg.setIntegerValueField(field, value: Int64(window.windowNumber)) }
        setWindowLocation?(cg, CGPoint(x: point.x, y: window.frame.height - point.y))
        return NSEvent(cgEvent: cg)
    }
}
#endif
