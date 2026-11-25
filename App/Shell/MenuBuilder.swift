import AppKit

/// AppKit 文本响应链的撤销动作。
@objc private protocol TextUndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}
import MVCommands
import MVLayout

/// 把菜单模型渲染成菜单栏，再加上系统菜单项（关于、服务、隐藏、编辑、窗口列表、退出）。
///
/// 命令项的启用状态来自 CommandRegistry，单键绑定显示为快捷键。快捷键由谁触发按绑定的作用域区分：
/// - global 作用域的绑定是真正的菜单快捷键，没有窗口或焦点在文本框中时也可用；
/// - 其余作用域的绑定只在菜单打开时显示。菜单关着时这些项没有快捷键，AppKit 不会拿它们匹配按键，
///   按键经响应链走到 InputRouter，按第一响应者的作用域解析，所以文本框能收到方向键，也不会重复执行。
/// 只在菜单打开时显示的快捷键信息（用于非 global 作用域的动态子菜单项）。
@MainActor
final class MenuDisplayShortcut: NSObject {
    let key: String
    let mask: NSEvent.ModifierFlags
    let payload: Any?

    init(key: String, mask: NSEvent.ModifierFlags, payload: Any? = nil) {
        self.key = key
        self.mask = mask
        self.payload = payload
    }
}

