import Darwin
import Foundation

/// 路径所在的挂载。
struct MountInfo: Sendable, Equatable {
    var mountPoint: String
    var fileSystem: String
    /// 挂载来源，例如 `//user@192.168.31.201/Picture`、`192.168.31.201:/fs/1000/nfs`。
    var source: String

    static func of(_ path: String) throws(SystemCallError) -> MountInfo {
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw .last("statfs") }
        return MountInfo(
            mountPoint: cString(of: &info.f_mntonname),
            fileSystem: cString(of: &info.f_fstypename),
            source: cString(of: &info.f_mntfromname)
        )
    }

    /// 网络卷的服务器地址；本地卷为 nil。
    var host: String? {
        switch fileSystem {
        case "smbfs": SMBShare.parse(source: source)?.server
        case "nfs": NFSExport.parse(source: source)?.server
        default: nil
        }
    }

    /// 路径相对挂载点的部分，用 `/` 分隔，挂载点本身为空串。
    func relativePath(of path: String) throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved == mountPoint || resolved.hasPrefix(mountPoint + "/") else {
            throw ValidationFailure("\(path) 不在挂载点 \(mountPoint) 下")
        }
        return String(resolved.dropFirst(mountPoint.count).drop { $0 == "/" })
    }
}

/// smbfs 的挂载来源 `//[domain;][user@]server/share`。
struct SMBShare: Sendable, Equatable {
    var server: String
    var share: String
    var user: String?

    static func parse(source: String) -> SMBShare? {
        guard source.hasPrefix("//") else { return nil }
        let rest = source.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = rest[..<slash]
        let share = String(rest[rest.index(after: slash)...])
        guard !share.isEmpty else { return nil }
        var user: String?
        var server = Substring(authority)
        if let at = authority.lastIndex(of: "@") {
            user = String(authority[..<at]).removingPercentEncoding
            server = authority[authority.index(after: at)...]
        }
        return SMBShare(server: String(server), share: share.removingPercentEncoding ?? share, user: user)
    }
}

/// NFS 的挂载来源 `server:/export`。
struct NFSExport: Sendable, Equatable {
    var server: String
    var path: String

    static func parse(source: String) -> NFSExport? {
        guard let colon = source.firstIndex(of: ":") else { return nil }
        let path = source[source.index(after: colon)...]
        guard path.hasPrefix("/") else { return nil }
        return NFSExport(server: String(source[..<colon]), path: String(path))
    }
}

/// 参数或环境不满足测量条件。
struct ValidationFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
