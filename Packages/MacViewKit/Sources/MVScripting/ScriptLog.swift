import Foundation
import Synchronization

public struct ScriptLogEntry: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable { case info, warning, error }
    public var id: UInt64
    public var date: Date
    public var source: String
    public var level: Level
    public var text: String

    public init(id: UInt64, date: Date, source: String, level: Level, text: String) {
        self.id = id; self.date = date; self.source = source; self.level = level; self.text = text
    }
}

public final class ScriptLog: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        var entries: [ScriptLogEntry] = []
        var observers: [UUID: AsyncStream<[ScriptLogEntry]>.Continuation] = [:]
    }
    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 500) { self.capacity = max(0, capacity) }

    public func append(source: String, level: ScriptLogEntry.Level, text: String) {
        state.withLock { state in
            state.nextID &+= 1
            state.entries.append(ScriptLogEntry(id: state.nextID, date: Date(), source: source, level: level, text: text))
            if state.entries.count > capacity { state.entries.removeFirst(state.entries.count - capacity) }
            for observer in state.observers.values { observer.yield(state.entries) }
        }
    }

    public func entries() -> [ScriptLogEntry] { state.withLock { $0.entries } }

    public func changes() -> AsyncStream<[ScriptLogEntry]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ScriptLogEntry].self)
        let id = UUID()
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    public func clear() {
        state.withLock { state in
            state.entries.removeAll()
            for observer in state.observers.values { observer.yield(state.entries) }
        }
    }
}
