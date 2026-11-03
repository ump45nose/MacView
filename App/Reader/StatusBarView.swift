import AppKit
import MVReading

/// 窗口底部的状态栏：当前页位置、页面像素尺寸，以及右侧的服务标记。
///
/// “跳到指定页”时，位置文字换成页码输入框：回车跳转，Esc 或失去焦点取消。
@MainActor
final class StatusBarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 28

    private let position = NSTextField(labelWithString: "")
    private let pixelSize = NSTextField(labelWithString: "")
    private let jumpLabel = NSTextField(labelWithString: String(localized: "跳到"))
    let jumpField = NSTextField()
    private let jumpTotal = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let volume = NSTextField(labelWithString: "")
    private let topLine = CALayer()
    private var jumpViews: [NSView] { [jumpLabel, jumpField, jumpTotal] }
    /// 输入了页码（从 1 开始）并回车。
    var onJump: ((Int) -> Void)?
    /// 跳转输入结束，焦点应回到页面。
    var onJumpEnd: (() -> Void)?

    init(serviceBadge: String, badgeToolTip: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(topLine)
        for label in [position, pixelSize, jumpLabel, jumpTotal, volume, badge] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.text2
            label.lineBreakMode = .byTruncatingTail
        }
        pixelSize.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        jumpField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        jumpField.controlSize = .small
        jumpField.placeholderString = String(localized: "页码")
        jumpField.delegate = self
        jumpField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        jumpField.setAccessibilityLabel(String(localized: "页码"))
        badge.stringValue = serviceBadge
        badge.toolTip = badgeToolTip
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        let badgeIcon = NSImageView(image: NSImage(systemSymbolName: "testtube.2", accessibilityDescription: nil) ?? NSImage())
        badgeIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        badgeIcon.contentTintColor = Theme.text2
        badgeIcon.toolTip = badgeToolTip
        badgeIcon.isHidden = serviceBadge.isEmpty

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [position, jumpLabel, jumpField, jumpTotal, pixelSize, spacer, volume, badgeIcon, badge])
        stack.orientation = .horizontal
        stack.spacing = 18
        stack.setCustomSpacing(6, after: jumpLabel)
        stack.setCustomSpacing(6, after: jumpField)
        stack.setCustomSpacing(5, after: badgeIcon)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        jumpViews.forEach { $0.isHidden = true }
        volume.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        topLine.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
    }

    /// 卷不健康时显示。
    func setVolumeStatus(_ text: String?) {
        volume.stringValue = text ?? ""
        volume.isHidden = text == nil
    }

    var volumeStatus: String? { volume.isHidden ? nil : volume.stringValue }

    func refresh(_ session: ReaderSession) {
        let pages = session.book?.pages ?? []
        let frame = session.frames.indices.contains(session.currentFrame) ? session.frames[session.currentFrame] : nil
        let shown = (frame?.elements.map(\.page) ?? []).sorted()
        if let first = shown.first, let last = shown.last {
            position.stringValue = first == last
                ? String(localized: "第 \(first + 1) 页 / 共 \(pages.count) 页")
                : String(localized: "第 \(first + 1)–\(last + 1) 页 / 共 \(pages.count) 页")
        } else {
            position.stringValue = ""
        }
        if let page = shown.first.flatMap({ pages.indices.contains($0) ? pages[$0] : nil }), let size = page.metadata?.pixelSize {
            pixelSize.stringValue = "\(size.width) × \(size.height)"
        } else {
            pixelSize.stringValue = ""
        }
        jumpTotal.stringValue = String(localized: "页 / 共 \(pages.count) 页")
    }

    var isJumping: Bool { !jumpField.isHidden }

    /// 显示页码输入框，填入当前页并全选。
    func beginJump(current: Int) {
        position.isHidden = true
        jumpViews.forEach { $0.isHidden = false }
        jumpField.stringValue = String(current)
        window?.makeFirstResponder(jumpField)
        jumpField.currentEditor()?.selectAll(nil)
    }

    private func endJump() {
        guard isJumping else { return }
        jumpViews.forEach { $0.isHidden = true }
        position.isHidden = false
        onJumpEnd?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let number = Int(jumpField.stringValue.trimmingCharacters(in: .whitespaces))
            endJump()
            if let number { onJump?(number) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endJump()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endJump()
    }
}
