import CryptoKit
import Foundation

/// 内容身份：位置、大小、修改时间和可选的校验值。文件一变，缓存键随之改变，缓存自然失效。
public struct ContentIdentity: Hashable, Sendable, Codable {
    public var location: Location
    public var size: Int64
    /// 修改时间，自 1970 年起的纳秒数。
    public var modificationNanos: Int64
    /// 可选的校验值，例如 zip 条目的 CRC32。
    public var checksum: UInt32?

    public init(location: Location, size: Int64, modificationNanos: Int64, checksum: UInt32? = nil) {
        self.location = location
        self.size = size
        self.modificationNanos = modificationNanos
        self.checksum = checksum
    }

    /// 缓存键：各字段规范编码后的 SHA-256，取前 16 字节的十六进制。
    ///
    /// 跨进程、跨版本稳定，不能用 `Hasher`（每个进程的种子不同）。改动编码时要换掉版本前缀。
    public var cacheKey: String {
        var encoder = CanonicalEncoder()
        encoder.add("MacView.ContentIdentity.v1")
        switch location.root {
        case .local:
            encoder.add(0)
        case let .network(scheme, host, share):
            encoder.add(1)
            encoder.add(scheme)
            encoder.add(host)
            encoder.add(share)
        case let .plugin(id):
            encoder.add(2)
            encoder.add(id)
        }
        encoder.add(UInt64(location.layers.count))
        for layer in location.layers {
            encoder.add(UInt64(layer.count))
            layer.forEach { encoder.add($0) }
        }
        encoder.add(UInt64(bitPattern: size))
        encoder.add(UInt64(bitPattern: modificationNanos))
        if let checksum {
            encoder.add(1)
            encoder.add(UInt64(checksum))
        } else {
            encoder.add(0)
        }
        return encoder.hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 整数按 64 位小端写入，字符串先写 UTF-8 字节数再写字节。
private struct CanonicalEncoder {
    private(set) var hasher = SHA256()

    mutating func add(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
    }

    mutating func add(_ string: String) {
        let bytes = Array(string.utf8)
        add(UInt64(bytes.count))
        hasher.update(data: bytes)
    }
}

public enum ArchiveFormat: String, Sendable, Codable {
    case zip, tar, tarGzip, gzip
}

public enum EntryKind: Hashable, Sendable, Codable {
    case directory
    case archive(ArchiveFormat)
    case image
    case video
    case other
}

/// 目录或压缩包中的一项。位置、大小和修改时间来自 `identity`。
public struct Entry: Hashable, Sendable, Codable {
    public var identity: ContentIdentity
    public var name: String
    public var kind: EntryKind
    public var created: Date?

    public init(identity: ContentIdentity, name: String, kind: EntryKind, created: Date? = nil) {
        self.identity = identity
        self.name = name
        self.kind = kind
        self.created = created
    }

    public var location: Location { identity.location }
    public var size: Int64 { identity.size }
    public var modified: Date { Date(timeIntervalSince1970: Double(identity.modificationNanos) / 1e9) }
}

extension EntryKind {
    /// 按扩展名判断文件的种类，不读内容；目录由调用方判断。`.gz` 先当作 gzip，是否为 tar 由 MVArchive 按内容判断。
    public init(fileName: String) {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".tar.gz") {
            self = .archive(.tarGzip)
            return
        }
        guard let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex else {
            self = .other
            return
        }
        switch lowered[lowered.index(after: dot)...] {
        case "zip", "cbz": self = .archive(.zip)
        case "tar": self = .archive(.tar)
        case "tgz": self = .archive(.tarGzip)
        case "gz": self = .archive(.gzip)
        case "mp4", "mov", "m4v": self = .video
        case "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "jxl", "tif", "tiff", "bmp", "psd",
             "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2":
            self = .image
        default: self = .other
        }
    }
}
