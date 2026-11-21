import AppKit
import MVCommands
import MVFoundation
import os

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
/// 未注册专门提供者的命令会生成通用菜单项，执行时经 `CommandRegistry.perform` 并把点中项写入 `CommandContext.selection`。
@MainActor
final class ContextMenuProvider {
    private weak var app: AppDelegate?
    private let logger = Logger(category: "commands")
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
        guard let app, let registry = app.services?.commands else { return nil }
        let context = CommandContext(session: target.window.session.id, scope: .viewer, selection: target.locations)
        let title = app.menuTitle(for: id) ?? app.catalog.title(of: id)
        let item = MenuAction(title) { [weak self, weak window = target.window] in
            self?.performGeneric(id, context: context, in: window)
        }.item
        if let state = app.menuState(for: id) {
            item.state = state
        }
        if let chord = app.catalog.menuBinding(for: id)?.sequence.first,
           let equivalent = KeyMapping.menuKeyEquivalent(for: chord) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        }
        item.isEnabled = registry.isEnabled(id, context: context)
        return item
    }

    private func performGeneric(_ id: CommandID, context: CommandContext, in controller: ReaderWindowController?) {
        guard let app, let registry = app.services?.commands else { return }
        Task { @MainActor in
            do {
                try await registry.perform(id, arguments: nil, context: context)
            } catch let error as CommandError {
                logger.debug("右键菜单命令未执行：\(id.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                if case .disabled = error, app.dispatcher?.onDisabledCommand?(id, controller) == true { return }
                NSSound.beep()
            } catch {
                logger.error("右键菜单命令失败：\(id.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = String(localized: "无法完成操作")
                alert.informativeText = ErrorText.describe(error)
                if let window = controller?.window {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}
