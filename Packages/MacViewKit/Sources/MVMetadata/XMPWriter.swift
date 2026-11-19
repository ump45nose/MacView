import CoreGraphics
import Foundation
import ImageIO
import MVFoundation

public enum XMPWriter {
    /// 在内存里改写，返回新文件字节；校验失败抛 `MetadataError.verificationFailed`。
    public static func write(_ change: XMPFields, into original: Data) throws(MetadataError) -> Data {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else {
            throw .unsupportedFormat("unknown")
        }
        guard let uti = CGImageSourceGetType(source) as String?, MetadataFormat.isWritableUTI(uti) else {
            let uti = CGImageSourceGetType(source) as String?
            throw .unsupportedFormat(MetadataFormat.formatLabel(forUTI: uti))
        }

        let mutableMetadata: CGMutableImageMetadata
        if let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            mutableMetadata = copy
        } else {
            mutableMetadata = CGImageMetadataCreateMutable()
        }

        CGImageMetadataRegisterNamespaceForPrefix(
            mutableMetadata,
            kCGImageMetadataNamespaceXMPBasic,
            kCGImageMetadataPrefixXMPBasic,
            nil
        )
        CGImageMetadataRegisterNamespaceForPrefix(
            mutableMetadata,
            kCGImageMetadataNamespaceDublinCore,
            kCGImageMetadataPrefixDublinCore,
            nil
        )
        CGImageMetadataRegisterNamespaceForPrefix(
            mutableMetadata,
            XMPReader.microsoftPhotoNamespace as CFString,
            XMPReader.microsoftPhotoPrefix as CFString,
            nil
        )

        var removesTags = false

        if let rating = change.rating {
            if rating <= 0 {
                removesTags = true
                CGImageMetadataRemoveTagWithPath(mutableMetadata, nil, "xmp:Rating" as CFString)
                CGImageMetadataRemoveTagWithPath(mutableMetadata, nil, "MicrosoftPhoto:Rating" as CFString)
                removeTags(in: mutableMetadata, namespace: XMPReader.microsoftPhotoNamespace, name: "Rating")
            } else {
                let clamped = min(5, max(1, rating))
                guard let xmpTag = CGImageMetadataTagCreate(
                    kCGImageMetadataNamespaceXMPBasic,
                    kCGImageMetadataPrefixXMPBasic,
                    "Rating" as CFString,
                    .string,
                    "\(clamped)" as CFString
                ),
                let msTag = CGImageMetadataTagCreate(
                    XMPReader.microsoftPhotoNamespace as CFString,
                    XMPReader.microsoftPhotoPrefix as CFString,
                    "Rating" as CFString,
                    .string,
                    "\(XMPReader.microsoftPhotoValue(forRating: clamped))" as CFString
                ) else {
                    throw .encodeFailed
                }
                guard CGImageMetadataSetTagWithPath(mutableMetadata, nil, "xmp:Rating" as CFString, xmpTag),
                      CGImageMetadataSetTagWithPath(mutableMetadata, nil, "MicrosoftPhoto:Rating" as CFString, msTag)
                else {
                    throw .encodeFailed
                }
            }
        }

        if let tags = change.tags {
            CGImageMetadataRemoveTagWithPath(mutableMetadata, nil, "dc:subject" as CFString)
            if tags.isEmpty {
                removesTags = true
            } else {
                let itemTags: [CGImageMetadataTag] = tags.compactMap { item in
                    CGImageMetadataTagCreate(
                        kCGImageMetadataNamespaceDublinCore,
                        kCGImageMetadataPrefixDublinCore,
                        "subject" as CFString,
                        .string,
                        item as CFString
                    )
                }
                guard itemTags.count == tags.count,
                      let subjectTag = CGImageMetadataTagCreate(
                          kCGImageMetadataNamespaceDublinCore,
                          kCGImageMetadataPrefixDublinCore,
                          "subject" as CFString,
                          .arrayUnordered,
                          itemTags as CFArray
                      ),
                      CGImageMetadataSetTagWithPath(mutableMetadata, nil, "dc:subject" as CFString, subjectTag)
                else {
                    throw .encodeFailed
                }
            }
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, uti as CFString, 1, nil) else {
            throw .encodeFailed
        }

        // 删除标签时关闭 MergeMetadata，避免 ImageIO 把原文件的旧标签重新合回；
        // mutableMetadata 本身已从原文件完整拷贝，故原有 EXIF/TIFF/GPS 等依然完整保留。
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: mutableMetadata,
            kCGImageDestinationMergeMetadata: !removesTags,
        ]
        var copyError: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &copyError)
        copyError?.release()
        guard copied else {
            throw .encodeFailed
        }

        let result = output as Data
        try verify(original: original, rewritten: result, uti: uti)
        return result
    }

    // MARK: - Verification

    private static func verify(original: Data, rewritten: Data, uti: String) throws(MetadataError) {
        if uti == "public.jpeg" {
            guard let originalScan = jpegScanSegment(in: original),
                  let rewrittenScan = jpegScanSegment(in: rewritten),
                  originalScan == rewrittenScan
            else {
                throw .verificationFailed
            }
            return
        }

        guard let originalPixels = decodedFirstFramePixels(from: original),
              let rewrittenPixels = decodedFirstFramePixels(from: rewritten),
              originalPixels.width == rewrittenPixels.width,
              originalPixels.height == rewrittenPixels.height,
              originalPixels.bytes == rewrittenPixels.bytes
        else {
            throw .verificationFailed
        }
    }

    /// 提取 JPEG 第一个 SOS（FF DA）到 EOI（FF D9）的扫描段字节。
    static func jpegScanSegment(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var offset = 2
        var sosOffset: Int?

        while offset < count {
            // 寻找下一个 marker 前缀 0xFF
            guard bytes[offset] == 0xFF else { return nil }
            let markerStart = offset
            while offset < count && bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < count else { return nil }
            let marker = bytes[offset]
            offset += 1

            if marker == 0xDA { // SOS
                sosOffset = markerStart
                break
            }
            if marker == 0xD9 { // EOI before SOS
                return nil
            }
            // 无长度字段的 standalone marker（RST0–RST7, TEM）
            if (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                continue
            }
            guard offset + 2 <= count else { return nil }
            let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            guard length >= 2, offset + length <= count else { return nil }
            offset += length
        }

        guard let start = sosOffset else { return nil }

        // 从文件尾部向前找 EOI（FF D9）
        var eoiEnd: Int?
        var i = count - 2
        while i >= start {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD9 {
                eoiEnd = i + 2
                break
            }
            i -= 1
        }
        guard let end = eoiEnd, end > start else { return nil }
        return Data(bytes[start..<end])
    }

    private struct DecodedPixels {
        let width: Int
        let height: Int
        let bytes: Data
    }

    private static func decodedFirstFramePixels(from data: Data) -> DecodedPixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        let drawn: Bool = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drawn else { return nil }
        return DecodedPixels(width: width, height: height, bytes: buffer)
    }

    private static func removeTags(in metadata: CGMutableImageMetadata, namespace: String, name: String) {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return }
        for tag in tags {
            let tagNS = CGImageMetadataTagCopyNamespace(tag) as String?
            let tagName = CGImageMetadataTagCopyName(tag) as String?
            if tagNS == namespace && tagName == name,
               let prefix = CGImageMetadataTagCopyPrefix(tag) as String? {
                CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
            }
        }
    }
}
