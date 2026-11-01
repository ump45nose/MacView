import AppKit

/// 阅读窗口的内容视图：上方是主视图，下方是状态栏，底部居中浮着多键序列的待定提示。整个窗口都是拖放目标。
///
/// 主视图可以替换：停靠框架（S1-F2）把它换成包含停靠区的容器，正式查看器（S2-F1）替换最简页面视图。
@MainActor
final class ReaderContentView: NSView {
    let statusBar: StatusBarView
    let pendingView = PendingSequenceView()
    /// 拖入了文件 URL。
    var onDrop: (([URL]) -> Void)?
    private var mainConstraints: [NSLayoutConstraint] = []
    private var isDropTarget = false {
        didSet { updateDropBorder() }
    }

    var mainView: NSView {
        didSet {
            oldValue.removeFromSuperview()
            install(mainView)
        }
    }

    init(mainView: NSView, statusBar: StatusBarView) {
        self.mainView = mainView
        self.statusBar = statusBar
        super.init(frame: .zero)
        wantsLayer = true
        for view in [statusBar, pendingView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            pendingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pendingView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -12),
        ])
        install(mainView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func install(_ view: NSView) {
        NSLayoutConstraint.deactivate(mainConstraints)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: statusBar)
        mainConstraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ]
        NSLayoutConstraint.activate(mainConstraints)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDropBorder()
    }

    private func updateDropBorder() {
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
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
