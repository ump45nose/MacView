import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MVFoundation
import MVTestSupport

/// 一个夹具：清单中的期望属性，加上生成它的方法。
struct FixtureSpec: Sendable {
    var fixture: Fixture
    /// 把夹具写到 `url`；目录树类的夹具在 `url` 下建出整棵树。
    var write: @Sendable (URL) async throws -> Void
}

/// 全部夹具。期望属性由生成参数直接给出，不从生成结果中读取，完整性测试才能发现生成器的错误。
enum FixtureCatalog {
    static func specs() throws -> [FixtureSpec] {
        var specs = formats()
        specs += orientations()
        specs += aspects()
        specs += sizes()
        specs += colors()
        specs += animations()
        specs += try zips()
        specs += try tars()
        specs += try gzips()
        specs += try trees()
        specs += videos()
        specs.append(largeDirectory())
        return specs
    }

    private static let local = Fixtures.localDirectory

    // MARK: - 图片

    private static func formats() -> [FixtureSpec] {
        let size = PixelSize(width: 480, height: 720)
        func format(_ name: String, _ type: String, _ purpose: String, progressive: Bool? = nil, encode: @escaping @Sendable (CGImage) throws -> Data) -> FixtureSpec {
            imageFixture("image/format/\(name)", purpose, ImageFacts(type: type, pixelSize: size, progressive: progressive)) {
                try encode(FixtureArt.image(name, size: size))
            }
        }
        return [
            format("baseline.jpg", FixtureType.jpeg, "基线 JPEG", progressive: false) { try FixtureEncoder.jpeg($0) },
            format("progressive.jpg", FixtureType.jpeg, "渐进 JPEG", progressive: true) { try FixtureEncoder.jpeg($0, progressive: true) },
            format("image.png", FixtureType.png, "PNG") { try FixtureEncoder.encode([$0], type: FixtureType.png) },
            format("image.heic", FixtureType.heic, "HEIC；硬件编码，重新生成时字节可能不同") {
                try FixtureEncoder.encode([$0], type: FixtureType.heic, frames: [[kCGImageDestinationLossyCompressionQuality: 0.8]])
            },
            format("image.avif", FixtureType.avif, "AVIF；重新生成时字节可能不同") {
                try FixtureEncoder.encode([$0], type: FixtureType.avif, frames: [[kCGImageDestinationLossyCompressionQuality: 0.8]])
            },
            format("image.tiff", FixtureType.tiff, "TIFF，LZW 压缩") {
                try FixtureEncoder.encode([$0], type: FixtureType.tiff, frames: [[kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]])
            },
            format("image.webp", FixtureType.webp, "WebP，用 cwebp 生成") { try FixtureEncoder.webp([$0]) },
            format("image.psd", FixtureType.psd, "PSD 合成图") { try FixtureEncoder.encode([$0], type: FixtureType.psd) },
        ]
    }

    private static func orientations() -> [FixtureSpec] {
        let upright = PixelSize(width: 240, height: 160)
        return (1...8).map { orientation in
            imageFixture(
                "image/orientation/\(orientation).jpg",
                "EXIF 方向 \(orientation)：像素按逆变换存放，正确处理方向后与方向 1 看起来相同",
                ImageFacts(type: FixtureType.jpeg, pixelSize: upright, orientation: orientation, quadrants: ["#FF0000", "#00FF00", "#0000FF", "#FFFF00"])
            ) {
                try FixtureEncoder.jpeg(FixtureArt.orientation(orientation, upright: upright), quality: 0.9, orientation: orientation)
            }
        }
    }

    private static func aspects() -> [FixtureSpec] {
        let shapes: [(String, Int, Int, String)] = [
            ("square-1x1", 600, 600, "正方形"),
            ("landscape-3x2", 600, 400, "横图"),
            ("portrait-2x3", 400, 600, "竖图，写真图集的常见比例"),
            ("wide-16x9", 640, 360, "宽屏横图"),
            ("tall-9x16", 360, 640, "手机竖屏截图"),
            ("panorama-8x1", 2400, 300, "超宽全景"),
            ("strip-1x12", 300, 3600, "超长条漫"),
        ]
        return shapes.map { name, width, height, purpose in
            let size = PixelSize(width: width, height: height)
            return imageFixture("image/aspect/\(name).jpg", "宽高比：\(purpose)", ImageFacts(type: FixtureType.jpeg, pixelSize: size)) {
                try FixtureEncoder.jpeg(FixtureArt.image(name, size: size))
            }
        }
    }

