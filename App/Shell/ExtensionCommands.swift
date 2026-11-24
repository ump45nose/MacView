import AppKit
import Foundation
import MVCommands
import MVFoundation
import MVScripting
import MVServices
import MVSettings

/// 一次运行的对象：所在窗口与目标位置（选中项；没有选中项时为当前页）。
@MainActor
struct ScriptTarget {
    let window: ReaderWindowController?
    let locations: [Location]
}

/// 外部命令执行结果（W2.5 填充完整执行逻辑）。
enum ExternalRunResult: Sendable, Equatable {
    case succeeded(output: String?)
    case failed(String)
}

/// 把脚本与外部命令登记成命令，并在变化时增删；菜单与设置页由此刷新。
@MainActor
final class ExtensionCommands {
    private struct EventErrorKey: Hashable {
        let scriptID: String
        let message: String
    }

    private weak var app: AppDelegate?
    private let services: CoreServices
    private let externalRunner = ExternalCommandRunner()

    /// 应用类外部命令的打开器钩子，默认使用 `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`；自检可替换以验证参数。
    var applicationOpener: ExternalCommandRunner.ApplicationOpener {
        get { externalRunner.applicationOpener }
        set { externalRunner.applicationOpener = newValue }
    }

    /// 含有 problem 的全部脚本，供设置页列表使用。
    private(set) var allScripts: [ScriptInfo] = []
    /// 可执行的脚本（不含 problem），供菜单与命令登记使用。
    private(set) var scriptItems: [ScriptInfo] = []
    /// 外部命令列表（按名称排序）。
    private(set) var externalItems: [ExternalCommand] = []

    private var registeredScriptIDs: Set<String> = []
    private var registeredExternalIDs: Set<String> = []
    private var reportedEventErrors: Set<EventErrorKey> = []

    private var scriptsTask: Task<Void, Never>?
    private var externalCommandsTask: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var runtimeEventsTask: Task<Void, Never>?

    init(app: AppDelegate, services: CoreServices) {
        self.app = app
        self.services = services
    }

    func start() {
        registerBuiltInScriptCommands()
        registerContextMenuProvider()
        if let store = services.externalCommands {
            applyExternalCommands(store.value().commands, reload: false)
        }
        observeScripts()
        observeExternalCommands()
        observeScriptStorage()
        observeRuntimeEvents()
    }

    func stop() {
        scriptsTask?.cancel()
        scriptsTask = nil
        externalCommandsTask?.cancel()
        externalCommandsTask = nil
        storageTask?.cancel()
        storageTask = nil
        runtimeEventsTask?.cancel()
        runtimeEventsTask = nil
    }

    /// 执行外部命令：解析目标租约、展开模板并运行，结果写进 `scriptLog` 并在状态栏反馈。
    func runExternal(_ command: ExternalCommand, target: ScriptTarget) async -> ExternalRunResult {
        await externalRunner.run(command, target: target, services: services, app: app)
    }

    /// 填充「脚本」菜单：可执行脚本（按名称排序）→ 分隔线 → 外部命令（按名称排序）；`includeFixedItems` 为 true 时再追加固定三项。
    func populateScriptsMenu(_ menu: NSMenu, target: ScriptTarget, includeFixedItems: Bool) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let scripts = scriptItems
        let externals = externalItems

        for info in scripts {
            let commandID = Self.scriptCommandID(for: info.id)
            let item = MenuAction(info.name) { [weak self] in
                self?.runScript(info, target: target)
            }.item
            item.isEnabled = services.scriptRuntime != nil
            applyMenuShortcut(to: item, commandID: commandID)
            menu.addItem(item)
        }

        if !scripts.isEmpty && !externals.isEmpty {
            menu.addItem(.separator())
        }

        for command in externals {
            let commandID = Self.externalCommandID(for: command.id)
            let item = MenuAction(command.name) { [weak self] in
                guard let self else { return }
                let resolved = self.resolvedTarget(target)
                Task { @MainActor [weak self] in
                    _ = await self?.runExternal(command, target: resolved)
                }
            }.item
            item.isEnabled = true
            applyMenuShortcut(to: item, commandID: commandID)
            menu.addItem(item)
        }

