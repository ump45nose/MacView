import CoreGraphics
import Foundation
import ImageIO
import MVFoundation
import Testing
@testable import MVMetadata

// MARK: - C1.1 写入、读回、无损校验与 EXIF 保留

@Test(arguments: ["public.jpeg", "public.tiff", "public.heic"])
func writeRatingAndTagsPreservesPixelsAndExif(_ uti: String) throws {
    let original = try makeTestImage(uti: uti, width: 128, height: 96, withRichExif: true)
    let originalDetails = try #require(XMPReader.details(fromHeader: original))
    #expect(originalDetails.cameraMake == "Canon")
    #expect(originalDetails.cameraModel == "EOS R5")
    #expect(originalDetails.capturedAt != nil)

    let rewritten = try XMPWriter.write(XMPFields(rating: 4, tags: ["精选", "写真"]), into: original)

    let fields = try #require(XMPReader.fields(fromHeader: rewritten))
    #expect(fields.rating == 4)
    #expect(fields.tags == ["精选", "写真"])

    // 验证原有 EXIF 保留
    let rewrittenDetails = try #require(XMPReader.details(fromHeader: rewritten))
    #expect(rewrittenDetails.cameraMake == originalDetails.cameraMake)
    #expect(rewrittenDetails.cameraModel == originalDetails.cameraModel)
    #expect(rewrittenDetails.capturedAt == originalDetails.capturedAt)
    #expect(rewrittenDetails.lens == originalDetails.lens)

    // 验证像素 / 扫描段无损
    if uti == "public.jpeg" {
        let origScan = try #require(XMPWriter.jpegScanSegment(in: original))
        let newScan = try #require(XMPWriter.jpegScanSegment(in: rewritten))
        #expect(origScan == newScan)
    } else {
        let origPixels = try renderRGBA(original)
        let newPixels = try renderRGBA(rewritten)
        #expect(origPixels == newPixels)
    }
}

// MARK: - C1.2 清除字段与单字段局部更新

@Test(arguments: ["public.jpeg", "public.tiff", "public.heic"])
func clearAndPartialUpdateFields(_ uti: String) throws {
    let original = try makeTestImage(uti: uti, width: 64, height: 64, withRichExif: true)
    let initial = try XMPWriter.write(XMPFields(rating: 5, tags: ["风景", "夜景"]), into: original)

    // 只改 rating，tags 不变
    let ratingOnly = try XMPWriter.write(XMPFields(rating: 3, tags: nil), into: initial)
    let afterRating = try #require(XMPReader.fields(fromHeader: ratingOnly))
    #expect(afterRating.rating == 3)
    #expect(afterRating.tags == ["风景", "夜景"])

    // 只改 tags，rating 不变
    let tagsOnly = try XMPWriter.write(XMPFields(rating: nil, tags: ["人像"]), into: ratingOnly)
    let afterTags = try #require(XMPReader.fields(fromHeader: tagsOnly))
    #expect(afterTags.rating == 3)
    #expect(afterTags.tags == ["人像"])

    // rating = 0 清除两个评分字段，tags 保留
    let clearedRating = try XMPWriter.write(XMPFields(rating: 0, tags: nil), into: tagsOnly)
    let afterClearRating = try #require(XMPReader.fields(fromHeader: clearedRating))
    #expect(afterClearRating.rating == nil)
    #expect(afterClearRating.tags == ["人像"])

    // 确认底层 XMP 中 xmp:Rating 和 MicrosoftPhoto:Rating 均已删除
    let source1 = try #require(CGImageSourceCreateWithData(clearedRating as CFData, nil))
    let meta1 = try #require(CGImageSourceCopyMetadataAtIndex(source1, 0, nil))
    #expect(CGImageMetadataCopyTagWithPath(meta1, nil, "xmp:Rating" as CFString) == nil)
    #expect(CGImageMetadataCopyTagWithPath(meta1, nil, "MicrosoftPhoto:Rating" as CFString) == nil)

    // tags = [] 清除 dc:subject，且保留原有 EXIF
    let clearedAll = try XMPWriter.write(XMPFields(rating: nil, tags: []), into: clearedRating)
    #expect(XMPReader.fields(fromHeader: clearedAll) == nil)

    let source2 = try #require(CGImageSourceCreateWithData(clearedAll as CFData, nil))
    if let meta2 = CGImageSourceCopyMetadataAtIndex(source2, 0, nil) {
        #expect(CGImageMetadataCopyTagWithPath(meta2, nil, "dc:subject" as CFString) == nil)
    }
    let detailsAfterClear = try #require(XMPReader.details(fromHeader: clearedAll))
    #expect(detailsAfterClear.cameraMake == "Canon")
    #expect(detailsAfterClear.cameraModel == "EOS R5")
}

// MARK: - C1.3 格式可写性识别与不可写格式报错

