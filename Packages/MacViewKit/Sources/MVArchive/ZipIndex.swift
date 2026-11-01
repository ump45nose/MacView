import CoreFoundation
import Foundation
import MVFoundation
import MVIO

enum ZipIndex {
    static func read(_ source: any ByteSource, priority: IOPriority) async throws -> ArchiveIndex {
        let location = source.identity.location
        let size = source.identity.size
        guard size >= 22 else { throw IOError.corrupted(location, "zip 缺少结尾记录") }
        // 常见的无注释 zip 只读最后 22 字节；有注释时才扫描完整的 64 KB 窗口。
        var tailStart = size - 22
        var tail = try await archiveRead(source, tailStart..<size, priority: priority)
        var end = findEnd(tail)
        if end == nil {
            tailStart = max(0, size - 65_557)
            tail = try await archiveRead(source, tailStart..<size - 22, priority: priority) + tail
            end = findEnd(tail)
        }
        guard let end else { throw IOError.corrupted(location, "找不到 zip 中央目录结尾") }
        guard tail.archiveInteger(UInt16.self, at: end + 4) == 0,
              tail.archiveInteger(UInt16.self, at: end + 6) == 0 else { throw IOError.unsupported(location) }
        var count = UInt64(tail.archiveInteger(UInt16.self, at: end + 10))
        var length = UInt64(tail.archiveInteger(UInt32.self, at: end + 12))
        var offset = UInt64(tail.archiveInteger(UInt32.self, at: end + 16))
        if count == 0xFFFF || length == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let endOffset = tailStart + Int64(end)
            guard endOffset >= 20 else { throw IOError.corrupted(location, "ZIP64 缺少定位记录") }
            let locator = try await slice(source, endOffset - 20..<endOffset, tail: tail, start: tailStart, priority: priority)
            guard locator.archiveInteger(UInt32.self, at: 0) == 0x0706_4B50,
                  locator.archiveInteger(UInt32.self, at: 4) == 0,
                  locator.archiveInteger(UInt32.self, at: 16) == 1 else { throw IOError.corrupted(location, "无效的 ZIP64 定位记录") }
            let recordOffset = try checked(locator.archiveInteger(UInt64.self, at: 8), at: location)
            guard recordOffset <= size - 56 else { throw IOError.corrupted(location, "ZIP64 结尾越界") }
            let record = try await slice(source, recordOffset..<recordOffset + 56, tail: tail, start: tailStart, priority: priority)
            guard record.archiveInteger(UInt32.self, at: 0) == 0x0606_4B50,
                  record.archiveInteger(UInt64.self, at: 4) >= 44,
                  record.archiveInteger(UInt32.self, at: 16) == 0,
                  record.archiveInteger(UInt32.self, at: 20) == 0 else { throw IOError.corrupted(location, "无效的 ZIP64 结尾记录") }
            count = record.archiveInteger(UInt64.self, at: 32)
            length = record.archiveInteger(UInt64.self, at: 40)
            offset = record.archiveInteger(UInt64.self, at: 48)
        }
        let centralOffset = try checked(offset, at: location)
        let centralSize = try checked(length, at: location)
        guard centralOffset <= size, centralSize <= size - centralOffset,
              count <= UInt64(centralSize / 46) else { throw IOError.corrupted(location, "zip 中央目录越界") }
        let central = try await slice(source, centralOffset..<centralOffset + centralSize, tail: tail, start: tailStart, priority: priority)
        var index = ArchiveIndex()
        var cursor = 0
        for _ in 0..<count {
            try archiveCheckCancellation()
            guard cursor <= central.count - 46,
                  central.archiveInteger(UInt32.self, at: cursor) == 0x0201_4B50 else { throw IOError.corrupted(location, "无效的 zip 中央目录条目") }
            let flags = central.archiveInteger(UInt16.self, at: cursor + 8)
            let method = central.archiveInteger(UInt16.self, at: cursor + 10)
            guard flags & 0x2041 == 0, method == 0 || method == 8 else { throw IOError.unsupported(location) }
            var compressed = UInt64(central.archiveInteger(UInt32.self, at: cursor + 20))
            var uncompressed = UInt64(central.archiveInteger(UInt32.self, at: cursor + 24))
            let nameLength = Int(central.archiveInteger(UInt16.self, at: cursor + 28))
            let extraLength = Int(central.archiveInteger(UInt16.self, at: cursor + 30))
            let commentLength = Int(central.archiveInteger(UInt16.self, at: cursor + 32))
            let disk = central.archiveInteger(UInt16.self, at: cursor + 34)
            var local = UInt64(central.archiveInteger(UInt32.self, at: cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= central.count else { throw IOError.corrupted(location, "zip 条目名称或扩展字段越界") }
            let nameData = Data(central[cursor + 46..<cursor + 46 + nameLength])
            let name = try decodeName(nameData, utf8: flags & (1 << 11) != 0, at: location)
            var modification = dosDate(date: central.archiveInteger(UInt16.self, at: cursor + 14),
                                       time: central.archiveInteger(UInt16.self, at: cursor + 12))
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            var zip64 = false
            while extra < extraEnd {
                guard extra <= extraEnd - 4 else { throw IOError.corrupted(location, "zip 扩展字段不完整") }
                let tag = central.archiveInteger(UInt16.self, at: extra)
                let fieldLength = Int(central.archiveInteger(UInt16.self, at: extra + 2))
                let field = extra + 4
                guard fieldLength <= extraEnd - field else { throw IOError.corrupted(location, "zip 扩展字段越界") }
                if tag == 1 {
                    var current = field
                    func value() throws -> UInt64 {
                        guard current <= field + fieldLength - 8 else { throw IOError.corrupted(location, "ZIP64 扩展字段不完整") }
                        defer { current += 8 }
                        return central.archiveInteger(UInt64.self, at: current)
                    }
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try value() }
                    if compressed == 0xFFFF_FFFF { compressed = try value() }
                    if local == 0xFFFF_FFFF { local = try value() }
                    if disk == 0xFFFF {
                        guard current <= field + fieldLength - 4,
                              central.archiveInteger(UInt32.self, at: current) == 0 else { throw IOError.unsupported(location) }
                    }
                    zip64 = true
                } else if tag == 0x5455, fieldLength >= 5, central[field] & 1 != 0 {
                    modification = Int64(central.archiveInteger(UInt32.self, at: field + 1)) * 1_000_000_000
                }
                extra = field + fieldLength
            }
            guard (disk == 0 || disk == 0xFFFF && zip64),
                  (zip64 || compressed != 0xFFFF_FFFF && uncompressed != 0xFFFF_FFFF && local != 0xFFFF_FFFF) else {
                throw IOError.corrupted(location, "ZIP64 缺少扩展字段")
            }
            let originalSize = try checked(uncompressed, at: location)
            let compressedSize = try checked(compressed, at: location)
            let headerOffset = try checked(local, at: location)
            guard headerOffset <= size - 30 else { throw IOError.corrupted(location, "zip 本地头越界") }
            let directory = name.hasSuffix("/") || central.archiveInteger(UInt32.self, at: cursor + 38) & 0x10 != 0
            index.append(ArchiveRecord(path: try archivePath(name, at: location), size: originalSize,
                                       modificationNanos: modification,
                                       checksum: directory ? nil : central.archiveInteger(UInt32.self, at: cursor + 16),
                                       kind: directory ? .directory : EntryKind(fileName: name), offset: headerOffset,
                                       compressedSize: compressedSize, method: method, localHeader: true))
            cursor = next
        }
        return index
    }

