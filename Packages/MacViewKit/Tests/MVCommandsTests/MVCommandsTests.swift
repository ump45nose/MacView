import Foundation
import MVFoundation
import Testing
@testable import MVCommands

@MainActor
private final class Recorder {
    var enabled = true
    var calls: [[String: JSONValue]?] = []
}

@MainActor
struct CommandRegistryTests {
    @Test func performsOnlyRegisteredAndEnabledCommands() async throws {
        let registry = CommandRegistry()
        let recorder = Recorder()
        let next = CommandID("page.next")
        registry.register(
            CommandDescriptor(id: next, title: "下一页", category: "page"),
            isEnabled: { _ in recorder.enabled },
            perform: { _, arguments in recorder.calls.append(arguments) }
        )
        let context = CommandContext(scope: .viewer)
        try await registry.perform(next, arguments: ["count": .number(2)], context: context)
        #expect(recorder.calls == [["count": .number(2)]])

        recorder.enabled = false
        #expect(!registry.isEnabled(next, context: context))
        await #expect(throws: CommandError.disabled(next)) {
            try await registry.perform(next, arguments: nil, context: context)
        }
        await #expect(throws: CommandError.unknownCommand(CommandID("none"))) {
            try await registry.perform(CommandID("none"), arguments: nil, context: context)
        }
    }

    @Test func registeringAgainReplacesTheHandlerAndKeepsTheOrder() async throws {
        let registry = CommandRegistry()
        let recorder = Recorder()
        let first = CommandID("a")
        let second = CommandID("b")
        registry.register(CommandDescriptor(id: first, title: "A", category: "x"), isEnabled: { _ in true }, perform: { _, _ in recorder.calls.append(["v": .number(1)]) })
        registry.register(CommandDescriptor(id: second, title: "B", category: "x"), isEnabled: { _ in true }, perform: { _, _ in })
        registry.register(CommandDescriptor(id: first, title: "A", category: "x"), isEnabled: { _ in true }, perform: { _, _ in recorder.calls.append(["v": .number(2)]) })
        try await registry.perform(first, arguments: nil, context: CommandContext(scope: .global))
        #expect(recorder.calls == [["v": .number(2)]])
        #expect(registry.descriptors().map(\.id) == [first, second])
    }
}

@Test func scopeBindingsWinAndTextInputDoesNotFallBackToGlobal() {
    let right = KeyChord("Right")
    var resolver = BindingResolver(bindings: [
        KeyBinding(sequence: [right], command: CommandID("book.next"), scope: .global),
        KeyBinding(sequence: [right], command: CommandID("page.next"), scope: .viewer),
    ], sequenceTimeout: .seconds(1))
    let now = ContinuousClock.now
    #expect(resolver.feed(right, scope: .viewer, at: now) == .command(CommandID("page.next"), nil))
    #expect(resolver.feed(right, scope: .list, at: now) == .command(CommandID("book.next"), nil))
    #expect(resolver.feed(right, scope: .textInput, at: now) == .unmatched)
    #expect(resolver.feed(KeyChord("Right", modifiers: .shift), scope: .viewer, at: now) == .unmatched)
}

/// keybindings.json 中命令是字符串，修饰键是位掩码。
@Test func bindingJSONUsesPlainValues() throws {
    let binding = KeyBinding(sequence: [KeyChord("a", modifiers: [.command, .shift])], command: CommandID("file.open"), arguments: ["new": .bool(true)])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = String(decoding: try encoder.encode(binding), as: UTF8.self)
    #expect(json == #"{"arguments":{"new":true},"command":"file.open","scope":"global","sequence":[{"key":"a","modifiers":9}]}"#)
    #expect(try JSONDecoder().decode(KeyBinding.self, from: Data(json.utf8)) == binding)
}

@Test func menuModelRoundTrips() throws {
    let menu = MenuModel(roots: [.submenu(titleKey: "menu.view", children: [.command(CommandID("view.waterfall")), .separator])])
    #expect(try JSONDecoder().decode(MenuModel.self, from: JSONEncoder().encode(menu)) == menu)
}
