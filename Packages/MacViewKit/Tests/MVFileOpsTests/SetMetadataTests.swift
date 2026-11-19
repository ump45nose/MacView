import CoreGraphics
import Foundation
import ImageIO
import MVFoundation
import MVIO
@testable import MVMetadata
import Testing
@testable import MVFileOps

@Suite(.serialized)
struct SetMetadataTests {
    @Test("C1.10 本机约 20 MB JPEG 写评分校验通过、无残留临时文件，注入 rename 失败保留原文件并删临时文件")
    func localLargeJPEGAndRenameFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mvfileops-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        let fs = sources.fileSystem
        let service = try FileOperationService(fileSystem: fs, journalURL: dir.appendingPathComponent("transfers.json"))

        let largeData = try Self.makeJPEG(width: 4000, height: 3000, quality: 1.0, noisy: true)
        #expect(largeData.count >= 15_000_000, "测试样图应接近 20 MB，实际 \(largeData.count) 字节")
        let fileURL = dir.appendingPathComponent("large.jpg")
        try largeData.write(to: fileURL)

        let location = try await sources.location(for: fileURL)
        let oldIdentity = try await fs.entry(at: location).identity

        // 先读该图，使 FileReader 缓存读描述符
        let opened = try await fs.open(location)
        let head = try await opened.read(0..<65536, priority: .visible, group: nil)
        #expect(head.count == 65536)

