import Foundation
import MVFoundation
import MVIO

enum TarIndex {
    static func isHeader(_ data: Data) -> Bool {
        guard data.count >= 512, !data.prefix(512).allSatisfy({ $0 == 0 }),
              let expected = number(data, range: 148..<156) else { return false }
        var sum: Int64 = 0
        var signed: Int64 = 0
        for i in 0..<512 {
            sum += (148..<156).contains(i) ? 32 : Int64(data[i])
            signed += (148..<156).contains(i) ? 32 : Int64(Int8(bitPattern: data[i]))
        }
        return expected == sum || expected == signed
    }

    static func read(_ source: any ByteSource, priority: IOPriority) async throws -> ArchiveIndex {
        var reader = TarReader(source: source, priority: priority)
        var offset: Int64 = 0
        var index = ArchiveIndex()
        var global: [String: String] = [:]
        var local: [String: String] = [:]
        var longName: String?
        while offset <= source.identity.size - 512 {
            try archiveCheckCancellation()
            let header = try await reader.read(offset, count: 512)
            if header.allSatisfy({ $0 == 0 }) { return index }
            guard isHeader(header), let headerSize = number(header, range: 124..<136), headerSize >= 0,
                  let mtime = number(header, range: 136..<148) else { throw IOError.corrupted(source.identity.location, "无效的 tar 头部或校验和") }
            let type = header[156]
            let payload = offset + 512
            var size = headerSize
            if type != UInt8(ascii: "x"), type != UInt8(ascii: "g"), type != UInt8(ascii: "L"), type != UInt8(ascii: "K") {
                if let text = local["size"] ?? global["size"] {
                    guard let value = Int64(text), value >= 0 else { throw IOError.corrupted(source.identity.location, "无效的 pax size") }
                    size = value
                }
            }
            guard size <= source.identity.size - payload,
                  size <= Int64.max - 511 else { throw IOError.corrupted(source.identity.location, "tar 条目数据越界") }
            if type == UInt8(ascii: "x") || type == UInt8(ascii: "g") {
                let data = try await archiveRead(source, payload..<payload + size, priority: priority)
                let values = try pax(data, at: source.identity.location)
                if type == UInt8(ascii: "g") {
                    for (key, value) in values { global[key] = value.isEmpty ? nil : value }
                } else { local = values }
            } else if type == UInt8(ascii: "L") {
                let data = try await archiveRead(source, payload..<payload + size, priority: priority)
                longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            } else if type != UInt8(ascii: "K") {
                // GNU 旧头在这一段存 atime/ctime 与稀疏文件字段，只有 POSIX ustar 才是 prefix。
                let prefix = header[257..<263] == Data("ustar\0".utf8) ? header.archiveString(345..<500) : ""
                let short = header.archiveString(0..<100)
                let name = local["path"] ?? global["path"] ?? longName ?? (prefix.isEmpty ? short : prefix + "/" + short)
                let nanos: Int64
                if let text = local["mtime"] ?? global["mtime"] {
                    guard let value = paxTimeNanos(text) else { throw IOError.corrupted(source.identity.location, "无效的 pax mtime") }
                    nanos = value
                } else {
                    let (value, overflow) = mtime.multipliedReportingOverflow(by: 1_000_000_000)
                    guard !overflow else { throw IOError.corrupted(source.identity.location, "tar 时间超出范围") }
                    nanos = value
                }
                let kind: EntryKind = switch type {
                case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): EntryKind(fileName: name)
                case UInt8(ascii: "5"): .directory
                default: .other
                }
                index.append(ArchiveRecord(path: try archivePath(name, at: source.identity.location), size: size,
                                           modificationNanos: nanos, kind: kind, offset: payload, compressedSize: size))
                local.removeAll(keepingCapacity: true)
                longName = nil
            }
            offset = payload + ((size + 511) / 512) * 512
        }
        guard offset == source.identity.size else { throw IOError.corrupted(source.identity.location, "tar 结尾不完整") }
        return index
    }

    private static func paxTimeNanos(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        var offset = 0
        let negative = bytes.first == UInt8(ascii: "-")
        if negative || bytes.first == UInt8(ascii: "+") { offset += 1 }

        // 累加负数可表示 Int64.min 的绝对值，最后再处理正数的边界。
        var value: Int64 = 0
        var digits = 0
        var fractionalDigits = 0
        var hasDecimalPoint = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == UInt8(ascii: "."), !hasDecimalPoint {
                hasDecimalPoint = true
                continue
            }
            guard byte >= 48, byte <= 57 else { return nil }
            digits += 1
            if hasDecimalPoint { fractionalDigits += 1 }
            if !hasDecimalPoint || fractionalDigits <= 9 {
                let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                let (next, underflow) = scaled.subtractingReportingOverflow(Int64(byte - 48))
                guard !underflow else { return nil }
                value = next
            }
        }
        guard digits > 0 else { return nil }
        for _ in min(fractionalDigits, 9)..<9 {
            let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            value = scaled
        }
        if negative { return value }
        let (positive, overflow) = Int64.zero.subtractingReportingOverflow(value)
        return overflow ? nil : positive
    }

    private static func number(_ data: Data, range: Range<Int>) -> Int64? {
        if data[range.lowerBound] & 0x80 != 0 {
            // GNU 的 base-256 正数；负数时间可由 pax mtime 表示。
            guard data[range.lowerBound] & 0x40 == 0 else { return nil }
            var result: UInt64 = UInt64(data[range.lowerBound] & 0x7F)
            for byte in data[(range.lowerBound + 1)..<range.upperBound] {
                guard result <= UInt64(Int64.max) >> 8 else { return nil }
                result = result << 8 | UInt64(byte)
            }
            return Int64(result)
        }
        let text = String(decoding: data[range].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? 0 : Int64(text, radix: 8)
    }

    private static func pax(_ data: Data, at location: Location) throws -> [String: String] {
        var values: [String: String] = [:]
        var offset = 0
        while offset < data.count {
            guard let space = data[offset...].firstIndex(of: 32),
                  let count = Int(String(decoding: data[offset..<space], as: UTF8.self)), count > space - offset + 2,
                  count <= data.count - offset, data[offset + count - 1] == 10 else { throw IOError.corrupted(location, "无效的 pax 记录长度") }
            let body = data[space + 1..<offset + count - 1]
            guard let equal = body.firstIndex(of: 61),
                  let key = String(data: body[..<equal], encoding: .utf8),
                  let value = String(data: body[body.index(after: equal)...], encoding: .utf8) else { throw IOError.corrupted(location, "无效的 pax 键值") }
            values[key] = value
            offset += count
        }
        return values
    }
}

private struct TarReader {
    let source: any ByteSource
    let priority: IOPriority
    private var start: Int64 = 0
    private var buffer = Data()

    init(source: any ByteSource, priority: IOPriority) {
        self.source = source
        self.priority = priority
    }

    mutating func read(_ offset: Int64, count: Int64) async throws -> Data {
        if offset < start || offset + count > start + Int64(buffer.count) {
            start = offset
            buffer = try await archiveRead(source, offset..<min(offset + (64 << 10), source.identity.size), priority: priority)
        }
        return Data(buffer[Int(offset - start)..<Int(offset + count - start)])
    }
}
