import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVServices
import MVSettings
import MVTestSupport
import os

/// App 的生命周期：启动服务容器、生成菜单、管理阅读窗口，退出时有时限地关闭服务。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(category: "app")
    private(set) var catalog = CommandCatalog()
    private var menuBuilder: MenuBuilder?
    private(set) var services: CoreServices?
    private(set) var dispatcher: CommandDispatcher?
    private(set) var dock: DockCoordinator?
    var isMock: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "MVMockServices")
        #else
        false
        #endif
    }
    private var keyBindingsTask: Task<Void, Never>?
    private var keyBindingsError: String?
    private(set) var supportDirectory = URL.applicationSupportDirectory.appending(path: "MacView")
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
        installMenu()
    }

    private func installMenu() {
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
            reloadBindings()
            observeBindings()
            let dispatcher = CommandDispatcher(registry: services.commands)
            self.dispatcher = dispatcher
            dock = DockCoordinator(fileURL: DockCoordinator.defaultFileURL())
            registerCommands(in: services.commands)
        } catch {
            logger.fault("服务启动失败：\(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "无法启动 MacView")
            alert.informativeText = ErrorText.describe(error)
            alert.addButton(withTitle: String(localized: "退出"))
            #if DEBUG
            SelfTest.checkStartupFailureIfRequested(app: self, alert: alert)
            #endif
            alert.runModal()
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
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
        DockSelfTest.runIfRequested(app: self)
        #endif
    }

    /// Debug 自检可覆盖目录，避免触碰用户的配置与缓存。
    private func makeServices() async throws -> CoreServices {
        if isMock { return CoreServices.makeMock() }
        var cacheDirectory = URL.cachesDirectory.appending(path: "MacView")
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "MVSupportDirectory") { supportDirectory = URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: "MVCacheDirectory") { cacheDirectory = URL(fileURLWithPath: path) }
        #endif
        let pixels = NSScreen.screens.map { $0.frame.size.applying(.init(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
        let bounds = PixelSize(width: Int(pixels.map(\.width).max() ?? 3840), height: Int(pixels.map(\.height).max() ?? 2160))
        return try await CoreServices.make(configuration: CoreConfiguration(
            supportDirectory: supportDirectory, cacheDirectory: cacheDirectory,
            browseBounds: bounds, helperExecutable: Bundle.main.executableURL
        ))
    }

    private func reloadBindings() {
        catalog = CommandCatalog(user: services?.keyBindings?.value().bindings ?? [])
        menuBuilder?.update(catalog: catalog, in: NSApp)
        controllers.forEach { $0.updateBindings(catalog) }
    }

    private func observeBindings() {
        guard let store = services?.keyBindings else { return }
        let changes = store.changes()
        keyBindingsTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .reloaded:
                    keyBindingsError = nil
                    reloadBindings()
                case let .fileError(message):
                    keyBindingsError = message
                }
                controllers.forEach { showBindingsError(in: $0) }
            }
        }
    }

    private func showBindingsError(in controller: ReaderWindowController) {
        controller.content.showFileError(keyBindingsError, fileURL: supportDirectory.appending(path: "keybindings.json"))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        keyBindingsTask?.cancel()
        // shutdown 自己有时限，不等被卡住的 I/O。
        Task {
            await dock?.flush()
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
        guard let services, let dispatcher, let dock else { return nil }
        let controller = ReaderWindowController(services: services, catalog: catalog, dispatcher: dispatcher, dock: dock, isMock: isMock)
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
        showBindingsError(in: controller)
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
