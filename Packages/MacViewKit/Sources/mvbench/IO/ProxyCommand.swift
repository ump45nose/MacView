import ArgumentParser
import Darwin
import Foundation
import NetFS

/// `mvbench io proxy`：经本机代理另挂一份测试挂载，接受控制命令，退出时卸载。
struct ProxyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxy",
        abstract: "经本机 TCP 代理把源路径所在的 SMB 或 NFS 共享另挂到 --mount-at，供故障测试使用。",
        discussion: """
            挂好后在标准输出打印一行 JSON：挂载点、源路径在测试挂载里的对应路径、控制端口。
            控制端口接受一行命令 pause、drop、forward 或 status，回一行 JSON 状态。
            收到 SIGINT 或 SIGTERM 时恢复转发、卸载、停止代理后退出。原有挂载不受影响。
            SMB 需要凭据：先读钥匙串里 Finder 保存的项（系统会弹窗请用户允许），读不到时在终端提示输入。
            """
    )

    @Option(help: "现有 SMB 或 NFS 挂载下的路径，用来确定服务器和共享。")
    var source: String

    @Option(help: "测试挂载点，必须是空目录或不存在。")
    var mountAt: String

    @Option(help: "控制端口；0 表示由系统分配。")
    var controlPort: UInt16 = 0

    @Flag(help: "软挂载：服务器无响应时调用超时返回错误。")
    var soft = false

    @Option(help: "NFS：追加的挂载选项，逗号分隔。")
    var nfsOptions: String?

    func run() throws {
        let mount = try MountInfo.of(source)
        let relative = try mount.relativePath(of: source)
        let mountPoint = URL(fileURLWithPath: mountAt).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        let proxy: FaultProxy
        switch mount.fileSystem {
        case "smbfs":
            guard let share = SMBShare.parse(source: mount.source) else {
                throw ValidationFailure("无法解析 SMB 挂载来源")
            }
            let credentials = try SMBCredentials.obtain(server: share.server, user: share.user)
            proxy = try FaultProxy(targets: [.init(host: share.server, port: 445)])
            try Self.mountSMB(share: share.share, port: proxy.ports[0], at: mountPoint, credentials: credentials, soft: soft)
        case "nfs":
            guard let export = NFSExport.parse(source: mount.source) else {
                throw ValidationFailure("无法解析 NFS 挂载来源 \(mount.source)")
            }
            let mountd = try Self.mountdPort(of: export.server)
            proxy = try FaultProxy(targets: [.init(host: export.server, port: 2049), .init(host: export.server, port: mountd)])
            var options = ["vers=3", "tcp", "port=\(proxy.ports[0])", "mountport=\(proxy.ports[1])", "nolocks"]
            if soft { options += ["soft", "intr"] }
            if let nfsOptions { options.append(nfsOptions) }
            try runTool("/sbin/mount_nfs", ["-o", options.joined(separator: ","), "127.0.0.1:" + export.path, mountPoint])
        default:
            throw ValidationFailure("\(source) 所在的卷是 \(mount.fileSystem)，只支持 smbfs 和 nfs")
        }
        let (control, port) = try FaultProxy.listen(port: controlPort)
        let ready = ProxyReady(
            fileSystem: mount.fileSystem,
            mountPoint: mountPoint,
            path: relative.isEmpty ? mountPoint : mountPoint + "/" + relative,
            controlPort: port,
            proxyPorts: proxy.ports,
            soft: soft
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(ready) + Data("\n".utf8))
        Thread { Self.serveControl(control, proxy: proxy) }.start()

        Self.waitForTermination()
        proxy.set(.forward)
        Self.unmountWithRetries(mountPoint)
        proxy.stop()
        rmdir(mountPoint)
        progress("已卸载 \(mountPoint)，代理已停止")
    }

    private static func mountSMB(share: String, port: UInt16, at mountPoint: String, credentials: SMBCredentials, soft: Bool) throws {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/" + share
        guard let url = components.url else { throw ValidationFailure("无法构造 SMB URL") }
        // NetFS 的选项键是 CFSTR 宏，Swift 无法导入，这里直接写字符串值。
        // ForceNewSession：不与同一服务器上已有的会话共用连接，保证流量经过这个代理。
        let openOptions: NSMutableDictionary = ["UIOption": "NoUI", "ForceNewSession": true]
        let mountOptions: NSMutableDictionary = ["MountAtMountDir": true, "SoftMount": soft]
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL,
            URL(fileURLWithPath: mountPoint) as CFURL,
            credentials.user as CFString,
            credentials.password as CFString,
            openOptions,
            mountOptions,
            &mountpoints
        )
        mountpoints?.release()
        guard status == 0 else {
            let reason = status > 0 ? String(cString: strerror(status)) : "NetFS 错误 \(status)"
            throw ValidationFailure("挂载 \(url.absoluteString) 失败：\(reason)")
        }
    }

    /// 从 rpcinfo 的输出里找 mountd v3 的 TCP 端口。
    private static func mountdPort(of server: String) throws -> UInt16 {
        let output = try runTool("/usr/sbin/rpcinfo", ["-p", server])
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count >= 5, fields[0] == "100005", fields[1] == "3", fields[2] == "tcp", let port = UInt16(fields[3]) {
                return port
            }
        }
        throw ValidationFailure("\(server) 的 rpcinfo 里没有 mountd v3 TCP 端口")
    }

    private static func serveControl(_ listener: Int32, proxy: FaultProxy) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            defer { close(client) }
            guard let command = ProxyControl.readLine(from: client) else { continue }
            switch command {
            case "pause": proxy.set(.pause)
            case "drop": proxy.set(.drop)
            case "forward": proxy.set(.forward)
            default: break
            }
            progress("代理：\(command)")
            if let reply = try? encoder.encode(proxy.status) {
                ProxyControl.write(reply + Data("\n".utf8), to: client)
            }
        }
    }

    private static func waitForTermination() {
        let semaphore = DispatchSemaphore(value: 0)
        let sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { semaphore.signal() }
            source.resume()
            return source
        }
        semaphore.wait()
        withExtendedLifetime(sources) {}
    }

    private static func unmountWithRetries(_ mountPoint: String) {
        for attempt in 1...5 {
            if unmount(mountPoint, 0) == 0 { return }
            progress("卸载 \(mountPoint) 失败（第 \(attempt) 次）：\(String(cString: strerror(errno)))")
            sleep(1)
        }
        if unmount(mountPoint, MNT_FORCE) != 0 {
            progress("强制卸载 \(mountPoint) 失败：\(String(cString: strerror(errno)))")
        }
    }
}

