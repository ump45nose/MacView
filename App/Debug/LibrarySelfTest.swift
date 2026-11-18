#if DEBUG
import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreVideo
import MVCommands
import MVFoundation
import MVLayout
import MVLibraryData
import MVReading
import MVServices
import MVSettings

/// 历史、书签、播放列表与虚拟书的自检（`-MVLibrarySelfTest YES`，真实服务）。
///
/// 测试书在隔离 support 目录下自建：文件夹书 alpha、bravo、echo，压缩包书 charlie.zip，含 1 个视频的 delta。
/// 点击、拖放和按键经 `NSApp.sendEvent` 走真实事件路径（拖放：mouseDown 发起真实拖动会话，再排队拖动事件和 mouseUp）；
/// 右键菜单取视图的 `menu(for:)` 后执行菜单项，弹出按钮选项后发送它的动作。拖放离不开前台，要加 `-MVSelfTestActivate YES`。
/// 不能自动化的项（重启后保持、3000 项流畅度、“连接”打开卷、拖到标签上停留切换）记 SKIP。
@MainActor
final class LibrarySelfTest {
    static let launchKey = "MVLibrarySelfTest"
    private static let pages = ["alpha": 4, "bravo": 3, "charlie.zip": 3, "delta": 3, "echo": 2, "bravo-2": 3]
    private let app: AppDelegate, log = SelfTestLog(), fm = FileManager.default
    private let temporary = TestPresentation.scratchDirectory("library")
    private var shelf: URL { temporary.appending(path: "shelf", directoryHint: .isDirectory) }
    private var controller: ReaderWindowController!
    private var window: NSWindow!
    private var services: CoreServices!
    private var library: (any LibraryStore)!
    private var history: HistoryPanel!
    private var bookmarks: BookmarksPanel!
    private var playlist: PlaylistPanel!
    private var shelfView: CollectionView!
    private var pageList: PageListPanel!
    private var listA: UUID?, listB: UUID?
    private var shelfLocation = Location(root: .local)
    private var eventNumber = 1000

    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
        setbuf(stdout, nil)
        UserDefaults.standard.register(defaults: ["NSAllowMultipleDrags": true])
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            print("FAIL 资料库自检总超时（300s）"); fflush(stdout); _Exit(2)
        }
        let test = LibrarySelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) { self.app = app }

    private func run() async {
        guard let services = app.services, let library = services.library, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "资料库自检需要真实服务、资料库和窗口"); exit(log.summarize())
        }
        self.services = services; self.library = library; self.controller = controller; self.window = window
        window.setContentSize(NSSize(width: 1360, height: 820))
        TestPresentation.place(window)
        window.makeKeyAndOrderFront(nil)
        TestPresentation.activateIfAllowed()
        do {
            try await makeBooks()
            try await layoutChecks()
            try await dragPayloadChecks()
            try await pageRecheckChecks(interactive: false)
            guard TestPresentation.activationAllowed, await until("App 进入前台", attempts: 1200, condition: { NSApp.isActive }) else {
                throw Failure(description: "资料库自检需要前台；请解锁屏幕并加 -\(TestPresentation.activateKey) YES，经 open -n 启动")
            }
            try await historyChecks()
            try await bookmarkChecks()
            try await unavailableChecks()
            try await playlistChecks()
            try await debugChecks()
            try await virtualBookChecks()
            try await playlistEditChecks()
            try await deleteChecks()
            try await relocateChecks()
            try await pageRecheckChecks(interactive: true)
            try await clearChecks()
        } catch { log.check(false, "资料库自检中断：\(error)") }
        skip("C2.1、C2.2、C2.12 重启后保持：要重启 App；历史、书签、列表的持久化由 MVLibraryData 单元测试 c12–c14 覆盖，布局由 -MVDockSelfTest restore 覆盖")
        skip("C2.3 “连接”打开 mountURL：会弹出系统连接服务器的对话框，只检查按钮存在，由用户确认")
        skip("C2.6 3000 项列表的滚动、拖动排序与翻页流畅度：由 mvbench library seed-playlist 与用户目视确认")
        skip("拖到面板标签上停留约 0.35 秒切到该面板：本自检用上下分割显示全部面板，由用户确认")
        try? fm.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: C2.12 面板勾选项

    private func layoutChecks() async throws {
        let dock = controller.dock
        let ids = [PanelID("history"), PanelID("bookmarks"), PanelID("playlist")]
        log.check(ids.allSatisfy { dock.dockLayout.placement(of: $0) == nil }, "C2.12 没有登记新面板的布局里三个新面板默认不出现")
        let titles = dock.areas[.left]!.optionsMenu().items.prefix(DockPanels.all.count).map(\.title)
        log.check(titles == DockPanels.all.map(\.title), "C2.12 停靠区 ⋯ 菜单列出全部面板：\(titles)")
        perform(dock.areas[.left]!.optionsMenu(), String(localized: "历史")); await settle()
        perform(dock.areas[.left]!.optionsMenu(), String(localized: "书签")); await settle()
        perform(dock.areas[.right]!.optionsMenu(), String(localized: "播放列表")); await settle()
        log.check(dock.dockLayout.visiblePanels(in: .left) == [DockPanels.bookshelf] + ids.prefix(2) && dock.dockLayout.visiblePanels(in: .right) == [DockPanels.pageList, ids[2]],
                  "C2.12 左区勾上历史、书签，右区勾上播放列表后出现为标签：\(dock.dockLayout.visiblePanels(in: .left)) / \(dock.dockLayout.visiblePanels(in: .right))")
        let checked = dock.areas[.left]!.optionsMenu().items.filter { $0.state == .on }.map(\.title)
        log.check(checked == [String(localized: "书架"), String(localized: "历史"), String(localized: "书签")], "C2.12 左区 ⋯ 菜单勾选状态与显示一致：\(checked)")
        perform(dock.areas[.right]!.optionsMenu(), String(localized: "历史")); await settle()
        let moved = if case .docked(.right, _)? = dock.dockLayout.placement(of: ids[0]) { true } else { false }
        log.check(moved && !dock.dockLayout.visiblePanels(in: .left).contains(ids[0]), "C2.12 在右区勾上历史则从左区搬到右区")
        perform(dock.areas[.right]!.optionsMenu(), String(localized: "历史")); await settle()
        log.check(!DockEdge.allCases.contains { dock.dockLayout.visiblePanels(in: $0).contains(ids[0]) }, "C2.12 取消勾选即隐藏")
        perform(dock.areas[.left]!.optionsMenu(), String(localized: "历史")); await settle()
        dock.perform { $0.moving(ids[0], to: .area(.left, index: 1)) }
        try? await Task.sleep(for: DockCoordinator.saveDelay + .milliseconds(400))
        let saved = UserDefaults.standard.string(forKey: DockCoordinator.layoutFileKey).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        log.check(["history", "bookmarks", "playlist"].allSatisfy(saved.contains), "C2.12 勾选后的布局写进 layout.json")
        // 上下分割：三个面板同时可见，便于检查和截图。
        dock.perform { $0.togglingStyle(.left).togglingStyle(.right) }
        await settle()
        guard let history = dock.panels[ids[0]] as? HistoryPanel, let bookmarks = dock.panels[ids[1]] as? BookmarksPanel,
              let playlist = dock.panels[ids[2]] as? PlaylistPanel, let shelf = dock.panels[DockPanels.bookshelf] as? BookshelfPanel,
              let pageList = dock.panels[DockPanels.pageList] as? PageListPanel else { throw Failure(description: "找不到资料库面板") }
        self.history = history; self.bookmarks = bookmarks; self.playlist = playlist; self.pageList = pageList
        shelf.setStyle(.list); pageList.setStyle(.list)
        shelfView = shelf.collection
        await settle()
        log.snapshot(window, "library-empty")
    }

    /// 先验证生产拖出路径写出的类型；这一步不冒充跨面板真实放下。
    private func dragPayloadChecks() async throws {
        await open("alpha")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard let shelf = controller.dock.panels[DockPanels.bookshelf] as? BookshelfPanel else { throw Failure(description: "没有书架") }
        for style in CollectionStyle.allCases {
            shelf.setStyle(style)
            await settle()
            guard let index = shelfView.items.firstIndex(where: { $0.name == "bravo" }), let writer = shelfView.pasteboardWriter(forItemAt: index) else { throw Failure(description: "没有书架拖出写入器") }
            board.clearContents(); board.writeObjects([writer])
            log.check(LibraryPasteboard.locations(from: board) == [book("bravo")] && board.availableType(from: [.fileURL]) != nil,
                      "C2.7 \(style) 的生产拖出保留文件 URL 与内部位置")
        }
        shelf.setStyle(.list)
        await open("charlie.zip")
        guard let writer = pageList.collection?.pasteboardWriter(forItemAt: 0) else { throw Failure(description: "没有 ZIP 页拖出写入器") }
        board.clearContents(); board.writeObjects([writer])
        log.check(writer is NSFilePromiseProvider && LibraryPasteboard.locations(from: board) == [controller.session.book!.pages[0].id], "ZIP 页生产拖出保留文件承诺与内部位置")
        app.fileOps?.dragSessionEnded(operation: [])
        await open("alpha")
    }

    // MARK: C2.1 历史、C2.13 上限

    private func historyChecks() async throws {
        await open("alpha")
        controller.session.go(.index(2))
        _ = await until("alpha 翻到第 3 页并记下") { await self.services.settings.bookMemory(for: self.book("alpha"))?.lastPageIndex == 2 }
        for name in ["bravo", "charlie.zip", "delta", "echo"] { await open(name) }
        _ = await until("历史列出 5 本") { self.history.entries.count == 5 }
        log.check(names(history.entries) == ["echo", "delta", "charlie.zip", "bravo", "alpha"], "C2.1 历史从新到旧：\(names(history.entries))")
        let table = tableView(in: history.view)
        await click(rowPoint(table, 4))
        let reopened = await until("从历史打开 alpha") { self.controller.session.book?.location.name == "alpha" && self.controller.session.currentPage == 2 }
        log.check(reopened, "C2.1 单击历史行打开 alpha 并回到上次的第 3 页：\(controller.session.currentPage + 1)")
        _ = await until("alpha 排到最前") { self.history.entries.first?.book.name == "alpha" }
        guard let bravo = history.entries.firstIndex(where: { $0.book.name == "bravo" }) else { throw Failure(description: "历史里没有 bravo") }
        perform(contextMenu(table, row: bravo), String(localized: "从历史中删除"))
        let removed = await until("删除 bravo") { !self.names(self.history.entries).contains("bravo") }
        log.check(removed && history.entries.count == 4, "C2.1 右键“从历史中删除”只删这一条：\(names(history.entries))")

        guard let settings = app.openSettings() else { throw Failure(description: "打不开设置窗口") }
        settings.state.page = .browse
        await settle()
        guard let settingsWindow = settings.window, let content = settingsWindow.contentView,
              let field = views(NSTextField.self, in: content).first(where: {
                  $0.isEditable && $0.stringValue == String(settings.state.model.global.historyLimit)
              }) else { throw Failure(description: "找不到设置里的历史保留本数输入框") }
        await click(center(of: field), in: settingsWindow)
        await type("3", in: settingsWindow)
        let trimmed = await until("上限 3 立即生效") { self.history.entries.count == 3 }
        log.check(trimmed && names(history.entries) == ["alpha", "echo", "delta"], "C2.13 上限改为 3 后立即只留最近 3 本：\(names(history.entries))")
        await settle()
        if let settingsWindow = settings.window { log.snapshot(settingsWindow, "library-settings-history") }
        settings.window?.close()
        for name in ["alpha", "bravo", "charlie.zip", "delta", "echo"] { await open(name) }
        _ = await until("历史只剩最近 3 本") { self.names(self.history.entries) == ["echo", "delta", "charlie.zip"] }
        log.check(names(history.entries) == ["echo", "delta", "charlie.zip"] && texts(in: history.view).contains("3 / 3"), "C2.13 依次打开 5 本书，历史只剩最近 3 本，信息行显示 3 / 3：\(names(history.entries))")
    }

    // MARK: C2.2 书签、C2.7 加入书签

    private func bookmarkChecks() async throws {
        await open("alpha")
        _ = await until("书架列出 5 本") { self.shelfView.items.count == 5 }
        let outline = tableView(in: bookmarks.view)
        guard let bravoRow = shelfView.items.firstIndex(where: { $0.name == "bravo" }), let start = shelfView.rowPointInWindow(bravoRow) else { throw Failure(description: "书架里没有 bravo") }
        await drag(from: start, to: outline.convert(NSPoint(x: outline.bounds.midX, y: 30), to: nil))
        let dropped = await until("拖进书签") { await self.tree() == "bravo" }
        log.check(dropped, "C2.7 从书架拖一本书进书签面板：\(await tree())")
        guard dropped else { throw Failure(description: "书架拖入书签失败，停止依赖该书签的后续断言") }
        log.check(await message(String(localized: "已加入书签：\("bravo")")), "C2.7 加入后状态栏提示“已加入书签”")

        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_D, [.command])
        log.check(await until("⌘D 加入书签") { await self.tree() == "bravo, alpha" }, "C2.7 查看器里 ⌘D 收藏当前书：\(await tree())")
        await sendKey(kVK_ANSI_D, [.command])
        let again = await message(String(localized: "《\("alpha")》已在书签里"))
        let unchanged = await tree() == "bravo, alpha"
        log.check(again && unchanged, "C2.7 同一本书再按 ⌘D 提示已在书签里")
        let shelfTable = tableView(in: shelfView)
        guard let charlie = shelfView.items.firstIndex(where: { $0.name == "charlie.zip" }) else { throw Failure(description: "书架里没有 charlie.zip") }
        perform(contextMenu(shelfTable, row: charlie), String(localized: "加入书签"))
        log.check(await until("书架右键加入书签") { await self.tree() == "bravo, alpha, charlie.zip" }, "C2.7 书架右键“加入书签”：\(await tree())")

        guard let addFolder = button(String(localized: "＋ 文件夹"), in: bookmarks.view) else { throw Failure(description: "找不到“＋ 文件夹”按钮") }
        await click(center(of: addFolder))
        _ = await until("新文件夹进入改名") { self.window.firstResponder is NSTextView }
        await type("画集")
        log.check(await until("文件夹改名") { await self.tree() == "bravo, alpha, charlie.zip, 画集[]" }, "C2.2 点“＋ 文件夹”新建并回车确认名字：\(await tree())")
        guard let folderRow = row(outline, "画集") else { throw Failure(description: "书签里没有“画集”") }
        perform(contextMenu(outline, row: folderRow), String(localized: "新建文件夹"))
        _ = await until("子文件夹进入改名") { self.window.firstResponder is NSTextView }
        await type(nil)
        let folder = String(localized: "新文件夹")
        log.check(await until("子文件夹") { await self.tree() == "bravo, alpha, charlie.zip, 画集[\(folder)[]]" }, "C2.2 文件夹可多级，Esc 取消改名保留原名：\(await tree())")
        await settle()

        guard let bravoMark = row(outline, "bravo"), let folderMark = row(outline, "画集") else { throw Failure(description: "书签行缺失") }
        await drag(from: rowPoint(outline, bravoMark), to: rowPoint(outline, folderMark))
        log.check(await until("拖进文件夹") { await self.tree() == "alpha, charlie.zip, 画集[\(folder)[], bravo]" }, "C2.2 把书签拖进文件夹：\(await tree())")
        await settle()
        guard let charlieMark = row(outline, "charlie.zip"), let alphaMark = row(outline, "alpha") else { throw Failure(description: "书签行缺失") }
        await drag(from: rowPoint(outline, charlieMark), to: rowPoint(outline, alphaMark, fraction: 0.2))
        log.check(await until("拖动排序") { await self.tree() == "charlie.zip, alpha, 画集[\(folder)[], bravo]" }, "C2.2 拖动排序：\(await tree())")
        await settle()

        guard let alphaRow = row(outline, "alpha") else { throw Failure(description: "书签里没有 alpha") }
        await click(rowPoint(outline, alphaRow), count: 2)
        _ = await until("双击进入改名") { self.window.firstResponder is NSTextView }
        await type("阿尔法")
        let renamed = await until("改显示名") { await self.tree() == "charlie.zip, 阿尔法(alpha), 画集[\(folder)[], bravo]" }
        let detail = row(outline, "阿尔法").map { texts(in: outline.view(atColumn: 0, row: $0, makeIfNecessary: true)!) } ?? []
        log.check(renamed && detail.contains(String(localized: "原名：\("alpha")")), "C2.2 双击改显示名、回车确认，第二行显示原名：\(detail)")
        await settle()
        guard let labelRow = row(outline, "阿尔法") else { throw Failure(description: "书签里没有“阿尔法”") }
        perform(contextMenu(outline, row: labelRow), String(localized: "恢复原名"))
        log.check(await until("恢复原名") { await self.tree() == "charlie.zip, alpha, 画集[\(folder)[], bravo]" }, "C2.2 右键“恢复原名”")
        await settle()

        await open("echo")
        guard let openRow = row(outline, "alpha") else { throw Failure(description: "书签里没有 alpha") }
        await click(rowPoint(outline, openRow))
        log.check(await until("从书签打开") { self.controller.session.book?.location.name == "alpha" && self.controller.session.currentPage == 2 }, "C2.2 单击书签打开 alpha 并回到上次的第 3 页")
        guard let removeRow = row(outline, "charlie.zip") else { throw Failure(description: "书签里没有 charlie.zip") }
        perform(contextMenu(outline, row: removeRow), String(localized: "从书签中移除"))
        log.check(await until("移除书签") { await self.tree() == "alpha, 画集[\(folder)[], bravo]" }, "C2.2 右键“从书签中移除”")
        log.check(["alpha", "bravo", "charlie.zip"].allSatisfy { exists(shelf.appending(path: $0)) }, "C2.2 改显示名、移动、移除书签后原文件名不变")
    }

    // MARK: C2.3 不可用（S10）

    private func unavailableChecks() async throws {
        await open("echo")
        let outline = tableView(in: bookmarks.view), historyTable = tableView(in: history.view)
        // 没挂上的网络根：不存在的主机上的共享。
        let offline = Location(root: .network(scheme: "smb", host: "macview-selftest.invalid", share: "Offline"), layers: [["画册"]])
        _ = try await library.addBookmarks([offline], into: nil, at: nil)
        try await library.recordOpened(offline, at: Date())
        let volumeText = String(localized: "网络卷没有连接")
        let marked = await until("网络根的书签变灰") { self.row(outline, "画册").flatMap { self.badge(outline, row: $0) }?.isHidden == false }
        let mark = row(outline, "画册").flatMap { badge(outline, row: $0) }
        log.check(marked && mark?.toolTip == volumeText, "C2.3 没挂上的网络根的书签变灰并带“网络卷没有连接”标记：\(mark?.toolTip ?? "无")")
        let historyMarked = await until("网络根的历史变灰") {
            self.history.entries.firstIndex { $0.book == offline }.flatMap { self.badge(historyTable, row: $0) }?.isHidden == false
        }
        log.check(historyMarked, "C2.3 没挂上的网络根的历史行变灰并带标记")
        guard let offlineRow = row(outline, "画册") else { throw Failure(description: "书签里没有网络根的条目") }
        await click(rowPoint(outline, offlineRow))
        _ = await until("弹出原因") { self.popoverWindow() != nil }
        let volumeTexts = popoverWindow().map { texts(in: $0.contentView!) } ?? []
        let connect = popoverWindow().flatMap { button(String(localized: "连接"), in: $0.contentView!) }
        log.check(volumeTexts.contains(volumeText) && connect != nil, "C2.3 点击不可用的行弹出原因“网络卷没有连接”，带“连接”按钮：\(volumeTexts.prefix(2))")
        if let popover = popoverWindow() { log.snapshot(popover, "library-popover-volume") }
        if let popover = popoverWindow(), let remove = button(String(localized: "移除"), in: popover.contentView!) {
            await click(center(of: remove), in: popover)
        }
        log.check(await until("移除网络根书签") { await self.tree() == "alpha, 画集[\(String(localized: "新文件夹"))[], bravo]" }, "C2.3 原因弹出层里“移除”后条目消失")

        // Finder 里移走再移回：切回 MacView 时重查（这里发出 App 激活的通知代替切换应用）。
        let alpha = shelf.appending(path: "alpha"), away = temporary.appending(path: "alpha-away")
        try fm.moveItem(at: alpha, to: away)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let missing = String(localized: "找不到")
        let gone = await until("移走后变灰") {
            self.row(outline, "alpha").flatMap { self.badge(outline, row: $0) }?.toolTip == missing
                && self.history.entries.firstIndex { $0.book.name == "alpha" }.flatMap { self.badge(historyTable, row: $0) }?.toolTip == missing
        }
        log.check(gone, "C2.3 在 MacView 之外移走后切回，书签和历史里的 alpha 变灰并带“找不到”标记")
        await settle()
        log.snapshot(window, "library-unavailable")
        if let alphaRow = history.entries.firstIndex(where: { $0.book.name == "alpha" }) { await click(rowPoint(historyTable, alphaRow)) }
        _ = await until("弹出找不到的原因") { self.popoverWindow() != nil }
        let missingTexts = popoverWindow().map { texts(in: $0.contentView!) } ?? []
        log.check(missingTexts.contains(String(localized: "找不到\(String(localized: "这本书"))")) && popoverWindow().flatMap { button(String(localized: "连接"), in: $0.contentView!) } == nil,
                  "C2.3 找不到的书弹出“找不到这本书”，没有“连接”：\(missingTexts.prefix(2))")
        if let popover = popoverWindow() { log.snapshot(popover, "library-popover-missing") }
        await click(history.view.convert(NSPoint(x: 20, y: 14), to: nil))
        _ = await until("弹出层关闭") { self.popoverWindow() == nil }
        try fm.moveItem(at: away, to: alpha)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        let back = await until("移回后恢复") {
            self.row(outline, "alpha").flatMap { self.badge(outline, row: $0) }?.isHidden == true
                && self.history.entries.firstIndex { $0.book.name == "alpha" }.flatMap { self.badge(historyTable, row: $0) }?.isHidden == true
        }
        log.check(back, "C2.3 移回原处后切回，书签和历史里的 alpha 自动恢复")
    }

    // MARK: C2.8 加到播放列表、C2.4 列表管理

    private func playlistChecks() async throws {
        let pageTable = tableView(in: pageList.collection!), listTable = tableView(in: playlist.view)
        log.check(button(String(localized: "新建播放列表"), in: playlist.view) != nil && texts(in: playlist.view).contains(String(localized: "还没有播放列表")), "C2.4 还没有列表时显示空状态和“新建播放列表”")
        await open("delta")
        await click(rowPoint(pageTable, 0))
        await click(rowPoint(pageTable, 2), flags: .command)
        log.check(pageTable.selectedRowIndexes == IndexSet([0, 2]), "C2.8 页面列表 ⌘ 点击多选两页（含视频）")
        perform(contextMenu(pageTable, row: 2), String(localized: "加到播放列表"), String(localized: "新建播放列表…"))
        let firstName = String(localized: "新播放列表 \(1)")
        _ = await until("新建列表") { self.playlist.lists.count == 1 && self.playlist.items.count == 2 }
        log.check(playlist.lists.map(\.name) == [firstName] && playlist.items.map(\.name) == ["001.png", "clip.mp4"], "C2.8 右键“加到播放列表 ▸ 新建播放列表…”新建并加入：\(playlist.items.map(\.name))")
        listA = playlist.lists.first?.id
        perform(areaMenu(.right), String(localized: "播放列表"), String(localized: "重命名当前列表"))
        _ = await until("列表进入改名") { self.window.firstResponder is NSTextView }
        await type("列表 A")
        log.check(await until("列表改名") { self.playlist.lists.map(\.name) == ["列表 A"] }, "C2.4 ⋯“重命名当前列表”改名：\(playlist.lists.map(\.name))")

        await open("charlie.zip")
        _ = await until("菜单里有列表 A") { LibraryActions.playlists.map(\.name) == ["列表 A"] }
        await click(rowPoint(pageTable, 1))
        let submenu = contextMenu(pageTable, row: 1)?.items.first { $0.title == String(localized: "加到播放列表") }?.submenu
        log.check(submenu?.items.first?.title == "列表 A" && submenu?.items.first?.badge != nil && submenu?.items.last?.title == String(localized: "新建播放列表…"),
                  "C2.8 子菜单最近用的列表排第一并标“最近用”，末尾“新建播放列表…”：\(submenu?.items.map(\.title) ?? [])")
        perform(contextMenu(pageTable, row: 1), String(localized: "加到播放列表"), "列表 A")
        log.check(await message(String(localized: "已加 \(1) 项到「\("列表 A")」")), "C2.8 加入后提示加了几项")
        log.check(try await items(listA) == ["delta/001.png", "delta/clip.mp4", "charlie.zip!/002.png"], "C2.8 列表 A 共 3 项（含压缩包内的页和视频），顺序与操作一致：\(try await items(listA))")

        perform(areaMenu(.right), String(localized: "播放列表"), String(localized: "新建播放列表"))
        _ = await until("新列表进入改名") { self.window.firstResponder is NSTextView && self.playlist.lists.count == 2 }
        await type(nil)
        let nameB = String(localized: "新播放列表 \(2)")
        listB = playlist.lists.first { $0.name == nameB }?.id
        log.check(listB != nil && playlist.items.isEmpty && texts(in: playlist.view).contains(String(localized: "列表是空的")), "C2.4 ⋯“新建播放列表”新建并切到它，Esc 保留默认名：\(playlist.lists.map(\.name))")
        await click(rowPoint(pageTable, 0))
        await click(rowPoint(pageTable, 2), flags: .command)
        await drag(from: rowPoint(pageTable, 0), to: listTable.convert(NSPoint(x: listTable.bounds.midX, y: 30), to: nil))
        log.check(await until("拖进列表 B") { (try? await self.items(self.listB)) == ["charlie.zip!/001.png", "charlie.zip!/003.png"] }, "C2.8 页面列表拖 2 页进列表 B：\(try await items(listB))")
        await click(rowPoint(pageTable, 1))
        await click(rowPoint(pageTable, 2), flags: .shift)
        await sendKey(kVK_ANSI_L, [.command])
        log.check(await message(String(localized: "已加 \(1) 项到「\(nameB)」，\(1) 项已在列表中")), "C2.8 页面列表 ⇧ 多选 2 页按 ⌘L 加到最近用的列表，提示其中 1 项已在列表中")
        await open("echo")
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_L, [.command])
        let expectedB = ["charlie.zip!/001.png", "charlie.zip!/003.png", "charlie.zip!/002.png", "echo/001.png"]
        log.check(await until("查看器 ⌘L") { (try? await self.items(self.listB)) == expectedB }, "C2.8 查看器 ⌘L 把当前页加到最近用的列表，顺序与操作一致：\(try await items(listB))")
        let titles = popupTitles()
        log.check(titles == [String(localized: "\("列表 A")（\(3)）"), String(localized: "\(nameB)（\(4)）") + String(localized: " · 最近用")], "C2.4 列表弹出按钮显示项数，最近用的标“最近用”：\(titles)")
        await choose(listA)
        log.check(playlist.items.map(\.name) == ["001.png", "clip.mp4", "002.png"] && texts(in: playlist.view).contains(String(localized: "\("charlie.zip") 内")), "C2.4 切换列表；行显示文件名与来自哪本书：\(playlist.items.map(\.name))")
        await settle()
        log.snapshot(window, "library-panels")
    }

    // MARK: C2.9 虚拟书

    private func debugChecks() async throws {
        let response = await DebugCommands(app: app).respond(to: Data(#"{"id":1,"command":"state"}"#.utf8))
        let json = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        let state = (json?["result"] as? [String: Any])?["library"] as? [String: Any]
        let histories = try await library.history()
        let lists = state?["playlists"] as? [[String: Any]]
        log.check(json?["ok"] as? Bool == true && state?["historyCount"] as? Int == histories.count
                  && (state?["bookmarks"] as? [Any])?.count == 2
                  && lists?.compactMap { $0["count"] as? Int } == [3, 4],
                  "调试 state.library 包含历史条数、书签树、各列表项数")
        if let output = log.output { try response.write(to: output.appending(path: "library-debug-state.json")) }
    }

    private func virtualBookChecks() async throws {
        guard let listA, let play = button(String(localized: "▶ 当书打开"), in: playlist.view) else { throw Failure(description: "找不到“当书打开”") }
        let session = controller.session, book = Location.playlist(listA)
        await click(center(of: play))
        let opened = await until("当书打开列表 A") { session.book?.location == book && session.book?.pages.count == 3 && session.book?.pages.allSatisfy { $0.metadata != nil } == true }
        let order = (try await library.items(of: listA)).map(\.location)
        log.check(opened && session.book?.pages.map(\.id) == order, "C2.9 列表 A 当书打开，页序与列表一致")
        let titleTexts = window.toolbar?.items.first { $0.itemIdentifier.rawValue == "book.title" }?.view.map(texts(in:)) ?? []
        log.check(window.title == "列表 A" && titleTexts.contains(String(localized: "播放列表")) && titleTexts.contains(String(localized: "\(3) 项，来自 \(2) 本书")),
                  "C2.9 标题前有“播放列表”标记，副标题“3 项，来自 2 本书”：\(titleTexts)")
        log.check(texts(in: controller.viewer).contains { $0.contains("《delta》 · 001.png") }, "C2.9 顶部胶囊显示“来自 《delta》 · 001.png”")
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_RightArrow)
        let playing = await until("视频页可播放") { self.controller.viewer.paged.video?.player?.currentItem?.status == .readyToPlay }
        log.check(playing && session.currentPage == 1, "C2.9 视频页能播放")
        await sendKey(kVK_RightArrow)
        _ = await until("翻到压缩包内的页") { session.currentPage == 2 }
        await settle()
        log.check(placeholders().isEmpty && session.unavailablePages.isEmpty && controller.content.statusBar.pagePathText?.contains("charlie.zip") == true,
                  "C2.9 压缩包内的页正常显示，状态栏显示原文件路径：\(controller.content.statusBar.pagePathText ?? "无")")
        let sortMenu = NSMenu()
        pageList.addOptions(to: sortMenu)
        let note = sortMenu.items.first { $0.title == String(localized: "排序") }?.submenu?.items
        log.check(note?.count == 1 && note?.first?.isEnabled == false && note?.first?.title == String(localized: "虚拟书：页序就是列表顺序"), "C2.9 页面列表的排序菜单不可用并显示说明")
        let dispatcher = app.dispatcher
        log.check(dispatcher?.isEnabled(.bookNext, in: controller, scope: .viewer) == false && dispatcher?.isEnabled(.bookPrevious, in: controller, scope: .viewer) == false, "C2.9 虚拟书里上一本、下一本不可用")
        await sendKey(kVK_ANSI_D, [.command])
        log.check(await message(String(localized: "播放列表不能加入书签")), "C2.7 虚拟书里 ⌘D 提示播放列表不能加入书签")
        log.snapshot(window, "library-virtual-book")

        await sendKey(kVK_ANSI_2)
        await sendKey(kVK_ANSI_D)
        _ = await until("切成双页、适合宽度") { session.settings.pageMode == .double && session.settings.scaleMode == .fitWidth }
        let page = session.currentPage
        try? await Task.sleep(for: .milliseconds(600))
        await open("alpha")
        await click(center(of: play))
        let restored = await until("重新打开列表 A") { session.book?.location == book && session.book?.pages.count == 3 && session.currentPage == page }
        log.check(restored && session.settings.pageMode == .double && session.settings.scaleMode == .fitWidth,
                  "C2.9 关掉再打开回到第 \(page + 1) 页并保持双页与适合宽度：第 \(session.currentPage + 1) 页，\(session.settings.pageMode)，\(session.settings.scaleMode)")
        log.check(await until("历史里有列表 A") { (try? await self.library.history())?.contains { $0.book == book } == true }, "C2.9 历史里出现列表 A")
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_D)
        _ = await until("回到单页") { session.settings.pageMode == .single }
    }

    // MARK: C2.4 双击、C2.5 多选、排序、移除、打开所在的书

    private func playlistEditChecks() async throws {
        guard let listB else { throw Failure(description: "没有列表 B") }
        let session = controller.session, table = tableView(in: playlist.view)
        await choose(listB)
        await click(rowPoint(table, 2), count: 2)
        log.check(await until("双击从该项开始读") { session.book?.location == .playlist(listB) && session.currentPage == 2 }, "C2.4 双击一项当书打开并从该项开始读：第 \(session.currentPage + 1) 页")
        await click(rowPoint(table, 0))
        await click(rowPoint(table, 2), flags: .command)
        await click(rowPoint(table, 3), flags: .shift)
        log.check(table.selectedRowIndexes == IndexSet([0, 2, 3]), "C2.5 列表里 ⌘、⇧ 点击多选：\(Array(table.selectedRowIndexes))")
        await click(rowPoint(table, 3))
        await drag(from: rowPoint(table, 3), to: rowPoint(table, 0, fraction: 0.15))
        let reordered = ["echo/001.png", "charlie.zip!/001.png", "charlie.zip!/003.png", "charlie.zip!/002.png"]
        log.check(await until("拖动排序") { (try? await self.items(listB)) == reordered }, "C2.5 拖动排序：\(try await items(listB))")
        let zip = shelf.appending(path: "charlie.zip"), zipBytes = try Data(contentsOf: zip)
        await click(rowPoint(table, 2))
        await sendKey(kVK_Delete)
        log.check(await until("⌫ 移除") { (try? await self.items(listB)) == ["echo/001.png", "charlie.zip!/001.png", "charlie.zip!/002.png"] }, "C2.5 ⌫ 从列表移除：\(try await items(listB))")
        log.check(await message(String(localized: "已从「\(String(localized: "新播放列表 \(2)"))」移除 \(1) 项，原文件不动")) && (try? Data(contentsOf: zip)) == zipBytes, "C2.5 移除只拿掉条目，原文件不动")
        perform(contextMenu(table, row: 2), String(localized: "打开所在的书"))
        log.check(await until("打开所在的书") { session.book?.location.name == "charlie.zip" && session.currentPage == 1 }, "C2.5 右键“打开所在的书”跳到那本书的那一页：\(session.book?.location.name ?? "无") 第 \(session.currentPage + 1) 页")
    }

    // MARK: C2.10 虚拟书里删除与撤销

    private func deleteChecks() async throws {
        guard let listA, let play = button(String(localized: "▶ 当书打开"), in: playlist.view) else { throw Failure(description: "找不到列表 A") }
        let session = controller.session, table = tableView(in: playlist.view), pageTable = tableView(in: pageList.collection!)
        let file = shelf.appending(path: "delta/001.png")
        await choose(listA)
        await click(center(of: play))
        _ = await until("打开列表 A") { session.book?.location == .playlist(listA) && session.book?.pages.count == 3 }
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_Home)
        _ = await until("回到第 1 页") { session.currentPage == 0 }
        await settle()
        await sendKey(kVK_Delete, [.command])
        _ = await until("删除原文件") { !self.exists(file) && self.app.fileOps?.isBusy == false }
        let shown = await until("占位页") {
            self.placeholders().first?.reason == .missing && self.pageList.collection?.items.first?.failure != nil && self.badge(table, row: 0)?.isHidden == false
        }
        log.check(!exists(file) && shown, "C2.10 ⌘⌫ 删除已显示过的页：原文件进废纸篓，该页变为占位页而非缓存旧图，页面列表与播放列表里该项变灰")
        await settle()
        log.snapshot(window, "library-placeholder")
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_Z, [.command])
        let restored = await until("撤销删除") {
            self.exists(file) && self.placeholders().isEmpty && self.pageList.collection?.items.first?.failure == nil && self.badge(table, row: 0)?.isHidden != false
        }
        log.check(restored, "C2.10 ⌘Z 后原文件回来，页和条目恢复")
        perform(contextMenu(pageTable, row: 1), String(localized: "从列表移除"))
        log.check(await until("从列表移除") { (try? await self.items(listA)) == ["delta/001.png", "charlie.zip!/002.png"] } && exists(shelf.appending(path: "delta/clip.mp4")),
                  "C2.10 对另一页“从列表移除”只拿掉条目，原文件不动：\(try await items(listA))")
    }

    // MARK: C2.11 在 MacView 里改名与移动

    private func relocateChecks() async throws {
        guard let listA, let fileOps = app.fileOps else { throw Failure(description: "没有文件操作") }
        let session = controller.session
        await open("bravo")
        await open("alpha")
        let bravo = book("bravo"), renamed = book("bravo-2")
        _ = await fileOps.perform(.rename(bravo, to: "bravo-2"), title: "重命名“bravo”", origin: FileOrigin(window: controller))
        let folder = String(localized: "新文件夹")
        let followed = await until("书签和历史跟到新位置") {
            let tree = await self.tree(), history = (try? await self.library.history()) ?? []
            return tree == "alpha, 画集[\(folder)[], bravo-2]" && history.contains { $0.book == renamed }
        }
        log.check(followed, "C2.11 改名书所在的文件夹后书签和历史指向新位置：\(await tree())")
        let moved = temporary.appending(path: "moved", directoryHint: .isDirectory)
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        let page = book("delta").appending("001.png"), target = try await services.sources.location(for: moved)
        _ = await fileOps.perform(.transfer([page], into: target, mode: .move, conflict: .appendNumber), title: "移动“001.png”", origin: FileOrigin(window: controller))
        log.check(await until("列表跟到新位置") { (try? await self.items(listA))?.first == "moved/001.png" }, "C2.11 把列表里的一页移到另一个文件夹后列表指向新位置：\(try await items(listA))")
        let outline = tableView(in: bookmarks.view)
        if let index = row(outline, "bravo-2") { await click(rowPoint(outline, index)) }
        log.check(await until("从书签打开改名后的书") { session.book?.location == renamed && session.book?.pages.count == 3 }, "C2.11 改名后的书从书签能打开")
        guard let play = button(String(localized: "▶ 当书打开"), in: playlist.view) else { throw Failure(description: "找不到“当书打开”") }
        await click(center(of: play))
        let playable = await until("移动后的页能打开") {
            session.book?.location == .playlist(listA) && session.book?.pages.first?.id == target.appending("001.png") && session.book?.pages.first?.metadata != nil
        }
        log.check(playable && session.unavailablePages.isEmpty, "C2.11 移动后的页在虚拟书里能打开")
    }

    /// 当前页帧之外的可见行必须独立重查；同一批缺页在瀑布流里必须有可点的操作。
    private func pageRecheckChecks(interactive: Bool) async throws {
        let bookName = interactive ? "bravo-2" : "bravo"
        let id = try await library.createPlaylist(named: "recheck")
        let locations = (1...4).map { book("alpha").appending(String(format: "%03d.png", $0)) }
            + (1...2).map { book(bookName).appending(String(format: "%03d.png", $0)) }
        let entries = try await LibraryActions.entries(for: locations, app: app)
        _ = try await library.addItems(entries, to: id)
        _ = await until("重查列表出现") { self.playlist.lists.contains { $0.id == id } }
        await choose(id)
        guard let play = button(String(localized: "▶ 当书打开"), in: playlist.view) else { throw Failure(description: "找不到当书打开") }
        if interactive { await click(center(of: play)) } else { controller.openBook(.playlist(id)) }
        _ = await until("打开重查列表") { self.controller.session.book?.pages.count == 6 && self.pageList.collection?.items.count == 6 && self.controller.session.book?.pages.allSatisfy { $0.metadata != nil } == true }
        let table = tableView(in: pageList.collection!)
        table.scrollRowToVisible(5)
        await settle()
        let original = shelf.appending(path: bookName), away = temporary.appending(path: "recheck-away")
        try fm.moveItem(at: original, to: away)
        defer { if exists(away) { try? fm.moveItem(at: away, to: original) } }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        log.check(await until("页面列表远处行重查") { self.pageList.collection?.items.last?.failure != nil }
                  && controller.session.currentPage == 0, "页面列表：App 激活时重查当前页帧以外的可见行并灰显")
        window.makeFirstResponder(controller.viewer)
        if interactive {
            await sendKey(kVK_End)
            await sendKey(kVK_ANSI_2, [.command])
        } else {
            controller.session.go(.index(5))
            controller.session.update { $0.browseMode = .waterfall }
        }
        let shown = await until("瀑布流占位操作") { self.placeholders().contains { $0.reason == .missing } }
        log.check(shown, "C2.15 瀑布流缺页显示原因和移除操作")
        log.snapshot(window, "library-waterfall-placeholder")
        if let view = placeholders().first, let remove = button(String(localized: "从列表移除"), in: view) {
            log.check(!remove.isHiddenOrHasHiddenAncestor, "C2.15 瀑布流占位页的移除按钮可见")
            if interactive {
                await click(center(of: remove))
                log.check(await until("瀑布流移除") { (try? await self.library.items(of: id).count) == 5 }, "C2.15 瀑布流占位页可直接从列表移除")
            }
        } else { log.check(false, "瀑布流占位页没有移除按钮") }
        try fm.moveItem(at: away, to: original)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        log.check(await until("页面列表恢复") { self.pageList.collection?.items.allSatisfy { $0.failure == nil } == true }, "页面列表：App 激活重查后缺页恢复")
        try await library.deletePlaylist(id)
        if interactive { await choose(listA) }
        await open("alpha")
    }

    // MARK: C2.4 删除列表、C2.1 清空历史

    private func clearChecks() async throws {
        guard let listA else { return }
        await open("alpha")
        perform(areaMenu(.right), String(localized: "播放列表"), String(localized: "删除当前列表…"))
        await settle()
        let banner = texts(in: playlist.view)
        log.check(banner.contains(String(localized: "删除播放列表「\("列表 A")」（\(2) 项）？只删除列表，原文件不动。")), "C2.4 删除列表先在面板内确认，说明原文件不动")
        log.snapshot(window, "library-playlist-delete")
        guard let delete = button(String(localized: "删除"), in: playlist.view) else { throw Failure(description: "找不到“删除”") }
        await click(center(of: delete))
        log.check(await until("删除列表") { self.playlist.lists.allSatisfy { $0.id != listA } } && exists(temporary.appending(path: "moved/001.png")), "C2.4 确认后删除列表，原文件不动")

        let count = history.entries.count
        perform(areaMenu(.left), String(localized: "历史"), String(localized: "清空历史…"))
        await settle()
        log.check(texts(in: history.view).contains(String(localized: "清空全部 \(count) 条历史？书的“上次看到的页”不受影响。")), "C2.1 ⋯“清空历史…”先在面板内确认，文案说明不影响上次看到的页")
        log.snapshot(window, "library-history-clear")
        guard let clear = button(String(localized: "清空"), in: history.view) else { throw Failure(description: "找不到“清空”") }
        await click(center(of: clear))
        let cleared = await until("清空历史") { self.history.entries.isEmpty }
        let memory = await services.settings.bookMemory(for: book("alpha"))?.lastPageIndex
        log.check(cleared && memory == 2 && texts(in: history.view).contains(String(localized: "还没有历史")), "C2.1 清空后历史为空，alpha 的上次看到的页仍是第 \((memory ?? -1) + 1) 页")
        guard let restored = app.newWindow() else { throw Failure(description: "打不开恢复窗口") }
        restored.openBook(book("alpha"), restoring: true)
        _ = await until("恢复打开 alpha") { restored.session.book?.isEnumerated == true && restored.session.currentPage == 2 }
        await settle()
        log.check((try await library.history()).isEmpty, "C2.1 恢复会话不重新写回已清空的历史")
        restored.openBook(book("echo"))
        log.check(await until("主动打开仍记历史") { (try? await self.library.history().map(\.book.name)) == ["echo"] }, "C2.1 恢复之后主动打开别的书仍记录历史")
        restored.window?.close()
    }

    // MARK: 测试书

    private func makeBooks() async throws {
        for (name, count) in [("alpha", 4), ("bravo", 3), ("echo", 2)] {
            try writePages(count, into: shelf.appending(path: name, directoryHint: .isDirectory), hue: CGFloat(name.count) / 10)
        }
        let source = temporary.appending(path: "charlie-src", directoryHint: .isDirectory)
        try writePages(3, into: source, hue: 0.55)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, shelf.appending(path: "charlie.zip").path]
        try ditto.run(); ditto.waitUntilExit()
        let delta = shelf.appending(path: "delta", directoryHint: .isDirectory)
        try writePages(2, into: delta, hue: 0.8)
        try await Self.writeVideo(to: delta.appending(path: "clip.mp4"))
        shelfLocation = try await services.sources.location(for: shelf)
    }

    private func writePages(_ count: Int, into directory: URL, hue: CGFloat) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 1...count {
            let width = 400, height = 560
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure(description: "建不了图") }
            context.setFillColor(NSColor(hue: (hue + CGFloat(index) * 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.85, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: directory.appending(path: String(format: "%03d.png", index)))
        }
    }

    /// 6 帧、2 秒的 H.264 视频。
    private nonisolated static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: 320, height: 240)))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<6 {
            guard let pool = receiver.pixelBufferPool else { throw Failure(description: "没有像素缓冲池") }
            var buffer = try pool.makeMutablePixelBuffer()
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                for plane in planes { plane.bytes.initializeMemory(as: UInt8.self, repeating: UInt8(60 + index * 25)) }
            }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: Int64(index), timescale: 3))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(description: "视频写入失败：\(String(describing: writer.error))") }
    }

    // MARK: 读取状态

    private func book(_ name: String) -> Location { shelfLocation.appending(name) }

    private func names(_ entries: [HistoryEntry]) -> [String] { entries.map(\.book.name) }

    /// 书签树：书是显示名（有自定义名时带原名），文件夹是“名字[子项]”。
    private func tree() async -> String {
        func describe(_ nodes: [BookmarkNode]) -> String {
            nodes.map { node in
                switch node {
                case let .folder(_, name, children): "\(name)[\(describe(children))]"
                case let .book(_, location, label): label.map { "\($0)(\(location.name))" } ?? location.name
                }
            }.joined(separator: ", ")
        }
        return describe((try? await library.bookmarks()) ?? [])
    }

    /// 列表的项：所在的书名加文件名，压缩包内用“!/”。
    private func items(_ list: UUID?) async throws -> [String] {
        guard let list else { return [] }
        return try await library.items(of: list).map { entry in
            let location = entry.location
            return location.layers.count > 1 ? "\(location.layers[0].last ?? "")!/\(location.name)" : "\(location.parent?.name ?? "")/\(location.name)"
        }
    }

    private func message(_ expected: String) async -> Bool {
        let shown = await until("提示“\(expected)”") { self.controller.content.statusBar.message == expected }
        if !shown { print("INFO 状态栏提示：\(controller.content.statusBar.message ?? "无")") }
        return shown
    }

    private func popupTitles() -> [String] { views(NSPopUpButton.self, in: playlist.view).first?.itemTitles ?? [] }

    private func choose(_ list: UUID?) async {
        guard let popup = views(NSPopUpButton.self, in: playlist.view).first,
              let index = popup.menu?.items.firstIndex(where: { ($0.representedObject as? UUID) == list }) else { return }
        popup.selectItem(at: index)
        popup.sendAction(popup.action, to: popup.target)
        let count = playlist.lists.first { $0.id == list }?.count ?? 0
        _ = await until("切换列表") { self.playlist.items.count == count }
        await settle()
    }

    private func placeholders() -> [UnavailablePageView] {
        views(UnavailablePageView.self, in: controller.viewer).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func popoverWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }
    }

    private func badge(_ table: NSTableView, row: Int) -> UnavailableBadge? {
        guard row >= 0, row < table.numberOfRows, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        return views(UnavailableBadge.self, in: cell).first
    }

    /// 第一列文字里有 `text` 的行。
    private func row(_ table: NSTableView, _ text: String) -> Int? {
        (0..<table.numberOfRows).first { row in
            table.view(atColumn: 0, row: row, makeIfNecessary: true).map { texts(in: $0).contains(text) } ?? false
        }
    }

    // MARK: 视图与菜单

    private func tableView(in view: NSView) -> NSTableView { views(NSTableView.self, in: view).first! }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// 显示出来的文字：标签与文本框，按钮标题。
    private func texts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        var own: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { own.append(field.stringValue) }
        if let button = view as? NSButton, !(view is NSPopUpButton), !button.attributedTitle.string.isEmpty { own.append(button.attributedTitle.string) }
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        views(NSButton.self, in: view).first { $0.attributedTitle.string == title && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// 上下分割时区的 ⋯ 菜单里每个面板一个子菜单。
    private func areaMenu(_ edge: DockEdge) -> NSMenu? { controller.dock.areas[edge]?.optionsMenu() }

    private func perform(_ menu: NSMenu?, _ path: String...) {
        var current = menu
        for (depth, title) in path.enumerated() {
            let last = depth == path.count - 1
            guard let menu = current, let index = menu.items.firstIndex(where: { $0.title == title && (last || $0.submenu != nil) }) else {
                log.check(false, "菜单里没有“\(title)”：\(current?.items.map(\.title) ?? [])"); return
            }
            if last {
                menu.update()
                menu.performActionForItem(at: index)
            } else {
                current = menu.items[index].submenu
            }
        }
    }

    private func contextMenu(_ table: NSTableView, row: Int) -> NSMenu? {
        table.menu(for: mouse(.rightMouseDown, at: rowPoint(table, row), in: window))
    }

    // MARK: 事件

    private func rowPoint(_ table: NSTableView, _ row: Int, fraction: CGFloat = 0.5) -> NSPoint {
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.midX, y: rect.minY + rect.height * fraction), to: nil)
    }

    private func center(of view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }

    /// 同一次点击或拖动的事件共用一个编号：按钮的跟踪循环只认编号与 mouseDown 相同的 mouseUp，编号 0 不算。
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, number: Int = 1, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: number, clickCount: clicks, pressure: [.leftMouseUp, .rightMouseUp].contains(type) ? 0 : 1)!
    }

    /// 点击：先排队 mouseUp，再发 mouseDown，控件的跟踪循环从队列里取到 mouseUp。
    private func click(_ point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) async {
        let target = target ?? window!
        if !target.isKeyWindow, target.canBecomeKey { target.makeKeyAndOrderFront(nil) }
        target.displayIfNeeded()
        for clicks in 1...count { sendClick(point, clicks: clicks, flags: flags, in: target) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func sendClick(_ point: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = [], in target: NSWindow) {
        eventNumber += 1
        NSApp.postEvent(mouse(.leftMouseUp, at: point, in: target, number: eventNumber, clicks: clicks, flags: flags), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown, at: point, in: target, number: eventNumber, clicks: clicks, flags: flags))
    }

    /// 拖放：mouseDown 的跟踪循环取到排队的拖动事件后发起真实拖动会话，会话再从队列里取后面的拖动和 mouseUp。
    private func drag(from start: NSPoint, to end: NSPoint) async {
        window.displayIfNeeded()
        // AppKit 拖放管理器读取全局指针位置；合成事件本身不会移动指针。
        let cursor = NSEvent.mouseLocation
        defer { movePointer(toScreen: cursor) }
        movePointer(toScreen: window.convertPoint(toScreen: start))
        eventNumber += 1
        let number = eventNumber
        NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: start.x + 8, y: start.y - 8), in: window, number: number), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown, at: start, in: window, number: number))
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            movePointer(toScreen: window.convertPoint(toScreen: point))
            NSApp.postEvent(mouse(.leftMouseDragged, at: point, in: window, number: number), atStart: false)
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(150))
        NSApp.postEvent(mouse(.leftMouseUp, at: end, in: window, number: number), atStart: false)
        try? await Task.sleep(for: .milliseconds(400))
        // 拖动会话结束后窗口吞掉下一次 mouseDown：在信息行上补一次空点击。
        sendClick(history.view.convert(NSPoint(x: 20, y: 14), to: nil), in: window)
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func movePointer(toScreen point: NSPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y))
    }

    private func sendKey(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) async {
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            if NSApp.keyWindow != nil { NSApp.sendEvent(event) }
            else if event.type == .keyUp || (!window.performKeyEquivalent(with: event) && NSApp.mainMenu?.performKeyEquivalent(with: event) != true) { window.sendEvent(event) }
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    /// 在正在编辑的文本框里输入并回车；`text` 为 nil 时按 Esc 取消。
    private func type(_ text: String?, in target: NSWindow? = nil) async {
        guard let editor = (target ?? window)?.firstResponder as? NSTextView else { return log.check(false, "没有正在编辑的文本框") }
        if let text {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            await sendKey(kVK_Return)
        } else {
            await sendKey(kVK_Escape)
        }
        await settle()
    }

    private func open(_ name: String) async {
        let url = shelf.appending(path: name)
        controller.open([url])
        _ = await until("打开 \(name)") {
            self.controller.session.book?.location.name == name && self.controller.session.book?.isEnumerated == true
                && self.controller.session.book?.pages.count == Self.pages[name]
        }
        await settle()
    }

    // MARK: 工具

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    private func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
    private func skip(_ message: String) { print("SKIP \(message)") }

    /// 等条件成立，最多 6 秒；超时只打印，结果由随后的检查判定。
    @discardableResult
    private func until(_ description: String, attempts: Int = 240, condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(25 * attempts)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if await condition() { return true }
        print("INFO 等待超时：\(description)")
        return false
    }
}
#endif