        let result = await service.perform(.setMetadata([location], XMPFields(rating: 4, tags: ["精选", "写真"])))
        #expect(result.failures.isEmpty)
        #expect(result.retry == nil)
        #expect(result.changes.count == 1)
        guard case let .rewritten(newEntry, previous, newMeta) = try #require(result.changes.first) else {
            Issue.record("预期产出 .rewritten")
            return
        }
        #expect(previous == oldIdentity)
        #expect(newEntry.location == location)
        #expect(newEntry.identity != oldIdentity)
        #expect(newMeta.rating == 4)
        #expect(newMeta.tags == ["精选", "写真"])

        let updatedData = try Data(contentsOf: fileURL)
        let readBack = try #require(XMPReader.fields(fromHeader: updatedData))
        #expect(readBack.rating == 4)
        #expect(readBack.tags == ["精选", "写真"])
        #expect(XMPWriter.jpegScanSegment(in: updatedData) == XMPWriter.jpegScanSegment(in: largeData))

        let namesAfterWrite = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!namesAfterWrite.contains { $0.contains(".mvtmp-") || $0.hasPrefix(".nfs.") })

        // 注入 rename 失败：原文件字节不变、临时文件已删、结果里有 failure 与 retry
        let failingService = try FileOperationService(
            fileSystem: fs,
            journalURL: dir.appendingPathComponent("transfers-fail.json"),
            renameFile: { _, _, _ in throw IOError.underlying("injected rename failure") },
            isNetwork: { _ in false },
            volumeRoot: { try fs.volumeRoot(of: $0) },
            networkRoots: { [] },
            trash: { try await fs.moveToTrash($0) }
        )
        let failed = await failingService.perform(.setMetadata([location], XMPFields(rating: 2)))
        #expect(failed.changes.isEmpty)
        #expect(failed.failures.count == 1)
        #expect(failed.retry == FileOperation.setMetadata([location], XMPFields(rating: 2)))
        #expect(try Data(contentsOf: fileURL) == updatedData)

        let namesAfterFail = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!namesAfterFail.contains { $0.contains(".mvtmp-") || $0.hasPrefix(".nfs.") })
    }

    @Test("C1.10 NFS 测试目录约 20 MB JPEG 先缓存描述符再写评分，无临时文件与 .nfs.*")
    func nfsLargeJPEGWriteWithoutSillyRename() async throws {
        let nfsBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MacViewBench/fileops-a", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: nfsBase.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isWritableFile(atPath: nfsBase.path) else {
            return
        }

        let workDir = nfsBase.appendingPathComponent(".mv-w13-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let helperURL = Self.helperExecutableURL()
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: helperURL))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        let fs = sources.fileSystem
        let journalDir = FileManager.default.temporaryDirectory.appendingPathComponent("mvfileops-nfs-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let service = try FileOperationService(fileSystem: fs, journalURL: journalDir.appendingPathComponent("transfers.json"))

        let largeData = try Self.makeJPEG(width: 4000, height: 3000, quality: 1.0, noisy: true)
        #expect(largeData.count >= 15_000_000, "测试样图应接近 20 MB，实际 \(largeData.count) 字节")
        let fileURL = workDir.appendingPathComponent("nfs-large.jpg")
        try largeData.write(to: fileURL)

        let location = try await sources.location(for: fileURL)
        let oldIdentity = try await fs.entry(at: location).identity

        // 先经辅助进程读一次，让辅助进程缓存目标路径的读描述符
        let opened = try await fs.open(location)
        let head = try await opened.read(0..<65536, priority: .visible, group: nil)
        #expect(head.count == 65536)

        let start = ContinuousClock.now
        let result = await service.perform(.setMetadata([location], XMPFields(rating: 5, tags: ["NFS校验"])))
        let elapsed = start.duration(to: .now)
        print("C1.10 NFS 20MB setMetadata: size=\(largeData.count) elapsed=\(elapsed)")

        #expect(result.failures.isEmpty)
        #expect(result.changes.count == 1)
        guard case let .rewritten(newEntry, previous, newMeta) = try #require(result.changes.first) else {
            Issue.record("预期产出 .rewritten")
            return
        }
        #expect(previous == oldIdentity)
        #expect(newEntry.identity != oldIdentity)
        #expect(newMeta.rating == 5)
        #expect(newMeta.tags == ["NFS校验"])

        let updatedData = try Data(contentsOf: fileURL)
        let readBack = try #require(XMPReader.fields(fromHeader: updatedData))
        #expect(readBack.rating == 5)
        #expect(readBack.tags == ["NFS校验"])
        #expect(XMPWriter.jpegScanSegment(in: updatedData) == XMPWriter.jpegScanSegment(in: largeData))

        let names = try FileManager.default.contentsOfDirectory(atPath: workDir.path)
        #expect(!names.contains { $0.contains(".mvtmp-") || $0.hasPrefix(".nfs.") }, "目录残留文件：\(names)")
    }

    @Test("C1.11 批量 20 张含 1 张 PNG 与 1 张压缩包内条目，其余成功，inverse 全部回到原值")
    func batchMixedFormatsAndInverse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mvfileops-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        let fs = sources.fileSystem
        let service = try FileOperationService(fileSystem: fs, journalURL: dir.appendingPathComponent("transfers.json"))
        let root = try await sources.location(for: dir)

        let baseJPEG = try Self.makeJPEG(width: 64, height: 48, quality: 0.9, noisy: false)
        let preRatedJPEG = try XMPWriter.write(XMPFields(rating: 2, tags: ["旧标签"]), into: baseJPEG)
        let pngData = try Self.makePNG(width: 64, height: 48)

        var jpegLocations: [Location] = []
        for i in 0..<18 {
            let name = String(format: "img-%02d.jpg", i)
            let url = dir.appendingPathComponent(name)
            try (i < 6 ? preRatedJPEG : baseJPEG).write(to: url)
            jpegLocations.append(root.appending(name))
        }
        let pngURL = dir.appendingPathComponent("unsupported.png")
        try pngData.write(to: pngURL)
        let pngLocation = root.appending("unsupported.png")
        let archiveLocation = root.appending("book.zip").appendingLayer(["page1.jpg"])

        let all20 = jpegLocations + [pngLocation, archiveLocation]
        let result = await service.perform(.setMetadata(all20, XMPFields(rating: 4, tags: ["批量标签"])))

        #expect(result.changes.count == 18)
        #expect(result.failures.count == 2)
        let pngFailure = try #require(result.failures.first { $0.location == pngLocation })
        #expect((pngFailure.error as? FileOpsError) == .metadataUnsupported("png"))
        let archiveFailure = try #require(result.failures.first { $0.location == archiveLocation })
        #expect((archiveFailure.error as? FileOpsError) == .readOnly)

        // 确认 18 张全部已写入新值
        for i in 0..<18 {
            let url = dir.appendingPathComponent(String(format: "img-%02d.jpg", i))
            let fields = try #require(XMPReader.fields(fromHeader: try Data(contentsOf: url)))
            #expect(fields.rating == 4)
            #expect(fields.tags == ["批量标签"])
        }

        // 执行 inverse 后全部回到原值
        let inverse = try #require(result.inverse)
        let undone = await service.perform(inverse)
        #expect(undone.failures.isEmpty)
        #expect(undone.changes.count == 18)
        for i in 0..<18 {
            let url = dir.appendingPathComponent(String(format: "img-%02d.jpg", i))
            let fields = XMPReader.fields(fromHeader: try Data(contentsOf: url))
            if i < 6 {
                #expect(fields?.rating == 2)
                #expect(fields?.tags == ["旧标签"])
            } else {
                #expect(fields?.rating == nil)
                #expect(fields?.tags == nil)
            }
        }
    }

    // MARK: - Helpers

    private static func makeJPEG(width: Int, height: Int, quality: Double, noisy: Bool) throws -> Data {
        let image = try makeCGImage(width: width, height: height, noisy: noisy)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let image = try makeCGImage(width: width, height: height, noisy: false)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    private static func makeCGImage(width: Int, height: Int, noisy: Bool) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        if noisy {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            pixels.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for i in 0..<words.count {
                    state ^= state >> 12
                    state ^= state << 25
                    state ^= state >> 27
                    words[i] = state &* 0x2545_F491_4F6C_DD1D
                }
            }
        } else {
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    pixels[offset] = UInt8((x * 255) / max(1, width))
                    pixels[offset + 1] = UInt8((y * 255) / max(1, height))
                    pixels[offset + 2] = 128
                    pixels[offset + 3] = 255
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return image
    }

    private final class BundleMarker {}

    private static func helperExecutableURL() -> URL? {
        let url = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mvio-helper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
