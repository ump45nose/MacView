import Synchronization

/// 按字节成本淘汰的 LRU。链表和成本只在同一把锁内访问。
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int64
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int64) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private struct State: @unchecked Sendable {
        var budget: Int64
        var totalCost: Int64 = 0
        var nodes: [Key: Node] = [:]
        var oldest: Node?
        var newest: Node?

        mutating func unlink(_ node: Node) {
            if let previous = node.previous { previous.next = node.next }
            else { oldest = node.next }
            if let next = node.next { next.previous = node.previous }
            else { newest = node.previous }
            node.previous = nil
            node.next = nil
        }

        mutating func append(_ node: Node) {
            node.previous = newest
            newest?.next = node
            newest = node
            if oldest == nil { oldest = node }
        }

        mutating func remove(_ node: Node) {
            unlink(node)
            nodes.removeValue(forKey: node.key)
            totalCost -= node.cost
        }

        mutating func trim(to limit: Int64) {
            while totalCost > limit, let node = oldest { remove(node) }
        }
    }

    private let state: Mutex<State>

    public init(budget: Int64) { state = Mutex(State(budget: max(0, budget))) }
    public var budget: Int64 { state.withLock { $0.budget } }
    public var totalCost: Int64 { state.withLock { $0.totalCost } }

    public func value(for key: Key) -> Value? {
        state.withLock { state in
            guard let node = state.nodes[key] else { return nil }
            state.unlink(node)
            state.append(node)
            return node.value
        }
    }

    public func insert(_ value: Value, for key: Key, cost: Int64) {
        state.withLock { state in
            if let previous = state.nodes[key] { state.remove(previous) }
            guard cost >= 0, cost <= state.budget else { return }
            state.trim(to: state.budget - cost)
            let node = Node(key: key, value: value, cost: cost)
            state.nodes[key] = node
            state.append(node)
            state.totalCost += cost
        }
    }

    public func removeValue(for key: Key) {
        state.withLock { state in
            if let node = state.nodes[key] { state.remove(node) }
        }
    }

    public func setBudget(_ budget: Int64) {
        state.withLock { state in
            state.budget = max(0, budget)
            state.trim(to: state.budget)
        }
    }

    /// 预算保持不变；warning 用 0.5，critical 用 0.25。
    public func trim(toFraction fraction: Double) {
        state.withLock { state in
            let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
            let target = fraction == 1 ? state.budget : Int64(Double(state.budget) * fraction)
            state.trim(to: target)
        }
    }
}
