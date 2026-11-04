import Foundation
import MVFoundation
import MVIO

struct GzipHeader {
    var payloadOffset: Int64
    var name: String?
    var modificationNanos: Int64?

    static func read(_ source: any ByteSource, priority: IOPriority) async throws -> GzipHeader {
        let location = source.identity.location
        guard source.identity.size >= 18 else { throw IOError.corrupted(location, "gzip 文件不完整") }
        var reader = GzipHeaderReader(source: source, priority: priority)
        let fixed = try await reader.bytes(10)
        // 扩展名是 .gz、文件头却是 RAR 或 7z 时，报实际格式，不当成 gzip 损坏。
        if let format = Self.disguisedFormat(fixed) { throw IOError.unsupportedFormat(location, format) }
        guard fixed[0] == 0x1F, fixed[1] == 0x8B, fixed[2] == 8, fixed[3] & 0xE0 == 0 else { throw IOError.corrupted(location, "无效的 gzip 头部") }
        let flags = fixed[3]
        if flags & 4 != 0 {
            let count = try await reader.bytes(2).archiveInteger(UInt16.self, at: 0)
            _ = try await reader.bytes(Int(count))
        }
        var name: String?
        if flags & 8 != 0 {
            let bytes = try await reader.zeroTerminated()
            let decoded = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)!
            name = decoded.split(separator: "/").last.map(String.init)
        }
        if flags & 16 != 0 { _ = try await reader.zeroTerminated() }
        if flags & 2 != 0 {
            let expected = UInt16(truncatingIfNeeded: ~reader.crc)
            let actual = try await reader.bytes(2).archiveInteger(UInt16.self, at: 0)
            guard actual == expected else { throw IOError.corrupted(location, "gzip 头部 CRC16 不一致") }
        }
        let mtime = fixed.archiveInteger(UInt32.self, at: 4)
        guard reader.position <= source.identity.size - 8 else { throw IOError.corrupted(location, "gzip 头部越界") }
        return GzipHeader(payloadOffset: reader.position, name: name, modificationNanos: mtime == 0 ? nil : Int64(mtime) * 1_000_000_000)
    }

    /// RAR4、RAR5 与 7z 的文件头。两种 RAR 都叫 RAR。
    private static func disguisedFormat(_ header: Data) -> String? {
        let rar5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let sevenZip: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        if header.starts(with: rar5) || header.starts(with: rar4) { return "RAR" }
        if header.starts(with: sevenZip) { return "7z" }
        return nil
    }
}

enum GzipDecoder {
    static func extract(_ source: any ByteSource, to destination: URL, priority: IOPriority) async throws -> Int64 {
        let header = try await GzipHeader.read(source, priority: priority)
        let end = source.identity.size
        let trailer = try await archiveRead(source, end - 8..<end, priority: priority)
        let output = try await ExtractOutput.create(destination)
        defer { output.close() }
        var size: Int64 = 0
        try await ArchiveInflate.run(source, range: header.payloadOffset..<end - 8, priority: priority, group: nil,
                                     expectedSize: nil, checksum: trailer.archiveInteger(UInt32.self, at: 0)) { chunk in
            try await output.write(chunk)
            size += Int64(chunk.count)
        }
        guard UInt32(truncatingIfNeeded: size) == trailer.archiveInteger(UInt32.self, at: 4) else {
            throw IOError.corrupted(source.identity.location, "gzip ISIZE 不一致")
        }
        try await output.synchronize()
        return size
    }
}

private struct GzipHeaderReader {
    let source: any ByteSource
    let priority: IOPriority
    private(set) var position: Int64 = 0
    private(set) var crc = UInt32.max
    private var buffer = Data()
    private var start: Int64 = 0

    init(source: any ByteSource, priority: IOPriority) {
        self.source = source
        self.priority = priority
    }

    mutating func bytes(_ count: Int) async throws -> Data {
        guard Int64(count) <= source.identity.size - position else { throw IOError.corrupted(source.identity.location, "gzip 头部不完整") }
        if position + Int64(count) > start + Int64(buffer.count) {
            start = position
            buffer = try await archiveRead(source, position..<min(position + Int64(max(count, 4096)), source.identity.size), priority: priority)
        }
        let result = Data(buffer[Int(position - start)..<Int(position - start) + count])
        position += Int64(count)
        crc = ArchiveCRC.update(crc, with: result)
        return result
    }

    mutating func zeroTerminated() async throws -> Data {
        var data = Data()
        while true {
            let byte = try await bytes(1)[0]
            if byte == 0 { return data }
            data.append(byte)
        }
    }
}
