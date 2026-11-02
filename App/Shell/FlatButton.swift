import AppKit

/// 设计稿的矩形按钮：圆角底色、可选描边，文字颜色随外观切换。系统按钮的 `contentTintColor` 作用不到文字，底色也不受令牌控制，所以自绘。
@MainActor
final class FlatButton: NSButton {
    private let fill: NSColor
    private let foreground: NSColor
    private let border: NSColor?
    private let radius: CGFloat
    private let height: CGFloat
    private let padding: CGFloat

    init(font: NSFont, fill: NSColor, foreground: NSColor, border: NSColor? = nil, radius: CGFloat, height: CGFloat, padding: CGFloat) {
        self.fill = fill
        self.foreground = foreground
        self.border = border
        self.radius = radius
        self.height = height
        self.padding = padding
        super.init(frame: .zero)
        isBordered = false
        self.font = font
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [.font: font as Any, .foregroundColor: foreground])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + padding * 2, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = border == nil ? 0 : 0.25
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        fill.withAlphaComponent(isHighlighted ? fill.alphaComponent * 0.8 : fill.alphaComponent).setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
    }
}
