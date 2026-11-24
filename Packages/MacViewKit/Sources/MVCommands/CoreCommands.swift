import Foundation
import MVFoundation

extension CommandID {
    public static let frameNext = CommandID("frame.next")
    public static let framePrevious = CommandID("frame.previous")
    public static let frameLeft = CommandID("frame.left")
    public static let frameRight = CommandID("frame.right")
    public static let pageNext = CommandID("page.next")
    public static let pagePrevious = CommandID("page.previous")
    public static let pageFirst = CommandID("page.first")
    public static let pageLast = CommandID("page.last")
    public static let pageJump = CommandID("page.jump")
    public static let bookNext = CommandID("book.next")
    public static let bookPrevious = CommandID("book.previous")
    public static let fileOpen = CommandID("file.open")
    public static let fileDelete = CommandID("file.delete")
    public static let fileRename = CommandID("file.rename")
    public static let fileCopy = CommandID("file.copy")
    public static let fileCopyPath = CommandID("file.copyPath")
    public static let fileReveal = CommandID("file.reveal")
    public static let fileOpenWith = CommandID("file.openWith")
    public static let recycleEmpty = CommandID("file.recycle.empty")
    public static let classifyTarget = CommandID("classify.target")
    public static let classifyModeToggle = CommandID("classify.mode.toggle")
    public static let classifyNewTarget = CommandID("classify.newTarget")
    public static let classifyPanelToggle = CommandID("panel.classify.toggle")
    public static let editUndo = CommandID("edit.undo")
    public static let editRedo = CommandID("edit.redo")
    public static let bookReveal = CommandID("book.reveal")
    public static let bookmarkAdd = CommandID("library.bookmark.add")
    public static let playlistAddCurrent = CommandID("library.playlist.addCurrent")
    public static let playlistRemoveItem = CommandID("library.playlist.removeItem")
    public static let playlistOpenContainingBook = CommandID("library.playlist.openContainingBook")
    public static let historyToggle = CommandID("panel.history.toggle")
    public static let bookmarksToggle = CommandID("panel.bookmarks.toggle")
    public static let playlistToggle = CommandID("panel.playlist.toggle")
    public static let browsePaged = CommandID("view.paged")
    public static let browseWaterfall = CommandID("view.waterfall")
    public static let browseVerticalStrip = CommandID("view.verticalStrip")
    public static let browseHorizontalStrip = CommandID("view.horizontalStrip")
    public static let pageModeToggle = CommandID("view.pageMode.toggle")
    public static let readingDirectionToggle = CommandID("view.direction.toggle")
    public static let firstPageSingleToggle = CommandID("view.firstPageSingle.toggle")
    public static let widePageAsIs = CommandID("view.widePage.asIs")
    public static let widePageSingle = CommandID("view.widePage.single")
    public static let widePageSplit = CommandID("view.widePage.split")
    public static let zoomOriginal = CommandID("zoom.original")
    public static let zoomFitWindow = CommandID("zoom.fitWindow")
    public static let zoomFitWidth = CommandID("zoom.fitWidth")
    public static let zoomFitHeight = CommandID("zoom.fitHeight")
    public static let zoomFill = CommandID("zoom.fill")
    public static let zoomFixed = CommandID("zoom.fixed")
    public static let zoomDevicePixel = CommandID("zoom.devicePixel")
    public static let zoomIn = CommandID("zoom.in")
    public static let zoomOut = CommandID("zoom.out")
    public static let zoomAllowUpscaleToggle = CommandID("zoom.allowUpscale.toggle")
    public static let magnifierToggle = CommandID("zoom.magnifier.toggle")
    public static let keepZoomOnPageTurnToggle = CommandID("zoom.keepOnPageTurn.toggle")
    public static let sortName = CommandID("sort.name")
    public static let sortModified = CommandID("sort.modified")
    public static let sortCreated = CommandID("sort.created")
    public static let sortSize = CommandID("sort.size")
    public static let sortType = CommandID("sort.type")
    public static let sortRandom = CommandID("sort.random")
    public static let sortAscending = CommandID("sort.ascending")
    public static let sortDescending = CommandID("sort.descending")
    public static let sortFoldersFirstToggle = CommandID("sort.foldersFirst.toggle")
    public static let recursionToggle = CommandID("book.recursion.toggle")
    public static let windowNew = CommandID("window.new")
    public static let windowNewTab = CommandID("window.newTab")
    public static let fullScreenToggle = CommandID("window.fullScreen.toggle")
    public static let windowKeepOnTopToggle = CommandID("window.keepOnTop.toggle")
    public static let windowTitleBarAutoHideToggle = CommandID("window.titleBar.autoHide.toggle")
    public static let windowBorderlessToggle = CommandID("window.borderless.toggle")
    public static let bookshelfToggle = CommandID("panel.bookshelf.toggle")
    public static let pageListToggle = CommandID("panel.pageList.toggle")
    public static let docksToggle = CommandID("panel.docks.toggle")
    public static let retryFailed = CommandID("item.retryFailed")
    public static let settingsOpen = CommandID("app.settings")
    public static let ratingSet0 = CommandID("rating.set.0")
    public static let ratingSet1 = CommandID("rating.set.1")
    public static let ratingSet2 = CommandID("rating.set.2")
    public static let ratingSet3 = CommandID("rating.set.3")
    public static let ratingSet4 = CommandID("rating.set.4")
    public static let ratingSet5 = CommandID("rating.set.5")
    public static let metadataTagsEdit = CommandID("metadata.tags.edit")
    public static let searchFocus = CommandID("search.focus")
    public static let searchIndexFolder = CommandID("search.indexFolder")
    public static let infoPanelToggle = CommandID("panel.info.toggle")
    public static let displayProfileApply = CommandID("displayProfile.apply")
    public static let effectsToggle = CommandID("effects.toggle")
    public static let effectsPanelToggle = CommandID("panel.effects.toggle")
    public static let layoutSchemeSave = CommandID("layout.scheme.save")
    public static let layoutSchemeApply = CommandID("layout.scheme.apply")
    public static let layoutSchemeManage = CommandID("layout.scheme.manage")
    public static let scriptStopAll = CommandID("script.stopAll")
    public static let scriptRevealFolder = CommandID("script.revealFolder")
    public static let scriptManage = CommandID("script.manage")
}

