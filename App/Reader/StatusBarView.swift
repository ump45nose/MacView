import AppKit
import MVReading

/// 状态栏中的 120 pt 进度条：轨道用 line，填充用 text2。
@MainActor
private final class StatusProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 4) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.line.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        Theme.text2.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// 状态栏进度右侧的圆形取消按钮（16×16 pt）。
@MainActor
private final class StatusCancelButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.selected.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        super.draw(dirtyRect)
    }
}

/// 窗口底部的状态栏：当前页位置、页面像素尺寸，以及右侧的消息/进度、卷状态和服务标记。
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
    private let messageLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = StatusProgressBar()
    let cancelProgressButton: NSButton = StatusCancelButton()
    private lazy var progressRow = NSStackView(views: [progressLabel, progressBar, cancelProgressButton])
    private let badge = NSTextField(labelWithString: "")
    private let volume = NSTextField(labelWithString: "")
    /// 虚拟书里当前页的原文件路径。
    private let pagePath = NSTextField(labelWithString: "")
    private let topLine = CALayer()
    private var jumpViews: [NSView] { [jumpLabel, jumpField, jumpTotal] }
    private var messageTask: Task<Void, Never>?
    private var onCancelProgress: (() -> Void)?
    /// 输入了页码（从 1 开始）并回车。
    var onJump: ((Int) -> Void)?
    /// 跳转输入结束，焦点应回到页面。
    var onJumpEnd: (() -> Void)?

    init(serviceBadge: String, badgeToolTip: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(topLine)
        for label in [position, pixelSize, jumpLabel, jumpTotal, messageLabel, progressLabel, volume, pagePath, badge] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.text2
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [messageLabel, progressLabel] {
            label.textColor = Theme.text
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        pagePath.lineBreakMode = .byTruncatingHead
        pagePath.setContentCompressionResistancePriority(.init(249), for: .horizontal)
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

        cancelProgressButton.isBordered = false
        cancelProgressButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "取消"))
        cancelProgressButton.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        cancelProgressButton.contentTintColor = Theme.text2
        cancelProgressButton.toolTip = String(localized: "取消")
        cancelProgressButton.target = self
        cancelProgressButton.action = #selector(cancelProgressClicked(_:))
        progressRow.spacing = 8
        NSLayoutConstraint.activate([
            progressBar.widthAnchor.constraint(equalToConstant: 120), progressBar.heightAnchor.constraint(equalToConstant: 4),
            cancelProgressButton.widthAnchor.constraint(equalToConstant: 16), cancelProgressButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [position, jumpLabel, jumpField, jumpTotal, pixelSize, spacer, messageLabel, progressRow, volume, pagePath, badgeIcon, badge])
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
        messageLabel.isHidden = true
        progressRow.isHidden = true
        volume.isHidden = true
        pagePath.isHidden = true
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
    var pagePathText: String? { pagePath.isHidden ? nil : pagePath.stringValue }
    var message: String? { messageLabel.isHidden || messageLabel.stringValue.isEmpty ? nil : messageLabel.stringValue }
    var progressText: String? { progressRow.isHidden || progressLabel.stringValue.isEmpty ? nil : progressLabel.stringValue }
    var isShowingProgress: Bool { !progressRow.isHidden }

    func showMessage(_ text: String) {
        messageTask?.cancel()
        messageLabel.stringValue = text; messageLabel.alphaValue = 1; messageLabel.isHidden = !progressRow.isHidden
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.messageLabel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            self.messageLabel.stringValue = ""; self.messageLabel.isHidden = true; self.messageLabel.alphaValue = 1
        }
    }

    func showProgress(_ text: String, fraction: Double?, onCancel: @escaping () -> Void) {
        progressLabel.stringValue = text; progressBar.fraction = fraction ?? 0; onCancelProgress = onCancel
        messageLabel.isHidden = true; progressRow.isHidden = false
    }

    func hideProgress() {
        progressRow.isHidden = true; progressLabel.stringValue = ""; progressBar.fraction = 0; onCancelProgress = nil
        if !messageLabel.stringValue.isEmpty { messageLabel.isHidden = false }
    }

    @objc private func cancelProgressClicked(_ sender: Any?) { onCancelProgress?() }

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
        let current = session.isVirtualBook && pages.indices.contains(session.currentPage) ? pages[session.currentPage].id.displayPath : ""
        pagePath.stringValue = current
        pagePath.toolTip = current
        pagePath.isHidden = current.isEmpty
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
