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
        #expect(resolver.feed(KeyChord("r", modifiers: [.command, .option]), scope: scope, at: now) == .command(.fileReveal, nil))
        #expect(resolver.feed(KeyChord("z", modifiers: .command), scope: scope, at: now) == .command(.editUndo, nil))
        #expect(resolver.feed(KeyChord("z", modifiers: [.command, .shift]), scope: scope, at: now) == .command(.editRedo, nil))
    }
    #expect(resolver.feed(KeyChord("r", modifiers: [.command, .shift]), scope: .list, at: now) == .unmatched)
    #expect(resolver.feed(KeyChord("r", modifiers: [.command, .shift]), scope: .viewer, at: now) == .command(.recursionToggle, nil))
}

@Test("C1.13 资料库默认键无冲突，加入命令在书菜单，面板开关在窗口菜单")
func libraryCommandsHaveBindingsAndMenuPositions() throws {
    let bindings = CoreCommands.all.flatMap(\.defaultBindings)
    #expect(BindingResolver.conflicts(in: bindings).isEmpty)
    var resolver = BindingResolver(bindings: bindings)
    let now = ContinuousClock.now
    for scope in [InputScope.viewer, .list] {
        #expect(resolver.feed(KeyChord("d", modifiers: .command), scope: scope, at: now) == .command(.bookmarkAdd, nil))
        #expect(resolver.feed(KeyChord("l", modifiers: .command), scope: scope, at: now) == .command(.playlistAddCurrent, nil))
        for (key, command) in [("4", CommandID.historyToggle), ("5", .bookmarksToggle), ("6", .playlistToggle)] {
            #expect(resolver.feed(KeyChord(key, modifiers: [.command, .option]), scope: scope, at: now) == .command(command, nil))
        }
    }
    #expect(CoreCommands.all.first { $0.id == .playlistRemoveItem }?.defaultBindings.isEmpty == true)
    let bookMenu = try #require(CoreCommands.defaultMenu.roots.first { if case .submenu("书", _) = $0 { true } else { false } })
    let windowMenu = try #require(CoreCommands.defaultMenu.roots.first { if case .submenu("窗口", _) = $0 { true } else { false } })
    #expect(Set(menuCommands([bookMenu])).isSuperset(of: [.bookmarkAdd, .playlistAddCurrent, .playlistRemoveItem]))
    #expect(Set(menuCommands([windowMenu])).isSuperset(of: [.historyToggle, .bookmarksToggle, .playlistToggle]))
    #expect(CommandID.bookmarkAdd.rawValue == "library.bookmark.add")
    #expect(CommandID.playlistAddCurrent.rawValue == "library.playlist.addCurrent")
    #expect(CommandID.playlistRemoveItem.rawValue == "library.playlist.removeItem")
}

@Test("C1.19 评分、标签、搜索、建立索引与信息面板命令进 CoreCommands.all 且无快捷键冲突")
func searchAndMetadataCommandsHaveNoConflicts() throws {
    let expected: [(CommandID, String)] = [
        (.ratingSet0, "rating.set.0"),
        (.ratingSet1, "rating.set.1"),
        (.ratingSet2, "rating.set.2"),
        (.ratingSet3, "rating.set.3"),
        (.ratingSet4, "rating.set.4"),
        (.ratingSet5, "rating.set.5"),
        (.metadataTagsEdit, "metadata.tags.edit"),
        (.searchFocus, "search.focus"),
        (.searchIndexFolder, "search.indexFolder"),
        (.infoPanelToggle, "panel.info.toggle"),
    ]
    for (id, raw) in expected {
        #expect(id.rawValue == raw)
        #expect(CoreCommands.all.contains { $0.id == id })
    }
    let bindings = CoreCommands.all.flatMap(\.defaultBindings)
    #expect(BindingResolver.conflicts(in: bindings).isEmpty)

    var resolver = BindingResolver(bindings: bindings)
    let now = ContinuousClock.now
    for scope in [InputScope.viewer, .list] {
        for (key, command) in [
            ("0", CommandID.ratingSet0), ("1", .ratingSet1), ("2", .ratingSet2),
            ("3", .ratingSet3), ("4", .ratingSet4), ("5", .ratingSet5),
        ] {
            #expect(resolver.feed(KeyChord(key, modifiers: .option), scope: scope, at: now) == .command(command, nil))
        }
        #expect(resolver.feed(KeyChord("t", modifiers: .option), scope: scope, at: now) == .command(.metadataTagsEdit, nil))
        #expect(resolver.feed(KeyChord("f", modifiers: .command), scope: scope, at: now) == .command(.searchFocus, nil))
        #expect(resolver.feed(KeyChord("i", modifiers: [.command, .option]), scope: scope, at: now) == .command(.infoPanelToggle, nil))
    }
    #expect(CoreCommands.all.first { $0.id == .searchIndexFolder }?.defaultBindings.isEmpty == true)
    let menu = Set(menuCommands(CoreCommands.defaultMenu.roots))
    for (id, _) in expected {
        #expect(menu.contains(id))
    }
}

@Test("C1.9/C1.10 显示配置与效果命令绑定、作用域、菜单位置与无冲突")
func displayProfileAndEffectsCommandsHaveBindingsAndNoConflicts() throws {
    let expected: [(CommandID, String)] = [
        (.displayProfileApply, "displayProfile.apply"),
        (.effectsToggle, "effects.toggle"),
        (.effectsPanelToggle, "panel.effects.toggle"),
    ]
    for (id, raw) in expected {
        #expect(id.rawValue == raw)
        #expect(CoreCommands.all.contains { $0.id == id })
    }
    let bindings = CoreCommands.all.flatMap(\.defaultBindings)
    #expect(BindingResolver.conflicts(in: bindings).isEmpty)

    var resolver = BindingResolver(bindings: bindings)
    let now = ContinuousClock.now
    for scope in [InputScope.viewer, .list] {
        for slot in 1...9 {
            #expect(
                resolver.feed(KeyChord(String(slot), modifiers: .control), scope: scope, at: now)
                    == .command(.displayProfileApply, ["slot": .number(Double(slot))])
            )
        }
    }
    #expect(resolver.feed(KeyChord("1", modifiers: .control), scope: .textInput, at: now) == .unmatched)
    #expect(resolver.feed(KeyChord("e"), scope: .viewer, at: now) == .command(.effectsToggle, nil))
    #expect(resolver.feed(KeyChord("e"), scope: .textInput, at: now) == .unmatched)
    #expect(resolver.feed(KeyChord("e"), scope: .list, at: now) == .unmatched)
    for scope in [InputScope.global, .viewer, .list] {
        #expect(resolver.feed(KeyChord("e", modifiers: [.command, .option]), scope: scope, at: now) == .command(.effectsPanelToggle, nil))
    }
    #expect(resolver.feed(KeyChord("e", modifiers: [.command, .option]), scope: .textInput, at: now) == .unmatched)

    let viewMenu = try #require(CoreCommands.defaultMenu.roots.first { if case .submenu("显示", _) = $0 { true } else { false } })
    let windowMenu = try #require(CoreCommands.defaultMenu.roots.first { if case .submenu("窗口", _) = $0 { true } else { false } })
    #expect(Set(menuCommands([viewMenu])).isSuperset(of: [.effectsToggle, .displayProfileApply]))
    #expect(Set(menuCommands([windowMenu])).contains(.effectsPanelToggle))
}
