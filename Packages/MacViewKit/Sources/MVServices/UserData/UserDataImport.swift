import Darwin
import Foundation

extension UserDataArchive {
    private struct Journal: Codable {
        enum State: String, Codable { case applying, committed }
        var state: State
        var existed: [String: Bool]
        // 老记录没有该字段。新替换在第一次移动之前就确定跨卷复制的临时文件名。
        var moveID: UUID?
        var layoutPath: String?
        // 仅用于升级旧记录：删暂存后若再中断，仍记得本次没有布局需要恢复。
        var layoutOmitted: Bool?

        var layoutCopyID: UUID? { layoutPath == nil ? nil : moveID }

        func save(in locations: UserDataLocations) throws {
            try JSONEncoder().encode(self).write(to: locations.rollback.appending(path: "journal.json"), options: .atomic)
        }
    }

    /// SQLite 的主文件和两个附属文件分别记录，以区分从未存在、还没挪走和已经恢复。
    private struct Part {
        var name: String
        var live: URL
    }

    private static func parts(for item: UserDataItem, in locations: UserDataLocations) -> [Part] {
        let url = item.url(in: locations)
        var parts = [Part(name: item.rawValue, live: url)]
        if item.kind == .sqlite {
            for suffix in ["-wal", "-shm"] {
                parts.append(Part(name: item.rawValue + suffix, live: URL(filePath: url.path + suffix)))
            }
        }
        return parts
    }

    public static func applyPendingImport(for locations: UserDataLocations, origin: UserDataOrigin) async -> UserDataImportOutcome? {
        await applyPendingImport(for: locations, origin: origin, move: move)
    }