@Test func formatWritabilityAndUnsupportedWrite() throws {
    let jpeg = try makeTestImage(uti: "public.jpeg", width: 16, height: 16, withRichExif: false)
    let tiff = try makeTestImage(uti: "public.tiff", width: 16, height: 16, withRichExif: false)
    let heic = try makeTestImage(uti: "public.heic", width: 16, height: 16, withRichExif: false)
    let png = try makeTestImage(uti: "public.png", width: 16, height: 16, withRichExif: false)
    let gif = try makeTestImage(uti: "com.compuserve.gif", width: 16, height: 16, withRichExif: false)

    #expect(MetadataFormat.writability(fileName: "a.jpg", header: jpeg) == .writable)
    #expect(MetadataFormat.writability(fileName: "a.tiff", header: tiff) == .writable)
    #expect(MetadataFormat.writability(fileName: "a.heic", header: heic) == .writable)
    #expect(MetadataFormat.writability(fileName: "a.jpg", header: nil) == .writable)
    #expect(MetadataFormat.writability(fileName: "a.tif", header: nil) == .writable)
    #expect(MetadataFormat.writability(fileName: "a.heic", header: nil) == .writable)

    // 不可写格式（按头）
    guard case .unsupportedFormat = MetadataFormat.writability(fileName: "a.png", header: png) else {
        Issue.record("PNG 应为 unsupportedFormat")
        return
    }
    guard case .unsupportedFormat = MetadataFormat.writability(fileName: "a.gif", header: gif) else {
        Issue.record("GIF 应为 unsupportedFormat")
        return
    }
    // 伪装扩展名：头是 PNG 但文件名是 .jpg，仍按头判为 unsupportedFormat
    guard case .unsupportedFormat = MetadataFormat.writability(fileName: "fake.jpg", header: png) else {
        Issue.record("PNG 头配 .jpg 扩展名应按文件头判为 unsupportedFormat")
        return
    }

    // WebP、AVIF、MP4、ZIP 魔数与扩展名
    let webpHeader = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
    let avifHeader = Data([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66])
    let mp4Header = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
    let zipHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])

    for (name, header) in [
        ("a.png", png),
        ("a.gif", gif),
        ("a.webp", webpHeader),
        ("a.avif", avifHeader),
        ("a.mp4", mp4Header),
        ("a.zip", zipHeader),
    ] {
        guard case .unsupportedFormat = MetadataFormat.writability(fileName: name, header: header) else {
            Issue.record("\(name)（带头）应为 unsupportedFormat")
            continue
        }
        guard case .unsupportedFormat = MetadataFormat.writability(fileName: name, header: nil) else {
            Issue.record("\(name)（无头）应为 unsupportedFormat")
            continue
        }
    }

    // 对 PNG 调 write 抛 unsupportedFormat
    #expect(throws: MetadataError.unsupportedFormat("png")) {
        _ = try XMPWriter.write(XMPFields(rating: 5), into: png)
    }
}

// MARK: - C1.4 前 64 KB 读取、MicrosoftPhoto:Rating 换算与完整 ImageDetails

@Test func readsFieldsFromFirst64KB() throws {
    // 生成较大的高熵 JPEG（> 64 KB），验证只给前 64 KB 时仍能读出评分与标签
    let largeJpeg = try makeNoisyJPEG(width: 640, height: 480)
    #expect(largeJpeg.count > 64 * 1024)

    let tagged = try XMPWriter.write(XMPFields(rating: 4, tags: ["精选", "旅行"]), into: largeJpeg)
    let prefix64KB = Data(tagged.prefix(64 * 1024))
    #expect(prefix64KB.count == 64 * 1024)

    let fields = try #require(XMPReader.fields(fromHeader: prefix64KB))
    #expect(fields.rating == 4)
    #expect(fields.tags == ["精选", "旅行"])
}

@Test func readsMicrosoftPhotoRatingAndPrefersXMPRating() throws {
    let base = try makeTestImage(uti: "public.jpeg", width: 32, height: 32, withRichExif: false)

    // 只有 MicrosoftPhoto:Rating 时按规则换算
    let mapping: [(Int, Int?)] = [(0, nil), (1, 1), (25, 2), (50, 3), (75, 4), (99, 5)]
    for (msValue, expected) in mapping {
        let data = try injectCustomXMP(
            into: base,
            xmpRating: nil,
            microsoftPhotoRating: msValue
        )
        let fields = XMPReader.fields(fromHeader: data)
        #expect(fields?.rating == expected, "MicrosoftPhoto:Rating=\(msValue)")
    }

    // 同时存在时 xmp:Rating 优先
    let both = try injectCustomXMP(into: base, xmpRating: 2, microsoftPhotoRating: 99)
    #expect(XMPReader.fields(fromHeader: both)?.rating == 2)
}

