import Foundation
import MVFoundation
import Testing
@testable import MVCommands

@Test func twoKeySequencesMatchWithinTheDefaultTimeoutAndResetAfterIt() {
    let g = KeyChord("g")
    let e = KeyChord("e")
    let space = KeyChord("Space")
    let arguments: [String: JSONValue] = ["index": .number(42)]
    var resolver = BindingResolver(bindings: [
        KeyBinding(sequence: [g, g], command: .pageFirst, scope: .viewer),
        KeyBinding(sequence: [g, e], command: .pageJump, arguments: arguments, scope: .viewer),
        KeyBinding(sequence: [space], command: .frameNext, scope: .viewer),
    ])
    let start = ContinuousClock.now
    #expect(resolver.feed(g, scope: .viewer, at: start) == .pending([g]))
    #expect(resolver.feed(e, scope: .viewer, at: start + .milliseconds(999)) == .command(.pageJump, arguments))
    #expect(resolver.feed(g, scope: .viewer, at: start + .seconds(2)) == .pending([g]))
    #expect(resolver.feed(e, scope: .viewer, at: start + .seconds(3)) == .unmatched)
    #expect(resolver.feed(g, scope: .viewer, at: start + .seconds(4)) == .pending([g]))
    #expect(resolver.feed(g, scope: .viewer, at: start + .milliseconds(4500)) == .command(.pageFirst, nil))
    // 续键失配后仍作为新的首键处理，不吞掉本来可执行的单键。
    #expect(resolver.feed(g, scope: .viewer, at: start + .seconds(5)) == .pending([g]))
    #expect(resolver.feed(space, scope: .viewer, at: start + .milliseconds(5100)) == .command(.frameNext, nil))
}

@Test func scopePrefixesWinAndTextInputAcceptsOnlyItsExplicitBindings() {
    let a = KeyChord("a")
    let b = KeyChord("b")
    let x = KeyChord("x")
    let global = CommandID("test.global")
    let viewer = CommandID("test.viewer")
    let text = CommandID("test.text")
    var resolver = BindingResolver(bindings: [
        KeyBinding(sequence: [a], command: global),
        KeyBinding(sequence: [a, b], command: viewer, scope: .viewer),
        KeyBinding(sequence: [x], command: text, scope: .textInput),
    ])
    let start = ContinuousClock.now
    #expect(resolver.feed(a, scope: .viewer, at: start) == .pending([a]))
    #expect(resolver.feed(b, scope: .viewer, at: start + .milliseconds(100)) == .command(viewer, nil))
    #expect(resolver.feed(a, scope: .list, at: start) == .command(global, nil))
    #expect(resolver.feed(a, scope: .textInput, at: start) == .unmatched)
    #expect(resolver.feed(x, scope: .textInput, at: start) == .command(text, nil))
    #expect(resolver.feed(a, scope: .viewer, at: start) == .pending([a]))
    #expect(resolver.feed(b, scope: .textInput, at: start + .milliseconds(100)) == .unmatched)
}

@Test func conflictsIncludeEqualSequencesAndPrefixesOnlyInTheSameScope() {
    let first = KeyBinding(sequence: [KeyChord("g")], command: .pageFirst, scope: .viewer)
    let duplicate = KeyBinding(sequence: first.sequence, command: .pageJump, scope: .viewer)
    let longer = KeyBinding(sequence: [KeyChord("g"), KeyChord("g")], command: .pageLast, scope: .viewer)
    let otherScope = KeyBinding(sequence: first.sequence, command: .bookNext, scope: .list)
    let disabled = KeyBinding(sequence: [], command: .fileOpen, scope: .viewer)
    #expect(BindingResolver.conflicts(in: [first, duplicate, longer, otherScope, disabled]) == [
        BindingConflict(scope: .viewer, first: first, second: duplicate),
        BindingConflict(scope: .viewer, first: first, second: longer),
        BindingConflict(scope: .viewer, first: duplicate, second: longer),
    ])
}

@Test func userBindingsReplaceAllDefaultsForTheirCommandAndRoundTripAsAFileValue() throws {
    let open = KeyBinding(sequence: [KeyChord("o", modifiers: .command)], command: .fileOpen)
    let alternate = KeyBinding(sequence: [KeyChord("o")], command: .fileOpen, scope: .viewer)
    let newWindow = KeyBinding(sequence: [KeyChord("n", modifiers: .command)], command: .windowNew)
    let settings = KeyBinding(sequence: [KeyChord(",", modifiers: .command)], command: .settingsOpen)
    let defaults = [
        CommandDescriptor(id: .fileOpen, title: "打开", category: "book", defaultBindings: [open, alternate]),
        CommandDescriptor(id: .windowNew, title: "新建窗口", category: "window", defaultBindings: [newWindow]),
        CommandDescriptor(id: .settingsOpen, title: "设置", category: "other", defaultBindings: [settings]),
    ]
    let user = [
        KeyBinding(sequence: [KeyChord("k"), KeyChord("o")], command: .fileOpen, arguments: ["newWindow": .bool(true)]),
        KeyBinding(sequence: [], command: .settingsOpen),
    ]
    let effective = KeyBinding.effective(defaults: defaults, user: user)
    #expect(effective == [newWindow] + user)
    let file = KeyBindingsFile(bindings: user)
    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(KeyBindingsFile.self, from: data) == file)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["bindings"])
    var resolver = BindingResolver(bindings: effective)
    #expect(resolver.feed(KeyChord(",", modifiers: .command), scope: .viewer, at: ContinuousClock.now) == .unmatched)
}
