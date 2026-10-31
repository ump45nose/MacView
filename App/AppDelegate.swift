import AppKit
import MVFoundation
import os

/// 最小骨架：启动后打开一个空窗口，支持新建窗口和原生标签页。S1-F1 会重写。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let logger = Logger(category: "app")
    /// NSWindow 不持有自己的控制器，由这里保留到窗口关闭。
    private var windowControllers: [NSWindowController] = []
    private var cascadePoint = NSPoint.zero

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate 是弱引用。
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install(in: NSApp)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        newWindow(nil)
        logger.info("启动完成")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        let window = makeWindow()
        // tabbingMode 为 .preferred 时，新窗口会自动并入当前窗口的标签组；这里要的是独立窗口。
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .preferred
    }

    /// 菜单的“新建标签页”和标签栏的“+”按钮都发送这个动作。
    @objc func newWindowForTab(_ sender: Any?) {
        let window = makeWindow()
        if let current = NSApp.keyWindow {
            current.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacView"
        window.minSize = NSSize(width: 480, height: 320)
        // 窗口由控制器持有，关闭时不能再让 AppKit 释放一次。
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "MacView.reader"
        window.tabbingMode = .preferred
        window.delegate = self
        if windowControllers.isEmpty {
            window.center()
            cascadePoint = .zero
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        windowControllers.append(NSWindowController(window: window))
        return window
    }
}
