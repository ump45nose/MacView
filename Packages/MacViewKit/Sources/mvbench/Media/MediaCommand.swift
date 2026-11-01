import AppKit
import ArgumentParser
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import MVFoundation
import MVMedia
import QuartzCore

/// `mvbench media`：MVMedia 的探测、解码、重采样、分块与渲染件编码的用时。数据先读进内存，不含 I/O。
struct MediaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "media",
        abstract: "测量探测、显示解码、重采样、分块、上屏和渲染件编码的用时。",
        subcommands: [MediaDecodeCommand.self, MediaEncodeCommand.self, MediaTilesCommand.self, MediaLayerCommand.self]
    )
}

/// media 子命令共用的选项。
struct MediaOptions: ParsableArguments {
    @Option(name: .customLong("dir"), help: "样本目录，取其中的普通文件。")
    var directory: String

    @Option(help: "最多取的文件数。")
    var limit: Int?

    @Option(name: .shortAndLong, help: "JSON 输出文件；省略时输出到标准输出。")
    var output: String?

    func files() throws -> [SampleFile] {
        let files = try Samples.files(in: directory, limit: limit)
        guard !files.isEmpty else { throw ValidationFailure("\(directory) 下没有文件") }
        return files
    }
}

struct MediaReport<Result: Encodable>: Encodable {
    var environment: BenchEnvironment
    var directory: String
    var files: Int
    var finishedAt: Date
    var result: Result

    static func write(_ result: Result, directory: String, files: Int, output: String?) throws {
        try JSONReport.write(
            MediaReport(environment: .collect(paths: [directory], host: nil), directory: SampleDirectory.anonymizedPath(directory), files: files, finishedAt: Date(), result: result),
            to: output
        )
    }
}

// MARK: decode

struct MediaDecodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "逐个文件测探测、缩小解码、Lanczos 缩放和整个显示解码的用时，再测并发解码的吞吐。",
        discussion: "显示解码的目标是长边 --long-side 的等比尺寸。先用第一个文件预热一次。"
    )

    @OptionGroup var options: MediaOptions

    @Option(help: "目标长边，像素。")
    var longSide = 2560

    @Option(help: "每个文件重复的次数。")
    var `repeat` = 1

    @Option(help: "测吞吐时的并发解码数；默认为性能核心数。")
    var concurrency = ImageDecoder.defaultConcurrency

    struct Result: Encodable {
        var longSide: Int
        var probe: Summary?
        var decode: Summary?
        var resample: Summary?
        var total: Summary?
        var probeHeaderBytes: Summary?
        var concurrency: Int
        var filesPerSecond: Double
    }

    func run() async throws {
        let files = try options.files()
        let datas = try files.map { try Data(contentsOf: URL(filePath: $0.path, directoryHint: .notDirectory)) }
        let decoder = ImageDecoder()
        var probe: [Double] = [], decode: [Double] = [], resample: [Double] = [], total: [Double] = [], header: [Double] = []
        let clock = ContinuousClock()
        _ = try await decoder.image(datas[0], target: DisplayTarget(pixelSize: try Self.metadata(datas[0]).metadata.pixelSize.fitting(longSide: longSide)))
        for data in datas {
            for _ in 0..<self.repeat {
                var probed: (metadata: ImageMetadata, bytes: Int)!
                probe.append(try clock.measure { probed = try Self.metadata(data) }.milliseconds)
                header.append(Double(probed.bytes))
                let target = probed.metadata.pixelSize.fitting(longSide: longSide)
                var decoded: CGImage!
                decode.append(try clock.measure { decoded = try ImageDecoder.decode(ImageDecoder.source(data), index: 0, atLeast: target) }.milliseconds)
                resample.append(try clock.measure { _ = try Bitmap.resampled(decoded, to: target, filter: .lanczos, sharpen: 0, quality: .exact) }.milliseconds)
                let begin = clock.now
                _ = try await decoder.image(data, target: DisplayTarget(pixelSize: target))
                total.append((clock.now - begin).milliseconds)
            }
        }
        // 吞吐：所有文件同时提交，解码器按并发上限执行。
        let throughputDecoder = ImageDecoder(maxConcurrentDecodes: concurrency)
        let longSide = longSide
        let begin = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for data in datas {
                group.addTask {
                    let target = try Self.metadata(data).metadata.pixelSize.fitting(longSide: longSide)
                    _ = try await throughputDecoder.image(data, target: DisplayTarget(pixelSize: target))
                }
            }
            try await group.waitForAll()
        }
        let seconds = (clock.now - begin).milliseconds / 1000
        let result = Result(
            longSide: longSide, probe: Summary(probe), decode: Summary(decode), resample: Summary(resample), total: Summary(total),
            probeHeaderBytes: Summary(header), concurrency: concurrency, filesPerSecond: Double(datas.count) / seconds
        )
        progress(String(format: "探测 P95 %.1f ms，缩小解码 P95 %.1f ms，Lanczos P95 %.1f ms，显示解码 P50 %.1f / P95 %.1f ms；并发 %d 时 %.1f 张/秒",
                        result.probe?.p95 ?? 0, result.decode?.p95 ?? 0, result.resample?.p95 ?? 0, result.total?.p50 ?? 0, result.total?.p95 ?? 0, concurrency, result.filesPerSecond))
        try MediaReport.write(result, directory: options.directory, files: files.count, output: options.output)
    }

    /// 按管线的方式探测：从 64 KB 起，按要求加长。
    static func metadata(_ data: Data) throws -> (metadata: ImageMetadata, bytes: Int) {
        var length = MediaProbe.initialHeaderLength
        while true {
            let complete = length >= data.count
            switch try MediaProbe.image(complete ? data : data.prefix(length), isComplete: complete) {
            case let .metadata(metadata): return (metadata, min(length, data.count))
            case let .needsMoreData(next): length = next ?? data.count
            }
        }
    }
}

