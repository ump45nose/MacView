import AppKit
import MVFoundation
import MVLayout
import MVReading
import MVSettings
import Observation

struct EffectsPanelSettings: Codable, Equatable {}

/// 停靠面板“效果”：实时调色、阅读背景与显示配置管理。
@MainActor
final class EffectsPanel: DockPanel {
    typealias Settings = EffectsPanelSettings

    private(set) var settings: EffectsPanelSettings
    var onSettingsChange: (() -> Void)?
    private(set) weak var owner: ReaderWindowController?
    let panelView = EffectsPanelView()
    var view: NSView { panelView }

    private(set) var profiles: [DisplayProfile] = []
    private(set) var activeSavePopover: SaveProfilePopover?

    private var observedSession: SessionID?
    private var effectsObserver: NSObjectProtocol?
    private var profilesTask: Task<Void, Never>?
    private var colorPanelTarget: ColorPanelRelay?
    private var lastCustomColor = NSColor(srgbRed: 0x3B / 255, green: 0x4A / 255, blue: 0x5C / 255, alpha: 1)

    init(_ settings: EffectsPanelSettings?) {
        self.settings = settings ?? EffectsPanelSettings()
        panelView.onToggleEffects = { [weak self] enabled in
            guard let self, let owner else { return }
            owner.setEffectsEnabled(enabled)
            owner.content.statusBar.showMessage(
                enabled ? String(localized: "效果已打开") : String(localized: "效果已关闭，显示原图")
            )
        }
        panelView.onChangeAdjust = { [weak self] mutation in
            self?.updateColorAdjust(mutation)
        }
        panelView.onResetAll = { [weak self] in
            self?.updateColorAdjust { $0 = .identity }
        }
        panelView.onSelectBackground = { [weak self] background in
            self?.selectBackground(background)
        }
        panelView.onPickCustomColor = { [weak self] in
            self?.openColorPanel()
        }

        let list = panelView.profileListView
        list.onApplyToBook = { [weak self] profile in
            guard let owner = self?.owner else { return }
            DisplayProfileHelpers.applyToBook(profile, in: owner)
        }
        list.onUpdateWithCurrent = { [weak self] profile in
            self?.updateProfileWithCurrent(profile)
        }
        list.onRename = { [weak self] profile in
            self?.promptRename(profile)
        }
        list.onDelete = { [weak self] profile in
            self?.confirmDelete(profile)
        }
        list.onReorder = { [weak self] from, to in
            self?.reorderProfile(from: from, to: to)
        }
        list.onOpenSave = { [weak self] anchor in
            self?.openSavePopover(from: anchor)
        }
    }

    isolated deinit {
        profilesTask?.cancel()
        if let effectsObserver { NotificationCenter.default.removeObserver(effectsObserver) }
    }

