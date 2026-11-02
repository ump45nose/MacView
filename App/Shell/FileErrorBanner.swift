import AppKit

/// 配置文件出错时窗口顶部的提示条（设计稿“状态与反馈 · 配置文件解析失败”）：图标、标题与说明、“打开文件”、关闭。
@MainActor
final class FileErrorBanner: NSView {
    private let fileURL: URL
    private let onClose: () -> Void
    private let bottomLine = CALayer()

    init(title: String, detail: String, fileURL: URL, onClose: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(bottomLine)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.exclamationmark", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = Theme.danger
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = Theme.text2
        detailLabel.isSelectable = true
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let open = NSButton(title: String(localized: "打开文件"), target: self, action: #selector(openFile(_:)))
        open.controlSize = .small
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "关闭提示")) ?? NSImage(),
                             target: self, action: #selector(close(_:)))
        close.isBordered = false
        close.contentTintColor = Theme.text2
        close.toolTip = String(localized: "关闭提示")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, open, close])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.dangerSoft.cgColor
        bottomLine.backgroundColor = Theme.line.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        CATransaction.commit()
    }

    @objc private func openFile(_ sender: Any?) {
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func close(_ sender: Any?) {
        onClose()
    }
}