@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    /// 一个命令菜单项的动作目标；由菜单项的 representedObject 持有。
    @MainActor
    private final class Trigger: NSObject, NSMenuItemValidation {
        let command: CommandID
        /// 只在菜单打开时显示的快捷键。
        let display: (key: String, mask: NSEvent.ModifierFlags)?
        // 配置热重载会替换菜单；AppKit 仍在跟踪的旧菜单项要保留自己的 builder。
        let builder: MenuBuilder

        init(command: CommandID, display: (key: String, mask: NSEvent.ModifierFlags)?, builder: MenuBuilder) {
            self.command = command
            self.display = display
            self.builder = builder
        }

        @objc func trigger(_ sender: Any?) {
            builder.perform(command)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if let app = NSApp.delegate as? AppDelegate {
                if let title = app.menuTitle(for: command) {
                    menuItem.title = title
                }
                if let state = app.menuState(for: command) {
                    menuItem.state = state
                }
            }
            return builder.isEnabled(command)
        }
    }

    @MainActor
    private final class DynamicSubmenu: NSObject, NSMenuItemValidation {
        let submenu: NSMenu
        let populate: (NSMenu) -> Bool

        init(submenu: NSMenu, populate: @escaping (NSMenu) -> Bool) {
            self.submenu = submenu
            self.populate = populate
        }

        @objc func noop(_ sender: Any?) {}

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            let enabled = populate(submenu)
            Theme.applyMenuFont(to: submenu)
            return enabled
        }
    }

    private let catalog: CommandCatalog
    private let isEnabled: (CommandID) -> Bool
    private let perform: (CommandID) -> Void
    private var pluginPanelHost: (menu: NSMenu, anchor: NSMenuItem?, inserted: [NSMenuItem])?
    private var panelsObserver: NSObjectProtocol?

    init(
        catalog: CommandCatalog,
        isEnabled: @escaping (CommandID) -> Bool,
        perform: @escaping (CommandID) -> Void
    ) {
        self.catalog = catalog
        self.isEnabled = isEnabled
        self.perform = perform
        super.init()
        panelsObserver = NotificationCenter.default.addObserver(
            forName: DockPanels.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPluginPanelsInMenu()
            }
        }
    }

    isolated deinit {
        if let panelsObserver {
            NotificationCenter.default.removeObserver(panelsObserver)
        }
    }

    /// 按菜单树和上下文条目提供者生成查看器右键菜单；自动合并相邻和首尾分隔线。
    func contextMenu(nodes: [MenuNode], provider: ContextMenuProvider, target: ContextMenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        appendContextItems(from: nodes, to: menu, provider: provider, target: target)
        Theme.applyMenuFont(to: menu)
        return menu
    }

    private func appendContextItems(from nodes: [MenuNode], to menu: NSMenu, provider: ContextMenuProvider, target: ContextMenuTarget) {
        var needsSeparator = false
        for node in nodes {
            switch node {
            case .separator:
                if !menu.items.isEmpty { needsSeparator = true }
            case let .command(id):
                guard let item = provider.menuItem(for: id, target: target) else { continue }
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(item)
            case let .dynamic(id):
                guard let item = provider.menuItem(for: id, target: target) else { continue }
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(item)
            case let .submenu(titleKey, children) where children == [.dynamic(.scripts)]:
                guard let item = provider.menuItem(for: .scripts, target: target) else { continue }
                let localizedTitle = Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil)
                item.title = localizedTitle
                item.submenu?.title = localizedTitle
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(item)
            case let .submenu(titleKey, children):
                let submenu = NSMenu(title: Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil))
                submenu.autoenablesItems = false
                appendContextItems(from: children, to: submenu, provider: provider, target: target)
                guard !submenu.items.isEmpty else { continue }
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(holder(for: submenu))
            }
        }
    }

    /// `extra` 中的菜单插在“窗口”之前，例如 Debug 构建的“调试”菜单。
    func install(in app: NSApplication, extra: [NSMenu] = []) {
        let appName = ProcessInfo.processInfo.processName
        let services = NSMenu(title: String(localized: "服务"))
        let main = NSMenu()
        main.addItem(holder(for: appMenu(appName: appName, services: services)))

        var windows: NSMenu?
        for root in catalog.menu.roots {
            guard case let .submenu(titleKey, children) = root else { continue }
            let menu = commandMenu(titleKey: titleKey, children: children)
            switch titleKey {
            case "文件":
                main.addItem(holder(for: menu))
                main.addItem(holder(for: editMenu()))
            case "显示":
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "显示标签页栏"), #selector(NSWindow.toggleTabBar(_:))))
                menu.addItem(item(String(localized: "显示所有标签页"), #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]))
                main.addItem(holder(for: menu))
            case "窗口":
                // 系统项在前，与 macOS 惯例一致；系统会在末尾加入标签页命令和窗口列表。
                let system = [
                    item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
                    item(String(localized: "缩放"), #selector(NSWindow.performZoom(_:))),
                    NSMenuItem.separator(),
                ]
                for (index, systemItem) in system.enumerated() {
                    menu.insertItem(systemItem, at: index)
                }
                menu.addItem(.separator())
                menu.addItem(item(String(localized: "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:))))
                extra.forEach { main.addItem(holder(for: $0)) }
                main.addItem(holder(for: menu))
                windows = menu
            default:
                main.addItem(holder(for: menu))
            }
        }

        Theme.applyMenuFont(to: main, includeRoot: false)
        app.mainMenu = main
        app.servicesMenu = services
        app.windowsMenu = windows
    }

    // MARK: 命令菜单

    private func commandMenu(titleKey: String, children: [MenuNode]) -> NSMenu {
        let menu = NSMenu(title: Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil))
        menu.delegate = self
        var needsSeparator = false
        for child in children {
            switch child {
            case let .command(id):
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(commandItem(id))
            case let .submenu(key, nested) where nested.isEmpty:
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                menu.addItem(dynamicSubmenuItem(title: Bundle.main.localizedString(forKey: key, value: nil, table: nil)) { submenu in
                    (NSApp.delegate as? AppDelegate)?.updateSubmenu(key: key, menu: submenu) ?? false
                })
            case let .submenu(key, nested):
                if needsSeparator {
                    menu.addItem(.separator())
                    needsSeparator = false
                }
                let submenu = commandMenu(titleKey: key, children: nested)
                menu.addItem(holder(for: submenu))
            case .separator:
                if !menu.items.isEmpty { needsSeparator = true }
            case let .dynamic(id):
                let dynamicItems = mainMenuDynamicItems(for: id)
                if id == .pluginPanels {
                    let anchor = menu.items.last
                    var inserted: [NSMenuItem] = []
                    if !dynamicItems.isEmpty {
                        if needsSeparator {
                            let sep = NSMenuItem.separator()
                            menu.addItem(sep)
                            inserted.append(sep)
                            needsSeparator = false
                        }
                        for item in dynamicItems {
                            menu.addItem(item)
                            inserted.append(item)
                        }
                    }
                    pluginPanelHost = (menu, anchor, inserted)
                } else if !dynamicItems.isEmpty {
                    if needsSeparator {
                        menu.addItem(.separator())
                        needsSeparator = false
                    }
                    dynamicItems.forEach { menu.addItem($0) }
                }
            }
        }
        return menu
    }

    private func mainMenuDynamicItems(for id: DynamicMenuID) -> [NSMenuItem] {
        switch id {
        case .scripts:
            return mainMenuScriptItems()
        case .pluginPanels:
            return mainMenuPluginPanelItems()
        default:
            return mainMenuDynamicItem(for: id).map { [$0] } ?? []
        }
    }

    private func mainMenuPluginPanelItems() -> [NSMenuItem] {
        let app = NSApp.delegate as? AppDelegate
        let groups = app?.plugins?.mainMenuPluginPanelGroups() ?? []
        var covered: Set<PanelID> = []
        var items: [NSMenuItem] = []

        for group in groups {
            if group.panels.count == 1, let only = group.panels.first {
                covered.insert(only.id)
                items.append(commandItem(only.commandID))
            } else if group.panels.count > 1 {
                let submenu = NSMenu(title: group.title)
                submenu.delegate = self
                for panel in group.panels {
                    covered.insert(panel.id)
                    submenu.addItem(commandItem(panel.commandID))
                }
                items.append(holder(for: submenu))
            }
        }

        // 支持未经过 PluginCoordinator 直接登记进 DockPanels.plugins 的面板类型（例如自检替身）。
        for type in DockPanels.plugins where !covered.contains(type.id) {
            if catalog.descriptor(type.toggleCommand) != nil {
                items.append(commandItem(type.toggleCommand))
            } else {
                let title = String(localized: "显示或隐藏 \(type.title)")
                let item = MenuAction(title) { [weak app] in
                    guard let app else { return }
                    app.dock?.togglePanel(type, in: app.mainController?.dock)
                }.item
                items.append(item)
            }
        }
        return items
    }

    private func refreshPluginPanelsInMenu() {
        guard var host = pluginPanelHost else { return }
        for item in host.inserted where item.menu === host.menu {
            host.menu.removeItem(item)
        }
        host.inserted = []

        let dynamicItems = mainMenuPluginPanelItems()
        if !dynamicItems.isEmpty {
            let insertionIndex: Int
            if let anchor = host.anchor, let anchorIndex = host.menu.items.firstIndex(where: { $0 === anchor }) {
                insertionIndex = anchorIndex + 1
            } else {
                insertionIndex = 0
            }
            var toInsert: [NSMenuItem] = []
            if insertionIndex > 0, !host.menu.items[insertionIndex - 1].isSeparatorItem {
                toInsert.append(.separator())
            }
            toInsert.append(contentsOf: dynamicItems)
            if insertionIndex < host.menu.items.count, !host.menu.items[insertionIndex].isSeparatorItem {
                toInsert.append(.separator())
            }
            for (offset, item) in toInsert.enumerated() {
                host.menu.insertItem(item, at: insertionIndex + offset)
            }
            host.inserted = toInsert
            Theme.applyMenuFont(to: host.menu)
        }
        pluginPanelHost = host
    }

    private func mainMenuScriptItems() -> [NSMenuItem] {
        guard let app = NSApp.delegate as? AppDelegate else { return [] }
        let scripts = app.extensions?.scriptItems ?? []
        let externals = app.extensions?.externalItems ?? []
        let pluginGroups = app.plugins?.mainMenuPluginGroups() ?? []
        var items: [NSMenuItem] = []
        for info in scripts {
            items.append(commandItem(ExtensionCommands.scriptCommandID(for: info.id)))
        }
        if !scripts.isEmpty && !externals.isEmpty {
            items.append(.separator())
        }
        for command in externals {
            items.append(commandItem(ExtensionCommands.externalCommandID(for: command.id)))
        }
        if !pluginGroups.isEmpty {
            if !items.isEmpty {
                items.append(.separator())
            }
            for group in pluginGroups {
                let submenu = NSMenu(title: group.title)
                submenu.delegate = self
                for commandID in group.commandIDs {
                    submenu.addItem(commandItem(commandID))
                }
                items.append(holder(for: submenu))
            }
        }
        return items
    }

    private func mainMenuDynamicItem(for id: DynamicMenuID) -> NSMenuItem? {
        switch id {
        case .openWith:
            dynamicSubmenuItem(title: String(localized: "用指定应用打开")) { submenu in
                (NSApp.delegate as? AppDelegate)?.updateSubmenu(key: "用指定应用打开", menu: submenu) ?? false
            }
        case .moveTo:
            dynamicSubmenuItem(title: String(localized: "移动到")) { submenu in
                (NSApp.delegate as? AppDelegate)?.updateSubmenu(key: "移动到", menu: submenu) ?? false
            }
        case .copyTo:
            dynamicSubmenuItem(title: String(localized: "复制到")) { submenu in
                (NSApp.delegate as? AppDelegate)?.updateSubmenu(key: "复制到", menu: submenu) ?? false
            }
        case .displayProfiles:
            dynamicSubmenuItem(title: String(localized: "套用显示配置")) { submenu in
                (NSApp.delegate as? AppDelegate)?.updateSubmenu(key: "套用显示配置", menu: submenu) ?? false
            }
        case .rating:
            holder(for: commandMenu(titleKey: "评分", children: [
                .command(.ratingSet0), .command(.ratingSet1), .command(.ratingSet2),
                .command(.ratingSet3), .command(.ratingSet4), .command(.ratingSet5),
            ]))
        case .scripts, .pluginPanels:
            nil
        case .sources:
            dynamicSubmenuItem(title: String(localized: "打开来源")) { submenu in
                guard let plugins = (NSApp.delegate as? AppDelegate)?.plugins else { return false }
                plugins.populateSourcesMenu(submenu)
                return true
            }
        case .layoutSchemes:
            dynamicSubmenuItem(title: String(localized: "布局方案")) { submenu in
                (NSApp.delegate as? AppDelegate)?.populateLayoutSchemesMenu(submenu) ?? false
            }
        }
    }

    private func dynamicSubmenuItem(title: String, populate: @escaping (NSMenu) -> Bool) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.delegate = self
        let dynamic = DynamicSubmenu(submenu: submenu, populate: populate)
        let item = NSMenuItem(title: title, action: #selector(DynamicSubmenu.noop(_:)), keyEquivalent: "")
        item.target = dynamic
        item.representedObject = dynamic
        item.submenu = submenu
        return item
    }

    private func commandItem(_ id: CommandID) -> NSMenuItem {
        let binding = catalog.menuBinding(for: id)
        let equivalent = binding.flatMap { KeyMapping.menuKeyEquivalent(for: $0.sequence[0]) }
        let live = binding?.scope == .global
        let trigger = Trigger(command: id, display: live ? nil : equivalent, builder: self)
        let item = NSMenuItem(title: catalog.title(of: id), action: #selector(Trigger.trigger(_:)), keyEquivalent: "")
        item.target = trigger
        item.representedObject = trigger
        if live, let equivalent {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.mask
        }
        return item
    }

    /// 只在真正打开时填上；menuNeedsUpdate 在菜单栏例行更新和匹配快捷键时也会被调用，不能用。
    func menuWillOpen(_ menu: NSMenu) {
        setDisplayedKeys(in: menu, shown: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        // 回调中不改菜单项，关闭后再清除。
        Task { @MainActor in self.setDisplayedKeys(in: menu, shown: false) }
    }

    private func setDisplayedKeys(in menu: NSMenu, shown: Bool) {
        for item in menu.items {
            if let display = (item.representedObject as? Trigger)?.display {
                item.keyEquivalent = shown ? display.key : ""
                item.keyEquivalentModifierMask = shown ? display.mask : []
            } else if let display = item.representedObject as? MenuDisplayShortcut {
                item.keyEquivalent = shown ? display.key : ""
                item.keyEquivalentModifierMask = shown ? display.mask : []
            }
        }
    }

    // MARK: 系统菜单

    private func appMenu(appName: String, services: NSMenu) -> NSMenu {
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        return menu(appName, [
            item(String(localized: "关于 \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            servicesItem,
            .separator(),
            item(String(localized: "隐藏 \(appName)"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "全部显示"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "退出 \(appName)"), #selector(NSApplication.terminate(_:)), "q"),
        ])
    }

    /// 文本框的撤销与剪贴板命令走响应链；“查找”聚焦书架搜索框。
    private func editMenu() -> NSMenu {
        let findItem = commandItem(.searchFocus)
        findItem.title = String(localized: "查找")
        let edit = menu(String(localized: "编辑"), [
            item(String(localized: "撤销"), #selector(TextUndoActions.undo(_:)), "z"),
            item(String(localized: "重做"), #selector(TextUndoActions.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "剪切"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "拷贝"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            findItem,
        ])
        edit.delegate = self
        return edit
    }

    private func holder(for submenu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        return holder
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.items = items
        return menu
    }

    private func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
