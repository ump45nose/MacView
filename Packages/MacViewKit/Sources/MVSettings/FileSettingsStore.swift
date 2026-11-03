import Foundation
import GRDB
import MVFoundation
import Synchronization

/// settings.json、path-rules.json 与 state.sqlite 的真实设置存储。
public final class FileSettingsStore: SettingsStore {
    private struct State {
        var memories: [Location: BookMemory]
        var pending: [Location: BookMemory] = [:]
        var observers: [UUID: AsyncStream<SettingsChange>.Continuation] = [:]
        var errors: [String: String] = [:]
        var timer: (any DispatchSourceTimer)?
    }

    private let settings: JSONDocumentStore<GlobalSettings>
    private let rules: JSONDocumentStore<[PathRule]>
    private let database: DatabaseQueue
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "MacView.BookMemory")

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = try JSONDocumentStore(fileURL: directory.appending(path: "settings.json"), version: 1,
                                         defaultValue: .default, valueDecoder: Self.decodeGlobal)
        rules = try JSONDocumentStore(fileURL: directory.appending(path: "path-rules.json"), version: 1, defaultValue: [])
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try Self.enableWriteAheadLogging(database)
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: directory.appending(path: "state.sqlite").path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("book-memory-v1") { database in
            try database.create(table: "book_memory") { table in
                table.column("location", .text).primaryKey()
                table.column("memory", .blob).notNull()
            }
        }
        try migrator.migrate(database)
        let memories = try database.read { database in
            try Row.fetchAll(database, sql: "SELECT memory FROM book_memory").map { row in
                try JSONDecoder().decode(BookMemory.self, from: row["memory"] as Data)
            }
        }
        state = Mutex(State(memories: Dictionary(uniqueKeysWithValues: memories.map { ($0.book, $0) })))
        settings.observe { [weak self] change in self?.documentChanged(change, file: "settings.json", change: .global) }
        rules.observe { [weak self] change in self?.documentChanged(change, file: "path-rules.json", change: .pathRules) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do { try self.writePending() }
            catch { self.reportMemoryError(error) }
        }
        state.withLock { $0.timer = timer }
        timer.resume()
    }

    deinit {
        let observers = state.withLock { current in
            current.timer?.cancel()
            return Array(current.observers.values)
        }
        for observer in observers { observer.finish() }
    }

    public func global() async -> GlobalSettings { settings.value() }

    public func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws {
        try await settings.update(change)
    }

    public func pathRules() async -> [PathRule] { rules.value() }

    public func updatePathRules(_ change: @Sendable (inout [PathRule]) -> Void) async throws {
        try await rules.update(change)
    }

    public func resolve(for book: Location) async -> ResolvedBookSettings {
        var resolved = settings.value().defaultBook
        let matching = rules.value().enumerated().filter { book.hasPrefix($0.element.prefix) }
            .sorted {
                let left = $0.element.prefix.layers.reduce(0) { $0 + $1.count }
                let right = $1.element.prefix.layers.reduce(0) { $0 + $1.count }
                return (left, $0.offset) < (right, $1.offset)
            }
        for rule in matching { resolved = resolved.applying(rule.element.settings) }
        if let memory = state.withLock({ $0.memories[book] }) { resolved = resolved.applying(memory.settings) }
        return resolved
    }

    public func bookMemory(for book: Location) async -> BookMemory? { state.withLock { $0.memories[book] } }

    public func saveBookMemory(_ memory: BookMemory) async {
        state.withLock { current in
            current.memories[memory.book] = memory
            current.pending[memory.book] = memory
        }
    }

    /// 将合并的书记忆用单个事务写入；退出前调用，错误交给组合根。
    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do { try writePending(); continuation.resume() }
                catch { reportMemoryError(error); continuation.resume(throwing: error) }
            }
        }
    }

    public func changes() -> AsyncStream<SettingsChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: SettingsChange.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { current in
            current.observers[id] = continuation
            for (file, message) in current.errors { continuation.yield(.fileError(file: file, message: message)) }
        }
        return stream
    }

    private func documentChanged(_ document: DocumentChange, file: String, change: SettingsChange) {
        state.withLock { current in
            let event: SettingsChange
            switch document {
            case .reloaded: current.errors.removeValue(forKey: file); event = change
            case let .fileError(message): current.errors[file] = message; event = .fileError(file: file, message: message)
            }
            for observer in current.observers.values { observer.yield(event) }
        }
    }

    private func reportMemoryError(_ error: any Error) {
        documentChanged(.fileError(message: error.localizedDescription), file: "state.sqlite", change: .global)
    }

    private static func enableWriteAheadLogging(_ database: Database) throws {
        var deadline: ContinuousClock.Instant?
        while true {
            do {
                try database.execute(sql: "PRAGMA journal_mode = WAL")
                return
            } catch let error as DatabaseError {
                guard error.resultCode == .SQLITE_BUSY else { throw error }
                let now = ContinuousClock.now
                let retryDeadline = deadline ?? now + .seconds(5)
                deadline = retryDeadline
                guard now.duration(to: retryDeadline) >= .milliseconds(20) else { throw error }
                Thread.sleep(for: .milliseconds(20))
            }
        }
    }

    private func writePending() throws {
        let pending = state.withLock { current in
            let pending = current.pending
            current.pending.removeAll(keepingCapacity: true)
            return pending
        }
        guard !pending.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let rows = try pending.map { book, memory in
                (String(decoding: try encoder.encode(book), as: UTF8.self), try encoder.encode(memory))
            }
            try database.write { database in
                for (location, memory) in rows {
                    try database.execute(sql: "INSERT INTO book_memory (location, memory) VALUES (?, ?) "
                        + "ON CONFLICT(location) DO UPDATE SET memory = excluded.memory", arguments: [location, memory])
                }
            }
            _ = state.withLock { $0.errors.removeValue(forKey: "state.sqlite") }
        } catch {
            // 失败的批次留待显式 flush 或下一次定时写入；期间的新值优先。
            state.withLock { current in current.pending.merge(pending) { newer, _ in newer } }
            throw error
        }
    }

    private static func decodeGlobal(_ data: Data) throws -> (GlobalSettings, String?) {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GlobalSettings.default))
        let object = try JSONSerialization.jsonObject(with: data)
        var missing: [String] = []
        let merged = filling(object, defaults: defaults, path: "", missing: &missing)
        let value = try JSONDecoder().decode(GlobalSettings.self, from: JSONSerialization.data(withJSONObject: merged, options: [.fragmentsAllowed]))
        return (value, missing.isEmpty ? nil : String(localized: "缺少全局字段，已补默认值：\(missing.sorted().joined(separator: ", "))", bundle: .main))
    }

    private static func filling(_ object: Any, defaults: Any, path: String, missing: inout [String]) -> Any {
        guard var object = object as? [String: Any], let defaults = defaults as? [String: Any] else { return object }
        for (key, value) in defaults {
            let field = path.isEmpty ? key : path + "." + key
            if let present = object[key] { object[key] = filling(present, defaults: value, path: field, missing: &missing) }
            else { object[key] = value; missing.append(field) }
        }
        return object
    }
}

private extension Thread {
    static func sleep(for duration: Duration) {
        let components = duration.components
        sleep(forTimeInterval: TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}
