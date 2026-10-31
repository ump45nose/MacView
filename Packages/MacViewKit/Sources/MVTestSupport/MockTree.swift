import Foundation
import MVFoundation

/// 内存目录树中的一项。
public struct MockNode: Sendable {
    public enum Content: Sendable {
        case directory([MockNode])
        case archive(ArchiveFormat, [MockNode])
        case image(PixelSize, frames: Int)
        case video(PixelSize, duration: Double)
        case other
    }

    /// 默认的修改时间：2025-01-01 00:00:00 UTC。
    public static let baseTime: Int64 = 1_735_689_600_000_000_000

    public var name: String
    public var content: Content
    public var size: Int64
    public var modificationNanos: Int64

    public init(name: String, content: Content, size: Int64, modificationNanos: Int64 = MockNode.baseTime) {
        self.name = name
        self.content = content
        self.size = size
        self.modificationNanos = modificationNanos
    }

    var kind: EntryKind {
        switch content {
        case .directory: .directory
        case let .archive(format, _): .archive(format)
        case .image: .image
        case .video: .video
        case .other: .other
        }
    }

    public static func directory(_ name: String, _ children: [MockNode]) -> MockNode {
        MockNode(name: name, content: .directory(children), size: 0)
    }

    public static func archive(_ name: String, format: ArchiveFormat = .zip, _ children: [MockNode]) -> MockNode {
        MockNode(name: name, content: .archive(format, children), size: children.reduce(0) { $0 + $1.size })
    }

    /// 文件大小按每像素 0.5 字节估算，与 JPEG 相当。
    public static func image(_ name: String, _ pixelSize: PixelSize, frames: Int = 1, modified: Int64 = baseTime) -> MockNode {
        MockNode(name: name, content: .image(pixelSize, frames: frames), size: Int64(pixelSize.width * pixelSize.height / 2), modificationNanos: modified)
    }

    /// 文件大小按 8 Mbps 估算。
    public static func video(_ name: String, _ pixelSize: PixelSize, duration: Double) -> MockNode {
        MockNode(name: name, content: .video(pixelSize, duration: duration), size: Int64(duration * 1_000_000))
    }

    public static func file(_ name: String, size: Int64 = 4096) -> MockNode {
        MockNode(name: name, content: .other, size: size)
    }

    /// 一本书：`pages` 张图，文件名是补零的序号（`001.jpg`…），修改时间按序号递增。
    /// - Parameters:
    ///   - shapes: 页面尺寸，按序号确定性地选取。
    ///   - wideEvery: 每隔几页放一张跨页（宽度加倍）；0 表示没有。
    ///   - archive: 不为 nil 时生成压缩包，`name` 要带扩展名。
    ///   - hiddenFiles: 附带 `._` 文件、`.DS_Store` 与 `.url`，用来检验过滤。
    public static func book(
        _ name: String, pages: Int, shapes: [PixelSize] = [PixelSize(width: 3600, height: 5400)],
        wideEvery: Int = 0, archive: ArchiveFormat? = nil, hiddenFiles: Bool = true
    ) -> MockNode {
        precondition(!shapes.isEmpty, "shapes 不能为空")
        let digits = max(3, String(pages).count)
        var children: [MockNode] = (0..<pages).map { offset in
            let number = offset + 1
            var size = shapes[Int(MockRandom.mix(UInt64(number)) % UInt64(shapes.count))]
            if wideEvery > 0, number % wideEvery == 0 {
                size.width *= 2
            }
            return .image(String(format: "%0\(digits)d.jpg", number), size, modified: baseTime + Int64(number) * 1_000_000_000)
        }
        if hiddenFiles, let first = children.first {
            children += [.image("._" + first.name, PixelSize(width: 1, height: 1)), .file(".DS_Store"), .file("说明.url", size: 120)]
        }
        if let archive {
            return .archive(name, format: archive, children)
        }
        return .directory(name, children)
    }
}

/// 一棵内存目录树。
public struct MockTree: Sendable {
    public static let defaultRoot = Location.Root.network(scheme: "nfs", host: "mock.local", share: "/mock")

    public var root: Location.Root
    public var nodes: [MockNode]

    public init(root: Location.Root = MockTree.defaultRoot, nodes: [MockNode]) {
        self.root = root
        self.nodes = nodes
    }

    /// 由显示路径得到位置：层之间用 `!/` 分隔，例如 `漫画/作品 1.zip!/001.jpg`；空串是根。
    public func location(_ path: String) -> Location {
        guard !path.isEmpty else { return Location(root: root) }
        return Location(root: root, layers: path.components(separatedBy: "!/").map { $0.split(separator: "/").map(String.init) })
    }

    static let portraitShapes = [
        PixelSize(width: 3600, height: 5400), PixelSize(width: 3000, height: 4500), PixelSize(width: 2832, height: 4256),
    ]

    static let mixedShapes = [
        PixelSize(width: 3600, height: 5400), PixelSize(width: 5400, height: 3600), PixelSize(width: 4000, height: 4000),
        PixelSize(width: 3000, height: 4000), PixelSize(width: 4000, height: 3000), PixelSize(width: 1080, height: 1920),
        PixelSize(width: 2400, height: 3600), PixelSize(width: 6000, height: 2000),
    ]

    /// 界面开发用的示例库：画集、压缩包、动图与视频、单层穿透，以及 1 万页的大书。
    public static let sample = MockTree(nodes: [
        .directory("画集", [
            .directory("系列 A", (1...6).map { MockNode.book("第 \($0) 卷", pages: 20 + $0 * 16, shapes: portraitShapes, wideEvery: 9) }),
            .directory("系列 B", (1...4).map { MockNode.book("Book \($0)", pages: 60, shapes: mixedShapes) }),
        ]),
        .directory("漫画", [
            .book("作品 1.zip", pages: 40, archive: .zip),
            .book("作品 2.cbz", pages: 32, wideEvery: 8, archive: .zip),
            .directory("作品 3", [.book("第 1 话", pages: 24), .book("第 2 话", pages: 26)]),
        ]),
        .directory("动图与视频", [
            .image("封面.jpg", PixelSize(width: 2400, height: 3600)),
            .image("循环.gif", PixelSize(width: 480, height: 270), frames: 24),
            .video("片段.mp4", PixelSize(width: 1920, height: 1080), duration: 30),
        ]),
        .directory("单层穿透", [.directory("唯一子目录", [.book("内层的书", pages: 12)])]),
        .book("大书（1 万页）", pages: 10_000, shapes: mixedShapes),
    ])
}

/// 确定性的伪随机数：SplitMix64，字符串种子取 FNV-1a。Mock 的结果因此在各次运行间一致。
struct MockRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    init(seed text: String) {
        self.init(seed: Self.fnv1a(text))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return Self.mix(state)
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}
