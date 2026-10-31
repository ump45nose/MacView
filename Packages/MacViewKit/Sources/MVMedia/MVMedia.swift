// MVMedia：探测、解码与重采样、动图帧、视频封面、渲染件编码。职责与契约见 docs/architecture.md §2、§4。
import CoreGraphics
import Foundation
import MVFoundation

public struct ImageMetadata: Sendable, Codable, Hashable {
    /// 已按 EXIF 方向换算。
    public var pixelSize: PixelSize
    public var frameCount: Int
    /// 视频与动图的时长，秒。
    public var duration: Double?
    public var capturedAt: Date?
    public var colorSpace: String?

    public init(pixelSize: PixelSize, frameCount: Int = 1, duration: Double? = nil, capturedAt: Date? = nil, colorSpace: String? = nil) {
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.duration = duration
        self.capturedAt = capturedAt
        self.colorSpace = colorSpace
    }
}

/// 要求输出的图像：设备像素尺寸、重采样滤镜和缩小后的锐化强度。
public struct DisplayTarget: Sendable, Hashable {
    public var pixelSize: PixelSize
    public var filter: ResampleFilter
    public var sharpen: Float

    public init(pixelSize: PixelSize, filter: ResampleFilter = .lanczos, sharpen: Float = 0) {
        self.pixelSize = pixelSize
        self.filter = filter
        self.sharpen = sharpen
    }
}

/// 渐进交付的阶段，按声明顺序越来越精确。
public enum RenditionQuality: Int, Sendable, Comparable {
    case placeholder, browse, exact, original

    public static func < (lhs: RenditionQuality, rhs: RenditionQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 已解码的图像。CGImage 不可变，可以跨线程传递。
public struct RenderedImage: @unchecked Sendable {
    public let image: CGImage
    public let quality: RenditionQuality

    public init(image: CGImage, quality: RenditionQuality) {
        self.image = image
        self.quality = quality
    }
}

/// 动图的帧，按需逐帧解码；播放节奏由前端驱动。
public protocol AnimatedFrameSource: Sendable {
    var frameCount: Int { get }
    func duration(at index: Int) -> Double
    func frame(at index: Int) async throws -> RenderedImage
}

/// 超大图的分块来源。`rect` 是原图像素坐标，`scale` 是输出相对原图的比例。
public protocol TiledImageSource: Sendable {
    var pixelSize: PixelSize { get }
    func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage
}
