import Foundation
import MVFoundation

/// 仓库中的测试夹具。由 `mvbench fixtures` 生成，清单见 `Fixtures/manifest.json`。
public enum Fixtures {
    /// 仓库的 `Fixtures/` 目录。
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MVTestSupport
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // MacViewKit
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    /// 不入库的大夹具所在的目录，相对 `root`。
    public static let localDirectory = "local/generated"

    public static func url(_ path: String, in root: URL = root) -> URL {
        root.appending(path: path)
    }

    public static func manifest(in root: URL = root) throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url("manifest.json", in: root)))
    }

    /// 大夹具是否已经生成。
    public static func hasLocal(in root: URL = root) -> Bool {
        FileManager.default.fileExists(atPath: url(localDirectory, in: root).path)
    }
}

public struct FixtureManifest: Codable, Sendable, Equatable {
    public var fixtures: [Fixture]

    public init(fixtures: [Fixture]) {
        self.fixtures = fixtures
    }

    public subscript(path: String) -> Fixture? {
        fixtures.first { $0.path == path }
    }
}

/// 一个夹具：位置、用途与期望属性。按类型只设其中一种属性。
public struct Fixture: Codable, Sendable, Equatable {
    /// 相对 `Fixtures/` 的路径；以 `local/generated/` 开头的不入库。
    public var path: String
    public var purpose: String
    public var image: ImageFacts?
    public var video: VideoFacts?
    public var archive: ArchiveFacts?
    public var directory: DirectoryFacts?

    public init(path: String, purpose: String, image: ImageFacts? = nil, video: VideoFacts? = nil, archive: ArchiveFacts? = nil, directory: DirectoryFacts? = nil) {
        self.path = path
        self.purpose = purpose
        self.image = image
        self.video = video
        self.archive = archive
        self.directory = directory
    }

    public var isLocal: Bool {
        path.hasPrefix(Fixtures.localDirectory + "/")
    }
}

public struct ImageFacts: Codable, Sendable, Equatable {
    /// 类型标识，例如 `public.jpeg`。
    public var type: String
    /// 按 EXIF 方向换算后的像素尺寸。
    public var pixelSize: PixelSize
    public var orientation: Int
    public var frameCount: Int
    /// 动图各帧的时长，秒。
    public var frameDelays: [Double]?
    /// 动图的循环次数，0 表示无限循环。
    public var loopCount: Int?
    public var progressive: Bool?
    /// 颜色模型：`RGB`、`Gray` 或 `CMYK`。
    public var colorModel: String?
    /// 每个分量的位数。
    public var depth: Int?
    public var hasAlpha: Bool?
    /// 内嵌 ICC 配置文件的名称。
    public var profileName: String?
    /// 按方向换算后，左上、右上、左下、右下四个象限中心的颜色，例如 `#FF0000`。
    public var quadrants: [String]?

    public init(
        type: String, pixelSize: PixelSize, orientation: Int = 1, frameCount: Int = 1, frameDelays: [Double]? = nil, loopCount: Int? = nil,
        progressive: Bool? = nil, colorModel: String? = nil, depth: Int? = nil, hasAlpha: Bool? = nil, profileName: String? = nil, quadrants: [String]? = nil
    ) {
        self.type = type
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.frameCount = frameCount
        self.frameDelays = frameDelays
        self.loopCount = loopCount
        self.progressive = progressive
        self.colorModel = colorModel
        self.depth = depth
        self.hasAlpha = hasAlpha
        self.profileName = profileName
        self.quadrants = quadrants
    }
}

public struct VideoFacts: Codable, Sendable, Equatable {
    /// 编码的 FourCC，例如 `avc1`、`hvc1`。
    public var codec: String
    /// 按轨道变换换算后的显示尺寸。
    public var pixelSize: PixelSize
    /// 轨道变换的顺时针旋转角度。
    public var rotation: Int
    /// 秒。
    public var duration: Double
    public var frameRate: Double

    public init(codec: String, pixelSize: PixelSize, rotation: Int = 0, duration: Double, frameRate: Double) {
        self.codec = codec
        self.pixelSize = pixelSize
        self.rotation = rotation
        self.duration = duration
        self.frameRate = frameRate
    }
}

public struct ArchiveFacts: Codable, Sendable, Equatable {
    public var format: ArchiveFormat
    /// 夹具要覆盖的、从条目上看不出来的特性。
    public var features: [ArchiveFeature]
    /// 按在压缩包中的顺序；目录以 `/` 结尾。gzip 的条目是解压后的文件，内容是 tar 时是 tar 中的条目。
    public var entries: [ArchiveEntryFacts]

    public init(format: ArchiveFormat, features: [ArchiveFeature] = [], entries: [ArchiveEntryFacts]) {
        self.format = format
        self.features = features
        self.entries = entries
    }
}

public enum ArchiveFeature: String, Codable, Sendable {
    /// zip：条目带 UTF-8 标志。
    case utf8Names
    /// zip：条目名是 GBK 编码，不带 UTF-8 标志。
    case gbkNames
    /// zip：全部条目和目录结尾都用 ZIP64 格式。
    case zip64
    /// zip：条目的 CRC 与大小写在数据之后的数据描述符里。
    case dataDescriptor
    /// tar：路径超过 100 字节，用 ustar 的 prefix 字段。
    case ustarPrefix
    /// tar：路径写在 pax 扩展头里。
    case pax
    /// tar：路径写在 GNU 的 `././@LongLink` 条目里。
    case gnuLongName
    /// gzip：头部记有原文件名。
    case originalName
    /// gzip：解压后是 tar。
    case tarContent
}

public struct ArchiveEntryFacts: Codable, Sendable, Equatable {
    /// 解码后的路径。
    public var path: String
    public var size: Int64
    /// 文件内容的 SHA-256，十六进制；目录为 nil。
    public var sha256: String?
    /// zip 中文件条目的压缩方法：`stored` 或 `deflate`。
    public var compression: String?
    /// 条目本身是压缩包时，它的内容。
    public var archive: ArchiveFacts?

    public init(path: String, size: Int64, sha256: String? = nil, compression: String? = nil, archive: ArchiveFacts? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.compression = compression
        self.archive = archive
    }

    public var isDirectory: Bool {
        path.hasSuffix("/")
    }
}

/// 目录树。`entries` 与 `count` 二者取其一：项多时只核对数量。
public struct DirectoryFacts: Codable, Sendable, Equatable {
    /// 全部后代的相对路径，按字节序排列；目录以 `/` 结尾，含隐藏文件。
    public var entries: [String]?
    /// 后代的数量。
    public var count: Int?

    public init(entries: [String]) {
        self.entries = entries
        self.count = nil
    }

    public init(count: Int) {
        self.entries = nil
        self.count = count
    }
}