    private static func sizes() -> [FixtureSpec] {
        let sizes: [(String, Int, Int, String)] = [
            ("image/size/1x1.png", 1, 1, "最小的图"),
            ("image/size/64x64.png", 64, 64, "小图标"),
            ("image/size/3600x5400.jpg", 3600, 5400, "写真图集的典型尺寸"),
            ("\(local)/image/20000x20000.jpg", 20000, 20000, "超过 GPU 纹理上限（16384）和显示解码上限的大图"),
        ]
        return sizes.map { path, width, height, purpose in
            let size = PixelSize(width: width, height: height)
            let type = path.hasSuffix(".png") ? FixtureType.png : FixtureType.jpeg
            return imageFixture(path, "尺寸：\(purpose)", ImageFacts(type: type, pixelSize: size)) {
                let image = try FixtureArt.image("\(width)×\(height)", size: size)
                return type == FixtureType.png ? try FixtureEncoder.encode([image], type: type) : try FixtureEncoder.jpeg(image)
            }
        }
    }

    private static func colors() -> [FixtureSpec] {
        let size = PixelSize(width: 300, height: 450)
        return [
            imageFixture("image/color/display-p3.jpg", "Display P3 色域，内嵌配置文件", ImageFacts(type: FixtureType.jpeg, pixelSize: size, colorModel: "RGB", profileName: "Display P3")) {
                try FixtureEncoder.jpeg(FixtureArt.image("Display P3", size: size, pixels: .displayP3))
            },
            imageFixture("image/color/gray.jpg", "灰度 JPEG，扫描的漫画常见", ImageFacts(type: FixtureType.jpeg, pixelSize: size, colorModel: "Gray", depth: 8)) {
                try FixtureEncoder.jpeg(FixtureArt.image("Gray", size: size, pixels: .gray))
            },
            imageFixture("image/color/cmyk.jpg", "CMYK JPEG，印刷用的扫描件常见", ImageFacts(type: FixtureType.jpeg, pixelSize: size, colorModel: "CMYK")) {
                try FixtureEncoder.jpeg(FixtureArt.image("CMYK", size: size, pixels: .cmyk))
            },
            imageFixture("image/color/alpha.png", "带透明通道，四周透明", ImageFacts(type: FixtureType.png, pixelSize: size, hasAlpha: true)) {
                try FixtureEncoder.encode([FixtureArt.image("Alpha", size: size, pixels: .rgba)], type: FixtureType.png)
            },
            imageFixture("image/color/16bit.png", "每个分量 16 位", ImageFacts(type: FixtureType.png, pixelSize: size, depth: 16, hasAlpha: false)) {
                try FixtureEncoder.encode([FixtureArt.image("16 bit", size: size, pixels: .rgb16)], type: FixtureType.png)
            },
        ]
    }

    private static func animations() -> [FixtureSpec] {
        let size = PixelSize(width: 240, height: 160)
        @Sendable func frames(_ title: String, _ count: Int) throws -> [CGImage] {
            try (0..<count).map { try FixtureArt.image("\(title) \($0 + 1)/\(count)", size: size, phase: Double($0) / Double(max(count - 1, 1))) }
        }
        let even = Array(repeating: 0.1, count: 12)
        let uneven = [0.05, 0.2, 0.5, 1.0]
        return [
            imageFixture("animated/loop.gif", "GIF 动图，12 帧，无限循环", ImageFacts(type: FixtureType.gif, pixelSize: size, frameCount: 12, frameDelays: even, loopCount: 0)) {
                try FixtureEncoder.gif(frames("GIF", 12), delays: even, loopCount: 0)
            },
            imageFixture("animated/uneven.gif", "GIF 动图，各帧时长不同，循环 3 次", ImageFacts(type: FixtureType.gif, pixelSize: size, frameCount: 4, frameDelays: uneven, loopCount: 3)) {
                try FixtureEncoder.gif(frames("GIF", 4), delays: uneven, loopCount: 3)
            },
            imageFixture("animated/single.gif", "只有一帧的 GIF", ImageFacts(type: FixtureType.gif, pixelSize: size)) {
                try FixtureEncoder.gif(frames("GIF", 1))
            },
            imageFixture("animated/loop.png", "APNG 动图，12 帧，无限循环", ImageFacts(type: FixtureType.png, pixelSize: size, frameCount: 12, frameDelays: even, loopCount: 0)) {
                try FixtureEncoder.apng(frames("APNG", 12), delays: even, loopCount: 0)
            },
            imageFixture("animated/loop.webp", "WebP 动图，12 帧，无限循环，用 img2webp 生成", ImageFacts(type: FixtureType.webp, pixelSize: size, frameCount: 12, frameDelays: even, loopCount: 0)) {
                try FixtureEncoder.webp(frames("WebP", 12), delay: 0.1, loopCount: 0)
            },
        ]
    }

