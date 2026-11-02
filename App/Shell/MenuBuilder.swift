import AppKit
import MVCommands

/// 把菜单模型渲染成菜单栏，再加上系统菜单项（关于、服务、隐藏、编辑、窗口列表、退出）。
///
/// 命令项的启用状态来自 CommandRegistry，单键绑定显示为快捷键。快捷键由谁触发按绑定的作用域区分：
/// - global 作用域的绑定是真正的菜单快捷键，没有窗口或焦点在文本框中时也可用；
/// - 其余作用域的绑定只在菜单打开时显示。菜单关着时这些项没有快捷键，AppKit 不会拿它们匹配按键，
///   按键经响应链走到 InputRouter，按第一响应者的作用域解析，所以文本框能收到方向键，也不会重复执行。
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
            builder.isEnabled(command)
        }
    }

    private let catalog: CommandCatalog
    private let isEnabled: (CommandID) -> Bool
    private let perform: (CommandID) -> Void

    init(catalog: CommandCatalog, isEnabled: @escaping (CommandID) -> Bool, perform: @escaping (CommandID) -> Void) {
        self.catalog = catalog
        self.isEnabled = isEnabled
        self.perform = perform
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

        app.mainMenu = main
        app.servicesMenu = services
        app.windowsMenu = windows
    }

    // MARK: 命令菜单

    private func commandMenu(titleKey: String, children: [MenuNode]) -> NSMenu {
        let menu = NSMenu(title: Bundle.main.localizedString(forKey: titleKey, value: nil, table: nil))
        menu.delegate = self
        for child in children {
            switch child {
            case let .command(id):
                menu.addItem(commandItem(id))
            case let .submenu(key, nested):
                let submenu = commandMenu(titleKey: key, children: nested)
                menu.addItem(holder(for: submenu))
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
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
            guard let display = (item.representedObject as? Trigger)?.display else { continue }
            item.keyEquivalent = shown ? display.key : ""
            item.keyEquivalentModifierMask = shown ? display.mask : []
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

    /// 文本框的撤销与剪贴板命令走响应链。
    private func editMenu() -> NSMenu {
        menu(String(localized: "编辑"), [
            item(String(localized: "撤销"), Selector(("undo:")), "z"),
            item(String(localized: "重做"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "剪切"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "拷贝"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a"),
        ])
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
