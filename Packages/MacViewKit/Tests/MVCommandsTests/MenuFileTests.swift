import Foundation
import Testing
@testable import MVCommands

@Test("C1.3 MenuFile 编解码往返（含 dynamic 节点与 ToolbarItemID）")
func menuFileRoundTrips() throws {
    let file = MenuFile(
        mainMenu: [
            .submenu(titleKey: "文件", children: [
                .command(.fileOpen),
                .dynamic(.openWith),
                .separator,
                .dynamic(.moveTo),
                .dynamic(.copyTo),
            ]),
            .submenu(titleKey: "窗口", children: [
                .command(.layoutSchemeSave),
                .dynamic(.layoutSchemes),
            ]),
        ],
        viewerContextMenu: [
            .command(.playlistAddCurrent),
            .dynamic(.rating),
            .separator,
            .command(.fileDelete),
        ],
        toolbar: [
            .dockLeft,
            ToolbarItemID(command: .bookPrevious),
            .space,
            .bookTitle,
            .flexibleSpace,
            ToolbarItemID(command: .effectsToggle),
            .dockRight,
        ]
    )
    let encoded = try JSONEncoder().encode(file)
    let decoded = try JSONDecoder().decode(MenuFile.self, from: encoded)
    #expect(decoded == file)
    #expect(decoded.resolvedMainMenu == file.mainMenu)
    #expect(decoded.resolvedViewerContextMenu == file.viewerContextMenu)
    #expect(decoded.resolvedToolbar == file.toolbar)
}

@Test("C1.3 MenuFile 缺省字段（nil）取默认主菜单、默认右键菜单和默认工具栏")
func menuFileNilFieldsResolveToDefaults() throws {
    let empty = try JSONDecoder().decode(MenuFile.self, from: Data("{}".utf8))
    #expect(empty == MenuFile())
    #expect(empty.mainMenu == nil)
    #expect(empty.viewerContextMenu == nil)
    #expect(empty.toolbar == nil)
    #expect(empty.resolvedMainMenu == CoreCommands.defaultMenu.roots)
    #expect(empty.resolvedViewerContextMenu == CoreCommands.defaultViewerContextMenu)
    #expect(empty.resolvedToolbar == CoreCommands.defaultToolbar)

    // 默认右键菜单与 ReaderWindowController.viewerMenu(for:) 条目和顺序一致。
    #expect(CoreCommands.defaultViewerContextMenu == [
        .command(.playlistAddCurrent),
        .command(.playlistRemoveItem),
        .command(.playlistOpenContainingBook),
        .separator,
        .dynamic(.rating),
        .command(.metadataTagsEdit),
        .separator,
        .command(.fileCopy),
        .command(.fileCopyPath),
        .command(.fileReveal),
        .dynamic(.openWith),
        .separator,
        .dynamic(.moveTo),
        .dynamic(.copyTo),
        .command(.fileRename),
        .command(.fileDelete),
        .separator,
        .submenu(titleKey: "脚本", children: [.dynamic(.scripts)]),
    ])

    // 默认工具栏与 ReaderWindowController.toolbarDefaultItemIdentifiers 一致。
    #expect(CoreCommands.defaultToolbar.map(\.rawValue) == [
        "dock.left",
        "book.previous",
        "book.next",
        "book.title",
        "flexibleSpace",
        "view.waterfallOptions",
        "view.browse",
        "view.options",
        "window.fullScreen",
        "effects.toggle",
        "dock.right",
    ])
}

@Test("C1.3 旧的 MenuNode JSON（不含 dynamic）照常解码，DynamicMenuID 全部可往返")
func legacyMenuNodeJSONDecodesAndDynamicMenuIDsRoundTrip() throws {
    let legacyJSON = #"{"roots":[{"submenu":{"titleKey":"menu.view","children":[{"command":{"_0":"view.waterfall"}},{"separator":{}}]}}]}"#
    let decoded = try JSONDecoder().decode(MenuModel.self, from: Data(legacyJSON.utf8))
    #expect(decoded == MenuModel(roots: [
        .submenu(titleKey: "menu.view", children: [.command(.browseWaterfall), .separator]),
    ]))

    let allDynamic = DynamicMenuID.allCases.map { MenuNode.dynamic($0) }
    #expect(DynamicMenuID.allCases.count == 8)
    #expect(try JSONDecoder().decode([MenuNode].self, from: JSONEncoder().encode(allDynamic)) == allDynamic)

    // C1.24：默认文件菜单包含「打开来源」动态项，旧 menus.json 解码不受影响。
    let fileMenu = try #require(CoreCommands.defaultMenu.roots.first {
        if case .submenu("文件", _) = $0 { true } else { false }
    })
    if case let .submenu(_, children) = fileMenu {
        #expect(Array(children.prefix(2)) == [.command(.fileOpen), .dynamic(.sources)])
    }
    let oldMenusJSON = #"{"mainMenu":[{"submenu":{"titleKey":"文件","children":[{"command":{"_0":"file.open"}}]}}]}"#
    let decodedOld = try JSONDecoder().decode(MenuFile.self, from: Data(oldMenusJSON.utf8))
    #expect(decodedOld.mainMenu?.count == 1)
}

