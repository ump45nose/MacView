import CoreWLAN
import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// 一次基准测试的运行环境，随结果一起写入 JSON。
struct BenchEnvironment: Codable, Sendable {
    struct Machine: Codable, Sendable {
        var model: String?
        var chip: String?
        var memoryBytes: UInt64?
        var performanceCores: Int?
        var efficiencyCores: Int?
    }

    struct System: Codable, Sendable {
        var version: String
        var build: String?
    }

    struct NetworkInterface: Codable, Sendable {
        var name: String
        var type: String?
        /// 有线接口取协商速率，Wi-Fi 取当前发送速率。
        var linkSpeedMbps: Double?
        var wifiPHYMode: String?
    }

    struct Route: Codable, Sendable {
        var host: String
        var interface: String?
        var error: String?
    }

    struct Volume: Codable, Sendable {
        var path: String
        var mountPoint: String?
        var fileSystem: String?
        var source: String?
        var error: String?
    }

    var collectedAt: Date
    var machine: Machine
    var system: System
    var network: [NetworkInterface]
    var route: Route?
    var volumes: [Volume]

    /// 卡住的 NAS 挂载会让 statfs 一直阻塞，超过这个时间就记为错误。
    static let volumeProbeTimeout: Double = 5

    static func collect(paths: [String], host: String?) -> BenchEnvironment {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return BenchEnvironment(
            collectedAt: Date(),
            machine: Machine(
                model: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"),
                memoryBytes: sysctlInteger("hw.memsize", as: UInt64.self),
                performanceCores: sysctlInteger("hw.perflevel0.physicalcpu", as: Int32.self).map { Int($0) },
                efficiencyCores: sysctlInteger("hw.perflevel1.physicalcpu", as: Int32.self).map { Int($0) }
            ),
            system: System(
                version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                build: sysctlString("kern.osversion")
            ),
            network: networkInterfaces(),
            route: host.map(findRoute(to:)),
            volumes: paths.map(volume(at:))
        )
    }

    /// 去掉挂载来源里的用户名，例如 `//user@host/share` → `//host/share`。
    static func redactingUser(_ source: String) -> String {
        guard source.hasPrefix("//") else { return source }
        let rest = source.dropFirst(2)
        guard let at = rest.firstIndex(of: "@") else { return source }
        if let slash = rest.firstIndex(of: "/"), slash < at { return source }
        return "//" + rest[rest.index(after: at)...]
    }
}

// MARK: - 机型与系统

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

private func sysctlInteger<T: FixedWidthInteger>(_ name: String, as _: T.Type) -> T? {
    var value: T = 0
    var size = MemoryLayout<T>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

// MARK: - 网络

/// 列出已启用、有 IPv4 地址的非回环接口。不记录地址本身。
private func networkInterfaces() -> [BenchEnvironment.NetworkInterface] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var active: Set<String> = []
    var baudRates: [String: UInt32] = [:]
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let entry = pointer.pointee
        let flags = Int32(entry.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr else { continue }
        let name = String(cString: entry.ifa_name)
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            active.insert(name)
        case AF_LINK:
            if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                baudRates[name] = data.pointee.ifi_baudrate
            }
        default:
            break
        }
    }

    let types = interfaceTypes()
    return active.sorted().map { name in
        if let wifi = wifiStatus(for: name) {
            return BenchEnvironment.NetworkInterface(name: name, type: types[name], linkSpeedMbps: wifi.transmitRate, wifiPHYMode: wifi.phyMode)
        }
        let baud = baudRates[name] ?? 0
        return BenchEnvironment.NetworkInterface(name: name, type: types[name], linkSpeedMbps: baud > 0 ? Double(baud) / 1_000_000 : nil)
    }
}

/// BSD 名到 SystemConfiguration 接口类型（如 Ethernet、IEEE80211）的映射。
private func interfaceTypes() -> [String: String] {
    var types: [String: String] = [:]
    for interface in SCNetworkInterfaceCopyAll() as! [SCNetworkInterface] {
        if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
           let type = SCNetworkInterfaceGetInterfaceType(interface) as String? {
            types[name] = type
        }
    }
    return types
}

private func wifiStatus(for name: String) -> (transmitRate: Double, phyMode: String)? {
    guard let interface = CWWiFiClient.shared().interface(withName: name), interface.powerOn() else { return nil }
    let mode: String
    switch interface.activePHYMode() {
    case .modeNone: return nil
    case .mode11a: mode = "802.11a"
    case .mode11b: mode = "802.11b"
    case .mode11g: mode = "802.11g"
    case .mode11n: mode = "802.11n"
    case .mode11ac: mode = "802.11ac"
    case .mode11ax: mode = "802.11ax"
    case .mode11be: mode = "802.11be"
    @unknown default: mode = "unknown(\(interface.activePHYMode().rawValue))"
    }
    return (interface.transmitRate(), mode)
}

/// 用 `route -n get` 找出访问指定主机走哪个接口。
private func findRoute(to host: String) -> BenchEnvironment.Route {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/route")
    process.arguments = ["-n", "get", host]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return BenchEnvironment.Route(host: host, interface: nil, error: error.localizedDescription)
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let interface = String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix("interface:") }
        .map { $0.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces) }
    let failure = process.terminationStatus == 0 ? nil : "route 退出码 \(process.terminationStatus)"
    return BenchEnvironment.Route(host: host, interface: interface, error: interface == nil ? failure ?? "输出中没有 interface 字段" : nil)
}

// MARK: - 卷

private func volume(at path: String) -> BenchEnvironment.Volume {
    let probe = TimeoutBox<BenchEnvironment.Volume>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        probe.set(statVolume(at: path))
        done.signal()
    }
    guard done.wait(timeout: .now() + BenchEnvironment.volumeProbeTimeout) == .success, let result = probe.get() else {
        return BenchEnvironment.Volume(path: path, error: "statfs 超过 \(Int(BenchEnvironment.volumeProbeTimeout)) 秒未返回")
    }
    return result
}

private func statVolume(at path: String) -> BenchEnvironment.Volume {
    var info = statfs()
    guard statfs(path, &info) == 0 else {
        return BenchEnvironment.Volume(path: path, error: String(cString: strerror(errno)))
    }
    return BenchEnvironment.Volume(
        path: path,
        mountPoint: cString(of: &info.f_mntonname),
        fileSystem: cString(of: &info.f_fstypename),
        source: BenchEnvironment.redactingUser(cString(of: &info.f_mntfromname))
    )
}

/// 把 C 结构里定长的字符数组字段转成字符串。
func cString<T>(of tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// 在线程间传递一次结果；超时后调用方不再等待，后台线程自行结束。
private final class TimeoutBox<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)

    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    func get() -> Value? { value.withLock { $0 } }
}