    static func applyPendingImport(for locations: UserDataLocations, origin: UserDataOrigin,
                                   move: @escaping @Sendable (URL, URL, UUID) throws -> Void) async -> UserDataImportOutcome? {
        await withCheckedContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try apply(locations, origin: origin, move: move)) }
                catch {
                    continuation.resume(returning: .recoveryFailed(reason: String(localized: "无法恢复或清理上次导入的数据。", bundle: .main)))
                }
            }
        }
    }

    private static func apply(_ requested: UserDataLocations, origin: UserDataOrigin,
                              move: (URL, URL, UUID) throws -> Void) throws -> UserDataImportOutcome? {
        var locations = requested
        let journalFile = locations.rollback.appending(path: "journal.json")
        if try type(of: journalFile) != nil {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalFile))
            if let path = journal.layoutPath {
                guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0),
                      URL(filePath: path).standardizedFileURL.path == path else { throw CocoaError(.fileReadCorruptFile) }
                locations.layoutFile = URL(filePath: path)
            }
            if journal.state == .committed {
                try cleanup(locations, moveID: journal.layoutCopyID)
                return nil
            }
            try restore(journal, in: locations)
            return .rolledBack(reason: String(localized: "上次导入中断，已恢复原数据。", bundle: .main))
        }
        // 不带记录的回滚目录只会出现在写记录之前或清理的最后一步，此时应为空。
        if try type(of: locations.rollback) != nil {
            guard try files.contentsOfDirectory(atPath: locations.rollback.path).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try files.removeItem(at: locations.rollback)
        }
        guard try type(of: locations.staging) != nil else { return nil }
        let ready = locations.staging.appending(path: "ready")
        guard try type(of: ready) == S_IFREG else {
            try removeIfPresent(locations.staging)
            return nil
        }

        // 记录并使用同一个绝对位置。后续启动的布局参数和目录别名可以改变。
        let layoutParent = requested.layoutFile.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        locations.layoutFile = layoutParent.appending(path: requested.layoutFile.lastPathComponent)
        let backup = backupURL(for: locations)
        let manifest: UserDataManifest
        var journal: Journal
        let moveID = UUID()
        do {
            let token = try Data(contentsOf: locations.staging.appending(path: "token"))
            guard try Data(contentsOf: ready) == token, UUID(uuidString: String(decoding: token, as: UTF8.self)) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            manifest = try readManifest(in: locations.staging)
            try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try writeArchive(from: locations, origin: origin, to: backup)
            var existed: [String: Bool] = [:]
            for part in UserDataItem.allCases.flatMap({ parts(for: $0, in: locations) }) {
                existed[part.name] = try type(of: part.live) != nil
            }
            guard try type(of: scratch(beside: locations.layoutFile, id: moveID)) == nil else { throw POSIXError(.EEXIST) }
            journal = Journal(state: .applying, existed: existed, moveID: moveID, layoutPath: locations.layoutFile.path)
            try makePrivateDirectory(locations.rollback)
            try journal.save(in: locations)
        } catch {
            try removeIfPresent(locations.staging)
            try removeIfPresent(locations.rollback)
            return .rolledBack(reason: (error as? UserDataArchiveError)?.localizedDescription
                ?? String(localized: "无法准备导入或备份本机数据。", bundle: .main))
        }

        do {
            for item in UserDataItem.allCases {
                for part in parts(for: item, in: locations) where journal.existed[part.name] == true {
                    try move(part.live, locations.rollback.appending(path: part.name), moveID)
                }
                if manifest.items.contains(item) {
                    let target = item.url(in: locations)
                    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try move(locations.staging.appending(path: "data").appending(path: item.rawValue), target, moveID)
                }
            }
            if manifest.items.contains(.pluginSecrets) {
                guard chmod(UserDataItem.pluginSecrets.url(in: locations).path, 0o600) == 0 else { throw posixError() }
            }
            journal.state = .committed
            try journal.save(in: locations)
        } catch {
            try restore(journal, in: locations)
            return .rolledBack(reason: String(localized: "替换用户数据失败，已恢复原数据。", bundle: .main))
        }
        try cleanup(locations, moveID: journal.layoutCopyID)
        return .imported(manifest, backup: backup)
    }

    private static func restore(_ journal: Journal, in locations: UserDataLocations) throws {
        let allParts = UserDataItem.allCases.flatMap { parts(for: $0, in: locations) }
        guard Set(journal.existed.keys) == Set(allParts.map(\.name)) else { throw CocoaError(.fileReadCorruptFile) }
        // 旧记录无法确认布局原来放在哪里。只有新旧都无布局时才可跳过这一项，恢复其他项。
        let parts: [Part]
        let recordOmission = journal.layoutPath == nil && journal.layoutOmitted != true
        if journal.layoutPath == nil {
            guard journal.existed[UserDataItem.layout.rawValue] == false else { throw CocoaError(.fileReadCorruptFile) }
            if recordOmission, try readManifest(in: locations.staging).items.contains(.layout) { throw CocoaError(.fileReadCorruptFile) }
            parts = allParts.filter { $0.name != UserDataItem.layout.rawValue }
        } else {
            parts = allParts
        }
        // 在改变现场前，先确认所有原件仍在回滚目录或原位。
        for part in parts where journal.existed[part.name] == true {
            guard try type(of: locations.rollback.appending(path: part.name)) != nil || type(of: part.live) != nil else {
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
        // 半次跨卷复制的源仍完整；先清除这个事务的半成品，下一次复制可以从头开始。
        var journal = journal
        let moveID = journal.moveID ?? UUID()
        if journal.moveID == nil || recordOmission {
            if journal.layoutPath != nil, try type(of: scratch(beside: locations.layoutFile, id: moveID)) != nil {
                throw POSIXError(.EEXIST)
            }
            journal.moveID = moveID
            if recordOmission { journal.layoutOmitted = true }
            try journal.save(in: locations)
        }
        if let id = journal.layoutCopyID { try removeIfPresent(scratch(beside: locations.layoutFile, id: id)) }
        try removeIfPresent(scratch(beside: locations.rollback.appending(path: UserDataItem.layout.rawValue), id: moveID))
        for part in parts {
            if journal.existed[part.name] == true {
                let saved = locations.rollback.appending(path: part.name)
                if try type(of: saved) != nil {
                    try removeIfPresent(part.live)
                    try move(saved, part.live, moveID)
                }
            } else {
                try removeIfPresent(part.live)
            }
        }
        try cleanup(locations, moveID: journal.layoutCopyID)
    }

    private static func cleanup(_ locations: UserDataLocations, moveID: UUID?) throws {
        if let moveID { try removeIfPresent(scratch(beside: locations.layoutFile, id: moveID)) }
        // ready 先消失。记录存在期间重启仍能判定该恢复还是清理；记录最后删除。
        try removeIfPresent(locations.staging)
        let entries = try files.contentsOfDirectory(atPath: locations.rollback.path)
        for name in entries where name != "journal.json" { try files.removeItem(at: locations.rollback.appending(path: name)) }
        try removeIfPresent(locations.rollback.appending(path: "journal.json"))
        try files.removeItem(at: locations.rollback)
    }

    private static func scratch(beside destination: URL, id: UUID) -> URL {
        destination.deletingLastPathComponent().appending(path: ".macview-move-\(id)")
    }

    static func move(_ from: URL, _ to: URL, _ moveID: UUID) throws {
        if rename(from.path, to.path) == 0 { return }
        // layoutFile 可以在另一个卷。先完整复制并原子发布，再移除源，回滚记录始终可重放。
        guard errno == EXDEV else { throw posixError() }
        let copy = scratch(beside: to, id: moveID)
        guard try type(of: copy) == nil else { throw POSIXError(.EEXIST) }
        defer { try? removeIfPresent(copy) }
        try files.copyItem(at: from, to: copy)
        guard rename(copy.path, to.path) == 0 else { throw posixError() }
        try files.removeItem(at: from)
    }
}
