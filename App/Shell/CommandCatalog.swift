import Foundation
import MVCommands

extension CommandID {
    /// App 侧的界面命令：关闭当前窗口或标签页。
    static let windowClose = CommandID("window.close")
    /// 显示或隐藏一个停靠区。
    static let dockLeftToggle = CommandID("dock.left.toggle")
    static let dockRightToggle = CommandID("dock.right.toggle")
    static let dockBottomToggle = CommandID("dock.bottom.toggle")
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
        CommandDescriptor(id: .dockLeftToggle, title: LocalizedStringResource("显示或隐藏左侧停靠区"), category: "window"),
        CommandDescriptor(id: .dockRightToggle, title: LocalizedStringResource("显示或隐藏右侧停靠区"), category: "window"),
        CommandDescriptor(id: .dockBottomToggle, title: LocalizedStringResource("显示或隐藏底部停靠区"), category: "window"),
    ]

    /// 停靠区与面板的显示命令：从 Core 默认菜单的“窗口”移到“显示”的末尾，加上三个停靠区。
    @MainActor
    static var dockMenu: [MenuNode] {
        [.command(.docksToggle), .command(.dockLeftToggle), .command(.dockRightToggle), .command(.dockBottomToggle), .separator]
            + DockPanels.all.map { .command($0.toggleCommand) }
    }

    let bindings: [KeyBinding]
    let menu: MenuModel
    private let descriptors: [CommandID: CommandDescriptor]

    /// `user` 是 keybindings.json 中的绑定。
    @MainActor
    init(user: [KeyBinding] = []) {
        let all = CoreCommands.all + Self.appCommands
        descriptors = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        bindings = KeyBinding.effective(defaults: all, user: user)
        let dockCommands = Set(Self.dockMenu.compactMap { node -> CommandID? in
            if case let .command(id) = node { id } else { nil }
        })
        menu = MenuModel(roots: CoreCommands.defaultMenu.roots.map { root in
            guard case let .submenu(titleKey, children) = root else { return root }
            switch titleKey {
            // “关闭”放在“文件”菜单末尾。
            case "文件": return .submenu(titleKey: titleKey, children: children + [.separator, .command(.windowClose)])
            case "显示": return .submenu(titleKey: titleKey, children: children + [.separator] + Self.dockMenu)
            case "窗口": return .submenu(titleKey: titleKey, children: Self.removing(dockCommands, from: children))
            default: return root
            }
        })
    }

    /// 去掉命令后，合并相邻与首尾的分隔线。
    private static func removing(_ commands: Set<CommandID>, from nodes: [MenuNode]) -> [MenuNode] {
        var result: [MenuNode] = []
        for node in nodes {
            if case let .command(id) = node, commands.contains(id) { continue }
            if node == .separator, result.last == .separator || result.isEmpty { continue }
            result.append(node)
        }
        if result.last == .separator { result.removeLast() }
        return result
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
