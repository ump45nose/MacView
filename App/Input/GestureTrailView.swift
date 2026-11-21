import AppKit
import MVCommands
import QuartzCore

/// 查看器鼠标手势的透明浮层：绘制拖动轨迹，并在光标旁实时显示方向序列与将执行的命令标题。
/// 不拦截任何鼠标事件。
@MainActor
final class GestureTrailView: NSView {
    private let trailLayer = CAShapeLayer()
    private let pill = NSView()
    private let directionsLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let pillStack = NSStackView()

    private(set) var displayedDirections: [PointerDirection] = []
    private(set) var displayedCommandTitle: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        trailLayer.fillColor = nil
        trailLayer.lineWidth = 3
        trailLayer.lineCap = .round
        trailLayer.lineJoin = .round
        trailLayer.shadowColor = NSColor.black.cgColor
        trailLayer.shadowOpacity = 0.25
        trailLayer.shadowRadius = 4
        trailLayer.shadowOffset = .zero
        layer?.addSublayer(trailLayer)

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.borderWidth = 0.5
        pill.layer?.shadowOpacity = 1
        pill.layer?.shadowRadius = 12
        pill.layer?.shadowOffset = CGSize(width: 0, height: -4)

        directionsLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        directionsLabel.textColor = Theme.accent
        directionsLabel.setContentHuggingPriority(.required, for: .horizontal)

        commandLabel.font = .systemFont(ofSize: 13, weight: .medium)
        commandLabel.textColor = Theme.text
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.setContentHuggingPriority(.required, for: .horizontal)

        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.spacing = 8
        pillStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        pillStack.addArrangedSubview(directionsLabel)
        pillStack.addArrangedSubview(commandLabel)
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            pillStack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            pillStack.topAnchor.constraint(equalTo: pill.topAnchor),
            pillStack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        addSubview(pill)
        isHidden = true
        updateAppearanceColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailLayer.frame = bounds
        CATransaction.commit()
    }

    func update(points: [CGPoint], directions: [PointerDirection], commandTitle: String?) {
        displayedDirections = directions
        displayedCommandTitle = commandTitle

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailLayer.frame = bounds
        if points.count >= 2 {
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            trailLayer.path = path
        } else {
            trailLayer.path = nil
        }
        CATransaction.commit()

        directionsLabel.stringValue = Self.format(directions)
        if let commandTitle, !commandTitle.isEmpty {
            commandLabel.stringValue = commandTitle
            commandLabel.isHidden = false
        } else {
            commandLabel.stringValue = ""
            commandLabel.isHidden = true
        }

        pill.layoutSubtreeIfNeeded()
        let pillSize = pillStack.fittingSize
        if let anchor = points.last {
            let margin: CGFloat = 12
            let offsetX: CGFloat = 16
            let offsetY: CGFloat = -pillSize.height - 14
            let rawX = anchor.x + offsetX
            let rawY = anchor.y + offsetY
            let maxX = max(margin, bounds.width - pillSize.width - margin)
            let maxY = max(margin, bounds.height - pillSize.height - margin)
            let clampedX = min(max(rawX, margin), maxX)
            let clampedY = min(max(rawY < margin ? anchor.y + 18 : rawY, margin), maxY)
            pill.frame = CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: pillSize)
        }
        isHidden = false
    }

    func clear() {
        displayedDirections = []
        displayedCommandTitle = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailLayer.path = nil
        CATransaction.commit()
        isHidden = true
    }

    static func symbol(for direction: PointerDirection) -> String {
        switch direction {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }

    static func format(_ directions: [PointerDirection]) -> String {
        directions.map(symbol(for:)).joined(separator: " ")
    }

    private func updateAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trailLayer.strokeColor = Theme.accent.withAlphaComponent(0.88).cgColor
            pill.layer?.backgroundColor = Theme.hud.cgColor
            pill.layer?.borderColor = Theme.lineStrong.cgColor
            pill.layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        }
    }
}