    private static func imageFixture(_ path: String, _ purpose: String, _ facts: ImageFacts, encode: @escaping @Sendable () throws -> Data) -> FixtureSpec {
        FixtureSpec(fixture: Fixture(path: path, purpose: purpose, image: facts)) { try encode().write(to: $0) }
    }

    // MARK: - 压缩包

    private static func zips() throws -> [FixtureSpec] {
        func entries(_ archive: String, _ paths: [String], _ compression: ZipEntry.Compression = .deflate) throws -> [ZipEntry] {
            try paths.map { $0.hasSuffix("/") ? ZipEntry(path: $0) : ZipEntry(path: $0, data: try page("\(archive) · \($0)"), compression: compression) }
        }
        func zip(_ name: String, _ purpose: String, _ entries: [ZipEntry], options: ZipOptions = ZipOptions(), features: [ArchiveFeature] = [], nested: [String: ArchiveFacts] = [:]) throws -> FixtureSpec {
            let data = try ZipWriter.archive(entries, options: options)
            let facts = ArchiveFacts(format: .zip, features: features, entries: entries.map { zipFacts($0, archive: nested[$0.path]) })
            return FixtureSpec(fixture: Fixture(path: "archive/zip/\(name)", purpose: purpose, archive: facts)) { try data.write(to: $0) }
        }

        let chinese = ["封面.jpg", "第1话/", "第1话/001.jpg", "第1话/002.jpg"]
        let innerStored = try entries("inner-stored.zip", ["001.jpg", "002.jpg"])
        let innerDeflate = try entries("inner-deflate.zip", ["001.jpg", "002.jpg"], .stored)
        let finder = try entries("macos-metadata.zip", ["book/", "book/001.jpg", "book/002.jpg"]) + [
            ZipEntry(path: "__MACOSX/"),
            ZipEntry(path: "__MACOSX/book/"),
            ZipEntry(path: "__MACOSX/book/._001.jpg", data: appleDouble),
            ZipEntry(path: "__MACOSX/book/._002.jpg", data: appleDouble),
        ]
        return [
            try zip("stored.zip", "stored 条目；子目录有目录条目", entries("stored.zip", ["001.jpg", "002.jpg", "sub/", "sub/003.jpg"], .stored)),
            try zip("deflate.zip", "deflate 条目；子目录没有目录条目", entries("deflate.zip", ["chapter/001.jpg", "chapter/002.jpg", "chapter/003.jpg"])),
            try zip("book.cbz", "扩展名为 cbz 的 zip", entries("book.cbz", ["001.jpg", "002.jpg", "003.jpg"])),
            try zip("utf8-names.zip", "中文文件名，带 UTF-8 标志", entries("utf8-names.zip", chinese), options: ZipOptions(names: .utf8), features: [.utf8Names]),
            try zip(
                "gbk-names.zip", "中文文件名用 GBK 编码、不带 UTF-8 标志，制作方为 MS-DOS，与中文 Windows 上的旧压缩工具一致",
                entries("gbk-names.zip", chinese), options: ZipOptions(names: .gbk), features: [.gbkNames]
            ),
            try zip(
                "zip64.zip", "小文件也用 ZIP64：条目的大小与偏移在 ZIP64 扩展字段里，目录结尾用 ZIP64 记录",
                entries("zip64.zip", ["001.jpg"], .stored) + entries("zip64.zip", ["002.jpg"]), options: ZipOptions(zip64: true), features: [.zip64]
            ),
            try zip(
                "data-descriptor.zip", "CRC 与大小写在数据之后的数据描述符里，本地头中为 0",
                entries("data-descriptor.zip", ["001.jpg", "002.jpg"]), options: ZipOptions(dataDescriptor: true), features: [.dataDescriptor]
            ),
            try zip(
                "zip64-data-descriptor.zip", "ZIP64 加数据描述符，描述符中的大小为 8 字节",
                entries("zip64-data-descriptor.zip", ["001.jpg", "002.jpg"]), options: ZipOptions(zip64: true, dataDescriptor: true), features: [.zip64, .dataDescriptor]
            ),
            try zip(
                "nested.zip", "zip 套 zip：inner-stored.zip 以 stored 存放，可以直接映射偏移；inner-deflate.zip 以 deflate 存放",
                [
                    ZipEntry(path: "inner-stored.zip", data: try ZipWriter.archive(innerStored), compression: .stored),
                    ZipEntry(path: "inner-deflate.zip", data: try ZipWriter.archive(innerDeflate), compression: .deflate),
                ],
                nested: [
                    "inner-stored.zip": ArchiveFacts(format: .zip, entries: innerStored.map { zipFacts($0) }),
                    "inner-deflate.zip": ArchiveFacts(format: .zip, entries: innerDeflate.map { zipFacts($0) }),
                ]
            ),
            try zip(
                "macos-metadata.zip", "访达“压缩”生成的结构：__MACOSX 下有 AppleDouble 元数据，用数据描述符",
                finder, options: ZipOptions(dataDescriptor: true), features: [.dataDescriptor]
            ),
        ]
    }