/// P0 的命令元数据与默认菜单。处理器由 MVServices 和 App 注册。
/// 字母键用小写逻辑键名；空格及方向键用 Space、Right 等名称，交给 App 的 InputRouter 转换。
public enum CoreCommands {
    public static let all: [CommandDescriptor] = groups.flatMap { $0.sections.flatMap(\.commands) }

    public static let defaultMenu = MenuModel(roots: groups.map { group in
        var children: [MenuNode] = []
        for section in group.sections {
            let items = section.commands.map { MenuNode.command($0.id) } + section.trailingNodes
            if let title = section.title {
                children.append(.submenu(titleKey: title, children: items))
            } else {
                if !children.isEmpty { children.append(.separator) }
                children.append(contentsOf: items)
            }
        }
        return .submenu(titleKey: group.title, children: children)
    })

    private struct Group: Sendable {
        var title: String
        var sections: [Section]
    }

    private struct Section: Sendable {
        var title: String?
        var commands: [CommandDescriptor]
        var trailingNodes: [MenuNode]

        init(_ commands: [CommandDescriptor], trailingNodes: [MenuNode] = []) {
            self.title = nil
            self.commands = commands
            self.trailingNodes = trailingNodes
        }

        init(_ title: String, _ commands: [CommandDescriptor], trailingNodes: [MenuNode] = []) {
            self.title = title
            self.commands = commands
            self.trailingNodes = trailingNodes
        }
    }