// MARK: encode

struct MediaEncodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract: "比较渲染件的编码格式：编码用时、文件大小、解码用时，以及与编码前的 PSNR 和 SSIM。",
        discussion: "缩略图为长边 --thumbnail；浏览图为能放进 --browse 的等比尺寸，默认取当前最大显示器的像素尺寸。"
    )

    @OptionGroup var options: MediaOptions

    @Option(help: "缩略图的长边，像素。")
    var thumbnail = 1024

    @Option(help: "浏览图的边界，例如 3024x1964；省略时取当前最大显示器的像素尺寸。")
    var browse: String?

    @Option(parsing: .upToNextOption, help: "编码质量，可给多个值。")
    var quality: [Double] = [RenditionEncoding.defaultQuality]

    struct Measurement: Encodable {
        var rendition: String
        var encoding: RenditionEncoding
        var quality: Double
        var size: PixelSize
        var encode: Summary?
        var decode: Summary?
        var kilobytes: Summary?
        var psnr: Summary?
        var ssim: Summary?
    }

    func run() async throws {
        let files = try options.files()
        let bounds = try browse.map(Self.parseSize) ?? Self.largestDisplay()
        let decoder = ImageDecoder()
        let clock = ContinuousClock()
        var samples: [String: (encode: [Double], decode: [Double], bytes: [Double], psnr: [Double], ssim: [Double], size: PixelSize)] = [:]
        for file in files {
            let data = try Data(contentsOf: URL(filePath: file.path, directoryHint: .notDirectory))
            let size = try MediaDecodeCommand.metadata(data).metadata.pixelSize
            for (name, target) in [("thumbnail", size.fitting(longSide: thumbnail)), ("browse", size.fitting(within: bounds))] {
                let source = try await decoder.image(data, target: DisplayTarget(pixelSize: target)).image
                for encoding in RenditionEncoding.allCases {
                    for quality in quality {
                        var encoded = Data()
                        let encodeTime = try clock.measure { encoded = try encoding.encode(source, quality: quality) }.milliseconds
                        let begin = clock.now
                        let decoded = try await decoder.image(encoded, target: DisplayTarget(pixelSize: target)).image
                        let decodeTime = (clock.now - begin).milliseconds
                        let (psnr, ssim) = Similarity.compare(decoded, source)
                        let key = "\(name)|\(encoding.rawValue)|\(quality)"
                        var entry = samples[key] ?? ([], [], [], [], [], target)
                        entry.encode.append(encodeTime)
                        entry.decode.append(decodeTime)
                        entry.bytes.append(Double(encoded.count) / 1024)
                        entry.psnr.append(psnr)
                        entry.ssim.append(ssim)
                        samples[key] = entry
                    }
                }
            }
        }
        let measurements = samples.keys.sorted().map { key in
            let parts = key.split(separator: "|")
            let entry = samples[key]!
            return Measurement(
                rendition: String(parts[0]), encoding: RenditionEncoding(rawValue: String(parts[1]))!, quality: Double(parts[2])!, size: entry.size,
                encode: Summary(entry.encode), decode: Summary(entry.decode), kilobytes: Summary(entry.bytes), psnr: Summary(entry.psnr), ssim: Summary(entry.ssim)
            )
        }
        for m in measurements {
            progress(String(format: "%@ %@ q%.2f：编码 P50 %.1f ms，解码 P50 %.1f ms，%.0f KB，PSNR %.2f dB，SSIM %.4f",
                            m.rendition, m.encoding.rawValue, m.quality, m.encode?.p50 ?? 0, m.decode?.p50 ?? 0, m.kilobytes?.p50 ?? 0, m.psnr?.p50 ?? 0, m.ssim?.p50 ?? 0))
        }
        try MediaReport.write(measurements, directory: options.directory, files: files.count, output: options.output)
    }

    static func parseSize(_ text: String) throws -> PixelSize {
        let parts = text.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { throw ValidationFailure("尺寸的格式是 宽x高，例如 3024x1964") }
        return PixelSize(width: parts[0], height: parts[1])
    }

    /// 当前像素面积最大的显示器。
    static func largestDisplay() throws -> PixelSize {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let sizes = displays.compactMap { CGDisplayCopyDisplayMode($0).map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) } }
        guard let largest = sizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { throw ValidationFailure("没有活动的显示器，用 --browse 指定") }
        return PixelSize(width: max(largest.width, largest.height), height: min(largest.width, largest.height))
    }
}

