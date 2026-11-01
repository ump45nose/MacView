import Foundation

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