    private static func tars() throws -> [FixtureSpec] {
        func entries(_ archive: String, _ paths: [String]) throws -> [TarEntry] {
            try paths.map { $0.hasSuffix("/") ? TarEntry(path: $0) : TarEntry(path: $0, data: try page("\(archive) · \(($0 as NSString).lastPathComponent)")) }
        }
        func tar(_ name: String, _ purpose: String, _ entries: [TarEntry], style: TarWriter.Style, format: ArchiveFormat = .tar, features: [ArchiveFeature] = []) throws -> FixtureSpec {
            let bytes = try TarWriter.archive(entries, style: style)
            let data = format == .tarGzip ? try Gzip.compress(bytes) : bytes
            let facts = ArchiveFacts(format: format, features: features, entries: entries.map(tarFacts))
            return FixtureSpec(fixture: Fixture(path: "archive/tar/\(name)", purpose: purpose, archive: facts)) { try data.write(to: $0) }
        }

        let prefixed = "book/a-directory-name-long-enough-to-need-the-ustar-prefix-field/and-a-second-directory-to-pass-one-hundred-bytes/003.jpg"
        let paxPath = (1...6).map { "level-\($0)-" + String(repeating: "x", count: 40) }.joined(separator: "/") + "/002.jpg"
        let gnuPath = "chapter-with-a-rather-long-directory-name/and-an-even-longer-file-name-so-the-whole-path-exceeds-100-bytes.jpg"
        return [
            try tar("ustar.tar", "POSIX ustar：目录条目，以及超过 100 字节、拆进 prefix 字段的路径", entries("ustar.tar", ["book/", "book/001.jpg", "book/002.jpg", prefixed]), style: .ustar, features: [.ustarPrefix]),
            try tar("pax.tar", "pax 扩展头：中文文件名，以及超过 255 字节的路径", entries("pax.tar", ["001.jpg", "封面.jpg", paxPath]), style: .pax, features: [.pax]),
            try tar("gnu-longname.tar", "GNU 格式：超过 100 字节的路径写在 ././@LongLink 条目里", entries("gnu-longname.tar", ["001.jpg", gnuPath]), style: .gnu, features: [.gnuLongName]),
            try tar("book.tar.gz", "gzip 压缩的 tar", entries("book.tar.gz", ["001.jpg", "002.jpg", "003.jpg"]), style: .ustar, format: .tarGzip),
        ]
    }

