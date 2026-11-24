import Darwin
import Foundation
import JavaScriptCore
import Synchronization

public enum ScriptEventName: String, Sendable, Codable, CaseIterable {
    case startup, bookOpened, pageChanged, pageEnd, windowStateChanged
}

public struct ScriptProblem: Sendable, Hashable {
    public var line: Int?
    public var message: String
    public init(line: Int?, message: String) { self.line = line; self.message = message }
}

public struct ScriptInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var fileURL: URL
    public var name: String
    public var summary: String?
    public var events: [ScriptEventName]
    public var problem: ScriptProblem?

    public init(id: String, fileURL: URL, name: String, summary: String?, events: [ScriptEventName], problem: ScriptProblem?) {
        self.id = id; self.fileURL = fileURL; self.name = name; self.summary = summary
        self.events = events; self.problem = problem
    }
}

public final class ScriptLibrary: Sendable {
    private struct State {
        var scripts: [ScriptInfo] = []
        var subscribers: [ScriptEventName: [ScriptInfo]] = [:]
        var scanned = false
        var observers: [UUID: AsyncStream<[ScriptInfo]>.Continuation] = [:]
        var directoryMonitor: (any DispatchSourceFileSystemObject)?
        var fileMonitors: [any DispatchSourceFileSystemObject] = []
        var generation: UInt64 = 0
    }
    public let directory: URL
    private let queue = DispatchQueue(label: "MacView.ScriptLibrary")
    private let state = Mutex(State())

    public convenience init(directory: URL) {
        self.init(directory: directory, beforeInitialScan: {})
    }

    init(directory: URL, beforeInitialScan: @escaping @Sendable () -> Void) {
        self.directory = directory
        queue.sync {
            let exists = FileManager.default.fileExists(atPath: directory.path)
            if !exists {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for name in ["jump-middle", "ask-next-book"] {
                        if let source = Bundle.module.url(forResource: name, withExtension: "js") {
                            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("\(name).js"))
                        }
                    }
                } catch { /* scripts() remains empty if the directory is unavailable. */ }
            }
            watchDirectory()
        }
        queue.async { [weak self] in
            beforeInitialScan()
            self?.scan()
        }
    }

    deinit {
        state.withLock { state in
            state.directoryMonitor?.cancel()
            for monitor in state.fileMonitors { monitor.cancel() }
            for observer in state.observers.values { observer.finish() }
        }
    }

    public func scripts() -> [ScriptInfo] { state.withLock { $0.scripts } }
    func subscribers(for event: ScriptEventName) -> [ScriptInfo] { state.withLock { $0.subscribers[event] ?? [] } }

    public func changes() -> AsyncStream<[ScriptInfo]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ScriptInfo].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.observers[id] = continuation
            if state.scanned { continuation.yield(state.scripts) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    public func source(of id: String) throws -> String {
        try queue.sync {
            guard let file = state.withLock({ $0.scripts.first { $0.id == id }?.fileURL }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    private func watchDirectory() {
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        monitor.setEventHandler { [weak self] in self?.scheduleScan() }
        monitor.setCancelHandler { close(descriptor) }
        state.withLock { $0.directoryMonitor = monitor }
        monitor.resume()
    }

    private func watchFiles(_ files: [URL]) {
        let monitors: [any DispatchSourceFileSystemObject] = files.compactMap { file in
            let descriptor = open(file.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib], queue: queue)
            monitor.setEventHandler { [weak self] in self?.scheduleScan() }
            monitor.setCancelHandler { close(descriptor) }
            monitor.resume()
            return monitor
        }
        state.withLock { state in
            for monitor in state.fileMonitors { monitor.cancel() }
            state.fileMonitors = monitors
        }
    }

    private func scheduleScan() {
        let generation = state.withLock { state in
            state.generation &+= 1
            return state.generation
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, self.state.withLock({ $0.generation == generation }) else { return }
            self.scan()
        }
    }

    private func scan() {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])) ?? [])
            .filter { $0.pathExtension == "js" && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) }
        // Install file monitors before reading so an in-place edit during a scan is not missed.
        watchFiles(urls)
        let scripts = urls.map(Self.readScript).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        var subscribers: [ScriptEventName: [ScriptInfo]] = [:]
        for script in scripts where script.problem == nil {
            for event in script.events { subscribers[event, default: []].append(script) }
        }
        state.withLock { state in
            state.scripts = scripts
            state.subscribers = subscribers
            state.scanned = true
            for observer in state.observers.values { observer.yield(scripts) }
        }
    }

    private static func readScript(_ url: URL) -> ScriptInfo {
        let id = url.deletingPathExtension().lastPathComponent
        var info = ScriptInfo(id: id, fileURL: url, name: id, summary: nil, events: [], problem: nil)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            info.problem = ScriptProblem(line: nil, message: "无法读取脚本文件")
            return info
        }
        if ["stopAll", "revealFolder", "manage"].contains(id) {
            info.problem = ScriptProblem(line: nil, message: "此文件名由内置脚本命令保留")
        }
        for (index, rawLine) in source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else { break }
            let comment = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard comment.hasPrefix("@") else { continue }
            let parts = comment.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "name": if !value.isEmpty { info.name = value }
            case "description": info.summary = value
            case "event":
                for word in value.split(whereSeparator: { $0.isWhitespace }) {
                    if let event = ScriptEventName(rawValue: String(word)) {
                        if !info.events.contains(event) { info.events.append(event) }
                    } else if info.problem == nil {
                        info.problem = ScriptProblem(line: index + 1, message: "未知事件：\(word)")
                    }
                }
            default: break
            }
        }
        if info.problem == nil { info.problem = syntaxProblem(source) }
        return info
    }

    private static func syntaxProblem(_ source: String) -> ScriptProblem? {
        let context = JSGlobalContextCreate(nil)!
        defer { JSGlobalContextRelease(context) }
        let characters = Array(source.utf16)
        let script = characters.withUnsafeBufferPointer { JSStringCreateWithCharacters($0.baseAddress, $0.count)! }
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context, script, nil, 1, &exception), let exception else { return nil }
        let object = JSValueToObject(context, exception, nil)
        let lineKey = JSStringCreateWithUTF8CString("line")!
        defer { JSStringRelease(lineKey) }
        var line: Int?
        if let object, let value = JSObjectGetProperty(context, object, lineKey, nil), JSValueIsNumber(context, value) {
            let number = JSValueToNumber(context, value, nil)
            if number.isFinite && number > 0 && number < Double(Int.max) { line = Int(number) }
        }
        let message: String
        if let string = JSValueToStringCopy(context, exception, nil) {
            defer { JSStringRelease(string) }
            var buffer = [CChar](repeating: 0, count: JSStringGetMaximumUTF8CStringSize(string))
            let count = JSStringGetUTF8CString(string, &buffer, buffer.count)
            message = String(decoding: buffer.prefix(max(0, count - 1)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else { message = "JavaScript 语法错误" }
        return ScriptProblem(line: line, message: message)
    }
}
