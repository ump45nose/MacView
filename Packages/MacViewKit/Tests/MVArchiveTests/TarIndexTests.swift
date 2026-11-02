import Foundation
import MVFoundation
import MVIO
import MVTestSupport
import Testing
@testable import MVArchive

@Suite("tar 二进制 PAX 扩展值")
struct TarBinaryPAXTests {
    @Test("未知键允许非 UTF-8 字节，已知键和条目内容仍正确", arguments: [UInt8(ascii: "x"), UInt8(ascii: "g")])
    func binaryUnknownValue(type: UInt8) async throws {
        let directory = Fixtures.root.deletingLastPathComponent().appending(path: "build/stage4-repair/pax-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("image payload".utf8)
        let pax = paxRecord("LIBARCHIVE.xattr.com.apple.FinderInfo", value: Data([0xFF, 0, 0xFE, 61, 10, 0x80]))
            + paxRecord("path", value: Data("图像.jpg".utf8))
            + paxRecord("size", value: Data(String(payload.count).utf8))
            + paxRecord("mtime", value: Data("1700000000.125".utf8))
        let archive = header(name: "PaxHeader", size: pax.count, type: type) + padded(pax)
            + header(name: "fallback.jpg", size: 0, type: UInt8(ascii: "0")) + padded(payload) + Data(count: 1024)
        let file = directory.appending(path: "binary-pax.tar")
        try archive.write(to: file)
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let registry = FileSourceRegistry(scheduler: scheduler)
        let provider = try ArchiveProvider(fileSystem: registry.fileSystem, extractDirectory: directory.appending(path: "extract"))
        let location = try await registry.location(for: file)
        var listed: [Entry] = []
        for try await batch in provider.children(of: location, priority: .visible) { listed.append(contentsOf: batch) }
        #expect(listed.count == 1)
        let entry = try #require(listed.first)
        #expect(entry.name == "图像.jpg")
        #expect(entry.kind == .image)
        #expect(entry.size == Int64(payload.count))
        #expect(entry.identity.modificationNanos == 1_700_000_000_125_000_000)
        let source = try await provider.open(entry.location)
        #expect(try await source.read(0..<source.identity.size, priority: .visible, group: nil) == payload)
        await ExtractIO.drain()
    }

    private func paxRecord(_ key: String, value: Data) -> Data {
        let body = Data(" \(key)=".utf8) + value + Data([10])
        var digits = 1
        while String(body.count + digits).count != digits { digits = String(body.count + digits).count }
        return Data(String(body.count + digits).utf8) + body
    }

    private func header(name: String, size: Int, type: UInt8) -> Data {
        var block = Data(count: 512)
        func put(_ value: String, at offset: Int) {
            block.replaceSubrange(offset..<offset + value.utf8.count, with: value.utf8)
        }
        func octal(_ value: Int, at offset: Int, width: Int) {
            let digits = String(value, radix: 8)
            put(String(repeating: "0", count: width - 1 - digits.count) + digits, at: offset)
        }
        put(name, at: 0)
        octal(0o644, at: 100, width: 8)
        octal(size, at: 124, width: 12)
        octal(0, at: 136, width: 12)
        put("        ", at: 148)
        block[156] = type
        put("ustar\0" + "00", at: 257)
        let checksum = String(block.reduce(0) { $0 + Int($1) }, radix: 8)
        put(String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ", at: 148)
        return block
    }

    private func padded(_ data: Data) -> Data {
        data + Data(count: (512 - data.count % 512) % 512)
    }
}
