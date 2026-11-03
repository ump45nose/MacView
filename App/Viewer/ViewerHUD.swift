import AppKit
import MVFoundation
import MVMedia
import MVPipeline
import MVReading
import MVSettings

/// 分页模式底部的 HUD：相邻页帧的缩略图、页码滑块、当前比例和缩放按钮。鼠标靠近窗口底部时出现。
@MainActor
final class ViewerHUD: NSView {
    static let revealDistance = 180.0
    private static let cellCount = 9
    private let session: ReaderSession
    private let pipeline: any ImagePipeline
    private let strip = NSStackView()
    private var cells: [FrameCell] = []
    private let slider = NSSlider()
    private let position = NSTextField(labelWithString: "")
    private let total = NSTextField(labelWithString: "")
    private let scaleLabel = NSTextField(labelWithString: "")
    private var thumbnails: [ContentIdentity: Any] = [:]
    private var renderedKey: [[PageFrameElement]] = []
    private var bookLocation: Location?
    var onZoom: ((Double) -> Void)?

    init(session: ReaderSession, pipeline: any ImagePipeline) {
        self.session = session
        self.pipeline = pipeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        strip.spacing = 6
        strip.distribution = .gravityAreas
        slider.minValue = 0
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid)
        slider.trackFillColor = Theme.accent
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        position.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        position.textColor = Theme.text
        total.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        total.textColor = Theme.text2
        scaleLabel.font = .systemFont(ofSize: 12)
        scaleLabel.textColor = Theme.text
        scaleLabel.alignment = .center
        scaleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let row = NSStackView(views: [slider, position, total, line, zoomButton("minus", String(localized: "缩小"), #selector(zoomOut)), scaleLabel, zoomButton("plus", String(localized: "放大"), #selector(zoomIn))])
        row.spacing = 2
        row.setCustomSpacing(14, after: slider)
        row.setCustomSpacing(14, after: total)
        row.setCustomSpacing(14, after: line)
        let stack = NSStackView(views: [strip, row])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func zoomButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = Theme.text
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
    }

    /// HUD 上的点击不传给查看器。
    override func mouseDown(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) { superview?.mouseMoved(with: event) }

    private var isRightToLeft: Bool { session.settings.direction == .rightToLeft }

    /// 当前页帧在中间，前后各四个；右开时阅读顺序从右往左。
    func refresh() {
        let frames = session.frames
        guard session.settings.browseMode == .paged, frames.indices.contains(session.currentFrame), let pages = session.book?.pages else { return }
        if bookLocation != session.book?.location {
            bookLocation = session.book?.location
            thumbnails = [:]
        }
        let low = max(0, min(session.currentFrame - Self.cellCount / 2, frames.count - Self.cellCount))
        let high = min(frames.count, low + Self.cellCount)
        var shown = Array(low..<high)
        if isRightToLeft { shown.reverse() }
        while cells.count < shown.count {
            let cell = FrameCell(pipeline: pipeline)
            cell.onClick = { [weak self] page in self?.session.go(.index(page)) }
            cell.onThumbnail = { [weak self] identity, contents in self?.thumbnails[identity] = contents }
            cells.append(cell)
            strip.addArrangedSubview(cell)
        }
        for (index, cell) in cells.enumerated() {
            guard shown.indices.contains(index) else {
                cell.isHidden = true
                cell.clear()
                continue
            }
            let frame = frames[shown[index]]
            cell.isHidden = false
            cell.show(frame: frame, pages: pages, isCurrent: shown[index] == session.currentFrame, cached: thumbnails)
        }
        if thumbnails.count > 64 { thumbnails = [:] }
        let current = frames[session.currentFrame].elements.map(\.page)
        let first = current.min() ?? 0
        let last = current.max() ?? 0
        position.stringValue = first == last ? "\(first + 1)" : "\(first + 1)–\(last + 1)"
        total.stringValue = "/ \(pages.count)"
        slider.maxValue = Double(max(pages.count - 1, 1))
        slider.isEnabled = pages.count > 1
        if NSEvent.pressedMouseButtons == 0 || !isInLiveMove {
            slider.doubleValue = isRightToLeft ? slider.maxValue - Double(first) : Double(first)
        }
    }

    private var isInLiveMove: Bool { slider.cell?.isHighlighted == true }

    func updateZoom(percent: Int?) {
        let mode = Self.title(of: session.settings.scaleMode)
        scaleLabel.stringValue = percent.map { "\(mode) · \($0)%" } ?? mode
    }

    func cancel() {
        cells.forEach { $0.clear() }
    }

    static func title(of mode: ScaleMode) -> String {
        switch mode {
        case .original: String(localized: "原始尺寸")
        case .fitWindow: String(localized: "适合窗口")
        case .fitWidth: String(localized: "适合宽度")
        case .fitHeight: String(localized: "适合高度")
        case .fill: String(localized: "填满裁切")
        case .fixed: String(localized: "固定比例")
        case .devicePixel: String(localized: "设备像素 1:1")
        }
    }

    @objc private func slid() {
        let value = Int(slider.doubleValue.rounded())
        session.go(.index(isRightToLeft ? Int(slider.maxValue) - value : value))
    }

    @objc private func zoomIn() { onZoom?(1.25) }
    @objc private func zoomOut() { onZoom?(0.8) }
}

/// HUD 里的一个页帧：48 点高的缩略图和页码，当前页帧有陶土色的环。
@MainActor
private final class FrameCell: NSView {
    private let pipeline: any ImagePipeline
    private let thumbs = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var layers: [CALayer] = []
    private var tasks: [Task<Void, Never>] = []
    private var shown: PageFrame?
    private var targetPage = 0
    private var widths: [CGFloat] = []
    private var isCurrent = false
    var onClick: ((Int) -> Void)?
    var onThumbnail: ((ContentIdentity, Any) -> Void)?
    private var width: NSLayoutConstraint!

    init(pipeline: any ImagePipeline) {
        self.pipeline = pipeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.addSublayer(thumbs)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .center
        label.frame = .zero
        addSubview(label)
        width = widthAnchor.constraint(equalToConstant: 42)
        width.isActive = true
        heightAnchor.constraint(equalToConstant: 72).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isCurrent ? Theme.accentSoft : .clear).cgColor
        thumbs.borderColor = Theme.accent.cgColor
        for item in layers where item.contents == nil { item.backgroundColor = Theme.well.cgColor }
    }

    func show(frame: PageFrame, pages: [Page], isCurrent: Bool, cached: [ContentIdentity: Any]) {
        targetPage = frame.elements.map(\.page).min() ?? 0
        if self.isCurrent != isCurrent {
            self.isCurrent = isCurrent
            needsDisplay = true
            label.font = .monospacedSystemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular)
        }
        label.textColor = isCurrent ? Theme.text : Theme.text2
        thumbs.borderWidth = isCurrent ? 2 : 0
        let numbers = frame.elements.map(\.page).sorted()
        let text = numbers.first == numbers.last ? "\((numbers.first ?? 0) + 1)" : "\((numbers.first ?? 0) + 1)–\((numbers.last ?? 0) + 1)"
        label.stringValue = text
        guard frame != shown else { return }
        clear()
        shown = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x: CGFloat = 0
        for element in frame.elements where pages.indices.contains(element.page) {
            let page = pages[element.page]
            var aspect = page.metadata.map { Double($0.pixelSize.width) / Double(max($0.pixelSize.height, 1)) } ?? 2.0 / 3.0
            if element.part != .whole { aspect /= 2 }
            let side = (48 * aspect).rounded()
            let item = CALayer()
            item.frame = CGRect(x: x, y: 0, width: side, height: 48)
            item.contentsGravity = .resizeAspectFill
            item.masksToBounds = true
            item.backgroundColor = Theme.well.cgColor
            switch element.part {
            case .whole: break
            case .leftHalf: item.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
            case .rightHalf: item.contentsRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            }
            thumbs.addSublayer(item)
            layers.append(item)
            x += side + 1
            let identity = page.entry.identity
            if let contents = cached[identity] {
                item.contents = contents
            } else {
                let pipeline = pipeline
                tasks.append(Task { [weak self, weak item] in
                    guard let image = try? await pipeline.thumbnail(for: identity, maxPixel: 128, priority: .near), !Task.isCancelled else { return }
                    let contents: Any = image.surface ?? image.image
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    item?.contents = contents
                    CATransaction.commit()
                    self?.onThumbnail?(identity, contents)
                })
            }
        }
        let thumbWidth = max(x - 1, 10)
        thumbs.frame = CGRect(x: 5, y: 5, width: thumbWidth, height: 48)
        CATransaction.commit()
        width.constant = max(thumbWidth + 10, 42)
        label.frame = CGRect(x: 0, y: 56, width: width.constant, height: 14)
    }

    func clear() {
        tasks.forEach { $0.cancel() }
        tasks = []
        layers.forEach { $0.removeFromSuperlayer() }
        layers = []
        shown = nil
    }

    override func mouseUp(with event: NSEvent) {
        onClick?(targetPage)
    }

    override func mouseDown(with event: NSEvent) {}
}