// MARK: tiles

struct MediaTilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tiles",
        abstract: "超大图的分块：首个可显示分块（整图按 --long-side 缩小）、原尺寸分块的用时与进程峰值内存。",
        discussion: "每个文件单独运行一次，峰值内存才只属于这个文件。"
    )

    @Option(help: "超大图文件。")
    var file: String

    @Option(help: "首个分块（整图）的长边，像素。")
    var longSide = 2560

    @Option(help: "首个分块之后、取原尺寸分块之前空闲的秒数，让后台预热完成。")
    var idle = 2.0

    @Option(help: "随机分块的个数。")
    var count = 30

    @Option(help: "分块边长，像素。")
    var side = 1024

    @Option(name: .shortAndLong, help: "JSON 输出文件；省略时输出到标准输出。")
    var output: String?

    struct Result: Encodable {
        var pixelSize: PixelSize
        var longSide: Int
        var idleSeconds: Double
        var firstTileMilliseconds: Double
        var firstFullResolutionTileMilliseconds: Double
        var fullResolutionTiles: Summary?
        var halfScaleTiles: Summary?
        var peakFootprintMegabytes: Double
        var startFootprintMegabytes: Double
    }

    func run() async throws {
        let data = try Data(contentsOf: URL(filePath: file, directoryHint: .notDirectory))
        let start = Footprint.peakMegabytes()
        let clock = ContinuousClock()
        let decoder = ImageDecoder()
        var begin = clock.now
        let tiles = try decoder.tiledSource(data)
        let size = tiles.pixelSize
        let whole = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        _ = try await tiles.tile(whole, scale: Double(longSide) / Double(max(size.width, size.height)))
        let first = (clock.now - begin).milliseconds
        try await Task.sleep(for: .seconds(idle))
        var generator = SystemRandomNumberGenerator()
        func randomRect() -> CGRect {
            CGRect(x: Int.random(in: 0...(size.width - side), using: &generator), y: Int.random(in: 0...(size.height - side), using: &generator), width: side, height: side)
        }
        begin = clock.now
        _ = try await tiles.tile(randomRect(), scale: 1)
        let firstFull = (clock.now - begin).milliseconds
        var full: [Double] = [], half: [Double] = []
        for _ in 0..<count {
            begin = clock.now
            _ = try await tiles.tile(randomRect(), scale: 1)
            full.append((clock.now - begin).milliseconds)
            begin = clock.now
            _ = try await tiles.tile(randomRect().insetBy(dx: -CGFloat(side) / 2, dy: -CGFloat(side) / 2), scale: 0.5)
            half.append((clock.now - begin).milliseconds)
        }
        let result = Result(
            pixelSize: size, longSide: longSide, idleSeconds: idle, firstTileMilliseconds: first, firstFullResolutionTileMilliseconds: firstFull,
            fullResolutionTiles: Summary(full), halfScaleTiles: Summary(half), peakFootprintMegabytes: Footprint.peakMegabytes(), startFootprintMegabytes: start
        )
        progress(String(format: "首个分块 %.0f ms，首个原尺寸分块 %.0f ms，原尺寸分块 P95 %.1f ms，1/2 分块 P95 %.1f ms，峰值 %.0f MB",
                        first, firstFull, result.fullResolutionTiles?.p95 ?? 0, result.halfScaleTiles?.p95 ?? 0, result.peakFootprintMegabytes))
        try JSONReport.write(MediaReport(environment: .collect(paths: [file], host: nil), directory: SampleDirectory.anonymizedPath(file), files: 1, finishedAt: Date(), result: result), to: output)
    }
}

