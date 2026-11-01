import Compression
import Foundation
import MVFoundation
import MVIO

enum ArchiveCRC {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : UInt32(0xEDB8_8320) ^ (value >> 1) }
        return value
    }
    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        data.reduce(crc) { table[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) }
    }
    static func checksum(_ data: Data) -> UInt32 { ~update(.max, with: data) }
}

/// Compression 的 ZLIB 算法读取原始 DEFLATE；gzip 包装由 GzipHeader 单独处理。
enum ArchiveInflate {
    static func run(_ source: any ByteSource, range: Range<Int64>, priority: IOPriority,
                    group: IORequestGroup?, expectedSize: Int64?, checksum: UInt32?,
                    stopAt: Int64? = nil, sink: (Data) async throws -> Void) async throws {
        let decoder = try InflateStream(location: source.identity.location)
        var position = range.lowerBound
        var produced: Int64 = 0
        var crc = UInt32.max
        var ended = false
        while !ended {
            try archiveCheckCancellation()
            let upper = min(position + (4 << 20), range.upperBound)
            let input = try await archiveRead(source, position..<upper, priority: priority, group: group)
            let final = upper == range.upperBound
            var inputOffset = 0
            repeat {
                let step = try decoder.process(input, offset: &inputOffset, final: final)
                ended = step.ended
                produced += Int64(step.data.count)
                if let expectedSize, produced > expectedSize {
                    throw IOError.corrupted(source.identity.location, "解压大小超出条目声明")
                }
                if !step.data.isEmpty {
                    crc = ArchiveCRC.update(crc, with: step.data)
                    try await sink(step.data)
                }
                if let stopAt, produced >= stopAt { return }
                if ended || !step.progressed { break }
            } while inputOffset < input.count || decoder.filledOutput || final
            position = upper
            if final, !ended { throw IOError.corrupted(source.identity.location, "DEFLATE 数据不完整") }
            if ended, inputOffset != input.count || upper != range.upperBound {
                throw IOError.corrupted(source.identity.location, "DEFLATE 尾部有多余数据")
            }
        }
        if let expectedSize, produced != expectedSize { throw IOError.corrupted(source.identity.location, "解压大小不一致") }
        if let checksum, ~crc != checksum { throw IOError.corrupted(source.identity.location, "CRC32 不一致") }
    }
}

private final class InflateStream {
    private var stream: compression_stream
    private let output: UnsafeMutablePointer<UInt8>
    private let capacity = 256 << 10
    private let location: MVFoundation.Location
    private(set) var filledOutput = false

    init(location: MVFoundation.Location) throws {
        self.location = location
        output = .allocate(capacity: capacity)
        stream = compression_stream(dst_ptr: output, dst_size: capacity, src_ptr: output, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            output.deallocate()
            throw IOError.underlying("无法初始化 DEFLATE 解码器")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        output.deallocate()
    }

    func process(_ input: Data, offset: inout Int, final: Bool) throws -> (data: Data, ended: Bool, progressed: Bool) {
        try input.withUnsafeBytes { bytes in
            stream.src_ptr = (bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer(output)).advanced(by: offset)
            stream.src_size = input.count - offset
            try archiveCheckCancellation()
            stream.dst_ptr = output
            stream.dst_size = capacity
            let previous = stream.src_size
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else { throw IOError.corrupted(location, "无效的 DEFLATE 数据") }
            offset += previous - stream.src_size
            let count = capacity - stream.dst_size
            filledOutput = stream.dst_size == 0
            return (Data(bytes: output, count: count), status == COMPRESSION_STATUS_END, count > 0 || previous != stream.src_size)
        }
    }
}
