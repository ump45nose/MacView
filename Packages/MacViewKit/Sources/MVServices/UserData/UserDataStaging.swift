import Darwin
import Foundation
import GRDB
import MVCommands
import MVPlugins
import MVScripting
import MVSettings

extension UserDataArchive {
    public static func stage(_ archive: URL, for locations: UserDataLocations, appValidators: UserDataValidators) async throws -> StagedImport {
        try await perform {
            let staging = locations.staging
            do {
                try removeIfPresent(staging)
                try inspectPaths(archive)
                try files.createDirectory(at: locations.supportDirectory, withIntermediateDirectories: true)
                try makePrivateDirectory(staging)
                try checkArchiveLinks(archive, staging: staging)
                // ditto 保留插件内部的符号链接；将子进程的所有写入限制在暂存目录，
                // 即使后续归档条目经过前一个链接也无法写到本机其他位置。
                let sandbox = "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath (param \"STAGE\")))"
                let root = staging.resolvingSymlinksInPath().path
                try run("/usr/bin/sandbox-exec", ["-D", "STAGE=" + root, "-p", sandbox, "/usr/bin/ditto",
                    "-x", "-k", "--norsrc", "--noextattr", "--noacl", archive.path, root])
                let manifest = try readManifest(in: staging)
                try validatePayload(in: staging, manifest: manifest, appValidators: appValidators)
                let staged = StagedImport(manifest: manifest, token: UUID())
                try Data(staged.token.uuidString.utf8).write(to: staging.appending(path: "token"), options: .atomic)
                return staged
            } catch {
                try removeIfPresent(staging)
                if let error = error as? UserDataArchiveError { throw error }
                throw UserDataArchiveError.damaged(item: nil, reason: String(localized: "无法解包或读取暂存文件。", bundle: .main))
            }
        }
    }

    public static func commitStaged(_ staged: StagedImport, for locations: UserDataLocations) throws {
        try queue.sync {
            let expected = Data(staged.token.uuidString.utf8)
            guard (try? Data(contentsOf: locations.staging.appending(path: "token"))) == expected else {
                throw UserDataArchiveError.damaged(item: nil, reason: String(localized: "待导入的数据已更改，请重新选择文件。", bundle: .main))
            }
            try expected.write(to: locations.staging.appending(path: "ready"), options: .atomic)
        }
    }

    public static func discardStaged(for locations: UserDataLocations) {
        queue.sync { try? removeIfPresent(locations.staging) }
    }

    private static func inspectPaths(_ archive: URL) throws {
        guard let listing = try? run("/usr/bin/zipinfo", ["-1", archive.path]) else { throw UserDataArchiveError.notAnArchive }
        let names = String(decoding: listing, as: UTF8.self).split(separator: "\n")
        guard names.contains("manifest.json") else { throw UserDataArchiveError.notAnArchive }
        for name in names {
            guard name == "manifest.json" || name.hasPrefix("data/") else { throw structureError }
            let parts = (name.hasSuffix("/") ? name.dropLast() : name).split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(".."), !parts.contains("."), !parts.contains("") else { throw structureError }
        }
    }

    private static func checkArchiveLinks(_ archive: URL, staging: URL) throws {
        // zipinfo 的文件名显示会丢失部分 UTF-8 字节。用系统 bsdtar 的只读列表识别符号链接，
        // 同一工具的长、短列表顺序相同，无需拆分含空格、箭头或中文的文件名。
        let details = try run("/usr/bin/tar", ["-tvf", archive.path]).split(separator: 0x0a)
        let linkRows = details.indices.filter { details[$0].first == Character("l").asciiValue }
        guard !linkRows.isEmpty else { return }
        let listing = try run("/usr/bin/tar", ["-tf", archive.path])
        let names = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        guard details.count == names.count else { throw structureError }
        let caseSensitive = try staging.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        try checkLinkHierarchy(names, links: linkRows.map { names[$0] }, caseSensitive: caseSensitive)
    }

