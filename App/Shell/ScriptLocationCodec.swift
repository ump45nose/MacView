import Darwin
import Foundation
import MVFoundation
import MVIO

/// 位置标记与 `Location` 互转：
/// - 本机与已挂载网络卷上的普通文件（单层、非插件根）返回 POSIX 路径；
/// - 其余（压缩包内、嵌套压缩包、虚拟书、未挂载网络卷等）返回 `"mvloc:" + base64url(Location 的 JSON，sortedKeys)`；
/// - `path(for:)` 给出磁盘上真实存在的文件路径，压缩包内等非磁盘直达项返回 `nil`。
enum ScriptLocationCodec {
    static let tokenPrefix = "mvloc:"

    static func token(for location: Location) -> String {
        if let posix = path(for: location) {
            return posix
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(location) {
            return tokenPrefix + encodeBase64URL(data)
        }
        return location.description
    }

    static func path(for location: Location) -> String? {
        guard location.layers.count == 1, let components = location.layers.first else {
            return nil
        }
        switch location.root {
        case .local:
            return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        case .network:
            guard let mount = mountPoint(for: location.root) else { return nil }
            let base = mount == "/" ? "" : mount
            return components.isEmpty && !base.isEmpty ? base : base + "/" + components.joined(separator: "/")
        case .plugin:
            return nil
        }
    }

    static func location(from token: String, sources: any SourceRegistry) async throws -> Location {
        guard !token.isEmpty else {
            throw ScriptHostError.invalidLocation(String(localized: "位置不能为空"))
        }
        if token.hasPrefix(tokenPrefix) {
            let payload = String(token.dropFirst(tokenPrefix.count))
            guard let data = decodeBase64URL(payload) else {
                throw ScriptHostError.invalidLocation(String(localized: "无效的位置标记"))
            }
            let decoded: Location
            do {
                decoded = try JSONDecoder().decode(Location.self, from: data)
            } catch {
                throw ScriptHostError.invalidLocation(String(localized: "无法解析位置标记"))
            }
            guard !decoded.layers.isEmpty else {
                throw ScriptHostError.invalidLocation(String(localized: "无效的位置标记"))
            }
            return decoded
        }

        let expanded = (token as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ScriptHostError.invalidLocation(String(localized: "无效的路径：\(token)"))
        }
        let url = URL(fileURLWithPath: expanded)
        do {
            return try await sources.location(for: url)
        } catch {
            throw ScriptHostError.invalidLocation(ErrorText.describe(error))
        }
    }

    // MARK: - Base64URL

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        guard !string.isEmpty else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 2: base64.append("==")
        case 3: base64.append("=")
        default: return nil
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - 网络卷挂载点

    private static func mountPoint(for root: Location.Root) -> String? {
        guard case .network = root else { return nil }
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        var buffer = Array(repeating: Darwin.statfs(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return nil }
        for entry in buffer.prefix(Int(filled)) {
            var info = entry
            let fileSystem = withUnsafeBytes(of: &info.f_fstypename) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            let source = withUnsafeBytes(of: &info.f_mntfromname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if networkRoot(fileSystem: fileSystem, source: source) == root {
                return withUnsafeBytes(of: &info.f_mntonname) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
            }
        }
        return nil
    }

    /// 与 `MVIO/Volumes.swift` 保持一致的网络根解析规则。
    private static func networkRoot(fileSystem: String, source: String) -> Location.Root? {
        switch fileSystem {
        case "smbfs":
            guard source.hasPrefix("//") else { return nil }
            let rest = source.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var server = rest[..<slash]
            if let at = server.lastIndex(of: "@") {
                server = server[server.index(after: at)...]
            }
            let share = String(rest[rest.index(after: slash)...])
            guard !server.isEmpty, !share.isEmpty else { return nil }
            return .network(scheme: "smb", host: String(server).lowercased(), share: share.removingPercentEncoding ?? share)
        case "nfs":
            guard let colon = source.firstIndex(of: ":") else { return nil }
            let host = String(source[..<colon]).lowercased()
            let path = String(source[source.index(after: colon)...].drop { $0 == "/" })
            guard !host.isEmpty else { return nil }
            return .network(scheme: "nfs", host: host, share: path)
        default:
            return nil
        }
    }
}
