import Foundation
import MVFoundation

/// 缓存内部格式 v1：直接保存 Entry 的全部字段，避免热路径遍历 JSON 对象树。
/// 格式头、整数及浮点位模式跨进程稳定；格式不匹配或损坏时向调用方报错。
enum DirectoryListingStorage {
    private static let header = Data([0x4d, 0x56, 0x43, 0x4c, 1])

    static func encode(_ listing: DirectoryListing) throws -> Data {
        var writer = Writer()
        writer.data.append(header)
        writer.data.reserveCapacity(listing.entries.count * 100)
        writer.byte(listing.directoryModificationNanos == nil ? 0 : 1)
        if let nanos = listing.directoryModificationNanos { writer.integer(UInt64(bitPattern: nanos)) }
        try writer.count(listing.entries.count)
        for entry in listing.entries { try writer.entry(entry) }
        return writer.data
    }

    static func decode(_ data: Data) throws -> DirectoryListing {
        try data.withUnsafeBytes { bytes in
            guard data.starts(with: header) else { throw malformed("目录缓存格式版本不受支持") }
            var reader = Reader(bytes: bytes, offset: header.count)
            let nanos = try reader.present() ? Int64(bitPattern: reader.integer() as UInt64) : nil
            let count = try reader.count()
            guard count <= reader.remaining / 8 else { throw malformed() }
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let location = try reader.location()
                let size = Int64(bitPattern: try reader.integer() as UInt64)
                let modified = Int64(bitPattern: try reader.integer() as UInt64)
                let checksum: UInt32? = try reader.present() ? reader.integer() : nil
                let name = try reader.present() ? reader.string() : location.name
                let kind: EntryKind
                switch try reader.byte() {
                case 0: kind = .directory
                case 1:
                    switch try reader.byte() {
                    case 0: kind = .archive(.zip)
                    case 1: kind = .archive(.tar)
                    case 2: kind = .archive(.tarGzip)
                    case 3: kind = .archive(.gzip)
                    default: throw malformed()
                    }
                case 2: kind = .image
                case 3: kind = .video
                case 4: kind = .other
                default: throw malformed()
                }
                let created = try reader.present() ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: reader.integer())) : nil
                entries.append(Entry(identity: ContentIdentity(location: location, size: size, modificationNanos: modified, checksum: checksum), name: name, kind: kind, created: created))
            }
            guard reader.remaining == 0 else { throw malformed() }
            return DirectoryListing(entries: entries, directoryModificationNanos: nanos)
        }
    }

    private struct Writer {
        var data = Data()
        mutating func entry(_ entry: Entry) throws {
            try location(entry.location)
            integer(UInt64(bitPattern: entry.identity.size))
            integer(UInt64(bitPattern: entry.identity.modificationNanos))
            byte(entry.identity.checksum == nil ? 0 : 1)
            if let checksum = entry.identity.checksum { integer(checksum) }
            // 名称通常等于末端路径，省去第二份相同字符串的分配。
            byte(entry.name == entry.location.name ? 0 : 1)
            if entry.name != entry.location.name { try string(entry.name) }
            switch entry.kind {
            case .directory: byte(0)
            case let .archive(format):
                byte(1)
                switch format {
                case .zip: byte(0)
                case .tar: byte(1)
                case .tarGzip: byte(2)
                case .gzip: byte(3)
                }
            case .image: byte(2)
            case .video: byte(3)
            case .other: byte(4)
            }
            byte(entry.created == nil ? 0 : 1)
            if let created = entry.created { integer(created.timeIntervalSinceReferenceDate.bitPattern) }
        }
        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func integer<Value: FixedWidthInteger>(_ value: Value) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        mutating func count(_ value: Int) throws {
            guard let count = UInt32(exactly: value) else { throw malformed("目录缓存字段过长") }
            integer(count)
        }
        mutating func string(_ value: String) throws {
            try count(value.utf8.count)
            data.append(contentsOf: value.utf8)
        }
        mutating func location(_ location: Location) throws {
            switch location.root {
            case .local: byte(0)
            case let .network(scheme, host, share):
                byte(1)
                try string(scheme); try string(host); try string(share)
            case let .plugin(id): byte(2); try string(id)
            }
            try count(location.layers.count)
            for layer in location.layers {
                try count(layer.count)
                for part in layer { try string(part) }
            }
        }
    }

    private struct Reader {
        var bytes: UnsafeRawBufferPointer
        var offset: Int
        var remaining: Int { bytes.count - offset }
        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw malformed() }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func integer<Value: FixedWidthInteger>() throws -> Value {
            let length = MemoryLayout<Value>.size
            guard remaining >= length else { throw malformed() }
            defer { offset += length }
            return Value(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Value.self))
        }
        mutating func count() throws -> Int { Int(try integer() as UInt32) }
        mutating func present() throws -> Bool {
            switch try byte() {
            case 0: false
            case 1: true
            default: throw malformed()
            }
        }
        mutating func string() throws -> String {
            let length = try count()
            guard length <= remaining, let string = String(bytes: bytes[offset..<offset + length], encoding: .utf8) else { throw malformed() }
            offset += length
            return string
        }
        mutating func location() throws -> Location {
            let root: Location.Root
            switch try byte() {
            case 0: root = .local
            case 1: root = .network(scheme: try string(), host: try string(), share: try string())
            case 2: root = .plugin(id: try string())
            default: throw malformed()
            }
            let count = try count()
            guard count <= remaining / 4 else { throw malformed() }
            var layers: [[String]] = []
            layers.reserveCapacity(count)
            for _ in 0..<count {
                let parts = try self.count()
                guard parts <= remaining / 4 else { throw malformed() }
                var layer: [String] = []
                layer.reserveCapacity(parts)
                for _ in 0..<parts { layer.append(try string()) }
                layers.append(layer)
            }
            return Location(root: root, layers: layers)
        }
    }

    private static func malformed(_ message: String = "目录缓存数据损坏") -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: message))
    }
}
