import Foundation
import MVLayout
import Testing

struct ViewerTransformTests {
    private let viewport = CGSize(width: 1000, height: 800)
    private let frame = CGSize(width: 1000, height: 800)

    /// 视口内一点对应的内容坐标（相对 zoom 1 时页帧中心）。
    private func content(at point: CGPoint, _ transform: ViewerTransform) -> CGPoint {
        CGPoint(
            x: (point.x - viewport.width / 2 - transform.offset.x) / transform.zoom,
            y: (point.y - viewport.height / 2 - transform.offset.y) / transform.zoom
        )
    }

    @Test("放大时光标处的内容不动")
    func zoomKeepsCursor() {
        let point = CGPoint(x: 700, y: 200)
        var transform = ViewerTransform.identity
        let before = content(at: point, transform)
        transform = transform.zoomed(by: 2, around: point, frame: frame, viewport: viewport)
        let after = content(at: point, transform)
        #expect(transform.zoom == 2)
        #expect(abs(before.x - after.x) < 1e-9)
        #expect(abs(before.y - after.y) < 1e-9)
        transform = transform.zoomed(by: 1.5, around: point, frame: frame, viewport: viewport)
        let again = content(at: point, transform)
        #expect(abs(before.x - again.x) < 1e-9)
        #expect(abs(before.y - again.y) < 1e-9)
    }

    @Test("小于视口时居中，大于视口时不留空")
    func clamps() {
        let small = ViewerTransform(zoom: 0.5, offset: CGPoint(x: 100, y: -100)).clamped(frame: frame, viewport: viewport)
        #expect(small.offset == .zero)
        let big = ViewerTransform(zoom: 2, offset: CGPoint(x: 5000, y: -5000)).clamped(frame: frame, viewport: viewport)
        #expect(big.offset == CGPoint(x: 500, y: -400))
        let wide = ViewerTransform(zoom: 1, offset: CGPoint(x: 300, y: 300)).clamped(frame: CGSize(width: 2000, height: 100), viewport: viewport)
        #expect(wide.offset == CGPoint(x: 300, y: 0))
    }

    @Test("平移受边界限制；倍数有上下限")
    func panAndLimits() {
        let transform = ViewerTransform(zoom: 2).panned(by: CGPoint(x: 600, y: 10), frame: frame, viewport: viewport)
        #expect(transform.offset == CGPoint(x: 500, y: 10))
        #expect(ViewerTransform(zoom: 60).zoomed(by: 10, around: .zero, frame: frame, viewport: viewport).zoom == ViewerTransform.zoomRange.upperBound)
        #expect(ViewerTransform(zoom: 0.2).zoomed(by: 0.1, around: .zero, frame: frame, viewport: viewport).zoom == ViewerTransform.zoomRange.lowerBound)
    }
}
