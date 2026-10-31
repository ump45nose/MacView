import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MVFoundation
import MVTestSupport

/// 核对夹具与清单是否一致：图片用 ImageIO，视频用 AVFoundation，压缩包用系统的 bsdtar 和 gzip 解出后比对，
/// 再直接读 zip 与 tar 的头，确认要覆盖的特性确实存在。
enum FixtureVerifier {
    /// 返回不一致之处；为空表示一致。
    static func issues(of fixture: Fixture, in root: URL) async -> [String] {
        let url = Fixtures.url(fixture.path, in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return ["不存在"] }
        do {
            if let facts = fixture.image { return try imageIssues(facts, at: url) }
            if let facts = fixture.video { return try await videoIssues(facts, at: url) }
            if let facts = fixture.archive { return try archiveIssues(facts, at: url) }
            if let facts = fixture.directory { return try directoryIssues(facts, at: url) }
            return ["清单没有给出期望属性"]
        } catch {
            return ["核对失败：\(error)"]
        }
    }

    // MARK: - 图片

    private static func imageIssues(_ facts: ImageFacts, at url: URL) throws -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetStatus(source) == .statusComplete else {
            throw FixtureError("ImageIO 无法读取")
        }
        var issues = Issues()
        issues.check("类型", CGImageSourceGetType(source) as String?, facts.type)
        let count = CGImageSourceGetCount(source)
        issues.check("帧数", count, facts.frameCount)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        issues.check("方向", orientation, facts.orientation)
        issues.check("像素尺寸", orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height), facts.pixelSize)
        if let progressive = facts.progressive {
            let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
            issues.check("渐进", jfif?[kCGImagePropertyJFIFIsProgressive] as? Bool ?? false, progressive)
        }
        if let delays = facts.frameDelays {
            let actual = (0..<count).map { frameDelay(source, at: $0) }
            if actual.count != delays.count || zip(actual, delays).contains(where: { abs($0 - $1) > 0.0005 }) {
                issues.add("帧时长为 \(actual)，应为 \(delays)")
            }
        }
        if let loopCount = facts.loopCount {
            issues.check("循环次数", self.loopCount(source), loopCount)
        }
        if let colorModel = facts.colorModel {
            issues.check("颜色模型", properties[kCGImagePropertyColorModel] as? String, colorModel)
        }
        if let depth = facts.depth {
            issues.check("每分量位数", properties[kCGImagePropertyDepth] as? Int, depth)
        }
        if let hasAlpha = facts.hasAlpha {
            issues.check("透明通道", properties[kCGImagePropertyHasAlpha] as? Bool ?? false, hasAlpha)
        }
        if let profileName = facts.profileName {
            issues.check("配置文件", properties[kCGImagePropertyProfileName] as? String, profileName)
        }
        if let quadrants = facts.quadrants {
            issues.list += try quadrantIssues(source, size: facts.pixelSize, expected: quadrants)
        }
        return issues.list
    }

    private static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (container, unclamped, clamped) in keys {
            if let values = properties[container] as? [CFString: Any], let delay = (values[unclamped] ?? values[clamped]) as? Double {
                return delay
            }
        }
        return 0
    }

    private static func loopCount(_ source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ]
        for (container, key) in keys {
            if let values = properties[container] as? [CFString: Any], let count = values[key] as? Int {
                return count
            }
        }
        return nil
    }

    /// 按方向解码后，取四个象限中心的颜色，每个分量允许 48 的误差（JPEG 有损）。
    private static func quadrantIssues(_ source: CGImageSource, size: PixelSize, expected: [String]) throws -> [String] {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else {
            throw FixtureError("无法按方向解码")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw FixtureError("无法读取像素") }
        let points = [(1, 1), (3, 1), (1, 3), (3, 3)].map { (image.width * $0 / 4, image.height * $1 / 4) }
        var issues: [String] = []
        for ((x, y), hex) in zip(points, expected) {
            let offset = y * context.bytesPerRow + x * 4
            let actual = (0..<3).map { Int(pixels[offset + $0]) }
            let target = (0..<3).map { Int(hex.dropFirst(1 + $0 * 2).prefix(2), radix: 16) ?? -1 }
            if zip(actual, target).contains(where: { abs($0 - $1) > 48 }) {
                issues.append("(\(x), \(y)) 的颜色为 #\(actual.map { String(format: "%02X", $0) }.joined())，应为 \(hex)")
            }
        }
        return issues
    }

    // MARK: - 视频

    private static func videoIssues(_ facts: VideoFacts, at url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return ["没有视频轨道"] }
        let (naturalSize, transform, frameRate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        var issues = Issues()
        issues.check("编码", formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }, facts.codec)
        issues.check("旋转", (Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()) + 360) % 360, facts.rotation)
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        issues.check("显示尺寸", PixelSize(width: Int(displayed.width.rounded()), height: Int(displayed.height.rounded())), facts.pixelSize)
        if abs(duration.seconds - facts.duration) > 0.01 {
            issues.add("时长为 \(duration.seconds) 秒，应为 \(facts.duration)")
        }
        if abs(Double(frameRate) - facts.frameRate) > 0.01 {
            issues.add("帧率为 \(frameRate)，应为 \(facts.frameRate)")
        }
        return issues.list
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    // MARK: - 压缩包

    private static func archiveIssues(_ facts: ArchiveFacts, at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        switch facts.format {
        case .zip:
            // macOS 的 bsdtar 默认把 __MACOSX/ 下的 AppleDouble 当作元数据，不列出也不解出；关掉后才能看到实际存放的条目。
            let options = ["zip:!mac-ext"] + (facts.features.contains(.gbkNames) ? ["hdrcharset=CP936"] : [])
            return zipHeaderIssues(facts, [UInt8](data)) + (try extractionIssues(facts, archive: url, options: options))
        case .tar:
            return tarHeaderIssues(facts, [UInt8](data)) + (try extractionIssues(facts, archive: url))
        case .tarGzip:
            return try extractionIssues(facts, archive: url)
        case .gzip:
            return try gzipIssues(facts, data, at: url)
        }
    }

    /// 用 bsdtar 列出并解出全部条目，与清单比对路径、顺序、大小和 SHA-256；条目本身是压缩包时递归核对。
    private static func extractionIssues(_ facts: ArchiveFacts, archive url: URL, options: [String] = []) throws -> [String] {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "mvbench-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let options = options.isEmpty ? [] : ["--options", options.joined(separator: ",")]
        let locale = ["LC_ALL": "en_US.UTF-8"]
        let listing = try ExternalTool.run("/usr/bin/bsdtar", options + ["-tf", url.path], environment: locale)
        var issues = Issues()
        issues.check("bsdtar 列出的条目", String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init), facts.entries.map(\.path))
        try ExternalTool.run("/usr/bin/bsdtar", options + ["-xf", url.path, "-C", scratch.path, "--no-mac-metadata"], environment: locale)

        for entry in facts.entries {
            let file = scratch.appending(path: entry.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue == entry.isDirectory else {
                issues.add("解出后没有\(entry.isDirectory ? "目录" : "文件") \(entry.path)")
                continue
            }
            guard !entry.isDirectory else { continue }
            let content = try Data(contentsOf: file)
            issues.check("\(entry.path) 的大小", Int64(content.count), entry.size)
            issues.check("\(entry.path) 的 SHA-256", sha256Hex(content), entry.sha256)
            if let inner = entry.archive {
                issues.list += try archiveIssues(inner, at: file).map { "\(entry.path)!/\($0)" }
            }
        }
        let expected = Set(facts.entries.filter { !$0.isDirectory }.map(\.path))
        for path in try FileManager.default.subpathsOfDirectory(atPath: scratch.path).sorted() where !expected.contains(path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: scratch.appending(path: path).path, isDirectory: &isDirectory), !isDirectory.boolValue {
                issues.add("解出了清单之外的文件 \(path)")
            }
        }
        return issues.list
    }

    /// 读中央目录，核对各条目的压缩方法，以及 ZIP64、数据描述符和文件名编码。
    private static func zipHeaderIssues(_ facts: ArchiveFacts, _ bytes: [UInt8]) -> [String] {
        let reader = LittleEndian(bytes)
        guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { reader.u32($0) == 0x0605_4B50 }) else {
            return ["找不到中央目录结尾"]
        }
        var observed = Set<ArchiveFeature>()
        var count = reader.u16(end + 10)
        var position = reader.u32(end + 16)
        if end >= 20, reader.u32(end - 20) == 0x0706_4B50 {
            observed.insert(.zip64)
            let record = reader.u64(end - 20 + 8)
            count = reader.u64(record + 32)
            position = reader.u64(record + 48)
        }
        var issues = Issues()
        issues.check("中央目录的条目数", count, facts.entries.count)
        for index in 0..<min(count, facts.entries.count) {
            guard position + 46 <= bytes.count, reader.u32(position) == 0x0201_4B50 else {
                issues.add("第 \(index + 1) 个中央目录条目损坏")
                break
            }
            let flags = reader.u16(position + 8)
            let method = reader.u16(position + 10)
            let nameLength = reader.u16(position + 28)
            let name = bytes[(position + 46)..<min(position + 46 + nameLength, bytes.count)]
            if flags & 1 << 11 != 0 {
                observed.insert(.utf8Names)
            } else if name.contains(where: { $0 >= 0x80 }) {
                observed.insert(.gbkNames)
            }
            if flags & 1 << 3 != 0 {
                observed.insert(.dataDescriptor)
            }
            let entry = facts.entries[index]
            if let compression = entry.compression {
                issues.check("\(entry.path) 的压缩方法", method == 8 ? "deflate" : method == 0 ? "stored" : "方法 \(method)", compression)
            }
            position += 46 + nameLength + reader.u16(position + 30) + reader.u16(position + 32)
        }
        issues.list += featureIssues(observed, facts, among: [.zip64, .dataDescriptor, .utf8Names, .gbkNames])
        return issues.list
    }

    /// 逐个读 tar 头，确认 pax 扩展头、GNU 长文件名和 ustar prefix 字段确实出现。
    private static func tarHeaderIssues(_ facts: ArchiveFacts, _ bytes: [UInt8]) -> [String] {
        var observed = Set<ArchiveFeature>()
        var position = 0
        while position + 512 <= bytes.count, bytes[position..<position + 512].contains(where: { $0 != 0 }) {
            switch bytes[position + 156] {
            case UInt8(ascii: "x"): observed.insert(.pax)
            case UInt8(ascii: "L"): observed.insert(.gnuLongName)
            default: break
            }
            if Array(bytes[(position + 257)..<(position + 263)]) == Array("ustar\u{0}".utf8), bytes[position + 345] != 0 {
                observed.insert(.ustarPrefix)
            }
            let size = Int(String(decoding: bytes[(position + 124)..<(position + 136)].prefix { $0 != 0 && $0 != UInt8(ascii: " ") }, as: UTF8.self), radix: 8) ?? 0
            position += 512 + (size + 511) / 512 * 512
        }
        return featureIssues(observed, facts, among: [.pax, .gnuLongName, .ustarPrefix])
    }

    private static func gzipIssues(_ facts: ArchiveFacts, _ data: Data, at url: URL) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return ["不是 gzip"] }
        let originalName = bytes[3] & 0x08 == 0 ? nil : String(decoding: bytes[10...].prefix { $0 != 0 }, as: UTF8.self)
        var issues = Issues()
        issues.check("头部是否记有原文件名", originalName != nil, facts.features.contains(.originalName))
        if facts.features.contains(.tarContent) {
            // bsdtar 自动识别 gzip 压缩，内容不是 tar 时会失败。
            issues.list += try extractionIssues(facts, archive: url)
            return issues.list
        }
        guard facts.entries.count == 1, let entry = facts.entries.first else { return issues.list + ["单文件 gzip 的清单应只有一个条目"] }
        let content = try ExternalTool.run("/usr/bin/gzip", ["-dc", url.path])
        if let originalName {
            issues.check("原文件名", originalName, entry.path)
        }
        issues.check("解压后的大小", Int64(content.count), entry.size)
        issues.check("解压后的 SHA-256", sha256Hex(content), entry.sha256)
        return issues.list
    }

    private static func featureIssues(_ observed: Set<ArchiveFeature>, _ facts: ArchiveFacts, among relevant: Set<ArchiveFeature>) -> [String] {
        let expected = Set(facts.features).intersection(relevant)
        guard observed != expected else { return [] }
        return ["特性为 \(observed.map(\.rawValue).sorted())，应为 \(expected.map(\.rawValue).sorted())"]
    }

    // MARK: - 目录树

    private static func directoryIssues(_ facts: DirectoryFacts, at url: URL) throws -> [String] {
        let fileManager = FileManager.default
        let entries = try fileManager.subpathsOfDirectory(atPath: url.path).map { path in
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.appending(path: path).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? path + "/" : path
        }
        var issues = Issues()
        if let expected = facts.entries {
            let actual = Set(entries)
            let missing = expected.filter { !actual.contains($0) }
            let extra = Set(expected).symmetricDifference(actual).subtracting(missing).sorted()
            if !missing.isEmpty { issues.add("缺少 \(missing)") }
            if !extra.isEmpty { issues.add("多出 \(extra)") }
        }
        if let count = facts.count {
            issues.check("项数", entries.count, count)
        }
        return issues.list
    }
}

private struct Issues {
    var list: [String] = []

    mutating func check<Value: Equatable>(_ name: String, _ actual: Value, _ expected: Value) {
        if actual != expected {
            list.append("\(name)为 \(actual)，应为 \(expected)")
        }
    }

    mutating func add(_ issue: String) {
        list.append(issue)
    }
}

/// 按小端读整数；越界的部分按 0 处理，损坏的文件只会核对失败，不会越界访问。
private struct LittleEndian {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func u16(_ offset: Int) -> Int { value(offset, 2) }
    func u32(_ offset: Int) -> Int { value(offset, 4) }
    func u64(_ offset: Int) -> Int { value(offset, 8) }

    private func value(_ offset: Int, _ width: Int) -> Int {
        guard offset >= 0, offset + width <= bytes.count else { return 0 }
        return (0..<width).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
    }
}
