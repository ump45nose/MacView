import AppKit
import MVFoundation
import MVIO
import MVServices

/// 文件操作有失败项时窗口顶部的错误条（设计稿 5）：标题、每项文件名与原因（最多 5 行）、可选“重试 N 项”与关闭。
@MainActor
final class FileOperationBanner: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    private(set) var retryButton: FlatButton?
    let closeButton: NSButton
    private let onRetry: (() -> Void)?, onClose: () -> Void, bottomLine = CALayer()
    private var nameLabels: [NSTextField] = []
    private var detailLabels: [NSTextField] = []

    init(title: String, failures: [FileFailure], onRetry: (() -> Void)?, onClose: @escaping () -> Void) {
        self.onRetry = onRetry; self.onClose = onClose
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "关闭提示")) ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true; layer?.addSublayer(bottomLine)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel(title)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular); icon.contentTintColor = Theme.danger
        titleLabel.stringValue = title; titleLabel.font = Theme.font(.overlays, size: 13, weight: .semibold)
        titleLabel.textColor = Theme.text; titleLabel.lineBreakMode = .byTruncatingTail

        var textViews: [NSView] = [titleLabel]
        for failure in failures.prefix(5) {
            let name = NSTextField(labelWithString: failure.location.name)
            name.font = Theme.font(.overlays, size: 11.5, weight: .regular, monospacedDigits: true); name.textColor = Theme.text
            name.lineBreakMode = .byTruncatingMiddle; name.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            nameLabels.append(name)
            let reason = NSTextField(labelWithString: ErrorText.describe(failure.error))
            reason.font = Theme.font(.overlays, size: 12); reason.textColor = Theme.text2; reason.lineBreakMode = .byTruncatingTail
            reason.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabels.append(reason)
            let line = NSStackView(views: [name, reason]); line.alignment = .firstBaseline; line.spacing = 8
            textViews.append(line)
        }
        if failures.count > 5 {
            let more = NSTextField(labelWithString: String(localized: "还有 \(failures.count - 5) 项"))
            more.font = Theme.font(.overlays, size: 12); more.textColor = Theme.text2; detailLabels.append(more); textViews.append(more)
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
            let retry = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
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
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @objc private func applyFonts() {
        titleLabel.font = Theme.font(.overlays, size: 13, weight: .semibold)
        let nameFont = Theme.font(.overlays, size: 11.5, weight: .regular, monospacedDigits: true)
        let detailFont = Theme.font(.overlays, size: 12)
        nameLabels.forEach { $0.font = nameFont }
        detailLabels.forEach { $0.font = detailFont }
        retryButton?.applyFont(detailFont)
        needsLayout = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.dangerSoft.cgColor; bottomLine.backgroundColor = Theme.line.cgColor }
    override func layout() { super.layout(); bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5) }
    @objc private func retryClicked(_ sender: Any?) { onRetry?() }
    @objc private func closeClicked(_ sender: Any?) { onClose() }
}

