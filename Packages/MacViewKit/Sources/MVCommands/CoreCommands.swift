import Foundation

extension CommandID {
    public static let frameNext = CommandID("frame.next")
    public static let framePrevious = CommandID("frame.previous")
    public static let pageNext = CommandID("page.next")
    public static let pagePrevious = CommandID("page.previous")
    public static let pageFirst = CommandID("page.first")
    public static let pageLast = CommandID("page.last")
    public static let pageJump = CommandID("page.jump")
    public static let bookNext = CommandID("book.next")
    public static let bookPrevious = CommandID("book.previous")
    public static let fileOpen = CommandID("file.open")
    public static let bookReveal = CommandID("book.reveal")
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
    public static let bookshelfToggle = CommandID("panel.bookshelf.toggle")
    public static let pageListToggle = CommandID("panel.pageList.toggle")
    public static let docksToggle = CommandID("panel.docks.toggle")
    public static let retryFailed = CommandID("item.retryFailed")
    public static let settingsOpen = CommandID("app.settings")
}

/// P0 的命令元数据与默认菜单。处理器由 MVServices 和 App 注册。
/// 字母键用小写逻辑键名；空格及方向键用 Space、Right 等名称，交给 App 的 InputRouter 转换。
public enum CoreCommands {
    public static let all: [CommandDescriptor] = groups.flatMap { $0.sections.flatMap(\.commands) }

