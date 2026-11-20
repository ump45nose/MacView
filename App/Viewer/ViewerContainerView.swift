import AppKit
import MVCommands
import MVFoundation
import MVIO
import MVLibraryData
import MVPipeline
import MVReading
import MVSettings

/// 主区的查看器：按浏览方式切换分页和连续视图，回报视口，显示没有书、读取中和打开失败的提示。
@MainActor
final class ViewerContainerView: NSView, InputScoped {
    private let session: ReaderSession
    let paged: PagedViewerView
    let continuous: ContinuousViewer
    let hud: ViewerHUD
    private let message = ViewerMessageView()
    /// 虚拟书顶部的来源胶囊：“来自 《书名》 · 文件名”。
    private let sourcePill = SourcePillView()
    /// 评分、标签写入状态或不可评分原因的底部浮层提示。
    private let metadataToast = MetadataToastView()
    private var metadataToastTask: Task<Void, Never>?
    private let checker: AvailabilityChecker?
    /// 虚拟书里已交给检查器的页；重查时清空。
    private var checkedPages: Set<Location> = []
    private var checkedBook: Location?
    private var checkTasks: [Int: Task<Void, Never>] = [:]
    private var checkCounter = 0
    private var activationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var viewportTimer: Timer?
    private var reportedViewport: (pixels: PixelSize, scale: Double)?
    /// 没有书的新窗口用 ground 底（设计稿“空状态 · 新窗口”），其余状态用 canvas。
    private var isEmptyState = true {
        didSet { needsDisplay = true }
    }
    /// 当前窗口是否启用实时调色；由 `ReaderWindowController` 驱动。
    private(set) var effectsEnabled = true
    private var appliedEffects: EffectChain = .empty
    private var appliedBackground: ViewerBackground = .auto

    var inputScope: InputScope { .viewer }

    /// 提示里的主按钮：打开，或重试这本书。
    var onOpen: (() -> Void)?
    var onRetryBook: (() -> Void)?
    /// 连接书所在的卷。
    var onConnect: (() -> Void)?
    /// 右键菜单：参数是光标下的页（分页模式点在页外时是当前页）。
    var onContextMenu: ((Entry) -> NSMenu?)?

