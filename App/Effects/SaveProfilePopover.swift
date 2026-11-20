import AppKit
import MVSettings

/// “存为显示配置”弹出层：输入名称、勾选四组设置、同名覆盖提示。
@MainActor
final class SaveProfilePopover: NSObject, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let existingNames: Set<String>
    private let onSave: (String, Set<DisplayProfileGroup>) -> Void

    let nameField = NSTextField()
    private let warningLabel = NSTextField(wrappingLabelWithString: String(localized: "已有同名配置，保存会覆盖它。"))
    private var checkboxes: [DisplayProfileGroup: NSButton] = [:]
    let saveButton = FlatButton(
        font: .systemFont(ofSize: 12, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 6, height: 24, padding: 12
    )
    let cancelButton = FlatButton(
        font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10
    )

    init(
        settings: ResolvedBookSettings,
        existingNames: Set<String>,
        onSave: @escaping (String, Set<DisplayProfileGroup>) -> Void
    ) {
        self.existingNames = existingNames
        self.onSave = onSave
        super.init()

        let controller = NSViewController()
        controller.view = buildContent(settings: settings)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    func show(relativeTo anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    func close() {
        popover.performClose(nil)
    }

    func setGroup(_ group: DisplayProfileGroup, checked: Bool) {
        checkboxes[group]?.state = checked ? .on : .off
        refreshValidation()
    }

    func setName(_ name: String) {
        nameField.stringValue = name
        refreshValidation()
    }

    func submit() {
        saveClicked(nil)
    }

    var isShowingDuplicateWarning: Bool {
        !warningLabel.isHidden
    }

    private func buildContent(settings: ResolvedBookSettings) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: String(localized: "存为显示配置"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        stack.addArrangedSubview(title)

        nameField.stringValue = String(localized: "新配置")
        nameField.placeholderString = String(localized: "名称")
        nameField.font = .systemFont(ofSize: 12.5)
        nameField.bezelStyle = .roundedBezel
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(nameField)

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = Theme.danger
        warningLabel.isHidden = true
        stack.addArrangedSubview(warningLabel)

        for group in DisplayProfileHelpers.orderedGroups {
            let box = NSButton(checkboxWithTitle: DisplayProfileHelpers.title(of: group), target: self, action: #selector(groupToggled(_:)))
            box.state = .on
            box.font = .systemFont(ofSize: 12)
            checkboxes[group] = box

            let summary = NSTextField(wrappingLabelWithString: DisplayProfileHelpers.summary(of: group, in: settings))
            summary.font = .systemFont(ofSize: 11)
            summary.textColor = Theme.text2
            summary.maximumNumberOfLines = 2

            let groupStack = NSStackView(views: [box, summary])
            groupStack.orientation = .vertical
            groupStack.alignment = .leading
            groupStack.spacing = 2
            summary.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                summary.leadingAnchor.constraint(equalTo: groupStack.leadingAnchor, constant: 18),
                summary.trailingAnchor.constraint(equalTo: groupStack.trailingAnchor),
            ])
            stack.addArrangedSubview(groupStack)
            NSLayoutConstraint.activate([
                groupStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            ])
        }

        cancelButton.setText(String(localized: "取消"))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        saveButton.setText(String(localized: "保存"))
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [spacer, cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        stack.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 268),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            warningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])

        refreshValidation()
        return root
    }

    private var selectedGroups: Set<DisplayProfileGroup> {
        Set(checkboxes.compactMap { $0.value.state == .on ? $0.key : nil })
    }

    private func refreshValidation() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        warningLabel.isHidden = !existingNames.contains(trimmed)
        saveButton.isEnabled = !trimmed.isEmpty && !selectedGroups.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshValidation()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if saveButton.isEnabled { saveClicked(nil) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelClicked(nil)
            return true
        }
        return false
    }

    @objc private func groupToggled(_ sender: Any?) {
        refreshValidation()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }

    @objc private func saveClicked(_ sender: Any?) {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = selectedGroups
        guard !trimmed.isEmpty, !groups.isEmpty else { return }
        close()
        onSave(trimmed, groups)
    }
}
