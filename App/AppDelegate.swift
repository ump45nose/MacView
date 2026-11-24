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
    private(set) var menuBuilder: MenuBuilder?
    private(set) var contextMenuProvider: ContextMenuProvider?
    private(set) var services: CoreServices?
    private(set) var dispatcher: CommandDispatcher?
    private(set) var dock: DockCoordinator?
    private(set) var appearance: AppearanceController?
    private(set) var fileOps: FileOperationController?
    private(set) var metadataWriter: MetadataWriteController?
    private(set) var extensions: ExtensionCommands?
    var isMock: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "MVMockServices")
        #else
        false
        #endif
    }
    private var keyBindingsTask: Task<Void, Never>?
    private var menusTask: Task<Void, Never>?
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
    /// 供“显示 → 套用显示配置”动态子菜单同步读取的配置列表快照。
    private(set) var cachedProfiles: [DisplayProfile] = []
    /// NSWindow 不持有自己的控制器，由这里保留到窗口关闭。
    private(set) var controllers: [ReaderWindowController] = []
    /// 最近成为活动窗口的阅读窗口，供设置窗口等非阅读窗打开时定位目标。
    private weak var recentReaderController: ReaderWindowController?
    /// 阅读窗口增减或活动状态变化后调用（供设置页更新可用性）。
    var onReaderWindowsChange: (() -> Void)?
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
        #if DEBUG
        // 自检截图用：`-MVAppearance dark` 或 `light`。
        if let name = UserDefaults.standard.string(forKey: "MVAppearance") {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        #endif
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
        #if DEBUG
        // 自检和调试接口一律指向隔离目录，不碰用户的配置、缓存和停靠布局；少给一个就直接失败退出。
        if TestPresentation.isTestInstance {
            let missing = [Self.supportDirectoryKey, Self.cacheDirectoryKey, DockCoordinator.layoutFileKey].filter { UserDefaults.standard.string(forKey: $0) == nil }
            if !missing.isEmpty {
                print("FAIL 测试实例缺少隔离目录参数：\(missing.map { "-" + $0 }.joined(separator: " "))")
                fflush(stdout)
                exit(64)
            }
        }
        #endif
        do {
            let services = try await makeServices()
            self.services = services
            fileOps = FileOperationController(app: self)
            metadataWriter = MetadataWriteController(app: self)
            configureContextMenuProvider()
            let dispatcher = CommandDispatcher(registry: services.commands)
            dispatcher.onDisabledCommand = { [weak self] id, controller in
                self?.metadataWriter?.handleDisabledCommand(id, in: controller) ?? false
            }
            self.dispatcher = dispatcher
            let dock = DockCoordinator(
                fileURL: DockCoordinator.defaultFileURL(),
                schemesFileURL: DockCoordinator.defaultSchemesFileURL(supportDirectory: supportDirectory)
            )
            self.dock = dock
            let appearance = AppearanceController(store: services.settings)
            appearance.attach(dock: dock)
            appearance.start()
            self.appearance = appearance
            registerCommands(in: services.commands)
            registerFrameDirectionCommands(in: services.commands)
            registerWindowAppearanceCommands(in: services.commands)
            registerLayoutSchemeCommands(in: services.commands)
            let extensions = ExtensionCommands(app: self, services: services)
            self.extensions = extensions
            extensions.start()
            reloadCatalog()
            observeBindings()
            observeMenus()
            observeSettingsErrors()
            observeReaderActivation()
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
        await fileOps?.presentStartupRecovery()
        logger.info("启动完成")
        #if DEBUG
        SelfTest.runIfRequested(app: self)
        DockSelfTest.runIfRequested(app: self)
        ViewerSelfTest.runIfRequested(app: self)
        PanelSelfTest.runIfRequested(app: self)
        SettingsSelfTest.runIfRequested(app: self)
        SessionSelfTest.runIfRequested(app: self)
        FileOpsSelfTest.runIfRequested(app: self)
        LibrarySelfTest.runIfRequested(app: self)
        SearchSelfTest.runIfRequested(app: self)
        EffectsSelfTest.runIfRequested(app: self)
        InputSelfTest.runIfRequested(app: self)
        AppearanceSelfTest.runIfRequested(app: self)
        VideoPreviewSelfTest.runIfRequested(app: self)
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

    /// 打开设置窗口并切到指定页签（可选滚到指定节）。
    @discardableResult
    func openSettings(page: SettingsPage, scrollTo section: String? = nil) -> SettingsWindowController? {
        guard let controller = openSettings() else { return nil }
        controller.show(page: page, scrollTo: section)
        return controller
    }

    #if DEBUG
    static let supportDirectoryKey = "MVSupportDirectory"
    static let cacheDirectoryKey = "MVCacheDirectory"
    #endif

    /// Debug 构建可覆盖目录；测试实例必须覆盖（见 `start`）。
    private func makeServices() async throws -> CoreServices {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: Self.supportDirectoryKey) { supportDirectory = URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: Self.cacheDirectoryKey) { cacheDirectory = URL(fileURLWithPath: path) }
        await FileOpsSelfTest.prepareStartupRecoveryIfNeeded(supportDirectory: supportDirectory)
        #endif
        try? FileManager.default.removeItem(at: cacheDirectory.appending(path: "rendered", directoryHint: .isDirectory))
        if isMock { return CoreServices.makeMock() }
        let pixels = NSScreen.screens.map { $0.frame.size.applying(.init(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
        let bounds = PixelSize(width: Int(pixels.map(\.width).max() ?? 3840), height: Int(pixels.map(\.height).max() ?? 2160))
        return try await CoreServices.make(configuration: CoreConfiguration(
            supportDirectory: supportDirectory, cacheDirectory: cacheDirectory,
            browseBounds: bounds, helperExecutable: Bundle.main.executableURL
        ))
    }

    private func configureContextMenuProvider() {
        let provider = ContextMenuProvider(app: self)
        fileOps?.registerContextMenuProviders(in: provider)
        LibraryActions.registerContextMenuProviders(in: provider, app: self)
        metadataWriter?.registerContextMenuProviders(in: provider)
        provider.register(dynamic: .displayProfiles) { [weak self] _ in
            guard let self else { return nil }
            let sub = NSMenu(title: String(localized: "套用显示配置"))
            let enabled = updateSubmenu(key: "套用显示配置", menu: sub)
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            holder.isEnabled = enabled
            return holder
        }
        provider.register(dynamic: .layoutSchemes) { [weak self] _ in
            guard let self else { return nil }
            let sub = NSMenu(title: String(localized: "布局方案"))
            let enabled = populateLayoutSchemesMenu(sub)
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            holder.isEnabled = enabled
            return holder
        }
        contextMenuProvider = provider
    }

    func reloadCatalog() {
        catalog = CommandCatalog(
            file: services?.keyBindings?.value() ?? KeyBindingsFile(),
            menuFile: services?.menus?.value() ?? MenuFile(),
            descriptors: services?.commands.descriptors()
        )
        SettingsCommandCatalog.reload(from: services?.commands)
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
                    reloadCatalog()
                case let .fileError(message):
                    setFileProblem("keybindings.json", message)
                }
            }
        }
    }

    private func observeMenus() {
        guard let store = services?.menus else { return }
        let changes = store.changes()
        menusTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .reloaded:
                    setFileProblem("menus.json", nil)
                    reloadCatalog()
                case let .fileError(message):
                    setFileProblem("menus.json", message)
                }
            }
        }
    }

    private func observeSettingsErrors() {
        guard let services else { return }
        let changes = services.settings.changes()
        settingsErrorsTask = Task { [weak self] in
            let initialProfiles = await services.settings.profiles()
            guard let self, !Task.isCancelled else { return }
            self.cachedProfiles = initialProfiles
            for await change in changes {
                guard !Task.isCancelled else { return }
                switch change {
                case .global: setFileProblem("settings.json", nil)
                case .pathRules: setFileProblem("path-rules.json", nil)
                case .profiles:
                    setFileProblem("profiles.json", nil)
                    cachedProfiles = await services.settings.profiles()
                case let .fileError(file, message): setFileProblem(file, message)
                }
            }
        }
    }

    /// 配置错误按文件各一条；修好后 `message` 为 nil，这一条消失。
    func setFileProblem(_ file: String, _ message: String?) {
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
            #if DEBUG
            TestPresentation.present(shown?.window)
            #endif
            front = shown ?? front
        }
        return front
    }

    private func restore(_ tab: SessionSnapshot.Tab, in controller: ReaderWindowController) {
        if let layout = tab.dock { dock?.restore(controller.dock, layout: layout) }
        if let extent = tab.waterfallExtent { controller.viewer.continuous.waterfallExtent = extent }
        if let book = tab.book { controller.openBook(book, restoring: true) }
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
        menusTask?.cancel()
        settingsErrorsTask?.cancel()
        extensions?.stop()
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

    /// 最近活动的阅读窗口：设置窗口打开时仍指向之前激活的阅读窗口；所有阅读窗口关闭时为 nil。
    var activeReaderController: ReaderWindowController? {
        for candidate in [mainController, recentReaderController, controllers.first].compactMap({ $0 }) {
            if candidate.window != nil, controllers.contains(where: { $0 === candidate }) {
                return candidate
            }
        }
        return nil
    }

    private func observeReaderActivation() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleReaderWindowActivated(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(handleReaderWindowActivated(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(handleReaderWindowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func handleReaderWindowActivated(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              let reader = window.windowController as? ReaderWindowController,
              controllers.contains(where: { $0 === reader }) else { return }
        recentReaderController = reader
        dock?.activate(reader.dock)
        onReaderWindowsChange?()
    }

    @objc private func handleReaderWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              let reader = window.windowController as? ReaderWindowController else { return }
        if recentReaderController === reader {
            recentReaderController = controllers.last { $0 !== reader }
        }
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
        #if DEBUG
        TestPresentation.present(window)
        #endif
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
        #if DEBUG
        TestPresentation.present(window)
        #endif
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
        guard let services, let dispatcher, let dock, let fileOps else { return nil }
        let controller = ReaderWindowController(services: services, catalog: catalog, dispatcher: dispatcher, dock: dock, fileOps: fileOps, isMock: isMock)
        controller.onOpenExtra = { [weak self, weak controller] urls in
            guard let self, let controller else { return }
            for url in urls {
                newTab(beside: controller)?.open([url])
            }
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.onReaderWindowsChange?()
            self?.scheduleSessionSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSessionSave() }
        let window = controller.window!
        if controllers.isEmpty {
            #if DEBUG
            if TestPresentation.isTestInstance { TestPresentation.place(window) } else { window.center() }
            #else
            window.center()
            #endif
            cascadePoint = .zero
        }
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        controllers.append(controller)
        onReaderWindowsChange?()
        appearance?.register(controller)
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

    func populateLayoutSchemesMenu(_ menu: NSMenu) -> Bool {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let schemes = dock?.schemes ?? []
        let hasWindow = activeReaderController != nil
        if schemes.isEmpty {
            let empty = NSMenuItem(title: String(localized: "还没有布局方案"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for scheme in schemes {
                let item = NSMenuItem(title: scheme.name, action: #selector(applyLayoutSchemeFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = hasWindow
                item.representedObject = scheme.name
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: String(localized: "管理布局方案…"), action: #selector(manageLayoutSchemesFromMenu(_:)), keyEquivalent: "")
        manage.target = self
        manage.isEnabled = NSApp.modalWindow == nil
        menu.addItem(manage)
        return true
    }

    @objc private func applyLayoutSchemeFromMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let target = activeReaderController
        dispatcher?.run(.layoutSchemeApply, arguments: ["name": .string(name)], in: target, scope: menuScope)
    }

    @objc private func manageLayoutSchemesFromMenu(_ sender: Any?) {
        dispatcher?.run(.layoutSchemeManage, in: mainController, scope: menuScope)
    }

    private var targetReaderWindow: ReaderWindow? {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? controllers.first?.window) as? ReaderWindow
    }

    @objc func undo(_ sender: Any?) {
        targetReaderWindow?.undo(sender)
    }

    @objc func redo(_ sender: Any?) {
        targetReaderWindow?.redo(sender)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        targetReaderWindow?.validateMenuItem(menuItem) ?? false
    }

    #if DEBUG
    private func debugMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "调试"))
        menu.addItem(withTitle: String(localized: "画布测试"), action: #selector(showCanvasTest(_:)), keyEquivalent: "")
        return menu
    }
    #endif
}
