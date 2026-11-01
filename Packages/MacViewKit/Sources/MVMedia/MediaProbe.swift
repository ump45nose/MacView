import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MVFoundation

/// 从内存中的文件头得到元数据。不做 I/O：调用方先读 `initialHeaderLength` 字节，
/// 结果为 `needsMoreData` 时按要求再读，直到得到元数据。
public enum MediaProbe {
    public static let initialHeaderLength = 64 << 10
    /// 文件头超过这个长度仍得不到尺寸时，改要整个文件。
    public static let headerLimit = 1 << 20

    /// - Parameter isComplete: `data` 是否是整个文件。
    public static func image(_ data: Data, isComplete: Bool) throws(MediaError) -> ProbeResult {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, isComplete)
        guard let type = CGImageSourceGetType(source) as String? else {
            if isComplete || data.count >= headerLimit { throw .unsupported }
            return .needsMoreData(nextLength(after: data.count))
        }
        // 动图要读完全部帧才知道帧数和时长；静态的 PNG、WebP 在文件头里就能确定不是动图。
        if !isComplete, mayBeAnimated(type: type, header: data) {
            return .needsMoreData(nil)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            if isComplete { throw .decodeFailed("读不出尺寸") }
            return .needsMoreData(nextLength(after: data.count))
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        var metadata = ImageMetadata(
            pixelSize: orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height),
            capturedAt: capturedAt(properties),
            colorSpace: properties[kCGImagePropertyProfileName] as? String ?? properties[kCGImagePropertyColorModel] as? String
        )
        let count = CGImageSourceGetCount(source)
        if isComplete, count > 1 {
            metadata.frameCount = count
            metadata.duration = (0..<count).reduce(0) { $0 + FrameTiming.delay(source, at: $1) }
        }
        return .metadata(metadata)
    }

    /// 视频的时长和显示尺寸（按轨道变换换算）。网络卷上的 `asset` 来自 MVIO 的读取桥。
    public static func video(_ asset: AVAsset) async throws -> ImageMetadata {
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unsupported }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        return ImageMetadata(
            pixelSize: PixelSize(width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded())),
            duration: duration.seconds
        )
    }

    private static func nextLength(after length: Int) -> Int? {
        length >= headerLimit ? nil : min(headerLimit, max(initialHeaderLength, length * 2))
    }

    /// GIF 的帧数只能从头数到尾；PNG 看 IDAT 之前有没有 acTL，WebP 看 VP8X 的动画标志。
    static func mayBeAnimated(type: String, header: Data) -> Bool {
        switch type {
        case "com.compuserve.gif": true
        case "public.png": pngHasAnimationControl(header)
        case "org.webmproject.webp": webpHasAnimationFlag(header)
        default: false
        }
    }

    private static func pngHasAnimationControl(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(headerLimit))
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            if type == "acTL" { return true }
            if type == "IDAT" { return false }
            offset += 12 + length
        }
        // 文件头里还没到 IDAT：保守地当作可能是动图。
        return true
    }

    /// RIFF 头 12 字节之后是 VP8X 块时，标志字节的第 2 位表示动画。
    private static func webpHasAnimationFlag(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(21))
        guard bytes.count == 21 else { return true }
        return String(decoding: bytes[12..<16], as: UTF8.self) == "VP8X" && bytes[20] & 0x02 != 0
    }

    /// EXIF 的原始拍摄时间；有时区偏移时按偏移换算，没有时按本机时区。
    private static func capturedAt(_ properties: [CFString: Any]) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return formatter.date(from: text + offset)
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// 动图各帧的时长。
enum FrameTiming {
    /// 不超过 10 ms 的时长按 100 ms 处理，与浏览器一致：很多 GIF 把 0 写成“尽快”，原样播放会过快。
    static let minimumDelay = 0.011
    static let defaultDelay = 0.1

    static func delay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in keys {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? values[clamped] as? Double ?? 0
            return delay < minimumDelay ? defaultDelay : delay
        }
        return defaultDelay
    }

    static func loopCount(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ]
        for (dictionary, key) in keys {
            // 没有循环扩展的动图只播放一次。
            if let values = properties[dictionary] as? [CFString: Any] { return values[key] as? Int ?? 1 }
        }
        return 1
    }
}
