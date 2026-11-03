#if DEBUG
import AppKit
import MVCommands
import MVFoundation
import MVLayout
import MVReading
import MVSettings

/// 书架与页面列表的自检（`-MVPanelSelfTest YES -MVSelfTestFixtures <Fixtures目录>`，用真实服务）。
///
/// 覆盖四种样式、面板设置互不影响、排序不影响翻页、书架排序决定下一本、浮动面板跟随活动窗口、视频时长。
@MainActor
final class PanelSelfTest {
    private let app: AppDelegate
    private let log = SelfTestLog()
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewPanelSelfTest-\(UUID().uuidString)")

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "MVPanelSelfTest") else { return }
        let test = PanelSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) {
        self.app = app
    }

    private func run() async {
        NSApp.activate()
        guard let services = app.services, let controller = app.controllers.first, let window = controller.window,
              let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") else {
            log.check(false, "面板自检需要真实服务、窗口与 -MVSelfTestFixtures")
            exit(log.summarize())
        }
        do {
            window.setContentSize(NSSize(width: 1200, height: 800))
            let shelf = try makeShelf(fixtures: URL(fileURLWithPath: path))
            await open(controller, shelf.appending(path: "bravo")) { $0.isEnumerated && $0.pages.allSatisfy { $0.metadata != nil } }
            guard let dock = app.dock, let bookshelf = controller.dock.panels[DockPanels.bookshelf] as? BookshelfPanel,
                  let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel,
                  let shelfView = bookshelf.collection, let listView = pageList.collection else {
                log.check(false, "默认布局里应有两个面板，且已绑定窗口")
                exit(log.summarize())
            }
            await waitFor { shelfView.items.count == 5 }
            checkLegacySettings()
            await checkStyles(window: window, bookshelf: bookshelf, pageList: pageList, shelfView: shelfView, listView: listView)
            await checkIndependence(bookshelf: bookshelf, pageList: pageList)
            await checkPageSort(controller, pageList: pageList, listView: listView)
            await checkShelfSort(controller, bookshelf: bookshelf, shelfView: shelfView)
            await checkNavigation(controller, window: window, bookshelf: bookshelf, shelfView: shelfView, listView: listView, shelf: shelf)
            await checkOptionsMenu(controller, bookshelf: bookshelf)
            await checkFloating(controller, dock: dock, shelf: shelf)
        } catch {
            log.check(false, "面板自检失败：\(error)")
        }
        try? FileManager.default.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: 夹具

    /// 书架：alpha、bravo、charlie 三本图片书，clips 一本视频书，empty 一个空目录。
    /// bravo 的大小居中，修改时间最新。
    private func makeShelf(fixtures: URL) throws -> URL {
        let shelf = temporary.appending(path: "shelf")
        let manager = FileManager.default
        for (name, pages, width) in [("alpha", 3, 400), ("bravo", 6, 900), ("charlie", 4, 1200)] {
            let book = shelf.appending(path: name)
            try manager.createDirectory(at: book, withIntermediateDirectories: true)
            for page in 1...pages {
                let hue = CGFloat(page) / CGFloat(pages + 1)
                try writePNG(to: book.appending(path: String(format: "p%02d.png", page)), width: width, height: 900, hue: hue)
            }
        }
        let clips = shelf.appending(path: "clips")
        try manager.createDirectory(at: clips, withIntermediateDirectories: true)
        try manager.copyItem(at: fixtures.appending(path: "local/generated/video/h264.mp4"), to: clips.appending(path: "a.mp4"))
        try writePNG(to: clips.appending(path: "b.png"), width: 600, height: 400, hue: 0.4)
        try manager.createDirectory(at: shelf.appending(path: "empty"), withIntermediateDirectories: true)
        return shelf
    }

    private func writePNG(to url: URL, width: Int, height: Int, hue: CGFloat) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    // MARK: 检查

    private func checkLegacySettings() {
        let legacy: JSONValue = .object(["style": .string("list")])
        let made = DockPanels.type(DockPanels.bookshelf)!.instantiate(legacy)
        log.check(made.error == nil, "旧的 {\"style\":\"list\"} 能解码：\(String(describing: made.error))")
        let settings = (made.panel as? CollectionPanel)?.settings
        log.check(settings?.style == .list && settings?.itemExtent == PanelExtent.standard && settings?.sort == nil, "新字段取默认值")
    }

    private func checkStyles(window: NSWindow, bookshelf: BookshelfPanel, pageList: PageListPanel, shelfView: CollectionView, listView: CollectionView) async {
        // 列表：每本书一行，书架显示类型，页面列表显示尺寸和大小。
        log.check(shelfView.rowCount == 5, "书架列表 5 行：\(shelfView.rowCount)")
        log.check(listView.rowCount == 6, "页面列表 6 行：\(listView.rowCount)")
        log.check(shelfView.current == shelfView.items.firstIndex { $0.name == "bravo" }, "书架高亮当前书")
        log.check(listView.current == 0, "页面列表高亮当前页")
        log.check(listView.cellText(row: 0).first == "p01.png" && listView.cellText(row: 0).last?.hasPrefix("900×900") == true, "页面列表的行：\(listView.cellText(row: 0))")
        await waitFor { !shelfView.items.contains { $0.canvas.isPending && $0.name != "empty" } }
        log.check(shelfView.items.first { $0.name == "empty" }?.canvas.isPending == true, "空目录没有封面")
        await settle()
        log.snapshot(window, "list")

        // 表格。
        bookshelf.setStyle(.table)
        pageList.setStyle(.table)
        await settle()
        log.check(listView.cellText(row: 1).count == 3, "表格三列：\(listView.cellText(row: 1))")
        log.snapshot(window, "table")

        // 网格：有标题。
        bookshelf.setStyle(.grid)
        pageList.setStyle(.grid)
        await settle()
        log.check(listView.canvas.kind == .grid && listView.canvas.items.first?.label?.hasSuffix("p01.png") == true, "网格带标题")
        log.check(listView.canvas.selection == [0], "画布选中当前页")
        await waitFor { shelfView.canvas.placedCount == 5 }
        log.snapshot(window, "grid")

        // 瀑布流：封面的宽高比决定排版；空目录按 2:3，前缀不被卡住。
        bookshelf.setStyle(.masonry)
        pageList.setStyle(.masonry)
        await waitFor { shelfView.canvas.placedCount == 5 && listView.canvas.placedCount == 6 }
        log.check(shelfView.canvas.placedCount == 5, "书架瀑布流全部排好：\(shelfView.canvas.placedCount)")
        let empty = shelfView.items.firstIndex { $0.name == "empty" }
        log.check(empty.flatMap { shelfView.items[$0].canvas.aspectRatio } == 2.0 / 3, "没有封面的项按 2:3")
        let bravo = shelfView.items.firstIndex { $0.name == "bravo" }
        log.check(bravo.flatMap { shelfView.items[$0].canvas.aspectRatio } == 1, "封面的宽高比来自元数据")
        await settle()
        log.snapshot(window, "masonry")
        bookshelf.setStyle(.list)
        pageList.setStyle(.list)
        await settle()
    }

    private func checkIndependence(bookshelf: BookshelfPanel, pageList: PageListPanel) async {
        bookshelf.setStyle(.grid)
        bookshelf.setItemExtent(220)
        bookshelf.setSort(SortSpec(key: .size))
        pageList.setStyle(.table)
        pageList.setItemExtent(90)
        pageList.setSort(SortSpec(key: .name, ascending: false))
        await settle()
        log.check(bookshelf.settings.style == .grid && bookshelf.settings.itemExtent == 220 && bookshelf.settings.sort?.key == .size, "书架的设置：\(bookshelf.settings)")
        log.check(pageList.settings.style == .table && pageList.settings.itemExtent == 90 && pageList.settings.sort?.key == .name, "页面列表的设置：\(pageList.settings)")
        let encoded = app.dock?.current.settings[DockPanels.bookshelf]
        let decoded = encoded.flatMap { try? JSONDecoder().decode(CollectionPanelSettings.self, from: JSONEncoder().encode($0)) }
        log.check(decoded == bookshelf.settings, "面板设置写进布局并能解回：\(String(describing: encoded))")
        bookshelf.setStyle(.list)
        bookshelf.setSort(nil)
        pageList.setStyle(.list)
        pageList.setSort(nil)
        await settle()
    }

    private func checkPageSort(_ controller: ReaderWindowController, pageList: PageListPanel, listView: CollectionView) async {
        let session = controller.session
        let frames = session.frames
        let bookOrder = session.book?.pages.map(\.entry.name) ?? []
        pageList.setSort(SortSpec(key: .name, ascending: false))
        await settle()
        log.check(listView.items.map(\.name) == bookOrder.reversed(), "选了排序后面板倒序：\(listView.items.map(\.name))")
        log.check(session.frames == frames && session.book?.pages.map(\.entry.name) == bookOrder, "翻页顺序不变")
        session.go(.index(0))
        session.go(.nextFrame)
        await settle()
        log.check(session.currentPage == 1, "翻页按书的顺序：\(session.currentPage)")
        log.check(listView.current == listView.items.firstIndex { $0.name == bookOrder[1] }, "高亮的是这一页在面板里的位置：\(String(describing: listView.current))")
        // 面板倒序时点第一行，打开的是书里最后一页。
        pageList.activate(0)
        await settle()
        log.check(session.currentPage == bookOrder.count - 1, "点击按面板顺序定位：\(session.currentPage)")
        pageList.setSort(nil)
        await settle()
        log.check(listView.items.map(\.name) == bookOrder, "选「跟随书」后恢复")
        log.check(pageList.settings.sort == nil, "跟随书不存排序")
        session.go(.index(0))
    }

    private func checkShelfSort(_ controller: ReaderWindowController, bookshelf: BookshelfPanel, shelfView: CollectionView) async {
        let session = controller.session
        log.check(session.neighborSort == SortSpec(key: .name), "书架默认按名称决定下一本")
        await openNeighbor(controller, expect: "charlie", "名称升序：bravo 的下一本是 charlie")
        await openNeighbor(controller, .backward, expect: "bravo", "回到 bravo")
        bookshelf.setSort(SortSpec(key: .name, ascending: false))
        await waitFor { shelfView.items.first?.name == "empty" }
        log.check(shelfView.items.map(\.name) == ["empty", "clips", "charlie", "bravo", "alpha"], "书架倒序：\(shelfView.items.map(\.name))")
        log.check(session.neighborSort.ascending == false, "排序回报给会话")
        await openNeighbor(controller, expect: "alpha", "名称降序：bravo 的下一本是 alpha")
        await openNeighbor(controller, .backward, expect: "bravo", "回到 bravo")
        bookshelf.setSort(nil)
        await waitFor { shelfView.items.first?.name == "alpha" }
        await settle()
    }

    private func checkNavigation(_ controller: ReaderWindowController, window: NSWindow, bookshelf: BookshelfPanel, shelfView: CollectionView, listView: CollectionView, shelf: URL) async {
        // 真实事件点击书架的行。
        guard let row = shelfView.items.firstIndex(where: { $0.name == "clips" }) else {
            log.check(false, "找不到 clips 的行")
            return
        }
        await click(row: row, in: shelfView, window: window)
        await waitFor { controller.session.book?.location.name == "clips" && controller.session.book?.pages.allSatisfy { $0.metadata != nil } == true }
        await waitFor { listView.items.first?.canvas.badge?.contains(":") == true }
        log.check(controller.session.book?.location.name == "clips", "点击书架的行打开书")
        let video = listView.items.first { $0.name == "a.mp4" }
        log.check(video?.canvas.badge?.contains(":") == true, "视频项有时长：\(String(describing: video?.canvas.badge))")
        log.check(listView.items.first { $0.name == "b.png" }?.canvas.badge == nil, "图片没有角标")
        log.check(shelfView.current == row, "高亮跟到新书")

        // 真实事件点击页面列表。
        await click(row: 1, in: listView, window: window)
        await settle()
        log.check(controller.session.currentPage == 1, "点击页面列表的行翻到那一页：\(controller.session.currentPage)")

        // 上一层：目录变成 shelf 的父目录，这个层级里只有 shelf 一本。
        bookshelf.goUp()
        await waitFor { shelfView.items.contains { $0.name == "shelf" } }
        log.check(shelfView.items.contains { $0.name == "shelf" }, "可以进入上一层目录：\(shelfView.items.map(\.name))")
        log.check(shelfView.current == nil, "上一层没有当前书的高亮")
        // 双击文件夹进入这一层，再回到书架。
        if let parent = shelfView.items.firstIndex(where: { $0.name == "shelf" }) {
            bookshelf.doubleClicked(parent)
            await waitFor { shelfView.items.contains { $0.name == "clips" } }
            log.check(shelfView.items.count == 5, "双击进入文件夹：\(shelfView.items.map(\.name))")
        }
        log.check(controller.session.book?.location.name == "clips", "浏览目录不换书")
    }

    private func checkOptionsMenu(_ controller: ReaderWindowController, bookshelf: BookshelfPanel) async {
        guard let area = controller.dock.areas[.left] else { return }
        let menu = area.optionsMenu()
        let titles = menu.items.map(\.title)
        log.check(titles.contains(String(localized: "排序")) && titles.contains(String(localized: "浮动")) && titles.contains(String(localized: "隐藏停靠区")), "⋯ 菜单有排序、浮动、隐藏：\(titles)")
        if let index = menu.items.firstIndex(where: { $0.title == CollectionStyle.grid.title }) {
            menu.performActionForItem(at: index)
            await settle()
            log.check(bookshelf.settings.style == .grid, "经 ⋯ 菜单改样式")
            bookshelf.setStyle(.list)
        } else {
            log.check(false, "⋯ 菜单没有样式")
        }
        let split = area.optionsMenu()
        if let index = split.items.firstIndex(where: { $0.title == String(localized: "改为上下分割") }) {
            split.performActionForItem(at: index)
            await settle()
            log.check(controller.dock.dockLayout.left.style == .split, "经 ⋯ 菜单改成上下分割")
            controller.dock.perform { $0.togglingStyle(.left) }
            await settle()
        } else {
            log.check(false, "⋯ 菜单没有分割")
        }
    }

    /// 浮动的页面列表随活动窗口切换内容（C2.13）。
    private func checkFloating(_ first: ReaderWindowController, dock: DockCoordinator, shelf: URL) async {
        dock.float(DockPanels.pageList, from: first.dock, at: nil)
        await settle()
        guard let floating = dock.floatingWindows[DockPanels.pageList]?.panel as? PageListPanel, let view = floating.collection,
              let second = app.newWindow() else {
            log.check(false, "浮动面板没有创建")
            return
        }
        await open(second, shelf.appending(path: "alpha")) { $0.isEnumerated }
        second.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive {
            print("INFO App 不在前台，窗口成不了主窗口，直接切换活动窗口")
            dock.activate(second.dock)
        }
        await waitFor { floating.boundSession == second.session.id && view.items.count == 3 }
        log.check(view.items.map(\.name) == ["p01.png", "p02.png", "p03.png"], "切到窗口 2，浮动面板显示 alpha：\(view.items.map(\.name))")
        first.window?.makeKeyAndOrderFront(nil)
        await waitFor { floating.boundSession == first.session.id && view.items.count == 2 }
        log.check(view.items.map(\.name) == ["a.mp4", "b.png"], "切回窗口 1，显示 clips：\(view.items.map(\.name))")
        floating.activate(1)
        await settle()
        log.check(first.session.currentPage == 1, "浮动面板的点击作用于活动窗口")
        second.window?.close()
        dock.dockFloating(DockPanels.pageList)
        await settle()
    }

    // MARK: 工具

    private func open(_ controller: ReaderWindowController, _ url: URL, until condition: (Book) -> Bool) async {
        controller.open([url])
        for _ in 0..<400 {
            if let book = controller.session.book, book.location.name == url.lastPathComponent, condition(book) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await settle()
    }

    private func openNeighbor(_ controller: ReaderWindowController, _ direction: NavigationDirection = .forward, expect name: String, _ message: String) async {
        controller.openNeighbor(direction)
        await waitFor { controller.session.book?.location.name == name }
        log.check(controller.session.book?.location.name == name, "\(message)：\(controller.session.book?.location.name ?? "")")
        await settle()
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// 经 `NSApp.sendEvent` 点击一行。App 无法激活（屏幕锁定或别的 App 占着前台）时第一下点击只会激活窗口，改为直接触发行的动作。
    private func click(row: Int, in view: CollectionView, window: NSWindow) async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await waitFor { NSApp.isActive && window.isKeyWindow }
        guard NSApp.isActive, window.isKeyWindow, let point = view.rowPointInWindow(row) else {
            print("INFO App 未激活，直接触发行的动作")
            view.onActivate?(row)
            return
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!)
        }
    }
}

#endif