    private static func command(
        _ id: CommandID, _ title: LocalizedStringResource, _ category: String,
        scope: InputScope = .viewer, keys: [KeyChord] = [], sequences: [[KeyChord]] = [],
        symbol: String? = nil
    ) -> CommandDescriptor {
        CommandDescriptor(
            id: id, title: title, category: category,
            defaultBindings: (keys.map { [$0] } + sequences).map { KeyBinding(sequence: $0, command: id, scope: scope) },
            symbol: symbol
        )
    }

    private static func commandMany(
        _ id: CommandID, _ title: LocalizedStringResource, _ category: String,
        key: KeyChord, scopes: [InputScope], symbol: String? = nil
    ) -> CommandDescriptor {
        CommandDescriptor(
            id: id, title: title, category: category,
            defaultBindings: scopes.map { KeyBinding(sequence: [key], command: id, scope: $0) },
            symbol: symbol
        )
    }

    private static let classifyTargetCommand = CommandDescriptor(
        id: .classifyTarget, title: .init("分类到目标", bundle: .main), category: "file",
        defaultBindings: (1...10).map { index in
            KeyBinding(sequence: [KeyChord(index == 10 ? "0" : String(index))], command: .classifyTarget,
                       arguments: ["index": .number(Double(index))], scope: .classify)
        }
    )

    private static let displayProfileApplyCommand = CommandDescriptor(
        id: .displayProfileApply, title: .init("套用显示配置", bundle: .main), category: "view",
        defaultBindings: [InputScope.viewer, .list].flatMap { scope in
            (1...9).map { slot in
                KeyBinding(
                    sequence: [KeyChord(String(slot), modifiers: .control)],
                    command: .displayProfileApply,
                    arguments: ["slot": .number(Double(slot))],
                    scope: scope
                )
            }
        }
    )

