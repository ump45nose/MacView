import Foundation

/// keybindings.json 的文档内容（v2；新字段均可缺省，v1 文件照常读取）；版本与原子写入由 JSONDocumentStore 管理。
public struct KeyBindingsFile: Codable, Sendable, Hashable {
    public static let documentVersion = 2

    public var bindings: [KeyBinding]
    public var mouseGestures: [MouseGestureBinding]?
    public var trackpad: [TrackpadBinding]?
    public var clickZones: [ClickZoneBinding]?
    public var wheel: [WheelBinding]?

    public init(
        bindings: [KeyBinding] = [],
        mouseGestures: [MouseGestureBinding]? = nil,
        trackpad: [TrackpadBinding]? = nil,
        clickZones: [ClickZoneBinding]? = nil,
        wheel: [WheelBinding]? = nil
    ) {
        self.bindings = bindings
        self.mouseGestures = mouseGestures
        self.trackpad = trackpad
        self.clickZones = clickZones
        self.wheel = wheel
    }
}

extension KeyBinding {
    /// 只要用户为某个命令提供了绑定，就替换该命令的全部默认绑定，保留用户文件中的顺序。
    /// 空序列也参与覆盖，但不参与解析，可用来取消某个命令的默认快捷键。
    public static func effective(defaults: [CommandDescriptor], user: [KeyBinding]) -> [KeyBinding] {
        let overridden = Set(user.map(\.command))
        return defaults.flatMap(\.defaultBindings).filter { !overridden.contains($0.command) } + user
    }
}

public struct BindingConflict: Sendable, Hashable {
    public var scope: InputScope
    public var first: KeyBinding
    public var second: KeyBinding

    public init(scope: InputScope, first: KeyBinding, second: KeyBinding) {
        self.scope = scope
        self.first = first
        self.second = second
    }
}

/// 把单键或多键序列解析成命令。当前作用域的前缀优先于 global；textInput 不回退。
/// 超时、输入作用域变化或续键失配会清除待定序列；失配的按键重新作为首键匹配。
/// 有冲突的绑定按文件顺序取首项，完整匹配优先于继续等待；调用方可先用 conflicts 校验。
public struct BindingResolver: Sendable {
    private let bindings: [KeyBinding]
    private let sequenceTimeout: Duration
    private var sequence: [KeyChord] = []
    private var inputScope: InputScope?
    private var bindingScope: InputScope?
    private var inputOverlay: InputScope?
    private var lastInputTime: ContinuousClock.Instant?

    public init(bindings: [KeyBinding], sequenceTimeout: Duration = .seconds(1)) {
        self.bindings = bindings.filter { !$0.sequence.isEmpty }
        self.sequenceTimeout = sequenceTimeout
    }

    public mutating func feed(_ chord: KeyChord, scope: InputScope, overlay: InputScope? = nil, at time: ContinuousClock.Instant) -> ResolveResult {
        let overlay = scope == .textInput ? nil : overlay
        if let lastInputTime,
           scope != inputScope || overlay != inputOverlay || time < lastInputTime || lastInputTime.duration(to: time) >= sequenceTimeout {
            reset()
        }

        if let bindingScope, !sequence.isEmpty {
            let next = sequence + [chord]
            let candidates = bindings.filter { $0.scope == bindingScope && $0.sequence.starts(with: next) }
            if !candidates.isEmpty {
                return resolve(next, candidates: candidates, scope: scope, overlay: overlay, at: time)
            }
            reset()
        }

        let first = [chord]
        var scopes: [InputScope] = []
        if let overlay { scopes.append(overlay) }
        if !scopes.contains(scope) { scopes.append(scope) }
        if scope != .textInput && !scopes.contains(.global) { scopes.append(.global) }
        for bindingScope in scopes {
            let candidates = bindings.filter { $0.scope == bindingScope && $0.sequence.starts(with: first) }
            if !candidates.isEmpty { return resolve(first, candidates: candidates, scope: scope, overlay: overlay, at: time) }
        }
        return .unmatched
    }

    /// 同一作用域内序列相同，或一条序列是另一条的前缀时，每对返回一次，顺序与输入一致。
    public static func conflicts(in bindings: [KeyBinding]) -> [BindingConflict] {
        var result: [BindingConflict] = []
        for (index, first) in bindings.enumerated() where !first.sequence.isEmpty {
            for second in bindings.dropFirst(index + 1) where second.scope == first.scope && !second.sequence.isEmpty {
                if first.sequence.starts(with: second.sequence) || second.sequence.starts(with: first.sequence) {
                    result.append(BindingConflict(scope: first.scope, first: first, second: second))
                }
            }
        }
        return result
    }

    private mutating func resolve(
        _ next: [KeyChord], candidates: [KeyBinding], scope: InputScope, overlay: InputScope?, at time: ContinuousClock.Instant
    ) -> ResolveResult {
        if let complete = candidates.first(where: { $0.sequence.count == next.count }) {
            reset()
            return .command(complete.command, complete.arguments)
        }
        sequence = next
        inputScope = scope
        inputOverlay = overlay
        bindingScope = candidates[0].scope
        lastInputTime = time
        return .pending(next)
    }

    private mutating func reset() {
        sequence = []
        inputScope = nil
        inputOverlay = nil
        bindingScope = nil
        lastInputTime = nil
    }
}
