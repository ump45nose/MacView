import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MVFoundation

/// 夹具用的合成图：按标题取色的色带、网格、圆和居中的标题。内容只由参数决定。
enum FixtureArt {
    enum Pixels {
        case rgb, rgba, displayP3, gray, cmyk, rgb16
    }

    /// `phase`（0–1）给动图和视频的帧画一条移动的竖条。
    static func image(_ title: String, size: PixelSize, pixels: Pixels = .rgb, phase: Double? = nil) throws -> CGImage {
        let context = try makeContext(size, pixels)
        draw(title, in: context, size: size, transparentMargin: pixels == .rgba, phase: phase)
        guard let image = context.makeImage() else { throw FixtureError("无法生成 \(size.width)×\(size.height) 的图") }
        return image
    }

    static func draw(_ title: String, in context: CGContext, size: PixelSize, transparentMargin: Bool = false, phase: Double? = nil) {
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        let short = min(width, height)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: transparentMargin ? short * 0.1 : 0, dy: transparentMargin ? short * 0.1 : 0)
        let hue = Double(title.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } % 360) / 360

        let bands = 8
        let bandHeight = canvas.height / CGFloat(bands)
        for band in 0..<bands {
            context.setFillColor(color(hue: hue + Double(band) * 0.04, saturation: 0.5, brightness: 0.96 - Double(band) * 0.05))
            context.fill(CGRect(x: canvas.minX, y: canvas.maxY - bandHeight * CGFloat(band + 1), width: canvas.width, height: bandHeight))
        }

        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        context.setLineWidth(max(1, short / 300))
        let step = short / 8
        for x in stride(from: canvas.minX + step, to: canvas.maxX, by: step) {
            context.strokeLineSegments(between: [CGPoint(x: x, y: canvas.minY), CGPoint(x: x, y: canvas.maxY)])
        }
        for y in stride(from: canvas.minY + step, to: canvas.maxY, by: step) {
            context.strokeLineSegments(between: [CGPoint(x: canvas.minX, y: y), CGPoint(x: canvas.maxX, y: y)])
        }

        context.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 1))
        context.setLineWidth(max(1, short / 80))
        context.strokeEllipse(in: CGRect(x: canvas.midX - short * 0.3, y: canvas.midY - short * 0.3, width: short * 0.6, height: short * 0.6))

        if let phase {
            let bar = max(2, canvas.width / 16)
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 0.8))
            context.fill(CGRect(x: canvas.minX + (canvas.width - bar) * phase, y: canvas.minY, width: bar, height: canvas.height * 0.12))
        }

        drawText(title, in: context, center: CGPoint(x: canvas.midX, y: canvas.midY + short * 0.04), fontSize: short * 0.09)
        drawText("\(size.width)×\(size.height)", in: context, center: CGPoint(x: canvas.midX, y: canvas.midY - short * 0.08), fontSize: short * 0.06)
    }

    /// 方向夹具：直立时左上红、右上绿、左下蓝、右下黄，中间写方向值。
    /// 像素按 `orientation` 的逆变换存放，正确处理 EXIF 方向后，八张图看起来与方向 1 相同。
    static func orientation(_ orientation: Int, upright size: PixelSize) throws -> CGImage {
        let upright = try makeContext(size, .rgb)
        let width = CGFloat(size.width)
        let height = CGFloat(size.height)
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: width / 2, height: height / 2), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            upright.setFillColor(color)
            upright.fill(rect)
        }
        let radius = min(width, height) * 0.18
        upright.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        upright.fillEllipse(in: CGRect(x: width / 2 - radius, y: height / 2 - radius, width: radius * 2, height: radius * 2))
        drawText("\(orientation)", in: upright, center: CGPoint(x: width / 2, y: height / 2), fontSize: radius * 1.2)

        let transposed = orientation >= 5
        let stored = PixelSize(width: transposed ? size.height : size.width, height: transposed ? size.width : size.height)
        let target = try makeContext(stored, .rgb)
        guard let source = upright.data?.assumingMemoryBound(to: UInt32.self), let destination = target.data?.assumingMemoryBound(to: UInt32.self) else {
            throw FixtureError("无法访问位图数据")
        }
        let sourceRow = upright.bytesPerRow / 4
        let targetRow = target.bytesPerRow / 4
        for y in 0..<stored.height {
            for x in 0..<stored.width {
                let (displayX, displayY) = displayed(x: x, y: y, width: stored.width, height: stored.height, orientation: orientation)
                destination[y * targetRow + x] = source[displayY * sourceRow + displayX]
            }
        }
        guard let image = target.makeImage() else { throw FixtureError("无法生成方向 \(orientation) 的图") }
        return image
    }

    /// 存放的像素 (x, y) 在显示时的位置，坐标原点在左上角；`width`、`height` 是存放的尺寸。
    static func displayed(x: Int, y: Int, width: Int, height: Int, orientation: Int) -> (Int, Int) {
        switch orientation {
        case 2: (width - 1 - x, y)
        case 3: (width - 1 - x, height - 1 - y)
        case 4: (x, height - 1 - y)
        case 5: (y, x)
        case 6: (height - 1 - y, x)
        case 7: (height - 1 - y, width - 1 - x)
        case 8: (y, width - 1 - x)
        default: (x, y)
        }
    }

    private static func makeContext(_ size: PixelSize, _ pixels: Pixels) throws -> CGContext {
        let space: CGColorSpace?
        var bitsPerComponent = 8
        var alpha = CGImageAlphaInfo.noneSkipLast
        switch pixels {
        case .rgb:
            space = CGColorSpace(name: CGColorSpace.sRGB)
        case .rgba:
            space = CGColorSpace(name: CGColorSpace.sRGB)
            alpha = .premultipliedLast
        case .displayP3:
            space = CGColorSpace(name: CGColorSpace.displayP3)
        case .gray:
            space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
            alpha = .none
        case .cmyk:
            space = CGColorSpace(name: CGColorSpace.genericCMYK)
            alpha = .none
        case .rgb16:
            space = CGColorSpace(name: CGColorSpace.sRGB)
            bitsPerComponent = 16
        }
        guard let space, let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue
        ) else {
            throw FixtureError("无法创建 \(size.width)×\(size.height) 的 \(pixels) 位图")
        }
        return context
    }

    private static func drawText(_ text: String, in context: CGContext, center: CGPoint, fontSize: CGFloat) {
        guard fontSize >= 4 else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }

    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let hue = hue.truncatingRemainder(dividingBy: 1) * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(hue) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let base = brightness - chroma
        return CGColor(srgbRed: red + base, green: green + base, blue: blue + base, alpha: 1)
    }
}

