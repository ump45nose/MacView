import AppKit
import Foundation
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVPipeline
import MVPlugins
import MVReading
import MVScripting
import MVServices
import MVSettings
import Synchronization

/// 供 `Location.Root.displayName` 与 `ErrorText` 无隔离读取的插件来源状态快照。
final class PluginSourceLookup: Sendable {
    struct Entry: Sendable, Equatable {
        var name: String
        var pluginID: String
        var isPluginEnabled: Bool
    }

    static let shared = PluginSourceLookup()

    private let entries = Mutex<[UUID: Entry]>([:])

    func update(_ map: [UUID: Entry]) {
        entries.withLock { $0 = map }
    }

    func entry(for sourceID: UUID) -> Entry? {
        entries.withLock { $0[sourceID] }
    }
}

/// 协调插件的命令登记、菜单填充、来源打开与状态同步。
@MainActor
final class PluginCoordinator {
    static let didChangeNotification = Notification.Name("MacView.PluginCoordinator.didChange")

    private struct CommandEntry: Equatable {
        let pluginID: String
        let pluginName: String
        let command: PluginCommandDeclaration
    }

    private struct PanelEntry: Equatable {
        let pluginID: String
        let pluginName: String
        let directory: URL
        let panel: PluginPanelDeclaration
        let permissions: Set<PluginPermission>
    }

    private let services: CoreServices
    private let scripts: ExtensionCommands

    private(set) var allPlugins: [PluginInfo] = []
    private(set) var enabledPlugins: [PluginInfo] = []
    private(set) var statuses: [String: PluginStatus] = [:]
    private(set) var settingsProblem: String?

    var pluginsDirectory: URL? { services.pluginLibrary?.directory }
    var pluginSettingsStore: JSONDocumentStore<PluginSettingsFile>? { services.pluginSettings }
    var pluginSecrets: PluginSecrets? { services.pluginSecrets }
    var pluginHost: PluginHost? { services.pluginHost }
    var sourceInstances: [SourceInstance] { services.pluginSettings?.value().sources ?? [] }

    /// 插件启用集合或版本变化时回调（供 AppDelegate 刷新各窗口插件滤镜）。
    var onAvailabilityChange: (() -> Void)?

    private var registeredCommandIDs: Set<CommandID> = []
    private var lastCommandEntries: [CommandEntry] = []
    private var registeredPanelCommandIDs: Set<CommandID> = []
    private var lastPanelEntries: [PanelEntry] = []
    private var libraryTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var openSourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(services: CoreServices, scripts: ExtensionCommands) {
        self.services = services
        self.scripts = scripts
    }

    func start() {
        syncState(reloadCatalog: false)
        observeLibrary()
        observeSettings()
        observeStatuses()
    }

    func stop() {
        libraryTask?.cancel()
        libraryTask = nil
        settingsTask?.cancel()
        settingsTask = nil
        statusTask?.cancel()
        statusTask = nil
        for task in openSourceTasks.values { task.cancel() }
        openSourceTasks.removeAll()
        for id in registeredPanelCommandIDs {
            services.commands.unregister(id)
        }
        registeredPanelCommandIDs.removeAll()
        lastPanelEntries.removeAll()
        DockPanels.setPluginTypes([])
        PluginSourceLookup.shared.update([:])
    }

