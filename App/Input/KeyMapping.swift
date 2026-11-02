import AppKit
import Carbon.HIToolbox
import MVCommands

/// AppKit 按键与 Core 逻辑键名（`KeyChord.key`）之间的换算。
///
/// 逻辑键名：字母为小写，数字与标点为不带修饰键时键盘产出的字符，其余键用 `Right`、`Space` 这样的名称。
enum KeyMapping {
    private struct NamedKey {
        var name: String
        var keyCode: Int
        /// 菜单快捷键用的字符（NSMenuItem.keyEquivalent）。
        var menuCharacter: Character
        /// 显示用的符号；nil 时显示本地化的键名。
        var symbol: String?
    }

    private static func function(_ code: Int) -> Character {
        Character(UnicodeScalar(UInt16(code))!)
    }

    private static let namedKeys: [NamedKey] = [
        NamedKey(name: "Left", keyCode: kVK_LeftArrow, menuCharacter: function(NSLeftArrowFunctionKey), symbol: "←"),
        NamedKey(name: "Right", keyCode: kVK_RightArrow, menuCharacter: function(NSRightArrowFunctionKey), symbol: "→"),
        NamedKey(name: "Up", keyCode: kVK_UpArrow, menuCharacter: function(NSUpArrowFunctionKey), symbol: "↑"),
        NamedKey(name: "Down", keyCode: kVK_DownArrow, menuCharacter: function(NSDownArrowFunctionKey), symbol: "↓"),
        NamedKey(name: "Home", keyCode: kVK_Home, menuCharacter: function(NSHomeFunctionKey), symbol: "↖"),
        NamedKey(name: "End", keyCode: kVK_End, menuCharacter: function(NSEndFunctionKey), symbol: "↘"),
        NamedKey(name: "PageUp", keyCode: kVK_PageUp, menuCharacter: function(NSPageUpFunctionKey), symbol: "⇞"),
        NamedKey(name: "PageDown", keyCode: kVK_PageDown, menuCharacter: function(NSPageDownFunctionKey), symbol: "⇟"),
        NamedKey(name: "Space", keyCode: kVK_Space, menuCharacter: " ", symbol: nil),
        NamedKey(name: "Tab", keyCode: kVK_Tab, menuCharacter: "\t", symbol: "⇥"),
        NamedKey(name: "Return", keyCode: kVK_Return, menuCharacter: "\r", symbol: "↩"),
        NamedKey(name: "Return", keyCode: kVK_ANSI_KeypadEnter, menuCharacter: "\r", symbol: "↩"),
        NamedKey(name: "Escape", keyCode: kVK_Escape, menuCharacter: "\u{1B}", symbol: "⎋"),
        NamedKey(name: "Delete", keyCode: kVK_Delete, menuCharacter: "\u{8}", symbol: "⌫"),
        NamedKey(name: "ForwardDelete", keyCode: kVK_ForwardDelete, menuCharacter: function(NSDeleteFunctionKey), symbol: "⌦"),
    ] + zip(1...12, [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]).map { number, code in
        NamedKey(name: "F\(number)", keyCode: code, menuCharacter: function(NSF1FunctionKey + number - 1), symbol: "F\(number)")
    }

    /// 修饰键与 AppKit 标志的对应。
    private static let modifierFlags: [(KeyModifiers, NSEvent.ModifierFlags)] = [
        (.command, .command), (.option, .option), (.control, .control), (.shift, .shift), (.function, .function),
    ]

    private static let byKeyCode = Dictionary(namedKeys.map { ($0.keyCode, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byName = Dictionary(namedKeys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// 按下的键；修饰键本身、死键等没有逻辑键名的事件返回 nil。
    static func chord(for event: NSEvent) -> KeyChord? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = KeyModifiers()
        for (modifier, flag) in modifierFlags where modifier != .function && flags.contains(flag) {
            modifiers.insert(modifier)
        }
        if let named = byKeyCode[Int(event.keyCode)] {
            // 方向键、Home 等自带 function 标志，不算修饰键。
            return KeyChord(named.name, modifiers: modifiers)
        }
        if flags.contains(.function) { modifiers.insert(.function) }
        guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1 else { return nil }
        return KeyChord(characters.lowercased(), modifiers: modifiers)
    }

    /// 菜单项的快捷键字符与修饰键；无法表示的键返回 nil。
    static func menuKeyEquivalent(for chord: KeyChord) -> (key: String, mask: NSEvent.ModifierFlags)? {
        let key: String
        if let named = byName[chord.key] {
            key = String(named.menuCharacter)
        } else if chord.key.count == 1 {
            key = chord.key
        } else {
            return nil
        }
        var mask = NSEvent.ModifierFlags()
        for (modifier, flag) in modifierFlags where chord.modifiers.contains(modifier) {
            mask.insert(flag)
        }
        return (key, mask)
    }

    /// 键帽上的文字，例如 `⌘⇧J`、`G`、`空格`。
    static func displayName(for chord: KeyChord) -> String {
        var text = ""
        if chord.modifiers.contains(.function) { text += "fn " }
        if chord.modifiers.contains(.control) { text += "⌃" }
        if chord.modifiers.contains(.option) { text += "⌥" }
        if chord.modifiers.contains(.shift) { text += "⇧" }
        if chord.modifiers.contains(.command) { text += "⌘" }
        if let named = byName[chord.key] {
            text += named.symbol ?? String(localized: "空格")
        } else {
            text += chord.key.uppercased()
        }
        return text
    }
}
