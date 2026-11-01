import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MVFoundation
import os
import Synchronization

/// 解码内存中的图像数据。解码在有并发上限的专用队列上执行，不占用协作线程池；
/// 等待中的解码按调用方任务的优先级出队，同优先级先到先解。
public final class ImageDecoder: Sendable {
    /// 性能核心数。
    public static let defaultConcurrency: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else {
            return ProcessInfo.processInfo.activeProcessorCount
        }
        return Int(count)
    }()

    /// GPU 2D 纹理的边长上限：Apple GPU 第 3 代起为 16384。
    public static let maxTextureSide: Int = {
        guard let device = MTLCreateSystemDefaultDevice() else { return 8192 }
        return device.supportsFamily(.apple3) ? 16384 : 8192
    }()

    let limiter: WorkLimiter

    public init(maxConcurrentDecodes: Int = ImageDecoder.defaultConcurrency) {
        limiter = WorkLimiter(limit: max(1, maxConcurrentDecodes))
    }

    /// 长边超过解码上限或纹理上限的图不整张解码，改用 `tiledSource`。
    public static func needsTiling(_ size: PixelSize, maxDecodeLongSide: Int) -> Bool {
        max(size.width, size.height) > min(maxDecodeLongSide, maxTextureSide)
    }

    /// 按目标尺寸解码：先用 JPEG/HEIC 的缩小解码（1/2、1/4、1/8）得到不小于目标的图，再按滤镜精确缩放。
    public func image(_ data: Data, target: DisplayTarget, quality: RenditionQuality = .exact) async throws -> RenderedImage {
        try await limiter.run {
            let source = try Self.source(data)
            let decoded = try Self.decode(source, index: 0, atLeast: target.pixelSize)
            return try Bitmap.resampled(decoded, to: target.pixelSize, filter: target.filter, sharpen: target.sharpen, quality: quality)
        }
    }

    /// 整张解码原图。长边超过 `maxDecodeLongSide` 或纹理上限时抛出 `requiresTiling`。
    public func original(_ data: Data, maxDecodeLongSide: Int) async throws -> RenderedImage {
        try await limiter.run {
            let source = try Self.source(data)
            let size = try Self.orientedSize(source, index: 0)
            guard !Self.needsTiling(size, maxDecodeLongSide: maxDecodeLongSide) else { throw MediaError.requiresTiling(size) }
            let decoded = try Self.decode(source, index: 0, atLeast: size)
            return try Bitmap.normalized(decoded, quality: .original)
        }
    }

    /// 超大图的分块来源。分块按需从压缩数据中解出需要的区域，不整张解码。
    public func tiledSource(_ data: Data) throws(MediaError) -> any TiledImageSource {
        try TiledImage(source: Self.source(data), limiter: limiter)
    }

    /// 动图的帧源；每帧按 `target` 解码和缩放。
    public func animatedFrames(_ data: Data, target: DisplayTarget) throws(MediaError) -> any AnimatedFrameSource {
        try AnimatedImage(source: Self.source(data), target: target, limiter: limiter)
    }

    /// 视频封面：取 1 秒处和 10% 处中较早的一帧，长边不超过 `maxPixel`。
    public func videoPoster(_ asset: AVAsset, maxPixel: Int) async throws -> RenderedImage {
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let (image, _) = try await generator.image(at: CMTime(seconds: min(1, duration * 0.1), preferredTimescale: 600))
        return try Bitmap.normalized(image, quality: .exact)
    }

    package static func source(_ data: Data) throws(MediaError) -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil else { throw .unsupported }
        guard CGImageSourceGetCount(source) > 0 else { throw .decodeFailed("没有可解码的图像") }
        return source
    }

    static func orientedSize(_ source: CGImageSource, index: Int) throws(MediaError) -> PixelSize {
        let (stored, orientation) = try storedSize(source, index: index)
        return orientation >= 5 ? PixelSize(width: stored.height, height: stored.width) : stored
    }

    static func storedSize(_ source: CGImageSource, index: Int) throws(MediaError) -> (PixelSize, orientation: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw .decodeFailed("读不出尺寸") }
        return (PixelSize(width: width, height: height), properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// 缩小级别可以比输出小这么多，再放大到输出尺寸：例如 20000² 缩到 2560 时用 1/8（2500）而不是 1/4（5000），
    /// 解码的像素少 3/4，放大 2.4% 看不出差别。
    static let levelTolerance = 0.9

    /// 按 EXIF 方向解码，宽高都接近或大于 `target`。缩小解码只取 2 的幂，这样 JPEG 直接在 DCT 域缩小，不经 ImageIO 自己的重采样
    /// （3600×5400 解到 2700 用 44 ms，直接要 2560 用 70 ms）。
    package static func decode(_ source: CGImageSource, index: Int, atLeast target: PixelSize) throws(MediaError) -> CGImage {
        let size = try orientedSize(source, index: index)
        let ratio = min(Double(size.width) / Double(max(1, target.width)), Double(size.height) / Double(max(1, target.height)))
        var factor = 1
        while factor < 8, Double(factor * 2) * levelTolerance <= ratio { factor *= 2 }
        let longSide = (Double(max(size.width, size.height)) / Double(factor)).rounded(.up)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw .decodeFailed("ImageIO 解码失败")
        }
        return image
    }
}

