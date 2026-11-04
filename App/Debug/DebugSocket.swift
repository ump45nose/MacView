#if DEBUG
import AppKit
import Darwin
import MVCommands
import MVFoundation
import MVIO
import MVLayout
import MVMedia
import MVPipeline
import MVServices
import MVSettings
import os

/// 调试命令接口：`-MVDebugSocket <路径>` 开启的 Unix 域套接字，一行一个 JSON。
///
/// 协议见 docs/architecture.md §3.8。accept 和 read 在专用线程上，命令按到达顺序在主线程执行。
/// 前一条命令挂起等待时，已经读到的下一条仍会执行，这样打开或故障期间可以查询 state。
final class DebugSocket: Sendable {
    private let path: String
    private let commands: DebugCommands
    private static let logger = Logger(category: "debug")

    @MainActor
    static func startIfRequested(app: AppDelegate) -> DebugSocket? {
        guard let path = UserDefaults.standard.string(forKey: "MVDebugSocket"), !path.isEmpty else { return nil }
        NSApp.activate()
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
        }
    }

    /// 读请求的线程不挡住下一条命令。主线程上一条命令挂起等待时，后面的 `state` 仍能执行，用来观察枚举和故障期间界面有没有冻住。
    private func handle(_ client: Int32) {
        let connection = DebugClient(fd: client)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[..<count])
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<end])
                pending = Data(pending[(end + 1)...])
                guard !line.isEmpty else { continue }
                connection.begin()
                let commands = commands
                Task { @MainActor in
                    let response = await commands.respond(to: line) + [UInt8(ascii: "\n")]
                    connection.send(response)
                    connection.end()
                }
            }
        }
        connection.finishReading()
    }
}