    /// 供「脚本」动态菜单在外部命令之后追加每个插件的子菜单。
    func populatePluginMenus(_ menu: NSMenu, target: ScriptTarget) {
        let withCommands = enabledPlugins.filter { info in
            guard let manifest = info.manifest else { return false }
            return !manifest.commands.isEmpty
        }
        guard !withCommands.isEmpty else { return }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for info in withCommands {
            guard let manifest = info.manifest else { continue }
            let submenu = NSMenu(title: manifest.name)
            submenu.autoenablesItems = false
            for command in manifest.commands {
                let commandID = Self.commandID(plugin: info.id, command: command.id)
                let item = MenuAction(command.title) { [weak self] in
                    self?.runCommand(plugin: info, command: command, target: target)
                }.item
                item.isEnabled = services.pluginHost != nil
                scripts.applyMenuShortcut(to: item, commandID: commandID)
                submenu.addItem(item)
            }
            let holder = NSMenuItem(title: manifest.name, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            menu.addItem(holder)
        }
    }

    /// 供主菜单「脚本」动态段构造插件子菜单描述。
    func mainMenuPluginGroups() -> [(title: String, commandIDs: [CommandID])] {
        enabledPlugins.compactMap { info in
            guard let manifest = info.manifest, !manifest.commands.isEmpty else { return nil }
            let ids = manifest.commands.map { Self.commandID(plugin: info.id, command: $0.id) }
            return (manifest.name, ids)
        }
    }

    /// 供主菜单「窗口」动态段 `pluginPanels` 构造插件面板分组。
    func mainMenuPluginPanelGroups() -> [(title: String, panels: [(id: PanelID, commandID: CommandID, title: String)])] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var grouped: [String: [(id: PanelID, commandID: CommandID, title: String)]] = [:]
        for entry in lastPanelEntries {
            if titles[entry.pluginID] == nil {
                order.append(entry.pluginID)
                titles[entry.pluginID] = entry.pluginName
            }
            let pid = Self.panelID(plugin: entry.pluginID, panel: entry.panel.id)
            let cid = Self.panelToggleCommandID(plugin: entry.pluginID, panel: entry.panel.id)
            grouped[entry.pluginID, default: []].append((pid, cid, entry.panel.title))
        }
        return order.compactMap { pluginID in
            guard let title = titles[pluginID], let panels = grouped[pluginID], !panels.isEmpty else { return nil }
            return (title, panels)
        }
    }

