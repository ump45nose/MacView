import AppKit

/// 默认菜单栏。S1-F1 会改为由命令清单生成。
@MainActor
enum MainMenu {
    static func install(in app: NSApplication) {
        let appName = ProcessInfo.processInfo.processName
        let services = NSMenu(title: String(localized: "服务"))
        let windows = menu(String(localized: "窗口"), [
            item(String(localized: "最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "缩放"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(String(localized: "前置全部窗口"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services

        let main = NSMenu()
        for submenu in [
            menu(appName, [
                item(String(localized: "关于 \(appName)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                servicesItem,
                .separator(),
                item(String(localized: "隐藏 \(appName)"), #selector(NSApplication.hide(_:)), "h"),
                item(String(localized: "隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item(String(localized: "全部显示"), #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item(String(localized: "退出 \(appName)"), #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu(String(localized: "文件"), [
                item(String(localized: "新建窗口"), #selector(AppDelegate.newWindow(_:)), "n"),
                item(String(localized: "新建标签页"), #selector(AppDelegate.newWindowForTab(_:)), "t"),
                .separator(),
                item(String(localized: "关闭"), #selector(NSWindow.performClose(_:)), "w"),
            ]),
            menu(String(localized: "显示"), [
                item(String(localized: "显示标签页栏"), #selector(NSWindow.toggleTabBar(_:))),
                item(String(localized: "显示所有标签页"), #selector(NSWindow.toggleTabOverview(_:)), "\\", [.command, .shift]),
                .separator(),
                // 系统会把这一项的快捷键改为 🌐F，另加一个隐藏项保留 ⌃⌘F。
                item(String(localized: "进入全屏幕"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            ]),
            windows,
        ] {
            let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }

        app.mainMenu = main
        app.servicesMenu = services
        // 系统会往窗口菜单里加入窗口列表；标签页命令和窗口布局命令在菜单打开时加入。
        app.windowsMenu = windows
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.items = items
        return menu
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
