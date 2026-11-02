import AppKit
import MVCommands

/// 多键序列等待中的提示：已按下的键、“等待下一个键…”，以及可接的键和对应的命令。显示在主视图底部居中。
@MainActor
final class PendingSequenceView: NSView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
        ])
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.16).cgColor
    }

    func show(_ pending: InputRouter.Pending?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let pending else {
            isHidden = true
            return
        }
        let waiting = NSTextField(labelWithString: String(localized: "等待下一个键…"))
        waiting.font = .systemFont(ofSize: 12)
        waiting.textColor = Theme.text2
        let typed = NSStackView(views: pending.typed.map { KeyCapView(KeyMapping.displayName(for: $0), large: true) } + [waiting])
        typed.spacing = 8
        stack.addArrangedSubview(typed)

        if !pending.next.isEmpty {
            // 键帽等宽，命令名紧跟键帽、左对齐。NSGridView 会把多余的宽度分给键列，所以用行和等宽约束。
            let caps = pending.next.map { KeyCapView(KeyMapping.displayName(for: $0.chord), large: false) }
            let rows = zip(caps, pending.next).map { cap, next in
                let title = NSTextField(labelWithString: next.title)
                title.font = .systemFont(ofSize: 12)
                title.textColor = Theme.text
                let row = NSStackView(views: [cap, title])
                row.spacing = 10
                return row
            }
            let list = NSStackView(views: rows)
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 4
            stack.addArrangedSubview(list)
            NSLayoutConstraint.activate(caps.dropFirst().map { $0.widthAnchor.constraint(equalTo: caps[0].widthAnchor) })
        }
        let summary = ([pending.typed.map(KeyMapping.displayName).joined(separator: " "), waiting.stringValue]
            + pending.next.map { "\(KeyMapping.displayName(for: $0.chord)) \($0.title)" }).joined(separator: "，")
        setAccessibilityLabel(summary)
        isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: summary])
    }
}

/// 键帽：圆角描边，大号用于已按下的键。
@MainActor
private final class KeyCapView: NSView {
    private let label: NSTextField

    init(_ text: String, large: Bool) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: large ? 12 : 11)
        label.textColor = Theme.text
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let side: CGFloat = large ? 22 : 20
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: side),
            widthAnchor.constraint(greaterThanOrEqualToConstant: side),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: large ? 6 : 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: large ? -6 : -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.raised.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
    }
}
