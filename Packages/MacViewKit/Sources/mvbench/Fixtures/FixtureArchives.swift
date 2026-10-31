import Foundation

// 夹具用的 zip、tar、gzip 写入器。自己按格式逐字节写，才能精确控制 ZIP64、数据描述符、文件名编码和 tar 头的类型。

struct FixtureError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// 时间戳统一为 2025-01-01 00:00:00 UTC，生成结果才能逐字节重复。
let fixtureEpoch: Int64 = 1_735_689_600

// MARK: - zip

struct ZipEntry {
    enum Compression: String {
        case stored, deflate
    }

    /// 解码后的路径；目录以 `/` 结尾。
    var path: String
    var data = Data()
    var compression = Compression.deflate

    var isDirectory: Bool { path.hasSuffix("/") }
}

struct ZipOptions {
    enum Names {
        /// 只有 ASCII，不设 UTF-8 标志。
        case ascii
        /// 设 UTF-8 标志。
        case utf8
        /// GBK 编码、不设 UTF-8 标志，制作方标为 MS-DOS，与中文 Windows 上的旧工具一致。
        case gbk
    }

    var names = Names.ascii
    /// 全部条目和目录结尾都用 ZIP64 格式，与文件大小无关。
    var zip64 = false
    /// 文件条目的 CRC 与大小写在数据之后的数据描述符里，本地头中为 0。
    var dataDescriptor = false
}

enum ZipWriter {
    /// 2025-01-01 00:00:00 的 MS-DOS 日期与时间。
    private static let dosDate: UInt16 = (2025 - 1980) << 9 | 1 << 5 | 1
    private static let dosTime: UInt16 = 0

    static func archive(_ entries: [ZipEntry], options: ZipOptions = ZipOptions()) throws -> Data {
        var output = ByteWriter()
        var central = ByteWriter()
        let madeBy: UInt16 = options.names == .gbk ? 20 : 3 << 8 | 63
        for entry in entries {
            let name = try encodedName(entry.path, options.names)
            let method: UInt16 = entry.compression == .deflate && !entry.isDirectory ? 8 : 0
            let payload = method == 8 ? try deflate(entry.data) : entry.data
            let crc = CRC32.checksum(entry.data)
            let size = UInt64(entry.data.count)
            let compressed = UInt64(payload.count)
            let offset = UInt64(output.count)
            let descriptor = options.dataDescriptor && !entry.isDirectory
            var flags: UInt16 = 0
            if options.names == .utf8 { flags |= 1 << 11 }
            if descriptor { flags |= 1 << 3 }
            let needed: UInt16 = options.zip64 ? 45 : (method == 8 || entry.isDirectory ? 20 : 10)

            output.u32(0x0403_4B50)
            output.u16(needed)
            output.u16(flags)
            output.u16(method)
            output.u16(dosTime)
            output.u16(dosDate)
            output.u32(descriptor ? 0 : crc)
            if options.zip64 {
                output.u32(0xFFFF_FFFF)
                output.u32(0xFFFF_FFFF)
            } else {
                output.u32(descriptor ? 0 : UInt32(compressed))
                output.u32(descriptor ? 0 : UInt32(size))
            }
            output.u16(UInt16(name.count))
            output.u16(options.zip64 ? 20 : 0)
            output.bytes(name)
            if options.zip64 {
                // 本地头的 ZIP64 字段依次是原始大小和压缩后大小；有数据描述符时为 0。
                output.u16(0x0001)
                output.u16(16)
                output.u64(descriptor ? 0 : size)
                output.u64(descriptor ? 0 : compressed)
            }
            output.bytes(payload)
            if descriptor {
                output.u32(0x0807_4B50)
                output.u32(crc)
                if options.zip64 {
                    output.u64(compressed)
                    output.u64(size)
                } else {
                    output.u32(UInt32(compressed))
                    output.u32(UInt32(size))
                }
            }

            central.u32(0x0201_4B50)
            central.u16(madeBy)
            central.u16(needed)
            central.u16(flags)
            central.u16(method)
            central.u16(dosTime)
            central.u16(dosDate)
            central.u32(crc)
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(compressed))
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(size))
            central.u16(UInt16(name.count))
            central.u16(options.zip64 ? 28 : 0)
            central.u16(0)   // 注释长度
            central.u16(0)   // 起始磁盘
            central.u16(0)   // 内部属性
            central.u32(externalAttributes(directory: entry.isDirectory, dos: options.names == .gbk))
            central.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central.bytes(name)
            if options.zip64 {
                central.u16(0x0001)
                central.u16(24)
                central.u64(size)
                central.u64(compressed)
                central.u64(offset)
            }
        }

        let centralOffset = UInt64(output.count)
        let centralSize = UInt64(central.count)
        let count = UInt64(entries.count)
        output.bytes(central.data)
        if options.zip64 {
            let recordOffset = UInt64(output.count)
            output.u32(0x0606_4B50)
            output.u64(44)
            output.u16(madeBy)
            output.u16(45)
            output.u32(0)
            output.u32(0)
            output.u64(count)
            output.u64(count)
            output.u64(centralSize)
            output.u64(centralOffset)
            output.u32(0x0706_4B50)
            output.u32(0)
            output.u64(recordOffset)
            output.u32(1)
        }
        output.u32(0x0605_4B50)
        output.u16(0)
        output.u16(0)
        output.u16(options.zip64 ? 0xFFFF : UInt16(count))
        output.u16(options.zip64 ? 0xFFFF : UInt16(count))
        output.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(centralSize))
        output.u32(options.zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        output.u16(0)
        return output.data
    }

    private static func encodedName(_ path: String, _ names: ZipOptions.Names) throws -> [UInt8] {
        switch names {
        case .ascii:
            guard path.allSatisfy(\.isASCII) else { throw FixtureError("zip 条目名不是 ASCII：\(path)") }
            return Array(path.utf8)
        case .utf8:
            return Array(path.utf8)
        case .gbk:
            guard let data = path.data(using: .gbk) else { throw FixtureError("无法用 GBK 编码：\(path)") }
            return Array(data)
        }
    }

    private static func externalAttributes(directory: Bool, dos: Bool) -> UInt32 {
        switch (dos, directory) {
        case (true, true): 0x10
        case (true, false): 0x20
        case (false, true): 0o040755 << 16 | 0x10
        case (false, false): 0o100644 << 16
        }
    }
}

