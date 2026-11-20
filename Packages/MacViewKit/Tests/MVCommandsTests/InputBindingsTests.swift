import Foundation
import MVFoundation
import Testing
@testable import MVCommands

@Test("C1.1 v1 文件（只有 bindings）读入后各非键盘输入取默认值")
func v1KeyBindingsFileUsesStandardInputDefaults() throws {
    let v1JSON = #"{"bindings":[{"command":"file.open","scope":"global","sequence":[{"key":"o","modifiers":1}]}]}"#
    let file = try JSONDecoder().decode(KeyBindingsFile.self, from: Data(v1JSON.utf8))
    #expect(file.bindings.count == 1)
    #expect(file.mouseGestures == nil)
    #expect(file.trackpad == nil)
    #expect(file.clickZones == nil)
    #expect(file.wheel == nil)

    let effective = InputBindings.effective(defaults: .standard, user: file)

    #expect(effective.command(forGesture: [.left])?.0 == .frameLeft)
    #expect(effective.command(forGesture: [.right])?.0 == .frameRight)
    #expect(effective.command(forGesture: [.up])?.0 == .fullScreenToggle)
    #expect(effective.command(forGesture: [.down, .right])?.0 == .bookNext)
    #expect(effective.command(forGesture: [.down, .left])?.0 == .bookPrevious)
    #expect(effective.command(forGesture: [.down]) == nil)

    #expect(effective.command(for: .swipeLeft)?.0 == .frameLeft)
    #expect(effective.command(for: .swipeRight)?.0 == .frameRight)
    #expect(effective.command(for: .doubleTap) == nil)
    #expect(effective.command(for: .rotateLeft) == nil)
    #expect(effective.command(for: .rotateRight) == nil)

    #expect(effective.command(for: .left)?.0 == .frameLeft)
    #expect(effective.command(for: .right)?.0 == .frameRight)
    #expect(effective.command(for: .center) == nil)

    #expect(effective.wheelAction(device: .mouse, modifiers: []) == .standard)
    #expect(effective.wheelAction(device: .mouse, modifiers: .command) == .zoom)
    #expect(effective.wheelAction(device: .trackpad, modifiers: []) == .standard)
    #expect(effective.wheelAction(device: .trackpad, modifiers: .command) == .zoom)
}

@Test("C1.1 用户覆盖替换同一输入的默认值，command == nil 取消默认")
func userOverridesReplaceAndCancelDefaults() {
    let args: [String: JSONValue] = ["slot": .number(1)]
    let user = KeyBindingsFile(
        mouseGestures: [
            MouseGestureBinding(directions: [.left], command: .pageNext, arguments: args),
            MouseGestureBinding(directions: [.up], command: nil),
            MouseGestureBinding(directions: [.right, .down], command: .zoomFitWindow),
        ],
        trackpad: [
            TrackpadBinding(input: .swipeLeft, command: nil),
            TrackpadBinding(input: .doubleTap, command: .zoomOriginal, arguments: args),
        ],
        clickZones: [
            ClickZoneBinding(zone: .right, command: nil),
            ClickZoneBinding(zone: .center, command: .fullScreenToggle),
        ],
        wheel: [
            WheelBinding(device: .mouse, modifiers: .option, action: .commands(up: .bookPrevious, down: .bookNext)),
            WheelBinding(device: .trackpad, modifiers: .command, action: .none),
        ]
    )

    let effective = InputBindings.effective(defaults: .standard, user: user)

    // 鼠标手势：替换、取消、新增、未改保留默认
    let leftGesture = effective.command(forGesture: [.left])
    #expect(leftGesture?.0 == .pageNext)
    #expect(leftGesture?.1 == args)
    #expect(effective.command(forGesture: [.up]) == nil)
    #expect(effective.command(forGesture: [.right, .down])?.0 == .zoomFitWindow)
    #expect(effective.command(forGesture: [.right])?.0 == .frameRight)

    // 触控板：取消、新增、未改保留默认
    #expect(effective.command(for: .swipeLeft) == nil)
    #expect(effective.command(for: .swipeRight)?.0 == .frameRight)
    let doubleTap = effective.command(for: .doubleTap)
    #expect(doubleTap?.0 == .zoomOriginal)
    #expect(doubleTap?.1 == args)

    // 点击区域：取消、新增、未改保留默认
    #expect(effective.command(for: .left)?.0 == .frameLeft)
    #expect(effective.command(for: .right) == nil)
    #expect(effective.command(for: .center)?.0 == .fullScreenToggle)

    // 滚轮：新增修饰键、覆盖默认
    #expect(effective.wheelAction(device: .mouse, modifiers: .option) == .commands(up: .bookPrevious, down: .bookNext))
    #expect(effective.wheelAction(device: .trackpad, modifiers: .command) == .none)
    #expect(effective.wheelAction(device: .mouse, modifiers: .command) == .zoom)
}

