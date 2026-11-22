import Foundation
import MVTestSupport
import Testing
@testable import mvbench

struct MediaPreviewTests {
    @Test("C1.12 预览基准参数及非法次数校验")
    func commandOptions() throws {
        let command = try MediaPreviewCommand.parse(["--dir", "videos", "--limit", "3", "--repeat", "2", "-o", "report.json"])
        #expect(command.options.directory == "videos")
        #expect(command.options.limit == 3)
        #expect(command.repeat == 2)
        #expect(command.options.output == "report.json")
        #expect(throws: (any Error).self) { try MediaPreviewCommand.parse(["--dir", "videos", "--repeat", "0"]) }
        #expect(throws: (any Error).self) { try MediaPreviewCommand.parse(["--dir", "videos", "--limit", "-1"]) }
    }

    @Test("C1.12 先过滤视频再应用 limit，跳过隐藏文件和目录")
    func selectsOnlyVideos() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["0.jpg", "1.MP4", "2.mov", "3.m4v", "4.webm", ".hidden.mp4"] {
            try Data().write(to: root.appending(path: name))
        }
        try FileManager.default.createDirectory(at: root.appending(path: "directory.mp4"), withIntermediateDirectories: false)
        let files = try MediaPreviewCommand.videoFiles(directory: root.path, limit: 2)
        #expect(files.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["1.MP4", "2.mov"])
        #expect(try MediaPreviewCommand.videoFiles(directory: root.path, limit: nil).count == 3)
    }

    @Test("C1.12 实际命令输出逐视频逐轮 JSON，冷取、内存及重启磁盘路径均交付二十帧",
          .enabled(if: Fixtures.hasLocal(), "需要本地视频夹具"))
    func commandProducesJSON() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "videos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: Fixtures.url("local/generated/video/h264.mp4"), to: source.appending(path: "private-name.mp4"))
        let output = root.appending(path: "preview.json")
        let command = try MediaPreviewCommand.parse(["--dir", source.path, "--repeat", "2", "-o", output.path])
        try await command.run()
        let data = try Data(contentsOf: output)
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["files"] as? Int == 1)
        let result = try #require(report["result"] as? [String: Any])
        #expect(result["frameCount"] as? Int == 20)
        #expect(result["longSide"] as? Int == 640)
        #expect(result["repeats"] as? Int == 2)
        let samples = try #require(result["samples"] as? [[String: Any]])
        #expect(samples.count == 2)
        for sample in samples {
            for key in ["coldFirstFrameMilliseconds", "coldAllFramesMilliseconds", "memoryAllFramesMilliseconds", "diskAllFramesMilliseconds"] {
                let milliseconds = try #require(sample[key] as? Double)
                #expect(milliseconds.isFinite && milliseconds >= 0)
            }
            #expect((sample["coldFirstFrameMilliseconds"] as? Double ?? 1) <= (sample["coldAllFramesMilliseconds"] as? Double ?? 0))
        }
        #expect(!String(decoding: data, as: UTF8.self).contains("private-name.mp4"))
    }

    private func testDirectory() throws -> URL {
        let root = Fixtures.root.deletingLastPathComponent().appending(path: "build/w14-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