extension String.Encoding {
    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
}

// MARK: - tar

struct TarEntry {
    /// 目录以 `/` 结尾。
    var path: String
    var data = Data()

    var isDirectory: Bool { path.hasSuffix("/") }
}

enum TarWriter {
    enum Style {
        /// POSIX ustar：超过 100 字节的路径拆进 prefix 字段，拆不开就报错。
        case ustar
        /// 路径超过 100 字节或含非 ASCII 字符时，写进 pax 扩展头；ustar 头里放 ASCII 的替代名。
        case pax
        /// GNU：路径超过 100 字节时，先写一个 `././@LongLink` 条目。
        case gnu
    }

    static func archive(_ entries: [TarEntry], style: Style) throws -> Data {
        var output = Data()
        for entry in entries {
            let path = Array(entry.path.utf8)
            let type: UInt8 = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
            let mode = entry.isDirectory ? 0o755 : 0o644
            switch style {
            case .ustar:
                let (prefix, name) = try split(path)
                output += header(name: name, prefix: prefix, size: entry.data.count, type: type, mode: mode, gnu: false)
            case .pax:
                if path.count > 100 || !entry.path.allSatisfy(\.isASCII) {
                    let record = paxRecord(key: "path", value: entry.path)
                    let fallback = path.map { $0 < 0x80 ? $0 : UInt8(ascii: "_") }
                    output += header(name: Array("PaxHeaders/".utf8) + fallback.suffix(89), size: record.count, type: UInt8(ascii: "x"), mode: 0o644, gnu: false)
                    output += padded(record)
                    output += header(name: Array(fallback.suffix(100)), size: entry.data.count, type: type, mode: mode, gnu: false)
                } else {
                    output += header(name: path, size: entry.data.count, type: type, mode: mode, gnu: false)
                }
            case .gnu:
                if path.count > 100 {
                    output += header(name: Array("././@LongLink".utf8), size: path.count + 1, type: UInt8(ascii: "L"), mode: 0o644, gnu: true)
                    output += padded(Data(path + [0]))
                }
                output += header(name: Array(path.prefix(100)), size: entry.data.count, type: type, mode: mode, gnu: true)
            }
            output += padded(entry.data)
        }
        output += Data(count: 1024)
        // 与 bsdtar、GNU tar 一样，按 20 个块（10240 字节）的记录补齐。
        output += Data(count: (10240 - output.count % 10240) % 10240)
        return output
    }