extension PixelSize {
    /// 等比缩放到长边为 `longSide`；本来更小时不放大。
    public func fitting(longSide: Int) -> PixelSize {
        fitting(within: PixelSize(width: longSide, height: longSide))
    }

    /// 等比缩放到能放进 `bounds`；本来更小时不放大。
    public func fitting(within bounds: PixelSize) -> PixelSize {
        let scale = min(1, Double(bounds.width) / Double(max(1, width)), Double(bounds.height) / Double(max(1, height)))
        return PixelSize(width: max(1, Int((Double(width) * scale).rounded())), height: max(1, Int((Double(height) * scale).rounded())))
    }
}

/// 有并发上限的工作队列。工作在专用的并发队列上执行；等待中的按提交时任务的优先级出队。
final class WorkLimiter: Sendable {
    private struct Waiter {
        let id: UInt64
        let priority: TaskPriority
        let start: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }

    private enum Admission {
        case start, wait, cancelled
    }

    private struct State {
        var running = 0
        var waiting: [Waiter] = []
        var nextID: UInt64 = 0
        /// 已登记、还没结束的请求（执行中或等待中）。
        var admitted: Set<UInt64> = []
        /// 在登记之前就被取消的请求。
        var cancelledEarly: Set<UInt64> = []
    }

    private static let signposter = OSSignposter(category: .decode)
    private let limit: Int
    private let queue = DispatchQueue(label: "io.github.ump45nose.MacView.media.decode", qos: .userInitiated, attributes: .concurrent)
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    var waitingCount: Int {
        state.withLock { $0.waiting.count }
    }

    var runningCount: Int {
        state.withLock { $0.running }
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let priority = Task.currentPriority
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let start: @Sendable () -> Void = { [queue, self] in
                    queue.async {
                        let interval = Self.signposter.beginInterval("decode")
                        continuation.resume(with: Result { try body() })
                        Self.signposter.endInterval("decode", interval)
                        self.finish(id)
                    }
                }
                let cancel: @Sendable () -> Void = { continuation.resume(throwing: CancellationError()) }
                let admission = state.withLock { state -> Admission in
                    if state.cancelledEarly.remove(id) != nil { return .cancelled }
                    state.admitted.insert(id)
                    if state.running < limit {
                        state.running += 1
                        return .start
                    }
                    state.waiting.append(Waiter(id: id, priority: priority, start: start, cancel: cancel))
                    return .wait
                }
                switch admission {
                case .start: start()
                case .cancelled: cancel()
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                if let index = state.waiting.firstIndex(where: { $0.id == id }) {
                    state.admitted.remove(id)
                    return state.waiting.remove(at: index)
                }
                // 执行中的不打断；还没登记的，登记时直接取消。
                if !state.admitted.contains(id) { state.cancelledEarly.insert(id) }
                return nil
            }
            waiter?.cancel()
        }
    }

    private func finish(_ id: UInt64) {
        let next = state.withLock { state -> Waiter? in
            state.admitted.remove(id)
            // max(by:) 在相等时保留先出现的，即同优先级中最早提交的。
            guard let index = state.waiting.indices.max(by: { state.waiting[$0].priority < state.waiting[$1].priority }) else {
                state.running -= 1
                return nil
            }
            return state.waiting.remove(at: index)
        }
        next?.start()
    }
}
