import AppKit
import MVFoundation
import MVServices

/// 文件操作有失败项时窗口顶部的错误条（设计稿 5）：标题、每项文件名与原因（最多 5 行）、可选“重试 N 项”与关闭。
@MainActor
final class FileOperationBanner: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    private(set) var retryButton: FlatButton?
    let closeButton: NSButton
    private let onRetry: (() -> Void)?, onClose: () -> Void, bottomLine = CALayer()

    init(title: String, failures: [FileFailure], onRetry: (() -> Void)?, onClose: @escaping () -> Void) {
        self.onRetry = onRetry; self.onClose = onClose
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "关闭提示")) ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true; layer?.addSublayer(bottomLine)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(title)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular); icon.contentTintColor = Theme.danger
        titleLabel.stringValue = title; titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text; titleLabel.lineBreakMode = .byTruncatingTail

        var textViews: [NSView] = [titleLabel]
        for failure in failures.prefix(5) {
            let name = NSTextField(labelWithString: failure.location.name)
            name.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); name.textColor = Theme.text
            name.lineBreakMode = .byTruncatingMiddle; name.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            let reason = NSTextField(labelWithString: ErrorText.describe(failure.error))
            reason.font = .systemFont(ofSize: 12); reason.textColor = Theme.text2; reason.lineBreakMode = .byTruncatingTail
            reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = NSStackView(views: [name, reason]); line.alignment = .firstBaseline; line.spacing = 8
            textViews.append(line)
        }
        if failures.count > 5 {
            let more = NSTextField(labelWithString: String(localized: "还有 \(failures.count - 5) 项"))
            more.font = .systemFont(ofSize: 12); more.textColor = Theme.text2; textViews.append(more)
        }
        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical; textStack.alignment = .leading; textStack.spacing = 2
        textStack.setCustomSpacing(4, after: titleLabel)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.target = self; closeButton.action = #selector(closeClicked(_:))
        closeButton.isBordered = false; closeButton.contentTintColor = Theme.text2; closeButton.toolTip = String(localized: "关闭提示")

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var rowViews: [NSView] = [icon, textStack, spacer]
        if onRetry != nil {
            let retry = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
            retry.setText(String(localized: "重试 \(max(1, failures.count)) 项"))
            retry.target = self; retry.action = #selector(retryClicked(_:))
            retryButton = retry; rowViews.append(retry)
        }
        rowViews.append(closeButton)
        let row = NSStackView(views: rowViews)
        row.alignment = .top; row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 26), closeButton.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.dangerSoft.cgColor; bottomLine.backgroundColor = Theme.line.cgColor }
    override func layout() { super.layout(); bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5) }
    @objc private func retryClicked(_ sender: Any?) { onRetry?() }
    @objc private func closeClicked(_ sender: Any?) { onClose() }
}

/// 回收目录建不起来时转为永久删除的确认表单（设计稿 4）。
@MainActor
final class PermanentDeleteSheet: NSWindow {
    let cancelButton = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let confirmButton = FlatButton(font: .systemFont(ofSize: 12), fill: Theme.danger, foreground: Theme.onDanger, radius: 7, height: 26, padding: 11)
    private var onDecision: ((Bool) -> Void)?

    init(count: Int, volumeName: String, reason: String, onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; backgroundColor = Theme.ground
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular); icon.contentTintColor = Theme.danger
        let heading = NSTextField(labelWithString: String(localized: "永久删除这 \(count) 项？"))
        heading.font = .systemFont(ofSize: 13, weight: .semibold); heading.textColor = Theme.text
        let headerRow = NSStackView(views: [icon, heading]); headerRow.spacing = 10
        let detail = NSTextField(wrappingLabelWithString: String(localized: "“\(volumeName)”上建不了回收目录：\(reason)\n永久删除后不能撤销，也不能从回收目录找回。"))
        detail.font = .systemFont(ofSize: 12); detail.textColor = Theme.text2
        cancelButton.setText(String(localized: "取消")); cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed(_:))
        confirmButton.setText(String(localized: "永久删除")); confirmButton.target = self; confirmButton.action = #selector(confirmPressed(_:))

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, confirmButton]); actions.spacing = 8
        let body = NSStackView(views: [headerRow, detail, actions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10; body.setCustomSpacing(14, after: detail)
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20); body.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150)); container.addSubview(body)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20), body.widthAnchor.constraint(equalToConstant: 420),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor), body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor), body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            actions.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
        ])
        contentView = container
    }

    @objc private func cancelPressed(_ sender: Any?) { finish(confirmed: false) }
    @objc private func confirmPressed(_ sender: Any?) { finish(confirmed: true) }
    private func finish(confirmed: Bool) {
        let callback = onDecision; onDecision = nil
        if let parent = sheetParent { parent.endSheet(self) } else { close() }
        callback?(confirmed)
    }
}
