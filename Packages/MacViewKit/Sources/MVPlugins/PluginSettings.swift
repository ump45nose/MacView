import Darwin
import Foundation
import Synchronization

public struct PluginState: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var grantedPermissions: [PluginPermission]

    public init(enabled: Bool = false, grantedPermissions: [PluginPermission] = []) {
        self.enabled = enabled
        self.grantedPermissions = grantedPermissions
    }
}

public struct SourceInstance: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var plugin: String
    public var type: String
    public var name: String
    /// 非密码字段的值；密码字段单独保存在 `PluginSecrets`。
    public var values: [String: String]

    public init(id: UUID = UUID(), plugin: String, type: String, name: String, values: [String: String] = [:]) {
        self.id = id
        self.plugin = plugin
        self.type = type
        self.name = name
        self.values = values
    }

    /// 按清单把字段值拆为可进 `plugins.json` 的普通字段与须进 `plugin-secrets.json` 的密码字段。
    public static func partitionValues(
        _ allValues: [String: String],
        declaration: PluginSourceDeclaration?
    ) -> (publicValues: [String: String], secretValues: [String: String]) {
        guard let declaration else { return (allValues, [:]) }
        let secretKeys = declaration.passwordFieldKeys
        var pub: [String: String] = [:]
        var sec: [String: String] = [:]
        for (key, value) in allValues {
            if secretKeys.contains(key) {
                sec[key] = value
            } else {
                pub[key] = value
            }
        }
        return (pub, sec)
    }
}

public struct PluginSettingsFile: Codable, Sendable, Hashable {
    public var plugins: [String: PluginState]
    public var sources: [SourceInstance]

    public init(plugins: [String: PluginState] = [:], sources: [SourceInstance] = []) {
        self.plugins = plugins
        self.sources = sources
    }
}

public enum PluginStatus: Sendable, Hashable {
    case disabled
    case needsConsent
    case ready
    case running(since: Date)
    case failed(String)
    case invalid(PluginProblem)

    public static func evaluate(
        info: PluginInfo,
        state: PluginState?,
        runningSince: Date? = nil,
        failure: String? = nil
    ) -> PluginStatus {
        if let problem = info.problem {
            return .invalid(problem)
        }
        guard let manifest = info.manifest else {
            return .invalid(PluginProblem(file: "manifest.json", message: "清单不可用"))
        }
        guard let state, state.enabled else {
            return .disabled
        }
        if !Set(manifest.permissions).isSubset(of: Set(state.grantedPermissions)) {
            return .needsConsent
        }
        if let runningSince {
            return .running(since: runningSince)
        }
        if let failure {
            return .failed(failure)
        }
        return .ready
    }
}

/// 单独存放来源密码字段的 0600 权限文件。
public final class PluginSecrets: Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "MacView.PluginSecrets")
    private let state: Mutex<[UUID: [String: String]]>

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [UUID: [String: String]] = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Self.ensurePrivatePermissions(at: fileURL)
            let data = try Data(contentsOf: fileURL)
            let raw = try JSONDecoder().decode([String: [String: String]].self, from: data)
            for (key, value) in raw {
                if let uuid = UUID(uuidString: key) {
                    loaded[uuid] = value
                }
            }
        }
        self.state = Mutex(loaded)
    }

    public func values(for source: UUID) -> [String: String] {
        state.withLock { $0[source] ?? [:] }
    }

    public func set(_ values: [String: String], for source: UUID) async throws {
        try queue.sync {
            var next = state.withLock { $0 }
            if values.isEmpty {
                next.removeValue(forKey: source)
            } else {
                next[source] = values
            }
            try writeAtomicPrivate(next)
            state.withLock { $0 = next }
        }
    }

    public func remove(source: UUID) async throws {
        try queue.sync {
            var next = state.withLock { $0 }
            let removed = next.removeValue(forKey: source) != nil
            if removed || FileManager.default.fileExists(atPath: fileURL.path) {
                try writeAtomicPrivate(next)
            }
            state.withLock { $0 = next }
        }
    }

    private func writeAtomicPrivate(_ map: [UUID: [String: String]]) throws {
        let stringKeyed = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stringKeyed)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer {
            if !closed { close(fd) }
        }
        if fchmod(fd, 0o600) != 0 {
            let code = errno
            close(fd); closed = true
            unlink(tempURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let n = write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += n
                }
            }
            if fsync(fd) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(fd); closed = true
            if rename(tempURL.path, fileURL.path) != 0 {
                let code = errno
                unlink(tempURL.path)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try Self.ensurePrivatePermissions(at: fileURL)
        } catch {
            if !closed { close(fd); closed = true }
            unlink(tempURL.path)
            throw error
        }
    }

    private static func ensurePrivatePermissions(at url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if (st.st_mode & 0o777) != 0o600 {
            guard chmod(url.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
