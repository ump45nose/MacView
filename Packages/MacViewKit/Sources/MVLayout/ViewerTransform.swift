import CoreGraphics
import Foundation

/// 分页查看器的缩放与平移：`zoom` 是相对 `PageFrameFit` 结果的倍数，`offset` 是页帧中心相对视口中心的位移。
///
/// 坐标都是设备像素，y 向下。方法里的 `frame` 是 `zoom == 1` 时的页帧尺寸。
public struct ViewerTransform: Sendable, Hashable {
    public static let zoomRange: ClosedRange<Double> = 0.1...64
    public static let identity = ViewerTransform()

    public var zoom: Double
    public var offset: CGPoint

    public init(zoom: Double = 1, offset: CGPoint = .zero) {
        self.zoom = zoom
        self.offset = offset
    }

    /// 以视口内的 `point` 为中心缩放，这一点下的内容不动（缩到页帧小于视口时居中）。
    public func zoomed(by factor: Double, around point: CGPoint, frame: CGSize, viewport: CGSize) -> ViewerTransform {
        let newZoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let ratio = newZoom / zoom
        let fromCenter = CGPoint(x: point.x - viewport.width / 2, y: point.y - viewport.height / 2)
        let moved = CGPoint(x: fromCenter.x - (fromCenter.x - offset.x) * ratio, y: fromCenter.y - (fromCenter.y - offset.y) * ratio)
        return ViewerTransform(zoom: newZoom, offset: moved).clamped(frame: frame, viewport: viewport)
    }

    public func panned(by delta: CGPoint, frame: CGSize, viewport: CGSize) -> ViewerTransform {
        ViewerTransform(zoom: zoom, offset: CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)).clamped(frame: frame, viewport: viewport)
    }

    /// 页帧小于视口的方向居中，大于视口的方向不留空。
    public func clamped(frame: CGSize, viewport: CGSize) -> ViewerTransform {
        func limit(_ value: Double, content: Double, view: Double) -> Double {
            let room = (content - view) / 2
            return room <= 0 ? 0 : min(max(value, -room), room)
        }
        return ViewerTransform(zoom: zoom, offset: CGPoint(
            x: limit(offset.x, content: frame.width * zoom, view: viewport.width),
            y: limit(offset.y, content: frame.height * zoom, view: viewport.height)
        ))
    }
}
