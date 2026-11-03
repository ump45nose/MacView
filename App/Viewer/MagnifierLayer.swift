import AppKit
import QuartzCore

/// 放大镜：跟随光标的圆形图层。内容先用页面图层已有的图按比例裁出，超大图取到块后换成块。
@MainActor
final class MagnifierLayer {
    static let diameter = 240.0
    static let magnification = 3.0
    let root = CALayer()
    private let image = CALayer()

    init() {
        root.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        root.cornerRadius = Self.diameter / 2
        root.masksToBounds = true
        root.borderWidth = 2
        root.borderColor = Theme.accent.cgColor
        root.backgroundColor = Theme.canvas.cgColor
        root.isHidden = true
        image.frame = root.bounds
        image.contentsGravity = .resize
        root.addSublayer(image)
    }

    /// `fraction` 是光标在整页上的位置，`wholeSize` 是整页显示的点数。
    func show(contents: Any?, at point: CGPoint, fraction: CGPoint, wholeSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.isHidden = false
        root.position = point
        image.contents = contents
        let width = Self.diameter / Self.magnification / wholeSize.width
        let height = Self.diameter / Self.magnification / wholeSize.height
        image.contentsRect = CGRect(x: fraction.x - width / 2, y: fraction.y - height / 2, width: width, height: height)
        CATransaction.commit()
    }

    /// 超大图：光标附近的块到了，整幅显示它。
    func showDetail(_ contents: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = contents
        image.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        CATransaction.commit()
    }

    func hide() {
        root.isHidden = true
    }
}