/// 用 ImageIO 编码；WebP 用 Homebrew 的 cwebp、img2webp。
enum FixtureEncoder {
    static func encode(_ images: [CGImage], type: String, file: [CFString: Any] = [:], frames: [[CFString: Any]] = []) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else {
            throw FixtureError("ImageIO 不能写 \(type)")
        }
        if !file.isEmpty {
            CGImageDestinationSetProperties(destination, file as CFDictionary)
        }
        for (index, image) in images.enumerated() {
            CGImageDestinationAddImage(destination, image, (index < frames.count ? frames[index] : [:]) as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError("ImageIO 写 \(type) 失败") }
        return data as Data
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85, progressive: Bool = false, orientation: Int = 1) throws -> Data {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if progressive {
            properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        if orientation != 1 {
            properties[kCGImagePropertyOrientation] = orientation
        }
        return try encode([image], type: FixtureType.jpeg, frames: [properties])
    }

    static func gif(_ images: [CGImage], delays: [Double]? = nil, loopCount: Int? = nil) throws -> Data {
        try encode(
            images, type: FixtureType.gif,
            file: loopCount.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: $0]] } ?? [:],
            frames: delays?.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] } ?? []
        )
    }

    static func apng(_ images: [CGImage], delays: [Double], loopCount: Int) throws -> Data {
        try encode(
            images, type: FixtureType.png,
            file: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]],
            frames: delays.map { [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: $0]] }
        )
    }

    /// 一帧时用 cwebp 生成静态图；多帧时用 img2webp 生成动图，各帧时长相同。
    static func webp(_ images: [CGImage], delay: Double = 0.1, loopCount: Int = 0) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mvbench-webp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try images.enumerated().map { index, image in
            let url = directory.appending(path: String(format: "frame-%03d.png", index))
            try encode([image], type: FixtureType.png).write(to: url)
            return url.path
        }
        let output = directory.appending(path: "output.webp").path
        if inputs.count == 1 {
            try ExternalTool.run(ExternalTool.find("cwebp", install: "brew install webp"), ["-quiet", "-q", "80", "-metadata", "none", inputs[0], "-o", output])
        } else {
            let arguments = ["-loop", String(loopCount), "-lossy", "-q", "80", "-d", String(Int((delay * 1000).rounded()))] + inputs + ["-o", output]
            try ExternalTool.run(ExternalTool.find("img2webp", install: "brew install webp"), arguments)
        }
        return try Data(contentsOf: URL(fileURLWithPath: output))
    }
}

/// 夹具用到的类型标识，与 `CGImageSourceGetType` 的返回值一致。
enum FixtureType {
    static let jpeg = "public.jpeg"
    static let png = "public.png"
    static let gif = "com.compuserve.gif"
    static let heic = "public.heic"
    static let avif = "public.avif"
    static let tiff = "public.tiff"
    static let webp = "org.webmproject.webp"
    static let psd = "com.adobe.photoshop-image"
}
