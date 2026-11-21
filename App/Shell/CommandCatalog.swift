import Foundation
import MVCommands
import MVReading
import MVSettings

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

    /// “文件”菜单结构：包含打开、剪贴板、用指定应用打开、移动到、复制到、重命名、删除、建立索引、回收目录、窗口、设置与关闭。
    static let fileMenu: [MenuNode] = [
        .command(.fileOpen), .separator,
        .command(.fileCopy), .command(.fileCopyPath), .command(.fileReveal), .dynamic(.openWith), .separator,
        .dynamic(.moveTo), .dynamic(.copyTo),
        .command(.fileRename), .command(.fileDelete), .separator,
        .command(.searchIndexFolder), .command(.recycleEmpty), .separator,
        .command(.windowNew), .command(.windowNewTab), .separator,
        .command(.retryFailed), .command(.settingsOpen), .separator,
        .command(.windowClose),
    ]

    /// “图像”菜单：评分 0–5 子菜单与标签编辑。
    static let imageMenu: [MenuNode] = [
        .submenu(titleKey: "评分", children: [
            .command(.ratingSet0), .command(.ratingSet1), .command(.ratingSet2),
            .command(.ratingSet3), .command(.ratingSet4), .command(.ratingSet5),
        ]),
        .command(.metadataTagsEdit),
    ]

    /// 停靠区与面板的显示命令：从 Core 默认菜单的“窗口”移到“显示”的末尾，加上三个停靠区。
    @MainActor
    static var dockMenu: [MenuNode] {
        [.command(.docksToggle), .command(.dockLeftToggle), .command(.dockRightToggle), .command(.dockBottomToggle), .separator]
            + DockPanels.all.map { .command($0.toggleCommand) }
    }

    let bindings: [KeyBinding]
    let inputBindings: InputBindings
    let menu: MenuModel
    let viewerContextMenu: [MenuNode]
    let toolbar: [ToolbarItemID]
    private let descriptors: [CommandID: CommandDescriptor]

    /// `file` 是完整的 keybindings.json 文档（含键盘与鼠标/触控板/点击区域/滚轮绑定）；`menuFile` 是 menus.json 文档。
    @MainActor
    init(file: KeyBindingsFile, menuFile: MenuFile = MenuFile()) {
        self.init(user: file.bindings, inputBindings: InputBindings.effective(user: file), menuFile: menuFile)
    }

    /// `user` 是 keybindings.json 中的键盘绑定，`menuFile` 是 menus.json 中的自定义菜单与工具栏配置。
    @MainActor
    init(
        user: [KeyBinding] = [],
        inputBindings: InputBindings = InputBindings.effective(user: KeyBindingsFile()),
        menuFile: MenuFile = MenuFile()
    ) {
        let all = CoreCommands.all + Self.appCommands
        descriptors = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        bindings = KeyBinding.effective(defaults: all, user: user)
        self.inputBindings = inputBindings
        menu = menuFile.mainMenu.map(MenuModel.init(roots:)) ?? Self.defaultMainMenu()
        viewerContextMenu = menuFile.resolvedViewerContextMenu
        toolbar = menuFile.resolvedToolbar
    }

    @MainActor
    static func defaultMainMenu() -> MenuModel {
        let dockCommands = Set(Self.dockMenu.compactMap { node -> CommandID? in
            if case let .command(id) = node { id } else { nil }
        })
        return MenuModel(roots: CoreCommands.defaultMenu.roots.flatMap { root -> [MenuNode] in
            guard case let .submenu(titleKey, children) = root else { return [root] }
            switch titleKey {
            // 撤销与重做在“编辑”菜单；“文件”按文件操作规范排布。
            case "文件": return [.submenu(titleKey: titleKey, children: Self.fileMenu)]
            case "显示":
                let viewChildren = children.map { node -> MenuNode in
                    if case .command(.displayProfileApply) = node {
                        return .dynamic(.displayProfiles)
                    }
                    return node
                }
                return [.submenu(titleKey: titleKey, children: viewChildren + [.separator] + Self.dockMenu), .submenu(titleKey: "图像", children: Self.imageMenu)]
            case "书": return [.submenu(titleKey: titleKey, children: Self.removing([.searchFocus, .searchIndexFolder], from: children))]
            case "窗口": return [.submenu(titleKey: titleKey, children: Self.removing(dockCommands, from: children))]
            default: return [root]
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
        if id == .fileRename { return String(localized: "重命名…") }
        if id == .searchIndexFolder { return String(localized: "为此文件夹建立索引") }
        return descriptors[id].map { String(localized: $0.title) } ?? id.rawValue
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

extension AppDelegate {
    /// 注册按当前阅读方向换算上一帧/下一帧的左右翻帧命令（`frame.left` / `frame.right`）。
    func registerFrameDirectionCommands(in registry: CommandRegistry) {
        for id in [CommandID.frameLeft, .frameRight] {
            guard let descriptor = catalog.descriptor(id) else {
                preconditionFailure("命令清单中没有 \(id.rawValue)")
            }
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let session = self?.controller(for: context.session)?.session, !session.frames.isEmpty else { return false }
                let move = Self.frameMove(for: id, direction: session.settings.direction)
                return move == .nextFrame ? session.currentFrame < session.frames.count - 1 : session.currentFrame > 0
            }) { [weak self] context, _ in
                guard let session = self?.controller(for: context.session)?.session else { return }
                session.go(Self.frameMove(for: id, direction: session.settings.direction))
            }
        }
    }

    private static func frameMove(for id: CommandID, direction: ReadingDirection) -> PageMove {
        switch (id, direction) {
        case (.frameLeft, .leftToRight), (.frameRight, .rightToLeft):
            .previousFrame
        case (.frameLeft, .rightToLeft), (.frameRight, .leftToRight):
            .nextFrame
        default:
            .nextFrame
        }
    }
}
