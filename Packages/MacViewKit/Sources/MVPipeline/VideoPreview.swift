import MVMedia

/// 画廊和播放器共用的视频预览时间线。
public enum VideoPreview {
    public static let frameCount = 20
    public static let longSide = 640

    public static func time(of index: Int, duration: Double) -> Double {
        (Double(index) + 0.5) / Double(frameCount) * duration
    }

    public static func index(at fraction: Double) -> Int {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return frameCount - 1 }
        return Int(fraction * Double(frameCount))
    }
}

public struct VideoPreviewFrame: Sendable {
    public var index: Int
    public var time: Double
    public var duration: Double
    public var image: RenderedImage

    public init(index: Int, time: Double, duration: Double, image: RenderedImage) {
        self.index = index
        self.time = time
        self.duration = duration
        self.image = image
    }
}
