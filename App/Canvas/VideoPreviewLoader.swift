import MVFoundation
import MVPipeline
import os

/// 按内容身份收预览帧；画布和视频页共用。主线程使用。
@MainActor
final class VideoPreviewLoader {
    private let pipeline: any ImagePipeline
    private(set) var identity: ContentIdentity?
    private(set) var duration: Double?
    /// 每到一帧调用一次（主线程）。每次 start/stop 递增请求代次，回调只交付当前代次的帧，旧请求晚到的帧和结束事件一律丢弃。
    var onFrame: (() -> Void)?

    private var frames: [VideoPreviewFrame?] = Array(repeating: nil, count: VideoPreview.frameCount)
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private let signposter = OSSignposter(category: .render)
    var observationID: UInt64 { generation }

    init(pipeline: any ImagePipeline) {
        self.pipeline = pipeline
    }

    var loadedFrameCount: Int {
        frames.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    /// 开始收这个视频的帧；身份不同则先取消旧的。优先级 .near。
    func start(_ identity: ContentIdentity) {
        if self.identity == identity { return }
        stop()
        generation &+= 1
        let gen = generation
        self.identity = identity
        signposter.emitEvent("VideoPreviewStart", "request=\(gen, privacy: .public)")
        let pipeline = pipeline
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for try await frame in pipeline.videoPreviewFrames(for: identity, priority: .near) {
                    guard !Task.isCancelled, let self else { break }
                    if !(await self.receive(frame, generation: gen)) { break }
                }
            } catch {
                // 取帧失败或取消时保持封面，不向界面报错。
            }
            await self?.finish(generation: gen)
        }
    }

    /// 取消请求、清空已收的帧（帧仍在管线的内存缓存里）。
    func stop() {
        if task != nil { signposter.emitEvent("VideoPreviewCancel", "request=\(self.generation, privacy: .public)") }
        generation &+= 1
        task?.cancel()
        task = nil
        identity = nil
        duration = nil
        for index in frames.indices {
            frames[index] = nil
        }
    }

    /// 横向位置（0...1）对应的帧：想要的下标附近最近的已到帧；一张没到时为 nil。
    func frame(at fraction: Double) -> VideoPreviewFrame? {
        let wanted = VideoPreview.index(at: fraction)
        if let exact = frames[wanted] { return exact }
        for distance in 1..<VideoPreview.frameCount {
            let left = wanted - distance
            if left >= 0, let frame = frames[left] { return frame }
            let right = wanted + distance
            if right < VideoPreview.frameCount, let frame = frames[right] { return frame }
        }
        return nil
    }

    private func receive(_ frame: VideoPreviewFrame, generation gen: UInt64) -> Bool {
        guard gen == generation else { return false }
        guard frame.index >= 0, frame.index < VideoPreview.frameCount else { return true }
        frames[frame.index] = frame
        if frame.duration > 0 {
            duration = frame.duration
        }
        onFrame?()
        if loadedFrameCount == VideoPreview.frameCount {
            signposter.emitEvent("VideoPreviewComplete", "request=\(gen, privacy: .public)")
        }
        return true
    }

    private func finish(generation gen: UInt64) {
        signposter.emitEvent("VideoPreviewEnd", "request=\(gen, privacy: .public)")
        guard gen == generation else { return }
        task = nil
    }
}
