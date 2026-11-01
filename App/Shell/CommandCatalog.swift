import Foundation
import MVCommands

extension CommandID {
    /// App 侧的界面命令：关闭当前窗口或标签页。
    static let windowClose = CommandID("window.close")
}

/// 命令清单、生效的按键绑定与菜单模型：Core 的默认命令加上 App 侧的界面命令。
struct CommandCatalog {
    /// 多键序列的超时，BindingResolver 与待定提示共用。
    static let sequenceTimeout: Duration = .seconds(1)

    static let appCommands: [CommandDescriptor] = [
        CommandDescriptor(
            id: .windowClose, title: LocalizedStringResource("关闭"), category: "window",
            defaultBindings: [KeyBinding(sequence: [KeyChord("w", modifiers: .command)], command: .windowClose, scope: .global)]
        ),
    ]

    let bindings: [KeyBinding]
    let menu: MenuModel
    private let descriptors: [CommandID: CommandDescriptor]

    /// `user` 是 keybindings.json 中的绑定；接入真实服务（S1-T8）之前为空。
    init(user: [KeyBinding] = []) {
        let all = CoreCommands.all + Self.appCommands
        descriptors = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        bindings = KeyBinding.effective(defaults: all, user: user)
        menu = MenuModel(roots: CoreCommands.defaultMenu.roots.map { root in
            // “关闭”放在“文件”菜单末尾。
            guard case let .submenu(titleKey, children) = root, titleKey == "文件" else { return root }
            return .submenu(titleKey: titleKey, children: children + [.separator, .command(.windowClose)])
        })
    }

    func descriptor(_ id: CommandID) -> CommandDescriptor? {
        descriptors[id]
    }

    func title(of id: CommandID) -> String {
        descriptors[id].map { String(localized: $0.title) } ?? id.rawValue
    }

    /// 菜单项上显示的快捷键：该命令的第一个单键绑定。
    func menuBinding(for id: CommandID) -> KeyBinding? {
        bindings.first { $0.command == id && $0.sequence.count == 1 }
    }

    /// 多键序列待定时可接的下一个键。与 BindingResolver 的选择一致：当前作用域有候选时只看当前作用域，否则回退 global（textInput 不回退）。
    func continuations(of typed: [KeyChord], scope: InputScope) -> [(chord: KeyChord, title: String)] {
        func candidates(in scope: InputScope) -> [KeyBinding] {
            bindings.filter { $0.scope == scope && $0.sequence.count > typed.count && $0.sequence.starts(with: typed) }
        }
        var matches = candidates(in: scope)
        if matches.isEmpty, scope != .textInput, scope != .global {
            matches = candidates(in: .global)
        }
        var seen: Set<KeyChord> = []
        return matches.compactMap { binding in
            let next = binding.sequence[typed.count]
            guard seen.insert(next).inserted else { return nil }
            return (next, title(of: binding.command))
        }
    }
}
