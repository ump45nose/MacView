import Foundation
import MVFoundation

public enum PointerDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case up, down, left, right
}

public struct MouseGestureBinding: Codable, Sendable, Hashable {
    /// 1…4 个方向，相邻不重复。
    public var directions: [PointerDirection]
    /// `nil` 表示取消默认绑定。
    public var command: CommandID?
    public var arguments: [String: JSONValue]?

    public init(
        directions: [PointerDirection],
        command: CommandID?,
        arguments: [String: JSONValue]? = nil
    ) {
        self.directions = directions
        self.command = command
        self.arguments = arguments
    }
}

public enum TrackpadInput: String, Codable, Sendable, Hashable, CaseIterable {
    case swipeLeft, swipeRight, doubleTap, rotateLeft, rotateRight
}

public struct TrackpadBinding: Codable, Sendable, Hashable {
    public var input: TrackpadInput
    /// `nil` 表示取消默认绑定。
    public var command: CommandID?
    public var arguments: [String: JSONValue]?

    public init(
        input: TrackpadInput,
        command: CommandID?,
        arguments: [String: JSONValue]? = nil
    ) {
        self.input = input
        self.command = command
        self.arguments = arguments
    }
}

public enum ClickZone: String, Codable, Sendable, Hashable, CaseIterable {
    case left, center, right
}

public struct ClickZoneBinding: Codable, Sendable, Hashable {
    public var zone: ClickZone
    /// `nil` 表示取消默认绑定。
    public var command: CommandID?
    public var arguments: [String: JSONValue]?

    public init(
        zone: ClickZone,
        command: CommandID?,
        arguments: [String: JSONValue]? = nil
    ) {
        self.zone = zone
        self.command = command
        self.arguments = arguments
    }
}

public enum WheelDevice: String, Codable, Sendable, Hashable, CaseIterable {
    case mouse, trackpad
}

public enum WheelAction: Codable, Sendable, Hashable {
    /// 内容超出时滚动，否则鼠标滚轮翻页（现有行为）。
    case standard
    case zoom
    case commands(up: CommandID, down: CommandID)
    case none
}

public struct WheelBinding: Codable, Sendable, Hashable {
    public var device: WheelDevice
    public var modifiers: KeyModifiers
    public var action: WheelAction

    public init(device: WheelDevice, modifiers: KeyModifiers = [], action: WheelAction) {
        self.device = device
        self.modifiers = modifiers
        self.action = action
    }
}

public struct InputBindingDefaults: Sendable, Hashable {
    public var mouseGestures: [MouseGestureBinding]
    public var trackpad: [TrackpadBinding]
    public var clickZones: [ClickZoneBinding]
    public var wheel: [WheelBinding]

    public init(
        mouseGestures: [MouseGestureBinding] = [],
        trackpad: [TrackpadBinding] = [],
        clickZones: [ClickZoneBinding] = [],
        wheel: [WheelBinding] = []
    ) {
        self.mouseGestures = mouseGestures
        self.trackpad = trackpad
        self.clickZones = clickZones
        self.wheel = wheel
    }

    public static let standard = InputBindingDefaults(
        mouseGestures: [
            MouseGestureBinding(directions: [.left], command: .frameLeft),
            MouseGestureBinding(directions: [.right], command: .frameRight),
            MouseGestureBinding(directions: [.up], command: .fullScreenToggle),
            MouseGestureBinding(directions: [.down, .right], command: .bookNext),
            MouseGestureBinding(directions: [.down, .left], command: .bookPrevious),
        ],
        trackpad: [
            TrackpadBinding(input: .swipeLeft, command: .frameLeft),
            TrackpadBinding(input: .swipeRight, command: .frameRight),
        ],
        clickZones: [
            ClickZoneBinding(zone: .left, command: .frameLeft),
            ClickZoneBinding(zone: .right, command: .frameRight),
        ],
        wheel: [
            WheelBinding(device: .mouse, modifiers: [], action: .standard),
            WheelBinding(device: .mouse, modifiers: .command, action: .zoom),
            WheelBinding(device: .trackpad, modifiers: [], action: .standard),
            WheelBinding(device: .trackpad, modifiers: .command, action: .zoom),
        ]
    )
}

/// 编辑器用：同一输入出现多次的冲突条目。
public enum InputConflict: Sendable, Hashable {
    case key(BindingConflict)
    case mouseGesture(first: MouseGestureBinding, second: MouseGestureBinding)
    case trackpad(first: TrackpadBinding, second: TrackpadBinding)
    case clickZone(first: ClickZoneBinding, second: ClickZoneBinding)
    case wheel(first: WheelBinding, second: WheelBinding)
}

/// 生效的非键盘输入绑定：默认值叠加用户覆盖（同一输入用户的替换默认的）。
public struct InputBindings: Sendable, Hashable {
    private struct CommandAction: Sendable, Hashable {
        var command: CommandID
        var arguments: [String: JSONValue]?
    }

    private struct WheelKey: Sendable, Hashable {
        var device: WheelDevice
        var modifiers: KeyModifiers
    }

