import AppKit
import MVFoundation
import MVIO
import MVLibraryData
import MVServices

/// 不可用条目的原因弹出层：“找不到…”或“网络卷没有连接”，按钮“移除”；卷的情况另有“连接”，打开 `Location.Root.mountURL`。
/// 历史、书签、播放列表面板共用；同一时间只显示一个。
@MainActor
final class UnavailableReasonPopover: NSObject, NSPopoverDelegate {
    private static var current: UnavailableReasonPopover?

    private let popover = NSPopover()
    private let onRemove: () -> Void
    private let mountURL: URL?

    /// 在 `view` 的 `rect` 旁弹出。`what` 是条目的说法，例如“这本书”“原文件”。
    static func show(
        _ availability: Availability, what: String, location: Location,
        relativeTo rect: NSRect, of view: NSView, onRemove: @escaping () -> Void
    ) {
        current?.popover.close()
        let shown = UnavailableReasonPopover(availability, what: what, location: location, onRemove: onRemove)
        current = shown
        shown.popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    private init(_ availability: Availability, what: String, location: Location, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        let title: String
        let message: String
        let detail: String
        if case let .volumeUnavailable(root) = availability {
            mountURL = root.mountURL
            title = String(localized: "网络卷没有连接")
            message = String(localized: "它所在的网络卷现在没有挂载。连接后这一条会自动恢复。")
            detail = root.mountURL?.absoluteString ?? root.displayName
        } else {
            mountURL = nil
            title = String(localized: "找不到\(what)")
            message = String(localized: "可能已被删除，或在 MacView 之外被移走。放回原处后这一条会自动恢复。")
            detail = location.displayPath
        }
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let controller = NSViewController()
        controller.view = makeContent(title: title, message: message, detail: detail)
        popover.contentViewController = controller
    }

    private func makeContent(title: String, message: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.serif(14)
        titleLabel.textColor = Theme.text
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Theme.text2
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = Theme.text2
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.isSelectable = true

        let remove = Self.button(String(localized: "移除"), primary: false)
        remove.target = self
        remove.action = #selector(removePressed(_:))
        var buttons: [NSView] = [NSView(), remove]
        if mountURL != nil {
            let connect = Self.button(String(localized: "连接"), primary: true)
            connect.target = self
            connect.action = #selector(connectPressed(_:))
            buttons.append(connect)
        }
        let actions = NSStackView(views: buttons)
        actions.spacing = 6

        let stack = NSStackView(views: [titleLabel, messageLabel, detailLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let width: CGFloat = 280
        for label in [messageLabel, detailLabel] { label.preferredMaxLayoutWidth = width - 24 }
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        return stack
    }

    static func button(_ title: String, primary: Bool) -> FlatButton {
        let button = primary
            ? FlatButton(font: .systemFont(ofSize: 12), fill: Theme.primary, foreground: Theme.onPrimary, radius: 5, height: 22, padding: 9)
            : FlatButton(font: .systemFont(ofSize: 12), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 5, height: 22, padding: 9)
        button.setText(title)
        return button
    }

    @objc private func removePressed(_ sender: Any?) {
        popover.close()
        onRemove()
    }

    @objc private func connectPressed(_ sender: Any?) {
        popover.close()
        if let mountURL { NSWorkspace.shared.open(mountURL) }
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

/// 行右侧的不可用标记：卷没有连接是“⏏”，找不到是“⚠”；点击弹出原因。
@MainActor
final class UnavailableBadge: NSButton {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        isBordered = false
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 11, weight: .regular)
        contentTintColor = Theme.text2
        target = self
        action = #selector(pressed(_:))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 可用或还没有结果时隐藏。
    func show(_ availability: Availability?) {
        switch availability {
        case .volumeUnavailable:
            image = NSImage(systemSymbolName: "eject", accessibilityDescription: String(localized: "网络卷没有连接"))
            toolTip = String(localized: "网络卷没有连接")
            isHidden = false
        case .missing:
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: String(localized: "找不到"))
            toolTip = String(localized: "找不到")
            isHidden = false
        case .available, nil:
            isHidden = true
        }
    }

    @objc private func pressed(_ sender: Any?) { onPress?() }
}

extension Availability {
    var isUnavailable: Bool { self != .available }
}

extension Location {
    /// 界面上的路径：本机的家目录缩写为 `~`，网络卷以共享名开头。
    var displayPath: String {
        guard root == .local else { return description }
        return (description as NSString).abbreviatingWithTildeInPath
    }
}

/// 资料库面板的可用性：只检查可见行，结果只在内存。
///
/// 重查时机：面板显示或滚出新行（`visibleChanged`）、App 重新激活、卷挂载或卸载、卷状态变化、
/// `appliedFileChanges` 涉及的条目。已检查过的位置在下一次重查前不再提交。
@MainActor
final class LibraryAvailability {
    private(set) var states: [Location: Availability] = [:]
    /// 结果变化后调用，面板据此重画可见行。
    var onChange: (() -> Void)?
    /// 面板当前可见行的位置。
    var visibleLocations: () -> [Location] = { [] }
    /// 面板的视图：不在窗口里或被隐藏时不检查。
    weak var view: NSView?

    private weak var services: CoreServices?
    private var checked: Set<Location> = []
    private var generation: [Location: Int] = [:]
    private var counter = 0
    private var checks: [Int: Task<Void, Never>] = [:]
    private var observers: [Task<Void, Never>] = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    deinit {
        observers.forEach { $0.cancel() }
        checks.values.forEach { $0.cancel() }
    }

    func state(of location: Location) -> Availability? { states[location] }

    /// 换服务（窗口）时重新订阅；同一个服务不重复订阅。
    func attach(_ services: CoreServices?) {
        guard services !== self.services else { return }
        stop()
        self.services = services
        states = [:]
        checked = []
        guard let services, services.availability != nil else { return }
        let health = services.sources.volumeHealth()
        let applied = services.appliedFileChanges()
        observers = [
            Task { [weak self] in
                // 快照里还带在途计数，只看状态；新出现的健康卷不算变化。
                var last: [Location.Root: VolumeState] = [:]
                for await volumes in health {
                    let current = Dictionary(volumes.map { ($0.root, $0.state) }, uniquingKeysWith: { $1 })
                    let changed = Set(last.keys).union(current.keys).contains { (last[$0] ?? .healthy) != (current[$0] ?? .healthy) }
                    last = current
                    guard let self else { return }
                    if changed { recheckAll() }
                }
            },
            Task { [weak self] in
                for await batch in applied {
                    let touched = batch.flatMap { change -> [Location] in
                        switch change {
                        case let .removed(location): [location]
                        case let .added(entry): [entry.location]
                        case let .moved(from, to): [from, to.location]
                        }
                    }
                    guard let self else { return }
                    recheck { location in touched.contains { location.hasPrefix($0) } }
                }
            },
        ]
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckAll() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        tokens = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recheck)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main, using: recheck)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main, using: recheck)),
        ]
    }

    func stop() {
        observers.forEach { $0.cancel() }
        observers = []
        checks.values.forEach { $0.cancel() }
        checks = [:]
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    /// 可见行变化：只提交还没检查过的位置。
    func visibleChanged() {
        guard let checker = services?.availability, let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        var seen: Set<Location> = []
        let pending = visibleLocations().filter { !checked.contains($0) && seen.insert($0).inserted }
        guard !pending.isEmpty else { return }
        checked.formUnion(pending)
        counter += 1
        let token = counter
        for location in pending { generation[location] = token }
        let stream = checker.check(pending)
        checks[token] = Task { [weak self] in
            for await batch in stream {
                guard let self else { return }
                var changed = false
                for (location, state) in batch where generation[location] == token && states[location] != state {
                    states[location] = state
                    changed = true
                }
                if changed { onChange?() }
            }
            self?.checks[token] = nil
        }
    }

    /// 全部可见行重查；旧结果保留到新结果到达，避免闪烁。
    func recheckAll() {
        checked = []
        visibleChanged()
    }

    /// 满足条件的位置重查。
    func recheck(where affected: (Location) -> Bool) {
        checked = checked.filter { !affected($0) }
        visibleChanged()
    }

    /// 面板重新读取后只保留仍在的位置。
    func retain(_ locations: Set<Location>) {
        states = states.filter { locations.contains($0.key) }
        checked.formIntersection(locations)
        generation = generation.filter { locations.contains($0.key) }
    }
}
