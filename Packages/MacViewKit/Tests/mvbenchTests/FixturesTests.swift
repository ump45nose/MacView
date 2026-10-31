import Foundation
import MVTestSupport
import Testing
@testable import mvbench

/// 夹具完整性：入库的夹具与清单一致，重新生成得到同样的清单。
struct FixturesTests {
    @Test func committedFixturesMatchTheManifest() async throws {
        let manifest = try Fixtures.manifest()
        for fixture in manifest.fixtures where !fixture.isLocal {
            let issues = await FixtureVerifier.issues(of: fixture, in: Fixtures.root)
            #expect(issues.isEmpty, "\(fixture.path)：\(issues)")
        }
    }

    @Test(.enabled(if: Fixtures.hasLocal(), "运行 make bench ARGS=fixtures 生成大夹具"))
    func localFixturesMatchTheManifest() async throws {
        let manifest = try Fixtures.manifest()
        for fixture in manifest.fixtures where fixture.isLocal {
            let issues = await FixtureVerifier.issues(of: fixture, in: Fixtures.root)
            #expect(issues.isEmpty, "\(fixture.path)：\(issues)")
        }
    }

    @Test func committedFixturesStayWithinTwentyMebibytes() throws {
        let committed = try Fixtures.manifest().fixtures.filter { !$0.isLocal }
        let bytes = try committed.reduce(0) { $0 + (try $1.byteCount(in: Fixtures.root)) }
        #expect(bytes <= 20 << 20)
    }

    /// 重新生成入库的夹具，清单应与入库的一致；清单记有压缩包条目的 SHA-256，所以压缩包的内容也要逐字节一致。
    @Test func regeneratingReproducesTheCommittedManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mvbench-fixtures-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try await FixtureGenerator.generate(into: root, includeLocal: false)
        #expect(manifest == (try Fixtures.manifest()), "生成器与入库的清单不一致，运行 make bench ARGS=fixtures 重新生成")
        for fixture in manifest.fixtures where !fixture.isLocal {
            let issues = await FixtureVerifier.issues(of: fixture, in: root)
            #expect(issues.isEmpty, "\(fixture.path)：\(issues)")
        }
        #expect(!Fixtures.hasLocal(in: root))
    }

    @Test(arguments: 1...8)
    func orientationMappingRoundTrips(orientation: Int) {
        // 存放尺寸 3×2（方向 5–8 时显示为 2×3），每个存放像素映射到不同的显示位置。
        let positions = (0..<2).flatMap { y in (0..<3).map { x in FixtureArt.displayed(x: x, y: y, width: 3, height: 2, orientation: orientation) } }
        let display = orientation >= 5 ? (width: 2, height: 3) : (width: 3, height: 2)
        #expect(Set(positions.map { "\($0.0),\($0.1)" }).count == 6)
        #expect(positions.allSatisfy { (0..<display.width).contains($0.0) && (0..<display.height).contains($0.1) })
    }

    @Test func orientationSixRotatesClockwise() {
        // 方向 6：存放的图顺时针旋转 90° 后显示，存放的左上角显示在右上角。
        #expect(FixtureArt.displayed(x: 0, y: 0, width: 3, height: 2, orientation: 6) == (1, 0))
        #expect(FixtureArt.displayed(x: 2, y: 1, width: 3, height: 2, orientation: 6) == (0, 2))
    }
}

struct FixtureArchiveTests {
    @Test func zipRoundTripsThroughBsdtar() throws {
        let entries = [
            ZipEntry(path: "目录/", data: Data(), compression: .stored),
            ZipEntry(path: "目录/a.txt", data: Data("hello".utf8), compression: .deflate),
        ]
        let data = try ZipWriter.archive(entries, options: ZipOptions(names: .utf8, zip64: true, dataDescriptor: true))
        let url = FileManager.default.temporaryDirectory.appending(path: "mvbench-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let listing = try ExternalTool.run("/usr/bin/bsdtar", ["-tf", url.path], environment: ["LC_ALL": "en_US.UTF-8"])
        #expect(String(decoding: listing, as: UTF8.self) == "目录/\n目录/a.txt\n")
        let content = try ExternalTool.run("/usr/bin/bsdtar", ["-xOf", url.path, "目录/a.txt"], environment: ["LC_ALL": "en_US.UTF-8"])
        #expect(content == Data("hello".utf8))
    }

    @Test func paxRecordLengthIncludesItsOwnDigits() throws {
        // 记录长度包括长度本身的位数：" path=…\n" 共 98 字节，加两位是 100，变成三位，所以长度是 101。
        let path = String(repeating: "长", count: 30) + "a"
        let data = try TarWriter.archive([TarEntry(path: path, data: Data("x".utf8))], style: .pax)
        let record = String(decoding: data[512..<1024].prefix { $0 != 0 }, as: UTF8.self)
        let length = try #require(Int(record.prefix { $0 != " " }))
        #expect(length == 101)
        #expect(record.utf8.count == length)
        #expect(record.hasSuffix("path=\(path)\n"))
    }
}
