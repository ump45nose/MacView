import AppKit
import MVFoundation
import MVIO

extension Location.Root {
    /// 让系统挂载这个卷的地址。
    var mountURL: URL? {
        guard case let .network(scheme, host, share) = self else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + share
        return components.url
    }

    /// 界面上的卷名。
    var displayName: String {
        switch self {
        case .local: String(localized: "本机")
        case let .network(_, _, share): share
        case let .plugin(id): id
        }
    }
}

/// 卷状态提示条（设计稿“状态与反馈 · 卷响应缓慢、卷不可用”）。健康时不显示。
@MainActor
final class VolumeStatusView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let retry = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 10)
    private let connect = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 10)
    private let bottomLine = CALayer()
    private var mountURL: URL?
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(bottomLine)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = Theme.accent
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = Theme.text2
        detailLabel.lineBreakMode = .byTruncatingTail
        retry.setText(String(localized: "重试"))
        retry.target = self
        retry.action = #selector(retryPressed(_:))
        connect.setText(String(localized: "连接…"))
        connect.target = self
        connect.action = #selector(connectPressed(_:))
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, retry, connect])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 窗口当前的书所在的卷；`showsBanner` 为 false 时错误已经由查看器的提示显示。
    func show(_ health: VolumeHealth?, showsBanner: Bool) {
        guard showsBanner, let health, let text = Self.text(for: health) else {
            isHidden = true
            return
        }
        isHidden = false
        titleLabel.stringValue = text.title
        detailLabel.stringValue = text.detail
        setAccessibilityLabel(text.title)
        mountURL = health.root.mountURL
        connect.isHidden = health.state != .unavailable || mountURL == nil
    }

    private static func text(for health: VolumeHealth) -> (title: String, detail: String)? {
        let name = health.root.displayName
        switch health.state {
        case .healthy: return nil
        case .degraded: return (String(localized: "\(name) 响应缓慢"), String(localized: "新的读取已暂停，正在探测连接"))
        case .unavailable: return (String(localized: "无法访问 \(name)"), String(localized: "NAS 没有响应，或者共享已断开。已缓存的缩略图仍可浏览。"))
        }
    }

    /// 状态栏上的一行；健康时是 nil。
    static func statusText(for health: VolumeHealth?) -> String? {
        guard let health else { return nil }
        let name = health.root.displayName
        switch health.state {
        case .healthy: return nil
        case .degraded: return String(localized: "\(name) · 响应缓慢 · 正在探测")
        case .unavailable: return String(localized: "\(name) · 无法访问")
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accentSoft.cgColor
        bottomLine.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        CATransaction.commit()
    }

    @objc private func retryPressed(_ sender: Any?) {
        onRetry?()
    }

    @objc private func connectPressed(_ sender: Any?) {
        if let mountURL { NSWorkspace.shared.open(mountURL) }
    }
}
