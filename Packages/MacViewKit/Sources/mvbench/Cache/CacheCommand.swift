import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import MVCache
import MVFoundation
import MVMedia
import UniformTypeIdentifiers

/// C1.3：真实 SQLite 编解码与文件读取；不保存查询结果的内存副本。
struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cache", abstract: "预置缩略图，测量目录/元数据查询与首屏文件并发读取。")

    @Option(help: "临时缓存的父目录；每次运行建立独立目录，结束后清理。")
    var directory = "build/stage-1-work/cache-bench"

    @Option(help: "预置条目数。正式验收使用 10000。")
    var count = 10_000

    @Option(help: "重复测量次数。")
    var repetitions = 10

    @Option(name: .shortAndLong, help: "JSON 结果路径。")
    var output: String?

    struct Result: Encodable {
        var environment: BenchEnvironment
        var finishedAt: Date
        var entries: Int
        var firstScreenFiles: Int
        var sampleDescription: String
        var thumbnailPixelSize: PixelSize
        var thumbnailBytes: Summary?
        var totalThumbnailBytes: Int64
        var queryDescription: String
        var cacheCondition: String
        var firstQueryAfterReopenMilliseconds: Double
        var listingAndMetadataMilliseconds: Summary?
        var firstScreenReadMilliseconds: Summary?
        var listingAndMetadataLimitMilliseconds: Double
        var firstScreenReadLimitMilliseconds: Double
        var listingAndMetadataPassed: Bool
        var firstScreenReadPassed: Bool
    }

    func validate() throws {
        guard count >= 60, repetitions > 0 else { throw ValidationError("count 至少为 60，repetitions 必须大于 0。") }
    }

    func run() async throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let runDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        let images = try (0..<8).map(Self.thumbnail)
        let location = Location(root: .local, layers: [["cache-benchmark"]])
        let entries = (0..<count).map { number in
            let name = String(format: "%05d.jpg", number)
            let identity = ContentIdentity(location: location.appending(name), size: Int64(images[number % images.count].count), modificationNanos: 1_700_000_000_000_000_000 + Int64(number))
            return Entry(identity: identity, name: name, kind: .image)
        }
        let keys = entries.map { $0.identity.cacheKey }
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let database = runDirectory.appendingPathComponent("index.sqlite")
        let budget = totalBytes + (1 << 20)
        progress("预置 \(count) 个合成 JPEG 缩略图及目录、ImageMetadata……")
        // 创建与查询使用不同的 CacheIndex 实例。
        do {
            let index = try CacheIndex(databaseURL: database)
            let cache = try DiskCache(tier: .thumbnails, cacheDirectory: runDirectory, budget: budget, index: index)
            for number in entries.indices {
                try await cache.store(images[number % images.count], for: keys[number])
            }
            _ = try await DirectoryCache(index: index).update(location, listing: DirectoryListing(entries: entries, directoryModificationNanos: 1))
            let metadata = ImageMetadata(pixelSize: PixelSize(width: 320, height: 480), colorSpace: "sRGB")
            try await MetadataIndex(index: index).store(Dictionary(uniqueKeysWithValues: keys.map { ($0, metadata) }), in: location)
            try await index.flush()
        }
        let index = try CacheIndex(databaseURL: database)
        let listings = DirectoryCache(index: index)
        let metadata = MetadataIndex(index: index)
        let cache = try DiskCache(tier: .thumbnails, cacheDirectory: runDirectory, budget: budget, index: index)
        let clock = ContinuousClock()
        let firstStart = clock.now
        try await Self.query(listings: listings, metadata: metadata, location: location, keys: keys)
        let firstQuery = (clock.now - firstStart).milliseconds
        let queries = try await Measure.durations(repeat: repetitions) {
            try await Self.query(listings: listings, metadata: metadata, location: location, keys: keys)
        }
        // 首屏样本均匀分布在 1 万项中，覆盖不同的哈希分目录。
        let screenKeys = (0..<60).map { keys[$0 * keys.count / 60] }
        let reads = try await Measure.durations(repeat: repetitions) {
            let data = try await cache.data(for: screenKeys)
            guard data.count == 60 else { throw CacheBenchmarkError.incompleteRead }
            for value in data.values where value.isEmpty { throw CacheBenchmarkError.incompleteRead }
        }
        try await index.flush()
        let querySummary = Summary(queries.map(\.milliseconds))
        let readSummary = Summary(reads.map(\.milliseconds))
        let result = Result(
            environment: .collect(paths: [runDirectory.path], host: nil), finishedAt: Date(), entries: count,
            firstScreenFiles: 60,
            sampleDescription: "8 个确定性合成图案，ImageIO 编码为有效 320×480 sRGB JPEG，循环写入不同 cacheKey 的独立文件；元数据使用 MVFoundation.ImageMetadata。",
            thumbnailPixelSize: PixelSize(width: 320, height: 480), thumbnailBytes: Summary(images.map { Double($0.count) }), totalThumbnailBytes: totalBytes,
            queryDescription: "每次依次从 SQLite 读取并解码完整 DirectoryListing 和全部 10000 条 ImageMetadata；按容器范围查询元数据，计时含 SQL、值解码与完整性计数检查。无查询结果内存缓存。",
            cacheCondition: "重新打开 CacheIndex 后测首查和重复查；操作系统文件页缓存未清空。60 图计时仅含索引查询及并发文件读取，不含图片解码。",
            firstQueryAfterReopenMilliseconds: firstQuery, listingAndMetadataMilliseconds: querySummary, firstScreenReadMilliseconds: readSummary,
            listingAndMetadataLimitMilliseconds: 20, firstScreenReadLimitMilliseconds: 30,
            listingAndMetadataPassed: count == 10_000 && firstQuery <= 20 && (querySummary?.p95 ?? .infinity) <= 20,
            firstScreenReadPassed: (readSummary?.p95 ?? .infinity) <= 30
        )
        progress(String(format: "目录+元数据：重开首查 %.2f ms，P95 %.2f ms；60 图并发读 P95 %.2f ms", firstQuery, querySummary?.p95 ?? 0, readSummary?.p95 ?? 0))
        try JSONReport.write(result, to: output)
    }

    private static func query(listings: DirectoryCache, metadata: MetadataIndex, location: Location, keys: [String]) async throws {
        let listing = try await listings.cachedChildren(of: location)
        let values = try await metadata.values(in: location)
        guard listing?.entries.count == keys.count, values.count == keys.count else { throw CacheBenchmarkError.incompleteRead }
    }

    private static func thumbnail(_ variant: Int) throws -> Data {
        let width = 320, height = 480
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 3 + y + variant * 17) % 256)
                pixels[offset + 1] = UInt8((y * 2 + x / 8 + variant * 29) % 256)
                pixels[offset + 2] = UInt8(((x ^ y) + variant * 11) % 256)
            }
        }
        let bytes = Data(pixels)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CacheBenchmarkError.imageCreation
        }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { throw CacheBenchmarkError.imageCreation }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CacheBenchmarkError.imageCreation }
        return result as Data
    }
}

private enum CacheBenchmarkError: Error {
    case incompleteRead
    case imageCreation
}
