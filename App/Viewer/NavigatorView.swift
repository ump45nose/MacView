import AppKit
import QuartzCore

/// 导航图：页帧超出视口时显示在右上角，标出当前可见的区域；点按或拖动定位。
@MainActor
final class NavigatorView: NSView {
    let preferredSize = CGSize(width: 148, height: 148)
    /// 视口中心在页帧上的位置（0–1）。
    var onPan: ((CGPoint) -> Void)?
    private var thumbs: [CALayer] = []
    private let visible = CALayer()
    private var thumbFrame = CGRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        visible.borderWidth = 1.5
        visible.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(visible)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
        visible.borderColor = Theme.accent.cgColor
    }

    /// `frame` 是页帧在视图中的矩形，`viewport` 是视图的范围，都是点。
    func update(slots: [PageSlot], frame: CGRect, viewport: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let inner = bounds.insetBy(dx: 6, dy: 6)
        let scale = min(inner.width / frame.width, inner.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        thumbFrame = CGRect(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2, width: size.width, height: size.height)
        while thumbs.count < slots.count {
            let thumb = CALayer()
            thumb.contentsGravity = .resize
            layer?.insertSublayer(thumb, below: visible)
            thumbs.append(thumb)
        }
        while thumbs.count > slots.count { thumbs.removeLast().removeFromSuperlayer() }
        for (thumb, slot) in zip(thumbs, slots) {
            let page = slot.root.frame
            thumb.frame = CGRect(
                x: thumbFrame.minX + (page.minX - frame.minX) * scale, y: thumbFrame.minY + (page.minY - frame.minY) * scale,
                width: page.width * scale, height: page.height * scale
            )
            thumb.contents = slot.contents
            thumb.contentsRect = slot.imageLayer.contentsRect
        }
        let shown = viewport.intersection(frame)
        visible.frame = CGRect(
            x: thumbFrame.minX + (shown.minX - frame.minX) * scale, y: thumbFrame.minY + (shown.minY - frame.minY) * scale,
            width: shown.width * scale, height: shown.height * scale
        )
    }

    private func report(_ event: NSEvent) {
        guard thumbFrame.width > 0, thumbFrame.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPan?(CGPoint(
            x: min(max((point.x - thumbFrame.minX) / thumbFrame.width, 0), 1),
            y: min(max((point.y - thumbFrame.minY) / thumbFrame.height, 0), 1)
        ))
    }

    override func mouseDown(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
}
