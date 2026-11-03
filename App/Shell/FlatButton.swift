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

/// 工具栏的浏览方式切换（设计稿的分段）：well 底，选中段是 raised 底加半粗文字。系统分段控件的选中态不受令牌控制，所以自绘。
@MainActor
final class BrowseModeControl: NSView {
    private final class Segment: NSButton {
        var isSelected = false {
            didSet { if isSelected != oldValue { updateTitle() } }
        }

        func updateTitle() {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? Theme.text : Theme.text2,
            ])
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: ceil(attributedTitle.size().width) + 20, height: 24)
        }

        override func draw(_ dirtyRect: NSRect) {
            if isSelected {
                Theme.raised.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            }
            super.draw(dirtyRect)
        }
    }

    private var segments: [Segment] = []
    var onSelect: ((Int) -> Void)?
    var selected = 0 {
        didSet {
            for (index, segment) in segments.enumerated() { segment.isSelected = index == selected }
        }
    }

    init(labels: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        let stack = NSStackView()
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, label) in labels.enumerated() {
            let segment = Segment(title: label, target: self, action: #selector(pick(_:)))
            segment.isBordered = false
            segment.tag = index
            segment.isSelected = index == selected
            segment.updateTitle()
            segments.append(segment)
            stack.addArrangedSubview(segment)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.well.cgColor
        layer?.borderColor = Theme.line.cgColor
    }

    @objc private func pick(_ sender: NSButton) {
        selected = sender.tag
        onSelect?(sender.tag)
    }
}