    private static func split(_ path: [UInt8]) throws -> (prefix: [UInt8], name: [UInt8]) {
        if path.count <= 100 { return ([], path) }
        for index in path.indices where path[index] == UInt8(ascii: "/") && index <= 155 && path.count - index - 1 <= 100 && index + 1 < path.count {
            return (Array(path[..<index]), Array(path[(index + 1)...]))
        }
        throw FixtureError("路径无法放进 ustar 头：\(String(decoding: path, as: UTF8.self))")
    }

    /// pax 记录 `<长度> <键>=<值>\n`，长度包括它自己的位数。
    private static func paxRecord(key: String, value: String) -> Data {
        let body = " \(key)=\(value)\n".utf8.count
        var digits = String(body).count
        while String(body + digits).count != digits {
            digits = String(body + digits).count
        }
        return Data("\(body + digits) \(key)=\(value)\n".utf8)
    }

    private static func header(name: [UInt8], prefix: [UInt8] = [], size: Int, type: UInt8, mode: Int, gnu: Bool) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int) {
            block.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        func octal(_ value: Int, at offset: Int, width: Int) {
            let digits = String(value, radix: 8)
            put(Array((String(repeating: "0", count: width - 1 - digits.count) + digits).utf8), at: offset)
        }
        put(name, at: 0)
        octal(mode, at: 100, width: 8)
        octal(0, at: 108, width: 8)
        octal(0, at: 116, width: 8)
        octal(size, at: 124, width: 12)
        octal(Int(fixtureEpoch), at: 136, width: 12)
        put(Array(repeating: UInt8(ascii: " "), count: 8), at: 148)
        block[156] = type
        put(Array((gnu ? "ustar  " : "ustar\u{0}00").utf8), at: 257)
        put(Array("macview".utf8), at: 265)
        put(Array("staff".utf8), at: 297)
        if !gnu {
            octal(0, at: 329, width: 8)
            octal(0, at: 337, width: 8)
        }
        put(prefix, at: 345)
        let checksum = String(block.reduce(0) { $0 + Int($1) }, radix: 8)
        put(Array((String(repeating: "0", count: 6 - checksum.count) + checksum).utf8) + [0, UInt8(ascii: " ")], at: 148)
        return Data(block)
    }

    private static func padded(_ data: Data) -> Data {
        data + Data(count: (512 - data.count % 512) % 512)
    }
}

// MARK: - gzip

enum Gzip {
    /// 单成员 gzip；`originalName` 写进头部的 FNAME 字段。修改时间记为 0（未知），结果才能重复。
    static func compress(_ data: Data, originalName: String? = nil) throws -> Data {
        var output = ByteWriter()
        output.bytes([0x1F, 0x8B, 8, originalName == nil ? 0 : 0x08])
        output.u32(0)
        output.bytes([0, 3])
        if let originalName {
            output.bytes(Array(originalName.utf8) + [0])
        }
        output.bytes(try deflate(data))
        output.u32(CRC32.checksum(data))
        output.u32(UInt32(truncatingIfNeeded: data.count))
        return output.data
    }
}

/// 原始 DEFLATE（RFC 1951），zip 和 gzip 共用。
func deflate(_ data: Data) throws -> Data {
    try (data as NSData).compressed(using: .zlib) as Data
}

// MARK: - 基础

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

/// 按小端写入整数。
struct ByteWriter {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func bytes<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        data.append(contentsOf: bytes)
    }

    mutating func bytes(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
