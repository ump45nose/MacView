import Darwin
import Foundation

/// 主进程与 I/O 辅助进程之间的消息。每帧是 4 字节小端长度加正文，正文以请求编号开头。
enum HelperRequest: Sendable, Equatable {
    case stat(path: String)
    case read(ReadRequest)
    case list(path: String)
    /// 卷的健康探测，成功时回复 `done`。
    case probe(mountPoint: String)
    /// 停止一次还在分批返回的列目录。
    case cancel(id: UInt64)
}

enum HelperResponse: Sendable, Equatable {
    case attributes(FileAttributes)
    case data(Data)
    /// 列目录的一批；之后是更多的批，或者 `done`、`failure`。
    case batch([FileAttributes])
    case done
    case failure(FileOperationError)
}

enum HelperCodec {
    static func encode(id: UInt64, _ request: HelperRequest) -> Data {
        var writer = FrameWriter(id: id)
        switch request {
        case let .stat(path):
            writer.add(UInt8(1))
            writer.add(path)
        case let .read(read):
            writer.add(UInt8(2))
            writer.add(read.path)
            writer.add(read.offset)
            writer.add(Int64(read.length))
            writer.add(read.expectedSize)
            writer.add(read.expectedModificationNanos)
            writer.add(read.noCache)
            writer.add(read.retryByReopening)
        case let .list(path):
            writer.add(UInt8(3))
            writer.add(path)
        case let .cancel(target):
            writer.add(UInt8(4))
            writer.add(target)
        case let .probe(mountPoint):
            writer.add(UInt8(5))
            writer.add(mountPoint)
        }
        return writer.finish()
    }

    static func encode(id: UInt64, _ response: HelperResponse) -> Data {
        var writer = FrameWriter(id: id)
        switch response {
        case let .attributes(attributes):
            writer.add(UInt8(1))
            writer.add(attributes)
        case let .data(data):
            writer.add(UInt8(2))
            writer.add(data)
        case let .batch(entries):
            writer.add(UInt8(3))
            writer.add(UInt32(entries.count))
            entries.forEach { writer.add($0) }
        case .done:
            writer.add(UInt8(4))
        case let .failure(error):
            writer.add(UInt8(5))
            switch error {
            case let .system(call, code):
                writer.add(UInt8(0))
                writer.add(call)
                writer.add(Int64(code))
            case .changed:
                writer.add(UInt8(1))
            case .helperLost:
                writer.add(UInt8(2))
            }
        }
        return writer.finish()
    }

    static func decodeRequest(_ body: Data) throws -> (UInt64, HelperRequest) {
        var reader = FrameReader(body)
        let id = try reader.uint64()
        switch try reader.uint8() {
        case 1:
            return (id, .stat(path: try reader.string()))
        case 2:
            let request = ReadRequest(
                path: try reader.string(),
                offset: try reader.int64(),
                length: Int(try reader.int64()),
                expectedSize: try reader.optionalInt64(),
                expectedModificationNanos: try reader.optionalInt64(),
                noCache: try reader.bool(),
                retryByReopening: try reader.bool()
            )
            return (id, .read(request))
        case 3:
            return (id, .list(path: try reader.string()))
        case 4:
            return (id, .cancel(id: try reader.uint64()))
        case 5:
            return (id, .probe(mountPoint: try reader.string()))
        case let kind:
            throw HelperProtocolError("未知的请求类型 \(kind)")
        }
    }

    static func decodeResponse(_ body: Data) throws -> (UInt64, HelperResponse) {
        var reader = FrameReader(body)
        let id = try reader.uint64()
        switch try reader.uint8() {
        case 1:
            return (id, .attributes(try reader.attributes()))
        case 2:
            return (id, .data(try reader.blob()))
        case 3:
            let count = Int(try reader.uint32())
            var entries: [FileAttributes] = []
            entries.reserveCapacity(count)
            for _ in 0..<count { entries.append(try reader.attributes()) }
            return (id, .batch(entries))
        case 4:
            return (id, .done)
        case 5:
            switch try reader.uint8() {
            case 0: return (id, .failure(.system(call: try reader.string(), code: Int32(try reader.int64()))))
            case 1: return (id, .failure(.changed))
            default: return (id, .failure(.helperLost))
            }
        case let kind:
            throw HelperProtocolError("未知的回复类型 \(kind)")
        }
    }
}

struct HelperProtocolError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// 帧的读写，整数一律小端。
struct FrameWriter {
    private var data = Data(count: 4)

    init(id: UInt64) {
        add(id)
    }

    mutating func add(_ value: UInt8) {
        data.append(value)
    }

    mutating func add(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    mutating func add(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func add(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func add(_ value: Int64) {
        add(UInt64(bitPattern: value))
    }

    mutating func add(_ value: Int64?) {
        add(value != nil)
        add(value ?? 0)
    }

    mutating func add(_ value: Data) {
        add(UInt32(value.count))
        data.append(value)
    }

    mutating func add(_ value: String) {
        add(Data(value.utf8))
    }

    mutating func add(_ value: FileAttributes) {
        add(value.name)
        add(value.type.rawValue)
        add(value.size)
        add(value.modificationNanos)
        add(value.creationNanos)
    }

    /// 补上开头的长度（不含长度本身）。
    consuming func finish() -> Data {
        let length = UInt32(data.count - 4).littleEndian
        withUnsafeBytes(of: length) { data.replaceSubrange(0..<4, with: $0) }
        return data
    }
}

struct FrameReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw HelperProtocolError("帧不完整") }
        defer { offset += count }
        return data[offset..<offset + count]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        return T(littleEndian: raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }

    mutating func uint8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func uint32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func uint64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func int64() throws -> Int64 { Int64(bitPattern: try uint64()) }
    mutating func bool() throws -> Bool { try uint8() != 0 }

    mutating func optionalInt64() throws -> Int64? {
        let present = try bool()
        let value = try int64()
        return present ? value : nil
    }

    mutating func blob() throws -> Data {
        Data(try bytes(Int(try uint32())))
    }

    mutating func string() throws -> String {
        guard let string = String(data: try blob(), encoding: .utf8) else { throw HelperProtocolError("字符串不是 UTF-8") }
        return string
    }

    mutating func attributes() throws -> FileAttributes {
        let name = try string()
        guard let type = FileAttributes.FileType(rawValue: try uint8()) else { throw HelperProtocolError("未知的文件类型") }
        return FileAttributes(name: name, type: type, size: try int64(), modificationNanos: try int64(), creationNanos: try optionalInt64())
    }
}

/// 套接字上的帧收发。读写都会阻塞，只在专用线程上调用。
enum FrameIO {
    /// 读一帧的正文；对端关闭时返回 nil。
    static func read(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        return readExactly(fd, length)
    }

    /// 写完整的一帧；失败时返回 false。
    static func write(_ fd: Int32, _ frame: Data) -> Bool {
        frame.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + done, buffer.count - done)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += count
            }
            return true
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let read = Darwin.read(fd, buffer.baseAddress! + done, count - done)
                if read < 0, errno == EINTR { continue }
                if read <= 0 { return false }
                done += read
            }
            return true
        }
        return complete ? data : nil
    }
}