/// 一条调试连接。写和关闭共用一把锁，避免响应还在写时把描述符关掉。
private final class DebugClient: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private var inflight = 0
    private var ended = false

    init(fd: Int32) { self.fd = fd }

    func begin() {
        lock.lock()
        inflight += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        inflight -= 1
        let shouldClose = ended && inflight == 0
        lock.unlock()
        if shouldClose { closeSocket() }
    }

    func finishReading() {
        lock.lock()
        ended = true
        let shouldClose = inflight == 0
        lock.unlock()
        if shouldClose { closeSocket() }
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private func closeSocket() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 { close(current) }
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
        case "state": return await state()
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
        var arguments: [String: JSONValue]?
        if case let .object(value)? = args["arguments"] { arguments = value }
        if name == "panel.settings" { return try panelSettings(arguments) }
        guard let services = app.services else { throw Failure(message: "服务未就绪") }
        let controller = try frontController()
        let context = CommandContext(session: controller.session.id, scope: .viewer, selection: [])
        try await services.commands.perform(CommandID(name), arguments: arguments, context: context)
        return .object([:])
    }

    /// 改书架或页面列表的样式和尺寸。写入走面板自己的 `onSettingsChange`，退出时落进 layout.json。
    private func panelSettings(_ arguments: [String: JSONValue]?) throws -> JSONValue {
        guard let arguments, case let .string(name)? = arguments["panel"] else { throw Failure(message: "panel.settings 需要 panel") }
        let panel = try collectionPanel(name)
        if case let .string(style)? = arguments["style"] {
            guard let style = CollectionStyle(rawValue: style) else { throw Failure(message: "未知的面板样式 \(style)") }
            panel.setStyle(style)
        }
        if let extent = double(arguments["itemExtent"]) { panel.setItemExtent(extent) }
        return .object([:])
    }

    private func collectionPanel(_ name: String) throws -> CollectionPanel {
        let id: PanelID
        switch name {
        case "bookshelf": id = DockPanels.bookshelf
        case "pageList": id = DockPanels.pageList
        default: throw Failure(message: "panel 需要是 bookshelf 或 pageList")
        }
        let controller = try frontController()
        if let panel = controller.dock.panels[id] as? CollectionPanel { return panel }
        if let panel = app.dock?.floatingWindows[id]?.panel as? CollectionPanel { return panel }
        throw Failure(message: "找不到面板 \(name)")
    }

    private func open(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard case let .string(path)? = args["path"] else { throw Failure(message: "open 需要 path") }
        guard let services = app.services else { throw Failure(message: "服务未就绪") }
        let controller = try frontController()
        controller.beginFirstScreenThumbnails()
        let location = try await services.sources.location(for: URL(filePath: path, directoryHint: .inferFromPath))
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
        if let window = controller.window { orderFront(window) }
        return windowState(controller)
    }

    private func scroll(_ args: [String: JSONValue]) async throws -> JSONValue {
        let controller = try frontController()
        guard let window = controller.window else { throw Failure(message: "没有窗口") }
        orderFront(window)
        let viewer = controller.viewer
        let center = viewer.convert(NSPoint(x: viewer.bounds.midX, y: viewer.bounds.midY), to: nil)
        if let duration = int(args["durationMs"]), duration > 0 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !windowIsFront(window), ContinuousClock.now < deadline {
                orderFront(window)
                try? await Task.sleep(for: .milliseconds(50))
            }
            return try await continuousScroll(at: center, in: window, viewer: viewer, args: args, duration: duration)
        }
        let events = SyntheticScroll.events(
            at: center, in: window, dx: double(args["dx"]) ?? 0, dy: double(args["dy"]) ?? 0, steps: int(args["steps"]) ?? 1
        )
        let interval = max(int(args["intervalMs"]) ?? 0, 0)
        for event in events {
            NSApp.sendEvent(event)
            if interval > 0 { try? await Task.sleep(for: .milliseconds(interval)) }
        }
        return .object([
            "events": .number(Double(events.count)), "windowFront": .bool(windowIsFront(window)),
            "responsiveScrolling": .bool(CanvasView.isCompatibleWithResponsiveScrolling),
        ])
    }

    /// 一段连续手势：began、约 8 ms 一次的 changed，到边界后反向，最后 ended。结束后留出 settled 的时间。
    private func continuousScroll(at center: NSPoint, in window: NSWindow, viewer: ViewerContainerView, args: [String: JSONValue], duration: Int) async throws -> JSONValue {
        let interval = max(int(args["intervalMs"]) ?? 8, 1)
        var step = double(args["dy"]) ?? -12
        if step == 0 { step = -12 }
        let dx = double(args["dx"]) ?? 0
        func send(_ phase: CGScrollPhase, _ dy: Double) {
            if let event = SyntheticScroll.event(at: center, in: window, dx: dx, dy: dy, phase: phase) {
                NSApp.sendEvent(event)
            }
        }
        send(.began, step)
        var sent = 1
        var unchanged = 0
        var movements = 0
        var remainedFront = windowIsFront(window)
        var last = viewer.continuous.canvas.contentView.bounds.origin
        let end = ContinuousClock.now.advanced(by: .milliseconds(duration))
        while ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(interval))
            send(.changed, step)
            sent += 1
            remainedFront = remainedFront && windowIsFront(window)
            let origin = viewer.continuous.canvas.contentView.bounds.origin
            if origin == last { unchanged += 1 } else { unchanged = 0 }
            if origin != last { movements += 1 }
            if unchanged >= 3 {
                step = -step
                unchanged = 0
            }
            last = origin
        }
        send(.ended, 0)
        sent += 1
        try? await Task.sleep(for: .milliseconds(250))
        return .object([
            "events": .number(Double(sent)), "scrollMovements": .number(Double(movements)),
            "windowFront": .bool(remainedFront && windowIsFront(window)),
            "responsiveScrolling": .bool(CanvasView.isCompatibleWithResponsiveScrolling),
        ])
    }

    /// 只操作当前进程；无法取得前台时由验收脚本判为环境不满足。
    private func orderFront(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func windowIsFront(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible)
    }

    // MARK: state

    private func state() async -> JSONValue {
        var fileErrors = app.fileProblems.map { JSONValue.object(["file": .string($0.file), "message": .string($0.message)]) }
        if let problem = app.dock?.problem {
            fileErrors.append(.object(["file": .string("layout.json"), "message": .string(problem.detail)]))
        }
        let budgets = await app.services?.settings.global().cache
        let memory = (app.services?.pipeline as? FileImagePipeline)?.memory
        return .object([
            "windows": .array(app.controllers.map(windowState)),
            "volumes": .array(volumes.map(volumeState)),
            "fileErrors": .array(fileErrors),
            "residentBytes": .number(Double(Self.residentBytes())),
            "cacheBudgets": budgets.map { .object([
                "rawBytes": .number(Double($0.rawBytes)), "decodedBytes": .number(Double($0.decodedBytes)),
                "thumbnailMemoryBytes": .number(Double($0.thumbnailMemoryBytes)), "preloadBytes": .number(Double($0.preloadBytes)),
                "thumbnailDiskBytes": .number(Double($0.thumbnailBytes)), "browseDiskBytes": .number(Double($0.browseBytes)),
            ]) } ?? .null,
            "memory": memory.map { .object([
                "rawBytes": .number(Double($0.rawBytes)), "decodedBytes": .number(Double($0.decodedBytes)),
                "thumbnailMemoryBytes": .number(Double($0.thumbnailMemoryBytes)), "preloadBytes": .number(Double($0.preloadBytes)),
                "inFlightBytes": .number(Double($0.inFlightBytes)), "waitingTasks": .number(Double($0.waitingTasks)),
            ]) } ?? .null,
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
            "loadError": pageLoadError(controller).map { .string($0) } ?? .null,
            "lastDisplay": .null,
            "prefetchIdle": .bool(prefetchInFlightCount(controller) == 0),
            "prefetchInFlightCount": .number(Double(prefetchInFlightCount(controller))),
            "windowFront": .bool(windowIsFront(controller.window)),
            "responsiveScrolling": .bool(CanvasView.isCompatibleWithResponsiveScrolling),
            "docksVisible": .bool(DockEdge.allCases.contains { controller.dock.dockLayout.isShowing($0) }),
            "firstScreenThumbnailMilliseconds": controller.firstScreenThumbnailMilliseconds.map { .number($0) } ?? .null,
            "itemCount": .number(Double(session.book?.pages.count ?? 0)),
            "panels": .object([
                "bookshelf": panelSettingsState(DockPanels.bookshelf, controller: controller),
                "pageList": panelSettingsState(DockPanels.pageList, controller: controller),
            ]),
            "tiles": tileState(controller),
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

    private func prefetchInFlightCount(_ controller: ReaderWindowController) -> Int {
        guard let pipeline = controller.services.pipeline as? FileImagePipeline else { return 0 }
        return pipeline.prefetchInFlightCount(session: controller.session.id)
    }

    /// 书打不开时用会话错误；页读取失败时用当前页的错误，这样故障注入能出现在 state 里。
    private func pageLoadError(_ controller: ReaderWindowController) -> String? {
        if let error = controller.session.loadError { return ErrorText.describe(error) }
        return controller.viewer.paged.slots.lazy.compactMap(\.failure).first.map(ErrorText.describe)
    }

    private func panelSettingsState(_ id: PanelID, controller: ReaderWindowController) -> JSONValue {
        let panel = (controller.dock.panels[id] as? CollectionPanel)
            ?? (app.dock?.floatingWindows[id]?.panel as? CollectionPanel)
        guard let panel else { return .null }
        let settings = panel.settings
        return .object([
            "style": .string(settings.style.rawValue),
            "itemExtent": .number(settings.itemExtent),
            "sort": settings.sort.map(Self.sortValue) ?? .null,
        ])
    }

    private static func sortValue(_ sort: SortSpec) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(sort.key.rawValue),
            "ascending": .bool(sort.ascending),
            "foldersFirst": .bool(sort.foldersFirst),
        ]
        if let seed = sort.randomSeed { object["randomSeed"] = .number(Double(seed)) }
        return .object(object)
    }

    private func tileState(_ controller: ReaderWindowController) -> JSONValue {
        let layers = controller.viewer.paged.slots.compactMap(\.tiled)
        return .object([
            "requested": .number(Double(layers.reduce(0) { $0 + $1.requestedTiles })),
            "cancelled": .number(Double(layers.reduce(0) { $0 + $1.cancelledTiles })),
            "inFlight": .number(Double(layers.reduce(0) { $0 + $1.inFlightTiles })),
        ])
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
