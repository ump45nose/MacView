import Foundation

public struct UserDataLocations: Sendable, Equatable {
    public var supportDirectory: URL
    public var layoutFile: URL

    public init(supportDirectory: URL, layoutFile: URL) {
        self.supportDirectory = supportDirectory
        self.layoutFile = layoutFile
    }

    var staging: URL { supportDirectory.appending(path: ".import-staging") }
    var rollback: URL { supportDirectory.appending(path: ".import-rollback") }
}

public enum UserDataItem: String, CaseIterable, Codable, Sendable {
    case settings = "settings.json", keyBindings = "keybindings.json", menus = "menus.json"
    case pathRules = "path-rules.json", profiles = "profiles.json", layout = "layout.json"
    case layoutSchemes = "layout-schemes.json", session = "session.json"
    case externalCommands = "external-commands.json", scriptStorage = "script-storage.json"
    case plugins = "plugins.json", pluginSecrets = "plugin-secrets.json"
    case bookMemory = "state.sqlite", library = "library.sqlite"
    case scripts = "Scripts", pluginFiles = "Plugins"

    public enum Kind: Sendable { case json, sqlite, directory }

    public var kind: Kind {
        switch self {
        case .bookMemory, .library: .sqlite
        case .scripts, .pluginFiles: .directory
        default: .json
        }
    }

    public func url(in locations: UserDataLocations) -> URL {
        self == .layout ? locations.layoutFile : locations.supportDirectory.appending(path: rawValue)
    }
}

public struct UserDataSummary: Codable, Sendable, Equatable {
    public var history, bookmarks, playlists, scripts, plugins: Int

    public init(history: Int = 0, bookmarks: Int = 0, playlists: Int = 0, scripts: Int = 0, plugins: Int = 0) {
        self.history = history
        self.bookmarks = bookmarks
        self.playlists = playlists
        self.scripts = scripts
        self.plugins = plugins
    }
}

public struct UserDataOrigin: Sendable, Equatable {
    public var appVersion, appBuild, host: String

    public init(appVersion: String, appBuild: String, host: String) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.host = host
    }
}

public struct UserDataManifest: Codable, Sendable, Equatable {
    public var format: Int
    public var appVersion, appBuild: String
    public var createdAt: Date
    public var host: String
    public var summary: UserDataSummary
    public var items: [UserDataItem]
}

public enum UserDataImportOutcome: Sendable, Equatable {
    case imported(UserDataManifest, backup: URL)
    case rolledBack(reason: String)
    case recoveryFailed(reason: String)
}

public struct StagedImport: Sendable, Equatable {
    public var manifest: UserDataManifest
    public var token: UUID
}

public typealias UserDataValidators = [UserDataItem: @Sendable (Data) throws -> Void]

public enum UserDataArchiveError: Error, LocalizedError, Equatable {
    case notAnArchive
    case newerFormat(Int)
    case damaged(item: String?, reason: String)
    case writeFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: return String(localized: "这不是 MacView 导出的用户数据文件。", bundle: .main)
        case let .newerFormat(format): return String(localized: "此文件来自更新版本的 MacView（数据格式 \(format)）。", bundle: .main)
        case let .damaged(item?, reason): return String(localized: "用户数据文件损坏（\(item)）：\(reason)", bundle: .main)
        case let .damaged(nil, reason): return String(localized: "用户数据文件损坏：\(reason)", bundle: .main)
        case let .writeFailed(reason): return String(localized: "无法导出用户数据：\(reason)", bundle: .main)
        }
    }
}