/// 回收目录建不起来时转为永久删除，或清空回收目录第二步的确认表单（设计稿 4）。
@MainActor
final class PermanentDeleteSheet: NSWindow {
    let headingLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let cancelButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let confirmButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.danger, foreground: Theme.onDanger, radius: 7, height: 26, padding: 11)
    private var onDecision: ((Bool) -> Void)?

    convenience init(count: Int, volumeName: String, reason: String, onDecision: @escaping (Bool) -> Void) {
        self.init(
            heading: String(localized: "永久删除这 \(count) 项？"),
            detail: String(localized: "“\(volumeName)”上建不了回收目录：\(reason)\n永久删除后不能撤销，也不能从回收目录找回。"),
            onDecision: onDecision
        )
    }

    init(heading: String, detail: String, onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; backgroundColor = Theme.ground
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular); icon.contentTintColor = Theme.danger
        headingLabel.stringValue = heading; headingLabel.font = Theme.font(.overlays, size: 13, weight: .semibold); headingLabel.textColor = Theme.text
        let headerRow = NSStackView(views: [icon, headingLabel]); headerRow.spacing = 10
        detailLabel.stringValue = detail; detailLabel.font = Theme.font(.overlays, size: 12); detailLabel.textColor = Theme.text2
        cancelButton.setText(String(localized: "取消")); cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed(_:))
        confirmButton.setText(String(localized: "永久删除")); confirmButton.target = self; confirmButton.action = #selector(confirmPressed(_:))

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, confirmButton]); actions.spacing = 8
        let body = NSStackView(views: [headerRow, detailLabel, actions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10; body.setCustomSpacing(14, after: detailLabel)
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

/// 清空回收目录第一步选卷表单（设计稿 4）：列出已连接各卷的卷名、挂载路径与删除批次数，默认全选。
@MainActor
final class EmptyRecycleBinsSheet: NSWindow {
    struct Item: Equatable {
        var location: Location, volumeName: String, mountPath: String, batchCount: Int, binURL: URL?, isSelected = true
    }

    @MainActor
    final class VolumeRow: NSButton {
        private let checkBox = NSView(), checkIcon = NSImageView()
        let nameLabel = NSTextField(labelWithString: ""), pathLabel = NSTextField(labelWithString: ""), countLabel = NSTextField(labelWithString: "")
        var isChecked = true { didSet { updateAppearance() } }

        init(item: Item, index: Int, target: AnyObject?, action: Selector?) {
            super.init(frame: .zero)
            self.tag = index; self.target = target; self.action = action; isBordered = false; title = ""
            checkBox.wantsLayer = true; checkBox.layer?.cornerRadius = 4
            checkIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            checkIcon.symbolConfiguration = .init(pointSize: 9, weight: .bold); checkIcon.contentTintColor = .white
            checkIcon.translatesAutoresizingMaskIntoConstraints = false; checkBox.addSubview(checkIcon)
            nameLabel.stringValue = item.volumeName; nameLabel.font = Theme.font(.overlays, size: 13, weight: .medium); nameLabel.textColor = Theme.text
            pathLabel.stringValue = item.mountPath; pathLabel.font = Theme.font(.overlays, size: 11); pathLabel.textColor = Theme.text2; pathLabel.lineBreakMode = .byTruncatingMiddle
            countLabel.stringValue = String(localized: "\(item.batchCount) 次删除"); countLabel.font = Theme.font(.overlays, size: 12); countLabel.textColor = Theme.text2
            let textStack = NSStackView(views: [nameLabel, pathLabel]); textStack.orientation = .vertical; textStack.alignment = .leading; textStack.spacing = 1
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [checkBox, textStack, spacer, countLabel])
            row.alignment = .centerY; row.spacing = 10; row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
            NSLayoutConstraint.activate([
                checkBox.widthAnchor.constraint(equalToConstant: 14), checkBox.heightAnchor.constraint(equalToConstant: 14),
                checkIcon.centerXAnchor.constraint(equalTo: checkBox.centerXAnchor), checkIcon.centerYAnchor.constraint(equalTo: checkBox.centerYAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            isChecked = item.isSelected; updateAppearance()
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

        private func updateAppearance() {
            checkIcon.isHidden = !isChecked
            effectiveAppearance.performAsCurrentDrawingAppearance {
                checkBox.layer?.backgroundColor = (isChecked ? NSColor(srgbRed: 0x3A / 255, green: 0x72 / 255, blue: 0xD8 / 255, alpha: 1) : Theme.raised).cgColor
                checkBox.layer?.borderWidth = isChecked ? 0 : 1
                checkBox.layer?.borderColor = Theme.lineStrong.cgColor
            }
        }
    }

    private(set) var items: [Item]
    private(set) var rowButtons: [VolumeRow] = []
    let cancelButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let revealButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let emptyButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.danger, foreground: Theme.onDanger, radius: 7, height: 26, padding: 11)
    private let listBox = NSStackView()
    private let onReveal: (Item) -> Void
    private var onConfirm: (([Item]) -> Void)?

    init(items: [Item], onReveal: @escaping (Item) -> Void, onConfirm: @escaping ([Item]) -> Void) {
        self.items = items; self.onReveal = onReveal; self.onConfirm = onConfirm
        let initialHeight = CGFloat(min(420, 148 + items.count * 46))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: initialHeight), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; backgroundColor = Theme.ground
        let heading = NSTextField(labelWithString: String(localized: "清空回收目录"))
        heading.font = Theme.font(.overlays, size: 13, weight: .semibold); heading.textColor = Theme.text
        let detail = NSTextField(wrappingLabelWithString: String(localized: "删到回收目录的项在清空前都能手动找回。只列出当前已连接的卷。"))
        detail.font = Theme.font(.overlays, size: 12); detail.textColor = Theme.text2

        listBox.orientation = .vertical; listBox.alignment = .leading; listBox.spacing = 0
        listBox.wantsLayer = true; listBox.layer?.cornerRadius = 8; listBox.layer?.borderWidth = 0.5
        for (index, item) in items.enumerated() {
            if index > 0 {
                let sep = NSView(); sep.wantsLayer = true; sep.layer?.backgroundColor = Theme.line.cgColor
                listBox.addArrangedSubview(sep)
                NSLayoutConstraint.activate([sep.heightAnchor.constraint(equalToConstant: 0.5), sep.widthAnchor.constraint(equalTo: listBox.widthAnchor)])
            }
            let row = VolumeRow(item: item, index: index, target: self, action: #selector(rowToggled(_:)))
            rowButtons.append(row); listBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listBox.widthAnchor).isActive = true
        }
        cancelButton.setText(String(localized: "取消")); cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed(_:))
        revealButton.setText(String(localized: "在 Finder 中显示")); revealButton.target = self; revealButton.action = #selector(revealPressed(_:))
        emptyButton.setText(String(localized: "清空…")); emptyButton.target = self; emptyButton.action = #selector(emptyPressed(_:))

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, revealButton, emptyButton]); actions.spacing = 8
        let body = NSStackView(views: [heading, detail, listBox, actions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 6
        body.setCustomSpacing(10, after: detail); body.setCustomSpacing(14, after: listBox)
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20); body.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: initialHeight)); container.addSubview(body)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 420), listBox.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            actions.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor), body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor), body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container; updateState()
    }

    @objc private func rowToggled(_ sender: VolumeRow) {
        items[sender.tag].isSelected.toggle(); sender.isChecked = items[sender.tag].isSelected; updateState()
    }
    @objc private func revealPressed(_ sender: Any?) { if let first = items.first(where: \.isSelected) { onReveal(first) } }
    @objc private func cancelPressed(_ sender: Any?) { onConfirm = nil; if let parent = sheetParent { parent.endSheet(self) } else { close() } }
    @objc private func emptyPressed(_ sender: Any?) {
        let selected = items.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        let callback = onConfirm; onConfirm = nil
        if let parent = sheetParent { parent.endSheet(self) } else { close() }
        callback?(selected)
    }
    private func updateState() {
        let hasSelection = items.contains(where: \.isSelected)
        revealButton.isEnabled = hasSelection; emptyButton.isEnabled = hasSelection
        effectiveAppearance.performAsCurrentDrawingAppearance {
            listBox.layer?.backgroundColor = Theme.raised.cgColor; listBox.layer?.borderColor = Theme.line.cgColor
        }
    }
}

