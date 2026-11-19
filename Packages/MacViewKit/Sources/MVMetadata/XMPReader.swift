import Foundation
import ImageIO
import MVFoundation

public enum XMPReader {
    static let microsoftPhotoNamespace = "http://ns.microsoft.com/photo/1.0/"
    static let microsoftPhotoPrefix = "MicrosoftPhoto"

    /// 从前 64 KB（或完整头数据）读取；xmp:Rating 优先，没有就换算 MicrosoftPhoto:Rating（1→1、25→2、50→3、75→4、99→5，0→nil）；dc:subject。
    public static func fields(fromHeader data: Data) -> XMPFields? {
        guard !data.isEmpty else { return nil }
        if let metadata = metadataFromImageSource(data) {
            if let fields = extractFields(from: metadata) {
                return fields
            }
        }
        if let metadata = metadataFromEmbeddedXMP(data) {
            return extractFields(from: metadata)
        }
        return nil
    }

    public static func details(fromHeader data: Data) -> ImageDetails? {
        guard !data.isEmpty else { return nil }
        let source = makeImageSource(from: data)
        let uti = source.flatMap { CGImageSourceGetType($0) as String? }
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let xmpFields = source.flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }.flatMap { extractFields(from: $0) }
            ?? metadataFromEmbeddedXMP(data).flatMap { extractFields(from: $0) }

        guard uti != nil || properties != nil || xmpFields != nil else { return nil }

        var pixelSize: PixelSize?
        if let properties,
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            pixelSize = orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
        }

        let colorSpace = properties.flatMap {
            $0[kCGImagePropertyProfileName] as? String ?? $0[kCGImagePropertyColorModel] as? String
        }
        let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifAux = properties?[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        let gps = properties?[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let cameraMake = trimmedString(tiff?[kCGImagePropertyTIFFMake])
        let cameraModel = trimmedString(tiff?[kCGImagePropertyTIFFModel])
        let lens = trimmedString(exif?[kCGImagePropertyExifLensModel])
            ?? trimmedString(exifAux?[kCGImagePropertyExifAuxLensModel])
        let focalLength = doubleValue(exif?[kCGImagePropertyExifFocalLength])
        let aperture = doubleValue(exif?[kCGImagePropertyExifFNumber])
        let exposureTime = doubleValue(exif?[kCGImagePropertyExifExposureTime])
        let iso = isoValue(exif?[kCGImagePropertyExifISOSpeedRatings])
        let capturedAt = exif.flatMap { parseCapturedAt($0) }
        let (latitude, longitude) = parseGPS(gps)

        return ImageDetails(
            pixelSize: pixelSize,
            format: uti.map { MetadataFormat.displayFormat(forUTI: $0) },
            colorSpace: colorSpace,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lens: lens,
            focalLength: focalLength,
            aperture: aperture,
            exposureTime: exposureTime,
            iso: iso,
            capturedAt: capturedAt,
            latitude: latitude,
            longitude: longitude,
            fields: xmpFields
        )
    }

    // MARK: - Internal Helpers

    private static func makeImageSource(from data: Data) -> CGImageSource? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetType(source) != nil {
            return source
        }
        let incremental = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(incremental, data as CFData, false)
        return CGImageSourceGetType(incremental) != nil ? incremental : nil
    }

    private static func metadataFromImageSource(_ data: Data) -> CGImageMetadata? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            return metadata
        }
        let incremental = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(incremental, data as CFData, false)
        return CGImageSourceCopyMetadataAtIndex(incremental, 0, nil)
    }

    /// 兜底：当截断的前 64 KB 无法被 ImageIO 完整构建元数据树时，直接提取内嵌 XMP XML 数据包解析。
    private static func metadataFromEmbeddedXMP(_ data: Data) -> CGImageMetadata? {
        let startMarker = Data("<x:xmpmeta".utf8)
        let endMarker = Data("</x:xmpmeta>".utf8)
        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker, in: startRange.lowerBound..<data.endIndex)
        else { return nil }
        let packet = data[startRange.lowerBound..<endRange.upperBound]
        return CGImageMetadataCreateFromXMPData(Data(packet) as CFData)
    }

    private static func extractFields(from metadata: CGImageMetadata) -> XMPFields? {
        let rating = extractRating(from: metadata)
        let tags = extractTags(from: metadata)
        guard rating != nil || tags != nil else { return nil }
        return XMPFields(rating: rating, tags: tags)
    }

    private static func extractRating(from metadata: CGImageMetadata) -> Int? {
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString),
           let raw = intValue(CGImageMetadataTagCopyValue(tag)) {
            if raw >= 1 && raw <= 5 { return raw }
            if raw == 0 { return nil }
        }
        if let tag = findTag(in: metadata, namespace: microsoftPhotoNamespace, name: "Rating")
            ?? CGImageMetadataCopyTagWithPath(metadata, nil, "MicrosoftPhoto:Rating" as CFString),
           let raw = intValue(CGImageMetadataTagCopyValue(tag)) {
            return ratingFromMicrosoftPhoto(raw)
        }
        return nil
    }

    private static func extractTags(from metadata: CGImageMetadata) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString) else {
            return nil
        }
        guard let value = CGImageMetadataTagCopyValue(tag) else {
            return []
        }
        if let array = value as? [Any] {
            var result: [String] = []
            for element in array {
                if let str = element as? String {
                    result.append(str)
                } else if CFGetTypeID(element as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                    let subTag = element as! CGImageMetadataTag
                    if let str = CGImageMetadataTagCopyValue(subTag) as? String {
                        result.append(str)
                    }
                }
            }
            return result
        }
        if let single = value as? String {
            return single.isEmpty ? [] : [single]
        }
        return []
    }

    private static func findTag(in metadata: CGImageMetadata, namespace: String, name: String) -> CGImageMetadataTag? {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return nil }
        for tag in tags {
            let tagNS = CGImageMetadataTagCopyNamespace(tag) as String?
            let tagName = CGImageMetadataTagCopyName(tag) as String?
            if tagNS == namespace && tagName == name {
                return tag
            }
        }
        return nil
    }

    static func ratingFromMicrosoftPhoto(_ value: Int) -> Int? {
        switch value {
        case ...0: nil
        case 1...12: 1
        case 13...37: 2
        case 38...62: 3
        case 63...87: 4
        default: 5
        }
    }

    static func microsoftPhotoValue(forRating rating: Int) -> Int {
        switch rating {
        case 1: 1
        case 2: 25
        case 3: 50
        case 4: 75
        case 5: 99
        default: 0
        }
    }

    private static func intValue(_ value: CFTypeRef?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed) { return Int(d.rounded()) }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func isoValue(_ value: Any?) -> Int? {
        if let array = value as? [NSNumber], let first = array.first {
            return first.intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseCapturedAt(_ exif: [CFString: Any]) -> Date? {
        let text: String
        let offsetKey: CFString
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            text = original
            offsetKey = kCGImagePropertyExifOffsetTimeOriginal
        } else if let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            text = digitized
            offsetKey = kCGImagePropertyExifOffsetTimeDigitized
        } else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[offsetKey] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return formatter.date(from: text + offset)
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    private static func parseGPS(_ gps: [CFString: Any]?) -> (Double?, Double?) {
        guard let gps else { return (nil, nil) }
        var latitude = doubleValue(gps[kCGImagePropertyGPSLatitude])
        if let lat = latitude, (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" {
            latitude = -abs(lat)
        }
        var longitude = doubleValue(gps[kCGImagePropertyGPSLongitude])
        if let lon = longitude, (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" {
            longitude = -abs(lon)
        }
        return (latitude, longitude)
    }
}