    private static func findEnd(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            if data.archiveInteger(UInt32.self, at: offset) == 0x0605_4B50,
               offset + 22 + Int(data.archiveInteger(UInt16.self, at: offset + 20)) == data.count { return offset }
        }
        return nil
    }

    private static func slice(_ source: any ByteSource, _ range: Range<Int64>, tail: Data, start: Int64,
                              priority: IOPriority) async throws -> Data {
        if range.lowerBound >= start, range.upperBound <= start + Int64(tail.count) {
            return Data(tail[Int(range.lowerBound - start)..<Int(range.upperBound - start)])
        }
        return try await archiveRead(source, range, priority: priority)
    }

    private static func checked(_ value: UInt64, at location: Location) throws -> Int64 {
        guard value <= Int64.max else { throw IOError.corrupted(location, "zip 大小超出支持范围") }
        return Int64(value)
    }

    static func decodeName(_ data: Data, utf8: Bool, at location: Location) throws -> String {
        if utf8 {
            guard let name = String(data: data, encoding: .utf8) else { throw IOError.corrupted(location, "zip UTF-8 文件名无效") }
            return name
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let name = String(data: data, encoding: gb) { return name }
        let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        guard let name = String(data: data, encoding: cp437) else { throw IOError.corrupted(location, "zip 文件名无法解码") }
        return name
    }

    private static func dosDate(date: UInt16, time: UInt16) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(year: 1980 + Int(date >> 9), month: Int((date >> 5) & 15), day: Int(date & 31),
                                        hour: Int(time >> 11), minute: Int((time >> 5) & 63), second: Int(time & 31) * 2)
        return calendar.date(from: components).map { Int64($0.timeIntervalSince1970 * 1e9) } ?? 0
    }
}