    private static let groups: [Group] = [
        Group(title: "文件", sections: [
            Section([
                command(.fileOpen, .init("打开文件夹或压缩包…", bundle: .main), "book", scope: .global,
                        keys: [KeyChord("o", modifiers: .command)], symbol: "folder"),
            ]),
            Section([
                commandMany(.fileDelete, .init("删除", bundle: .main), "file", key: KeyChord("Delete", modifiers: .command), scopes: [.viewer, .list], symbol: "trash"),
                command(.fileRename, .init("重命名", bundle: .main), "file"),
                commandMany(.fileCopy, .init("复制", bundle: .main), "file", key: KeyChord("c", modifiers: .command), scopes: [.viewer, .list]),
                commandMany(.fileCopyPath, .init("复制路径", bundle: .main), "file", key: KeyChord("c", modifiers: [.command, .option]), scopes: [.viewer, .list]),
                commandMany(.fileReveal, .init("在 Finder 中显示", bundle: .main), "file", key: KeyChord("r", modifiers: [.command, .option]), scopes: [.viewer, .list], symbol: "arrow.up.forward.square"),
                command(.fileOpenWith, .init("用指定应用打开", bundle: .main), "file"),
                command(.recycleEmpty, .init("清空回收目录…", bundle: .main), "file"),
            ]),
            Section("评分", [
                commandMany(.ratingSet0, .init("清除评分", bundle: .main), "metadata", key: KeyChord("0", modifiers: .option), scopes: [.viewer, .list]),
                commandMany(.ratingSet1, .init("1 星", bundle: .main), "metadata", key: KeyChord("1", modifiers: .option), scopes: [.viewer, .list]),
                commandMany(.ratingSet2, .init("2 星", bundle: .main), "metadata", key: KeyChord("2", modifiers: .option), scopes: [.viewer, .list]),
                commandMany(.ratingSet3, .init("3 星", bundle: .main), "metadata", key: KeyChord("3", modifiers: .option), scopes: [.viewer, .list]),
                commandMany(.ratingSet4, .init("4 星", bundle: .main), "metadata", key: KeyChord("4", modifiers: .option), scopes: [.viewer, .list]),
                commandMany(.ratingSet5, .init("5 星", bundle: .main), "metadata", key: KeyChord("5", modifiers: .option), scopes: [.viewer, .list]),
            ]),
            Section([
                commandMany(.metadataTagsEdit, .init("编辑标签…", bundle: .main), "metadata", key: KeyChord("t", modifiers: .option), scopes: [.viewer, .list]),
            ]),
            Section([
                command(.editUndo, .init("撤销", bundle: .main), "edit", scope: .global, keys: [KeyChord("z", modifiers: .command)]),
                command(.editRedo, .init("重做", bundle: .main), "edit", scope: .global, keys: [KeyChord("z", modifiers: [.command, .shift])]),
            ]),
            Section([
                command(.windowNew, .init("新建窗口", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("n", modifiers: .command)]),
                command(.windowNewTab, .init("新建标签页", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("t", modifiers: .command)]),
            ]),
            Section([
                command(.retryFailed, .init("重试失败的项", bundle: .main), "other", scope: .global,
                        keys: [KeyChord("r", modifiers: .command)]),
                command(.settingsOpen, .init("设置…", bundle: .main), "other", scope: .global,
                        keys: [KeyChord(",", modifiers: .command)], symbol: "gearshape"),
            ]),
        ]),
        Group(title: "显示", sections: [
            Section("浏览方式", [
                command(.browsePaged, .init("分页", bundle: .main), "view",
                        keys: [KeyChord("1", modifiers: .command)], symbol: "book"),
                command(.browseWaterfall, .init("瀑布流", bundle: .main), "view",
                        keys: [KeyChord("2", modifiers: .command)], symbol: "square.grid.2x2"),
                command(.browseVerticalStrip, .init("纵向连续", bundle: .main), "view",
                        keys: [KeyChord("3", modifiers: .command)], symbol: "rectangle.split.1x2"),
                command(.browseHorizontalStrip, .init("横向连续", bundle: .main), "view",
                        keys: [KeyChord("4", modifiers: .command)], symbol: "rectangle.split.2x1"),
            ]),
            Section([
                command(.pageModeToggle, .init("切换单页与双页", bundle: .main), "view", keys: [KeyChord("d")], symbol: "book.closed"),
                command(.readingDirectionToggle, .init("切换阅读方向", bundle: .main), "view", keys: [KeyChord("r")], symbol: "arrow.left.arrow.right"),
                command(.firstPageSingleToggle, .init("首页单页", bundle: .main), "view"),
            ]),
            Section("宽页处理", [
                command(.widePageAsIs, .init("宽页保持原样", bundle: .main), "view"),
                command(.widePageSingle, .init("宽页单独显示", bundle: .main), "view"),
                command(.widePageSplit, .init("宽页拆分", bundle: .main), "view"),
            ]),
            Section("缩放", [
                command(.zoomFitWindow, .init("适合窗口", bundle: .main), "zoom", keys: [KeyChord("0")], symbol: "viewfinder"),
                command(.zoomFitWidth, .init("适合宽度", bundle: .main), "zoom", keys: [KeyChord("2")]),
                command(.zoomFitHeight, .init("适合高度", bundle: .main), "zoom", keys: [KeyChord("3")]),
                command(.zoomFill, .init("填满裁切", bundle: .main), "zoom", keys: [KeyChord("4")]),
                command(.zoomOriginal, .init("实际像素", bundle: .main), "zoom", keys: [KeyChord("1")], symbol: "1.magnifyingglass"),
                command(.zoomDevicePixel, .init("设备像素 1:1", bundle: .main), "zoom",
                        keys: [KeyChord("1", modifiers: [.option, .shift])]),
                command(.zoomFixed, .init("固定百分比…", bundle: .main), "zoom"),
                command(.zoomIn, .init("放大", bundle: .main), "zoom", keys: [KeyChord("=", modifiers: .command)], symbol: "plus.magnifyingglass"),
                command(.zoomOut, .init("缩小", bundle: .main), "zoom", keys: [KeyChord("-", modifiers: .command)], symbol: "minus.magnifyingglass"),
                command(.zoomAllowUpscaleToggle, .init("允许放大小图", bundle: .main), "zoom"),
                command(.magnifierToggle, .init("放大镜", bundle: .main), "zoom", keys: [KeyChord("z")], symbol: "magnifyingglass.circle"),
                command(.keepZoomOnPageTurnToggle, .init("翻页保持缩放与位置", bundle: .main), "zoom"),
            ]),
            Section([
                command(.effectsToggle, .init("效果开关", bundle: .main), "view", keys: [KeyChord("e")], symbol: "wand.and.stars"),
                displayProfileApplyCommand,
            ]),
        ]),
        Group(title: "翻页", sections: [
            Section([
                command(.frameNext, .init("下一帧", bundle: .main), "page", keys: [KeyChord("Right"), KeyChord("Space")], symbol: "arrow.right"),
                command(.framePrevious, .init("上一帧", bundle: .main), "page",
                        keys: [KeyChord("Left"), KeyChord("Space", modifiers: .shift)], symbol: "arrow.left"),
                command(.frameLeft, .init("左侧一帧", bundle: .main), "page", symbol: "chevron.backward"),
                command(.frameRight, .init("右侧一帧", bundle: .main), "page", symbol: "chevron.forward"),
                command(.pageNext, .init("下一页", bundle: .main), "page", keys: [KeyChord("Right", modifiers: .option)], symbol: "arrow.right.to.line"),
                command(.pagePrevious, .init("上一页", bundle: .main), "page", keys: [KeyChord("Left", modifiers: .option)], symbol: "arrow.left.to.line"),
            ]),
            Section([
                command(.pageFirst, .init("首页", bundle: .main), "page",
                        keys: [KeyChord("Home"), KeyChord("Left", modifiers: .command)],
                        sequences: [[KeyChord("g"), KeyChord("g")]], symbol: "backward.end"),
                command(.pageLast, .init("末页", bundle: .main), "page",
                        keys: [KeyChord("End"), KeyChord("Right", modifiers: .command)],
                        sequences: [[KeyChord("g"), KeyChord("e")]], symbol: "forward.end"),
                command(.pageJump, .init("跳到指定页…", bundle: .main), "page", keys: [KeyChord("g", modifiers: .command)]),
            ]),
        ]),
        Group(title: "书", sections: [
            Section([
                commandMany(.bookmarkAdd, .init("加入书签", bundle: .main), "book", key: KeyChord("d", modifiers: .command), scopes: [.viewer, .list], symbol: "bookmark"),
                commandMany(.playlistAddCurrent, .init("加入播放列表…", bundle: .main), "book", key: KeyChord("l", modifiers: .command), scopes: [.viewer, .list], symbol: "text.badge.plus"),
                command(.playlistRemoveItem, .init("从播放列表移除", bundle: .main), "book"),
                command(.playlistOpenContainingBook, .init("打开所在的书", bundle: .main), "book"),
            ]),
            Section([
                command(.bookNext, .init("下一本书", bundle: .main), "book", keys: [KeyChord("Down", modifiers: .option)], symbol: "chevron.right"),
                command(.bookPrevious, .init("上一本书", bundle: .main), "book", keys: [KeyChord("Up", modifiers: .option)], symbol: "chevron.left"),
                command(.bookReveal, .init("在书架中显示当前书", bundle: .main), "book", scope: .global,
                        keys: [KeyChord("j", modifiers: [.command, .shift])]),
            ]),
            Section("排序", [
                command(.sortName, .init("按名称排序", bundle: .main), "sort"),
                command(.sortModified, .init("按修改时间排序", bundle: .main), "sort"),
                command(.sortCreated, .init("按创建时间排序", bundle: .main), "sort"),
                command(.sortSize, .init("按大小排序", bundle: .main), "sort"),
                command(.sortType, .init("按类型排序", bundle: .main), "sort"),
                command(.sortRandom, .init("随机排序", bundle: .main), "sort"),
                command(.sortAscending, .init("升序", bundle: .main), "sort"),
                command(.sortDescending, .init("降序", bundle: .main), "sort"),
                command(.sortFoldersFirstToggle, .init("文件夹在前", bundle: .main), "sort"),
            ]),
            Section("分类", [
                classifyTargetCommand,
                command(.classifyModeToggle, .init("切换移动或复制", bundle: .main), "file"),
                command(.classifyNewTarget, .init("新建目标并移入", bundle: .main), "file"),
            ]),
            Section([
                command(.recursionToggle, .init("递归展开子文件夹", bundle: .main), "sort",
                        keys: [KeyChord("r", modifiers: [.command, .shift])]),
                command(.searchFocus, .init("搜索", bundle: .main), "search", scope: .global,
                        keys: [KeyChord("f", modifiers: .command)], symbol: "magnifyingglass"),
                command(.searchIndexFolder, .init("建立索引", bundle: .main), "search"),
            ]),
        ]),
        Group(title: "脚本", sections: [
            Section([], trailingNodes: [.dynamic(.scripts)]),
            Section([
                command(.scriptStopAll, .init("停止全部脚本", bundle: .main), "script", scope: .global),
                command(.scriptRevealFolder, .init("打开脚本文件夹", bundle: .main), "script", scope: .global),
                command(.scriptManage, .init("管理脚本与外部命令…", bundle: .main), "script", scope: .global),
            ]),
        ]),
        Group(title: "窗口", sections: [
            Section([
                command(.fullScreenToggle, .init("切换全屏幕", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("f", modifiers: [.control, .command])], symbol: "arrow.up.left.and.arrow.down.right"),
            ]),
            Section([
                command(.windowKeepOnTopToggle, .init("置顶", bundle: .main), "window", scope: .global),
                command(.windowTitleBarAutoHideToggle, .init("自动隐藏标题栏", bundle: .main), "window", scope: .global),
                command(.windowBorderlessToggle, .init("无边框", bundle: .main), "window", scope: .global),
            ]),
            Section([
                command(.bookshelfToggle, .init("显示或隐藏书架", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("1", modifiers: [.command, .option])], symbol: "books.vertical"),
                command(.pageListToggle, .init("显示或隐藏页面列表", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("2", modifiers: [.command, .option])], symbol: "list.bullet.rectangle"),
                command(.classifyPanelToggle, .init("显示或隐藏分类面板", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("3", modifiers: [.command, .option])], symbol: "folder.badge.plus"),
                command(.historyToggle, .init("显示或隐藏历史", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("4", modifiers: [.command, .option])], symbol: "clock"),
                command(.bookmarksToggle, .init("显示或隐藏书签", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("5", modifiers: [.command, .option])], symbol: "bookmark.fill"),
                command(.playlistToggle, .init("显示或隐藏播放列表", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("6", modifiers: [.command, .option])], symbol: "list.star"),
                command(.infoPanelToggle, .init("显示或隐藏信息面板", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("i", modifiers: [.command, .option])], symbol: "info.circle"),
                command(.effectsPanelToggle, .init("效果面板", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("e", modifiers: [.command, .option])], symbol: "slider.horizontal.3"),
                command(.docksToggle, .init("显示或隐藏停靠区", bundle: .main), "window", keys: [KeyChord("Tab")], symbol: "sidebar.squares.left"),
            ]),
            Section([
                command(.layoutSchemeSave, .init("保存为布局方案…", bundle: .main), "window", scope: .global),
                command(.layoutSchemeApply, .init("套用布局方案", bundle: .main), "window", scope: .global),
                command(.layoutSchemeManage, .init("管理布局方案…", bundle: .main), "window", scope: .global),
            ], trailingNodes: [.dynamic(.layoutSchemes)]),
        ]),
    ]
}