    /// 文件 › 打开来源。
    func populateSourcesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let sources = services.pluginSettings?.value().sources ?? []
        let pluginNames = Dictionary(
            allPlugins.map { ($0.id, $0.manifest?.name ?? $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for source in sources {
            let pluginName = pluginNames[source.plugin] ?? source.plugin
            let title = "\(source.name) · \(pluginName)"
            let sourceID = source.id
            let item = MenuAction(title) { [weak self] in
                self?.openSource(sourceID, in: self?.scripts.app?.activeReaderController)
            }.item
            item.isEnabled = true
            menu.addItem(item)
        }
        if !sources.isEmpty {
            menu.addItem(.separator())
        }
        let manage = MenuAction(String(localized: "管理来源…")) { [weak self] in
            self?.scripts.app?.openSettings(page: .extensions, scrollTo: "settings.extensions.plugins")
        }.item
        manage.isEnabled = NSApp.modalWindow == nil
        menu.addItem(manage)
        Theme.applyMenuFont(to: menu)
    }

    /// 打开指定插件来源实例：根里直接是媒体时当书打开，有子目录或压缩包时书架进入该目录；无窗口时新开窗口。
    func openSource(_ id: UUID, in controller: ReaderWindowController?) {
        guard let target = controller ?? scripts.app?.activeReaderController ?? scripts.app?.newWindow() else { return }
        let root = PluginSourceProvider.root(for: id)
        let location = Location(root: root, layers: [[]])
        let windowKey = ObjectIdentifier(target)
        openSourceTasks[windowKey]?.cancel()
        let sources = services.sources
        openSourceTasks[windowKey] = Task { [weak self, weak target] in
            guard let self else { return }
            defer { self.openSourceTasks[windowKey] = nil }
            guard let target else { return }
            do {
                let provider = try sources.provider(for: location)
                var entries: [Entry] = []
                for try await batch in provider.children(of: location, priority: .visible) {
                    guard !Task.isCancelled else { return }
                    entries.append(contentsOf: batch.filter(ReadingListing.isVisible))
                }
                guard !Task.isCancelled else { return }
                let hasMedia = entries.contains { $0.kind == .image || $0.kind == .video }
                let hasBooks = entries.contains { entry in
                    switch entry.kind {
                    case .directory, .archive: true
                    case .image, .video, .other: false
                    }
                }
                if hasMedia {
                    target.openBook(location)
                    if hasBooks {
                        target.showBookshelf(directory: location)
                    }
                } else if hasBooks {
                    target.showBookshelf(directory: location)
                    // 来源上次打开失败、主区还显示它的错误（如在错误页点「重试」）：重新载入主区，清掉旧错误。
                    if target.session.book?.location == location, target.session.loadError != nil {
                        target.openBook(location)
                    }
                } else {
                    target.openBook(location)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // 失败路径交给 ReaderSession.open，复用查看器的「无法访问 <名称>」与「重试」。
                target.openBook(location)
            }
        }
    }

    /// 插件来源根的显示名；非插件来源或已删除的来源返回 nil。
    func sourceName(for root: Location.Root) -> String? {
        guard let sourceID = PluginSourceProvider.sourceID(of: root) else { return nil }
        return services.pluginSettings?.value().sources.first { $0.id == sourceID }?.name
    }

    /// 当前效果链里已启用且对应插件处于启用状态的插件滤镜解析结果。
    func resolvedFilters(in chain: EffectChain) -> ResolvedPluginFilters {
        guard let host = services.pluginHost else { return .empty }
        let enabledByID = Dictionary(uniqueKeysWithValues: host.enabledPlugins().map { ($0.id, $0) })
        var requests: [PluginFilterRequest] = []
        var names: [String: String] = [:]
        var versions: [String: String] = [:]
        var pluginNames: [String: String] = [:]
        for effect in chain.effects {
            guard case let .plugin(filter) = effect,
                  filter.enabled,
                  let info = enabledByID[filter.plugin],
                  let manifest = info.manifest else { continue }
            requests.append(PluginFilterRequest(plugin: filter.plugin, filter: filter.filter, parameters: filter.parameters))
            let key = PluginFilterActivity.key(plugin: filter.plugin, filter: filter.filter)
            names[key] = manifest.filters.first { $0.id == filter.filter }?.name ?? filter.filter
            versions[filter.plugin] = manifest.version
            pluginNames[filter.plugin] = manifest.name
        }
        return ResolvedPluginFilters(requests: requests, names: names, versions: versions, pluginNames: pluginNames)
    }

    static func commandID(plugin: String, command: String) -> CommandID {
        CommandID("plugin.\(plugin).\(command)")
    }

    static func panelID(plugin: String, panel: String) -> PanelID {
        PanelID("plugin.\(plugin).\(panel)")
    }

    static func panelToggleCommandID(plugin: String, panel: String) -> CommandID {
        CommandID("plugin.\(plugin).panel.\(panel)")
    }

    // MARK: - 观察变化

    private func observeLibrary() {
        guard let library = services.pluginLibrary else { return }
        let stream = library.changes()
        libraryTask = Task { [weak self] in
            var firstScan = true
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                self.syncState(reloadCatalog: true)
                if firstScan {
                    firstScan = false
                    self.scripts.app?.scriptEvents?.noteInitialPluginsScanned()
                }
            }
        }
    }

    private func observeSettings() {
        guard let store = services.pluginSettings else { return }
        let stream = store.changes()
        settingsTask = Task { [weak self] in
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .reloaded:
                    self.settingsProblem = nil
                    self.scripts.app?.setFileProblem("plugins.json", nil)
                    self.syncState(reloadCatalog: true)
                case let .fileError(message):
                    self.settingsProblem = message
                    self.scripts.app?.setFileProblem("plugins.json", message)
                    self.notifyChange()
                }
            }
        }
    }