// MARK: layer

struct MediaLayerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layer",
        abstract: "把图像设为窗口里 CALayer.contents 后提交事务的主线程用时：ImageIO 的惰性图像、MVMedia 输出的 CGImage 与 IOSurface 对照。",
        discussion: "会在屏幕上开一个窗口。惰性图像在提交时解码并复制，已解码的 CGImage 在提交时复制给窗口服务器，IOSurface 只传递引用。"
    )

    @OptionGroup var options: MediaOptions

    @Option(help: "目标长边，像素。")
    var longSide = 2560

    struct Result: Encodable {
        var longSide: Int
        var lazyImage: Summary?
        var decodedImage: Summary?
        var surface: Summary?
    }

    func run() async throws {
        let files = try options.files()
        let result = try await Self.measure(files.map(\.path), longSide: longSide)
        progress(String(format: "提交一次：惰性图像 P50 %.1f ms，CGImage P50 %.1f ms，IOSurface P50 %.2f ms / P95 %.2f ms",
                        result.lazyImage?.p50 ?? 0, result.decodedImage?.p50 ?? 0, result.surface?.p50 ?? 0, result.surface?.p95 ?? 0))
        try MediaReport.write(result, directory: options.directory, files: files.count, output: options.output)
    }

    @MainActor
    private static func measure(_ paths: [String], longSide: Int) async throws -> Result {
        let decoder = ImageDecoder()
        let window = LayerWindow()
        var lazy: [Double] = [], decoded: [Double] = [], surfaces: [Double] = []
        for (index, path) in paths.enumerated() {
            let data = try Data(contentsOf: URL(filePath: path, directoryHint: .notDirectory))
            let size = try MediaDecodeCommand.metadata(data).metadata.pixelSize.fitting(longSide: longSide)
            // 不经 MVMedia 时的常见写法：ImageIO 返回的图像在第一次上屏时才解码。
            let lazyImage = try requireImage(CGImageSourceCreateImageAtIndex(ImageDecoder.source(data), 0, nil))
            let output = try await decoder.image(data, target: DisplayTarget(pixelSize: size))
            guard let surface = output.surface else { throw ValidationFailure("输出没有 IOSurface") }
            let times = [await window.commit(lazyImage), await window.commit(output.image), await window.commit(surface)]
            // 第一张包含窗口和着色器的一次性准备，不计入。
            if index > 0 {
                lazy.append(times[0])
                decoded.append(times[1])
                surfaces.append(times[2])
            }
        }
        return Result(longSide: longSide, lazyImage: Summary(lazy), decodedImage: Summary(decoded), surface: Summary(surfaces))
    }
}

