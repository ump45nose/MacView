import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import MVFoundation
import MVTestSupport
import Synchronization
import Testing
@testable import MVMedia

@Test func renditionsGetMorePreciseInDeclarationOrder() {
    let qualities: [RenditionQuality] = [.original, .placeholder, .exact, .browse]
    #expect(qualities.sorted() == [.placeholder, .browse, .exact, .original])
}

// MARK: 探测

/// 夹具清单中的每张图：按调用方的方式逐步加长文件头探测，元数据与清单一致；按长边 256 解码得到目标尺寸。
@Test(arguments: imageFixtures())
func everyImageFixtureProbesAndDecodes(_ fixture: Fixture) async throws {
    let facts = try #require(fixture.image)
    let data = try Data(contentsOf: Fixtures.url(fixture.path))
    let metadata = try probe(data)
    #expect(metadata.pixelSize == facts.pixelSize)
    #expect(metadata.frameCount == facts.frameCount)
    if let delays = facts.frameDelays, delays.count > 1 {
        #expect(abs((metadata.duration ?? 0) - delays.reduce(0, +)) < 0.001)
    }
    if let profile = facts.profileName {
        #expect(metadata.colorSpace == profile)
    }
    let target = metadata.pixelSize.fitting(longSide: 256)
    let rendered = try await ImageDecoder().image(data, target: DisplayTarget(pixelSize: target))
    #expect(PixelSize(width: rendered.image.width, height: rendered.image.height) == target)
    #expect(rendered.image.bitsPerPixel == 32)
    #expect(rendered.image.colorSpace?.model == .rgb)
}

@Test func staticHeadersAreEnoughButAnimationsNeedTheWholeFile() throws {
    let jpeg = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
    let header = try MediaProbe.image(jpeg.prefix(MediaProbe.initialHeaderLength), isComplete: false)
    #expect(header == .metadata(ImageMetadata(pixelSize: PixelSize(width: 3600, height: 5400), colorSpace: "sRGB IEC61966-2.1")))
    let png = try Data(contentsOf: Fixtures.url("image/format/image.png"))
    guard case .metadata = try MediaProbe.image(png.prefix(png.count / 2), isComplete: false) else {
        Issue.record("静态 PNG 的前半部分应该足够")
        return
    }
    for path in ["animated/loop.gif", "animated/loop.png", "animated/loop.webp"] {
        let data = try Data(contentsOf: Fixtures.url(path))
        #expect(try MediaProbe.image(data.prefix(data.count / 2), isComplete: false) == .needsMoreData(nil), "\(path)")
    }
    #expect(try MediaProbe.image(Data(count: 10), isComplete: false) == .needsMoreData(MediaProbe.initialHeaderLength))
    #expect(throws: MediaError.unsupported) { try MediaProbe.image(Data(repeating: 7, count: 100), isComplete: true) }
}

// MARK: 方向

/// 方向 2–8 的夹具解码后与方向 1 的参考图逐块一致。整张解码和分块各比较一次；分块取右下四分之一，检验区域换算。
@Test(arguments: 2...8)
func orientationsDecodeUpright(_ orientation: Int) async throws {
    let decoder = ImageDecoder()
    let reference = try Data(contentsOf: Fixtures.url("image/orientation/1.jpg"))
    let data = try Data(contentsOf: Fixtures.url("image/orientation/\(orientation).jpg"))
    let size = PixelSize(width: 240, height: 160)
    let expected = try await decoder.image(reference, target: DisplayTarget(pixelSize: size)).image
    let decoded = try await decoder.image(data, target: DisplayTarget(pixelSize: size)).image
    #expect(maxBlockDifference(decoded, expected, grid: 4) < 12)

    let tiles = try decoder.tiledSource(data)
    #expect(tiles.pixelSize == size)
    let quarter = CGRect(x: 120, y: 80, width: 120, height: 80)
    let tile = try await tiles.tile(quarter, scale: 1).image
    let expectedTile = try #require(expected.cropping(to: quarter))
    #expect(maxBlockDifference(tile, expectedTile, grid: 2) < 12)
}

// MARK: 色彩

@Test func outputsKeepWideGamutAndNormalizeOtherModels() async throws {
    let decoder = ImageDecoder()
    let p3 = try await decoder.image(Data(contentsOf: Fixtures.url("image/color/display-p3.jpg")), target: DisplayTarget(pixelSize: PixelSize(width: 100, height: 150)))
    #expect(p3.image.colorSpace?.name == CGColorSpace.displayP3)
    for path in ["image/color/gray.jpg", "image/color/cmyk.jpg", "image/color/16bit.png"] {
        let image = try await decoder.image(Data(contentsOf: Fixtures.url(path)), target: DisplayTarget(pixelSize: PixelSize(width: 100, height: 150))).image
        #expect(image.colorSpace?.model == .rgb, "\(path)")
        #expect(image.bitsPerComponent == 8, "\(path)")
        #expect(image.alphaInfo == .noneSkipFirst, "\(path)")
    }
    let alpha = try await decoder.image(Data(contentsOf: Fixtures.url("image/color/alpha.png")), target: DisplayTarget(pixelSize: PixelSize(width: 100, height: 150))).image
    #expect(alpha.alphaInfo == .premultipliedFirst)
}

