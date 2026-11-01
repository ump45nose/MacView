import Accelerate
import CoreGraphics
import IOSurface
import MVFoundation

/// 输出的位图：32 位 BGRA（预乘或不透明），写在带色彩空间标记的 IOSurface 里，同一块内存再包成 CGImage。
/// IOSurface 设为 CALayer.contents 时直接交给窗口服务器：每次提交 4 张 1000×1500 的图，
/// CGImage 要在主线程复制约 21 ms，IOSurface 只要 0.3 ms（S1-T3 实测）。宽色域靠色彩空间标记保留。
package enum Bitmap {
    /// 把任意 CGImage（灰度、CMYK、16 位、带透明等）转成输出位图，尺寸不变。
    package static func normalized(_ image: CGImage, quality: RenditionQuality) throws(MediaError) -> RenderedImage {
        let source = try Pixels(converting: image)
        return try output(PixelSize(width: image.width, height: image.height), like: image, quality: quality) {
            vImageCopyBuffer(&source.buffer, &$0, 4, vImage_Flags(kvImageNoFlags))
        }
    }

    /// 转换并按滤镜缩放到 `size`；`sharpen > 0` 且是缩小时，缩放后锐化。
    package static func resampled(_ image: CGImage, to size: PixelSize, filter: ResampleFilter, sharpen: Float, quality: RenditionQuality) throws(MediaError) -> RenderedImage {
        if image.width == size.width, image.height == size.height { return try normalized(image, quality: quality) }
        let source = try Pixels(converting: image)
        let scale = { (destination: inout vImage_Buffer) -> vImage_Error in
            filter == .lanczos
                ? vImageScale_ARGB8888(&source.buffer, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
                : nearest(&source.buffer, &destination)
        }
        guard sharpen > 0, size.width < image.width else { return try output(size, like: image, quality: quality, scale) }
        let scaled = try Pixels(size)
        try check(scale(&scaled.buffer), "缩放")
        return try output(size, like: image, quality: quality) { sharpening(&scaled.buffer, &$0, amount: sharpen) }
    }

    /// 把按存放方向裁出的区域转成显示方向（EXIF 方向 1–8），再用 Lanczos 缩放到 `size`。分块用。
    static func oriented(_ image: CGImage, orientation: Int, to size: PixelSize, quality: RenditionQuality) throws(MediaError) -> RenderedImage {
        var source = try Pixels(converting: image)
        try orient(&source, orientation)
        let unscaled = Int(source.buffer.width) == size.width && Int(source.buffer.height) == size.height
        return try output(size, like: image, quality: quality) { [source] destination in
            unscaled
                ? vImageCopyBuffer(&source.buffer, &destination, 4, vImage_Flags(kvImageNoFlags))
                : vImageScale_ARGB8888(&source.buffer, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }

    /// 分配 IOSurface，由 `write` 写入像素，打上色彩空间标记，再包成 CGImage。
    private static func output(_ size: PixelSize, like image: CGImage, quality: RenditionQuality, _ write: (inout vImage_Buffer) -> vImage_Error) throws(MediaError) -> RenderedImage {
        let space = space(of: image)
        guard let surface = IOSurface(properties: [.width: size.width, .height: size.height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 /* 'BGRA' */]) else {
            throw .decodeFailed("分配 \(size.width)×\(size.height) 的 IOSurface 失败")
        }
        surface.lock(options: [], seed: nil)
        var buffer = vImage_Buffer(data: surface.baseAddress, height: vImagePixelCount(size.height), width: vImagePixelCount(size.width), rowBytes: surface.bytesPerRow)
        let error = write(&buffer)
        surface.unlock(options: [], seed: nil)
        try check(error, "写入")
        if let tag = space.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, tag)
        }
        // CGImage 读像素时加只读锁，图像释放时释放 IOSurface。
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: { info in
                let surface = Unmanaged<IOSurface>.fromOpaque(info!).takeUnretainedValue()
                surface.lock(options: .readOnly, seed: nil)
                return UnsafeRawPointer(surface.baseAddress)
            },
            releaseBytePointer: { info, _ in
                Unmanaged<IOSurface>.fromOpaque(info!).takeUnretainedValue().unlock(options: .readOnly, seed: nil)
            },
            getBytesAtPosition: nil,
            releaseInfo: { info in Unmanaged<IOSurface>.fromOpaque(info!).release() }
        )
        let info = Unmanaged.passRetained(surface).toOpaque()
        guard let provider = CGDataProvider(directInfo: info, size: off_t(surface.bytesPerRow * size.height), callbacks: &callbacks) else {
            Unmanaged<IOSurface>.fromOpaque(info).release()
            throw .decodeFailed("构造图像失败")
        }
        guard let cgImage = CGImage(
            width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
            space: space, bitmapInfo: bitmapInfo(opaque: isOpaque(image)), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { throw .decodeFailed("构造图像失败") }
        return RenderedImage(image: cgImage, quality: quality, surface: surface)
    }

    /// 3×3 的拉普拉斯锐化：中心 1 + 4k，上下左右 −k。`amount` 即 k，1 为强锐化。
    private static func sharpening(_ source: inout vImage_Buffer, _ destination: inout vImage_Buffer, amount: Float) -> vImage_Error {
        let side = -Int16((min(amount, 4) * 64).rounded())
        let kernel: [Int16] = [0, side, 0, side, 64 - 4 * side, side, 0, side, 0]
        return vImageConvolve_ARGB8888(&source, &destination, nil, 0, 0, kernel, 3, 3, 64, nil, vImage_Flags(kvImageEdgeExtend))
    }

    /// 最近邻：按目标像素中心取源像素，像素画放大时保持硬边。
    private static func nearest(_ source: inout vImage_Buffer, _ destination: inout vImage_Buffer) -> vImage_Error {
        let (sw, sh, dw, dh) = (Int(source.width), Int(source.height), Int(destination.width), Int(destination.height))
        let columns = (0..<dw).map { min(sw - 1, ($0 * 2 + 1) * sw / (dw * 2)) }
        for y in 0..<dh {
            let row = source.data.advanced(by: min(sh - 1, (y * 2 + 1) * sh / (dh * 2)) * source.rowBytes).assumingMemoryBound(to: UInt32.self)
            let out = destination.data.advanced(by: y * destination.rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<dw { out[x] = row[columns[x]] }
        }
        return kvImageNoError
    }

    /// 方向 5、7 先顺时针转 90° 再水平、垂直翻转；6、8 是顺、逆时针 90°。
    private static func orient(_ pixels: inout Pixels, _ orientation: Int) throws(MediaError) {
        var background: [UInt8] = [0, 0, 0, 0]
        switch orientation {
        case 2: try transform(&pixels, swap: false) { vImageHorizontalReflect_ARGB8888(&$0, &$1, vImage_Flags(kvImageNoFlags)) }
        case 3: try transform(&pixels, swap: false) { vImageRotate90_ARGB8888(&$0, &$1, UInt8(kRotate180DegreesClockwise), &background, vImage_Flags(kvImageNoFlags)) }
        case 4: try transform(&pixels, swap: false) { vImageVerticalReflect_ARGB8888(&$0, &$1, vImage_Flags(kvImageNoFlags)) }
        case 5:
            try orient(&pixels, 6)
            try orient(&pixels, 2)
        case 6: try transform(&pixels, swap: true) { vImageRotate90_ARGB8888(&$0, &$1, UInt8(kRotate90DegreesClockwise), &background, vImage_Flags(kvImageNoFlags)) }
        case 7:
            try orient(&pixels, 6)
            try orient(&pixels, 4)
        case 8: try transform(&pixels, swap: true) { vImageRotate90_ARGB8888(&$0, &$1, UInt8(kRotate90DegreesCounterClockwise), &background, vImage_Flags(kvImageNoFlags)) }
        default: break
        }
    }

    private static func transform(_ pixels: inout Pixels, swap: Bool, _ body: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error) throws(MediaError) {
        let (width, height) = (Int(pixels.buffer.width), Int(pixels.buffer.height))
        let output = try Pixels(swap ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height))
        try check(body(&pixels.buffer, &output.buffer), "旋转")
        pixels = output
    }

    private static func check(_ error: vImage_Error, _ step: String) throws(MediaError) {
        guard error == kvImageNoError else { throw .decodeFailed("\(step)失败：vImage \(error)") }
    }

    static func bitmapInfo(opaque: Bool) -> CGBitmapInfo {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst
        return CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// RGB 图保留自己的色彩空间（如 Display P3）；灰度、CMYK 和没有色彩空间的图转成 sRGB。
    static func space(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }
}

/// 中间结果的像素缓冲区，对象释放时释放内存。
private final class Pixels {
    var buffer: vImage_Buffer

    init(_ size: PixelSize) throws(MediaError) {
        buffer = vImage_Buffer()
        guard vImageBuffer_Init(&buffer, vImagePixelCount(size.height), vImagePixelCount(size.width), 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw .decodeFailed("分配 \(size.width)×\(size.height) 的缓冲区失败")
        }
    }

    /// 转成输出的像素布局；颜色转换（灰度、CMYK 到 RGB，16 位到 8 位）在这里一次完成。
    init(converting image: CGImage) throws(MediaError) {
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(Bitmap.space(of: image)),
            bitmapInfo: Bitmap.bitmapInfo(opaque: Bitmap.isOpaque(image)),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        buffer = vImage_Buffer()
        let error = vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw .decodeFailed("转换像素格式失败：vImage \(error)") }
    }

    deinit {
        free(buffer.data)
    }
}