@Test("C1.3 新命令出现在 CoreCommands.all 且常用命令带 symbol")
func newCommandsAndSymbolsAreRegistered() {
    let expected: [(CommandID, String, String)] = [
        (.frameLeft, "frame.left", "page"),
        (.frameRight, "frame.right", "page"),
        (.layoutSchemeSave, "layout.scheme.save", "window"),
        (.layoutSchemeApply, "layout.scheme.apply", "window"),
        (.playlistOpenContainingBook, "library.playlist.openContainingBook", "book"),
    ]
    for (id, raw, category) in expected {
        #expect(id.rawValue == raw)
        let descriptor = CoreCommands.all.first { $0.id == id }
        #expect(descriptor != nil)
        #expect(descriptor?.category == category)
        #expect(descriptor?.defaultBindings.isEmpty == true)
    }

    let withSymbols = CoreCommands.all.filter { !($0.symbol ?? "").isEmpty }
    #expect(withSymbols.count >= 20)

    let requiredSymbols: [CommandID] = [
        .frameNext, .framePrevious, .frameLeft, .frameRight,
        .bookNext, .bookPrevious, .zoomIn, .zoomOut, .zoomFitWindow,
        .browsePaged, .browseWaterfall, .browseVerticalStrip, .browseHorizontalStrip,
        .fullScreenToggle, .effectsToggle, .bookmarkAdd,
        .bookshelfToggle, .pageListToggle, .docksToggle,
    ]
    for id in requiredSymbols {
        let symbol = CoreCommands.all.first { $0.id == id }?.symbol
        #expect(symbol != nil && !symbol!.isEmpty, "命令 \(id.rawValue) 应有 symbol")
    }
}

@Test("C1.6 外观与布局管理命令标题、分类及默认按键符合约定")
func appearanceWindowCommandsAreRegisteredWithoutDefaultKeys() throws {
    let expected: [(CommandID, String, String)] = [
        (.windowKeepOnTopToggle, "window.keepOnTop.toggle", "置顶"),
        (.windowTitleBarAutoHideToggle, "window.titleBar.autoHide.toggle", "自动隐藏标题栏"),
        (.windowBorderlessToggle, "window.borderless.toggle", "无边框"),
        (.layoutSchemeManage, "layout.scheme.manage", "管理布局方案…"),
    ]
    for (id, raw, title) in expected {
        #expect(id.rawValue == raw)
        let descriptor = try #require(CoreCommands.all.first { $0.id == id })
        #expect(descriptor.category == "window")
        #expect(String(localized: descriptor.title) == title)
        #expect(descriptor.defaultBindings.isEmpty)
    }
}

@Test("C1.6 窗口新命令独立成节，布局管理位于套用与动态子菜单之间")
func appearanceWindowCommandsHaveExpectedMenuPositions() throws {
    let window = try #require(CoreCommands.defaultMenu.roots.first {
        if case .submenu("窗口", _) = $0 { true } else { false }
    })
    guard case let .submenu(_, children) = window else { return }
    #expect(Array(children.prefix(7)) == [
        .command(.fullScreenToggle), .separator,
        .command(.windowKeepOnTopToggle), .command(.windowTitleBarAutoHideToggle),
        .command(.windowBorderlessToggle), .separator, .command(.bookshelfToggle),
    ])
    #expect(Array(children.suffix(5)) == [
        .separator, .command(.layoutSchemeSave), .command(.layoutSchemeApply),
        .command(.layoutSchemeManage), .dynamic(.layoutSchemes),
    ])
    #expect(MenuFile().resolvedMainMenu == CoreCommands.defaultMenu.roots)
}