@Test func outputsLiveInColorTaggedSurfaces() async throws {
    let decoder = ImageDecoder()
    let data = try Data(contentsOf: Fixtures.url("image/color/display-p3.jpg"))
    let outputs = [
        try await decoder.image(data, target: DisplayTarget(pixelSize: PixelSize(width: 100, height: 150), sharpen: 0.5)),
        try await decoder.original(data, maxDecodeLongSide: 8192),
        try await decoder.tiledSource(data).tile(CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1),
    ]
    for rendered in outputs {
        let surface = try #require(rendered.surface)
        #expect(surface.width == rendered.image.width && surface.height == rendered.image.height)
        #expect(surface.pixelFormat == 0x4247_5241)
        let tag = try #require(IOSurfaceCopyValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace))
        #expect(CGColorSpace(propertyListPlist: tag)?.name == CGColorSpace.displayP3)
        // CGImage 的像素就是 IOSurface 里的像素。
        surface.lock(options: .readOnly, seed: nil)
        let first = surface.baseAddress.load(as: UInt32.self)
        surface.unlock(options: .readOnly, seed: nil)
        let bytes = try #require(rendered.image.dataProvider?.data as Data?)
        #expect(bytes.withUnsafeBytes { $0.load(as: UInt32.self) } == first)
    }
}

@Test func nearestKeepsHardEdgesWhenEnlarging() async throws {
    let png = pngData(checkerboard())
    let image = try await ImageDecoder().image(png, target: DisplayTarget(pixelSize: PixelSize(width: 64, height: 64), filter: .nearest)).image
    let pixels = rgba(image)
    // 2×2 的棋盘放大 32 倍：左上一块全是同一个颜色，边界两侧截然不同。
    #expect(pixels[0] == pixels[31 * 64 + 31])
    #expect(abs(Int(pixels[31].red) - Int(pixels[32].red)) > 200)
}

// MARK: 原图与分块

@Test func originalsBeyondTheLimitRequireTiling() async throws {
    let data = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
    let decoder = ImageDecoder()
    let original = try await decoder.original(data, maxDecodeLongSide: 8192)
    #expect(original.quality == .original)
    #expect(original.image.width == 3600)
    await #expect(throws: MediaError.requiresTiling(PixelSize(width: 3600, height: 5400))) { try await decoder.original(data, maxDecodeLongSide: 4096) }
    #expect(ImageDecoder.needsTiling(PixelSize(width: 20000, height: 20000), maxDecodeLongSide: 32768))
}

@Test func tilesCoverRegionsAtTheRequestedScale() async throws {
    let data = try Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg"))
    let decoder = ImageDecoder()
    let tiles = try decoder.tiledSource(data)
    let tile = try await tiles.tile(CGRect(x: 1024, y: 2048, width: 1024, height: 1024), scale: 0.25)
    #expect(tile.image.width == 256 && tile.image.height == 256)
    let edge = try await tiles.tile(CGRect(x: 3000, y: 5000, width: 1024, height: 1024), scale: 1)
    #expect(edge.image.width == 600 && edge.image.height == 400)
    #expect(edge.quality == .original)
    // 同一区域按 1/4 取块，与整张缩小解码的对应区域一致。
    let whole = try await decoder.image(data, target: DisplayTarget(pixelSize: PixelSize(width: 900, height: 1350))).image
    let expected = try #require(whole.cropping(to: CGRect(x: 256, y: 512, width: 256, height: 256)))
    #expect(maxBlockDifference(tile.image, expected, grid: 4) < 6)
}

// MARK: 动图与视频

@Test(arguments: ["animated/loop.gif", "animated/uneven.gif", "animated/loop.png", "animated/loop.webp"])
func animationsReportFramesAndTimings(_ path: String) async throws {
    let facts = try #require(try Fixtures.manifest()[path]?.image)
    let frames = try ImageDecoder().animatedFrames(Data(contentsOf: Fixtures.url(path)), target: DisplayTarget(pixelSize: PixelSize(width: 120, height: 80)))
    #expect(frames.frameCount == facts.frameCount)
    #expect(frames.loopCount == facts.loopCount)
    // APNG 的帧时长在 ImageIO 里是 Float。
    let delays = (0..<frames.frameCount).map { frames.duration(at: $0) }
    #expect(zip(delays, facts.frameDelays ?? []).allSatisfy { abs($0 - $1) < 0.001 } && delays.count == facts.frameDelays?.count)
    let last = try await frames.frame(at: frames.frameCount - 1)
    #expect(last.image.width == 120 && last.image.height == 80)
}

@Test func tooShortGIFDelaysBecomeTheDefault() {
    #expect(FrameTiming.minimumDelay > 0.01)
    #expect(FrameTiming.defaultDelay == 0.1)
}

