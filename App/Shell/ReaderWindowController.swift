import AppKit
import MVCommands
import MVFoundation
import MVLayout
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

/// 工具栏的停靠区开关：尺寸和按下态的底色按设计稿，系统按钮的强调色底不受令牌控制，所以自绘。
@MainActor
private final class DockToggleButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            Theme.selected.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 一个窗口或标签页：持有自己的 ReaderSession、按键路由、停靠布局、页面视图和状态栏。
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSToolbarItemValidation, NSOpenSavePanelDelegate {
    static let tabbingIdentifier = "MacView.reader"

    let session: ReaderSession
    private(set) var router: InputRouter
    let viewer: ViewerContainerView
    let content: ReaderContentView
    let pendingView: PendingSequenceView
    /// 本窗口的停靠区；页面视图在中间栏。
    let dock: WindowDock
    private let services: CoreServices
    private let dispatcher: CommandDispatcher
    private var catalog: CommandCatalog
    private let isMock: Bool
    private var openTask: Task<Void, Never>?
    private let bookTitle = NSTextField(labelWithString: "")
    private let bookPath = NSTextField(labelWithString: "")
    private let browseControl = BrowseModeControl(
        labels: [String(localized: "单页"), String(localized: "双页"), String(localized: "瀑布"), String(localized: "竖条"), String(localized: "横条")]
    )
    private lazy var optionsButton = NSButton(
        title: String(localized: "显示"), image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil) ?? NSImage(),
        target: self, action: #selector(toggleOptions(_:))
    )
    private lazy var fullScreenButton = NSButton(
        image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: String(localized: "全屏")) ?? NSImage(),
        target: self, action: #selector(toggleFullScreen(_:))
    )
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sizeSlider = NSSlider()
    private var optionsPopover: NSPopover?
    /// 工具栏的停靠区开关，按下态跟随本窗口的布局。
    private(set) var dockToggles: [DockEdge: NSButton] = [:]
    private let logger = Logger(category: "window")
    /// 打开时有多个 URL，除第一个外的交给调用方（另开标签页）。
    var onOpenExtra: (([URL]) -> Void)?
    var onClose: ((ReaderWindowController) -> Void)?

    init(services: CoreServices, catalog: CommandCatalog, dispatcher: CommandDispatcher, dock dockCoordinator: DockCoordinator, isMock: Bool) {
        self.services = services
        self.dispatcher = dispatcher
        self.isMock = isMock
        session = services.makeSession()
        viewer = ViewerContainerView(session: session, services: ViewerServices(pipeline: services.pipeline, sources: services.sources, bookshelf: services.bookshelf))
        let statusBar = StatusBarView(
            serviceBadge: isMock ? String(localized: "Mock 服务") : "",
            badgeToolTip: isMock ? String(localized: "尚未接入真实服务，书和图片来自内存中的模拟目录（/Volumes/Mock）。") : ""
        )
        let mainView = ReaderMainView(viewer: viewer)
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
        window.initialFirstResponder = viewer
        window.router = router
        super.init(window: window)
        router.onCommand = { [weak self] id, arguments, scope in
            self?.dispatcher.run(id, arguments: arguments, in: self, scope: scope)
        }
        window.delegate = self

        configureBrowseControls()
        for entry in Self.dockToggleItems.values { dockToggles[entry.edge] = makeDockToggle(entry) }
        dock.onLayoutChange = { [weak self] in self?.updateDockToggles() }
        let toolbar = NSToolbar(identifier: "MacView.reader")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        router.onPendingChange = { [weak self] pending in self?.pendingView.show(pending) }
        viewer.onOpen = { [weak self] in self?.run(.fileOpen) }
        viewer.onRetryBook = { [weak self] in self?.reopenBook() }
        viewer.onConnect = { [weak self] in self?.connectVolume() }
        viewer.continuous.onWaterfallExtentChange = { [weak self] in self?.updateWaterfallControls() }
        content.onDrop = { [weak self] urls in self?.open(urls) }
        statusBar.onJump = { [weak self] number in self?.session.go(.index(number - 1)) }
        statusBar.onJumpEnd = { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(viewer)
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

    /// InputRouter 持有解析器状态；配置重载时整体替换，并清除未完成的序列。
    func updateBindings(_ catalog: CommandCatalog) {
        self.catalog = catalog
        router = InputRouter(catalog: catalog)
        router.onCommand = { [weak self] id, arguments, scope in
            self?.dispatcher.run(id, arguments: arguments, in: self, scope: scope)
        }
        router.onPendingChange = { [weak self] pending in self?.pendingView.show(pending) }
        (window as? ReaderWindow)?.router = router
        pendingView.show(nil)
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
        bookPath.stringValue = titleDetail(location)
        bookPath.isHidden = bookPath.stringValue.isEmpty
        viewer.refresh()
        updateBrowseControls()
        content.statusBar.refresh(session)
        window?.toolbar?.validateVisibleItems()
    }

    /// 书名下面的一行：所在路径；单页模式前面加当前页。
    private func titleDetail(_ location: Location?) -> String {
        let path = location?.parent.map(Self.breadcrumb) ?? ""
        let settings = session.settings
        guard settings.browseMode == .paged, settings.pageMode == .single, let pages = session.book?.pages, pages.indices.contains(session.currentPage) else { return path }
        let page = String(localized: "第 \(session.currentPage + 1) 页 · \(pages[session.currentPage].entry.name)")
        return path.isEmpty ? page : page + " · " + path
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
            guard let self else { return }
            await session.openNeighborBook(direction, sort: session.neighborSort)
        }
    }

    /// 重新打开这本书：书的位置不丢。
    func reopenBook() {
        guard let location = session.book?.location else { return }
        openTask?.cancel()
        openTask = Task { [weak self] in await self?.session.open(location, at: nil) }
    }

    /// 让系统挂载书所在的卷。
    func connectVolume() {
        guard let url = session.book?.location.root.mountURL else { return }
        NSWorkspace.shared.open(url)
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
        viewer.cancelLoads()
        services.pipeline.cancelAll(session: session.id)
        onClose?(self)
    }

    // MARK: 工具栏

    private static let toolbarTitle = NSToolbarItem.Identifier("book.title")

    private static let toolbarCommands: [NSToolbarItem.Identifier: (command: CommandID, symbol: String)] = [
        .init("book.previous"): (.bookPrevious, "chevron.left"),
        .init("book.next"): (.bookNext, "chevron.right"),
    ]

    private typealias DockToggleItem = (edge: DockEdge, command: CommandID, symbol: String)

    private static let dockToggleItems: [NSToolbarItem.Identifier: DockToggleItem] = [
        .init("dock.left"): (.left, .dockLeftToggle, "sidebar.left"),
        .init("dock.right"): (.right, .dockRightToggle, "sidebar.right"),
    ]

    private static let toolbarBrowse = NSToolbarItem.Identifier("view.browse")
    private static let toolbarWaterfall = NSToolbarItem.Identifier("view.waterfallOptions")
    private static let toolbarOptions = NSToolbarItem.Identifier("view.options")
    private static let toolbarFullScreen = NSToolbarItem.Identifier("window.fullScreen")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .init("dock.left"), .init("book.previous"), .init("book.next"), Self.toolbarTitle, .flexibleSpace,
            Self.toolbarWaterfall, Self.toolbarBrowse, Self.toolbarOptions, Self.toolbarFullScreen, .init("dock.right"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.toolbarTitle { return makeTitleItem() }
        if identifier == Self.toolbarBrowse { return viewItem(identifier, browseControl, label: String(localized: "浏览方式")) }
        if identifier == Self.toolbarWaterfall {
            let stack = NSStackView(views: [sortButton, sizeSlider])
            stack.spacing = 8
            return viewItem(identifier, stack, label: String(localized: "瀑布流选项"))
        }
        if identifier == Self.toolbarOptions { return viewItem(identifier, optionsButton, label: String(localized: "显示")) }
        if identifier == Self.toolbarFullScreen { return viewItem(identifier, fullScreenButton, label: catalog.title(of: .fullScreenToggle)) }
        if let entry = Self.dockToggleItems[identifier] { return makeDockToggleItem(identifier, entry) }
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

    private func viewItem(_ identifier: NSToolbarItem.Identifier, _ view: NSView, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.view = view
        item.isBordered = false
        item.autovalidates = false
        return item
    }

    private func configureBrowseControls() {
        browseControl.onSelect = { [weak self] index in self?.browseChanged(index) }
        optionsButton.isBordered = false
        optionsButton.imagePosition = .imageLeading
        optionsButton.font = .systemFont(ofSize: 12)
        optionsButton.contentTintColor = Theme.text
        fullScreenButton.isBordered = false
        fullScreenButton.contentTintColor = Theme.text
        fullScreenButton.toolTip = catalog.title(of: .fullScreenToggle)
        sortButton.isBordered = false
        sortButton.font = .systemFont(ofSize: 12)
        sortButton.pullsDown = true
        sortButton.menu = viewerSortMenu()
        sizeSlider.controlSize = .small
        sizeSlider.minValue = 120
        sizeSlider.maxValue = 480
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
    }

    /// 瀑布流工具项的排序菜单：第一项是按钮的标题。
    private func viewerSortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for (id, _) in Self.sortCommands {
            let item = NSMenuItem(title: catalog.title(of: id), action: #selector(sortPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private static let sortCommands: [(CommandID, SortKey)] = [
        (.sortName, .name), (.sortModified, .modified), (.sortCreated, .created), (.sortSize, .size), (.sortType, .type), (.sortRandom, .random),
    ]

    @objc private func sortPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        run(CommandID(raw))
    }

    private func updateBrowseControls() {
        let settings = session.settings
        browseControl.selected = switch settings.browseMode {
        case .paged: settings.pageMode == .single ? 0 : 1
        case .waterfall: 2
        case .verticalStrip: 3
        case .horizontalStrip: 4
        }
        let item = window?.toolbar?.items.first { $0.itemIdentifier == Self.toolbarWaterfall }
        item?.isHidden = settings.browseMode != .waterfall
        sortButton.menu?.items.first?.title = Self.sortTitle(settings.sort.key)
        sortButton.title = Self.sortTitle(settings.sort.key)
        updateWaterfallControls()
    }

    private func updateWaterfallControls() {
        sizeSlider.doubleValue = viewer.continuous.waterfallExtent
    }

    private static func sortTitle(_ key: SortKey) -> String {
        switch key {
        case .name: String(localized: "名称")
        case .modified: String(localized: "修改时间")
        case .created: String(localized: "创建时间")
        case .size: String(localized: "大小")
        case .type: String(localized: "类型")
        case .random: String(localized: "随机")
        }
    }

    private func browseChanged(_ index: Int) {
        switch index {
        case 0:
            session.update {
                $0.browseMode = .paged
                $0.pageMode = .single
            }
        case 1:
            session.update {
                $0.browseMode = .paged
                $0.pageMode = .double
            }
        case 2: run(.browseWaterfall)
        case 3: run(.browseVerticalStrip)
        default: run(.browseHorizontalStrip)
        }
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        viewer.continuous.waterfallExtent = sender.doubleValue
    }

    @objc private func toggleOptions(_ sender: NSButton) {
        if let optionsPopover, optionsPopover.isShown {
            optionsPopover.close()
            return
        }
        let popover = ViewOptionsPopover.make(session: session, viewer: viewer)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        optionsPopover = popover
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        run(.fullScreenToggle)
    }

    private func makeDockToggle(_ entry: DockToggleItem) -> NSButton {
        let title = catalog.title(of: entry.command)
        let button = DockToggleButton(
            image: NSImage(systemSymbolName: entry.symbol, accessibilityDescription: title) ?? NSImage(),
            target: self, action: #selector(dockToggleClicked(_:))
        )
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.contentTintColor = Theme.text
        button.toolTip = title
        return button
    }

    private func makeDockToggleItem(_ identifier: NSToolbarItem.Identifier, _ entry: DockToggleItem) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = catalog.title(of: entry.command)
        item.view = dockToggles[entry.edge]
        item.isBordered = false
        item.autovalidates = false
        // 导航项排在工具栏最前，左侧开关要在它们之前。
        item.isNavigational = entry.edge == .left
        return item
    }

    private func updateDockToggles() {
        for (edge, button) in dockToggles {
            button.state = dock.dockLayout.isShowing(edge) ? .on : .off
            button.isEnabled = !dock.dockLayout.visiblePanels(in: edge).isEmpty
        }
    }

    @objc private func dockToggleClicked(_ sender: NSButton) {
        guard let entry = Self.dockToggleItems.values.first(where: { dockToggles[$0.edge] === sender }) else { return }
        run(entry.command)
        // 命令没有改变布局时，按钮自己翻转的状态要改回来。
        updateDockToggles()
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
        // 路径可能很长，不能把后面的工具项挤进溢出菜单。
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
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
