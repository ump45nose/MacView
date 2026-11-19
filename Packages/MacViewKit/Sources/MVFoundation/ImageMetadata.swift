import Foundation

public struct ImageMetadata: Sendable, Codable, Hashable {
    /// 已按 EXIF 方向换算。
    public var pixelSize: PixelSize
    public var frameCount: Int
    /// 视频与动图的时长，秒。
    public var duration: Double?
    public var capturedAt: Date?
    public var colorSpace: String?
    /// 0–5，nil 表示文件里没有。
    public var rating: Int?
    /// nil 表示格式不带 XMP 或没读到，[] 表示读到了但为空。
    public var tags: [String]?

    public init(
        pixelSize: PixelSize,
        frameCount: Int = 1,
        duration: Double? = nil,
        capturedAt: Date? = nil,
        colorSpace: String? = nil,
        rating: Int? = nil,
        tags: [String]? = nil
    ) {
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.duration = duration
        self.capturedAt = capturedAt
        self.colorSpace = colorSpace
        self.rating = rating
        self.tags = tags
    }
}
