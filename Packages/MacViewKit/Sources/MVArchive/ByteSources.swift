import Foundation
import MVFoundation
import MVIO

struct RangeByteSource: ByteSource {
    let identity: ContentIdentity
    let outer: any ByteSource
    let offset: Int64

    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        let lower = max(0, range.lowerBound)
        let upper = min(identity.size, range.upperBound)
        guard lower < upper else { return Data() }
        let data = try await archiveRead(outer, offset + lower..<offset + upper, priority: priority, group: group)
        if lower == 0, upper == identity.size, let checksum = identity.checksum,
           ArchiveCRC.checksum(data) != checksum {
            throw IOError.corrupted(identity.location, "zip CRC32 不一致")
        }
        return data
    }
}

struct LeasedByteSource: ByteSource {
    let identity: ContentIdentity
    let source: any ByteSource
    let lease: ExtractLease

    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        // 显式延长租约到异步读取返回；淘汰不能删除正在读的文件。
        let result = try await source.read(range, priority: priority, group: group)
        withExtendedLifetime(lease) {}
        return result
    }
}

struct DeflateByteSource: ByteSource {
    let identity: ContentIdentity
    let outer: any ByteSource
    let range: Range<Int64>

    func read(_ requested: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data {
        let lower = max(0, requested.lowerBound)
        let upper = min(identity.size, requested.upperBound)
        guard lower < upper else { return Data() }
        var result = Data(capacity: Int(upper - lower))
        var offset: Int64 = 0
        try await ArchiveInflate.run(outer, range: range, priority: priority, group: group,
                                     expectedSize: identity.size, checksum: identity.checksum,
                                     stopAt: upper == identity.size ? nil : upper) { chunk in
            let end = offset + Int64(chunk.count)
            let start = max(lower, offset)
            let finish = min(upper, end)
            if start < finish { result.append(chunk[Int(start - offset)..<Int(finish - offset)]) }
            offset = end
        }
        return result
    }

    func extract(to output: ExtractOutput, priority: IOPriority) async throws {
        try await ArchiveInflate.run(outer, range: range, priority: priority, group: nil,
                                     expectedSize: identity.size, checksum: identity.checksum) { chunk in
            try await output.write(chunk)
        }
    }
}
