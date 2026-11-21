import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVLibraryData
import MVReading
import MVServices
import MVSettings
import Observation
import os

/// 阅读窗口：没有被响应链处理的按键交给 InputRouter。
@MainActor
final class ReaderWindow: NSWindow {
    var router: InputRouter?
    weak var fileOps: FileOperationController?
    weak var statusBar: StatusBarView?
    #if DEBUG
    private(set) var performDragCallCount = 0
    #endif

    override var undoManager: UndoManager? {
        (delegate as? ReaderWindowController)?.windowWillReturnUndoManager(self) ?? super.undoManager
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let controller = delegate as? ReaderWindowController,
           controller.chrome.isBorderlessActive,
           let hit = contentView?.hitTest(event.locationInWindow),
           hit.isDescendant(of: controller.viewer) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    override func performDrag(with event: NSEvent) {
        #if DEBUG
        performDragCallCount += 1
        #endif
        super.performDrag(with: event)
    }

    override func toggleFullScreen(_ sender: Any?) {
        (delegate as? ReaderWindowController)?.chrome.prepareForFullScreenToggle()
        super.toggleFullScreen(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is NSTextView), fileOps?.isBusy == true, let chord = KeyMapping.chord(for: event),
           chord == KeyChord("z", modifiers: .command) || chord == KeyChord("z", modifiers: [.command, .shift]) {
            statusBar?.showMessage(String(localized: "文件操作完成后才能撤销"))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let controller = delegate as? ReaderWindowController
        if let panelWindow = controller?.classifyPanel?.view.window, panelWindow !== self,
           let editor = panelWindow.firstResponder as? NSTextView, editor.isEditable {
            editor.keyDown(with: event)
            return
        }
        if router?.handle(event, in: self, overlay: controller?.inputOverlay) != true {
            super.keyDown(with: event)
        }
    }

    @objc func undo(_ sender: Any?) { stepUndo(isUndo: true) }
    @objc func redo(_ sender: Any?) { stepUndo(isUndo: false) }

    private func stepUndo(isUndo: Bool) {
        if let textView = firstResponder as? NSTextView {
            if isUndo { textView.undoManager?.undo() } else { textView.undoManager?.redo() }
            return
        }
        guard let fileOps else { return }
        if fileOps.isBusy {
            statusBar?.showMessage(String(localized: "文件操作完成后才能撤销"))
        } else if isUndo, fileOps.undoManager.canUndo {
            fileOps.undoManager.undo()
        } else if !isUndo, fileOps.undoManager.canRedo {
            fileOps.undoManager.redo()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(undo(_:)) || menuItem.action == #selector(redo(_:)) else {
            return super.validateMenuItem(menuItem)
        }
        let isUndo = menuItem.action == #selector(undo(_:))
        let textView = firstResponder as? NSTextView
        let manager = textView != nil ? textView?.undoManager : fileOps?.undoManager
        let canStep = (isUndo ? manager?.canUndo : manager?.canRedo) ?? false
        let name = (isUndo ? manager?.undoActionName : manager?.redoActionName) ?? ""
        menuItem.title = canStep && !name.isEmpty
            ? (isUndo ? String(localized: "撤销\(name)") : String(localized: "重做\(name)"))
            : (isUndo ? String(localized: "撤销") : String(localized: "重做"))
        return textView != nil ? canStep : (!(fileOps?.isBusy ?? true) && canStep)
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

/// 虚拟书标题前的“播放列表”标记：accent-soft 底的小胶囊。
@MainActor
private final class PlaylistMarkView: NSView {
    private let label = NSTextField(labelWithString: String(localized: "播放列表"))
    private static let textColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
            : NSColor(srgbRed: 0x8A / 255, green: 0x3F / 255, blue: 0x22 / 255, alpha: 1)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Self.textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accentSoft.cgColor
    }
}

/// 一个窗口或标签页：持有自己的 ReaderSession、按键路由、停靠布局、页面视图和状态栏。
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSToolbarItemValidation, NSOpenSavePanelDelegate {
    static let tabbingIdentifier = "MacView.reader"
    static let effectsEnabledDidChangeNotification = Notification.Name("MacView.effectsEnabledDidChange")

    /// 当前窗口是否启用实时调色；默认打开，不持久化。
    private(set) var effectsEnabled = true

    let session: ReaderSession
    private(set) var router: InputRouter
    let viewer: ViewerContainerView
    let content: ReaderContentView
    let chrome: WindowChrome
    let pendingView: PendingSequenceView
    /// 本窗口的停靠区；页面视图在中间栏。
    let dock: WindowDock
    let services: CoreServices
    let fileOps: FileOperationController
    let textUndoManager = UndoManager()
    private let dispatcher: CommandDispatcher
    private var catalog: CommandCatalog
    private let isMock: Bool
    private var openTask: Task<Void, Never>?
    private let bookTitle = NSTextField(labelWithString: "")
    /// 虚拟书的书名前的“播放列表”标记。
    private let playlistMark = PlaylistMarkView()
    /// 播放列表的名称，随资料库变化更新；虚拟书的标题用它。
    private var playlistNames: [UUID: String] = [:]
    private var libraryTask: Task<Void, Never>?
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
    private lazy var effectsToggleButton: NSButton = {
        let title = catalog.title(of: .effectsToggle)
        let button = DockToggleButton(
            image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: title) ?? NSImage(),
            target: self, action: #selector(effectsToggleClicked(_:))
        )
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.contentTintColor = Theme.text
        button.toolTip = title
        button.state = effectsEnabled ? .on : .off
        return button
    }()
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sizeSlider = NSSlider()
    private var optionsPopover: NSPopover?
    /// 工具栏的停靠区开关，按下态跟随本窗口的布局。
    private(set) var dockToggles: [DockEdge: NSButton] = [:]
    /// 程序按 menus.json 重建工具栏期间抑制写回，避免循环。
    private var isRebuildingToolbar = false
    private var toolbarSaveTask: Task<Void, Never>?
    private let logger = Logger(category: "window")
    /// 打开时有多个 URL，除第一个外的交给调用方（另开标签页）。
    var onOpenExtra: (([URL]) -> Void)?
    var onClose: ((ReaderWindowController) -> Void)?
    /// 窗口、书或布局变了，会话要重新保存。
    var onSessionChange: (() -> Void)?
    /// 上一次不是全屏时的 frame；全屏不进会话。
    private(set) var normalFrame = NSRect.zero
    private var healthTask: Task<Void, Never>?
    private var volumes: [VolumeHealth] = []
    #if DEBUG
    /// 首屏计时只给调试接口读，Release 不编译。这次打开的起点：调试接口在 `open` 之前记下；没有经过调试接口时，由页面列表在书出现时记下。
    private var firstScreenStart: ContinuousClock.Instant?
    private var firstScreenBook: Location?
    /// 调试接口的这次打开要等页面列表，书架封面不能抢先记成首屏。
    private var firstScreenExpectsBook = false
    /// 从这次打开到首屏可见项都有缩略图的毫秒。还没到是 nil。
    private(set) var firstScreenThumbnailMilliseconds: Double?
    #endif
    /// 窗口恢复只是继续上次会话，不把用户已清空或移除的历史重新写回。
    private var restoringBook = false

    init(services: CoreServices, catalog: CommandCatalog, dispatcher: CommandDispatcher, dock dockCoordinator: DockCoordinator, fileOps: FileOperationController, isMock: Bool) {
        self.services = services
        self.fileOps = fileOps
        self.dispatcher = dispatcher
        self.isMock = isMock
        session = services.makeSession()
        viewer = ViewerContainerView(session: session, services: ViewerServices(pipeline: services.pipeline, sources: services.sources, settings: services.settings, bookshelf: services.bookshelf, availability: services.availability))
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
        // 恢复由 SessionStore 负责，不用系统的窗口恢复。
        window.isRestorable = false
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        window.backgroundColor = Theme.ground
        // 标题栏透出窗口底色；书名由工具栏项按设计稿绘制，`title` 仍供标签页和“窗口”菜单使用。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = content
        window.initialFirstResponder = viewer
        window.router = router
        window.fileOps = fileOps
        window.statusBar = statusBar
        let toolbar = NSToolbar(identifier: "MacView.reader")
        chrome = WindowChrome(window: window, toolbar: toolbar, content: content)
        super.init(window: window)
        let recordOpened = session.onBookOpened
        session.onBookOpened = { [weak self] location in
            guard let self else { return }
            if restoringBook { restoringBook = false } else { recordOpened?(location) }
        }
        router.onCommand = { [weak self] id, arguments, scope in
            self?.dispatcher.run(id, arguments: arguments, in: self, scope: scope)
        }
        window.delegate = self

        configureBrowseControls()
        for entry in Self.dockToggleItems.values { dockToggles[entry.edge] = makeDockToggle(entry) }
        dock.onLayoutChange = { [weak self] in
            self?.updateDockToggles()
            self?.onSessionChange?()
        }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.autosavesConfiguration = false
        toolbar.allowsUserCustomization = true
        isRebuildingToolbar = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        syncToolbarItems(to: catalog.toolbar)
        isRebuildingToolbar = false

        router.onPendingChange = { [weak self] pending in self?.pendingView.show(pending) }
        viewer.onOpen = { [weak self] in self?.run(.fileOpen) }
        viewer.onRetryBook = { [weak self] in self?.reopenBook() }
        viewer.onConnect = { [weak self] in self?.connectVolume() }
        viewer.onContextMenu = { [weak self] entry in self?.viewerMenu(for: entry) }
        viewer.continuous.onWaterfallExtentChange = { [weak self] in
            self?.updateWaterfallControls()
            self?.onSessionChange?()
        }
        content.volumeStatus.onRetry = { [weak self] in self?.viewer.retryFailed() }
        content.onDrop = { [weak self] urls in self?.open(urls) }
        statusBar.onJump = { [weak self] number in self?.session.go(.index(number - 1)) }
        statusBar.onJumpEnd = { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(viewer)
        }
        dockCoordinator.attach(dock, to: self)
        observeSession()
        observeVolumes()
        observePlaylists()
        normalFrame = window.frame
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 设置当前窗口的效果开关；供命令处理器、效果面板与套用配置调用。
    func setEffectsEnabled(_ enabled: Bool) {
        guard effectsEnabled != enabled else { return }
        effectsEnabled = enabled
        viewer.setEffectsEnabled(enabled)
        effectsToggleButton.state = enabled ? .on : .off
        NotificationCenter.default.post(name: Self.effectsEnabledDidChangeNotification, object: self)
    }

    func toggleEffects() {
        setEffectsEnabled(!effectsEnabled)
        content.statusBar.showMessage(
            effectsEnabled ? String(localized: "效果已打开") : String(localized: "效果已关闭，显示原图")
        )
    }

    /// 按第一响应者的作用域执行命令，供工具栏和按钮使用。
    func run(_ id: CommandID) {
        dispatcher.run(id, in: self, scope: InputRouter.scope(of: window?.firstResponder))
    }

    /// 按当前焦点取一次文件命令的作用对象快照。
    func fileOrigin() -> FileOrigin {
        let key = NSApp.keyWindow
        let responder = (key === window || key is FloatingPanelWindow) ? key?.firstResponder : window?.firstResponder
        if let view = responder as? NSView {
            let panels = Array(dock.panels.values) + dock.coordinator.floatingWindows.values.map(\.panel)
            for case let panel as CollectionPanel in panels where panel.owner === self && view.isDescendant(of: panel.view) {
                return FileOrigin(window: self, items: panel.targetEntries)
            }
        }
        guard let book = session.book else { return FileOrigin(window: self) }
        // 虚拟书的页就是原文件的条目；列表本身不是文件，没有当前页时没有作用对象。
        if book.pages.indices.contains(session.currentPage) {
            return FileOrigin(window: self, items: [book.pages[session.currentPage].entry])
        }
        if session.isVirtualBook { return FileOrigin(window: self) }
        let kind: EntryKind = if case .archive = EntryKind(fileName: book.location.name) { EntryKind(fileName: book.location.name) } else { .directory }
        return FileOrigin(window: self, items: [Entry(identity: ContentIdentity(location: book.location, size: 0, modificationNanos: 0), name: book.location.name, kind: kind)])
    }

    /// 当前在本窗口打开（停靠且显示，或浮动且绑定到本窗口）的分类面板。
    var classifyPanel: ClassifyPanel? {
        if case let .docked(edge, _) = dock.dockLayout.placement(of: DockPanels.classify),
           dock.dockLayout.isPanelVisible(DockPanels.classify),
           dock.dockLayout[edge].style == .split || dock.dockLayout.currentTab(in: edge) == DockPanels.classify,
           let panel = dock.panels[DockPanels.classify] as? ClassifyPanel {
            return panel
        }
        if dock.coordinator.current.isPanelVisible(DockPanels.classify),
           let panel = dock.coordinator.floatingWindows[DockPanels.classify]?.panel as? ClassifyPanel,
           panel.owner === self {
            return panel
        }
        return nil
    }

    var inputOverlay: InputScope? {
        guard let panel = classifyPanel, !(window?.firstResponder is NSTextView),
              !(panel.view.window?.firstResponder is NSTextView) else { return nil }
        return .classify
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
        syncToolbarItems(to: catalog.toolbar)
    }

    /// 打开系统工具栏自定义面板（供设置页调用）。
    func runToolbarCustomization() {
        window?.toolbar?.runCustomizationPalette(nil)
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
        updateTitle()
        viewer.refresh()
        chrome.setFrostedBackground(session.settings.background == .frostedGlass)
        updateBrowseControls()
        content.statusBar.refresh(session)
        window?.toolbar?.validateVisibleItems()
        updateVolumeStatus()
        (dock.panels[DockPanels.classify] as? ClassifyPanel)?.refreshState()
        if let floating = dock.coordinator.floatingWindows[DockPanels.classify]?.panel as? ClassifyPanel, floating.owner === self {
            floating.refreshState()
        }
        onSessionChange?()
    }

    /// 书名与下面一行；虚拟书是“播放列表”标记加列表名，下面是“N 项，来自 M 本书”。
    private func updateTitle() {
        let location = session.book?.location
        if let playlist = location?.playlistID, let pages = session.book?.pages {
            window?.title = playlistNames[playlist] ?? LibraryActions.playlists.first { $0.id == playlist }?.name ?? String(localized: "播放列表")
            let books = Set(pages.compactMap { LibraryActions.containingBook(of: $0.id) }).count
            bookPath.stringValue = String(localized: "\(pages.count) 项，来自 \(books) 本书")
            playlistMark.isHidden = false
        } else {
            window?.title = location?.name ?? "MacView"
            bookPath.stringValue = titleDetail(location)
            playlistMark.isHidden = true
        }
        bookTitle.stringValue = window?.title ?? ""
        bookPath.isHidden = bookPath.stringValue.isEmpty
    }

    /// 播放列表改名后标题随之更新。
    private func observePlaylists() {
        guard let library = services.library else { return }
        let changes = library.changes()
        libraryTask = Task { [weak self] in
            await self?.loadPlaylistNames(library)
            for await change in changes where change == .playlists {
                guard let self else { return }
                await loadPlaylistNames(library)
            }
        }
    }

    private func loadPlaylistNames(_ library: any LibraryStore) async {
        guard let lists = try? await library.playlists() else { return }
        playlistNames = Dictionary(lists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        updateTitle()
    }

    /// 查看器右键：按 menus.json（缺省为默认查看器右键菜单树）经 MenuBuilder 与 ContextMenuProvider 生成。
    private func viewerMenu(for entry: Entry) -> NSMenu? {
        guard let app = NSApp.delegate as? AppDelegate,
              let builder = app.menuBuilder,
              let provider = app.contextMenuProvider else { return nil }
        return builder.contextMenu(
            nodes: catalog.viewerContextMenu,
            provider: provider,
            target: ContextMenuTarget(window: self, entries: [entry])
        )
    }

    #if DEBUG
    /// 调试接口在打开之前调用，把起点放在 `open` 之前。
    func beginFirstScreenThumbnails() {
        firstScreenStart = .now
        firstScreenThumbnailMilliseconds = nil
        firstScreenBook = nil
        firstScreenExpectsBook = true
    }

    /// 没有打开的书时，书架自己开始计封面。已经在等一本书的首屏时不重置。
    func beginShelfThumbnails() {
        guard session.book == nil, !firstScreenExpectsBook else { return }
        firstScreenStart = .now
        firstScreenThumbnailMilliseconds = nil
        firstScreenBook = nil
    }

    /// 书第一次出现时补记起点。调试接口已经记过这次打开时，不把起点往后推。
    func noteFirstScreenBook(_ location: Location) {
        if firstScreenBook == location { return }
        if firstScreenStart == nil || firstScreenBook != nil {
            firstScreenStart = .now
            firstScreenThumbnailMilliseconds = nil
        }
        firstScreenBook = location
    }

    /// 页面列表的可见项都有缩略图，或没有打开的书时书架可见项都有封面。
    func finishFirstScreenThumbnails(fromPageList: Bool) {
        if fromPageList {
            guard let book = session.book?.location, firstScreenBook == book else { return }
        } else if session.book != nil || firstScreenExpectsBook || firstScreenBook != nil {
            return
        }
        guard firstScreenThumbnailMilliseconds == nil, let start = firstScreenStart else { return }
        firstScreenExpectsBook = false
        firstScreenThumbnailMilliseconds = (ContinuousClock.now - start).milliseconds
    }
    #endif

    // MARK: 卷状态

    private func observeVolumes() {
        let updates = services.sources.volumeHealth()
        healthTask = Task { [weak self] in
            for await volumes in updates {
                guard let self, !Task.isCancelled else { return }
                let wasHealthy = currentVolume?.state ?? .healthy == .healthy
                let previous = Dictionary(self.volumes.map { ($0.root, $0.state) }, uniquingKeysWith: { $1 })
                self.volumes = volumes
                updateVolumeStatus()
                // 探测成功后自动恢复，失败项不用再点重试。
                if !wasHealthy, currentVolume?.state ?? .healthy == .healthy { viewer.retryFailed() }
                // 虚拟书的页来自多个卷：任一卷的状态变了就重查，并重试失败的页。
                let current = Dictionary(volumes.map { ($0.root, $0.state) }, uniquingKeysWith: { $1 })
                if session.isVirtualBook, Set(previous.keys).union(current.keys).contains(where: { (previous[$0] ?? .healthy) != (current[$0] ?? .healthy) }) {
                    viewer.recheckAvailability()
                    viewer.retryFailed()
                }
            }
        }
    }

    /// 当前书所在的卷。
    private var currentVolume: VolumeHealth? {
        guard let root = session.book?.location.root else { return nil }
        return volumes.first { $0.root == root }
    }

    private func updateVolumeStatus() {
        let health = currentVolume
        // 书整本打不开时由查看器的提示显示，同一件事不显示两次。
        let coveredByViewer = session.loadError.map(ViewerContainerView.isVolumeError) ?? false
        content.volumeStatus.show(health, showsBanner: !coveredByViewer)
        content.statusBar.setVolumeStatus(VolumeStatusView.statusText(for: health))
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
        restoringBook = false
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

    /// 打开书架上的一本书；传入 `page` 时打开后定位到该页（同一本书直接跳转）。
    func openBook(_ location: Location, at page: Location? = nil, restoring: Bool = false) {
        if let page, location == session.book?.location {
            if let index = session.book?.pages.firstIndex(where: { $0.id == page }) {
                session.go(.index(index))
                return
            }
        } else if page == nil, location == session.book?.location {
            return
        }
        restoringBook = restoring
        openTask?.cancel()
        openTask = Task { [weak self] in await self?.session.open(location, at: page) }
    }

    /// 本窗口关联的元数据写入控制器。
    var metadataWriter: MetadataWriteController? {
        (NSApp.delegate as? AppDelegate)?.metadataWriter
    }

    /// 本窗口当前关联的信息面板（停靠或浮动）。
    var infoPanel: InfoPanel? {
        if let docked = dock.panels[DockPanels.info] as? InfoPanel {
            return docked
        }
        if let floating = dock.coordinator.floatingWindows[DockPanels.info]?.panel as? InfoPanel,
           floating.owner === self {
            return floating
        }
        return nil
    }

    /// 本窗口当前关联的效果面板（停靠或浮动）。
    var effectsPanel: EffectsPanel? {
        if let docked = dock.panels[DockPanels.effects] as? EffectsPanel {
            return docked
        }
        if let floating = dock.coordinator.floatingWindows[DockPanels.effects]?.panel as? EffectsPanel,
           floating.owner === self {
            return floating
        }
        return nil
    }

    /// 本窗口当前关联的书架面板（停靠或浮动）。
    var bookshelfPanel: BookshelfPanel? {
        if let docked = dock.panels[DockPanels.bookshelf] as? BookshelfPanel {
            return docked
        }
        if let floating = dock.coordinator.floatingWindows[DockPanels.bookshelf]?.panel as? BookshelfPanel,
           floating.owner === self {
            return floating
        }
        return nil
    }

    /// ⌘F：显示书架（若隐藏）并聚焦搜索框。
    func focusBookshelfSearch() {
        let id = DockPanels.bookshelf
        if case .floating = dock.coordinator.current.placement(of: id) {
            if !dock.coordinator.current.isPanelVisible(id) {
                dock.coordinator.perform(in: nil) { $0.togglingPanel(id, defaultEdge: .left) }
            }
            if let floating = dock.coordinator.floatingWindows[id], let shelf = floating.panel as? BookshelfPanel {
                floating.makeKeyAndOrderFront(nil)
                shelf.focusSearch()
            }
        } else {
            dock.perform { layout in
                var next = layout
                if !next.isPanelVisible(id) {
                    next = next.togglingPanel(id, defaultEdge: .left)
                }
                return next.selecting(id)
            }
            if let shelf = dock.panels[id] as? BookshelfPanel {
                window?.makeKeyAndOrderFront(nil)
                shelf.focusSearch()
            }
        }
    }

    /// “为此文件夹建立索引”的作用目标：书架选中的单个文件夹，或书架当前文件夹，否则当前书所在文件夹。
    var folderForIndexing: Location? {
        if let folder = bookshelfPanel?.folderForIndexing {
            return folder
        }
        guard let book = session.book?.location, book.playlistID == nil else { return nil }
        return book.parent
    }

    func indexCurrentFolder() {
        guard let folder = folderForIndexing else { return }
        IndexController.shared.startIndexing(folder, services: services)
    }

    /// 在 Finder 中显示这本书。
    func revealBook() {
        guard let location = session.book?.location else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let lease = try await services.sources.provider(for: location).fileLease(for: location)
                NSWorkspace.shared.activateFileViewerSelecting([lease.url])
            } catch {
                presentOpenError(error, url: URL(fileURLWithPath: location.description))
            }
        }
    }

    func openNeighbor(_ direction: NavigationDirection) {
        restoringBook = false
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            await session.openNeighborBook(direction, sort: session.neighborSort)
        }
    }

    /// 重新打开这本书：书的位置不丢。
    func reopenBook() {
        restoringBook = false
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

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if window.firstResponder is NSText || window.firstResponder is NSTextField {
            return textUndoManager
        }
        return fileOps.undoManager
    }

    func windowDidBecomeMain(_ notification: Notification) {
        dock.coordinator.activate(dock)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        chrome.willEnterFullScreen()
        viewer.setFullScreen(true)
        dock.setAutoHide(true)
    }

    #if DEBUG
    func windowDidEnterFullScreen(_ notification: Notification) {
        chrome.didEnterFullScreen()
    }
    #endif

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        chrome.didFailToEnterFullScreen()
        viewer.setFullScreen(false)
        dock.setAutoHide(false)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        #if DEBUG
        chrome.willExitFullScreen()
        #endif
        dock.setAutoHide(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        chrome.didExitFullScreen()
        viewer.setFullScreen(false)
    }

    func windowDidMove(_ notification: Notification) {
        rememberFrame()
    }

    func windowDidResize(_ notification: Notification) {
        rememberFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onSessionChange?()
    }

    private func rememberFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        normalFrame = window.frame
        onSessionChange?()
    }

    func windowWillClose(_ notification: Notification) {
        dock.coordinator.detach(dock)
        openTask?.cancel()
        healthTask?.cancel()
        libraryTask?.cancel()
        toolbarSaveTask?.cancel()
        // 页码来自书记忆，关窗前落盘。
        Task { [session] in await session.flush() }
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
    private static let toolbarEffectsToggle = NSToolbarItem.Identifier("effects.toggle")

    static func toolbarIdentifier(for id: ToolbarItemID) -> NSToolbarItem.Identifier {
        switch id {
        case .flexibleSpace: .flexibleSpace
        case .space: .space
        default: NSToolbarItem.Identifier(id.rawValue)
        }
    }

    static func toolbarItemID(for identifier: NSToolbarItem.Identifier) -> ToolbarItemID {
        switch identifier {
        case .flexibleSpace: .flexibleSpace
        case .space: .space
        default: ToolbarItemID(identifier.rawValue)
        }
    }

    static func toolbarItemIDs(of toolbar: NSToolbar) -> [ToolbarItemID] {
        toolbar.items.map { toolbarItemID(for: $0.itemIdentifier) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        CoreCommands.defaultToolbar.map(Self.toolbarIdentifier(for:))
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var seen: Set<NSToolbarItem.Identifier> = []
        var result: [NSToolbarItem.Identifier] = []
        func append(_ identifier: NSToolbarItem.Identifier) {
            if seen.insert(identifier).inserted {
                result.append(identifier)
            }
        }
        for id in CoreCommands.defaultToolbar where id != .space && id != .flexibleSpace {
            append(Self.toolbarIdentifier(for: id))
        }
        for descriptor in catalog.symbolCommands {
            append(NSToolbarItem.Identifier(descriptor.id.rawValue))
        }
        append(.space)
        append(.flexibleSpace)
        return result
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.toolbarTitle {
            return flag ? makeTitleItem() : paletteItem(identifier, label: String(localized: "书名"), symbol: "text.alignleft")
        }
        if identifier == Self.toolbarBrowse {
            let label = String(localized: "浏览方式")
            return flag ? viewItem(identifier, browseControl, label: label) : paletteItem(identifier, label: label, symbol: "square.grid.2x2")
        }
        if identifier == Self.toolbarWaterfall {
            let label = String(localized: "瀑布流选项")
            guard flag else { return paletteItem(identifier, label: label, symbol: "arrow.up.arrow.down") }
            let stack = NSStackView(views: [sortButton, sizeSlider])
            stack.spacing = 8
            return viewItem(identifier, stack, label: label)
        }
        if identifier == Self.toolbarOptions {
            let label = String(localized: "显示")
            return flag ? viewItem(identifier, optionsButton, label: label) : paletteItem(identifier, label: label, symbol: "slider.horizontal.3")
        }
        if identifier == Self.toolbarFullScreen {
            let label = catalog.title(of: .fullScreenToggle)
            return flag ? viewItem(identifier, fullScreenButton, label: label) : paletteItem(identifier, label: label, symbol: "arrow.up.left.and.arrow.down.right")
        }
        if identifier == Self.toolbarEffectsToggle {
            let label = catalog.title(of: .effectsToggle)
            return flag ? viewItem(identifier, effectsToggleButton, label: label) : paletteItem(identifier, label: label, symbol: "circle.lefthalf.filled")
        }
        if let entry = Self.dockToggleItems[identifier] {
            return flag ? makeDockToggleItem(identifier, entry) : paletteItem(identifier, label: catalog.title(of: entry.command), symbol: entry.symbol)
        }
        if let entry = Self.toolbarCommands[identifier] {
            let title = catalog.title(of: entry.command)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: title)
            item.label = title
            item.paletteLabel = title
            item.toolTip = title
            item.isBordered = true
            item.isNavigational = true
            item.target = self
            item.action = #selector(toolbarCommand(_:))
            return item
        }
        let commandID = CommandID(identifier.rawValue)
        guard let descriptor = catalog.descriptor(commandID), let symbol = descriptor.symbol, !symbol.isEmpty else {
            return nil
        }
        let title = catalog.title(of: commandID)
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.isBordered = true
        item.target = self
        item.action = #selector(toolbarCommand(_:))
        return item
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard !isRebuildingToolbar else { return }
        scheduleToolbarSave()
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard !isRebuildingToolbar else { return }
        scheduleToolbarSave()
    }

    private func scheduleToolbarSave() {
        toolbarSaveTask?.cancel()
        toolbarSaveTask = Task { @MainActor [weak self] in
            // 等到当前事件循环结束后再读 toolbar.items，确保新增项已落位并合并同一次拖拽的删+增。
            await Task.yield()
            guard !Task.isCancelled, let self, let toolbar = window?.toolbar, let menus = services.menus else { return }
            let items = Self.toolbarItemIDs(of: toolbar)
            guard menus.value().resolvedToolbar != items else { return }
            do {
                try await menus.update { $0.toolbar = items }
            } catch {
                logger.error("无法保存工具栏配置到 menus.json：\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func syncToolbarItems(to desired: [ToolbarItemID]) {
        guard let toolbar = window?.toolbar else { return }
        guard Self.toolbarItemIDs(of: toolbar) != desired else { return }
        toolbarSaveTask?.cancel()
        toolbarSaveTask = nil
        isRebuildingToolbar = true
        defer { isRebuildingToolbar = false }
        for index in stride(from: toolbar.items.count - 1, through: 0, by: -1) {
            toolbar.removeItem(at: index)
        }
        for (index, id) in desired.enumerated() {
            toolbar.insertItem(withItemIdentifier: Self.toolbarIdentifier(for: id), at: index)
        }
        updateBrowseControls()
        updateDockToggles()
        toolbar.validateVisibleItems()
    }

    private func paletteItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.isBordered = true
        item.autovalidates = false
        return item
    }

    private func viewItem(_ identifier: NSToolbarItem.Identifier, _ view: NSView, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
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
        menu.addItem(NSMenuItem())
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

    @objc private func effectsToggleClicked(_ sender: NSButton) {
        run(.effectsToggle)
        effectsToggleButton.state = effectsEnabled ? .on : .off
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
        let title = catalog.title(of: entry.command)
        item.label = title
        item.paletteLabel = title
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
        playlistMark.isHidden = true
        let titleRow = NSStackView(views: [playlistMark, bookTitle])
        titleRow.spacing = 6
        let stack = NSStackView(views: [titleRow, bookPath])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        // 路径可能很长，不能把后面的工具项挤进溢出菜单。
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let item = NSToolbarItem(itemIdentifier: Self.toolbarTitle)
        item.label = String(localized: "书名")
        item.paletteLabel = item.label
        item.view = stack
        item.isBordered = false
        item.autovalidates = false
        item.visibilityPriority = .high
        return item
    }

    @objc private func toolbarCommand(_ sender: NSToolbarItem) {
        if let entry = Self.toolbarCommands[sender.itemIdentifier] {
            run(entry.command)
            return
        }
        let commandID = CommandID(sender.itemIdentifier.rawValue)
        guard catalog.descriptor(commandID) != nil else { return }
        run(commandID)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let commandID = Self.toolbarCommands[item.itemIdentifier]?.command ?? CommandID(item.itemIdentifier.rawValue)
        guard catalog.descriptor(commandID) != nil else { return false }
        return dispatcher.isEnabled(commandID, in: self, scope: InputRouter.scope(of: window?.firstResponder))
    }
}
