import AppKit

/// 阅读窗口的内容视图：上方是主视图（停靠容器），下方是状态栏，底部居中浮着多键序列的待定提示。整个窗口都是拖放目标。
@MainActor
final class ReaderContentView: NSView {
    let statusBar: StatusBarView
    let pendingView = PendingSequenceView()
    /// 拖入了文件 URL。
    var onDrop: (([URL]) -> Void)?
    private var isDropTarget = false {
        didSet { updateDropBorder() }
    }

    init(mainView: NSView, statusBar: StatusBarView) {
        self.statusBar = statusBar
        super.init(frame: .zero)
        wantsLayer = true
        for view in [mainView, statusBar, pendingView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            mainView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainView.topAnchor.constraint(equalTo: topAnchor),
            mainView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            pendingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            pendingView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -12),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
