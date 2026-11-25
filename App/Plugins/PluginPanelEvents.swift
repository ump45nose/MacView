import Foundation
import MVFoundation
import MVScripting

/// 网页面板可订阅的事件名：四个阅读事件加面板专有的 `targetChanged`。
enum PluginPanelEventName: String, Hashable, Sendable, CaseIterable {
    case bookOpened
    case pageChanged
    case pageEnd
    case windowStateChanged
    case targetChanged

    init?(_ scriptEvent: ScriptEventName) {
        switch scriptEvent {
        case .startup: return nil
        case .bookOpened: self = .bookOpened
        case .pageChanged: self = .pageChanged
        case .pageEnd: self = .pageEnd
        case .windowStateChanged: self = .windowStateChanged
        }
    }
}

/// 面板事件订阅中心：维护「面板 → 监听的事件集合」，供 `ScriptEvents` 判断是否需要构造载荷并分发。
@MainActor
final class PluginPanelEventHub {
    private struct Entry {
        weak var panel: PluginWebPanel?
        var events: Set<PluginPanelEventName>
    }

    static let shared = PluginPanelEventHub()

    private var entries: [ObjectIdentifier: Entry] = [:]

    func subscribe(_ panel: PluginWebPanel, event: PluginPanelEventName) {
        let key = ObjectIdentifier(panel)
        if var existing = entries[key] {
            existing.events.insert(event)
            entries[key] = existing
        } else {
            entries[key] = Entry(panel: panel, events: [event])
        }
    }

    func unsubscribe(_ panel: PluginWebPanel, event: PluginPanelEventName) {
        let key = ObjectIdentifier(panel)
        guard var existing = entries[key] else { return }
        existing.events.remove(event)
        if existing.events.isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = existing
        }
    }

    func clearSubscriptions(for panel: PluginWebPanel) {
        entries.removeValue(forKey: ObjectIdentifier(panel))
    }

    func isSubscribed(_ panel: PluginWebPanel, to event: PluginPanelEventName) -> Bool {
        entries[ObjectIdentifier(panel)]?.events.contains(event) == true
    }

    /// 是否有作用于 `session` 的面板监听指定脚本事件。
    func hasSubscribers(for scriptEvent: ScriptEventName, session: SessionID?) -> Bool {
        guard let session, let event = PluginPanelEventName(scriptEvent) else { return false }
        pruneDeadEntries()
        return entries.values.contains { entry in
            guard let panel = entry.panel, entry.events.contains(event) else { return false }
            return panel.boundSession == session && !panel.isUnresponsive
        }
    }

    /// 把脚本事件投递给所有监听它、且当前作用于 `session` 的面板。
    func dispatch(_ scriptEvent: ScriptEventName, payload: [String: JSONValue], session: SessionID?) {
        guard let session, let event = PluginPanelEventName(scriptEvent) else { return }
        pruneDeadEntries()
        let targets = entries.values.compactMap { entry -> PluginWebPanel? in
            guard let panel = entry.panel, entry.events.contains(event) else { return nil }
            return (panel.boundSession == session && !panel.isUnresponsive) ? panel : nil
        }
        for panel in targets {
            panel.enqueueEvent(event, payload: payload)
        }
    }

    private func pruneDeadEntries() {
        entries = entries.filter { $0.value.panel != nil && !$0.value.events.isEmpty }
    }
}

/// 单个网页面板的事件投递队列：
/// - 同一时刻最多只有一个未完成的 `evaluateJavaScript` 投递；
/// - `pageChanged` 在等待期间只保留最新一条，其余事件按序排队；
/// - 绑定代次或页面代次变化时丢弃旧事件；页面无响应后暂停投递直到重建。
@MainActor
final class PluginPanelEventQueue {
    struct Item {
        let event: PluginPanelEventName
        let payload: [String: JSONValue]
        let bindGeneration: UInt64
    }

    private static let maxQueuedItems = 64

    private var pending: [Item] = []
    private var isDelivering = false
    private(set) var isPaused = true

    /// 实际执行单次事件投递的回调：传入事件项与完成回调（页面代次由宿主校验）。
    var deliver: ((Item, @escaping @MainActor () -> Void) -> Void)?

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused {
            drainIfNeeded()
        }
    }

    func enqueue(event: PluginPanelEventName, payload: [String: JSONValue], bindGeneration: UInt64) {
        let item = Item(event: event, payload: payload, bindGeneration: bindGeneration)
        if event == .pageChanged, let index = pending.firstIndex(where: { $0.event == .pageChanged }) {
            pending[index] = item
        } else {
            if pending.count >= Self.maxQueuedItems {
                pending.removeFirst()
            }
            pending.append(item)
        }
        drainIfNeeded()
    }

    /// 切换作用窗口时丢弃旧窗口的待投递事件（保留正在进行的回调状态，由代次兜底）。
    func clearPending() {
        pending.removeAll()
    }

    /// 页面重建时清空待投递事件并重置投递状态，暂停直到新页面加载就绪。
    func resetForRebuild() {
        pending.removeAll()
        isDelivering = false
        isPaused = true
    }

    func drainIfNeeded() {
        guard !isPaused, !isDelivering, !pending.isEmpty, let deliver else { return }
        let next = pending.removeFirst()
        isDelivering = true
        deliver(next) { [weak self] in
            guard let self else { return }
            self.isDelivering = false
            self.drainIfNeeded()
        }
    }
}
