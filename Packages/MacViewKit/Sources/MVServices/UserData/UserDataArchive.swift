import Darwin
import Foundation
import GRDB
import MVLibraryData

public enum UserDataArchive {
    public static let formatVersion = 1
    public static let fileExtension = "macviewdata"

    // 导入、导出和 token 检查共用一条队列。阻塞的文件 I/O 与子进程均在队列上运行。
    static let queue = DispatchQueue(label: "MacView.UserDataArchive", qos: .userInitiated)
    static var files: FileManager { .default }

    public static func backupURL(for locations: UserDataLocations) -> URL {
        locations.supportDirectory.appending(path: "Backups/before-import.macviewdata")
    }

    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    public static func export(from locations: UserDataLocations, origin: UserDataOrigin, to destination: URL) async throws -> UserDataManifest {
        try await perform { try writeArchive(from: locations, origin: origin, to: destination) }
    }

    static func writeArchive(from locations: UserDataLocations, origin: UserDataOrigin, to destination: URL) throws -> UserDataManifest {
        // 目标同卷的私有替换目录也适用于网络卷；明文归档与解包中的文件仅当前用户可见。
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        do {
            let caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            let comparison: String.CompareOptions = caseSensitive == false ? [.caseInsensitive] : []
            let insidePayload = [UserDataItem.scripts, .pluginFiles].contains { item in
                let path = item.url(in: locations).resolvingSymlinksInPath().standardizedFileURL.path
                return parent.path.compare(path, options: comparison) == .orderedSame
                    || parent.path.range(of: path + "/", options: comparison.union(.anchored)) != nil
            }
            // 无论载荷目录是否为独立挂载点，发布和快照都与目标同卷；
            // 目标位于载荷内时，复制委托会在进入这个目录前将它排除。
            let temporary = parent.appending(path: ".macview-export-\(UUID())")
            try makePrivateDirectory(temporary)
            defer { try? files.removeItem(at: temporary) }
            let contents = temporary.appending(path: "contents")
            let payload = contents.appending(path: "data")
            try files.createDirectory(at: payload, withIntermediateDirectories: true)
            var items: [UserDataItem] = []
            for item in UserDataItem.allCases {
                let source = item.url(in: locations), target = payload.appending(path: item.rawValue)
                guard let type = try type(of: source) else { continue }
                guard type == (item.kind == .directory ? S_IFDIR : S_IFREG) else { throw CocoaError(.fileReadCorruptFile) }
                if item.kind == .sqlite {
                    let db = try reader(source)
                    try db.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [target.path]) }
                } else if insidePayload, item.kind == .directory {
                    // 同名覆盖时跳过这次的输出和私有快照。其余归档作为用户文件保留。
                    let output = parent.appending(path: destination.lastPathComponent)
                    let filter = ExportCopyFilter(excluding: [temporary, output], options: comparison)
                    let copier = FileManager()
                    copier.delegate = filter
                    try withExtendedLifetime(filter) { try copier.copyItem(at: source, to: target) }
                } else {
                    try files.copyItem(at: source, to: target)
                }
                items.append(item)
            }
            let summary = try countItems(items, in: payload)
            let manifest = UserDataManifest(format: formatVersion, appVersion: origin.appVersion, appBuild: origin.appBuild,
                createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), host: origin.host,
                summary: summary, items: items)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: contents.appending(path: "manifest.json"))
            let zip = temporary.appending(path: "archive.zip")
            try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", contents.path, zip.path])
            guard chmod(zip.path, 0o600) == 0, rename(zip.path, destination.path) == 0 else { throw posixError() }
            return manifest
        } catch {
            let reason = (error as? CocoaError)?.localizedDescription ?? (error as? POSIXError)?.localizedDescription
            throw UserDataArchiveError.writeFailed(reason: reason ?? String(localized: "无法读取数据或写入归档。", bundle: .main))
        }
    }

    private static func countItems(_ items: [UserDataItem], in data: URL) throws -> UserDataSummary {
        var summary = UserDataSummary()
        if items.contains(.library) {
            let counts = try SQLiteLibraryStore.summary(databaseURL: data.appending(path: UserDataItem.library.rawValue))
            summary.history = counts.history
            summary.bookmarks = counts.bookmarks
            summary.playlists = counts.playlists
        }
        if items.contains(.scripts) {
            let scripts = try files.contentsOfDirectory(at: data.appending(path: UserDataItem.scripts.rawValue), includingPropertiesForKeys: nil)
            summary.scripts = try scripts.filter { url in
                guard url.pathExtension == "js" else { return false }
                return try type(of: url) == S_IFREG
            }.count
        }
        if items.contains(.pluginFiles) {
            let plugins = try files.contentsOfDirectory(at: data.appending(path: UserDataItem.pluginFiles.rawValue), includingPropertiesForKeys: nil)
            summary.plugins = try plugins.filter { url in
                try type(of: url) == S_IFDIR && type(of: url.appending(path: "manifest.json")) == S_IFREG
            }.count
        }
        return summary
    }

    static func reader(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// lstat 不会跟随符号链接，权限错误也不能被误认为不存在。
    static func type(of url: URL) throws -> mode_t? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    static func removeIfPresent(_ url: URL) throws {
        if try type(of: url) != nil { try files.removeItem(at: url) }
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    @discardableResult static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8" // bsdtar 在 C locale 下会将中文显示成八进制转义。
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

private final class ExportCopyFilter: NSObject, FileManagerDelegate {
    private let excludedPaths: [String]
    private let options: String.CompareOptions

    init(excluding urls: [URL], options: String.CompareOptions) {
        excludedPaths = urls.map(\.path)
        self.options = options
    }

    func fileManager(_ fileManager: FileManager, shouldCopyItemAt source: URL, to destination: URL) -> Bool {
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let path = parent.appending(path: source.lastPathComponent).path
        return !excludedPaths.contains { path.compare($0, options: options) == .orderedSame }
    }
}