private func requireImage(_ image: CGImage?) throws -> CGImage {
    guard let image else { throw ValidationFailure("ImageIO 解码失败") }
    return image
}

/// 屏幕上的一个窗口，内容是一个图层。测设置 contents 后提交事务的主线程用时。
@MainActor
private final class LayerWindow {
    private let window: NSWindow
    private let layer = CALayer()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.contentsGravity = .resizeAspect
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFrontRegardless()
    }

    func commit(_ contents: Any) async -> Double {
        let time = ContinuousClock().measure {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = contents
            CATransaction.commit()
            CATransaction.flush()
        }.milliseconds
        // 等窗口服务器上屏后再测下一次。
        try? await Task.sleep(for: .milliseconds(100))
        return time
    }
}

// MARK: 辅助

/// 进程的内存占用（phys_footprint，与活动监视器的“内存”一致）。
enum Footprint {
    static func peakMegabytes() -> Double {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }
}

/// 图像相似度：画到同一尺寸的 sRGB 缓冲区后，在亮度上计算。
enum Similarity {
    /// PSNR（dB）与 SSIM。SSIM 用 8×8 窗口、步长 4，常数取 K1 = 0.01、K2 = 0.03。
    static func compare(_ a: CGImage, _ b: CGImage) -> (psnr: Double, ssim: Double) {
        let (width, height) = (b.width, b.height)
        let x = luma(a, width: width, height: height), y = luma(b, width: width, height: height)
        let mse = zip(x, y).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(x.count)
        let psnr = mse == 0 ? 100 : 10 * log10(255 * 255 / mse)
        let (c1, c2): (Double, Double) = ((0.01 * 255) * (0.01 * 255), (0.03 * 255) * (0.03 * 255))
        var total = 0.0, windows = 0
        for top in stride(from: 0, through: height - 8, by: 4) {
            for left in stride(from: 0, through: width - 8, by: 4) {
                var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
                for row in top..<top + 8 {
                    for column in left..<left + 8 {
                        let (p, q) = (x[row * width + column], y[row * width + column])
                        sx += p; sy += q; sxx += p * p; syy += q * q; sxy += p * q
                    }
                }
                let (mx, my) = (sx / 64, sy / 64)
                let (vx, vy, cov) = (sxx / 64 - mx * mx, syy / 64 - my * my, sxy / 64 - mx * my)
                total += (2 * mx * my + c1) * (2 * cov + c2) / ((mx * mx + my * my + c1) * (vx + vy + c2))
                windows += 1
            }
        }
        return (psnr, windows == 0 ? 1 : total / Double(windows))
    }

    private static func luma(_ image: CGImage, width: Int, height: Int) -> [Double] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<width * height).map { 0.299 * Double(pixels[$0 * 4]) + 0.587 * Double(pixels[$0 * 4 + 1]) + 0.114 * Double(pixels[$0 * 4 + 2]) }
    }
}
