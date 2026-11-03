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
    private(set) var supportDirectory = URL.applicationSupportDirectory.appending(path: "MacView")
    private(set) var cacheDirectory = URL.cachesDirectory.appending(path: "MacView")
    private var settingsWindow: SettingsWindowController?
    private var sessionStore: SessionStore?
    #if DEBUG
    private var debugSocket: DebugSocket?
    #endif
    private var sessionSaveEnabled = false
    private var tabObservations: [NSKeyValueObservation] = []
    private var settingsErrorsTask: Task<Void, Never>?
    /// 配置错误：文件名到文字，按文件各显示一条。
    private(set) var fileProblems: [FileProblem] = []
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
            observeSettingsErrors()
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
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "MVSelfTestOpenAtLaunch") { pendingURLs.append(URL(fileURLWithPath: path)) }
        #endif
        let urls = pendingURLs
        pendingURLs = []
        startSessionStore()
        let restored = restoreSession()
        if let restored {
            for url in urls { newTab(beside: restored)?.open([url]) }
        } else if urls.isEmpty {
            newWindow()
        } else {
            open(urls, in: nil)
        }
        sessionSaveEnabled = true
        scheduleSessionSave()
        logger.info("启动完成")
        #if DEBUG
        SelfTest.runIfRequested(app: self)
        DockSelfTest.runIfRequested(app: self)
        ViewerSelfTest.runIfRequested(app: self)
        PanelSelfTest.runIfRequested(app: self)
        SettingsSelfTest.runIfRequested(app: self)
        SessionSelfTest.runIfRequested(app: self)
        debugSocket = DebugSocket.startIfRequested(app: self)
        #endif
    }

    /// 全应用一个设置窗口。
    func openSettings() -> SettingsWindowController? {
        guard let services else { return nil }
        let controller = settingsWindow ?? SettingsWindowController(
            store: services.settings, sources: services.sources,
            supportDirectory: supportDirectory, cacheDirectory: cacheDirectory
        )
        settingsWindow = controller
        controller.show()
        return controller
    }

    /// Debug 自检可覆盖目录，避免触碰用户的配置与缓存。
    private func makeServices() async throws -> CoreServices {
        if isMock { return CoreServices.makeMock() }
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
        installMenu()
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
                    setFileProblem("keybindings.json", nil)
                    reloadBindings()
                case let .fileError(message):
                    setFileProblem("keybindings.json", message)
                }
            }
        }
    }

    private func observeSettingsErrors() {
        guard let services else { return }
        let changes = services.settings.changes()
        settingsErrorsTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .global: setFileProblem("settings.json", nil)
                case .pathRules: setFileProblem("path-rules.json", nil)
                case let .fileError(file, message): setFileProblem(file, message)
                }
            }
        }
    }

    /// 配置错误按文件各一条；修好后 `message` 为 nil，这一条消失。
    private func setFileProblem(_ file: String, _ message: String?) {
        fileProblems.removeAll { $0.file == file }
        if let message {
            let title = file == SessionStore.fileName
                ? String(localized: "\(file) 无法解析，这次没有恢复窗口")
                : String(localized: "\(file) 有错误，继续使用可用的配置")
            fileProblems.append(FileProblem(file: file, title: title, message: message, url: supportDirectory.appending(path: file)))
            fileProblems.sort { $0.file < $1.file }
        }
        controllers.forEach(showFileProblems)
    }

    private func showFileProblems(in controller: ReaderWindowController) {
        controller.content.setFileErrors(fileProblems) { [weak self] file in
            self?.setFileProblem(file, nil)
            if file == SessionStore.fileName { self?.sessionStore?.resumeSaving() }
        }
    }

    // MARK: 会话

    /// Mock 和自检不读不写用户的会话；会话自检自己指定目录。
    private func startSessionStore() {
        #if DEBUG
        guard !SelfTest.isRunningExceptSession else { return }
        #endif
        guard !isMock else { return }
        let store = SessionStore(fileURL: supportDirectory.appending(path: SessionStore.fileName))
        store.onProblem = { [weak self] message in self?.setFileProblem(SessionStore.fileName, message) }
        sessionStore = store
    }

    /// 恢复上次的窗口；没有可恢复的窗口时返回 nil。最后恢复的窗口在最前面。
    private func restoreSession() -> ReaderWindowController? {
        guard let windows = sessionStore?.saved.windows, !windows.isEmpty else { return nil }
        var front: ReaderWindowController?
        for saved in windows.reversed() where !saved.tabs.isEmpty {
            var first: ReaderWindowController?
            var selected: ReaderWindowController?
            for (index, tab) in saved.tabs.enumerated() {
                guard let controller = index == 0 ? newWindow() : newTab(beside: first) else { continue }
                if index == 0 {
                    first = controller
                    if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved.frame.rect) }) {
                        controller.window?.setFrame(saved.frame.rect, display: false)
                    }
                }
                restore(tab, in: controller)
                if index == saved.selected { selected = controller }
            }
            let shown = selected ?? first
            shown?.window?.tabGroup?.selectedWindow = shown?.window
            shown?.window?.makeKeyAndOrderFront(nil)
            front = shown ?? front
        }
        return front
    }

    private func restore(_ tab: SessionSnapshot.Tab, in controller: ReaderWindowController) {
        if let layout = tab.dock { dock?.restore(controller.dock, layout: layout) }
        if let extent = tab.waterfallExtent { controller.viewer.continuous.waterfallExtent = extent }
        if let book = tab.book { controller.openBook(book) }
    }

    func scheduleSessionSave() {
        guard sessionSaveEnabled, sessionStore != nil else { return }
        observeTabGroups()
        sessionStore?.schedule { [weak self] in self?.sessionSnapshot() }
    }

    /// 拖动标签改变顺序没有窗口通知，只能观察标签组。
    private func observeTabGroups() {
        var seen = Set<ObjectIdentifier>()
        tabObservations = controllers.compactMap { $0.window?.tabGroup }.filter { seen.insert(ObjectIdentifier($0)).inserted }.flatMap { group in
            [
                group.observe(\.windows) { [weak self] _, _ in MainActor.assumeIsolated { self?.saveAfterTabChange() } },
                group.observe(\.selectedWindow) { [weak self] _, _ in MainActor.assumeIsolated { self?.saveAfterTabChange() } },
            ]
        }
    }

    private func saveAfterTabChange() {
        guard sessionSaveEnabled else { return }
        sessionStore?.schedule { [weak self] in self?.sessionSnapshot() }
    }

    private func sessionSnapshot() -> SessionSnapshot {
        // orderedWindows 从前到后；没选中的标签不在里面，按标签组找回来。
        var seen = Set<ObjectIdentifier>()
        var groups: [[NSWindow]] = []
        var selected: [NSWindow?] = []
        let ordered = NSApp.orderedWindows.filter { $0.windowController is ReaderWindowController }
        let rest = controllers.compactMap(\.window).filter { window in !ordered.contains { $0 === window } }
        for window in ordered + rest {
            if let group = window.tabGroup {
                guard seen.insert(ObjectIdentifier(group)).inserted else { continue }
                groups.append(group.windows)
                selected.append(group.selectedWindow)
            } else {
                groups.append([window])
                selected.append(window)
            }
        }
        let windows: [SessionSnapshot.Window] = zip(groups, selected).compactMap { group, current in
            let tabs = group.compactMap { $0.windowController as? ReaderWindowController }
            guard let first = tabs.first else { return nil }
            let frame = tabs.first { $0.window === current }?.normalFrame ?? first.normalFrame
            return SessionSnapshot.Window(
                frame: SessionSnapshot.Frame(frame),
                selected: group.firstIndex { $0 === current } ?? 0,
                tabs: tabs.map { controller in
                    SessionSnapshot.Tab(
                        book: controller.session.book?.location,
                        dock: controller.dock.dockLayout,
                        waterfallExtent: controller.viewer.continuous.waterfallExtent
                    )
                }
            )
        }
        return SessionSnapshot(windows: windows)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services else { return .terminateNow }
        keyBindingsTask?.cancel()
        settingsErrorsTask?.cancel()
        sessionSaveEnabled = false
        let snapshot = sessionStore == nil ? nil : sessionSnapshot()
        // shutdown 自己有时限，不等被卡住的 I/O。
        Task {
            for controller in controllers { await controller.session.flush() }
            if let snapshot { await sessionStore?.flush(snapshot) }
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
            self?.scheduleSessionSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        let window = controller.window!
        if controllers.isEmpty {
            window.center()
            cascadePoint = .zero
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        controllers.append(controller)
        showFileProblems(in: controller)
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
