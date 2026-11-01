import AppKit
import MVFoundation

/// 占位面板：验证停靠框架用，S2-F2 换成正式的书架与页面列表。
///
/// 视图设置只有一项“样式”（列表或网格），用来验证设置的编解码；内容是骨架行或骨架格，
/// 顶部标出面板当前作用的窗口，用来验证浮动面板跟随活动窗口。
@MainActor
final class PlaceholderPanel: DockPanel {
    struct Settings: Codable, Equatable {
        enum Style: String, Codable { case list, grid }
        var style: Style = .list
    }

    private(set) var settings: Settings
    var onSettingsChange: (() -> Void)?
    /// 当前作用的窗口的会话。
    private(set) var boundSession: SessionID?
    private let content = PlaceholderPanelView()
    private var titleObservation: NSKeyValueObservation?

    var view: NSView { content }

    init(settings: Settings?) {
        self.settings = settings ?? Settings()
        content.styleControl.target = self
        content.styleControl.action = #selector(styleChanged(_:))
        content.render(self.settings.style)
    }

    func bind(to window: ReaderWindowController?) {
        boundSession = window?.session.id
        titleObservation = nil
        guard let nsWindow = window?.window else {
            content.target.stringValue = String(localized: "没有活动窗口")
            return
        }
        // 窗口标题随打开的书变化。
        titleObservation = nsWindow.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.content.target.stringValue = String(localized: "作用于：\(window.title)")
            }
        }
    }

    /// 自检与样式控件共用。
    func setStyle(_ style: Settings.Style) {
        guard style != settings.style else { return }
        settings.style = style
        content.render(style)
        onSettingsChange?()
    }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        setStyle(sender.selectedSegment == 1 ? .grid : .list)
    }
}

@MainActor
private final class PlaceholderPanelView: NSView {
    let styleControl = NSSegmentedControl(
        labels: [String(localized: "列表"), String(localized: "网格")], trackingMode: .selectOne, target: nil, action: nil
    )
    let target = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: String(localized: "占位面板，S2-F2 接入正式内容"))
    private var skeleton: [CALayer] = []
    private var style: PlaceholderPanel.Settings.Style = .list

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        styleControl.controlSize = .small
        styleControl.segmentStyle = .rounded
        for label in [target, note] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.text2
            label.lineBreakMode = .byTruncatingTail
        }
        for view in [styleControl, target, note] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func render(_ style: PlaceholderPanel.Settings.Style) {
        self.style = style
        styleControl.selectedSegment = style == .grid ? 1 : 0
        needsLayout = true
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        for (index, item) in skeleton.enumerated() {
            item.backgroundColor = (index == 0 ? Theme.selected : Theme.well).cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let width = bounds.width - inset * 2
        styleControl.sizeToFit()
        styleControl.frame.origin = CGPoint(x: inset, y: inset)
        var y = styleControl.frame.maxY + 6
        for label in [target, note] {
            label.frame = CGRect(x: inset, y: y, width: max(width, 0), height: 16)
            y += 18
        }
        y += 4
        // 骨架：列表是 26 pt 高的行，网格是 2:3 的格子，填满可见高度。
        var frames: [CGRect] = []
        switch style {
        case .list:
            while y + 26 <= bounds.height - inset, frames.count < 40 {
                frames.append(CGRect(x: inset, y: y, width: width, height: 26))
                y += 32
            }
        case .grid:
            let columns = max(1, Int((width + 6) / 70))
            let side = (width - CGFloat(columns - 1) * 6) / CGFloat(columns)
            var index = 0
            while y + side * 1.5 <= bounds.height - inset, frames.count < 60 {
                frames.append(CGRect(x: inset + CGFloat(index % columns) * (side + 6), y: y, width: side, height: side * 1.5))
                index += 1
                if index % columns == 0 { y += side * 1.5 + 6 }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while skeleton.count < frames.count {
            let item = CALayer()
            item.cornerRadius = 6
            layer?.addSublayer(item)
            skeleton.append(item)
        }
        while skeleton.count > frames.count {
            skeleton.removeLast().removeFromSuperlayer()
        }
        for (item, frame) in zip(skeleton, frames) {
            item.frame = frame
            item.cornerRadius = style == .grid ? 4 : 6
        }
        CATransaction.commit()
        needsDisplay = true
    }
}
