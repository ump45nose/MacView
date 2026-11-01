import Foundation
import MVFoundation
import MVIO

struct ArchiveRecord: Sendable {
    var path: [String]
    var size: Int64
    var modificationNanos: Int64
    var checksum: UInt32?
    var kind: EntryKind
    var offset: Int64
    var compressedSize: Int64
    var method: UInt16 = 0
    var localHeader: Bool = false

    func entry(in archive: Location) -> Entry {
        Entry(identity: ContentIdentity(location: archive.appendingLayer(path), size: size,
                                       modificationNanos: modificationNanos, checksum: checksum),
              name: path.last ?? "", kind: kind)
    }
}

struct ArchiveIndex: Sendable {
    var records: [[String]: ArchiveRecord] = [:]
    var order: [[String]] = []

    mutating func append(_ record: ArchiveRecord) {
        // 没有显式目录条目的 zip/tar 仍提供完整目录树。后来的显式目录覆盖合成项。
        for count in 1..<record.path.count {
            let path = Array(record.path.prefix(count))
            if records[path] == nil {
                order.append(path)
                records[path] = ArchiveRecord(path: path, size: 0, modificationNanos: record.modificationNanos,
                                              kind: .directory, offset: 0, compressedSize: 0)
            }
        }
        if records[record.path] == nil { order.append(record.path) }
        records[record.path] = record
    }

    func children(in archive: Location, path: [String]) -> [Entry] {
        order.compactMap { key in
            guard key.count == path.count + 1, key.starts(with: path) else { return nil }
            return records[key]?.entry(in: archive)
        }
    }
}

func archivePath(_ name: String, at location: Location) throws -> [String] {
    let components = name.split(separator: "/").map(String.init).filter { $0 != "." }
    guard !components.isEmpty, !components.contains(".."), !components.contains(where: { $0.contains("\0") }) else {
        throw IOError.corrupted(location, "无效的归档路径")
    }
    return components
}

func archiveCheckCancellation() throws {
    if Task.isCancelled { throw IOError.cancelled }
}

func archiveRead(_ source: any ByteSource, _ range: Range<Int64>, priority: IOPriority,
                 group: IORequestGroup? = nil) async throws -> Data {
    try archiveCheckCancellation()
    guard range.lowerBound >= 0, range.upperBound <= source.identity.size else {
        throw IOError.corrupted(source.identity.location, "归档数据超出文件范围")
    }
    let data = try await source.read(range, priority: priority, group: group)
    guard Int64(data.count) == range.upperBound - range.lowerBound else {
        throw IOError.corrupted(source.identity.location, "归档数据不完整")
    }
    return data
}

extension Data {
    func archiveInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    func archiveString(_ range: Range<Int>) -> String {
        String(decoding: self[range].prefix { $0 != 0 }, as: UTF8.self)
    }
}
