#if DEBUG
import AppKit
import Darwin
import MVCommands
import MVFoundation
import MVIO
import MVMedia
import MVServices
import Synchronization
import os

/// 调试命令接口：`-MVDebugSocket <路径>` 开启的 Unix 域套接字，一行一个 JSON。
///
/// 协议见 docs/architecture.md §3.10。阻塞的 accept 和 read 在一条专用线程上，命令在主线程执行，一次处理一条。
final class DebugSocket: Sendable {
    private let path: String
    private let commands: DebugCommands
    private static let logger = Logger(category: "debug")

    @MainActor
    static func startIfRequested(app: AppDelegate) -> DebugSocket? {
        guard let path = UserDefaults.standard.string(forKey: "MVDebugSocket"), !path.isEmpty else { return nil }
        let socket = DebugSocket(path: path, commands: DebugCommands(app: app))
        let thread = Thread { socket.serve() }
        thread.name = "MacView.DebugSocket"
        thread.start()
        return socket
    }

    private init(path: String, commands: DebugCommands) {
        self.path = path
        self.commands = commands
    }

    private func serve() {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard listener >= 0, path.utf8.count < capacity else {
            Self.logger.error("无法创建调试套接字：路径超过 \(capacity) 字节或 socket 失败")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.withCString { strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity - 1) }
        }
        unlink(path)
        let size = socklen_t(MemoryLayout.size(ofValue: address))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 4) == 0 else {
            Self.logger.error("无法监听调试套接字：\(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[..<count])
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<end])
                pending = Data(pending[(end + 1)...])
                guard !line.isEmpty else { continue }
                guard send(perform(line) + [UInt8(ascii: "\n")], to: client) else { return }
            }
        }
    }

    /// 把命令交给主线程，等它做完。这条线程只做这件事，可以阻塞。
    private func perform(_ line: Data) -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex(Data())
        let commands = commands
        Task { @MainActor in
            let response = await commands.respond(to: line)
            result.withLock { $0 = response }
            semaphore.signal()
        }
        semaphore.wait()
        return result.withLock { $0 }
    }

    private func send(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

/// 命令的实现。
@MainActor
final class DebugCommands: Sendable {
    private struct Request: Decodable {
        var id: JSONValue?
        var command: String
        var args: [String: JSONValue]?
    }

    private struct Failure: Error {
        var message: String
    }

    private let app: AppDelegate
    private var volumes: [VolumeHealth] = []
    private var healthTask: Task<Void, Never>?

    init(app: AppDelegate) {
        self.app = app
        if let updates = app.services?.sources.volumeHealth() {
            healthTask = Task { [weak self] in
                for await volumes in updates { self?.volumes = volumes }
            }
        }
    }

    func respond(to line: Data) async -> Data {
        var id = JSONValue.null
        var body: [String: JSONValue]
        do {
            let request = try JSONDecoder().decode(Request.self, from: line)
            id = request.id ?? .null
            let result = try await run(request.command, request.args ?? [:])
            body = ["id": id, "ok": .bool(true), "result": result]
        } catch let failure as Failure {
            body = ["id": id, "ok": .bool(false), "error": .string(failure.message)]
        } catch let error as CommandError {
            body = ["id": id, "ok": .bool(false), "error": .string(String(describing: error))]
        } catch {
            body = ["id": id, "ok": .bool(false), "error": .string(ErrorText.describe(error))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(body))) ?? Data(#"{"ok":false,"error":"无法编码响应"}"#.utf8)
    }

    private func run(_ command: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        switch command {
        case "perform": return try await perform(args)
        case "open": return try await open(args)
        case "resize": return try resize(args)
        case "scroll": return try await scroll(args)
        case "state": return state()
        case "quit":
            // 留时间写响应。不能在主队列的块里直接 terminate：`terminateLater` 的嵌套循环排不空主队列，退出流程的主线程任务永远跑不了。
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.05)
            return .object([:])
        default: throw Failure(message: "未知命令：\(command)")
        }
    }

    /// 前台窗口；App 不在前台时也能取到。
    private func frontController() throws -> ReaderWindowController {
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? ReaderWindowController }.first
        guard let controller = front ?? app.controllers.last else { throw Failure(message: "没有打开的窗口") }
        return controller
    }

    private func perform(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(name)? = args["command"] else { throw Failure(message: "perform 需要 command") }
        guard let services = app.services else { throw Failure(message: "服务未就绪") }
        let controller = try frontController()
        var arguments: [String: JSONValue]?
        if case let .object(value)? = args["arguments"] { arguments = value }
        let context = CommandContext(session: controller.session.id, scope: .viewer, selection: [])
        try await services.commands.perform(CommandID(name), arguments: arguments, context: context)
        return .object([:])
    }

    private func open(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(path)? = args["path"] else { throw Failure(message: "open 需要 path") }
        guard let services = app.services else { throw Failure(message: "服务未就绪") }
        let controller = try frontController()
        let location = try await services.sources.location(for: URL(fileURLWithPath: path))
        await controller.session.open(location, at: nil)
        if let error = controller.session.loadError { throw error }
        if let page = int(args["page"]) { controller.session.go(.index(page)) }
        return windowState(controller)
    }

    private func resize(_ args: [String: JSONValue]) throws -> JSONValue {
        guard let width = double(args["width"]), let height = double(args["height"]), width > 0, height > 0 else {
            throw Failure(message: "resize 需要 width、height")
        }
        let controller = try frontController()
        controller.window?.setContentSize(NSSize(width: width, height: height))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return windowState(controller)
    }

    private func scroll(_ args: [String: JSONValue]) async throws -> JSONValue {
        let controller = try frontController()
        guard let window = controller.window else { throw Failure(message: "没有窗口") }
        let viewer = controller.viewer
        let center = viewer.convert(NSPoint(x: viewer.bounds.midX, y: viewer.bounds.midY), to: nil)
        let events = SyntheticScroll.events(
            at: center, in: window, dx: double(args["dx"]) ?? 0, dy: double(args["dy"]) ?? 0, steps: int(args["steps"]) ?? 1
        )
        let interval = max(int(args["intervalMs"]) ?? 0, 0)
        for event in events {
            NSApp.sendEvent(event)
            if interval > 0 { try? await Task.sleep(for: .milliseconds(interval)) }
        }
        return .object(["events": .number(Double(events.count))])
    }

    // MARK: state

    private func state() -> JSONValue {
        var fileErrors = app.fileProblems.map { JSONValue.object(["file": .string($0.file), "message": .string($0.message)]) }
        if let problem = app.dock?.problem {
            fileErrors.append(.object(["file": .string("layout.json"), "message": .string(problem.detail)]))
        }
        return .object([
            "windows": .array(app.controllers.map(windowState)),
            "volumes": .array(volumes.map(volumeState)),
            "fileErrors": .array(fileErrors),
            "residentBytes": .number(Double(Self.residentBytes())),
        ])
    }

    private func windowState(_ controller: ReaderWindowController) -> JSONValue {
        let session = controller.session
        let viewer = controller.viewer
        let settings = session.settings
        let isPaged = settings.browseMode == .paged
        let visible = viewer.continuous.canvas.visibleRange.visible
        var range = isPaged ? Array(session.frames.indices.contains(session.currentFrame) ? session.frames[session.currentFrame].elements.map(\.page) : []) : []
        range.sort()
        var object: [String: JSONValue] = [
            "book": session.book.map { .string($0.location.description) } ?? .null,
            "page": .number(Double(session.currentPage)),
            "frame": .number(Double(session.currentFrame)),
            "frameCount": .number(Double(session.frames.count)),
            "browseMode": .string(settings.browseMode.rawValue),
            "scaleMode": .string(settings.scaleMode.rawValue),
            "zoom": .number(isPaged ? viewer.paged.transform.zoom : viewer.continuous.canvas.magnification),
            "viewport": .object(["width": .number(viewer.bounds.width), "height": .number(viewer.bounds.height)]),
            "visibleRange": isPaged
                ? .array(range.first.map { [.number(Double($0)), .number(Double((range.last ?? $0) + 1))] } ?? [])
                : .array([.number(Double(visible.lowerBound)), .number(Double(visible.upperBound))]),
            "loadError": session.loadError.map { .string(ErrorText.describe($0)) } ?? .null,
            "lastDisplay": .null,
        ]
        if let record = viewer.paged.lastDisplay {
            let (seconds, attoseconds) = record.duration.components
            object["lastDisplay"] = .object([
                "page": .number(Double(record.page)),
                "quality": .string(Self.name(of: record.quality)),
                "milliseconds": .number(Double(seconds) * 1000 + Double(attoseconds) / 1e15),
            ])
        }
        return .object(object)
    }

    private static func name(of quality: RenditionQuality) -> String {
        switch quality {
        case .placeholder: "placeholder"
        case .browse: "browse"
        case .exact: "exact"
        case .original: "original"
        }
    }

    private func volumeState(_ health: VolumeHealth) -> JSONValue {
        var state: [String: JSONValue]
        switch health.state {
        case .healthy: state = ["state": .string("healthy")]
        case let .degraded(reason): state = ["state": .string("degraded"), "reason": .string(reason)]
        case .unavailable: state = ["state": .string("unavailable")]
        }
        state["root"] = .string(Location(root: health.root).description)
        state["inFlight"] = .number(Double(health.inFlight))
        state["stuck"] = .number(Double(health.stuck))
        return .object(state)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func int(_ value: JSONValue?) -> Int? {
        double(value).map { Int($0) }
    }

    private func double(_ value: JSONValue?) -> Double? {
        if case let .number(number)? = value { return number }
        return nil
    }
}
#endif
