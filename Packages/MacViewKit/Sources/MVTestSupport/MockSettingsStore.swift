import Foundation
import MVFoundation
import MVSettings
import Synchronization

/// 内存中的设置。分层解析与真实实现的规则相同：全局 ⊕ 匹配的路径规则（越具体越靠后）⊕ 书记忆。
public final class MockSettingsStore: SettingsStore {
    private struct State {
        var global: GlobalSettings
        var rules: [PathRule]
        var memories: [Location: BookMemory]
        var observers: [UUID: AsyncStream<SettingsChange>.Continuation] = [:]

        func notify(_ change: SettingsChange) {
            observers.values.forEach { $0.yield(change) }
        }
    }

    private let state: Mutex<State>

    public init(global: GlobalSettings = .default, pathRules: [PathRule] = [], memories: [BookMemory] = []) {
        state = Mutex(State(global: global, rules: pathRules, memories: Dictionary(memories.map { ($0.book, $0) }) { _, last in last }))
    }

    public func resolve(for book: Location) async -> ResolvedBookSettings {
        state.withLock { current in
            let rules = current.rules.enumerated()
                .filter { book.hasPrefix($0.element.prefix) }
                .sorted { (Self.depth(of: $0.element.prefix), $0.offset) < (Self.depth(of: $1.element.prefix), $1.offset) }
            var settings = current.global.defaultBook
            for rule in rules {
                settings = settings.applying(rule.element.settings)
            }
            if let memory = current.memories[book] {
                settings = settings.applying(memory.settings)
            }
            return settings
        }
    }

    public func bookMemory(for book: Location) async -> BookMemory? {
        state.withLock { $0.memories[book] }
    }

    public func saveBookMemory(_ memory: BookMemory) async {
        state.withLock { $0.memories[memory.book] = memory }
    }

    public func global() async -> GlobalSettings {
        state.withLock { $0.global }
    }

    public func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws {
        state.withLock { current in
            change(&current.global)
            current.notify(.global)
        }
    }

    public func pathRules() async -> [PathRule] {
        state.withLock { $0.rules }
    }

    public func updatePathRules(_ change: @Sendable (inout [PathRule]) -> Void) async throws {
        state.withLock { current in
            change(&current.rules)
            current.notify(.pathRules)
        }
    }

    public func changes() -> AsyncStream<SettingsChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: SettingsChange.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        state.withLock { $0.observers[id] = continuation }
        return stream
    }

    /// 替换全部路径规则，供测试和界面开发使用。
    public func setPathRules(_ rules: [PathRule]) {
        state.withLock { current in
            current.rules = rules
            current.notify(.pathRules)
        }
    }

    /// 模拟设置文件解析失败。
    public func simulateFileError(file: String, message: String) {
        state.withLock { $0.notify(.fileError(file: file, message: message)) }
    }

    /// 规则前缀的组件数，越大越具体。
    private static func depth(of location: Location) -> Int {
        location.layers.reduce(0) { $0 + $1.count }
    }
}
