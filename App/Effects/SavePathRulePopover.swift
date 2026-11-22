import AppKit
import MVFoundation
import MVSettings

/// “存为路径规则”弹出层：选择当前书或其各级上层路径，默认选中上一层。
@MainActor
final class SavePathRulePopover: NSObject {
    private let popover = NSPopover()
    let candidates: [Location]
    private let onSave: (Location) -> Void

    let pathPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let saveButton = FlatButton(
        font: Theme.font(.panels, size: 12, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 6, height: 24, padding: 12
    )
    let cancelButton = FlatButton(
        font: Theme.font(.panels, size: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 6, height: 24, padding: 10
    )

    init(
        profile: DisplayProfile,
        bookLocation: Location,
        onSave: @escaping (Location) -> Void
    ) {
        self.candidates = Self.ancestors(of: bookLocation)
        self.onSave = onSave
        super.init()

        let controller = NSViewController()
        controller.view = buildContent(profile: profile)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    func show(relativeTo anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        popover.performClose(nil)
    }

    func selectCandidate(at index: Int) {
        guard candidates.indices.contains(index) else { return }
        pathPopup.selectItem(at: index)
    }

    func submit() {
        saveClicked(nil)
    }

    static func ancestors(of book: Location) -> [Location] {
        var result: [Location] = [book]
        var current = book
        while let parent = current.parent {
            // 本地根 `/` 太宽，若已有更具体的目录则不列根。
            if parent.root == .local, parent.layers == [[]] { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    private func buildContent(profile: DisplayProfile) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let title = NSTextField(labelWithString: String(localized: "存为路径规则"))
        title.font = Theme.font(.panels, size: 13, weight: .semibold)
        title.textColor = Theme.text
        stack.addArrangedSubview(title)

        pathPopup.controlSize = .small
        pathPopup.font = Theme.font(.menus, size: Theme.defaultSize(.menus))
        pathPopup.lineBreakMode = .byTruncatingMiddle
        for (index, location) in candidates.enumerated() {
            let label: String
            if index == 0 {
                label = String(localized: "\(location.description)（这本书）")
            } else if index == 1 {
                label = String(localized: "\(location.description)（上一层，含其他书）")
            } else {
                label = location.description
            }
            pathPopup.addItem(withTitle: label)
        }
        if let menu = pathPopup.menu {
            Theme.applyMenuFont(to: menu)
        }
        if candidates.count > 1 {
            pathPopup.selectItem(at: 1)
        }
        pathPopup.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(pathPopup)

        let note = NSTextField(wrappingLabelWithString: String(
            localized: "位置在这个路径下的书按“\(profile.name)”的值显示；书里单独改过的值仍优先。已有同一路径的规则时，并入那条规则。"
        ))
        note.font = Theme.font(.panels, size: 11)
        note.textColor = Theme.text2
        stack.addArrangedSubview(note)

        cancelButton.setText(String(localized: "取消"))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        saveButton.setText(String(localized: "存为规则"))
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
            root.widthAnchor.constraint(equalToConstant: 308),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pathPopup.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])

        return root
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }

    @objc private func saveClicked(_ sender: Any?) {
        let index = pathPopup.indexOfSelectedItem
        guard candidates.indices.contains(index) else { return }
        let selected = candidates[index]
        close()
        onSave(selected)
    }
}
