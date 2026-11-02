import AppKit
import MVCommands
import MVFoundation
import MVReading
import MVServices
import MVSettings
import Observation
import os

/// 阅读窗口：没有被响应链处理的按键交给 InputRouter。
@MainActor
final class ReaderWindow: NSWindow {
    var router: InputRouter?

    override func keyDown(with event: NSEvent) {
        if router?.handle(event, in: self) != true {
            super.keyDown(with: event)
        }
    }
}

/// 一个窗口或标签页：持有自己的 ReaderSession、按键路由、停靠布局、页面视图和状态栏。
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSToolbarItemValidation, NSOpenSavePanelDelegate {
    static let tabbingIdentifier = "MacView.reader"

    let session: ReaderSession
    let router: InputRouter
    let pageView: PageView
    let content: ReaderContentView
    let pendingView: PendingSequenceView
    /// 本窗口的停靠区；页面视图在中间栏。
    let dock: WindowDock
    private let services: CoreServices
    private let dispatcher: CommandDispatcher
    private let catalog: CommandCatalog
    private let isMock: Bool
    private var openTask: Task<Void, Never>?
    private let bookTitle = NSTextField(labelWithString: "")
    private let bookPath = NSTextField(labelWithString: "")
    private let logger = Logger(category: "window")
    /// 打开时有多个 URL，除第一个外的交给调用方（另开标签页）。
    var onOpenExtra: (([URL]) -> Void)?
    var onClose: ((ReaderWindowController) -> Void)?

    init(services: CoreServices, catalog: CommandCatalog, dispatcher: CommandDispatcher, dock dockCoordinator: DockCoordinator, isMock: Bool) {
        self.services = services
        self.dispatcher = dispatcher
        self.isMock = isMock
        session = services.makeSession()
        pageView = PageView(session: session, pipeline: services.pipeline)
        let statusBar = StatusBarView(
            serviceBadge: isMock ? String(localized: "Mock 服务") : "",
            badgeToolTip: String(localized: "尚未接入真实服务，书和图片来自内存中的模拟目录（/Volumes/Mock）。")
        )
        let mainView = ReaderMainView(pageView: pageView)
        pendingView = mainView.pendingView
        dock = WindowDock(coordinator: dockCoordinator, mainView: mainView)
        content = ReaderContentView(mainView: dock, statusBar: statusBar)
        self.catalog = catalog
        router = InputRouter(catalog: catalog)

        let window = ReaderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        // 窗口由控制器持有，关闭时不能再让 AppKit 释放一次。
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        window.backgroundColor = Theme.ground
        // 标题栏透出窗口底色；书名由工具栏项按设计稿绘制，`title` 仍供标签页和“窗口”菜单使用。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = content
        window.initialFirstResponder = pageView
        window.router = router
        super.init(window: window)
        router.onCommand = { [weak self] id, arguments, scope in
            self?.dispatcher.run(id, arguments: arguments, in: self, scope: scope)
        }
        window.delegate = self

        let toolbar = NSToolbar(identifier: "MacView.reader")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        router.onPendingChange = { [weak self] pending in self?.pendingView.show(pending) }
        pageView.onOpen = { [weak self] in self?.run(.fileOpen) }
        content.onDrop = { [weak self] urls in self?.open(urls) }
        statusBar.onJump = { [weak self] number in self?.session.go(.index(number - 1)) }
        statusBar.onJumpEnd = { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(pageView)
        }
        dockCoordinator.attach(dock, to: self)
        observeSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 按第一响应者的作用域执行命令，供工具栏和按钮使用。
    func run(_ id: CommandID) {
        dispatcher.run(id, in: self, scope: InputRouter.scope(of: window?.firstResponder))
    }

    // MARK: 会话

    private func observeSession() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSession() }
        }
    }

    private func render() {
        let location = session.book?.location
        window?.title = location?.name ?? "MacView"
        bookTitle.stringValue = window?.title ?? ""
        bookPath.stringValue = location?.parent.map(Self.breadcrumb) ?? ""
        bookPath.isHidden = bookPath.stringValue.isEmpty
        pageView.refresh()
        content.statusBar.refresh(session)
        window?.toolbar?.validateVisibleItems()
    }

    /// 显示用的路径，例如 `mock › 画集 › 系列 A`。
    private static func breadcrumb(_ location: Location) -> String {
        location.description.split(separator: "/").map(String.init).joined(separator: " › ")
    }

    /// 打开文件夹或压缩包：经 SourceRegistry 转成 Location 后交给会话；多出的 URL 交给 `onOpenExtra`。
    func open(_ urls: [URL]) {
        guard let url = urls.first else { return }
        if urls.count > 1 {
            onOpenExtra?(Array(urls.dropFirst()))
        }
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            let location: Location
            do {
                location = try await services.sources.location(for: url)
            } catch {
                guard !Task.isCancelled else { return }
                presentOpenError(error, url: url)
                return
            }
            logger.info("打开 \(location.description, privacy: .public)")
            await session.open(location, at: nil)
        }
    }

    func openNeighbor(_ direction: NavigationDirection) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            // 书架面板（S2-F2）之前没有书架的排序，按名称。
            await self?.session.openNeighborBook(direction, sort: SortSpec(key: .name))
        }
    }

    private func presentOpenError(_ error: any Error, url: URL) {
        logger.error("无法打开 \(url.path, privacy: .public)：\(String(describing: error), privacy: .public)")
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "无法打开“\(url.lastPathComponent)”")
        var detail = ErrorText.describe(error)
        if isMock {
            detail += "\n" + String(localized: "当前使用 Mock 服务，只能打开 /Volumes/Mock 下的模拟目录。")
        }
        alert.informativeText = detail
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// 打开面板：只能选文件夹和压缩包。
    func chooseBook() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "选择要打开的文件夹或压缩包")
        panel.prompt = String(localized: "打开")
        panel.delegate = self
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open([url])
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if case .archive = EntryKind(fileName: url.lastPathComponent) { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func beginPageJump() {
        let current = (session.frames.indices.contains(session.currentFrame)
            ? session.frames[session.currentFrame].elements.map(\.page).min() : nil) ?? 0
        content.statusBar.beginJump(current: current + 1)
    }

    // MARK: 窗口

    func windowDidBecomeMain(_ notification: Notification) {
        dock.coordinator.activate(dock)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        dock.setAutoHide(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        dock.setAutoHide(false)
    }

    func windowWillClose(_ notification: Notification) {
        dock.coordinator.detach(dock)
        openTask?.cancel()
        pageView.cancelLoads()
        services.pipeline.cancelAll(session: session.id)
        onClose?(self)
    }

    // MARK: 工具栏

    private static let toolbarTitle = NSToolbarItem.Identifier("book.title")

    private static let toolbarCommands: [NSToolbarItem.Identifier: (command: CommandID, symbol: String)] = [
        .init("book.previous"): (.bookPrevious, "chevron.left"),
        .init("book.next"): (.bookNext, "chevron.right"),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("book.previous"), .init("book.next"), Self.toolbarTitle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.toolbarTitle { return makeTitleItem() }
        guard let entry = Self.toolbarCommands[identifier] else { return nil }
        let title = catalog.title(of: entry.command)
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: title)
        item.label = title
        item.toolTip = title
        item.isBordered = true
        item.isNavigational = true
        item.target = self
        item.action = #selector(toolbarCommand(_:))
        return item
    }

    /// 书名（衬线 17/500）和它所在的路径。
    private func makeTitleItem() -> NSToolbarItem {
        bookTitle.font = Theme.serif(17)
        bookTitle.textColor = Theme.text
        bookPath.font = .systemFont(ofSize: 11)
        bookPath.textColor = Theme.text2
        for label in [bookTitle, bookPath] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [bookTitle, bookPath])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let item = NSToolbarItem(itemIdentifier: Self.toolbarTitle)
        item.view = stack
        item.isBordered = false
        item.autovalidates = false
        item.visibilityPriority = .high
        return item
    }

    @objc private func toolbarCommand(_ sender: NSToolbarItem) {
        guard let entry = Self.toolbarCommands[sender.itemIdentifier] else { return }
        run(entry.command)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let entry = Self.toolbarCommands[item.itemIdentifier] else { return false }
        return dispatcher.isEnabled(entry.command, in: self, scope: InputRouter.scope(of: window?.firstResponder))
    }
}