        if includeFixedItems {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let fixedIDs: [CommandID] = [.scriptStopAll, .scriptRevealFolder, .scriptManage]
            let window = target.window ?? app?.mainController ?? app?.activeReaderController
            for id in fixedIDs {
                let title = app?.catalog.title(of: id) ?? id.rawValue
                let item = MenuAction(title) { [weak self] in
                    guard let self else { return }
                    let targetWindow = target.window ?? self.app?.mainController ?? self.app?.activeReaderController
                    self.app?.dispatcher?.run(id, in: targetWindow, scope: .global)
                }.item
                item.isEnabled = app?.dispatcher?.isEnabled(id, in: window, scope: .global) ?? false
                applyMenuShortcut(to: item, commandID: id)
                menu.addItem(item)
            }
        }

        Theme.applyMenuFont(to: menu)
    }

    /// 构造右键菜单使用的「脚本」子菜单项；无任何脚本和外部命令时禁用。
    func scriptsSubmenuItem(target: ScriptTarget, title: String = String(localized: "脚本")) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        populateScriptsMenu(submenu, target: target, includeFixedItems: false)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        holder.isEnabled = !submenu.items.isEmpty
        return holder
    }

    private func registerContextMenuProvider() {
        app?.contextMenuProvider?.register(dynamic: .scripts) { [weak self] target in
            self?.scriptsSubmenuItem(target: ScriptTarget(window: target.window, locations: target.locations))
        }
    }

    private func runScript(_ info: ScriptInfo, target: ScriptTarget, arguments: [String: JSONValue]? = nil) {
        guard let runtime = services.scriptRuntime else { return }
        let resolved = resolvedTarget(target)
        let commandID = Self.scriptCommandID(for: info.id)
        let callContext = ScriptCallContext(
            caller: commandID.rawValue,
            callerName: info.name,
            session: resolved.window?.session.id,
            selection: resolved.locations.map(ScriptLocationCodec.token(for:))
        )
        runtime.run(info.id, arguments: arguments, context: callContext)
    }

    private func applyMenuShortcut(to item: NSMenuItem, commandID: CommandID) {
        if let chord = app?.catalog.menuBinding(for: commandID)?.sequence.first,
           let equivalent = KeyMapping.menuKeyEquivalent(for: chord) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        }
    }

    // MARK: - 固定脚本命令

    private func registerBuiltInScriptCommands() {
        let registry = services.commands
        if let stopAll = CommandCatalog.builtInDescriptor(.scriptStopAll) {
            registry.register(stopAll, isEnabled: { [weak self] _ in
                self?.services.scriptRuntime != nil
            }) { [weak self] _, _ in
                self?.services.scriptRuntime?.stopAll()
            }
        }
        if let reveal = CommandCatalog.builtInDescriptor(.scriptRevealFolder) {
            registry.register(reveal, isEnabled: { [weak self] _ in
                self?.services.scriptLibrary != nil
            }) { [weak self] _, _ in
                guard let dir = self?.services.scriptLibrary?.directory else { return }
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            }
        }
    }

    // MARK: - 订阅变化

    private func observeScripts() {
        guard let library = services.scriptLibrary else { return }
        let stream = library.changes()
        scriptsTask = Task { [weak self] in
            for await scripts in stream {
                guard let self, !Task.isCancelled else { return }
                self.applyScripts(scripts)
            }
        }
    }

    private func observeExternalCommands() {
        guard let store = services.externalCommands else { return }
        let stream = store.changes()
        externalCommandsTask = Task { [weak self] in
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .reloaded:
                    self.app?.setFileProblem("external-commands.json", nil)
                    self.applyExternalCommands(store.value().commands, reload: true)
                case let .fileError(message):
                    self.app?.setFileProblem("external-commands.json", message)
                }
            }
        }
    }

    private func observeScriptStorage() {
        guard let storage = services.scriptStorage else { return }
        let stream = storage.changes()
        storageTask = Task { [weak self] in
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .reloaded:
                    self.app?.setFileProblem("script-storage.json", nil)
                case let .fileError(message):
                    self.app?.setFileProblem("script-storage.json", message)
                }
            }
        }
    }

    private func observeRuntimeEvents() {
        guard let runtime = services.scriptRuntime else { return }
        let stream = runtime.events()
        runtimeEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                if case let .failed(run, problem) = event {
                    self.handleScriptFailure(run: run, problem: problem)
                }
            }
        }
    }

    // MARK: - 动态登记与同步

    private func applyScripts(_ scripts: [ScriptInfo]) {
        allScripts = scripts
        let runnable = scripts
            .filter { $0.problem == nil }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        scriptItems = runnable
        // 脚本目录重载后，清除事件错误去重表，确保新一次加载能重新提示。
        reportedEventErrors.removeAll()

        let nextIDs = Set(runnable.map(\.id))
        let removed = registeredScriptIDs.subtracting(nextIDs)
        let registry = services.commands
        for id in removed {
            registry.unregister(Self.scriptCommandID(for: id))
        }

        for info in runnable {
            let commandID = Self.scriptCommandID(for: info.id)
            let descriptor = CommandDescriptor(
                id: commandID,
                title: LocalizedStringResource(stringLiteral: info.name),
                category: "script",
                symbol: "applescript",
                verbatimTitle: info.name
            )
            registry.register(descriptor, isEnabled: { [weak self] _ in
                self?.services.scriptRuntime != nil
            }) { [weak self] context, arguments in
                guard let self, let runtime = self.services.scriptRuntime else { return }
                let target = self.resolveTarget(for: context)
                let callContext = ScriptCallContext(
                    caller: commandID.rawValue,
                    callerName: info.name,
                    session: target.window?.session.id ?? context.session,
                    selection: target.locations.map(ScriptLocationCodec.token(for:))
                )
                runtime.run(info.id, arguments: arguments, context: callContext)
            }
        }

        registeredScriptIDs = nextIDs
        app?.reloadCatalog()
        app?.scriptEvents?.noteInitialScanCompleted()
    }

    private func applyExternalCommands(_ commands: [ExternalCommand], reload: Bool) {
        let sorted = commands.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        externalItems = sorted

        let nextIDs = Set(sorted.map(\.id))
        let removed = registeredExternalIDs.subtracting(nextIDs)
        let registry = services.commands
        for id in removed {
            registry.unregister(Self.externalCommandID(for: id))
        }

        for command in sorted {
            let commandID = Self.externalCommandID(for: command.id)
            let descriptor = CommandDescriptor(
                id: commandID,
                title: LocalizedStringResource(stringLiteral: command.name),
                category: "script",
                symbol: "terminal",
                verbatimTitle: command.name
            )
            registry.register(descriptor, isEnabled: { _ in true }) { [weak self] context, _ in
                guard let self else { return }
                let target = self.resolveTarget(for: context)
                _ = await self.runExternal(command, target: target)
            }
        }

        registeredExternalIDs = nextIDs
        if reload {
            app?.reloadCatalog()
        }
    }

    // MARK: - 错误提示与目标解析

    private func handleScriptFailure(run: ScriptRun, problem: ScriptProblem) {
        let firstLine = problem.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? problem.message
        if case .event = run.trigger {
            let key = EventErrorKey(scriptID: run.scriptID, message: firstLine)
            guard reportedEventErrors.insert(key).inserted else { return }
        }
        let scriptName = allScripts.first { $0.id == run.scriptID }?.name ?? run.scriptID
        let targetWindow: ReaderWindowController? = if let session = run.session {
            app?.controller(for: session)
        } else {
            app?.mainController ?? app?.activeReaderController
        }
        targetWindow?.content.statusBar.showMessage(String(localized: "\(scriptName) 出错：\(firstLine)"))
    }

    private func resolveTarget(for context: CommandContext) -> ScriptTarget {
        let window: ReaderWindowController? = if let session = context.session {
            app?.controller(for: session) ?? app?.mainController ?? app?.activeReaderController
        } else {
            app?.mainController ?? app?.activeReaderController
        }
        return resolvedTarget(ScriptTarget(window: window, locations: context.selection))
    }

    private func resolvedTarget(_ target: ScriptTarget) -> ScriptTarget {
        let window = target.window ?? app?.mainController ?? app?.activeReaderController
        if !target.locations.isEmpty {
            return ScriptTarget(window: window, locations: target.locations)
        }
        if let session = window?.session,
           let pages = session.book?.pages,
           pages.indices.contains(session.currentPage) {
            return ScriptTarget(window: window, locations: [pages[session.currentPage].id])
        }
        return ScriptTarget(window: window, locations: [])
    }

    static func scriptCommandID(for id: String) -> CommandID {
        CommandID("script.\(id)")
    }

    static func externalCommandID(for id: String) -> CommandID {
        CommandID("external.\(id)")
    }
}
