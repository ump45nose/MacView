import AppKit
import MVCommands
import MVFoundation
import MVMedia
import MVPipeline
import MVReading
import MVSettings
import os
import QuartzCore

/// 最简页面视图：按会话的当前页帧显示图像，用来验证会话接入。正式查看器（S2-F1）会替换它。
///
/// 页帧中的各页按阅读方向并排，整体等比适合视图；图像按页的像素尺寸、以屏幕像素为上限向管线请求，渐进交付时逐级替换。
/// 没有书、读取中、书中没有页或打开失败时，显示居中的提示。
@MainActor
final class PageView: NSView, InputScoped {
    private struct Slot {
        var element: PageFrameElement
        var identity: ContentIdentity
        /// 宽高比；元数据未到时先按图像，再没有时按 2:3。
        var aspect: Double
        var layer: CALayer
        var task: Task<Void, Never>?
    }

    private let session: ReaderSession
    private let pipeline: any ImagePipeline
    private let logger = Logger(category: "page-view")
    private var slots: [Slot] = []
    private let message = PlaceholderView()

    var inputScope: InputScope { .viewer }
    /// 空状态里的“打开…”按钮。
    var onOpen: (() -> Void)? {
        get { message.onAction }
        set { message.onAction = newValue }
    }

    init(session: ReaderSession, pipeline: any ImagePipeline) {
        self.session = session
        self.pipeline = pipeline
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.canvas.cgColor
    }

    /// 会话状态变化后调用。
    func refresh() {
        updateMessage()
        let pages = session.book?.pages ?? []
        let frame = session.frames.indices.contains(session.currentFrame) ? session.frames[session.currentFrame] : nil
        var elements = frame?.elements.filter { pages.indices.contains($0.page) } ?? []
        if session.settings.direction == .rightToLeft {
            elements.reverse()
        }
        var kept: [Slot] = []
        for element in elements {
            let page = pages[element.page]
            let aspect = page.metadata.map { Self.aspect(of: $0.pixelSize, part: element.part) }
            if let index = slots.firstIndex(where: { $0.identity == page.entry.identity && $0.element.part == element.part }) {
                var slot = slots.remove(at: index)
                slot.element = element
                if let aspect { slot.aspect = aspect }
                kept.append(slot)
            } else {
                kept.append(makeSlot(element, page: page, aspect: aspect))
            }
        }
        for slot in slots {
            slot.task?.cancel()
            slot.layer.removeFromSuperlayer()
        }
        slots = kept
        needsLayout = true
    }

    /// 窗口关闭时取消全部请求。
    func cancelLoads() {
        for slot in slots {
            slot.task?.cancel()
        }
    }

    override func layout() {
        super.layout()
        let total = slots.reduce(0) { $0 + $1.aspect }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return }
        let height = min(bounds.height, bounds.width / total)
        var x = (bounds.width - height * total) / 2
        let y = (bounds.height - height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in slots {
            let width = height * slot.aspect
            slot.layer.frame = CGRect(x: x, y: y, width: width, height: height)
            x += width
        }
        CATransaction.commit()
    }

    private func makeSlot(_ element: PageFrameElement, page: Page, aspect: Double?) -> Slot {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.backgroundColor = Theme.line.cgColor
        switch element.part {
        case .whole: break
        case .leftHalf: layer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: layer.contentsRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        }
        self.layer?.addSublayer(layer)
        var slot = Slot(element: element, identity: page.entry.identity, aspect: aspect ?? 2.0 / 3.0, layer: layer)
        slot.task = load(page, into: layer)
        return slot
    }

    private func load(_ page: Page, into layer: CALayer) -> Task<Void, Never> {
        let identity = page.entry.identity
        let screen = (window?.screen ?? NSScreen.main).map { $0.frame.size.applying(.init(scaleX: $0.backingScaleFactor, y: $0.backingScaleFactor)) }
            ?? CGSize(width: 3840, height: 2160)
        let bounds = PixelSize(width: Int(screen.width), height: Int(screen.height))
        let target = DisplayTarget(pixelSize: (page.metadata?.pixelSize ?? bounds).fitting(within: bounds))
        let stream = pipeline.image(for: identity, target: target, allowOriginal: false, priority: .visible)
        return Task { [weak self] in
            do {
                for try await image in stream {
                    guard let self, !Task.isCancelled else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = image.surface ?? image.image
                    layer.backgroundColor = nil
                    CATransaction.commit()
                    self.imageArrived(identity, size: PixelSize(width: image.image.width, height: image.image.height))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.logger.error("读取页面失败：\(identity.location.description, privacy: .public) \(String(describing: error), privacy: .public)")
                self.showFailure(ErrorText.describe(error), in: layer)
            }
        }
    }

    /// 元数据还没到时，用图像自己的宽高比排版。
    private func imageArrived(_ identity: ContentIdentity, size: PixelSize) {
        guard let index = slots.firstIndex(where: { $0.identity == identity }),
              session.book?.pages.first(where: { $0.entry.identity == identity })?.metadata == nil else { return }
        slots[index].aspect = Self.aspect(of: size, part: slots[index].element.part)
        needsLayout = true
    }

    private func showFailure(_ text: String, in layer: CALayer) {
        let label = CATextLayer()
        label.string = text
        label.font = NSFont.systemFont(ofSize: 12)
        label.fontSize = 12
        label.foregroundColor = Theme.danger.cgColor
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = layer.bounds.insetBy(dx: 12, dy: layer.bounds.height / 2 - 20)
        label.autoresizingMask = [.layerWidthSizable, .layerMinYMargin, .layerMaxYMargin]
        layer.addSublayer(label)
    }

    private func updateMessage() {
        if let error = session.loadError {
            message.show(title: String(localized: "无法打开这本书"), detail: ErrorText.describe(error), action: String(localized: "打开…"))
        } else if let book = session.book {
            if !session.frames.isEmpty {
                message.isHidden = true
            } else if !book.isEnumerated {
                message.show(title: String(localized: "正在读取…"), detail: String(localized: "已找到 \(book.pages.count) 页"), action: nil)
            } else {
                message.show(title: String(localized: "这里没有图片或视频"), detail: book.location.name, action: nil)
            }
        } else {
            message.show(title: String(localized: "打开一个文件夹或压缩包"), detail: String(localized: "也可以把它们拖到这个窗口"), action: String(localized: "打开…"))
        }
    }

    private static func aspect(of size: PixelSize, part: PagePart) -> Double {
        let ratio = Double(size.width) / Double(max(size.height, 1))
        return part == .whole ? ratio : ratio / 2
    }
}

/// 页面视图中央的提示：衬线标题、说明和可选的主按钮。
@MainActor
private final class PlaceholderView: NSStackView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    var onAction: (() -> Void)?

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
        button.bezelStyle = .push
        button.controlSize = .large
        button.keyEquivalent = ""
        button.bezelColor = Theme.primary
        button.contentTintColor = Theme.onPrimary
        button.target = self
        button.action = #selector(act)
        addArrangedSubview(title)
        addArrangedSubview(detail)
        addArrangedSubview(button)
        setCustomSpacing(14, after: detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(title: String, detail: String, action: String?) {
        isHidden = false
        self.title.stringValue = title
        self.detail.stringValue = detail
        button.isHidden = action == nil
        button.title = action ?? ""
    }

    @objc private func act() {
        onAction?()
    }
}
