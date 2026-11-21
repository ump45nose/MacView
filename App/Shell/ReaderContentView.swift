import AppKit

/// 停靠框架中间栏的主视图：查看器，底部居中浮着多键序列的待定提示。
@MainActor
final class ReaderMainView: NSView {
    let pendingView = PendingSequenceView()

    init(viewer: NSView) {
        super.init(frame: .zero)
        for view in [viewer, pendingView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewer.topAnchor.constraint(equalTo: topAnchor),
            viewer.bottomAnchor.constraint(equalTo: bottomAnchor),
            pendingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pendingView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 一个配置文件的错误。
struct FileProblem: Equatable {
    var file: String
    var title: String
    var message: String
    var url: URL
}

/// 阅读窗口的内容视图：上方是停靠容器，下方是状态栏。整个窗口都是拖放目标。
@MainActor
final class ReaderContentView: NSView {
    let statusBar: StatusBarView
    /// 拖入了文件 URL。
    var onDrop: (([URL]) -> Void)?
    private let mainView: NSView
    private let topBackdrop = NSView()
    private var topInsetConstraint: NSLayoutConstraint!
    private let banners = NSStackView()
    private let volumeBanner = VolumeStatusView()
    /// 按文件各一条。
    private(set) var fileErrorBanners: [String: FileErrorBanner] = [:]
    /// 文件操作失败时的错误条，同一窗口新失败替换旧错误条。
    private(set) var fileOperationBanner: FileOperationBanner?
    private var isDropTarget = false {
        didSet { updateDropBorder() }
    }

    init(mainView: NSView, statusBar: StatusBarView) {
        self.statusBar = statusBar
        self.mainView = mainView
        super.init(frame: .zero)
        wantsLayer = true
        topBackdrop.wantsLayer = true
        topBackdrop.layer?.backgroundColor = Theme.ground.cgColor
        banners.orientation = .vertical
        banners.alignment = .width
        banners.spacing = 0
        banners.addArrangedSubview(volumeBanner)
        for view in [topBackdrop, banners, mainView, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let emptyBanners = banners.heightAnchor.constraint(equalToConstant: 0)
        emptyBanners.priority = .init(1)
        let topInset = banners.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        topInsetConstraint = topInset
        NSLayoutConstraint.activate([
            topBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBackdrop.topAnchor.constraint(equalTo: topAnchor),
            topBackdrop.bottomAnchor.constraint(equalTo: banners.topAnchor),
            banners.leadingAnchor.constraint(equalTo: leadingAnchor),
            banners.trailingAnchor.constraint(equalTo: trailingAnchor),
            topInset,
            emptyBanners,
            mainView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainView.topAnchor.constraint(equalTo: banners.bottomAnchor),
            mainView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 为多标签时的原生标签栏在顶部留出高度，并在该区域绘制实色底。
    func setTopInset(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard topInsetConstraint.constant != clamped else { return }
        topInsetConstraint.constant = clamped
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        topBackdrop.layer?.backgroundColor = Theme.ground.cgColor
        updateDropBorder()
    }

    private func updateDropBorder() {
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = Theme.accent.cgColor
    }

    /// 卷状态条，窗口控制器按当前书所在的卷更新。
    var volumeStatus: VolumeStatusView { volumeBanner }

    /// 按文件显示配置错误；不在 `errors` 里的条目移除。
    func setFileErrors(_ errors: [FileProblem], onClose: @escaping (String) -> Void) {
        fileErrorBanners.values.forEach { $0.removeFromSuperview() }
        fileErrorBanners = [:]
        for error in errors {
            let banner = FileErrorBanner(title: error.title, detail: error.message, fileURL: error.url) {
                onClose(error.file)
            }
            banners.addArrangedSubview(banner)
            fileErrorBanners[error.file] = banner
        }
    }

    /// 显示或移除文件操作错误条；新错误条替换旧错误条。
    func setFileOperationBanner(_ banner: FileOperationBanner?) {
        fileOperationBanner?.removeFromSuperview()
        fileOperationBanner = banner
        if let banner {
            banners.addArrangedSubview(banner)
        }
    }

    // MARK: 拖放

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
