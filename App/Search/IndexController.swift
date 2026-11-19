import AppKit
import MVFoundation
import MVSearch
import MVServices

/// 建立索引的界面状态快照。
struct IndexBannerState: Equatable {
    var folder: Location
    var progress: IndexProgress
    var errorMessage: String?
}

/// “为此文件夹建立索引”控制器：全应用同一时间仅运行一个索引任务，支持取消与两步进度通知。
@MainActor
final class IndexController {
    static let shared = IndexController()

    private(set) var state: IndexBannerState?
    private var indexTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var observers: [UUID: (IndexBannerState?) -> Void] = [:]

    var isIndexing: Bool { state.map { $0.progress.phase != .finished && $0.errorMessage == nil } ?? false }

    private init() {}

    @discardableResult
    func addObserver(_ observer: @escaping (IndexBannerState?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(state)
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func startIndexing(_ folder: Location, services: CoreServices) {
        guard !isIndexing, let indexer = services.indexer else { return }
        dismissTask?.cancel(); dismissTask = nil
        state = IndexBannerState(folder: folder, progress: IndexProgress(phase: .listing))
        notifyObservers()

        indexTask = Task { [weak self] in
            do {
                for try await progress in indexer.index(folder) {
                    guard !Task.isCancelled, let self else { return }
                    self.state = IndexBannerState(folder: folder, progress: progress)
                    self.notifyObservers()
                }
                guard !Task.isCancelled, let self else { return }
                self.indexTask = nil
                if var current = self.state, current.progress.phase != .finished {
                    current.progress.phase = .finished
                    self.state = current
                    self.notifyObservers()
                }
                self.dismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled, let self, self.state?.progress.phase == .finished, self.state?.errorMessage == nil else { return }
                    self.state = nil; self.notifyObservers()
                }
            } catch is CancellationError {
                guard let self else { return }
                self.indexTask = nil; self.state = nil; self.notifyObservers()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.indexTask = nil
                var next = self.state ?? IndexBannerState(folder: folder, progress: IndexProgress(phase: .listing))
                next.errorMessage = ErrorText.describe(error)
                self.state = next; self.notifyObservers()
            }
        }
    }

    func cancel() {
        indexTask?.cancel(); indexTask = nil
        dismissTask?.cancel(); dismissTask = nil
        guard state != nil else { return }
        state = nil; notifyObservers()
    }

    func dismissBanner() {
        guard !isIndexing else { return }
        dismissTask?.cancel(); dismissTask = nil
        guard state != nil else { return }
        state = nil; notifyObservers()
    }

    private func notifyObservers() {
        let snapshot = state
        observers.values.forEach { $0(snapshot) }
    }
}

/// 两步建立索引进度横幅（沿用 FileOperationBanner 边框与 FlatButton 样式）。
@MainActor
final class IndexProgressBanner: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let cancelButton = FlatButton(font: .systemFont(ofSize: 11.5), fill: Theme.raised, foreground: Theme.text, border: Theme.lineStrong, radius: 5, height: 22, padding: 9)
    let step1Detail = NSTextField(labelWithString: "")
    let step2Detail = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let step1Bar = NSProgressIndicator()
    private let step2Bar = NSProgressIndicator()
    private let bottomLine = CALayer()
    private var showsClose = false
    private var isErrorState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(bottomLine)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.setText(String(localized: "取消"))
        cancelButton.target = self; cancelButton.action = #selector(actionPressed(_:))

        for bar in [step1Bar, step2Bar] {
            bar.style = .bar; bar.controlSize = .small; bar.minValue = 0; bar.maxValue = 1
        }
        for detail in [step1Detail, step2Detail] {
            detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detail.textColor = Theme.text2; detail.alignment = .right; detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        errorLabel.font = .systemFont(ofSize: 11.5); errorLabel.textColor = Theme.danger; errorLabel.isHidden = true

        func row(_ left: NSView, _ right: NSView) -> NSStackView {
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let view = NSStackView(views: [left, spacer, right]); view.alignment = .centerY; view.spacing = 6
            return view
        }
        let s1 = NSTextField(labelWithString: String(localized: "① 文件名")); s1.font = .systemFont(ofSize: 11.5); s1.textColor = Theme.text
        let s2 = NSTextField(labelWithString: String(localized: "② 评分与标签")); s2.font = .systemFont(ofSize: 11.5); s2.textColor = Theme.text
        let rows: [NSView] = [row(titleLabel, cancelButton), row(s1, step1Detail), step1Bar, row(s2, step2Detail), step2Bar, errorLabel]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20) })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (isErrorState ? Theme.dangerSoft : Theme.raised).cgColor; bottomLine.backgroundColor = Theme.line.cgColor }
    override func layout() { super.layout(); bottomLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5) }

    func update(_ state: IndexBannerState?) {
        guard let state else { isHidden = true; step1Bar.stopAnimation(nil); return }
        isHidden = false
        let name = state.folder.name.isEmpty ? state.folder.description : state.folder.name
        let p = state.progress
        isErrorState = state.errorMessage != nil
        showsClose = isErrorState || p.phase == .finished

        if let error = state.errorMessage {
            titleLabel.stringValue = String(localized: "为“\(name)”建立索引失败")
            errorLabel.stringValue = error; errorLabel.isHidden = false
        } else if p.phase == .finished {
            titleLabel.stringValue = String(localized: "已完成“\(name)”的索引"); errorLabel.isHidden = true
        } else {
            titleLabel.stringValue = String(localized: "正在为“\(name)”建立索引"); errorLabel.isHidden = true
        }
        cancelButton.setText(showsClose ? String(localized: "关闭") : String(localized: "取消"))

        let listed = p.listed.formatted()
        switch p.phase {
        case .listing:
            step1Detail.stringValue = String(localized: "\(listed) 项")
            step1Bar.isIndeterminate = true; step1Bar.startAnimation(nil)
            step2Detail.stringValue = String(localized: "等待中")
            step2Bar.isIndeterminate = false; step2Bar.doubleValue = 0
        case .probing:
            step1Detail.stringValue = String(localized: "\(listed) 项 · 完成，已可搜索")
            step1Bar.stopAnimation(nil); step1Bar.isIndeterminate = false; step1Bar.doubleValue = 1
            step2Detail.stringValue = p.toProbe > 0 ? String(localized: "\(p.probed.formatted()) / \(p.toProbe.formatted()) 张") : String(localized: "无需更新")
            step2Bar.isIndeterminate = false; step2Bar.doubleValue = p.toProbe > 0 ? min(1, Double(p.probed) / Double(p.toProbe)) : 1
        case .finished:
            step1Detail.stringValue = String(localized: "\(listed) 项 · 完成")
            step1Bar.stopAnimation(nil); step1Bar.isIndeterminate = false; step1Bar.doubleValue = 1
            step2Detail.stringValue = p.failures > 0 ? String(localized: "\(p.probed.formatted()) 张 · \(p.failures) 项失败")
                : (p.toProbe > 0 ? String(localized: "\(p.probed.formatted()) 张 · 完成") : String(localized: "完成"))
            step2Bar.isIndeterminate = false; step2Bar.doubleValue = 1
        }
        needsDisplay = true
    }

    @objc private func actionPressed(_ sender: Any?) { if showsClose { onDismiss?() } else { onCancel?() } }
}
