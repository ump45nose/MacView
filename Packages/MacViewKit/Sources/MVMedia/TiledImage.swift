import CoreGraphics
import Foundation
import ImageIO
import MVFoundation
import Synchronization

/// 超大图的分块来源。每个缩小级别（1、1/2、1/4、1/8）一张不缓存像素的 CGImage，分块时裁出区域再绘制，
/// ImageIO 只解码需要的部分：20000×20000 的 JPEG 每块 1024² 只用几毫秒，进程峰值内存不到 100 MB（S1-T3 实测）。
/// 每个级别第一次取块时 ImageIO 要先扫描一遍压缩数据，所以第一次取块后在后台预热原尺寸级别。
final class TiledImage: TiledImageSource {
    let pixelSize: PixelSize
    private let stored: PixelSize
    private let orientation: Int
    private let limiter: WorkLimiter
    /// CGImageSource 没有标明可跨线程使用，在锁内访问。
    private let state: Mutex<(source: CGImageSource, levels: [Int: CGImage], warmed: Bool)>

    init(source: sending CGImageSource, limiter: WorkLimiter) throws(MediaError) {
        (stored, orientation) = try ImageDecoder.storedSize(source, index: 0)
        pixelSize = orientation >= 5 ? PixelSize(width: stored.height, height: stored.width) : stored
        self.limiter = limiter
        state = Mutex((source, [:], false))
    }

    /// `rect` 是显示方向下原图的像素坐标（左上角为原点），`scale` 是输出相对原图的比例。
    func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage {
        let bounds = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        let rect = rect.intersection(bounds).integral
        guard !rect.isEmpty, scale > 0 else { throw MediaError.decodeFailed("分块区域 \(rect) 在图外") }
        let output = PixelSize(width: max(1, Int((rect.width * scale).rounded())), height: max(1, Int((rect.height * scale).rounded())))
        var factor = 1
        while factor < 8, 1 / Double(factor * 2) >= scale * ImageDecoder.levelTolerance { factor *= 2 }
        let quality: RenditionQuality = factor == 1 && scale >= 1 ? .original : .exact
        let tile = try await limiter.run { [self, factor] in
            // CGImage 不可变，可以在多个线程上同时裁切和绘制；锁只保护级别的创建。
            let level = try state.withLock { state throws(MediaError) in try level(factor, &state) }
            let ratio = Double(level.width) / Double(stored.width)
            let region = storedRect(rect)
            let crop = CGRect(x: region.minX * ratio, y: region.minY * ratio, width: region.width * ratio, height: region.height * ratio).integral
            guard let cropped = level.cropping(to: crop) else { throw MediaError.decodeFailed("裁出分块失败") }
            return try Bitmap.oriented(cropped, orientation: orientation, to: output, quality: quality)
        }
        warmFullResolution()
        return tile
    }

    private func level(_ factor: Int, _ state: inout (source: CGImageSource, levels: [Int: CGImage], warmed: Bool)) throws(MediaError) -> CGImage {
        if let level = state.levels[factor] { return level }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let level = CGImageSourceCreateImageAtIndex(state.source, 0, options as CFDictionary) else { throw .decodeFailed("ImageIO 解码失败") }
        state.levels[factor] = level
        return level
    }

    private func warmFullResolution() {
        let start = state.withLock { state in
            defer { state.warmed = true }
            return !state.warmed
        }
        guard start else { return }
        Task(priority: .background) { [self] in
            _ = try? await tile(CGRect(x: pixelSize.width / 2, y: pixelSize.height / 2, width: 1, height: 1), scale: 1)
        }
    }

    /// 显示方向下的矩形换成存放方向下的矩形。与 EXIF 方向的定义互逆：例如方向 6 把存放的图顺时针转 90° 显示。
    func storedRect(_ rect: CGRect) -> CGRect {
        let (w, h) = (CGFloat(stored.width), CGFloat(stored.height))
        let (x, y, rw, rh) = (rect.minX, rect.minY, rect.width, rect.height)
        switch orientation {
        case 2: return CGRect(x: w - x - rw, y: y, width: rw, height: rh)
        case 3: return CGRect(x: w - x - rw, y: h - y - rh, width: rw, height: rh)
        case 4: return CGRect(x: x, y: h - y - rh, width: rw, height: rh)
        case 5: return CGRect(x: y, y: x, width: rh, height: rw)
        case 6: return CGRect(x: y, y: h - x - rw, width: rh, height: rw)
        case 7: return CGRect(x: w - y - rh, y: h - x - rw, width: rh, height: rw)
        case 8: return CGRect(x: w - y - rh, y: x, width: rh, height: rw)
        default: return rect
        }
    }
}

/// 动图的帧源。帧时长和循环次数在创建时读出，帧按需解码；ImageIO 给出的帧已按处置方式合成。
final class AnimatedImage: AnimatedFrameSource {
    let frameCount: Int
    let loopCount: Int
    private let delays: [Double]
    private let target: DisplayTarget
    private let limiter: WorkLimiter
    private let source: Mutex<CGImageSource>

    init(source: sending CGImageSource, target: DisplayTarget, limiter: WorkLimiter) throws(MediaError) {
        frameCount = CGImageSourceGetCount(source)
        loopCount = FrameTiming.loopCount(source)
        delays = (0..<frameCount).map { FrameTiming.delay(source, at: $0) }
        self.target = target
        self.limiter = limiter
        self.source = Mutex(source)
    }

    func duration(at index: Int) -> Double {
        delays[index]
    }

    func frame(at index: Int) async throws -> RenderedImage {
        guard delays.indices.contains(index) else { throw MediaError.decodeFailed("没有第 \(index) 帧") }
        let target = target
        return try await limiter.run { [self] in
            let decoded = try source.withLock { try ImageDecoder.decode($0, index: index, atLeast: target.pixelSize) }
            return try Bitmap.resampled(decoded, to: target.pixelSize, filter: target.filter, sharpen: target.sharpen, quality: .exact)
        }
    }
}