    private static func gzips() throws -> [FixtureSpec] {
        let image = try page("image.jpg.gz · image.jpg")
        let single = try Gzip.compress(image, originalName: "image.jpg")
        let pages = try ["001.jpg", "002.jpg"].map { TarEntry(path: $0, data: try page("pages.gz · \($0)")) }
        let tar = try Gzip.compress(TarWriter.archive(pages, style: .ustar))
        return [
            FixtureSpec(fixture: Fixture(
                path: "archive/gzip/image.jpg.gz", purpose: "单个文件的 gzip，头部记有原文件名",
                archive: ArchiveFacts(format: .gzip, features: [.originalName], entries: [ArchiveEntryFacts(path: "image.jpg", size: Int64(image.count), sha256: sha256Hex(image))])
            )) { try single.write(to: $0) },
            FixtureSpec(fixture: Fixture(
                path: "archive/gzip/pages.gz", purpose: "扩展名只有 .gz、内容是 tar，要按内容识别",
                archive: ArchiveFacts(format: .gzip, features: [.tarContent], entries: pages.map(tarFacts))
            )) { try tar.write(to: $0) },
        ]
    }

    private static func zipFacts(_ entry: ZipEntry, archive: ArchiveFacts? = nil) -> ArchiveEntryFacts {
        entry.isDirectory
            ? ArchiveEntryFacts(path: entry.path, size: 0)
            : ArchiveEntryFacts(path: entry.path, size: Int64(entry.data.count), sha256: sha256Hex(entry.data), compression: entry.compression.rawValue, archive: archive)
    }

    private static func tarFacts(_ entry: TarEntry) -> ArchiveEntryFacts {
        entry.isDirectory ? ArchiveEntryFacts(path: entry.path, size: 0) : ArchiveEntryFacts(path: entry.path, size: Int64(entry.data.count), sha256: sha256Hex(entry.data))
    }

    // MARK: - 目录树

    private static func trees() throws -> [FixtureSpec] {
        func pages(_ tree: String, _ paths: [String]) throws -> [(String, Data)] {
            try paths.map { ($0, try page("\(tree) · \(($0 as NSString).lastPathComponent)")) }
        }
        let deep = ["第1层/001.jpg", "第1层/第2层/第3层/第4层/002.jpg", "第1层/第2层/第3层/第4层/第5层/第6层/第7层/第8层/003.jpg"]
        return [
            tree("deep", "8 层嵌套的目录，第 1、4、8 层各有一张图", try pages("deep", deep)),
            tree(
                "pass-through", "单层穿透：“一层”只含子目录和 .DS_Store、没有媒体，应一路进入“一层/二层/书”；“不穿透”有图，留在原地",
                try pages("pass-through", ["一层/二层/书/001.jpg", "一层/二层/书/002.jpg", "不穿透/封面.jpg", "不穿透/子目录/001.jpg"]) + [("一层/.DS_Store", dsStore)]
            ),
            tree(
                "hidden", "隐藏文件与系统文件：._*（AppleDouble）、.DS_Store、Thumbs.db、.url 快捷方式，都不是页面",
                try pages("hidden", ["001.jpg", "002.jpg"]) + [("._001.jpg", appleDouble), (".DS_Store", dsStore), ("Thumbs.db", thumbsDatabase), ("说明.url", internetShortcut)]
            ),
        ]
    }