/// proxy 挂好后打印的信息。
struct ProxyReady: Codable {
    var fileSystem: String
    var mountPoint: String
    /// 源路径在测试挂载里的对应路径。
    var path: String
    var controlPort: UInt16
    var proxyPorts: [UInt16]
    var soft: Bool
}

/// proxy 控制端口的客户端与行协议。
enum ProxyControl {
    @discardableResult
    static func send(_ command: String, port: UInt16) throws -> FaultProxy.Status {
        guard let fd = FaultProxy.connect(to: .init(host: "127.0.0.1", port: port)) else {
            throw ValidationFailure("连不上代理的控制端口 \(port)")
        }
        defer { close(fd) }
        write(Data((command + "\n").utf8), to: fd)
        guard let reply = readLine(from: fd) else { throw ValidationFailure("代理没有回复 \(command)") }
        return try JSONDecoder().decode(FaultProxy.Status.self, from: Data(reply.utf8))
    }

    static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                sent += written
            }
        }
    }

    /// 读一行，不含换行符。
    static func readLine(from fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 4096 {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}

/// 运行一个命令行工具并返回标准输出；退出码非 0 时把标准错误作为错误抛出。
@discardableResult
func runTool(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ValidationFailure("\((path as NSString).lastPathComponent) 退出码 \(process.terminationStatus)：\(detail)")
    }
    return String(decoding: data, as: UTF8.self)
}
