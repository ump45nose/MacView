// MVMedia：探测、解码与重采样、动图帧、视频封面、渲染件编码。职责与契约见 docs/architecture.md §2、§4。
import CoreGraphics
import Foundation
import IOSurface
import MVFoundation

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

/// 已解码的图像。CGImage 和 IOSurface 都可以跨线程传递。
public struct RenderedImage: @unchecked Sendable {
    public let image: CGImage
    public let quality: RenditionQuality
    /// `image` 的像素所在的 IOSurface，带色彩空间标记。设为 CALayer.contents 时用它，提交时不复制；Mock 的图像没有。
    public let surface: IOSurface?

    public init(image: CGImage, quality: RenditionQuality, surface: IOSurface? = nil) {
        self.image = image
        self.quality = quality
        self.surface = surface
    }
}

/// 动图的帧，按需逐帧解码；播放节奏由前端驱动。
public protocol AnimatedFrameSource: Sendable {
    var frameCount: Int { get }
    /// 文件里记录的循环次数（GIF 的 NETSCAPE 扩展、APNG 的 num_plays、WebP 的 loop count），0 表示无限循环；没有记录时为 1。
    var loopCount: Int { get }
    func duration(at index: Int) -> Double
    func frame(at index: Int) async throws -> RenderedImage
}

/// 超大图的分块来源。`rect` 是原图像素坐标，`scale` 是输出相对原图的比例。
public protocol TiledImageSource: Sendable {
    var pixelSize: PixelSize { get }
    func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage
}

/// 媒体处理的失败。
public enum MediaError: Error, Sendable, Equatable {
    /// ImageIO 或 AVFoundation 不认识的格式。
    case unsupported
    /// 数据损坏或解码失败，附原因。
    case decodeFailed(String)
    /// 图太大，不能整张解码，要用 `TiledImageSource`。
    case requiresTiling(PixelSize)
}

/// 探测的结果：得到元数据，或者需要更长的文件头。
public enum ProbeResult: Sendable, Equatable {
    case metadata(ImageMetadata)
    /// 需要至少这么多字节；nil 表示需要整个文件，例如动图要读完全部帧才知道帧数和时长。
    case needsMoreData(Int?)
}
