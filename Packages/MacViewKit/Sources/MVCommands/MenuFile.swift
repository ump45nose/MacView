import Foundation

/// 运行时动态填充的子菜单占位。
public enum DynamicMenuID: String, Codable, Sendable, Hashable, CaseIterable {
    case openWith
    case moveTo
    case copyTo
    case rating
    case displayProfiles
    case layoutSchemes
}

/// 工具栏条目标识：命令 ID 字符串、现有特殊条目（如 `book.title`、`view.browse`）或 `flexibleSpace`、`space`。
public struct ToolbarItemID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(command: CommandID) {
        self.rawValue = command.rawValue
    }

    public static let flexibleSpace = ToolbarItemID("flexibleSpace")
    public static let space = ToolbarItemID("space")
    public static let dockLeft = ToolbarItemID("dock.left")
    public static let dockRight = ToolbarItemID("dock.right")
    public static let bookTitle = ToolbarItemID("book.title")
    public static let viewWaterfallOptions = ToolbarItemID("view.waterfallOptions")
    public static let viewBrowse = ToolbarItemID("view.browse")
    public static let viewOptions = ToolbarItemID("view.options")
    public static let windowFullScreen = ToolbarItemID("window.fullScreen")
}

/// `menus.json` 的文档内容；任一字段为 `nil` 时使用默认配置，非 `nil` 时整树/整列表替换默认。
public struct MenuFile: Codable, Sendable, Hashable {
    public var mainMenu: [MenuNode]?
    public var viewerContextMenu: [MenuNode]?
    public var toolbar: [ToolbarItemID]?

    public init(
        mainMenu: [MenuNode]? = nil,
        viewerContextMenu: [MenuNode]? = nil,
        toolbar: [ToolbarItemID]? = nil
    ) {
        self.mainMenu = mainMenu
        self.viewerContextMenu = viewerContextMenu
        self.toolbar = toolbar
    }

    public var resolvedMainMenu: [MenuNode] {
        mainMenu ?? CoreCommands.defaultMenu.roots
    }

    public var resolvedViewerContextMenu: [MenuNode] {
        viewerContextMenu ?? CoreCommands.defaultViewerContextMenu
    }

    public var resolvedToolbar: [ToolbarItemID] {
        toolbar ?? CoreCommands.defaultToolbar
    }
}

extension CoreCommands {
    /// 默认查看器右键菜单：与 `ReaderWindowController.viewerMenu(for:)` 条目和顺序一致。
    public static let defaultViewerContextMenu: [MenuNode] = [
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
    ]

    /// 默认工具栏条目列表：与 `ReaderWindowController.toolbarDefaultItemIdentifiers` 一致。
    public static let defaultToolbar: [ToolbarItemID] = [
        .dockLeft,
        ToolbarItemID(command: .bookPrevious),
        ToolbarItemID(command: .bookNext),
        .bookTitle,
        .flexibleSpace,
        .viewWaterfallOptions,
        .viewBrowse,
        .viewOptions,
        .windowFullScreen,
        ToolbarItemID(command: .effectsToggle),
        .dockRight,
    ]
}