    private static func tree(_ name: String, _ purpose: String, _ files: [(String, Data)]) -> FixtureSpec {
        var entries = Set<String>()
        for (path, _) in files {
            let components = path.split(separator: "/")
            for depth in 1..<components.count {
                entries.insert(components[..<depth].joined(separator: "/") + "/")
            }
            entries.insert(path)
        }
        return FixtureSpec(fixture: Fixture(path: "tree/\(name)", purpose: purpose, directory: DirectoryFacts(entries: entries.sorted()))) { root in
            for (path, data) in files {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
    }

    private static func largeDirectory() -> FixtureSpec {
        let count = 10_000
        return FixtureSpec(fixture: Fixture(
            path: "\(local)/tree/10000", purpose: "1 万项的目录：page1.jpg 到 page10000.jpg，编号不补零，自然排序与字节序不同",
            directory: DirectoryFacts(count: count)
        )) { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let size = PixelSize(width: 64, height: 96)
            for number in 1...count {
                try FixtureEncoder.jpeg(FixtureArt.image("\(number)", size: size), quality: 0.7).write(to: root.appending(path: "page\(number).jpg"))
            }
        }
    }

    // MARK: - 视频

    private static func videos() -> [FixtureSpec] {
        let size = PixelSize(width: 1280, height: 720)
        let clips: [(String, AVFileType, AVVideoCodecType, String, Bool, String)] = [
            ("h264.mp4", .mp4, .h264, "avc1", false, "H.264，mp4"),
            ("hevc.mp4", .mp4, .hevc, "hvc1", false, "HEVC，mp4"),
            ("h264.mov", .mov, .h264, "avc1", false, "H.264，mov"),
            ("hevc.mov", .mov, .hevc, "hvc1", false, "HEVC，mov"),
            ("h264.m4v", .m4v, .h264, "avc1", false, "H.264，m4v"),
            ("rotated.mov", .mov, .h264, "avc1", true, "H.264，轨道变换旋转 90°、显示为竖屏，与竖着拍的手机视频一样"),
        ]
        return clips.map { name, fileType, codec, fourCC, rotated, purpose in
            let spec = FixtureVideo.Spec(fileType: fileType, codec: codec, size: size, frames: 60, frameRate: 30, rotated: rotated)
            let facts = VideoFacts(
                codec: fourCC, pixelSize: rotated ? PixelSize(width: size.height, height: size.width) : size,
                rotation: rotated ? 90 : 0, duration: 2, frameRate: 30
            )
            return FixtureSpec(fixture: Fixture(path: "\(local)/video/\(name)", purpose: "视频：\(purpose)；2 秒，30 帧/秒", video: facts)) { url in
                try await FixtureVideo.write(spec, title: name, to: url)
            }
        }
    }

    // MARK: - 内容

    /// 压缩包和目录树里的页面：300×450 的 JPEG。
    private static func page(_ title: String) throws -> Data {
        try FixtureEncoder.jpeg(FixtureArt.image(title, size: PixelSize(width: 300, height: 450)), quality: 0.8)
    }

    /// 只含 Finder 信息的 AppleDouble 文件，即非 HFS 卷上的 `._*`。
    private static let appleDouble = Data(
        [0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00] + Array("Mac OS X        ".utf8)
            + [0x00, 0x01, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x26, 0x00, 0x00, 0x00, 0x20] + Array(repeating: 0, count: 32)
    )
    private static let dsStore = Data([0x00, 0x00, 0x00, 0x01] + Array("Bud1".utf8) + Array(repeating: 0, count: 24))
    /// Windows 的缩略图缓存，OLE 复合文档。
    private static let thumbsDatabase = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 504))
    private static let internetShortcut = Data("[InternetShortcut]\r\nURL=https://example.com/\r\n".utf8)
}

enum FixtureGenerator {
    /// 生成夹具并写出清单（清单总是列出全部夹具）。
    ///
    /// 生成器独占入库夹具的第一级目录和 `local/generated`，生成前先删掉它们；`local/` 下的其他内容不动。
    @discardableResult
    static func generate(into root: URL, includeLocal: Bool = true) async throws -> FixtureManifest {
        let specs = try FixtureCatalog.specs()
        let selected = specs.filter { includeLocal || !$0.fixture.isLocal }
        let fileManager = FileManager.default
        for directory in Set(selected.map { $0.fixture.isLocal ? Fixtures.localDirectory : String($0.fixture.path.prefix { $0 != "/" }) }) {
            let url = Fixtures.url(directory, in: root)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        for spec in selected {
            let url = Fixtures.url(spec.fixture.path, in: root)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await spec.write(url)
        }
        let manifest = FixtureManifest(fixtures: specs.map(\.fixture))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(manifest) + Data("\n".utf8)).write(to: Fixtures.url("manifest.json", in: root), options: .atomic)
        return manifest
    }
}