    public static let defaultMenu = MenuModel(roots: groups.map { group in
        var children: [MenuNode] = []
        for section in group.sections {
            let commands = section.commands.map { MenuNode.command($0.id) }
            if let title = section.title {
                children.append(.submenu(titleKey: title, children: commands))
            } else {
                if !children.isEmpty { children.append(.separator) }
                children.append(contentsOf: commands)
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

        init(_ commands: [CommandDescriptor]) {
            self.title = nil
            self.commands = commands
        }

        init(_ title: String, _ commands: [CommandDescriptor]) {
            self.title = title
            self.commands = commands
        }
    }

    private static func command(
        _ id: CommandID, _ title: LocalizedStringResource, _ category: String,
        scope: InputScope = .viewer, keys: [KeyChord] = [], sequences: [[KeyChord]] = []
    ) -> CommandDescriptor {
        CommandDescriptor(
            id: id, title: title, category: category,
            defaultBindings: (keys.map { [$0] } + sequences).map { KeyBinding(sequence: $0, command: id, scope: scope) }
        )
    }

    private static let groups: [Group] = [
        Group(title: "文件", sections: [
            Section([
                command(.fileOpen, .init("打开文件夹或压缩包…", bundle: .main), "book", scope: .global,
                        keys: [KeyChord("o", modifiers: .command)]),
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
                        keys: [KeyChord(",", modifiers: .command)]),
            ]),
        ]),
        Group(title: "显示", sections: [
            Section("浏览方式", [
                command(.browsePaged, .init("分页", bundle: .main), "view",
                        keys: [KeyChord("1", modifiers: .command)]),
                command(.browseWaterfall, .init("瀑布流", bundle: .main), "view",
                        keys: [KeyChord("2", modifiers: .command)]),
                command(.browseVerticalStrip, .init("纵向连续", bundle: .main), "view",
                        keys: [KeyChord("3", modifiers: .command)]),
                command(.browseHorizontalStrip, .init("横向连续", bundle: .main), "view",
                        keys: [KeyChord("4", modifiers: .command)]),
            ]),
            Section([
                command(.pageModeToggle, .init("切换单页与双页", bundle: .main), "view", keys: [KeyChord("d")]),
                command(.readingDirectionToggle, .init("切换阅读方向", bundle: .main), "view", keys: [KeyChord("r")]),
                command(.firstPageSingleToggle, .init("首页单页", bundle: .main), "view"),
            ]),
            Section("宽页处理", [
                command(.widePageAsIs, .init("宽页保持原样", bundle: .main), "view"),
                command(.widePageSingle, .init("宽页单独显示", bundle: .main), "view"),
                command(.widePageSplit, .init("宽页拆分", bundle: .main), "view"),
            ]),
            Section("缩放", [
                command(.zoomFitWindow, .init("适合窗口", bundle: .main), "zoom", keys: [KeyChord("0")]),
                command(.zoomFitWidth, .init("适合宽度", bundle: .main), "zoom", keys: [KeyChord("2")]),
                command(.zoomFitHeight, .init("适合高度", bundle: .main), "zoom", keys: [KeyChord("3")]),
                command(.zoomFill, .init("填满裁切", bundle: .main), "zoom", keys: [KeyChord("4")]),
                command(.zoomOriginal, .init("实际像素", bundle: .main), "zoom", keys: [KeyChord("1")]),
                command(.zoomDevicePixel, .init("设备像素 1:1", bundle: .main), "zoom",
                        keys: [KeyChord("1", modifiers: .option)]),
                command(.zoomFixed, .init("固定百分比…", bundle: .main), "zoom"),
                command(.zoomIn, .init("放大", bundle: .main), "zoom", keys: [KeyChord("=", modifiers: .command)]),
                command(.zoomOut, .init("缩小", bundle: .main), "zoom", keys: [KeyChord("-", modifiers: .command)]),
                command(.zoomAllowUpscaleToggle, .init("允许放大小图", bundle: .main), "zoom"),
                command(.magnifierToggle, .init("放大镜", bundle: .main), "zoom", keys: [KeyChord("z")]),
                command(.keepZoomOnPageTurnToggle, .init("翻页保持缩放与位置", bundle: .main), "zoom"),
            ]),
        ]),
        Group(title: "翻页", sections: [
            Section([
                command(.frameNext, .init("下一帧", bundle: .main), "page", keys: [KeyChord("Right"), KeyChord("Space")]),
                command(.framePrevious, .init("上一帧", bundle: .main), "page",
                        keys: [KeyChord("Left"), KeyChord("Space", modifiers: .shift)]),
                command(.pageNext, .init("下一页", bundle: .main), "page", keys: [KeyChord("Right", modifiers: .option)]),
                command(.pagePrevious, .init("上一页", bundle: .main), "page", keys: [KeyChord("Left", modifiers: .option)]),
            ]),
            Section([
                command(.pageFirst, .init("首页", bundle: .main), "page",
                        keys: [KeyChord("Home"), KeyChord("Left", modifiers: .command)],
                        sequences: [[KeyChord("g"), KeyChord("g")]]),
                command(.pageLast, .init("末页", bundle: .main), "page",
                        keys: [KeyChord("End"), KeyChord("Right", modifiers: .command)],
                        sequences: [[KeyChord("g"), KeyChord("e")]]),
                command(.pageJump, .init("跳到指定页…", bundle: .main), "page", keys: [KeyChord("g", modifiers: .command)]),
            ]),
        ]),
        Group(title: "书", sections: [
            Section([
                command(.bookNext, .init("下一本书", bundle: .main), "book", keys: [KeyChord("Down", modifiers: .option)]),
                command(.bookPrevious, .init("上一本书", bundle: .main), "book", keys: [KeyChord("Up", modifiers: .option)]),
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
            Section([
                command(.recursionToggle, .init("递归展开子文件夹", bundle: .main), "sort",
                        keys: [KeyChord("r", modifiers: [.command, .shift])]),
            ]),
        ]),
        Group(title: "窗口", sections: [
            Section([
                command(.fullScreenToggle, .init("切换全屏幕", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("f", modifiers: [.control, .command])]),
            ]),
            Section([
                command(.bookshelfToggle, .init("显示或隐藏书架", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("1", modifiers: [.command, .option])]),
                command(.pageListToggle, .init("显示或隐藏页面列表", bundle: .main), "window", scope: .global,
                        keys: [KeyChord("2", modifiers: [.command, .option])]),
                command(.docksToggle, .init("显示或隐藏停靠区", bundle: .main), "window", keys: [KeyChord("Tab")]),
            ]),
        ]),
    ]
}
