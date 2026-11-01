import CoreGraphics
import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import Synchronization

/// 生成带编号合成图的图像管线。
///
/// - 首访要在环境的读取队列里排队（默认 2.5 张/秒），之后各阶段相隔 `stageInterval`。
/// - 注入的错误和卷状态对所有请求生效。
/// - 合成图的长边不超过 4096 像素。
public final class MockImagePipeline: ImagePipeline {
    /// 缩略图渲染件的长边；占位图由它放大而来。
    static let thumbnailSide = 512
    static let browseSide = 2048
    static let maxRenderSide = 4096
    /// `thumbnails(for:)` 同时进行的请求数。
    static let thumbnailConcurrency = 16

    public let environment: MockEnvironment
    private let plans = Mutex<[SessionID: PrefetchPlan]>([:])

    public init(environment: MockEnvironment) {
        self.environment = environment
    }

    public func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata {
        let location = identity.location
        try await environment.access(location)
        return try environment.media(at: location).metadata
    }

    public func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage {
        let location = identity.location
        let media = try await environment.readMedia(location, priority: priority)
        return render(location, media, size: media.pixelSize.fitted(longSide: maxPixel), quality: .exact)
    }

    public func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> {
        AsyncStream { continuation in
            let task = Task {
                let work: @Sendable (ContentIdentity) async -> (ContentIdentity, Result<RenderedImage, any Error>) = { identity in
                    do {
                        return (identity, .success(try await self.thumbnail(for: identity, maxPixel: maxPixel, priority: priority)))
                    } catch {
                        return (identity, .failure(error))
                    }
                }
                await withTaskGroup(of: (ContentIdentity, Result<RenderedImage, any Error>).self) { group in
                    var pending = identities.makeIterator()
                    for _ in 0..<Self.thumbnailConcurrency {
                        guard let identity = pending.next() else { break }
                        group.addTask { await work(identity) }
                    }
                    while let result = await group.next() {
                        continuation.yield(result)
                        if let identity = pending.next() {
                            group.addTask { await work(identity) }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> {
        let location = identity.location
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let media = try await environment.readMedia(location, priority: priority)
                    continuation.yield(render(location, media, size: media.pixelSize.fitted(longSide: Self.thumbnailSide), quality: .placeholder))
                    try await environment.pause(environment.timing.stageInterval)
                    continuation.yield(render(location, media, size: media.pixelSize.fitted(longSide: Self.browseSide), quality: .browse))
                    try await environment.pause(environment.timing.stageInterval)
                    let upscaled = target.pixelSize.width > media.pixelSize.width || target.pixelSize.height > media.pixelSize.height
                    if allowOriginal, upscaled {
                        continuation.yield(render(location, media, size: media.pixelSize, quality: .original))
                    } else {
                        continuation.yield(render(location, media, size: target.pixelSize, quality: .exact))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource {
        let location = identity.location
        let media = try await environment.readMedia(location, priority: .visible)
        return MockTiledSource(pixelSize: media.pixelSize, seed: MockRandom.fnv1a(location.description))
    }

    public func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource {
        let location = identity.location
        let media = try await environment.readMedia(location, priority: .visible)
        guard media.frameCount > 1 else { throw IOError.unsupported(location) }
        return MockAnimatedFrames(title: Self.title(of: location), frameCount: media.frameCount, size: target.pixelSize, seed: MockRandom.fnv1a(location.description))
    }

    public func videoPoster(for identity: ContentIdentity, maxPixel: Int) async throws -> RenderedImage {
        let location = identity.location
        let media = try await environment.readMedia(location, priority: .near)
        guard media.duration != nil else { throw IOError.unsupported(location) }
        return render(location, media, size: media.pixelSize.fitted(longSide: maxPixel), quality: .exact)
    }

    public func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) {
        plans.withLock { $0[session] = plan }
    }

    public func cancelAll(session: SessionID) {
        plans.withLock { $0[session] = nil }
    }

    /// 会话当前的预取计划，供测试检查。
    public func prefetchPlan(for session: SessionID) -> PrefetchPlan? {
        plans.withLock { $0[session] }
    }

    private func render(_ location: Location, _ media: MockMedia, size: PixelSize, quality: RenditionQuality) -> RenderedImage {
        let size = size.fitted(longSide: Self.maxRenderSide)
        let kind = media.duration == nil ? "\(quality)" : "video \(quality)"
        let image = MockArtwork.image(title: Self.title(of: location), caption: "\(kind) \(size.width)×\(size.height)", size: size, seed: MockRandom.fnv1a(location.description))
        return RenderedImage(image: image, quality: quality)
    }

    /// 文件名去掉扩展名，例如 `050`。
    private static func title(of location: Location) -> String {
        (location.name as NSString).deletingPathExtension
    }
}

struct MockAnimatedFrames: AnimatedFrameSource {
    let title: String
    let frameCount: Int
    let loopCount = 0
    let size: PixelSize
    let seed: UInt64

    func duration(at index: Int) -> Double {
        0.1
    }

    func frame(at index: Int) async throws -> RenderedImage {
        try Task.checkCancellation()
        let image = MockArtwork.image(title: title, caption: "frame \(index + 1)/\(frameCount)", size: size.fitted(longSide: MockImagePipeline.maxRenderSide), seed: seed &+ UInt64(index) &* 7)
        return RenderedImage(image: image, quality: .exact)
    }
}

struct MockTiledSource: TiledImageSource {
    let pixelSize: PixelSize
    let seed: UInt64

    func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage {
        try Task.checkCancellation()
        let size = PixelSize(width: max(1, Int((rect.width * scale).rounded())), height: max(1, Int((rect.height * scale).rounded())))
        let image = MockArtwork.image(title: "\(Int(rect.minX)),\(Int(rect.minY))", caption: "tile ×\(scale)", size: size.fitted(longSide: MockImagePipeline.maxRenderSide), seed: seed)
        return RenderedImage(image: image, quality: .original)
    }
}

extension PixelSize {
    var longSide: Int { max(width, height) }

    /// 等比缩小到长边不超过 `limit`，不放大，至少 1 像素。
    func fitted(longSide limit: Int) -> PixelSize {
        guard limit > 0, longSide > limit else { return self }
        let scale = Double(limit) / Double(longSide)
        return PixelSize(width: max(1, Int((Double(width) * scale).rounded())), height: max(1, Int((Double(height) * scale).rounded())))
    }
}