@Test(.enabled(if: Fixtures.hasLocal(), "运行 make bench ARGS=fixtures 生成大夹具"), arguments: videoFixtures())
func videosReportDurationSizeAndPoster(_ fixture: Fixture) async throws {
    let facts = try #require(fixture.video)
    let asset = AVURLAsset(url: Fixtures.url(fixture.path))
    let metadata = try await MediaProbe.video(asset)
    #expect(metadata.pixelSize == facts.pixelSize)
    #expect(abs((metadata.duration ?? 0) - facts.duration) < 0.05)
    let poster = try await ImageDecoder().videoPoster(asset, maxPixel: 320)
    #expect(max(poster.image.width, poster.image.height) == 320)
    #expect((poster.image.width > poster.image.height) == (facts.pixelSize.width > facts.pixelSize.height))
}

// MARK: 并发上限

@Test func waitingDecodesStartByTaskPriority() async throws {
    let limiter = WorkLimiter(limit: 1)
    let gate = DispatchSemaphore(value: 0)
    let order = Mutex<[String]>([])
    let blocker = Task { try await limiter.run { gate.wait(); order.withLock { $0.append("blocker") } } }
    try await waitUntil { limiter.runningCount == 1 }
    let low = Task(priority: .background) { try await limiter.run { order.withLock { $0.append("low") } } }
    try await waitUntil { limiter.waitingCount == 1 }
    let high = Task(priority: .userInitiated) { try await limiter.run { order.withLock { $0.append("high") } } }
    try await waitUntil { limiter.waitingCount == 2 }
    let cancelled = Task(priority: .high) { try await limiter.run { order.withLock { $0.append("cancelled") } } }
    try await waitUntil { limiter.waitingCount == 3 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    gate.signal()
    for task in [blocker, low, high] { try await task.value }
    #expect(order.withLock { $0 } == ["blocker", "high", "low"])
    #expect(limiter.waitingCount == 0)
}

// MARK: 渲染件编码

@Test(arguments: RenditionEncoding.allCases)
func renditionsRoundTrip(_ encoding: RenditionEncoding) async throws {
    let decoder = ImageDecoder()
    let source = try await decoder.image(Data(contentsOf: Fixtures.url("image/size/3600x5400.jpg")), target: DisplayTarget(pixelSize: PixelSize(width: 683, height: 1024)))
    let data = try encoding.encode(source.image)
    let decoded = try await decoder.image(data, target: DisplayTarget(pixelSize: PixelSize(width: 683, height: 1024)))
    #expect(maxBlockDifference(decoded.image, source.image, grid: 8) < 8)
}

// MARK: 辅助

private func imageFixtures() -> [Fixture] {
    ((try? Fixtures.manifest().fixtures) ?? []).filter { $0.image != nil && (!$0.isLocal || Fixtures.hasLocal()) }
}

private func videoFixtures() -> [Fixture] {
    ((try? Fixtures.manifest().fixtures) ?? []).filter { $0.video != nil }
}

/// 按调用方的方式探测：从初始长度开始，按要求加长，直到得到元数据。
private func probe(_ data: Data) throws -> ImageMetadata {
    var length = MediaProbe.initialHeaderLength
    while true {
        let complete = length >= data.count
        switch try MediaProbe.image(complete ? data : data.prefix(length), isComplete: complete) {
        case let .metadata(metadata): return metadata
        case let .needsMoreData(next): length = next ?? data.count
        }
    }
}

private struct RGBA: Equatable {
    var red, green, blue, alpha: UInt8
}

/// 画到 sRGB 的 RGBA 缓冲区里读出像素，与输出的布局和色彩空间无关。
private func rgba(_ image: CGImage) -> [RGBA] {
    var pixels = [RGBA](repeating: RGBA(red: 0, green: 0, blue: 0, alpha: 0), count: image.width * image.height)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

/// 两张图按 grid×grid 分块求平均色，返回各块各通道差的最大值。
private func maxBlockDifference(_ a: CGImage, _ b: CGImage, grid: Int) -> Int {
    func blocks(_ image: CGImage) -> [[Double]] {
        let pixels = rgba(image)
        return (0..<grid * grid).map { block in
            let (bx, by) = (block % grid, block / grid)
            var sum = [0.0, 0.0, 0.0]
            var count = 0.0
            for y in by * image.height / grid..<(by + 1) * image.height / grid {
                for x in bx * image.width / grid..<(bx + 1) * image.width / grid {
                    let p = pixels[y * image.width + x]
                    sum[0] += Double(p.red); sum[1] += Double(p.green); sum[2] += Double(p.blue)
                    count += 1
                }
            }
            return sum.map { $0 / max(1, count) }
        }
    }
    return zip(blocks(a), blocks(b)).map { zip($0, $1).map { Int(abs($0 - $1).rounded()) }.max() ?? 0 }.max() ?? 0
}

private func checkerboard() -> CGImage {
    let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
    return context.makeImage()!
}

private func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(2))
    }
}
