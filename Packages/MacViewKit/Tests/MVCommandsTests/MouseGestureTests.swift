import CoreGraphics
import Testing
@testable import MVCommands

@Test("C1.2 直线移动：四向识别、相邻同向合并与 AppKit 坐标约定")
func straightLineGesturesFollowAppKitCoordinatesAndMergeSameDirection() {
    // +x -> .right，连续多段合并为单个 .right
    var right = MouseGestureTracker(origin: CGPoint(x: 100, y: 100))
    right.add(CGPoint(x: 112, y: 100))
    #expect(!right.hasMoved)
    right.add(CGPoint(x: 124, y: 100))
    right.add(CGPoint(x: 160, y: 102))
    right.add(CGPoint(x: 210, y: 98))
    #expect(right.hasMoved)
    #expect(right.directions == [.right])

    // -x -> .left
    var left = MouseGestureTracker(origin: CGPoint(x: 100, y: 100))
    left.add(CGPoint(x: 70, y: 100))
    left.add(CGPoint(x: 30, y: 100))
    #expect(left.hasMoved)
    #expect(left.directions == [.left])

    // +y -> .up（AppKit 非翻转视图坐标）
    var up = MouseGestureTracker(origin: CGPoint(x: 100, y: 100))
    up.add(CGPoint(x: 100, y: 130))
    up.add(CGPoint(x: 100, y: 170))
    #expect(up.hasMoved)
    #expect(up.directions == [.up])

    // -y -> .down（AppKit 非翻转视图坐标）
    var down = MouseGestureTracker(origin: CGPoint(x: 100, y: 100))
    down.add(CGPoint(x: 100, y: 70))
    down.add(CGPoint(x: 100, y: 30))
    #expect(down.hasMoved)
    #expect(down.directions == [.down])
}

@Test("C1.2 L 形与多段折线手势")
func lShapeAndMultiSegmentGestures() {
    // ↓→（如默认 book.next）
    var downRight = MouseGestureTracker(origin: CGPoint(x: 100, y: 200))
    downRight.add(CGPoint(x: 100, y: 170))
    downRight.add(CGPoint(x: 100, y: 140))
    downRight.add(CGPoint(x: 130, y: 140))
    downRight.add(CGPoint(x: 165, y: 140))
    #expect(downRight.hasMoved)
    #expect(downRight.directions == [.down, .right])

    // ↓←↑ 三段折线
    var uTurn = MouseGestureTracker(origin: CGPoint(x: 200, y: 200), minSegment: 20)
    uTurn.add(CGPoint(x: 200, y: 175))
    uTurn.add(CGPoint(x: 175, y: 175))
    uTurn.add(CGPoint(x: 175, y: 200))
    #expect(uTurn.hasMoved)
    #expect(uTurn.directions == [.down, .left, .up])
}

@Test("C1.2 抖动：小于阈值的反向回撤不产生多余方向")
func jitterBelowThresholdDoesNotProduceSpuriousDirections() {
    var tracker = MouseGestureTracker(origin: CGPoint(x: 0, y: 0), minSegment: 24)
    tracker.add(CGPoint(x: 30, y: 0))      // 触发 .right，anchor = (30, 0)
    tracker.add(CGPoint(x: 15, y: 2))      // 反向抖动 15 pt < 24，忽略
    tracker.add(CGPoint(x: 42, y: -3))     // 相对 anchor 仅 12 pt < 24，忽略
    tracker.add(CGPoint(x: 60, y: 0))      // 相对 anchor +30 pt，同向 .right 合并，anchor = (60, 0)
    tracker.add(CGPoint(x: 40, y: 5))      // 结尾反向抖动约 20.6 pt < 24，忽略
    #expect(tracker.hasMoved)
    #expect(tracker.directions == [.right])
}

@Test("C1.2 斜向移动按主方向判定")
func diagonalMovementUsesDominantAxis() {
    // |dx| > |dy| -> .right
    var rightDominant = MouseGestureTracker(origin: .zero)
    rightDominant.add(CGPoint(x: 26, y: 14))
    #expect(rightDominant.directions == [.right])

    // |dy| > |dx| -> .up
    var upDominant = MouseGestureTracker(origin: .zero)
    upDominant.add(CGPoint(x: 12, y: 26))
    #expect(upDominant.directions == [.up])

    // |dx| > |dy|（负向）-> .left
    var leftDominant = MouseGestureTracker(origin: .zero)
    leftDominant.add(CGPoint(x: -25, y: -15))
    #expect(leftDominant.directions == [.left])

    // |dy| > |dx|（负向）-> .down
    var downDominant = MouseGestureTracker(origin: .zero)
    downDominant.add(CGPoint(x: -10, y: -25))
    #expect(downDominant.directions == [.down])

    // 精确 45° 斜线（|dx| == |dy|，且距离 >= 24）按水平方向
    var exactDiagonal = MouseGestureTracker(origin: .zero)
    exactDiagonal.add(CGPoint(x: 20, y: 20))
    #expect(exactDiagonal.directions == [.right])
}

@Test("C1.2 未移动或位移均小于阈值时 hasMoved 为 false")
func unmovedOrBelowThresholdStaysIdle() {
    let idle = MouseGestureTracker(origin: CGPoint(x: 50, y: 50))
    #expect(!idle.hasMoved)
    #expect(idle.directions.isEmpty)

    var tiny = MouseGestureTracker(origin: CGPoint(x: 50, y: 50), minSegment: 24)
    tiny.add(CGPoint(x: 60, y: 55))
    tiny.add(CGPoint(x: 40, y: 45))
    tiny.add(CGPoint(x: 50, y: 73))   // dy = 23 < 24
    tiny.add(CGPoint(x: 66, y: 66))   // hypot(16, 16) ≈ 22.6 < 24
    #expect(!tiny.hasMoved)
    #expect(tiny.directions.isEmpty)
}
