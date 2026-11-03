@preconcurrency import AVFoundation
import AppKit
import MVFoundation
import MVIO

/// 视频页：`AVPlayerLayer` 加控制条。持有文件租约到离开这一页。
@MainActor
final class VideoPageView: NSView {
    let identity: ContentIdentity
    private let sources: any SourceRegistry
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
    var onFailure: ((any Error) -> Void)?

    init(identity: ContentIdentity, sources: any SourceRegistry) {
        self.identity = identity
        self.sources = sources
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
        slider.action = #selector(seek)
        slider.isContinuous = true
        for label in [position, total] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
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
        player.play()
    }

    /// 离开这一页：释放播放器和租约。
    func stop() {
        loadTask?.cancel()
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
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
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

    @objc private func seek() {
        guard let player, let item = player.currentItem, item.duration.isNumeric else { return }
        player.seek(to: CMTime(seconds: slider.doubleValue * item.duration.seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 点画面切换播放和暂停；拖动等手势交给查看器。
    override func mouseUp(with event: NSEvent) {
        togglePlay()
    }

    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
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
