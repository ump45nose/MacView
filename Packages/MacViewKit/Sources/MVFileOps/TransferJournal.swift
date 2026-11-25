import Darwin
import Foundation
import MVFoundation
import MVIO

struct TransferRecord: Codable, Sendable, Equatable {
    var id: UUID
    var source: Location
    var target: Location
    var temporary: Location
    var conflict: ConflictPolicy? = nil
}
struct TransferJournal: Codable, Sendable {
    var version: Int = 1
    var transfers: [TransferRecord] = []
}

enum JournalStore {
    static func load(_ url: URL) throws -> TransferJournal {
        do {
            let journal = try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: url))
            guard journal.version == 1 else { throw IOError.underlying(String(localized: "不支持的传输记录版本", bundle: .main)) }
            return journal
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return TransferJournal()
        }
    }
    static func save(_ journal: TransferJournal, to url: URL) throws {
        let bytes = try JSONEncoder().encode(journal)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw IOError.underlying(String(localized: "创建传输记录失败：\(String(cString: strerror(errno)))", bundle: .main)) }
        defer { close(fd); _ = unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw IOError.underlying(String(localized: "写入传输记录失败：\(String(cString: strerror(errno)))", bundle: .main))
                }
                guard count > 0 else { throw IOError.underlying(String(localized: "写入传输记录失败", bundle: .main)) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw IOError.underlying(String(localized: "同步传输记录失败：\(String(cString: strerror(errno)))", bundle: .main)) }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw IOError.underlying(String(localized: "替换传输记录失败：\(String(cString: strerror(errno)))", bundle: .main)) }
    }
    static func update(_ url: URL, _ transform: (inout [TransferRecord]) -> Void) throws {
        var journal = try load(url)
        transform(&journal.transfers)
        try save(journal, to: url)
    }
}
