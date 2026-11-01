import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVServices
import MVTestSupport
import os

/// App 的生命周期：启动服务容器、生成菜单、管理阅读窗口，退出时有时限地关闭服务。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(category: "app")
    let catalog = CommandCatalog()
    private var menuBuilder: MenuBuilder?
    private(set) var services: CoreServices?
    private(set) var dispatcher: CommandDispatcher?
    /// 真实服务（S1-T8）接入之前一律是 Mock，窗口状态栏会标明。
    private let isMock = true
    /// NSWindow 不持有自己的控制器，由这里保留到窗口关闭。
    private(set) var controllers: [ReaderWindowController] = []
    /// 服务就绪之前收到的打开请求（例如拖到 Dock 图标启动）。
    private var pendingURLs: [URL] = []
    private var cascadePoint = NSPoint.zero

    static func main() {
        // 作为 MVIO 的辅助进程启动时，在这里进入请求循环，不启动界面。
        IOHelper.runIfRequested()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate 是弱引用。
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let builder = MenuBuilder(
            catalog: catalog,
            isEnabled: { [weak self] id in self?.isEnabled(id) ?? false },
            perform: { [weak self] id in self?.runFromMenu(id) }
        )
        var extra: [NSMenu] = []
        #if DEBUG
        extra.append(debugMenu())
        #endif
        builder.install(in: NSApp, extra: extra)
        menuBuilder = builder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: CanvasTestWindowController.launchKey) {
            CanvasTestWindowController.show(autorun: UserDefaults.standard.bool(forKey: CanvasTestWindowController.autorunKey))
            logger.info("启动完成，打开画布测试")
            return
        }
        #endif
        Task { await start() }
    }

    private func start() async {
        do {
            let services = try await makeServices()
            self.services = services
            let dispatcher = CommandDispatcher(registry: services.commands)
            self.dispatcher = dispatcher
            registerCommands(in: services.commands)
        } catch {
            logger.fault("服务启动失败：\(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "无法启动 MacView")
            alert.informativeText = ErrorText.describe(error)
            alert.addButton(withTitle: String(localized: "退出"))
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let urls = pendingURLs
        pendingURLs = []
        if urls.isEmpty {
            newWindow()
        } else {
            open(urls, in: nil)
        }
        logger.info("启动完成")
        #if DEBUG
        SelfTest.runIfRequested(app: self)
        #endif
    }

    /// 服务容器。S1-T8 之后，没有 `-MVMockServices YES` 时改用 `CoreServices.make`；它失败时显示错误并退出，不回落到 Mock。
    private func makeServices() async throws -> CoreServices {
        CoreServices.makeMock()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        // shutdown 自己有时限，不等被卡住的 I/O。
        Task {
            await services.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, services != nil { newWindow() }
        return true
    }

    /// Finder 的“打开方式”和拖到 Dock 图标。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard services != nil else {
            pendingURLs += urls
            return
        }
        open(urls, in: mainController)
    }

    // MARK: 窗口

    /// 当前的阅读窗口：菜单命令作用于它。
    var mainController: ReaderWindowController? {
        NSApp.mainWindow?.windowController as? ReaderWindowController
    }

    func controller(for session: SessionID?) -> ReaderWindowController? {
        controllers.first { $0.session.id == session }
    }

    @discardableResult
    func newWindow() -> ReaderWindowController? {
        guard let controller = makeController() else { return nil }
        let window = controller.window!
        // tabbingMode 为 .preferred 时，新窗口会自动并入当前窗口的标签组；这里要的是独立窗口。
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .preferred
        return controller
    }

    @discardableResult
    func newTab(beside current: ReaderWindowController?) -> ReaderWindowController? {
        guard let controller = makeController() else { return nil }
        let window = controller.window!
        if let currentWindow = current?.window ?? NSApp.mainWindow {
            currentWindow.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        return controller
    }

    /// 标签栏的“+”按钮发送这个动作。
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(beside: mainController)
    }

    /// 第一个 URL 在 `controller`（为 nil 时新开窗口）中打开，其余各开一个标签页。
    func open(_ urls: [URL], in controller: ReaderWindowController?) {
        guard let first = urls.first, let target = controller ?? newWindow() else { return }
        target.open([first])
        for url in urls.dropFirst() {
            newTab(beside: target)?.open([url])
        }
    }

    private func makeController() -> ReaderWindowController? {
        guard let services, let dispatcher else { return nil }
        let controller = ReaderWindowController(services: services, catalog: catalog, dispatcher: dispatcher, isMock: isMock)
        controller.onOpenExtra = { [weak self, weak controller] urls in
            guard let self, let controller else { return }
            for url in urls {
                newTab(beside: controller)?.open([url])
            }
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        let window = controller.window!
        if controllers.isEmpty {
            window.center()
            cascadePoint = .zero
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        controllers.append(controller)
        return controller
    }

    // MARK: 菜单

    private var menuScope: InputScope {
        InputRouter.scope(of: NSApp.mainWindow?.firstResponder)
    }

    private func isEnabled(_ id: CommandID) -> Bool {
        dispatcher?.isEnabled(id, in: mainController, scope: menuScope) ?? false
    }

    private func runFromMenu(_ id: CommandID) {
        dispatcher?.run(id, in: mainController, scope: menuScope)
    }

    #if DEBUG
    private func debugMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "调试"))
        menu.addItem(withTitle: String(localized: "画布测试"), action: #selector(showCanvasTest(_:)), keyEquivalent: "")
        return menu
    }
    #endif
}