    init(session: ReaderSession, services: ViewerServices) {
        self.session = session
        checker = services.availability
        paged = PagedViewerView(session: session, pipeline: services.pipeline, sources: services.sources)
        continuous = ContinuousViewer(session: session, pipeline: services.pipeline, settings: services.settings, bookshelf: services.bookshelf)
        hud = ViewerHUD(session: session, pipeline: services.pipeline)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [paged, continuous] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        continuous.isHidden = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isHidden = true
        addSubview(hud)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        sourcePill.translatesAutoresizingMaskIntoConstraints = false
        sourcePill.isHidden = true
        addSubview(sourcePill)
        metadataToast.translatesAutoresizingMaskIntoConstraints = false
        metadataToast.isHidden = true
        addSubview(metadataToast)
        let hudWidth = hud.widthAnchor.constraint(equalToConstant: 880)
        hudWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            hud.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            hudWidth,
            sourcePill.centerXAnchor.constraint(equalTo: centerXAnchor),
            sourcePill.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            sourcePill.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            metadataToast.centerXAnchor.constraint(equalTo: centerXAnchor),
            metadataToast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
        message.onAction = { [weak self] in self?.messageAction() }
        message.onSecondary = { [weak self] in self?.onConnect?() }
        paged.onTransformChange = { [weak self] in self?.hud.updateZoom(percent: self?.paged.displayPercent) }
        hud.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        continuous.onEnterPaged = { [weak self] page in self?.enterPaged(at: page) }
        continuous.unavailableReason = { [weak self] location in
            if case let .volumeUnavailable(root) = self?.paged.availability[location] { return .volume(root) }
            if self?.session.unavailablePages.contains(location) == true { return .missing }
            return .failed(String(localized: "无法读取原文件"))
        }
        continuous.onPageFailure = { [weak self] location in self?.recheckAvailability { $0 == location } }
        continuous.onRemoveUnavailable = { [weak self] location in
            guard let id = self?.session.book?.location.playlistID, let app = NSApp.delegate as? AppDelegate else { return }
            Task { await LibraryActions.removeFromPlaylist([location], playlist: id, app: app) }
        }
        continuous.canvas.onContextMenu = { [weak self] index in
            guard let self, let index, let pages = session.book?.pages, pages.indices.contains(index) else { return nil }
            return onContextMenu?(pages[index].entry)
        }
        paged.onPageFailure = { [weak self] location in self?.recheckAvailability { $0 == location } }
        // 外部变化没有通知：App 重新激活、卷挂载或卸载时重查。
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckAvailability() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        activationTokens = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: recheck)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main, using: recheck)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main, using: recheck)),
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Self.backgroundColor(
            for: appliedBackground,
            isEmptyState: isEmptyState,
            appearance: effectiveAppearance
        )
    }

    private static let lightCheckerboard = makeCheckerboardColor(
        first: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        second: NSColor(srgbRed: 0xCF / 255, green: 0xCD / 255, blue: 0xC4 / 255, alpha: 1)
    )
    private static let darkCheckerboard = makeCheckerboardColor(
        first: NSColor(srgbRed: 0x2B / 255, green: 0x2A / 255, blue: 0x28 / 255, alpha: 1),
        second: NSColor(srgbRed: 0x1E / 255, green: 0x1D / 255, blue: 0x1C / 255, alpha: 1)
    )

    private static func makeCheckerboardColor(first: NSColor, second: NSColor) -> CGColor {
        let tile = 8.0
        let image = NSImage(size: NSSize(width: tile * 2, height: tile * 2), flipped: false) { _ in
            first.setFill()
            NSRect(x: 0, y: 0, width: tile * 2, height: tile * 2).fill()
            second.setFill()
            NSRect(x: 0, y: 0, width: tile, height: tile).fill()
            NSRect(x: tile, y: tile, width: tile, height: tile).fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
    }

    private static func backgroundColor(for background: ViewerBackground, isEmptyState: Bool, appearance: NSAppearance) -> CGColor {
        switch background {
        case .auto:
            return (isEmptyState ? Theme.ground : Theme.canvas).cgColor
        case .black:
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).cgColor
        case .gray:
            return NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor
        case .white:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor
        case .checkerboard:
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? darkCheckerboard : lightCheckerboard
        case let .custom(red, green, blue):
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// 分页模式取光标下的页，点在页外时取当前页。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pages = session.book?.pages else { return nil }
        let index = paged.page(at: paged.convert(event.locationInWindow, from: nil)) ?? session.currentPage
        guard pages.indices.contains(index) else { return nil }
        return onContextMenu?(pages[index].entry)
    }

    /// 会话状态变化后调用。
    func refresh() {
        updateMessage()
        updateSourcePill()
        checkAvailability()
        applyEffectsIfNeeded()
        if appliedBackground != session.settings.background {
            appliedBackground = session.settings.background
            needsDisplay = true
        }
        if session.settings.browseMode == .paged {
            continuous.isHidden = true
            continuous.leave()
            paged.isHidden = false
            paged.refresh()
            if window?.firstResponder is NSClipView || window?.firstResponder === continuous.canvas.documentView { window?.makeFirstResponder(self) }
        } else {
            paged.isHidden = true
            paged.clear()
            hud.isHidden = true
            continuous.isHidden = false
            continuous.refresh()
        }
        hud.refresh()
        hud.updateZoom(percent: paged.displayPercent)
    }

    func setEffectsEnabled(_ enabled: Bool) {
        guard effectsEnabled != enabled else { return }
        effectsEnabled = enabled
        applyEffectsIfNeeded()
    }

    var effectFilterCount: Int {
        session.settings.browseMode == .paged ? paged.effectFilterCount : continuous.canvas.effectFilterCount
    }

    private func applyEffectsIfNeeded() {
        let chain = effectsEnabled ? session.settings.effects : .empty
        guard chain != appliedEffects else { return }
        appliedEffects = chain
        paged.setEffects(chain)
        continuous.setEffects(chain)
    }

    /// 窗口关闭时取消全部请求。
    func cancelLoads() {
        checkTasks.values.forEach { $0.cancel() }
        checkTasks = [:]
        for (center, token) in activationTokens { center.removeObserver(token) }
        activationTokens = []
        viewportTimer?.invalidate()
        metadataToastTask?.cancel()
        paged.cancelLoads()
        continuous.leave()
        hud.cancel()
    }

    func enterPaged(at page: Int) {
        session.update { $0.browseMode = .paged }
        session.go(.index(page))
        window?.makeFirstResponder(self)
    }

    /// `zoom.in`、`zoom.out` 和 HUD 的按钮：分页以光标为中心，连续和瀑布改项的尺寸。
    func zoom(by factor: Double) {
        if session.settings.browseMode == .paged {
            paged.zoom(by: factor)
        } else {
            continuous.canvas.zoom(by: factor)
        }
    }

    /// `item.retryFailed`：书打开失败时重开，否则重试失败的项。
    func retryFailed() {
        if session.loadError != nil {
            onRetryBook?()
        } else if session.settings.browseMode == .paged {
            paged.retryFailed()
        } else {
            continuous.canvas.retryFailed()
        }
    }

    /// 显示评分/标签写入状态或不可写原因的短提示；`autoHideAfter` 为 nil 时持续显示直到下次更新或隐藏。
    func showMetadataToast(stars: Int? = nil, text: String, isSpinning: Bool = false, autoHideAfter: Duration? = .seconds(2)) {
        metadataToastTask?.cancel()
        metadataToast.show(stars: stars, text: text, isSpinning: isSpinning)
        metadataToast.alphaValue = 1
        metadataToast.isHidden = false
        guard let autoHideAfter else { return }
        metadataToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: autoHideAfter)
            guard let self, !Task.isCancelled else { return }
            self.hideMetadataToast()
        }
    }

    func hideMetadataToast() {
        metadataToastTask?.cancel()
        metadataToastTask = nil
        metadataToast.stopSpinner()
        metadataToast.isHidden = true
    }

    // MARK: 虚拟书

    /// 来源胶囊：当前页所在的书和文件名。
    private func updateSourcePill() {
        guard session.isVirtualBook, let pages = session.book?.pages, pages.indices.contains(session.currentPage) else {
            sourcePill.isHidden = true
            return
        }
        let page = pages[session.currentPage].id
        sourcePill.show(book: LibraryActions.containingBook(of: page)?.name ?? "", file: page.name)
        sourcePill.isHidden = false
    }

    /// 虚拟书：把当前页帧和前后页帧里还没查过的页交给检查器，结果经会话交回，同时留给占位页显示原因。
    private func checkAvailability() {
        guard let checker, session.isVirtualBook, let book = session.book, window != nil else { return }
        if checkedBook != book.location {
            checkedBook = book.location
            checkedPages = []
            paged.availability = [:]
        }
        let frames = session.frames
        let indices: [Int] = if frames.indices.contains(session.currentFrame) {
            (max(session.currentFrame - 1, 0)...min(session.currentFrame + 1, frames.count - 1)).flatMap { frames[$0].elements.map(\.page) }
        } else {
            Array(session.currentPage - 1...session.currentPage + 1)
        }
        var pending: [Location] = []
        for index in indices where book.pages.indices.contains(index) {
            let location = book.pages[index].id
            if checkedPages.insert(location).inserted { pending.append(location) }
        }
        guard !pending.isEmpty else { return }
        let stream = checker.check(pending)
        checkCounter += 1
        let token = checkCounter
        checkTasks[token] = Task { [weak self] in
            for await results in stream {
                guard let self, !Task.isCancelled, checkedBook == book.location else { return }
                session.setAvailability(results)
                paged.availability.merge(results) { _, new in new }
            }
            self?.checkTasks[token] = nil
        }
    }

    /// 重查满足条件的页（默认全部）：App 重新激活、卷状态变化、取图失败时调用。旧结果保留到新结果到达。
    func recheckAvailability(where affected: (Location) -> Bool = { _ in true }) {
        guard session.isVirtualBook else { return }
        checkedPages = checkedPages.filter { !affected($0) }
        checkAvailability()
    }

    // MARK: 视口

    private var backing: Double { Double((window ?? NSApp.mainWindow)?.backingScaleFactor ?? 2) }

    override func layout() {
        super.layout()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
        paged.needsLayout = true
    }

    /// 第一次立即回报，之后停下 150 ms 才回报：拖动窗口尺寸时不反复换预解码计划。
    private func reportViewport() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let scale = backing
        let pixels = PixelSize(width: Int((bounds.width * scale).rounded()), height: Int((bounds.height * scale).rounded()))
        if let reported = reportedViewport, reported.pixels == pixels, reported.scale == scale { return }
        let first = reportedViewport == nil
        reportedViewport = (pixels, scale)
        viewportTimer?.invalidate()
        if first {
            session.viewportChanged(pixels, backingScale: scale)
            return
        }
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.viewportChanged(pixels, backingScale: scale) }
        }
        RunLoop.main.add(timer, forMode: .common)
        viewportTimer = timer
    }

    // MARK: 输入

    override func mouseMoved(with event: NSEvent) {
        guard session.settings.browseMode == .paged, session.book != nil, !session.frames.isEmpty else { return }
        hud.isHidden = bounds.maxY - convert(event.locationInWindow, from: nil).y > ViewerHUD.revealDistance
    }

    override func mouseExited(with event: NSEvent) {
        hud.isHidden = true
    }

    // MARK: 提示

    private func messageAction() {
        session.loadError != nil && session.book != nil ? onRetryBook?() : onOpen?()
    }

    static func isVolumeError(_ error: any Error) -> Bool {
        switch error as? IOError {
        case .volumeUnavailable, .volumeDegraded: true
        default: false
        }
    }

    private func updateMessage() {
        isEmptyState = session.book == nil && session.loadError == nil
        if let error = session.loadError {
            let hasBook = session.book != nil
            if Self.isVolumeError(error), let root = session.book?.location.root {
                message.show(
                    title: String(localized: "无法访问 \(root.displayName)"),
                    detail: String(localized: "NAS 没有响应，或者共享已断开。已缓存的缩略图仍可浏览。"),
                    action: String(localized: "重试"),
                    secondary: root.mountURL == nil ? nil : String(localized: "连接…")
                )
            } else {
                message.show(
                    title: String(localized: "无法打开这本书"), detail: ErrorText.describe(error),
                    action: hasBook ? String(localized: "重试") : String(localized: "打开…"),
                    secondary: nil
                )
            }
        } else if let book = session.book {
            if !session.frames.isEmpty {
                message.isHidden = true
            } else if !book.isEnumerated {
                message.show(title: String(localized: "正在读取…"), detail: String(localized: "已找到 \(book.pages.count) 页"), action: nil)
            } else if book.pages.isEmpty {
                message.show(title: String(localized: "这里没有图片或视频"), detail: book.location.name, action: nil)
            } else {
                // 连续模式等第一页的尺寸时，进度由连续视图显示。
                message.isHidden = true
            }
        } else {
            message.show(title: String(localized: "打开一个文件夹或压缩包"), detail: String(localized: "也可以把它们拖到这个窗口"), action: String(localized: "打开…"))
        }
    }
}