    private static func checkLinkHierarchy(_ names: [String], links: [String], caseSensitive: Bool = false) throws {
        func key(_ name: String) -> String {
            let path = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return caseSensitive ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        let linkPaths = Set(links.map(key))
        var seenLinks: Set<String> = []
        for name in names {
            let path = key(name)
            if linkPaths.contains(path) {
                guard !name.hasSuffix("/"), seenLinks.insert(path).inserted else { throw structureError }
            }
            var ancestor = ""
            for component in path.split(separator: "/").dropLast() {
                ancestor += ancestor.isEmpty ? String(component) : "/" + component
                guard !linkPaths.contains(ancestor) else { throw structureError }
            }
        }
    }

    private struct Header: Decodable { var format: Int }

    static func readManifest(in directory: URL) throws -> UserDataManifest {
        let url = directory.appending(path: "manifest.json")
        guard try type(of: url) == S_IFREG else { throw structureError }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { throw UserDataArchiveError.notAnArchive }
        guard header.format <= formatVersion else { throw UserDataArchiveError.newerFormat(header.format) }
        guard let manifest = try? decoder.decode(UserDataManifest.self, from: data) else { throw UserDataArchiveError.notAnArchive }
        return manifest
    }

    static var structureError: UserDataArchiveError {
        .damaged(item: nil, reason: String(localized: "归档中的路径或文件与清单不符。", bundle: .main))
    }

    private static func validatePayload(in directory: URL, manifest: UserDataManifest, appValidators: UserDataValidators) throws {
        let data = directory.appending(path: "data")
        let names = Set(manifest.items.map(\.rawValue))
        guard try Set(files.contentsOfDirectory(atPath: directory.path)) == ["manifest.json", "data"],
              try type(of: data) == S_IFDIR, names.count == manifest.items.count,
              try Set(files.contentsOfDirectory(atPath: data.path)) == names else { throw structureError }
        for item in manifest.items {
            let path = data.appending(path: item.rawValue)
            do {
                guard try type(of: path) == (item.kind == .directory ? S_IFDIR : S_IFREG) else { throw structureError }
                switch item.kind {
                case .directory: break
                case .json:
                    guard try isValidJSON(item, at: path, appValidators: appValidators) else { throw structureError }
                case .sqlite:
                    // SQLite 将零字节文件当成新空库；归档中的快照必须已有数据库头。
                    let handle = try FileHandle(forReadingFrom: path)
                    defer { try? handle.close() }
                    guard try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else { throw structureError }
                    let results = try reader(path).read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
                    guard results == ["ok"] else { throw structureError }
                }
            } catch {
                // 解码器、数据库以及 App 校验可能在错误里包含私有字段，不向界面转发。
                throw UserDataArchiveError.damaged(item: item.rawValue, reason: String(localized: "数据内容或版本无效。", bundle: .main))
            }
        }
    }

    /// 内容或版本无效时返回 false。读取失败或缺少 App 校验函数时抛错。
    static func isValidJSON(_ item: UserDataItem, at path: URL, appValidators: UserDataValidators) throws -> Bool {
        let validate: (Data) throws -> Void
        switch item {
        case .settings, .pathRules, .profiles:
            validate = { try FileSettingsStore.validateDocument(item.rawValue, data: $0) }
        case .keyBindings:
            validate = { try JSONDocumentStore<KeyBindingsFile>.validate($0, version: KeyBindingsFile.documentVersion) }
        case .menus:
            validate = { try JSONDocumentStore<MenuFile>.validate($0, version: MenuFile.documentVersion) }
        case .externalCommands:
            validate = { try JSONDocumentStore<ExternalCommandFile>.validate($0, version: ExternalCommandFile.documentVersion) }
        case .scriptStorage:
            validate = { try JSONDocumentStore<ScriptStorage.DocumentValue>.validate($0, version: ScriptStorage.documentVersion) }
        case .plugins:
            validate = { try JSONDocumentStore<PluginSettingsFile>.validate($0, version: PluginSettingsFile.documentVersion) }
        case .pluginSecrets:
            // 来源密码使用无版本外壳的独立存储。它在读取时会把暂存的副本设为 0600。
            do {
                _ = try PluginSecrets(fileURL: path)
                return true
            } catch is DecodingError {
                return false
            }
        case .layout, .layoutSchemes, .session:
            guard let appValidator = appValidators[item] else { throw structureError }
            validate = appValidator
        case .bookMemory, .library, .scripts, .pluginFiles:
            preconditionFailure("Expected a JSON document")
        }
        let data = try Data(contentsOf: path)
        return (try? validate(data)) != nil
    }
}
