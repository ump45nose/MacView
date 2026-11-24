import AppKit
import MVCommands
import MVFoundation

/// 查看器右键菜单的点中目标上下文。
@MainActor
struct ContextMenuTarget {
    let window: ReaderWindowController
    let entries: [Entry]

    var origin: FileOrigin {
        FileOrigin(window: window, items: entries)
    }

    var locations: [Location] {
        entries.map(\.location)
    }
}

/// 查看器右键菜单条目提供者：按命令 ID 或 `DynamicMenuID` 为点中项生成 `NSMenuItem`。
///
/// 文件操作、资料库与元数据模块向这里注册专门提供者，保留按点中项计算标题、可用性、状态与动作的行为；
/// 未注册专门提供者的命令会生成通用菜单项，执行时经 `CommandDispatcher.run` 并把点中项写入 `CommandContext.selection`。
@MainActor
final class ContextMenuProvider {
    private weak var app: AppDelegate?
    private var commandProviders: [CommandID: (ContextMenuTarget) -> NSMenuItem?] = [:]
    private var dynamicProviders: [DynamicMenuID: (ContextMenuTarget) -> NSMenuItem?] = [:]

    init(app: AppDelegate) {
        self.app = app
    }

    func register(command id: CommandID, provider: @escaping (ContextMenuTarget) -> NSMenuItem?) {
        commandProviders[id] = provider
    }

    func register(dynamic id: DynamicMenuID, provider: @escaping (ContextMenuTarget) -> NSMenuItem?) {
        dynamicProviders[id] = provider
    }

    func menuItem(for command: CommandID, target: ContextMenuTarget) -> NSMenuItem? {
        if let provider = commandProviders[command] {
            return provider(target)
        }
        return genericMenuItem(for: command, target: target)
    }

    func menuItem(for dynamic: DynamicMenuID, target: ContextMenuTarget) -> NSMenuItem? {
        dynamicProviders[dynamic]?(target)
    }

    private func genericMenuItem(for id: CommandID, target: ContextMenuTarget) -> NSMenuItem? {
        guard let app, let dispatcher = app.dispatcher else { return nil }
        let selection = target.locations
        let title = app.menuTitle(for: id) ?? app.catalog.title(of: id)
        let item = MenuAction(title) { [weak app, weak window = target.window] in
            app?.dispatcher?.run(id, in: window, scope: .viewer, selection: selection)
        }.item
        if let state = app.menuState(for: id) {
            item.state = state
        }
        if let chord = app.catalog.menuBinding(for: id)?.sequence.first,
           let equivalent = KeyMapping.menuKeyEquivalent(for: chord) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        }
        item.isEnabled = dispatcher.isEnabled(id, in: target.window, scope: .viewer, selection: selection)
        return item
    }
}
