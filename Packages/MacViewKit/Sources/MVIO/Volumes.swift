import Darwin
import Foundation
import MVFoundation
import Synchronization

/// 一个挂载的卷。I/O 调度以卷为单位。
struct Volume: Sendable, Hashable {
    var mountPoint: String
    var fileSystem: String
    /// 卷在 Location 中的根。本机卷都是 `.local`，路径从 `/` 开始。
    var root: Location.Root
    /// statfs 带 `MNT_LOCAL`。不带的是网络卷，阻塞调用放进辅助进程。
    var isLocal: Bool

    /// 卷内路径在 Location 第一层中的分量。
    func components(ofPath path: String) -> [String] {
        let relative = root == .local ? path : String(path.dropFirst(mountPoint.count))
        return relative.split(separator: "/").map(String.init)
    }

    func path(of components: [String]) -> String {
        let base = root == .local ? "" : (mountPoint == "/" ? "" : mountPoint)
        return components.isEmpty && !base.isEmpty ? base : base + "/" + components.joined(separator: "/")
    }
}

/// 当前的挂载表。用 getfsstat(MNT_NOWAIT) 读取：只读内核里的挂载记录，网络卷卡住时也不会阻塞。
final class VolumeTable: Sendable {
    private struct Snapshot {
        var volumes: [Volume] = []
        var loadedAt: ContinuousClock.Instant?
    }

    private let snapshot = Mutex(Snapshot())
    private let maximumAge: Duration

    init(maximumAge: Duration = .seconds(1)) {
        self.maximumAge = maximumAge
    }

    var volumes: [Volume] {
        current(refresh: false)
    }

    /// 路径所在的卷：挂载点是路径前缀中最长的那个。
    func volume(containing path: String) -> Volume? {
        func match(_ volumes: [Volume]) -> Volume? {
            volumes.filter { $0.mountPoint == "/" || path == $0.mountPoint || path.hasPrefix($0.mountPoint + "/") }
                .max { $0.mountPoint.count < $1.mountPoint.count }
        }
        return match(current(refresh: false))
    }

    /// 根对应的挂载；本机根还要按路径找具体的卷。找不到时刷新一次挂载表再找。
    func volume(for location: Location) -> Volume? {
        func find(_ volumes: [Volume]) -> Volume? {
            switch location.root {
            case .local:
                let path = "/" + (location.layers.first ?? []).joined(separator: "/")
                return volumes.filter { $0.root == .local && ($0.mountPoint == "/" || path == $0.mountPoint || path.hasPrefix($0.mountPoint + "/")) }
                    .max { $0.mountPoint.count < $1.mountPoint.count }
            case .network:
                return volumes.first { $0.root == location.root }
            case .plugin:
                return nil
            }
        }
        return find(current(refresh: false)) ?? find(current(refresh: true))
    }

    private func current(refresh: Bool) -> [Volume] {
        let now = ContinuousClock.now
        if !refresh, let cached = snapshot.withLock({ snapshot -> [Volume]? in
            guard let loadedAt = snapshot.loadedAt, now - loadedAt < maximumAge else { return nil }
            return snapshot.volumes
        }) {
            return cached
        }
        let volumes = Self.load()
        snapshot.withLock { $0 = Snapshot(volumes: volumes, loadedAt: now) }
        return volumes
    }

    static func load() -> [Volume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array(repeating: Darwin.statfs(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map(volume)
    }

    static func volume(_ info: Darwin.statfs) -> Volume {
        var info = info
        let mountPoint = cString(&info.f_mntonname)
        let fileSystem = cString(&info.f_fstypename)
        let source = cString(&info.f_mntfromname)
        let isLocal = info.f_flags & UInt32(MNT_LOCAL) != 0
        return Volume(mountPoint: mountPoint, fileSystem: fileSystem, root: root(fileSystem: fileSystem, source: source) ?? .local, isLocal: isLocal)
    }

    /// 由挂载来源得到网络根，与挂载点的名称无关，`/Volumes/Picture-1` 这类重名挂载也归到同一个根。
    /// - smbfs：`//[domain;][user@]server/share` → `network(smb, server, share)`。
    /// - nfs：`server:/export/path` → `network(nfs, server, export/path)`。
    static func root(fileSystem: String, source: String) -> Location.Root? {
        switch fileSystem {
        case "smbfs":
            guard source.hasPrefix("//") else { return nil }
            let rest = source.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var server = rest[..<slash]
            if let at = server.lastIndex(of: "@") { server = server[server.index(after: at)...] }
            let share = String(rest[rest.index(after: slash)...])
            guard !server.isEmpty, !share.isEmpty else { return nil }
            return .network(scheme: "smb", host: String(server).lowercased(), share: share.removingPercentEncoding ?? share)
        case "nfs":
            guard let colon = source.firstIndex(of: ":") else { return nil }
            let path = source[source.index(after: colon)...].drop { $0 == "/" }
            guard colon != source.startIndex, !path.isEmpty else { return nil }
            return .network(scheme: "nfs", host: String(source[..<colon]).lowercased(), share: String(path))
        default:
            return nil
        }
    }
}

extension Location.Root {
    /// 让系统挂载这个根的 URL，供界面的“连接”按钮交给 NSWorkspace 打开。
    public var mountURL: URL? {
        guard case let .network(scheme, host, share) = self else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + share
        return components.url
    }
}

private func cString<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}
