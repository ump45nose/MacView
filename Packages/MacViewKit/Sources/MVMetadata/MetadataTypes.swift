import Foundation
import ImageIO
import MVFoundation

/// XMP 中可编辑的评分与标签字段。
public struct XMPFields: Sendable, Hashable, Codable {
    /// nil 表示不改这一项；写入时 0 表示清除评分，1–5 表示星级。
    public var rating: Int?
    /// nil 表示不改这一项；写入时 [] 表示清除标签。
    public var tags: [String]?

    public init(rating: Int? = nil, tags: [String]? = nil) {
        self.rating = rating
        self.tags = tags
    }
}

public enum MetadataWritability: Sendable, Equatable {
    case writable
    case unsupportedFormat(String)
    case insideArchive
}

public enum MetadataError: Error, Sendable, Equatable {
    case unsupportedFormat(String)
    case verificationFailed
    case encodeFailed
}

public struct ImageDetails: Sendable, Hashable {
    public var pixelSize: PixelSize?
    public var format: String?
    public var colorSpace: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var exposureTime: Double?
    public var iso: Int?
    public var capturedAt: Date?
    public var latitude: Double?
    public var longitude: Double?
    public var fields: XMPFields?

    public init(
        pixelSize: PixelSize? = nil,
        format: String? = nil,
        colorSpace: String? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lens: String? = nil,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        exposureTime: Double? = nil,
        iso: Int? = nil,
        capturedAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        fields: XMPFields? = nil
    ) {
        self.pixelSize = pixelSize
        self.format = format
        self.colorSpace = colorSpace
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.focalLength = focalLength
        self.aperture = aperture
        self.exposureTime = exposureTime
        self.iso = iso
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.fields = fields
    }
}

public enum MetadataFormat {
    /// 按文件头识别 JPEG、TIFF、HEIC；无头时按扩展名。
    public static func writability(fileName: String, header: Data?) -> MetadataWritability {
        if let header, !header.isEmpty {
            if let detected = detectFromHeader(header) {
                return detected
            }
        }
        return writabilityFromExtension(fileName)
    }

    static func isWritableUTI(_ uti: String) -> Bool {
        uti == "public.jpeg" || uti == "public.tiff" || uti == "public.heic" || uti == "public.heif"
    }

    static func displayFormat(forUTI uti: String) -> String {
        switch uti {
        case "public.jpeg": "JPEG"
        case "public.tiff": "TIFF"
        case "public.heic", "public.heif": "HEIC"
        case "public.png": "PNG"
        case "com.compuserve.gif": "GIF"
        case "org.webmproject.webp": "WebP"
        case "public.avif": "AVIF"
        default: uti
        }
    }

    static func formatLabel(forUTI uti: String?) -> String {
        guard let uti else { return "unknown" }
        switch uti {
        case "public.jpeg": return "jpeg"
        case "public.tiff": return "tiff"
        case "public.heic", "public.heif": return "heic"
        case "public.png": return "png"
        case "com.compuserve.gif": return "gif"
        case "org.webmproject.webp": return "webp"
        case "public.avif": return "avif"
        default: return uti
        }
    }

    private static func detectFromHeader(_ data: Data) -> MetadataWritability? {
        let bytes = [UInt8](data.prefix(32))
        // ZIP 魔数
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B,
           (bytes[2] == 0x03 && bytes[3] == 0x04)
            || (bytes[2] == 0x05 && bytes[3] == 0x06)
            || (bytes[2] == 0x07 && bytes[3] == 0x08) {
            return .unsupportedFormat("zip")
        }
        // ImageIO 识别图片格式（涵盖 JPEG、TIFF、HEIC、PNG、GIF、WebP、AVIF）
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        if let uti = CGImageSourceGetType(source) as String? {
            return isWritableUTI(uti) ? .writable : .unsupportedFormat(formatLabel(forUTI: uti))
        }
        // ISO BMFF 容器（区分 HEIC / AVIF / MP4）
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { // "ftyp"
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            switch brand {
            case "heic", "heix", "hevc", "hevx":
                return .writable
            case "avif", "avis":
                return .unsupportedFormat("avif")
            case "isom", "iso2", "mp41", "mp42", "M4V ", "M4A ", "qt  ", "avc1":
                return .unsupportedFormat("mp4")
            default:
                return .unsupportedFormat(brand.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func writabilityFromExtension(_ fileName: String) -> MetadataWritability {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "jpe", "jfif", "tif", "tiff", "heic", "heif":
            return .writable
        case "":
            return .unsupportedFormat("unknown")
        default:
            return .unsupportedFormat(ext)
        }
    }
}