    private func observeStatuses() {
        guard let host = services.pluginHost else { return }
        let stream = host.statusChanges()
        statusTask = Task { [weak self] in
            for await next in stream {
                guard let self, !Task.isCancelled else { return }
                self.statuses = next
                if self.syncPanels() {
                    self.scripts.app?.reloadCatalog()
                }
                self.notifyChange()
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - 同步命令与来源快照

    private func syncState(reloadCatalog: Bool) {
        allPlugins = services.pluginLibrary?.plugins() ?? []
        enabledPlugins = services.pluginHost?.enabledPlugins() ?? []
        if let host = services.pluginHost {
            statuses = host.statuses()
        }
        updateSourceLookup()

        var entries: [CommandEntry] = []
        for info in enabledPlugins {
            guard let manifest = info.manifest else { continue }
            for command in manifest.commands {
                entries.append(CommandEntry(pluginID: info.id, pluginName: manifest.name, command: command))
            }
        }

        let commandsChanged = entries != lastCommandEntries
        if commandsChanged {
            lastCommandEntries = entries
            let nextIDs = Set(entries.map { Self.commandID(plugin: $0.pluginID, command: $0.command.id) })
            let removed = registeredCommandIDs.subtracting(nextIDs)
            let registry = services.commands
            for id in removed {
                registry.unregister(id)
            }
            let byID = Dictionary(uniqueKeysWithValues: enabledPlugins.map { ($0.id, $0) })
            for entry in entries {
                guard let info = byID[entry.pluginID] else { continue }
                let id = Self.commandID(plugin: entry.pluginID, command: entry.command.id)
                let descriptor = CommandDescriptor(
                    id: id,
                    title: LocalizedStringResource(stringLiteral: entry.command.title),
                    category: entry.pluginName,
                    symbol: "puzzlepiece.extension",
                    verbatimTitle: entry.command.title
                )
                registry.register(descriptor, isEnabled: { [weak self] _ in
                    self?.services.pluginHost != nil
                }) { [weak self] context, arguments in
                    guard let self else { return }
                    let target = self.scripts.resolveTarget(for: context)
                    self.runCommand(plugin: info, command: entry.command, target: target, session: context.session, arguments: arguments)
                }
            }
            registeredCommandIDs = nextIDs
        }
        let panelsChanged = syncPanels()
        if (commandsChanged || panelsChanged), reloadCatalog {
            scripts.app?.reloadCatalog()
        }
        notifyChange()
        onAvailabilityChange?()
    }

    /// 同步已启用且就绪（`.ready` 或 `.running`）插件的面板类型、显示命令与打开中面板的快照。
    private func syncPanels() -> Bool {
        let pluginStates = services.pluginSettings?.value().plugins ?? [:]
        let byID = Dictionary(uniqueKeysWithValues: enabledPlugins.map { ($0.id, $0) })
        var entries: [PanelEntry] = []
        for info in enabledPlugins {
            guard let manifest = info.manifest, !manifest.panels.isEmpty else { continue }
            switch statuses[info.id] {
            case .ready?, .running?:
                break
            default:
                continue
            }
            let granted = pluginStates[info.id]?.grantedPermissions ?? []
            let effectivePermissions = Set(manifest.permissions).intersection(granted)
            for panel in manifest.panels {
                entries.append(PanelEntry(
                    pluginID: info.id,
                    pluginName: manifest.name,
                    directory: info.directory,
                    panel: panel,
                    permissions: effectivePermissions
                ))
            }
        }

        guard entries != lastPanelEntries else { return false }
        lastPanelEntries = entries

        let registry = services.commands
        let nextCommandIDs = Set(entries.map { Self.panelToggleCommandID(plugin: $0.pluginID, panel: $0.panel.id) })
        for id in registeredPanelCommandIDs.subtracting(nextCommandIDs) {
            registry.unregister(id)
        }

        var dockTypes: [DockPanelType] = []
        var snapshots: [PanelID: PluginPanelSnapshot] = [:]
        dockTypes.reserveCapacity(entries.count)

        for entry in entries {
            guard let info = byID[entry.pluginID] else { continue }
            let panelID = Self.panelID(plugin: entry.pluginID, panel: entry.panel.id)
            let commandID = Self.panelToggleCommandID(plugin: entry.pluginID, panel: entry.panel.id)
            let title = String(localized: "显示或隐藏 \(entry.panel.title)")
            let symbol = entry.panel.symbol ?? "puzzlepiece.extension"
            let descriptor = CommandDescriptor(
                id: commandID,
                title: LocalizedStringResource(stringLiteral: title),
                category: "window",
                symbol: symbol,
                verbatimTitle: title
            )
            registry.register(descriptor, isEnabled: { [weak self] context in
                self?.scripts.app?.controller(for: context.session) != nil
            }) { [weak self] context, _ in
                guard let self, let app = self.scripts.app, let type = DockPanels.type(panelID) else { return }
                app.dock?.togglePanel(type, in: app.controller(for: context.session)?.dock)
            }

            let panelDecl = entry.panel
            let coreServices = services
            let edge: DockEdge = switch panelDecl.defaultEdge {
            case .left: .left
            case .bottom: .bottom
            case .right, nil: .right
            }
            dockTypes.append(DockPanelType(
                id: panelID,
                title: panelDecl.title,
                symbol: symbol,
                toggleCommand: commandID,
                defaultEdge: edge,
                make: { _ in PluginWebPanel(plugin: info, panel: panelDecl, services: coreServices) }
            ))
            snapshots[panelID] = PluginPanelSnapshot(
                pluginID: entry.pluginID,
                pluginName: entry.pluginName,
                directory: entry.directory,
                declaration: panelDecl,
                permissions: entry.permissions
            )
        }
        registeredPanelCommandIDs = nextCommandIDs

        // 先更新已打开面板的快照并按需重建，再更新停靠注册表。
        if let dock = scripts.app?.dock {
            let openPanels = dock.docks.flatMap { Array($0.panels.values) } + dock.floatingWindows.values.map(\.panel)
            for case let webPanel as PluginWebPanel in openPanels {
                if let snapshot = snapshots[webPanel.panelID] {
                    webPanel.updateSnapshot(snapshot)
                }
            }
        }
        DockPanels.setPluginTypes(dockTypes)
        return true
    }

    private func updateSourceLookup() {
        let enabledIDs = Set(enabledPlugins.map(\.id))
        let sources = services.pluginSettings?.value().sources ?? []
        var map: [UUID: PluginSourceLookup.Entry] = [:]
        map.reserveCapacity(sources.count)
        for source in sources {
            map[source.id] = PluginSourceLookup.Entry(
                name: source.name,
                pluginID: source.plugin,
                isPluginEnabled: enabledIDs.contains(source.plugin)
            )
        }
        PluginSourceLookup.shared.update(map)
    }

    // MARK: - 执行插件命令

    private func runCommand(
        plugin info: PluginInfo,
        command: PluginCommandDeclaration,
        target: ScriptTarget,
        session: SessionID? = nil,
        arguments: [String: JSONValue]? = nil
    ) {
        guard let host = services.pluginHost else { return }
        let resolved = session == nil ? scripts.resolvedTarget(target) : target
        let pluginName = info.manifest?.name ?? info.id
        let callContext = ScriptCallContext(
            caller: "plugin:\(info.id)",
            callerName: pluginName,
            session: resolved.window?.session.id ?? session,
            selection: resolved.locations.map(ScriptLocationCodec.token(for:))
        )
        let targetSession = callContext.session
        let pluginID = info.id
        let commandID = command.id
        Task { @MainActor [weak self] in
            do {
                _ = try await host.runCommand(
                    plugin: pluginID,
                    command: commandID,
                    arguments: arguments,
                    context: callContext
                )
            } catch is CancellationError {
                return
            } catch PluginError.cancelled {
                return
            } catch {
                guard let self else { return }
                let message = error.localizedDescription
                self.services.scriptLog?.append(source: pluginName, level: .error, text: message)
                self.scripts.showFailureStatus(source: pluginName, session: targetSession, message: message)
            }
        }
    }
}