/// 窗口内重命名表单（设计稿 3）：预选扩展名前的主体，名字为空或未改动时禁用，重名或错误在表单内显示且改动后消失。
@MainActor
final class RenameSheet: NSWindow, NSTextFieldDelegate {
    let entry: Entry, origin: FileOrigin
    let textField = NSTextField(string: "")
    let errorLabel = NSTextField(labelWithString: "")
    let errorRow: NSStackView
    let cancelButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 7, height: 26, padding: 11)
    let confirmButton = FlatButton(font: Theme.font(.overlays, size: 12), fill: Theme.primary, foreground: Theme.onPrimary, radius: 7, height: 26, padding: 11)
    private weak var fileOps: FileOperationController?
    private let inputBox = NSView()
    private var hasError = false, isSubmitting = false

    init(entry: Entry, origin: FileOrigin, fileOps: FileOperationController) {
        self.entry = entry; self.origin = origin; self.fileOps = fileOps
        let errIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil) ?? NSImage())
        errIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular); errIcon.contentTintColor = Theme.danger
        errorRow = NSStackView(views: [errIcon, errorLabel]); errorRow.spacing = 6; errorRow.alignment = .centerY; errorRow.isHidden = true
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 156), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; backgroundColor = Theme.ground
        let heading = NSTextField(labelWithString: String(localized: "重命名“\(entry.name)”"))
        heading.font = Theme.font(.overlays, size: 13, weight: .semibold); heading.textColor = Theme.text; heading.lineBreakMode = .byTruncatingMiddle

        inputBox.wantsLayer = true; inputBox.layer?.cornerRadius = 7; inputBox.layer?.borderWidth = 1
        textField.stringValue = entry.name; textField.font = Theme.font(.overlays, size: 13, weight: .regular, monospacedDigits: true)
        textField.textColor = Theme.text; textField.isBordered = false; textField.drawsBackground = false
        textField.focusRingType = .none; textField.delegate = self; textField.translatesAutoresizingMaskIntoConstraints = false
        inputBox.addSubview(textField)
        errorLabel.font = Theme.font(.overlays, size: 12); errorLabel.textColor = Theme.danger; errorLabel.lineBreakMode = .byTruncatingTail

        cancelButton.setText(String(localized: "取消")); cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed(_:))
        confirmButton.setText(String(localized: "重命名")); confirmButton.target = self; confirmButton.action = #selector(confirmPressed(_:))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, confirmButton]); actions.spacing = 8
        let body = NSStackView(views: [heading, inputBox, errorRow, actions])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8; body.setCustomSpacing(14, after: errorRow)
        body.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20); body.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 156)); container.addSubview(body)
        NSLayoutConstraint.activate([
            errIcon.widthAnchor.constraint(equalToConstant: 14), errIcon.heightAnchor.constraint(equalToConstant: 14),
            inputBox.heightAnchor.constraint(equalToConstant: 30), inputBox.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            textField.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 10), textField.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: inputBox.centerYAnchor), body.widthAnchor.constraint(equalToConstant: 420),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor), body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor), body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            actions.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
        ])
        contentView = container; updateState()
    }

    override func becomeKey() { super.becomeKey(); selectInitialRange() }

    func selectInitialRange() {
        makeFirstResponder(textField)
        let ns = entry.name as NSString, ext = (ns.pathExtension as NSString).length
        let len = entry.kind == .directory ? ns.length : (ext > 0 && ns.length > ext + 1 ? ns.length - ext - 1 : ns.length)
        textField.currentEditor()?.selectedRange = NSRange(location: 0, length: len)
    }

    func setInputText(_ text: String) { textField.stringValue = text; textDidChange() }
    func controlTextDidChange(_ obj: Notification) { textDidChange() }

    private func textDidChange() {
        if hasError { hasError = false; errorRow.isHidden = true }
        updateState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if confirmButton.isEnabled { confirmPressed(nil) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { closeSheet(); return true }
        return false
    }

    private func updateState() {
        let name = textField.stringValue
        confirmButton.isEnabled = !isSubmitting && !hasError && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != entry.name
        effectiveAppearance.performAsCurrentDrawingAppearance {
            inputBox.layer?.backgroundColor = Theme.well.cgColor
            inputBox.layer?.borderColor = (hasError ? Theme.danger : Theme.accent).cgColor
        }
    }

    @objc func cancelPressed(_ sender: Any?) { closeSheet() }

    @objc func confirmPressed(_ sender: Any?) {
        let newName = textField.stringValue
        guard confirmButton.isEnabled, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, newName != entry.name, let fileOps else { return }
        isSubmitting = true; updateState()
        Task { @MainActor in
            let result = await fileOps.perform(.rename(entry.location, to: newName), title: String(localized: "重命名“\(entry.name)”"), origin: origin, reportsFailures: false)
            self.isSubmitting = false
            if let failure = result?.failures.first {
                self.hasError = true
                self.errorLabel.stringValue = if case IOError.alreadyExists = failure.error { String(localized: "这个文件夹里已有“\(newName)”。") } else { ErrorText.describe(failure.error) }
                self.errorRow.isHidden = false; self.updateState(); self.makeFirstResponder(self.textField)
            } else if result != nil { self.closeSheet() } else { self.updateState() }
        }
    }

    private func closeSheet() { if let parent = sheetParent { parent.endSheet(self) } else { close() } }
}
