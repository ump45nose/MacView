import Darwin
import Foundation
import Synchronization

public enum DocumentChange: Sendable, Equatable {
    case reloaded
    /// 消息包含行列位置；仍保留上一份可用的值。
    case fileError(message: String)
}

private struct DocumentHeader: Decodable { var version: Int }
private struct Document<Value: Codable>: Codable { var version: Int; var value: Value }

/// 带版本号的 JSON 文档。监听所在目录，因此原子替换文件后仍能继续重载。
public final class JSONDocumentStore<Value: Codable & Sendable>: Sendable {
    private struct State {
        var value: Value
        var lastData: Data?
        var error: String?
        var observers: [UUID: @Sendable (DocumentChange) -> Void] = [:]
        var monitor: (any DispatchSourceFileSystemObject)?
        var fileMonitor: (any DispatchSourceFileSystemObject)?
        var reloadGeneration: UInt64 = 0
    }

    private let fileURL: URL
    private let version: Int
    private let defaultValue: Value
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "MacView.JSONDocumentStore")
    private let valueDecoder: @Sendable (Data) throws -> (Value, String?)

    /// 文件不存在时只使用默认值，第一次 update 才写出。
    public convenience init(fileURL: URL, version: Int, defaultValue: Value) throws {
        try self.init(fileURL: fileURL, version: version, defaultValue: defaultValue) {
            (try JSONDecoder().decode(Value.self, from: $0), nil)
        }
    }

    /// 设置文件需要在解析 value 时补齐缺省全局字段；通用文档仍严格按 Codable 解析。
    init(fileURL: URL, version: Int, defaultValue: Value,
         valueDecoder: @escaping @Sendable (Data) throws -> (Value, String?)) throws {
        self.fileURL = fileURL
        self.version = version
        self.defaultValue = defaultValue
        self.valueDecoder = valueDecoder
        state = Mutex(State(value: defaultValue))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 先监听再读文件，避免初始化期间漏掉替换。
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        monitor.setEventHandler { [weak self] in self?.scheduleReload() }
        monitor.setCancelHandler { close(descriptor) }
        state.withLock { $0.monitor = monitor }
        // 初始化的 I/O 错误交给创建者；外部文档错误则保留默认值并通过 changes 报告。
        do {
            if let data = try readData() { load(data) }
            try watchFile()
        }
        catch { monitor.resume(); monitor.cancel(); throw error }
        monitor.resume()
    }

    deinit {
        state.withLock { current in
            current.monitor?.cancel()
            current.fileMonitor?.cancel()
        }
    }

    public func value() -> Value { state.withLock { $0.value } }

    public func update(_ change: @Sendable (inout Value) -> Void) async throws {
        // 非隔离 async 方法在调用者 actor 之外执行；同一队列串行化更新和外部重载。
        try queue.sync {
            var next = value()
            change(&next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(version: version, value: next))
            // Foundation 在同一目录写临时文件并 rename；旧文件在替换前一直完整可读。
            try data.write(to: fileURL, options: .atomic)
            state.withLock { $0.value = next; $0.lastData = data; $0.error = nil }
            try watchFile()
            publish(.reloaded)
        }
    }

    public func changes() -> AsyncStream<DocumentChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: DocumentChange.self)
        let id = observe { continuation.yield($0) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    @discardableResult
    func observe(_ observer: @escaping @Sendable (DocumentChange) -> Void) -> UUID {
        let id = UUID()
        let error = state.withLock { current in
            current.observers[id] = observer
            return current.error
        }
        if let error { observer(.fileError(message: error)) }
        return id
    }

    private func publish(_ change: DocumentChange) {
        let observers = state.withLock { Array($0.observers.values) }
        for observer in observers { observer(change) }
    }

    private func scheduleReload() {
        let generation = state.withLock { current in
            current.reloadGeneration &+= 1
            return current.reloadGeneration
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.state.withLock({ $0.reloadGeneration == generation }) else { return }
            self.reload()
        }
    }

    private func readData() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func reload() {
        do {
            let data = try readData()
            try watchFile()
            guard data != state.withLock({ $0.lastData }) else { return }
            if let data { load(data) }
            else {
                state.withLock { $0.value = defaultValue; $0.lastData = nil; $0.error = nil }
                publish(.reloaded)
            }
        } catch {
            let message = Self.message(for: error, data: nil)
            state.withLock { $0.error = message }
            publish(.fileError(message: message))
        }
    }

    /// 目录源跟踪 rename，文件源补足编辑器原地写入的 NOTE_WRITE。
    private func watchFile() throws {
        state.withLock { $0.fileMonitor?.cancel(); $0.fileMonitor = nil }
        let descriptor = open(fileURL.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        monitor.setEventHandler { [weak self] in self?.scheduleReload() }
        monitor.setCancelHandler { close(descriptor) }
        state.withLock { $0.fileMonitor = monitor }
        monitor.resume()
    }

    private func load(_ data: Data) {
        do {
            // 先校验语法，以取得 JSONSerialization 提供的精确行列位置。
            let object = try JSONSerialization.jsonObject(with: data)
            let header = try JSONDecoder().decode(DocumentHeader.self, from: data)
            guard header.version <= version else {
                throw DocumentError(message: "文档版本 \(header.version) 高于支持的版本 \(version)", key: "version")
            }
            guard let dictionary = object as? [String: Any], let rawValue = dictionary["value"] else {
                throw DocumentError(message: "缺少 value 字段", key: "value")
            }
            let valueData = try JSONSerialization.data(withJSONObject: rawValue, options: [.fragmentsAllowed])
            let (value, warning) = try valueDecoder(valueData)
            let message = warning.map { Self.message(for: DocumentError(message: $0, key: "value"), data: data) }
            state.withLock { $0.value = value; $0.lastData = data; $0.error = message }
            publish(.reloaded)
            if let message { publish(.fileError(message: message)) }
        } catch {
            let message = Self.message(for: error, data: data)
            state.withLock { $0.lastData = data; $0.error = message }
            publish(.fileError(message: message))
        }
    }

    private struct DocumentError: Error { var message: String; var key: String }

    private static func message(for error: any Error, data: Data?) -> String {
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let nsError = error as NSError
        var detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        var key: String?
        if let error = error as? DocumentError { detail = error.message; key = error.key }
        switch error {
        case let DecodingError.keyNotFound(codingKey, context):
            key = context.codingPath.last?.stringValue ?? "value"
            detail = "缺少字段 \(codingKey.stringValue)"
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context),
             let DecodingError.dataCorrupted(context):
            key = context.codingPath.last?.stringValue ?? "value"
            detail = context.debugDescription
        default: break
        }
        // JSONSerialization 的语法错误一般直接带 line/column。
        if let expression = try? NSRegularExpression(pattern: #"line (\d+), column (\d+)"#),
           let match = expression.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
           let line = Range(match.range(at: 1), in: detail), let column = Range(match.range(at: 2), in: detail) {
            return "第 \(detail[line]) 行，第 \(detail[column]) 列：\(detail)"
        }
        let offset: String.Index
        if let key, let range = text.range(of: "\"\(key)\"") { offset = range.lowerBound }
        else if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
            offset = text.index(text.startIndex, offsetBy: min(index, text.count))
        } else { offset = text.startIndex }
        let prefix = text[..<offset]
        let line = prefix.filter { $0 == "\n" }.count + 1
        let column = prefix.reversed().prefix(while: { $0 != "\n" }).count + 1
        return "第 \(line) 行，第 \(column) 列：\(detail)"
    }
}