    func bind(to window: ReaderWindowController?) {
        guard window !== owner else { return }
        if let effectsObserver {
            NotificationCenter.default.removeObserver(effectsObserver)
            self.effectsObserver = nil
        }
        profilesTask?.cancel()
        profilesTask = nil
        owner = window
        observedSession = window?.session.id
        if let window {
            effectsObserver = NotificationCenter.default.addObserver(
                forName: ReaderWindowController.effectsEnabledDidChangeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderState() }
            }
            observeProfiles(in: window.services.settings)
        } else {
            profiles = []
        }
        observeSession()
    }

    func addOptions(to menu: NSMenu) {}

    // MARK: 观察

    private func observeProfiles(in store: any SettingsStore) {
        let changes = store.changes()
        profilesTask = Task { [weak self] in
            let initial = await store.profiles()
            guard let self, !Task.isCancelled else { return }
            self.profiles = initial
            self.renderProfiles()
            for await change in changes {
                guard !Task.isCancelled else { return }
                if case .profiles = change {
                    let latest = await store.profiles()
                    guard !Task.isCancelled else { return }
                    self.profiles = latest
                    self.renderProfiles()
                }
            }
        }
    }

    private func observeSession() {
        guard let owner, let id = observedSession else {
            renderState()
            return
        }
        withObservationTracking {
            _ = owner.session.book
            _ = owner.session.settings
            _ = owner.session.isVirtualBook
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeSession()
            }
        }
        renderState()
    }

    private func renderState() {
        guard let owner else {
            panelView.apply(
                hasBook: false,
                isVirtualBook: false,
                effectsEnabled: true,
                adjust: .identity,
                background: .auto,
                customColor: lastCustomColor
            )
            renderProfiles()
            return
        }
        let settings = owner.session.settings
        if case let .custom(red, green, blue) = settings.background {
            lastCustomColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        panelView.apply(
            hasBook: owner.session.book != nil,
            isVirtualBook: owner.session.isVirtualBook,
            effectsEnabled: owner.effectsEnabled,
            adjust: settings.effects.colorAdjust,
            background: settings.background,
            customColor: lastCustomColor
        )
        renderProfiles()
    }

    private func renderProfiles() {
        panelView.profileListView.update(
            profiles: profiles,
            hasBook: owner?.session.book != nil,
            isVirtualBook: owner?.session.isVirtualBook ?? false
        )
    }

    // MARK: 调色与背景

    private func updateColorAdjust(_ mutation: (inout ColorAdjust) -> Void) {
        guard let owner, owner.session.book != nil else { return }
        var chain = owner.session.settings.effects
        var adjust = chain.colorAdjust
        mutation(&adjust)
        chain.colorAdjust = adjust
        owner.session.update { $0.effects = chain }
    }

    private func selectBackground(_ background: ViewerBackground) {
        guard let owner, owner.session.book != nil else { return }
        if case let .custom(red, green, blue) = background {
            lastCustomColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        owner.session.update { $0.background = background }
    }

    private func openColorPanel() {
        guard let owner, owner.session.book != nil else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = lastCustomColor
        let relay = ColorPanelRelay { [weak self] color in
            guard let self, let srgb = color.usingColorSpace(.sRGB) else { return }
            self.selectBackground(.custom(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            ))
        }
        colorPanelTarget = relay
        panel.setTarget(relay)
        panel.setAction(#selector(ColorPanelRelay.colorChanged(_:)))
        panel.orderFront(nil)
    }

    // MARK: 显示配置操作

    func openSavePopover(from anchor: NSView) {
        guard let owner, owner.session.book != nil else { return }
        let current = owner.session.settings
        let popover = SaveProfilePopover(
            settings: current,
            existingNames: Set(profiles.map(\.name))
        ) { [weak self] name, groups in
            self?.saveProfile(name: name, groups: groups, from: current)
        }
        activeSavePopover = popover
        popover.show(relativeTo: anchor)
    }

    func saveProfile(name: String, groups: Set<DisplayProfileGroup>, from resolved: ResolvedBookSettings) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak self, weak owner] in
            do {
                try await store.updateProfiles { list in
                    if let idx = list.firstIndex(where: { $0.name == name }) {
                        let existingID = list[idx].id
                        list[idx] = DisplayProfile(id: existingID, name: name, capturing: resolved, groups: groups)
                    } else {
                        list.append(DisplayProfile(name: name, capturing: resolved, groups: groups))
                    }
                }
                let latest = await store.profiles()
                self?.profiles = latest
                self?.renderProfiles()
                owner?.content.statusBar.showMessage(String(localized: "已保存“\(name)”"))
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }

    private func updateProfileWithCurrent(_ profile: DisplayProfile) {
        guard let owner, owner.session.book != nil else { return }
        let resolved = owner.session.settings
        let store = owner.services.settings
        Task { [weak self, weak owner] in
            do {
                try await store.updateProfiles { list in
                    guard let idx = list.firstIndex(where: { $0.id == profile.id }) else { return }
                    let target = list[idx]
                    list[idx] = DisplayProfile(id: target.id, name: target.name, capturing: resolved, groups: target.groups)
                }
                let latest = await store.profiles()
                self?.profiles = latest
                self?.renderProfiles()
                owner?.content.statusBar.showMessage(String(localized: "已用当前值更新“\(profile.name)”"))
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }

    private func promptRename(_ profile: DisplayProfile) {
        guard let window = owner?.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "重命名显示配置")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != profile.name else { return }
            self?.renameProfile(id: profile.id, to: trimmed)
        }
    }

    func renameProfile(id: UUID, to newName: String) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak self, weak owner] in
            do {
                try await store.updateProfiles { list in
                    guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
                    list[idx].name = newName
                }
                let latest = await store.profiles()
                self?.profiles = latest
                self?.renderProfiles()
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }

    private func confirmDelete(_ profile: DisplayProfile) {
        guard let window = owner?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "删除“\(profile.name)”？")
        alert.informativeText = String(localized: "已套用到各本书的设置不受影响。")
        alert.addButton(withTitle: String(localized: "删除"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteProfile(id: profile.id)
        }
    }

    func deleteProfile(id: UUID) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak self, weak owner] in
            do {
                try await store.updateProfiles { list in
                    list.removeAll { $0.id == id }
                }
                let latest = await store.profiles()
                self?.profiles = latest
                self?.renderProfiles()
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }

    func reorderProfile(from source: Int, to destination: Int) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak self, weak owner] in
            do {
                try await store.updateProfiles { list in
                    guard list.indices.contains(source), destination >= 0, destination < list.count else { return }
                    let item = list.remove(at: source)
                    list.insert(item, at: destination)
                }
                let latest = await store.profiles()
                self?.profiles = latest
                self?.renderProfiles()
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }
}

@MainActor
private final class ColorPanelRelay: NSObject {
    private let onColor: (NSColor) -> Void

    init(onColor: @escaping (NSColor) -> Void) {
        self.onColor = onColor
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        onColor(sender.color)
    }
}