@Test func readsFullImageDetails() throws {
    let jpeg = try makeTestImage(uti: "public.jpeg", width: 320, height: 240, withRichExif: true)
    let tagged = try XMPWriter.write(XMPFields(rating: 5, tags: ["作品"]), into: jpeg)

    let details = try #require(XMPReader.details(fromHeader: tagged))
    #expect(details.pixelSize == PixelSize(width: 320, height: 240))
    #expect(details.format == "JPEG")
    #expect(details.colorSpace != nil)
    #expect(details.cameraMake == "Canon")
    #expect(details.cameraModel == "EOS R5")
    #expect(details.lens == "RF50mm F1.2 L USM")
    #expect(details.focalLength == 50.0)
    #expect(details.aperture == 1.4)
    #expect(abs((details.exposureTime ?? 0) - 0.004) < 0.0001)
    #expect(details.iso == 400)
    #expect(details.capturedAt != nil)
    #expect(abs((details.latitude ?? 0) - 35.6762) < 0.0001)
    #expect(abs((details.longitude ?? 0) - (-139.6503)) < 0.0001)
    #expect(details.fields == XMPFields(rating: 5, tags: ["作品"]))
}

// MARK: - Test Image Builders

private func makeTestImage(uti: String, width: Int, height: Int, withRichExif: Bool) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw MetadataError.encodeFailed
    }

    // 绘制可区分图案，方便像素比对
    context.setFillColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1.0)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0.95, green: 0.35, blue: 0.2, alpha: 1.0)
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

    guard let image = context.makeImage() else { throw MetadataError.encodeFailed }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, uti as CFString, 1, nil) else {
        throw MetadataError.encodeFailed
    }

    var properties: [CFString: Any] = [:]
    if withRichExif {
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: "Canon",
            kCGImagePropertyTIFFModel: "EOS R5",
        ]
        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifLensModel: "RF50mm F1.2 L USM",
            kCGImagePropertyExifFocalLength: 50.0,
            kCGImagePropertyExifFNumber: 1.4,
            kCGImagePropertyExifExposureTime: 0.004,
            kCGImagePropertyExifISOSpeedRatings: [400],
            kCGImagePropertyExifDateTimeOriginal: "2025:06:15 14:30:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+08:00",
        ]
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 35.6762,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.6503,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]
    }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw MetadataError.encodeFailed
    }
    return data as Data
}

private func makeNoisyJPEG(width: Int, height: Int) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        pixels[i] = UInt8((state >> 24) & 0xFF)
        pixels[i + 1] = UInt8((state >> 16) & 0xFF)
        pixels[i + 2] = UInt8((state >> 8) & 0xFF)
        pixels[i + 3] = 255
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let cgImage: CGImage = try pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let img = context.makeImage() else {
            throw MetadataError.encodeFailed
        }
        return img
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
        throw MetadataError.encodeFailed
    }
    CGImageDestinationAddImage(
        destination,
        cgImage,
        [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { throw MetadataError.encodeFailed }
    return output as Data
}

private func injectCustomXMP(into original: Data, xmpRating: Int?, microsoftPhotoRating: Int?) throws -> Data {
    guard let source = CGImageSourceCreateWithData(original as CFData, nil),
          let uti = CGImageSourceGetType(source)
    else { throw MetadataError.encodeFailed }

    let metadata = CGImageMetadataCreateMutable()
    CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, nil)
    CGImageMetadataRegisterNamespaceForPrefix(metadata, XMPReader.microsoftPhotoNamespace as CFString, XMPReader.microsoftPhotoPrefix as CFString, nil)

    if let xmpRating,
       let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "Rating" as CFString, .string, "\(xmpRating)" as CFString) {
        CGImageMetadataSetTagWithPath(metadata, nil, "xmp:Rating" as CFString, tag)
    }
    if let microsoftPhotoRating,
       let tag = CGImageMetadataTagCreate(XMPReader.microsoftPhotoNamespace as CFString, XMPReader.microsoftPhotoPrefix as CFString, "Rating" as CFString, .string, "\(microsoftPhotoRating)" as CFString) {
        CGImageMetadataSetTagWithPath(metadata, nil, "MicrosoftPhoto:Rating" as CFString, tag)
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, uti, 1, nil) else {
        throw MetadataError.encodeFailed
    }
    let options: [CFString: Any] = [
        kCGImageDestinationMetadata: metadata,
        kCGImageDestinationMergeMetadata: true,
    ]
    var error: Unmanaged<CFError>?
    let ok = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
    error?.release()
    guard ok else { throw MetadataError.encodeFailed }
    return output as Data
}

private func renderRGBA(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw MetadataError.encodeFailed }

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var buffer = Data(count: bytesPerRow * height)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let ok: Bool = buffer.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { throw MetadataError.encodeFailed }
    return buffer
}
