import AppKit
import MVLayout

extension NSPasteboard.PasteboardType {
    /// 拖动中的面板；内容是面板标识。拖动的来源记在 `DockCoordinator.drag` 中。
    static let dockPanel = NSPasteboard.PasteboardType("io.github.ump45nose.MacView.dock-panel")
}

/// 面板的标签：单击选中，拖动超过几个点后开始拖放，右键弹出移动菜单。
///
/// 停靠区的标签页、上下分割时每一格的标题、浮动面板的标题条都用它。
@MainActor
final class DockTabView: NSView, NSDraggingSource {
    let panel: PanelID
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    var onSelect: (() -> Void)?
    var onDragBegan: (() -> Void)?
    /// 拖动结束：屏幕坐标、是否被某个停靠区接收、是否按 Esc 取消。
    var onDragEnded: ((NSPoint, _ accepted: Bool, _ cancelled: Bool) -> Void)?
    var contextMenu: (() -> NSMenu?)?

    private let icon: NSImageView
    private let label: NSTextField
    private var mouseDownPoint: NSPoint?

    init(type: DockPanelType) {
        panel = type.id
        icon = NSImageView(image: NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil) ?? NSImage())
        label = NSTextField(labelWithString: type.title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = Theme.text2
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(type.title)
        toolTip = type.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// 左 8 点、图标 14 点、间距 4 点、标题、右 8 点，再留几点免得标题被截断。
    var fittingWidth: CGFloat {
        ceil(label.intrinsicContentSize.width) + 8 + 14 + 4 + 8 + 6
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = CGRect(x: 8, y: (height - 14) / 2, width: 14, height: 14)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = CGRect(x: 26, y: (height - labelHeight) / 2, width: max(bounds.width - 34, 0), height: labelHeight)
    }

    override func updateLayer() {
        layer?.backgroundColor = isSelected ? Theme.selected.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? Theme.text : Theme.text2
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        onDragBegan?()
        let item = NSPasteboardItem()
        item.setString(panel.rawValue, forType: .dockPanel)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil { onSelect?() }
        mouseDownPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    /// 拖动时的图像：凸起底色上的图标和标题。
    private func snapshot() -> NSImage {
        guard let layer else { return NSImage() }
        let background = layer.backgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = Theme.raised.cgColor
            layer.borderColor = Theme.lineStrong.cgColor
        }
        layer.borderWidth = 0.5
        let image = renderedImage()
        layer.backgroundColor = background
        layer.borderWidth = 0
        return image.map { NSImage(cgImage: $0, size: bounds.size) } ?? NSImage()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // 拖到停靠区以外（包括窗口之外）时结束操作为空，由回调改成浮动；Esc 取消时什么都不做。
        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
        onDragEnded?(screenPoint, operation != [], cancelled)
    }
}

extension NSView {
    /// 把视图的图层树按窗口的缩放渲染成图像；不需要屏幕录制权限。拖动图像和自检的截图都用它。
    func renderedImage() -> CGImage? {
        guard let layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if isFlipped, !layer.isGeometryFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }
}