    private var mouseGestures: [[PointerDirection]: CommandAction]
    private var trackpad: [TrackpadInput: CommandAction]
    private var clickZones: [ClickZone: CommandAction]
    private var wheel: [WheelKey: WheelAction]

    public static func effective(
        defaults: InputBindingDefaults = .standard,
        user: KeyBindingsFile
    ) -> InputBindings {
        var mouseGestures: [[PointerDirection]: CommandAction] = [:]
        for binding in defaults.mouseGestures where !binding.directions.isEmpty {
            if let command = binding.command {
                mouseGestures[binding.directions] = CommandAction(command: command, arguments: binding.arguments)
            }
        }
        var seenGestures: Set<[PointerDirection]> = []
        for binding in user.mouseGestures ?? [] where !binding.directions.isEmpty {
            guard seenGestures.insert(binding.directions).inserted else { continue }
            if let command = binding.command {
                mouseGestures[binding.directions] = CommandAction(command: command, arguments: binding.arguments)
            } else {
                mouseGestures.removeValue(forKey: binding.directions)
            }
        }

        var trackpad: [TrackpadInput: CommandAction] = [:]
        for binding in defaults.trackpad {
            if let command = binding.command {
                trackpad[binding.input] = CommandAction(command: command, arguments: binding.arguments)
            }
        }
        var seenTrackpad: Set<TrackpadInput> = []
        for binding in user.trackpad ?? [] {
            guard seenTrackpad.insert(binding.input).inserted else { continue }
            if let command = binding.command {
                trackpad[binding.input] = CommandAction(command: command, arguments: binding.arguments)
            } else {
                trackpad.removeValue(forKey: binding.input)
            }
        }

        var clickZones: [ClickZone: CommandAction] = [:]
        for binding in defaults.clickZones {
            if let command = binding.command {
                clickZones[binding.zone] = CommandAction(command: command, arguments: binding.arguments)
            }
        }
        var seenClickZones: Set<ClickZone> = []
        for binding in user.clickZones ?? [] {
            guard seenClickZones.insert(binding.zone).inserted else { continue }
            if let command = binding.command {
                clickZones[binding.zone] = CommandAction(command: command, arguments: binding.arguments)
            } else {
                clickZones.removeValue(forKey: binding.zone)
            }
        }

        var wheel: [WheelKey: WheelAction] = [:]
        for binding in defaults.wheel {
            wheel[WheelKey(device: binding.device, modifiers: binding.modifiers)] = binding.action
        }
        var seenWheel: Set<WheelKey> = []
        for binding in user.wheel ?? [] {
            let key = WheelKey(device: binding.device, modifiers: binding.modifiers)
            guard seenWheel.insert(key).inserted else { continue }
            wheel[key] = binding.action
        }

        return InputBindings(
            mouseGestures: mouseGestures,
            trackpad: trackpad,
            clickZones: clickZones,
            wheel: wheel
        )
    }

    public func command(forGesture directions: [PointerDirection]) -> (CommandID, [String: JSONValue]?)? {
        guard let action = mouseGestures[directions] else { return nil }
        return (action.command, action.arguments)
    }

    public func command(for input: TrackpadInput) -> (CommandID, [String: JSONValue]?)? {
        guard let action = trackpad[input] else { return nil }
        return (action.command, action.arguments)
    }

    public func command(for zone: ClickZone) -> (CommandID, [String: JSONValue]?)? {
        guard let action = clickZones[zone] else { return nil }
        return (action.command, action.arguments)
    }

    /// 没有绑定的修饰键组合回到该设备无修饰键的动作。
    public func wheelAction(device: WheelDevice, modifiers: KeyModifiers) -> WheelAction {
        if let action = wheel[WheelKey(device: device, modifiers: modifiers)] {
            return action
        }
        if !modifiers.isEmpty, let fallback = wheel[WheelKey(device: device, modifiers: [])] {
            return fallback
        }
        return .none
    }

    /// 编辑器用：同一输入出现多次的条目，每对返回一次，顺序与文件一致。
    public static func conflicts(in file: KeyBindingsFile) -> [InputConflict] {
        var result: [InputConflict] = BindingResolver.conflicts(in: file.bindings).map(InputConflict.key)

        let gestures = file.mouseGestures ?? []
        for (index, first) in gestures.enumerated() where !first.directions.isEmpty {
            for second in gestures.dropFirst(index + 1) where second.directions == first.directions {
                result.append(.mouseGesture(first: first, second: second))
            }
        }

        let trackpad = file.trackpad ?? []
        for (index, first) in trackpad.enumerated() {
            for second in trackpad.dropFirst(index + 1) where second.input == first.input {
                result.append(.trackpad(first: first, second: second))
            }
        }

        let clickZones = file.clickZones ?? []
        for (index, first) in clickZones.enumerated() {
            for second in clickZones.dropFirst(index + 1) where second.zone == first.zone {
                result.append(.clickZone(first: first, second: second))
            }
        }

        let wheel = file.wheel ?? []
        for (index, first) in wheel.enumerated() {
            for second in wheel.dropFirst(index + 1)
                where second.device == first.device && second.modifiers == first.modifiers {
                result.append(.wheel(first: first, second: second))
            }
        }

        return result
    }
}
