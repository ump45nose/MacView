@preconcurrency import AVFoundation
import AppKit
import MVFoundation
import MVIO
import MVPipeline
import MVSettings
import QuartzCore

/// 视频页：`AVPlayerLayer` 加控制条。持有文件租约到离开这一页。
@MainActor
final class VideoPageView: NSView {
    let identity: ContentIdentity
    private let sources: any SourceRegistry
    private var pendingStartTime: Double?
    private let playerLayer = AVPlayerLayer()
    private(set) var player: AVPlayer?
    private var lease: FileLease?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private let bar = NSVisualEffectView()
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let position = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let previewLoader: VideoPreviewLoader
    private let hoverPopover = ScrubPreviewPopoverView()
    private var hoverTrackingArea: NSTrackingArea?
    private var settingsTask: Task<Void, Never>?
    private var videoHoverPreviewEnabled = true
    private var isHoveringSlider = false
    private var isDraggingSlider = false
    private var hoverFraction = 0.0
    private var hoverAnchorX: CGFloat = 0
    var onFailure: ((any Error) -> Void)?

    init(identity: ContentIdentity, sources: any SourceRegistry, pipeline: any ImagePipeline, startTime: Double? = nil) {
        self.identity = identity
        self.sources = sources
        self.pendingStartTime = startTime.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.previewLoader = VideoPreviewLoader(pipeline: pipeline)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: String(localized: "暂停"))
        slider.controlSize = .small
        slider.minValue = 0
        slider.maxValue = 1
        slider.target = self
        slider.action = #selector(seekFromSlider)
        slider.isContinuous = true
        for label in [position, total] {
            label.font = Theme.font(.overlays, size: 11, weight: .regular, monospacedDigits: true)
            label.textColor = Theme.text
        }
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        let stack = NSStackView(views: [playButton, position, slider, total])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        hoverPopover.isHidden = true
        addSubview(hoverPopover)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            bar.widthAnchor.constraint(equalToConstant: 420).withPriority(.defaultHigh),
        ])
        previewLoader.onFrame = { [weak self] in
            guard let self, self.isHoveringSlider || self.isDraggingSlider, self.videoHoverPreviewEnabled, self.previewLoader.identity == self.identity else { return }
            self.updateHoverPopover()
        }
        if let settings = (NSApp.delegate as? AppDelegate)?.services?.settings {
            observeVideoHoverPreviewSetting(settings)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applyFonts), name: Theme.fontsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopHoverPreview() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        if isHoveringSlider || isDraggingSlider {
            let track = sliderTrackRect
            hoverAnchorX = track.minX + CGFloat(hoverFraction) * track.width
            updateHoverPopover()
        }
    }

    func start() {
        let sources = sources
        let location = identity.location
        loadTask = Task { [weak self] in
            do {
                let lease = try await sources.provider(for: location).fileLease(for: location)
                guard let self, !Task.isCancelled else { return }
                self.lease = lease
                play(AVPlayer(url: lease.url))
            } catch {
                guard !Task.isCancelled else { return }
                self?.onFailure?(error)
            }
        }
    }

    private func play(_ player: AVPlayer) {
        self.player = player
        playerLayer.player = player
        statusObservation = player.currentItem?.observe(\.status) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            MainActor.assumeIsolated {
                guard status == .failed, let self else { return }
                self.stop()
                self.onFailure?(error ?? VideoError.unplayable)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        if let startTime = pendingStartTime {
            pendingStartTime = nil
            seekAndPlay(player, to: startTime)
        } else {
            player.play()
        }
    }

    /// 跳转到指定时间点并播放；播放器尚未建好时记下，建好后跳转完成后再起播。
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, seconds)
        if let player {
            pendingStartTime = nil
            seekAndPlay(player, to: target)
        } else {
            pendingStartTime = target
        }
    }

    private func seekAndPlay(_ player: AVPlayer, to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor [weak self, weak player] in
                guard finished, let self, let player, self.player === player else { return }
                player.play()
                self.updateProgress()
            }
        }
    }

    /// 离开这一页：释放播放器和租约。
    func stop() {
        stopHoverPreview()
        settingsTask?.cancel()
        settingsTask = nil
        loadTask?.cancel()
        pendingStartTime = nil
        statusObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        playerLayer.player = nil
        player = nil
        lease = nil
    }

    private func updateProgress() {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite else { return }
        if NSEvent.pressedMouseButtons == 0 { slider.doubleValue = current / duration }
        position.stringValue = Self.format(current)
        total.stringValue = Self.format(duration)
        playButton.image = player.rate == 0
            ? NSImage(systemSymbolName: "play.fill", accessibilityDescription: String(localized: "播放"))
            : NSImage(systemSymbolName: "pause.fill", accessibilityDescription: String(localized: "暂停"))
        if isHoveringSlider || isDraggingSlider {
            updateHoverPopover()
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.rate == 0 {
            if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
        updateProgress()
    }

    @objc private func seekFromSlider() {
        let fraction = min(max(slider.doubleValue, 0), 1)
        if let player, let item = player.currentItem, item.duration.isNumeric {
            player.seek(to: CMTime(seconds: fraction * item.duration.seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            isDraggingSlider = true
            let track = sliderTrackRect
            showHover(fraction: fraction, anchorX: track.minX + CGFloat(fraction) * track.width)
        case .leftMouseUp:
            isDraggingSlider = false
            let point = convert(event.locationInWindow, from: nil)
            if sliderTrackingRect.contains(point) {
                isHoveringSlider = true
                let track = sliderTrackRect
                showHover(fraction: fraction, anchorX: track.minX + CGFloat(fraction) * track.width)
            } else {
                stopHoverPreview()
            }
        default: break
        }
    }

    // MARK: - 进度条悬停预览

    private func observeVideoHoverPreviewSetting(_ settings: any SettingsStore) {
        let changes = settings.changes()
        settingsTask = Task { [weak self] in
            let initial = await settings.global().videoHoverPreview
            self?.setVideoHoverPreviewEnabled(initial)
            for await change in changes where change == .global {
                guard !Task.isCancelled, let self else { return }
                self.setVideoHoverPreviewEnabled(await settings.global().videoHoverPreview)
            }
        }
    }

    private func setVideoHoverPreviewEnabled(_ enabled: Bool) {
        videoHoverPreviewEnabled = enabled
        if !enabled { stopHoverPreview() }
    }

    @objc private func applyFonts() {
        let barFont = Theme.font(.overlays, size: 11, weight: .regular, monospacedDigits: true)
        position.font = barFont
        total.font = barFont
        hoverPopover.timeLabel.font = Theme.font(.overlays, size: 11, weight: .medium, monospacedDigits: true)
        if isHoveringSlider || isDraggingSlider { updateHoverPopover() }
    }

    private var sliderTrackRect: CGRect {
        if let cell = slider.cell as? NSSliderCell {
            let track = cell.barRect(flipped: slider.isFlipped)
            if track.width > 0 { return convert(track, from: slider) }
        }
        return convert(slider.bounds, from: slider)
    }

    private var sliderTrackingRect: CGRect {
        convert(slider.bounds, from: slider).insetBy(dx: 0, dy: -6)
    }

    private func handleSliderHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard videoHoverPreviewEnabled, sliderTrackingRect.contains(point) else {
            if !isDraggingSlider || !videoHoverPreviewEnabled { stopHoverPreview() }
            return
        }
        let track = sliderTrackRect
        let fraction = min(max(Double((point.x - track.minX) / max(track.width, 1)), 0), 1)
        isHoveringSlider = true
        showHover(fraction: fraction, anchorX: min(max(point.x, track.minX), track.maxX))
    }

    private func showHover(fraction: Double, anchorX: CGFloat) {
        guard videoHoverPreviewEnabled else { stopHoverPreview(); return }
        hoverFraction = fraction
        hoverAnchorX = anchorX
        previewLoader.start(identity)
        updateHoverPopover()
    }

    private func updateHoverPopover() {
        guard isHoveringSlider || isDraggingSlider, videoHoverPreviewEnabled else { hoverPopover.isHidden = true; return }
        let frame = previewLoader.frame(at: hoverFraction)
        let duration = player?.currentItem?.duration.seconds
        let validDuration = (duration?.isFinite == true && (duration ?? 0) > 0) ? duration : previewLoader.duration
        let timeText = validDuration.map { Self.format(hoverFraction * $0) } ?? "0:00"
        let aspect: CGFloat = if let frame, frame.image.image.height > 0 {
            CGFloat(frame.image.image.width) / CGFloat(frame.image.image.height)
        } else if let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0 {
            size.width / size.height
        } else {
            16.0 / 9.0
        }
        let size = hoverPopover.update(frame: frame, timeText: timeText, aspectRatio: aspect, maxHeight: max(0, bar.frame.minY - 18))
        let inset = min(8, max(0, (bounds.width - size.width) / 2))
        let x = min(max(hoverAnchorX - size.width / 2, inset), max(inset, bounds.width - inset - size.width))
        let y = max(8, bar.frame.minY - 10 - size.height)
        hoverPopover.frame = CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
        hoverPopover.isHidden = false
    }

    private func stopHoverPreview() {
        guard isHoveringSlider || isDraggingSlider || !hoverPopover.isHidden || previewLoader.identity != nil else { return }
        isHoveringSlider = false
        isDraggingSlider = false
        hoverPopover.isHidden = true
        previewLoader.stop()
    }

    #if DEBUG
    struct ScrubPreviewSnapshot {
        var isVisible: Bool
        var frame: CGRect
        var fraction: Double
        var frameIndex: Int?
        var loadedFrameCount: Int
        var timeText: String
        var hasImage: Bool
        var isLoaderActive: Bool
    }

    var scrubPreviewSnapshot: ScrubPreviewSnapshot {
        ScrubPreviewSnapshot(
            isVisible: !hoverPopover.isHidden,
            frame: hoverPopover.frame,
            fraction: hoverFraction,
            frameIndex: (isHoveringSlider || isDraggingSlider) ? previewLoader.frame(at: hoverFraction)?.index : nil,
            loadedFrameCount: previewLoader.loadedFrameCount,
            timeText: hoverPopover.timeLabel.stringValue,
            hasImage: hoverPopover.hasImage,
            isLoaderActive: previewLoader.identity != nil
        )
    }

    var sliderTrackFrame: CGRect { sliderTrackRect }
    var controlBarFrame: CGRect { bar.frame }
    #endif

    override func mouseEntered(with event: NSEvent) { handleSliderHover(with: event) }
    override func mouseMoved(with event: NSEvent) { handleSliderHover(with: event) }
    override func mouseExited(with event: NSEvent) { if !isDraggingSlider { stopHoverPreview() } }

    /// 点画面切换播放和暂停；拖动等手势交给查看器。
    override func mouseUp(with event: NSEvent) {
        togglePlay()
    }

    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { superview?.rightMouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { superview?.smartMagnify(with: event) }
    override func rotate(with event: NSEvent) { superview?.rotate(with: event) }
}

/// 播放进度条悬停预览浮层：160 pt 宽预览图（圆角 5 pt）+ 下方等宽数字时间；未到帧时只显示时间。
@MainActor
private final class ScrubPreviewPopoverView: NSView {
    private let imageLayer = CALayer()
    let timeLabel = NSTextField(labelWithString: "0:00")
    private(set) var hasImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        imageLayer.cornerRadius = 5
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        timeLabel.alignment = .center
        timeLabel.textColor = Theme.text
        timeLabel.font = Theme.font(.overlays, size: 11, weight: .medium, monospacedDigits: true)
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = Theme.hud.cgColor
        layer?.borderColor = Theme.lineStrong.cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
    }

    func update(frame: VideoPreviewFrame?, timeText: String, aspectRatio: CGFloat, maxHeight: CGFloat) -> CGSize {
        timeLabel.stringValue = timeText
        timeLabel.sizeToFit()
        let labelHeight = ceil(timeLabel.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let frame {
            let chrome = 11 + labelHeight // 上下 4 + 间距 3 + 时间行
            let upper = maxHeight > chrome + 60 ? min(220, maxHeight - chrome) : 220
            let imageHeight = min(max((160 / max(aspectRatio, 0.25)).rounded(), 60), max(60, upper))
            imageLayer.contents = frame.image.surface ?? frame.image.image
            imageLayer.frame = CGRect(x: 4, y: 4, width: 160, height: imageHeight)
            imageLayer.isHidden = false
            timeLabel.frame = CGRect(x: 4, y: 7 + imageHeight, width: 160, height: labelHeight)
            hasImage = true
            return CGSize(width: 168, height: chrome + imageHeight)
        }
        let width = max(ceil(timeLabel.frame.width) + 16, 48)
        imageLayer.contents = nil
        imageLayer.isHidden = true
        timeLabel.frame = CGRect(x: 0, y: 4, width: width, height: labelHeight)
        hasImage = false
        return CGSize(width: width, height: labelHeight + 8)
    }
}

enum VideoError: Error {
    case unplayable
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
