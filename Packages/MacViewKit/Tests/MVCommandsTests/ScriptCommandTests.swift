import Foundation
import Testing
@testable import MVCommands

@Test @MainActor func unregisterScriptCommands() async throws {
    let registry = CommandRegistry()
    let first = CommandDescriptor(id: CommandID("script.first"), title: .init("first"), category: "script", verbatimTitle: "原始标题")
    let second = CommandDescriptor(id: CommandID("script.second"), title: .init("second"), category: "script")
    registry.register(first, isEnabled: { _ in true }, perform: { _, _ in })
    registry.register(second, isEnabled: { _ in true }, perform: { _, _ in })
    registry.unregister(first.id)
    registry.unregister(first.id)
    #expect(registry.descriptors().map(\.id) == [second.id])
    do { try await registry.perform(first.id, arguments: nil, context: CommandContext(scope: .global)); Issue.record("未登记的命令仍可执行") }
    catch let error as CommandError { #expect(error == .unknownCommand(first.id)) }
    registry.register(first, isEnabled: { _ in true }, perform: { _, _ in })
    #expect(registry.descriptors().map(\.id) == [second.id, first.id])
    #expect(registry.descriptors().last?.verbatimTitle == "原始标题")
}

@Test func defaultScriptMenusAndCommands() throws {
    let roots = CoreCommands.defaultMenu.roots
    let scriptIndex = try #require(roots.firstIndex { if case .submenu("脚本", _) = $0 { true } else { false } })
    let windowIndex = try #require(roots.firstIndex { if case .submenu("窗口", _) = $0 { true } else { false } })
    #expect(scriptIndex + 1 == windowIndex)
    #expect(roots[scriptIndex] == .submenu(titleKey: "脚本", children: [.dynamic(.scripts), .separator, .command(.scriptStopAll), .command(.scriptRevealFolder), .command(.scriptManage)]))
    #expect(CoreCommands.defaultViewerContextMenu.suffix(2) == [.separator, .submenu(titleKey: "脚本", children: [.dynamic(.scripts)])])
    for id in [CommandID.scriptStopAll, .scriptRevealFolder, .scriptManage] {
        let descriptor = try #require(CoreCommands.all.first { $0.id == id })
        #expect(descriptor.category == "script" && descriptor.defaultBindings.isEmpty)
    }
    let legacy = try JSONDecoder().decode(MenuFile.self, from: Data(#"{"viewerContextMenu":[{"command":{"_0":"file.delete"}}]}"#.utf8))
    #expect(legacy.resolvedViewerContextMenu == [.command(.fileDelete)])
}
