import CoreGraphics

/// 手势方向识别：喂入点（标准 macOS AppKit 视图坐标，单位点），
/// 按 `minSegment`（默认 24 pt）折成四向序列，相邻同向合并。
///
/// 坐标约定（AppKit 非翻转视图坐标）：
/// - `+x` → `.right`
/// - `-x` → `.left`
/// - `+y` → `.up`
/// - `-y` → `.down`
///
/// 斜向移动按水平/垂直分量绝对值较大者取主方向（绝对值相等时取水平方向）。
public struct MouseGestureTracker: Sendable {
    public let minSegment: CGFloat
    private var anchor: CGPoint
    public private(set) var directions: [PointerDirection] = []

    public init(origin: CGPoint, minSegment: CGFloat = 24) {
        self.anchor = origin
        self.minSegment = minSegment.isFinite && minSegment > 0 ? minSegment : 24
    }

    /// 喂入下一个指针位置（标准 AppKit 视图坐标，单位点）。
    public mutating func add(_ point: CGPoint) {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard dx * dx + dy * dy >= minSegment * minSegment else { return }

        let direction: PointerDirection
        if abs(dx) >= abs(dy) {
            direction = dx >= 0 ? .right : .left
        } else {
            direction = dy >= 0 ? .up : .down
        }

        if directions.last != direction {
            directions.append(direction)
        }
        anchor = point
    }

    /// 超过 `minSegment` 才算拖动；未拖动时 App 应弹出右键菜单。
    public var hasMoved: Bool {
        !directions.isEmpty
    }
}
