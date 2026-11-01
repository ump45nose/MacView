import AppKit
import MVCommands
import MVFoundation
import os

/// 菜单、工具栏、按钮和按键执行命令的统一入口：组装上下文，经 CommandRegistry 执行并处理错误。
@MainActor
final class CommandDispatcher {
    let registry: CommandRegistry
    private let logger = Logger(category: "commands")

    init(registry: CommandRegistry) {
        self.registry = registry
    }

    func context(_ controller: ReaderWindowController?, scope: InputScope) -> CommandContext {
        CommandContext(session: controller?.session.id, scope: scope)
    }

    func isEnabled(_ id: CommandID, in controller: ReaderWindowController?, scope: InputScope) -> Bool {
        registry.isEnabled(id, context: context(controller, scope: scope))
    }

    /// 命令没登记或当前不可用时提示音；处理器抛出的错误显示在所在窗口上。
    func run(_ id: CommandID, arguments: [String: JSONValue]? = nil, in controller: ReaderWindowController?, scope: InputScope) {
        let context = context(controller, scope: scope)
        Task {
            do {
                try await registry.perform(id, arguments: arguments, context: context)
            } catch let error as CommandError {
                logger.debug("命令未执行：\(id.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
                NSSound.beep()
            } catch {
                logger.error("命令失败：\(id.rawValue, privacy: .public) \(String(describing: error), privacy: .public)")
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
