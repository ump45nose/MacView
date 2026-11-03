import AppKit
import MVFoundation
import MVMedia
import MVPipeline
import QuartzCore

/// 动图的播放：显示链接按帧时长推进，帧按需解码。窗口不可见时暂停。
@MainActor
final class AnimatedPageLayer: NSObject {
    let target: DisplayTarget
    private let identity: ContentIdentity
    private let pipeline: any ImagePipeline
    private weak var layer: CALayer?
    private weak var view: NSView?
    private var source: (any AnimatedFrameSource)?
    private var loadTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var link: CADisplayLink?
    private var next: (index: Int, image: RenderedImage)?
    private var due: CFTimeInterval = 0
    private var loops = 0
    private var visible = true
    private(set) var frameIndex = 0
    /// 累计显示过的帧数，供自检确认在前进。
    private(set) var framesShown = 0
    var onFailure: ((any Error) -> Void)?

    init(identity: ContentIdentity, target: DisplayTarget, pipeline: any ImagePipeline, layer: CALayer, view: NSView) {
        self.identity = identity
        self.target = target
        self.pipeline = pipeline
        self.layer = layer
        self.view = view
    }

    var isPlaying: Bool { link?.isPaused == false }

    func start() {
        let pipeline = pipeline
        let identity = identity
        let target = target
        loadTask = Task { [weak self] in
            do {
                let source = try await pipeline.animatedFrames(for: identity, target: target)
                guard let self, !Task.isCancelled else { return }
                self.source = source
                decode(1 % source.frameCount)
                let link = view?.displayLink(target: self, selector: #selector(tick(_:)))
                link?.add(to: .main, forMode: .common)
                link?.isPaused = !visible
                self.link = link
            } catch {
                guard !Task.isCancelled else { return }
                self?.onFailure?(error)
            }
        }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        link?.isPaused = !visible
    }

    /// 显示链接持有目标，离开页面时要显式停止。
    func stop() {
        loadTask?.cancel()
        decodeTask?.cancel()
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let source else { return }
        if due == 0 { due = link.timestamp + frameDuration(frameIndex, source) }
        guard link.timestamp >= due, let ready = next else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = ready.image.surface ?? ready.image.image
        CATransaction.commit()
        frameIndex = ready.index
        framesShown += 1
        next = nil
        due = max(due + frameDuration(frameIndex, source), link.timestamp)
        if frameIndex == 0 {
            loops += 1
            if source.loopCount != 0, loops >= source.loopCount {
                stop()
                return
            }
        }
        decode((frameIndex + 1) % source.frameCount)
    }

    /// 帧时长为 0 的文件按浏览器的惯例取 0.1 秒。
    private func frameDuration(_ index: Int, _ source: any AnimatedFrameSource) -> CFTimeInterval {
        let value = source.duration(at: index)
        return value > 0.01 ? value : 0.1
    }

    private func decode(_ index: Int) {
        guard let source else { return }
        decodeTask = Task { [weak self] in
            do {
                let image = try await source.frame(at: index)
                guard !Task.isCancelled else { return }
                self?.next = (index, image)
            } catch {
                guard !Task.isCancelled else { return }
                self?.onFailure?(error)
            }
        }
    }
}
