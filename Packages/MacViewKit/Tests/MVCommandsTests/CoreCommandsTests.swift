import Foundation
import Testing
@testable import MVCommands

@Test func defaultBindingsHaveNoConflictsAndSupportMacNavigation() {
    let bindings = CoreCommands.all.flatMap(\.defaultBindings)
    #expect(BindingResolver.conflicts(in: bindings).isEmpty)
    var resolver = BindingResolver(bindings: bindings)
    let start = ContinuousClock.now
    #expect(resolver.feed(KeyChord("Right"), scope: .viewer, at: start) == .command(.frameNext, nil))
    #expect(resolver.feed(KeyChord("Space"), scope: .viewer, at: start) == .command(.frameNext, nil))
    #expect(resolver.feed(KeyChord("Space", modifiers: .shift), scope: .viewer, at: start) == .command(.framePrevious, nil))
    #expect(resolver.feed(KeyChord("Right", modifiers: .option), scope: .viewer, at: start) == .command(.pageNext, nil))
    #expect(resolver.feed(KeyChord("o", modifiers: .command), scope: .global, at: start) == .command(.fileOpen, nil))
    #expect(resolver.feed(KeyChord("f", modifiers: [.control, .command]), scope: .viewer, at: start) == .command(.fullScreenToggle, nil))
    #expect(resolver.feed(KeyChord("g"), scope: .viewer, at: start) == .pending([KeyChord("g")]))
    #expect(resolver.feed(KeyChord("g"), scope: .viewer, at: start + .milliseconds(100)) == .command(.pageFirst, nil))
    #expect(resolver.feed(KeyChord("d"), scope: .textInput, at: start) == .unmatched)
}

@Test func p0CommandsHaveTitlesCategoriesAndMenuEntries() {
    let required: [String: [CommandID]] = [
        "page": [.frameNext, .framePrevious, .pageNext, .pagePrevious, .pageFirst, .pageLast, .pageJump],
        "book": [.bookNext, .bookPrevious, .fileOpen, .bookReveal],
        "view": [.browsePaged, .browseWaterfall, .browseVerticalStrip, .browseHorizontalStrip,
                 .pageModeToggle, .readingDirectionToggle, .firstPageSingleToggle,
                 .widePageAsIs, .widePageSingle, .widePageSplit],
        "zoom": [.zoomOriginal, .zoomFitWindow, .zoomFitWidth, .zoomFitHeight, .zoomFill, .zoomFixed,
                 .zoomDevicePixel, .zoomIn, .zoomOut, .zoomAllowUpscaleToggle, .magnifierToggle, .keepZoomOnPageTurnToggle],
        "sort": [.sortName, .sortModified, .sortCreated, .sortSize, .sortType, .sortRandom,
                 .sortAscending, .sortDescending, .sortFoldersFirstToggle, .recursionToggle],
        "window": [.windowNew, .windowNewTab, .fullScreenToggle, .bookshelfToggle, .pageListToggle, .docksToggle],
        "other": [.retryFailed, .settingsOpen],
    ]
    let catalog = CoreCommands.all
    let ids = Set(catalog.map(\.id))
    #expect(ids.count == catalog.count)
    for (category, commands) in required {
        for command in commands {
            #expect(catalog.contains { $0.id == command && $0.category == category })
        }
    }
    let menu = menuCommands(CoreCommands.defaultMenu.roots)
    #expect(Set(menu) == ids)
    #expect(menu.count == ids.count)
    for descriptor in catalog {
        #expect(!String(localized: descriptor.title).isEmpty)
        #expect(!descriptor.category.isEmpty)
        #expect(descriptor.id.rawValue.contains("."))
        #expect(descriptor.defaultBindings.allSatisfy { $0.command == descriptor.id })
    }
    let roots = CoreCommands.defaultMenu.roots.compactMap { node -> String? in
        if case let .submenu(titleKey, _) = node { return titleKey }; return nil
    }
    #expect(roots == ["文件", "显示", "翻页", "书", "窗口"])
}

private func menuCommands(_ nodes: [MenuNode]) -> [CommandID] {
    nodes.flatMap { node -> [CommandID] in
        return switch node {
        case let .command(command): [command]
        case let .submenu(_, children): menuCommands(children)
        case .separator: []
        }
    }
}

@Test func fileOperationCommandsHaveExpectedIDsAndBindings() {
    let expected: [(CommandID, String)] = [(.fileDelete, "file.delete"), (.fileRename, "file.rename"),
        (.fileCopy, "file.copy"), (.fileCopyPath, "file.copyPath"), (.fileReveal, "file.reveal"),
        (.fileOpenWith, "file.openWith"), (.recycleEmpty, "file.recycle.empty"), (.classifyTarget, "classify.target"),
        (.classifyModeToggle, "classify.mode.toggle"), (.classifyNewTarget, "classify.newTarget"),
        (.classifyPanelToggle, "panel.classify.toggle"), (.editUndo, "edit.undo"), (.editRedo, "edit.redo")]
    for (id, raw) in expected {
        #expect(id.rawValue == raw)
        #expect(CoreCommands.all.contains { $0.id == id })
    }
    var resolver = BindingResolver(bindings: CoreCommands.all.flatMap(\.defaultBindings))
    let now = ContinuousClock.now
    for scope in [InputScope.viewer, .list] {
        #expect(resolver.feed(KeyChord("Delete", modifiers: .command), scope: scope, at: now) == .command(.fileDelete, nil))
        #expect(resolver.feed(KeyChord("c", modifiers: .command), scope: scope, at: now) == .command(.fileCopy, nil))
        #expect(resolver.feed(KeyChord("c", modifiers: [.command, .option]), scope: scope, at: now) == .command(.fileCopyPath, nil))
        #expect(resolver.feed(KeyChord("z", modifiers: .command), scope: scope, at: now) == .command(.editUndo, nil))
        #expect(resolver.feed(KeyChord("z", modifiers: [.command, .shift]), scope: scope, at: now) == .command(.editRedo, nil))
    }
    #expect(resolver.feed(KeyChord("r", modifiers: [.command, .shift]), scope: .list, at: now) == .command(.fileReveal, nil))
    // 此键与现有递归切换冲突：viewer 暂保留原绑定，等待设计侧决议。
    #expect(resolver.feed(KeyChord("r", modifiers: [.command, .shift]), scope: .viewer, at: now) == .command(.recursionToggle, nil))
}