/// 查看器用到的服务。
struct ViewerServices {
    let pipeline: any ImagePipeline
    let sources: any SourceRegistry
    let settings: any SettingsStore
    let bookshelf: any Bookshelf
    /// 虚拟书的页可用性检查；Mock 为 nil。
    var availability: AvailabilityChecker? = nil
}

/// 虚拟书顶部的来源胶囊：hud 底，书名用正文色加粗。
@MainActor
private final class SourcePillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String { label.stringValue }

    func show(book: String, file: String) {
        let font = NSFont.systemFont(ofSize: 11)
        let text = NSMutableAttributedString(string: String(localized: "来自 "), attributes: [.font: font, .foregroundColor: Theme.text2])
        text.append(NSAttributedString(string: "《\(book)》", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.text]))
        text.append(NSAttributedString(string: " · " + file, attributes: [.font: font, .foregroundColor: Theme.text2]))
        label.attributedStringValue = text
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
    }

    // 胶囊不挡点击：右键和拖动交给下面的页。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 查看器中央的提示：衬线标题、说明和可选的按钮。
@MainActor
private final class ViewerMessageView: NSStackView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let button = FlatButton(
        font: .systemFont(ofSize: 13, weight: .semibold), fill: Theme.primary, foreground: Theme.onPrimary, radius: 8, height: 30, padding: 16
    )
    private let secondary = FlatButton(
        font: .systemFont(ofSize: 13), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 8, height: 30, padding: 16
    )
    var onAction: (() -> Void)?
    var onSecondary: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 10
        title.font = Theme.serif(24)
        title.textColor = Theme.text
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.text2
        detail.alignment = .center
        detail.maximumNumberOfLines = 4
        button.target = self
        button.action = #selector(act)
        secondary.target = self
        secondary.action = #selector(actSecondary)
        buttons.spacing = 8
        buttons.setHuggingPriority(.required, for: .horizontal)
        buttons.addArrangedSubview(button)
        buttons.addArrangedSubview(secondary)
        addArrangedSubview(title)
        addArrangedSubview(detail)
        addArrangedSubview(buttons)
        setCustomSpacing(14, after: detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, detail: String, action: String?, secondary secondaryTitle: String? = nil) {
        isHidden = false
        self.title.stringValue = title
        self.detail.stringValue = detail
        buttons.isHidden = action == nil
        button.setText(action ?? "")
        secondary.isHidden = secondaryTitle == nil
        secondary.setText(secondaryTitle ?? "")
    }

    @objc private func act() {
        onAction?()
    }

    @objc private func actSecondary() {
        onSecondary?()
    }
}

/// 查看器底部的评分与元数据状态提示胶囊。
@MainActor
private final class MetadataToastView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isHidden = true
        label.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 19 / 255, alpha: 0.86).cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(stars: Int?, text: String, isSpinning: Bool) {
        spinner.isHidden = !isSpinning
        if isSpinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let out = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12)
        if let stars {
            let filled = min(max(stars, 0), 5)
            if filled > 0 {
                out.append(NSAttributedString(string: String(repeating: "★", count: filled), attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0xE3 / 255, green: 0x9A / 255, blue: 0x77 / 255, alpha: 1)]))
            }
            if filled < 5 {
                out.append(NSAttributedString(string: String(repeating: "☆", count: 5 - filled), attributes: [.font: font, .foregroundColor: NSColor(white: 0.72, alpha: 1)]))
            }
            out.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0xF5 / 255, green: 0xF4 / 255, blue: 0xEE / 255, alpha: 1)]))
        label.attributedStringValue = out
    }

    func stopSpinner() {
        spinner.stopAnimation(nil)
    }
}