@Test("C1.1 滚轮未绑定的修饰键回到该设备无修饰键动作")
func wheelUnboundModifiersFallBackToUnmodifiedAction() {
    let defaultsOnly = InputBindings.effective(defaults: .standard, user: KeyBindingsFile())
    #expect(defaultsOnly.wheelAction(device: .mouse, modifiers: .option) == .standard)
    #expect(defaultsOnly.wheelAction(device: .mouse, modifiers: [.shift, .control]) == .standard)
    #expect(defaultsOnly.wheelAction(device: .trackpad, modifiers: .shift) == .standard)

    // 修改单个设备的无修饰键动作，未绑定的修饰键跟随该设备的新无修饰键动作，不影响另一设备。
    let user = KeyBindingsFile(
        wheel: [
            WheelBinding(device: .mouse, modifiers: [], action: .commands(up: .pagePrevious, down: .pageNext)),
            WheelBinding(device: .trackpad, modifiers: [], action: .none),
        ]
    )
    let effective = InputBindings.effective(defaults: .standard, user: user)
    #expect(effective.wheelAction(device: .mouse, modifiers: .option) == .commands(up: .pagePrevious, down: .pageNext))
    #expect(effective.wheelAction(device: .mouse, modifiers: .command) == .zoom)
    #expect(effective.wheelAction(device: .trackpad, modifiers: .option) == .none)
    #expect(effective.wheelAction(device: .trackpad, modifiers: .command) == .zoom)

    // 空默认且无用户绑定时返回 .none。
    let empty = InputBindings.effective(defaults: InputBindingDefaults(), user: KeyBindingsFile())
    #expect(empty.wheelAction(device: .mouse, modifiers: []) == .none)
    #expect(empty.wheelAction(device: .mouse, modifiers: .option) == .none)
}

@Test("C1.1 冲突检测找出重复输入，且按文件顺序首项生效")
func conflictDetectionFindsDuplicateInputsAcrossAllCategories() {
    let key1 = KeyBinding(sequence: [KeyChord("g")], command: .pageFirst, scope: .viewer)
    let key2 = KeyBinding(sequence: [KeyChord("g"), KeyChord("g")], command: .pageLast, scope: .viewer)
    let gesture1 = MouseGestureBinding(directions: [.down, .left], command: .bookPrevious)
    let gesture2 = MouseGestureBinding(directions: [.down, .left], command: .bookNext)
    let emptyGesture1 = MouseGestureBinding(directions: [], command: .pageNext)
    let emptyGesture2 = MouseGestureBinding(directions: [], command: .pagePrevious)
    let trackpad1 = TrackpadBinding(input: .rotateLeft, command: .pagePrevious)
    let trackpad2 = TrackpadBinding(input: .rotateLeft, command: .bookPrevious)
    let zone1 = ClickZoneBinding(zone: .center, command: .fullScreenToggle)
    let zone2 = ClickZoneBinding(zone: .center, command: nil)
    let wheel1 = WheelBinding(device: .mouse, modifiers: .option, action: .zoom)
    let wheel2 = WheelBinding(device: .mouse, modifiers: .option, action: .none)
    let wheelOtherDevice = WheelBinding(device: .trackpad, modifiers: .option, action: .zoom)

    let file = KeyBindingsFile(
        bindings: [key1, key2],
        mouseGestures: [gesture1, gesture2, emptyGesture1, emptyGesture2],
        trackpad: [trackpad1, trackpad2],
        clickZones: [zone1, zone2],
        wheel: [wheel1, wheelOtherDevice, wheel2]
    )

    let conflicts = InputBindings.conflicts(in: file)
    #expect(conflicts == [
        .key(BindingConflict(scope: .viewer, first: key1, second: key2)),
        .mouseGesture(first: gesture1, second: gesture2),
        .trackpad(first: trackpad1, second: trackpad2),
        .clickZone(first: zone1, second: zone2),
        .wheel(first: wheel1, second: wheel2),
    ])

    // 冲突条目按文件顺序取首项。
    let effective = InputBindings.effective(defaults: .standard, user: file)
    #expect(effective.command(forGesture: [.down, .left])?.0 == .bookPrevious)
    #expect(effective.command(for: .rotateLeft)?.0 == .pagePrevious)
    #expect(effective.command(for: .center)?.0 == .fullScreenToggle)
    #expect(effective.wheelAction(device: .mouse, modifiers: .option) == .zoom)
}

@Test("KeyBindingsFile v2 完整编解码往返，且默认配置无冲突")
func keyBindingsFileV2RoundTripsAndStandardDefaultsHaveNoConflicts() throws {
    let standardAsFile = KeyBindingsFile(
        bindings: CoreCommands.all.flatMap(\.defaultBindings),
        mouseGestures: InputBindingDefaults.standard.mouseGestures,
        trackpad: InputBindingDefaults.standard.trackpad,
        clickZones: InputBindingDefaults.standard.clickZones,
        wheel: InputBindingDefaults.standard.wheel
    )
    #expect(InputBindings.conflicts(in: standardAsFile).isEmpty)

    let v2 = KeyBindingsFile(
        bindings: [KeyBinding(sequence: [KeyChord("k")], command: .framePrevious, scope: .viewer)],
        mouseGestures: [
            MouseGestureBinding(directions: [.left], command: .frameLeft),
            MouseGestureBinding(directions: [.up], command: nil),
        ],
        trackpad: [
            TrackpadBinding(input: .doubleTap, command: .zoomFitWindow, arguments: ["animated": .bool(false)]),
        ],
        clickZones: [
            ClickZoneBinding(zone: .center, command: .fullScreenToggle),
        ],
        wheel: [
            WheelBinding(device: .mouse, modifiers: .option, action: .commands(up: .pagePrevious, down: .pageNext)),
            WheelBinding(device: .trackpad, modifiers: .command, action: .zoom),
        ]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(v2)
    let decoded = try JSONDecoder().decode(KeyBindingsFile.self, from: data)
    #expect(decoded == v2)
}
