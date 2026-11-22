import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import Testing
@testable import MVTestSupport

/// C1.11：Mock 给出带序号的 20 帧，尺寸遵循视频宽高比，时间线一致。
@Test(arguments: [PixelSize(width: 1080, height: 1920), PixelSize(width: 90, height: 160)])
func mockVideoPreviewFramesFollowMetadataAndHaveDifferentPixels(size: PixelSize) async throws {
    let tree = MockTree(nodes: [.video("portrait.mp4", size, duration: 30)])
    let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
    let pipeline = MockImagePipeline(environment: environment)
    let identity = try environment.item(at: tree.location("portrait.mp4")).entry.identity
    var frames: [VideoPreviewFrame] = []
    for try await frame in pipeline.videoPreviewFrames(for: identity, priority: .near) { frames.append(frame) }
    #expect(frames.map(\.index) == Array(0..<20))
    for frame in frames {
        #expect(frame.duration == 30)
        #expect(frame.time == VideoPreview.time(of: frame.index, duration: 30))
        #expect(frame.image.image.width == 360)
        #expect(frame.image.image.height == 640)
        #expect(frame.image.quality == .exact)
    }
    let pixels = frames.compactMap { $0.image.image.dataProvider?.data as Data? }
    #expect(Set(pixels).count == 20)
}

@Test func mockVideoPreviewRejectsMissingDurationAndSupportsCancellationDelay() async throws {
    let tree = MockTree(nodes: [.image("still.jpg", PixelSize(width: 1920, height: 1080)),
                                .video("clip.mp4", PixelSize(width: 1920, height: 1080), duration: 30)])
    let environment = MockEnvironment(MockOptions(tree: tree, timing: .instant))
    let pipeline = MockImagePipeline(environment: environment)
    let still = try environment.item(at: tree.location("still.jpg")).entry.identity
    await #expect(throws: MediaError.unsupported) {
        for try await _ in pipeline.videoPreviewFrames(for: still, priority: .near) {}
    }
    pipeline.videoPreviewFrameDelay = .milliseconds(20)
    let clip = try environment.item(at: tree.location("clip.mp4")).entry.identity
    let consumer = Task {
        var count = 0
        do {
            for try await _ in pipeline.videoPreviewFrames(for: clip, priority: .near) {
                count += 1
                if count == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        } catch is CancellationError {}
        return count
    }
    #expect(try await consumer.value == 5)
}
