import AppKit
import MVFoundation
import MVLayout
import MVPlugins
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
    private(set) var activePathRulePopover: SavePathRulePopover?

    private var observedSession: SessionID?
    private var effectsObserver: NSObjectProtocol?
    private var pluginsObserver: NSObjectProtocol?
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
        panelView.pluginFiltersSection.onToggleFilter = { [weak self] pluginID, filterID, isOn in
            self?.setPluginFilter(plugin: pluginID, filter: filterID, enabled: isOn)
        }
        panelView.pluginFiltersSection.onChangeParameter = { [weak self] pluginID, filterID, key, value in
            self?.setPluginFilterParameter(plugin: pluginID, filter: filterID, key: key, value: value)
        }

        let list = panelView.profileListView
        list.onApplyToBook = { [weak self] profile in
            guard let owner = self?.owner else { return }
            DisplayProfileHelpers.applyToBook(profile, in: owner)
        }
        list.onApplyToGlobal = { [weak self] profile in
            self?.applyToGlobal(profile)
        }
        list.onSaveAsPathRule = { [weak self] profile, anchor in
            self?.openSavePathRulePopover(for: profile, from: anchor)
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
        if let pluginsObserver { NotificationCenter.default.removeObserver(pluginsObserver) }
    }

    func bind(to window: ReaderWindowController?) {
        guard window !== owner else { return }
        if let effectsObserver {
            NotificationCenter.default.removeObserver(effectsObserver)
            self.effectsObserver = nil
        }
        if let pluginsObserver {
            NotificationCenter.default.removeObserver(pluginsObserver)
            self.pluginsObserver = nil
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
            pluginsObserver = NotificationCenter.default.addObserver(
                forName: PluginCoordinator.didChangeNotification,
                object: nil,
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
            _ = owner.pluginFilterActivity.states
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
            panelView.applyPluginFilters([], hasBook: false, effectsEnabled: true)
            renderProfiles()
            return
        }
        let settings = owner.session.settings
        if case let .custom(red, green, blue) = settings.background {
            lastCustomColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        let hasBook = owner.session.book != nil
        panelView.apply(
            hasBook: hasBook,
            isVirtualBook: owner.session.isVirtualBook,
            effectsEnabled: owner.effectsEnabled,
            adjust: settings.effects.colorAdjust,
            background: settings.background,
            customColor: lastCustomColor
        )
        panelView.applyPluginFilters(
            buildPluginFilterItems(chain: settings.effects, activity: owner.pluginFilterActivity),
            hasBook: hasBook,
            effectsEnabled: owner.effectsEnabled
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

    // MARK: 插件滤镜

    private func buildPluginFilterItems(
        chain: EffectChain,
        activity: PluginFilterActivity
    ) -> [PluginFilterDisplayItem] {
        let coordinator = (NSApp.delegate as? AppDelegate)?.plugins
        let enabledPlugins = coordinator?.enabledPlugins ?? []
        let allPlugins = coordinator?.allPlugins ?? []

        var configuredByKey: [String: PluginFilterEffect] = [:]
        var chainEntries: [PluginFilterEffect] = []
        for effect in chain.effects {
            if case let .plugin(filter) = effect {
                let key = PluginFilterActivity.key(plugin: filter.plugin, filter: filter.filter)
                configuredByKey[key] = filter
                chainEntries.append(filter)
            }
        }

        var items: [PluginFilterDisplayItem] = []
        var coveredKeys: Set<String> = []
        for info in enabledPlugins {
            guard let manifest = info.manifest else { continue }
            for decl in manifest.filters {
                let key = PluginFilterActivity.key(plugin: info.id, filter: decl.id)
                coveredKeys.insert(key)
                let existing = configuredByKey[key]
                let isOn = existing?.enabled ?? false
                let values = existing?.parameters ?? Self.defaultParameters(for: decl)
                let state = isOn ? (activity.states[key] ?? .idle) : .idle
                items.append(PluginFilterDisplayItem(
                    pluginID: info.id,
                    filterID: decl.id,
                    title: decl.name,
                    subtitle: info.id,
                    isAvailable: true,
                    isOn: isOn,
                    parameters: decl.parameters,
                    values: values,
                    activity: state
                ))
            }
        }

        for entry in chainEntries {
            let key = PluginFilterActivity.key(plugin: entry.plugin, filter: entry.filter)
            guard !coveredKeys.contains(key) else { continue }
            coveredKeys.insert(key)
            let knownName = allPlugins
                .first { $0.id == entry.plugin }?
                .manifest?
                .filters
                .first { $0.id == entry.filter }?
                .name
            items.append(PluginFilterDisplayItem(
                pluginID: entry.plugin,
                filterID: entry.filter,
                title: knownName ?? entry.filter,
                subtitle: String(localized: "插件未启用"),
                isAvailable: false,
                isOn: entry.enabled,
                parameters: [],
                values: entry.parameters,
                activity: .idle
            ))
        }

        return items
    }

    private func setPluginFilter(plugin: String, filter: String, enabled: Bool) {
        guard let owner, owner.session.book != nil else { return }
        var chain = owner.session.settings.effects
        if enabled {
            let coordinator = (NSApp.delegate as? AppDelegate)?.plugins
            guard let decl = coordinator?.enabledPlugins
                .first(where: { $0.id == plugin })?
                .manifest?
                .filters
                .first(where: { $0.id == filter }) else {
                return
            }
            if let idx = chain.effects.firstIndex(where: {
                if case let .plugin(existing) = $0 { return existing.plugin == plugin && existing.filter == filter }
                return false
            }) {
                if case var .plugin(existing) = chain.effects[idx] {
                    existing.enabled = true
                    chain.effects[idx] = .plugin(existing)
                }
            } else {
                chain.effects.append(.plugin(PluginFilterEffect(
                    plugin: plugin,
                    filter: filter,
                    parameters: Self.defaultParameters(for: decl),
                    enabled: true
                )))
            }
        } else {
            chain.effects.removeAll {
                if case let .plugin(existing) = $0 { return existing.plugin == plugin && existing.filter == filter }
                return false
            }
        }
        owner.session.update { $0.effects = chain }
    }

    private func setPluginFilterParameter(plugin: String, filter: String, key: String, value: JSONValue) {
        guard let owner, owner.session.book != nil else { return }
        var chain = owner.session.settings.effects
        guard let idx = chain.effects.firstIndex(where: {
            if case let .plugin(existing) = $0 { return existing.plugin == plugin && existing.filter == filter }
            return false
        }), case var .plugin(existing) = chain.effects[idx] else { return }
        existing.parameters[key] = value
        chain.effects[idx] = .plugin(existing)
        owner.session.update { $0.effects = chain }
    }

    private static func defaultParameters(for decl: PluginFilterDeclaration) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for param in decl.parameters {
            if let defaultVal = param.defaultValue {
                result[param.key] = defaultVal
            } else {
                switch param.type {
                case .number: result[param.key] = .number(param.min ?? 0)
                case .bool: result[param.key] = .bool(false)
                case .choice: result[param.key] = .string(param.options?.first ?? "")
                }
            }
        }
        return result
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

    func applyToGlobal(_ profile: DisplayProfile) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak owner] in
            do {
                try await store.updateGlobal { global in
                    global.defaultBook = global.defaultBook.applying(profile.settings)
                }
                let groupsText = DisplayProfileHelpers.groupListText(profile.groups)
                owner?.content.statusBar.showMessage(
                    String(localized: "已把“\(profile.name)”套用到全局默认（\(groupsText)）")
                )
            } catch {
                owner?.content.statusBar.showMessage(ErrorText.describe(error))
            }
        }
    }

    func openSavePathRulePopover(for profile: DisplayProfile, from anchor: NSView) {
        guard let owner, let bookLocation = owner.session.book?.location, !owner.session.isVirtualBook else { return }
        let popover = SavePathRulePopover(profile: profile, bookLocation: bookLocation) { [weak self] prefix in
            self?.saveAsPathRule(profile: profile, prefix: prefix)
        }
        activePathRulePopover = popover
        popover.show(relativeTo: anchor)
    }

    func saveAsPathRule(profile: DisplayProfile, prefix: Location) {
        guard let owner else { return }
        let store = owner.services.settings
        Task { [weak owner] in
            do {
                try await store.updatePathRules { rules in
                    if let idx = rules.firstIndex(where: { $0.prefix == prefix }) {
                        rules[idx].settings.merge(profile.settings)
                    } else {
                        rules.append(PathRule(name: profile.name, prefix: prefix, settings: profile.settings))
                    }
                }
                let groupsText = DisplayProfileHelpers.groupListText(profile.groups)
                owner?.content.statusBar.showMessage(
                    String(localized: "已把“\(profile.name)”存为路径规则（\(groupsText)）")
                )
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
