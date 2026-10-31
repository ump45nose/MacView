import Darwin
import Foundation
import Synchronization

/// 本机 TCP 代理，把 127.0.0.1 上的端口转发到 NAS，只影响经过它的测试挂载。
/// 暂停时不再转发数据、连接保持，模拟 NAS 卡住；切断时重置全部连接并拒绝新连接，模拟断线。
final class FaultProxy: Sendable {
    enum Mode: String, Codable, Sendable {
        case forward
        case pause
        case drop
    }

    struct Target: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    struct Status: Codable, Sendable {
        var mode: Mode
        /// 当前转发中的连接数。
        var connections: Int
        /// 累计建立的连接数。
        var accepted: Int
    }

    /// 与 targets 一一对应的本机监听端口。
    let ports: [UInt16]
    private let state = Mutex(State())

    private struct State {
        var mode = Mode.forward
        var stopped = false
        var nextID = 0
        var accepted = 0
        var connections: [Int: Connection] = [:]
    }

    init(targets: [Target]) throws(SystemCallError) {
        var listeners: [(socket: Int32, target: Target)] = []
        var ports: [UInt16] = []
        for target in targets {
            let (socket, port) = try Self.listen(port: 0)
            listeners.append((socket, target))
            ports.append(port)
        }
        self.ports = ports
        for listener in listeners {
            Thread { self.acceptLoop(listener.socket, target: listener.target) }.start()
        }
    }

    var status: Status {
        state.withLock { Status(mode: $0.mode, connections: $0.connections.count, accepted: $0.accepted) }
    }

    func set(_ mode: Mode) {
        let dropped = state.withLock { state in
            state.mode = mode
            return mode == .drop ? Array(state.connections.values) : []
        }
        for connection in dropped { connection.reset() }
    }

    /// 停止监听，切断全部连接。
    func stop() {
        let connections = state.withLock { state in
            state.stopped = true
            return Array(state.connections.values)
        }
        for connection in connections { connection.reset() }
    }

    private func acceptLoop(_ listener: Int32, target: Target) {
        defer { close(listener) }
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !state.withLock({ $0.stopped }) {
            descriptor.revents = 0
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            if state.withLock({ $0.mode == .drop }) {
                Self.resetAndClose(client)
                continue
            }
            Thread { self.open(client, to: target) }.start()
        }
    }

    private func open(_ client: Int32, to target: Target) {
        guard let upstream = Self.connect(to: target) else {
            Self.resetAndClose(client)
            return
        }
        Self.disableNagle(client)
        Self.disableNagle(upstream)
        let connection = Connection(client: client, upstream: upstream)
        let id: Int? = state.withLock { state in
            guard !state.stopped, state.mode != .drop else { return nil }
            state.nextID += 1
            state.accepted += 1
            state.connections[state.nextID] = connection
            return state.nextID
        }
        guard let id else {
            connection.reset()
            connection.closeSockets()
            return
        }
        Thread { self.pump(from: client, to: upstream, connection: connection, id: id) }.start()
        Thread { self.pump(from: upstream, to: client, connection: connection, id: id) }.start()
    }

    /// 单向转发。任一方向结束都会关闭整个连接；两个方向都结束后关闭套接字。
    private func pump(from source: Int32, to destination: Int32, connection: Connection, id: Int) {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)
        defer {
            buffer.deallocate()
            connection.shutdown()
            if connection.endOneDirection() {
                connection.closeSockets()
                state.withLock { _ = $0.connections.removeValue(forKey: id) }
            }
        }
        while waitWhilePaused() {
            let count = Darwin.read(source, buffer.baseAddress, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, waitWhilePaused() else { return }
            var sent = 0
            while sent < count {
                let written = Darwin.write(destination, buffer.baseAddress! + sent, count - sent)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                sent += written
            }
        }
    }

    /// 暂停期间每 10 ms 检查一次状态。返回 false 表示连接应当结束。
    private func waitWhilePaused() -> Bool {
        while true {
            switch state.withLock({ $0.stopped ? Mode.drop : $0.mode }) {
            case .forward: return true
            case .drop: return false
            case .pause: usleep(10_000)
            }
        }
    }

    /// 一对被转发的套接字。
    private final class Connection: Sendable {
        let client: Int32
        let upstream: Int32
        private let endedDirections = Mutex(0)

        init(client: Int32, upstream: Int32) {
            self.client = client
            self.upstream = upstream
        }

        /// 唤醒两个方向上阻塞的读写。
        func shutdown() {
            _ = Darwin.shutdown(client, SHUT_RDWR)
            _ = Darwin.shutdown(upstream, SHUT_RDWR)
        }

        /// 关闭时发送 RST 而不是 FIN，模拟断线。
        func reset() {
            FaultProxy.setLingerZero(client)
            FaultProxy.setLingerZero(upstream)
            shutdown()
        }

        func endOneDirection() -> Bool {
            endedDirections.withLock { count in
                count += 1
                return count == 2
            }
        }

        func closeSockets() {
            close(client)
            close(upstream)
        }
    }

    /// 在 127.0.0.1 上监听，port 为 0 时由系统分配。返回套接字和实际端口。
    static func listen(port: UInt16) throws(SystemCallError) -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .last("socket") }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.address("127.0.0.1", port: port)!
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let error = SystemCallError.last("bind")
            close(fd)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    static func connect(to target: Target) -> Int32? {
        guard var address = address(target.host, port: target.port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// IPv4 地址；host 必须是点分十进制。
    static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return address
    }

    private static func disableNagle(_ fd: Int32) {
        var enable: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enable, socklen_t(MemoryLayout<Int32>.size))
    }

    fileprivate static func setLingerZero(_ fd: Int32) {
        var option = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
    }

    private static func resetAndClose(_ fd: Int32) {
        setLingerZero(fd)
        close(fd)
    }
}
