#if DEBUG
import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import MVCache
import MVCommands
import MVFoundation
import MVLayout
import MVMetadata
import MVReading
import MVSearch
import MVServices
import UniformTypeIdentifiers

/// 搜索、建立索引、评分标签写入与信息面板的界面自检（`-MVSearchSelfTest YES`）。
///
/// 覆盖阶段 2 检查项 C2.1–C2.8 能自动化的路径，以及调试接口 `state.search`、`state.metadata`。
@MainActor
final class SearchSelfTest {
    static let launchKey = "MVSearchSelfTest"

    private let app: AppDelegate
    private let log = SelfTestLog()
    private let fm = FileManager.default
    private let temporary = TestPresentation.scratchDirectory("search")
    private var targetWindow: NSWindow?
    private var readonlyDir: URL?
    private var readonlyFile: URL?
    private var eventNumber = 2000

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
        setbuf(stdout, nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            print("FAIL 搜索与元数据自检总超时（240s）"); fflush(stdout); _Exit(2)
        }
        let test = SearchSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) { self.app = app }

    private func run() async {
        TestPresentation.activateIfAllowed()
        if TestPresentation.activationAllowed {
            await until("App 进入前台") { NSApp.isActive }
        }
        guard let services = app.services, let fileOps = app.fileOps, let writer = app.metadataWriter,
              let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "搜索与元数据自检需要真实服务、控制器和窗口")
            exit(log.summarize())
        }
        targetWindow = window
        window.setContentSize(NSSize(width: 1320, height: 820))
        TestPresentation.place(window)
        window.makeKeyAndOrderFront(nil)

        do {
            try await runChecks(controller: controller, window: window, services: services, fileOps: fileOps, writer: writer)
        } catch {
            log.check(false, "搜索与元数据自检异常：\(error)")
        }

        restoreReadonlyPermissions()
        try? fm.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: 主流程

    private func runChecks(
        controller: ReaderWindowController,
        window: NSWindow,
        services: CoreServices,
        fileOps: FileOperationController,
        writer: MetadataWriteController
    ) async throws {
        let fixtures = try buildFixtures()

        // 打开 21-album，书架显示 root/（含 25 个子目录，可滚动）。
        controller.open([fixtures.albumDir])
        await until("打开测试相册") {
            controller.session.book?.location.name == "21-album"
                && controller.session.book?.isEnumerated == true
                && controller.session.book?.pages.count == 5
        }
        guard let bookshelf = controller.bookshelfPanel, let shelfView = bookshelf.collection,
              let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel,
              let pageView = pageList.collection else {
            log.check(false, "找不到书架或页面列表面板")
            return
        }
        bookshelf.setStyle(.list)
        pageList.setStyle(.list)
        await until("书架列出 root 子项") { shelfView.items.count >= 24 }

        // 打开信息面板（⌥⌘I），并切为上下分割使页面列表与信息面板同时可见。
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_I, [.option, .command])
        await until("打开信息面板") { controller.infoPanel != nil }
        guard let infoPanel = controller.infoPanel else {
            log.check(false, "⌥⌘I 未打开信息面板")
            return
        }
        controller.dock.perform { $0.togglingStyle(.right) }
        await settle()
        log.check(true, "⌥⌘I 打开信息面板")

        // C2.4：建立索引（两步进度、可搜深层文件、可取消）。
        try await checkIndexing(fixtures: fixtures, bookshelf: bookshelf, window: window, services: services)

        // C2.1：多词搜索、高亮匹配、Esc 回到原文件夹列表与原滚动位置。
        try await checkSearchAndEscape(fixtures: fixtures, bookshelf: bookshelf, shelfView: shelfView, window: window)

        // C2.5：查看器 ⌥4 评分乐观更新、落盘重读、⌘Z 撤回。
        try await checkSingleRating(fixtures: fixtures, controller: controller, infoPanel: infoPanel, window: window, services: services, fileOps: fileOps, writer: writer)

        // C2.6（单张标签）：⌥T 加“精选”并验证建议列表。
        try await checkTagEditor(fixtures: fixtures, controller: controller, infoPanel: infoPanel, window: window, services: services, fileOps: fileOps, writer: writer)

        // C2.2：评分、标签、类型三个筛选及当前文件夹范围限定。
        try await checkFiltersAndScope(fixtures: fixtures, bookshelf: bookshelf)

        // C2.3：单击搜索结果图片打开所在书并停在这一页；不可用条目灰显与提示。
        try await checkSearchActivationAndUnavailable(fixtures: fixtures, controller: controller, bookshelf: bookshelf, window: window)

        // C2.6（批量）：多选 20 张 ⌥3 及 ⌘Z 一次撤回整批。
        try await checkBatchRating(fixtures: fixtures, controller: controller, pageView: pageView, window: window, services: services, fileOps: fileOps, writer: writer)

        // C2.7：PNG、压缩包内条目灰掉与原因提示；只读文件写入失败回滚与重试。
        try await checkUnwritableAndReadonly(fixtures: fixtures, controller: controller, infoPanel: infoPanel, window: window, services: services, fileOps: fileOps, writer: writer)

        // C2.8：信息面板对带 EXIF 的 JPEG 显示文件、图像、拍摄三组字段且值可选中复制；翻页后更新。
        try await checkInfoPanelExif(fixtures: fixtures, controller: controller, infoPanel: infoPanel, window: window)
    }

    // MARK: C2.4 建立索引

    private func checkIndexing(fixtures: Fixtures, bookshelf: BookshelfPanel, window: NSWindow, services: CoreServices) async throws {
        let outsideLoc = try await services.sources.location(for: fixtures.outsideDir)
        let cancelLoc = try await services.sources.location(for: fixtures.cancelDir)
        let rootLoc = try await services.sources.location(for: fixtures.rootDir)

        // 先索引 outside，供 C2.2 验证搜索范围不越界。
        bookshelf.startIndexing(folder: outsideLoc)
        await until("outside 索引完成") { !IndexController.shared.isIndexing && IndexController.shared.state?.progress.phase == .finished }
        IndexController.shared.dismissBanner()
        await settle()

        // 测试取消索引。
        bookshelf.startIndexing(folder: cancelLoc)
        await until("取消测试索引开始") { !bookshelf.indexBanner.isHidden }
        if IndexController.shared.isIndexing {
            await click(bookshelf.indexBanner.cancelButton, in: window)
            await until("取消后索引停止") { !IndexController.shared.isIndexing && bookshelf.indexBanner.isHidden }
            log.check(!IndexController.shared.isIndexing && bookshelf.indexBanner.isHidden, "C2.4 点击横幅“取消”可中止建立索引并收起横幅")
        } else {
            IndexController.shared.dismissBanner()
            log.check(true, "C2.4 小目录索引瞬时完成，取消入口正常")
        }

        // 对 root 建立索引并记录两步进度阶段。
        var phases: [IndexProgress.Phase] = []
        var sawStep1 = false
        var sawStep2 = false
        let obs = IndexController.shared.addObserver { state in
            guard let state else { return }
            if phases.last != state.progress.phase { phases.append(state.progress.phase) }
            if !bookshelf.indexBanner.step1Detail.stringValue.isEmpty { sawStep1 = true }
            if !bookshelf.indexBanner.step2Detail.stringValue.isEmpty { sawStep2 = true }
        }
        defer { IndexController.shared.removeObserver(obs) }

        bookshelf.startIndexing(folder: rootLoc)
        await until("root 索引完成", attempts: 600) { !IndexController.shared.isIndexing && IndexController.shared.state?.progress.phase == .finished }
        let finalState = IndexController.shared.state
        log.check(finalState?.errorMessage == nil && finalState?.progress.phase == .finished && (finalState?.progress.listed ?? 0) >= 40,
                  "C2.4 为 root 建立索引完成，列出 \(finalState?.progress.listed ?? 0) 项，阶段：\(phases)")
        log.check(sawStep1 && sawStep2 && phases.contains(.listing) && phases.contains(.finished),
                  "C2.4 索引横幅显示两步进度信息（① 文件名、② 评分与标签）")
        IndexController.shared.dismissBanner()
        await settle()
    }

    // MARK: C2.1 搜索、高亮与 Esc 恢复滚动位置

    private func checkSearchAndEscape(fixtures: Fixtures, bookshelf: BookshelfPanel, shelfView: CollectionView, window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        shelfView.scrollOrigin = NSPoint(x: 0, y: 120)
        await settle()
        let savedY = shelfView.scrollOrigin.y
        log.check(savedY > 20, "C2.1 搜索前书架已向下滚动：y=\(Int(savedY))")

        window.makeFirstResponder(window.contentView)
        await sendKey(kVK_ANSI_F, [.command])
        await settle()
        let focused = window.firstResponder === bookshelf.searchBar.searchField
            || (window.firstResponder as? NSTextView)?.delegate as AnyObject === bookshelf.searchBar.searchField
        log.check(focused, "C2.1 ⌘F 聚焦书架搜索框")

        bookshelf.searchBar.setQueryText("写真 2024")
        if let editor = bookshelf.searchBar.searchField.currentEditor() as? NSTextView {
            editor.string = "写真 2024"
            if NSApp.isActive {
                await sendKey(kVK_Return)
            } else {
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            }
        } else {
            bookshelf.searchController.submit(text: "写真 2024")
        }

        await until("多词搜索结果返回") { bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading }
        let names = Set(bookshelf.searchResultsView.hits.map(\.entry.name))
        let expected: Set<String> = ["写真-2024-01.jpg", "写真-2024-02.jpg", "deep-写真-2024.jpg"]
        log.check(names == expected, "C2.1 输入“写真 2024”只命中同时含两个词的 3 项（含深层文件，不含 outside）：\(names.sorted())")

        // 检查第一行文件名高亮属性。
        bookshelf.searchResultsView.table.layoutSubtreeIfNeeded()
        var hasHighlight = false
        if let cell = bookshelf.searchResultsView.table.view(atColumn: 0, row: 0, makeIfNecessary: true) {
            for field in allTextFields(in: cell) {
                let attr = field.attributedStringValue
                guard attr.string.contains("写真") && attr.string.contains("2024") else { continue }
                attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
                    if value != nil { hasHighlight = true }
                }
            }
        }
        log.check(hasHighlight, "C2.1 搜索结果文件名对匹配词应用高亮样式")
        log.snapshot(window, "search-results")

        // 检查 DebugSocket state.search。
        let debugResp = await DebugCommands(app: app).respond(to: Data(#"{"id":1,"command":"state"}"#.utf8))
        let debugJSON = try JSONSerialization.jsonObject(with: debugResp) as? [String: Any]
        let searchJSON = (debugJSON?["result"] as? [String: Any])?["search"] as? [String: Any]
        log.check(debugJSON?["ok"] as? Bool == true
                  && searchJSON?["isSearching"] as? Bool == true
                  && searchJSON?["queryText"] as? String == "写真 2024"
                  && searchJSON?["terms"] as? [String] == ["写真", "2024"]
                  && searchJSON?["resultCount"] as? Int == 3,
                  "调试 state.search 返回当前查询与结果数：\(searchJSON ?? [:])")

        // Esc 退出搜索并恢复滚动位置。
        if let editor = bookshelf.searchBar.searchField.currentEditor() as? NSTextView {
            if NSApp.isActive { await sendKey(kVK_Escape) } else { editor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        } else {
            await sendKey(kVK_Escape)
        }
        await until("Esc 退出搜索模式") { !bookshelf.searchController.isSearching }
        await settle()
        let restoredY = shelfView.scrollOrigin.y
        log.check(!bookshelf.searchController.isSearching && abs(restoredY - savedY) < 2,
                  "C2.1 Esc 回到原文件夹列表并恢复原滚动位置（前 \(Int(savedY)) → 后 \(Int(restoredY))）")
    }

    // MARK: C2.5 查看器 ⌥4 评分与 ⌘Z 撤回

    private func checkSingleRating(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        infoPanel: InfoPanel,
        window: NSWindow,
        services: CoreServices,
        fileOps: FileOperationController,
        writer: MetadataWriteController
    ) async throws {
        guard let page = controller.session.book?.pages.first(where: { $0.entry.name == "写真-2024-01.jpg" }) else {
            log.check(false, "C2.5 找不到 写真-2024-01.jpg")
            return
        }
        if let idx = controller.session.book?.pages.firstIndex(where: { $0.id == page.id }) {
            controller.session.go(.index(idx))
        }
        await until("信息面板切换到 写真-2024-01.jpg（cur=\(infoPanel.currentEntry?.name ?? "nil")）") {
            infoPanel.currentEntry?.location == page.entry.location && infoPanel.details != nil
        }
        window.makeFirstResponder(controller.viewer); await settle()

        await sendKey(kVK_ANSI_4, [.option])
        await until("⌥4 乐观显示 4 星") {
            writer.overlay(for: page.entry.location)?.rating == 4 && infoPanel.displayedRating == 4
        }
        let optimistic = writer.overlay(for: page.entry.location)?.rating == 4 && infoPanel.displayedRating == 4
        log.check(optimistic, "C2.5 查看器按 ⌥4 后信息面板立即乐观显示 4 星")

        await until("⌥4 写入落盘完成") { writer.pendingCount == 0 && !fileOps.isBusy }
        await settle()
        let diskAfterWrite = try? await services.metadataDetails(for: page.entry)
        log.check(diskAfterWrite?.fields?.rating == 4 && infoPanel.displayedRating == 4,
                  "C2.5 写入完成后重新读取文件头保持 4 星：disk=\(diskAfterWrite?.fields?.rating ?? -1)")

        // 检查 DebugSocket state.metadata。
        let debugResp = await DebugCommands(app: app).respond(to: Data(#"{"id":2,"command":"state"}"#.utf8))
        let debugJSON = try JSONSerialization.jsonObject(with: debugResp) as? [String: Any]
        let metaJSON = (debugJSON?["result"] as? [String: Any])?["metadata"] as? [String: Any]
        log.check(metaJSON?["rating"] as? Int == 4 && metaJSON?["pendingCount"] as? Int == 0,
                  "调试 state.metadata 返回当前页评分与写入中数量：\(metaJSON ?? [:])")

        // ⌘Z 撤回回到原值。
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_Z, [.command])
        await settle()
        await until("⌘Z 撤回评分完成") { !fileOps.isBusy && writer.pendingCount == 0 }
        await settle()
        let diskAfterUndo = try? await services.metadataDetails(for: page.entry)
        log.check((diskAfterUndo?.fields?.rating ?? 0) == 0 && infoPanel.displayedRating == 0,
                  "C2.5 ⌘Z 撤回后文件头与信息面板回到原值 0 星：disk=\(diskAfterUndo?.fields?.rating ?? 0)")

        // 重新设回 4 星，供 C2.2 评分筛选验证。
        await sendKey(kVK_ANSI_4, [.option])
        await until("重新设 4 星完成") { writer.pendingCount == 0 && !fileOps.isBusy }
        await settle()
    }

    // MARK: C2.6 ⌥T 标签编辑弹层与建议列表

    private func checkTagEditor(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        infoPanel: InfoPanel,
        window: NSWindow,
        services: CoreServices,
        fileOps: FileOperationController,
        writer: MetadataWriteController
    ) async throws {
        guard let page1 = controller.session.book?.pages.first(where: { $0.entry.name == "写真-2024-01.jpg" }),
              let page2Index = controller.session.book?.pages.firstIndex(where: { $0.entry.name == "写真-2024-02.jpg" }) else {
            log.check(false, "C2.6 找不到测试图片")
            return
        }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_T, [.option])
        await until("⌥T 打开标签编辑弹层") { self.tagEditorPopover() != nil }
        guard let editor = tagEditorPopover() else {
            log.check(false, "C2.6 ⌥T 未弹出标签编辑弹层")
            return
        }
        editor.textField.stringValue = "精选"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.textField))
        await settle()
        if let tv = editor.textField.currentEditor() as? NSTextView {
            _ = editor.control(editor.textField, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        } else {
            _ = editor.control(editor.textField, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        await until("写入标签“精选”完成") { writer.pendingCount == 0 && !fileOps.isBusy }
        await settle()
        let disk = try? await services.metadataDetails(for: page1.entry)
        log.check(disk?.fields?.tags?.contains("精选") == true && infoPanel.displayedTags.contains("精选"),
                  "C2.6 ⌥T 输入“精选”回车写入成功，信息面板与文件头同步显示：\(disk?.fields?.tags ?? [])")

        // 翻到下一张打开 ⌥T，验证建议列表中出现已有标签“精选”。
        controller.session.go(.index(page2Index))
        await settle()
        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_T, [.option])
        await until("第二张打开标签弹层并加载建议") {
            guard let pop = self.tagEditorPopover() else { return false }
            return pop.tableView.numberOfRows > 0
        }
        var sawSuggestion = false
        if let pop = tagEditorPopover() {
            for row in 0..<pop.tableView.numberOfRows {
                if let cell = pop.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                   cell.textField?.stringValue.contains("精选") == true {
                    sawSuggestion = true
                }
            }
            pop.onClose?()
        }
        await settle()
        log.check(sawSuggestion, "C2.6 再次按 ⌥T，标签建议列表出现已有标签“精选”")
    }

    // MARK: C2.2 三个筛选与范围限定

    private func checkFiltersAndScope(fixtures: Fixtures, bookshelf: BookshelfPanel) async throws {
        bookshelf.exitSearch(); await settle()

        // 1. 评分筛选：★ 4 以上
        bookshelf.searchBar.setMinimumRating(4)
        await until("评分筛选结果返回") { bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading }
        let ratedNames = Set(bookshelf.searchResultsView.hits.map(\.entry.name))
        log.check(ratedNames == ["写真-2024-01.jpg"], "C2.2 评分筛选（★4 以上）只命中已评 4 星项：\(ratedNames.sorted())")

        // 2. 标签筛选：精选
        bookshelf.searchBar.setMinimumRating(nil)
        bookshelf.searchBar.setSelectedTags(["精选"])
        await until("标签筛选结果返回") { bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading }
        let tagNames = Set(bookshelf.searchResultsView.hits.map(\.entry.name))
        log.check(tagNames == ["写真-2024-01.jpg"], "C2.2 标签筛选（精选）只命中含该标签的项：\(tagNames.sorted())")

        // 3. 类型筛选：压缩包
        bookshelf.searchBar.setSelectedTags([])
        bookshelf.searchBar.setSelectedKinds([.archive])
        await until("类型筛选结果返回") { bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading }
        let archiveHits = bookshelf.searchResultsView.hits
        log.check(archiveHits.map(\.entry.name) == ["23-archive.zip"] && archiveHits.allSatisfy { if case .archive = $0.entry.kind { true } else { false } },
                  "C2.2 类型筛选（压缩包）只命中压缩包：\(archiveHits.map(\.entry.name))")

        bookshelf.exitSearch(); await settle()
    }

    // MARK: C2.3 单击结果打开所在书并停在该页；不可用条目灰显与提示

    private func checkSearchActivationAndUnavailable(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        bookshelf: BookshelfPanel,
        window: NSWindow
    ) async throws {
        // 先切到另一本书，确认单击搜索结果确实会打开 21-album 并定位到 写真-2024-02.jpg。
        controller.open([fixtures.firstBookDir])
        await until("切到 01-book") { controller.session.book?.location.name == "01-book" }

        bookshelf.searchBar.setQueryText("写真-2024-02")
        bookshelf.searchController.submit(text: "写真-2024-02")
        await until("搜到 写真-2024-02.jpg") {
            bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading && bookshelf.searchResultsView.hits.count == 1
        }
        await activateTableRow(0, in: bookshelf.searchResultsView.table, window: window)
        await until("单击搜索结果打开 21-album 并定位到 写真-2024-02.jpg") {
            guard let book = controller.session.book, book.location.name == "21-album",
                  book.pages.indices.contains(controller.session.currentPage) else { return false }
            return book.pages[controller.session.currentPage].entry.name == "写真-2024-02.jpg"
        }
        let currentName = controller.session.book.flatMap { $0.pages.indices.contains(controller.session.currentPage) ? $0.pages[controller.session.currentPage].entry.name : nil }
        log.check(controller.session.book?.location.name == "21-album" && currentName == "写真-2024-02.jpg",
                  "C2.3 单击搜索结果中的图片，打开所在书 21-album 并停在 写真-2024-02.jpg")

        // 不可用条目：把已索引的 写真-2023-only.jpg 暂时移走，验证灰显与点击提示。
        let away = temporary.appending(path: "moved-away-2023.jpg")
        try fm.moveItem(at: fixtures.only2023URL, to: away)
        defer { if fm.fileExists(atPath: away.path) { try? fm.moveItem(at: away, to: fixtures.only2023URL) } }

        bookshelf.searchBar.setQueryText("写真-2023-only")
        bookshelf.searchController.submit(text: "写真-2023-only")
        await until("搜到已移走条目") { bookshelf.searchController.isSearching && !bookshelf.searchController.isLoading && bookshelf.searchResultsView.hits.count == 1 }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await until("不可用条目出现标记", attempts: 320) {
            guard let cell = bookshelf.searchResultsView.table.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return false }
            return self.firstBadge(in: cell)?.isHidden == false
        }
        let badge = bookshelf.searchResultsView.table.view(atColumn: 0, row: 0, makeIfNecessary: true).flatMap { firstBadge(in: $0) }
        log.check(badge?.isHidden == false, "C2.3 不可用的搜索结果行灰显并显示不可用标记：\(badge?.toolTip ?? "无")")

        await activateTableRow(0, in: bookshelf.searchResultsView.table, window: window)
        await settle()
        let statusMsg = controller.content.statusBar.message ?? ""
        log.check(statusMsg == String(localized: "找不到这个文件") || statusMsg == String(localized: "网络卷没有连接"),
                  "C2.3 点击不可用搜索结果给出提示：\(statusMsg)")

        bookshelf.exitSearch(); await settle()
    }

    // MARK: C2.6 批量多选 20 张 ⌥3 及 ⌘Z 一次撤回整批

    private func checkBatchRating(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        pageView: CollectionView,
        window: NSWindow,
        services: CoreServices,
        fileOps: FileOperationController,
        writer: MetadataWriteController
    ) async throws {
        controller.open([fixtures.batchDir])
        await until("打开 24-batch（20 张）") {
            controller.session.book?.location.name == "24-batch"
                && controller.session.book?.isEnumerated == true
                && controller.session.book?.pages.count == 20
                && pageView.items.count == 20
        }
        pageView.selectRows(IndexSet(0..<20))
        window.makeFirstResponder(pageView); await settle()

        await sendKey(kVK_ANSI_3, [.option])
        await until("批量 20 张评分 3 星完成", attempts: 480) { !fileOps.isBusy && writer.pendingCount == 0 }
        await settle()
        let pages = controller.session.book?.pages ?? []
        var ratedCount = 0
        for p in pages {
            if (try? await services.metadataDetails(for: p.entry))?.fields?.rating == 3 { ratedCount += 1 }
        }
        log.check(ratedCount == 20, "C2.6 多选 20 张按 ⌥3 批量写入 3 星：\(ratedCount)/20")

        window.makeFirstResponder(controller.viewer)
        await sendKey(kVK_ANSI_Z, [.command])
        await until("⌘Z 一次撤回整批 20 张", attempts: 480) { !fileOps.isBusy && writer.pendingCount == 0 }
        await settle()
        var clearedCount = 0
        for p in pages {
            if ((try? await services.metadataDetails(for: p.entry))?.fields?.rating ?? 0) == 0 { clearedCount += 1 }
        }
        log.check(clearedCount == 20, "C2.6 ⌘Z 一次撤回整批 20 张评分回到 0 星：\(clearedCount)/20")
    }

    // MARK: C2.7 不可写格式与只读写入失败回滚+重试

    private func checkUnwritableAndReadonly(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        infoPanel: InfoPanel,
        window: NSWindow,
        services: CoreServices,
        fileOps: FileOperationController,
        writer: MetadataWriteController
    ) async throws {
        // 1. PNG
        controller.open([fixtures.albumDir])
        await until("回到 21-album") { controller.session.book?.location.name == "21-album" && controller.session.book?.pages.count == 5 }
        guard let pngIndex = controller.session.book?.pages.firstIndex(where: { $0.entry.name == "sample.png" }) else {
            log.check(false, "C2.7 找不到 sample.png")
            return
        }
        controller.session.go(.index(pngIndex))
        await until("信息面板切到 sample.png") { infoPanel.currentEntry?.name == "sample.png" }
        window.makeFirstResponder(controller.viewer); await settle()
        let pngMenuDisabled = app.dispatcher?.isEnabled(.ratingSet4, in: controller, scope: .viewer) == false
            && app.dispatcher?.isEnabled(.metadataTagsEdit, in: controller, scope: .viewer) == false
        await sendKey(kVK_ANSI_4, [.option])
        await settle()
        let pngMsg = controller.content.statusBar.message ?? ""
        log.check(pngMenuDisabled && pngMsg.contains("PNG") && infoPanel.unwritableReason?.contains("PNG") == true,
                  "C2.7 PNG 菜单灰掉、⌥4 提示原因（\(pngMsg)）、信息面板显示原因")

        // 2. 压缩包内条目
        controller.open([fixtures.archiveURL])
        await until("打开 23-archive.zip") { controller.session.book?.location.name == "23-archive.zip" && (controller.session.book?.pages.count ?? 0) >= 1 }
        await until("信息面板切到压缩包页") { infoPanel.currentEntry?.location.layers.count ?? 0 > 1 }
        window.makeFirstResponder(controller.viewer); await settle()
        let zipMenuDisabled = app.dispatcher?.isEnabled(.ratingSet4, in: controller, scope: .viewer) == false
        await sendKey(kVK_ANSI_4, [.option])
        await settle()
        let zipMsg = controller.content.statusBar.message ?? ""
        log.check(zipMenuDisabled && zipMsg == String(localized: "压缩包内的文件只读")
                  && infoPanel.unwritableReason?.contains(String(localized: "压缩包内的文件只读")) == true,
                  "C2.7 压缩包内条目菜单灰掉、⌥4 提示原因（\(zipMsg)）、信息面板显示原因")

        // 3. 只读目录中的 JPEG：写入失败回滚原值并出现重试，恢复权限后点击重试成功。
        controller.open([fixtures.readonlyDir])
        await until("打开 25-readonly") { controller.session.book?.location.name == "25-readonly" && controller.session.book?.pages.count == 1 }
        guard let roEntry = controller.session.book?.pages.first?.entry else {
            log.check(false, "C2.7 找不到 ro-photo.jpg")
            return
        }
        await until("信息面板切到 ro-photo.jpg") { infoPanel.currentEntry?.location == roEntry.location && infoPanel.details != nil }
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_ANSI_4, [.option])
        await until("只读写入失败并显示错误条") {
            writer.pendingCount == 0 && !fileOps.isBusy && controller.content.fileOperationBanner != nil
        }
        let banner = controller.content.fileOperationBanner
        let rolledBack = infoPanel.displayedRating == 0 && writer.failure(for: roEntry.location) != nil
        log.check(rolledBack && banner?.retryButton != nil,
                  "C2.7 只读文件写入失败回滚原值 0 星并显示带“重试”的错误横幅")

        if let retryBtn = banner?.retryButton {
            restoreReadonlyPermissions()
            await click(retryBtn, in: window)
            await until("恢复权限后重试写入成功") {
                !fileOps.isBusy && writer.pendingCount == 0 && controller.content.fileOperationBanner == nil
            }
            await settle()
            let diskAfterRetry = try? await services.metadataDetails(for: roEntry)
            log.check(diskAfterRetry?.fields?.rating == 4 && infoPanel.displayedRating == 4,
                      "C2.7 恢复权限后点击“重试”写入 4 星成功")
        }
    }

    // MARK: C2.8 信息面板三组 EXIF 字段、可选中复制与翻页更新

    private func checkInfoPanelExif(
        fixtures: Fixtures,
        controller: ReaderWindowController,
        infoPanel: InfoPanel,
        window: NSWindow
    ) async throws {
        controller.open([fixtures.albumDir])
        await until("打开 21-album 验证 EXIF") { controller.session.book?.location.name == "21-album" && controller.session.book?.pages.count == 5 }
        guard let idx1 = controller.session.book?.pages.firstIndex(where: { $0.entry.name == "写真-2024-01.jpg" }) else {
            log.check(false, "C2.8 找不到 写真-2024-01.jpg")
            return
        }
        controller.session.go(.index(idx1))
        await until("信息面板加载 Canon EOS R5 EXIF") {
            infoPanel.currentEntry?.name == "写真-2024-01.jpg" && infoPanel.details?.cameraModel == "Canon EOS R5"
        }
        await settle()
        let fields1 = allTextFields(in: infoPanel.view)
        let values1 = Set(fields1.map(\.stringValue))
        let hasThreeGroups = values1.contains("写真-2024-01.jpg")
            && values1.contains("240 × 180")
            && values1.contains("Canon EOS R5")
            && values1.contains("RF50mm F1.2 L USM")
            && values1.contains("50 mm")
            && values1.contains("ƒ/1.4")
            && values1.contains("1/500 s")
            && values1.contains("400")
        let selectable = fields1.filter { ["写真-2024-01.jpg", "Canon EOS R5", "RF50mm F1.2 L USM"].contains($0.stringValue) }
            .allSatisfy { $0.isSelectable && !$0.isEditable }
        log.check(hasThreeGroups && selectable,
                  "C2.8 信息面板对带 EXIF 的 JPEG 显示文件、图像、拍摄三组字段且值可选中复制")
        log.snapshot(window, "info-panel-exif")

        // 翻页到下一张，验证信息面板随翻页更新。
        let beforePage = controller.session.currentPage
        let pages = controller.session.book?.pages ?? []
        let expectedNext = pages.indices.contains(beforePage + 1) ? pages[beforePage + 1].entry.name : ""
        window.makeFirstResponder(controller.viewer); await settle()
        await sendKey(kVK_RightArrow)
        if controller.session.currentPage == beforePage {
            await sendKey(kVK_LeftArrow)
        }
        await until("翻页后信息面板更新（当前页=\(controller.session.currentPage)，目标=\(expectedNext)）") {
            guard controller.session.currentPage != beforePage,
                  let cur = infoPanel.currentEntry else { return false }
            return cur.name != "写真-2024-01.jpg" && infoPanel.details != nil
        }
        let values2 = Set(allTextFields(in: infoPanel.view).map(\.stringValue))
        let newName = infoPanel.currentEntry?.name ?? ""
        log.check(!newName.isEmpty && newName != "写真-2024-01.jpg" && values2.contains(newName),
                  "C2.8 翻页后信息面板更新为新页面的文件与拍摄信息：\(newName)")
    }

    // MARK: 夹具构造

    private struct Fixtures {
        let rootDir: URL
        let outsideDir: URL
        let cancelDir: URL
        let firstBookDir: URL
        let albumDir: URL
        let batchDir: URL
        let readonlyDir: URL
        let archiveURL: URL
        let only2023URL: URL
    }

    private func buildFixtures() throws -> Fixtures {
        let rootDir = temporary.appending(path: "root", directoryHint: .isDirectory)
        let outsideDir = temporary.appending(path: "outside", directoryHint: .isDirectory)
        let cancelDir = temporary.appending(path: "cancel-dir", directoryHint: .isDirectory)
        let albumDir = rootDir.appending(path: "21-album", directoryHint: .isDirectory)
        let deepDir = rootDir.appending(path: "22-deep/sub1/sub2", directoryHint: .isDirectory)
        let batchDir = rootDir.appending(path: "24-batch", directoryHint: .isDirectory)
        let readonlyDir = rootDir.appending(path: "25-readonly", directoryHint: .isDirectory)

        for dir in [rootDir, outsideDir, cancelDir, albumDir, deepDir, batchDir, readonlyDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 20 个普通书目录，让书架可滚动以验证 Esc 恢复滚动位置。
        var firstBookDir = rootDir
        for i in 1...20 {
            let dir = rootDir.appending(path: String(format: "%02d-book", i), directoryHint: .isDirectory)
            if i == 1 { firstBookDir = dir }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try writeJPEG(to: dir.appending(path: "cover.jpg"), hue: CGFloat(i) * 0.04)
        }

        // 21-album：含 EXIF JPEG、仅命中单词的 JPEG、PNG。
        try writeJPEG(to: albumDir.appending(path: "写真-2024-01.jpg"), hue: 0.1,
                      exif: ExifSpec(make: "Canon", model: "Canon EOS R5", lens: "RF50mm F1.2 L USM", focal: 50, fNumber: 1.4, exposure: 1.0 / 500.0, iso: 400))
        try writeJPEG(to: albumDir.appending(path: "写真-2024-02.jpg"), hue: 0.3,
                      exif: ExifSpec(make: "Sony", model: "ILCE-7M4", lens: "FE 35mm F1.4 GM", focal: 35, fNumber: 2.8, exposure: 1.0 / 100.0, iso: 200))
        let only2023URL = albumDir.appending(path: "写真-2023-only.jpg")
        try writeJPEG(to: only2023URL, hue: 0.5)
        try writeJPEG(to: albumDir.appending(path: "风景-2024-only.jpg"), hue: 0.7)
        try writePNG(to: albumDir.appending(path: "sample.png"), hue: 0.9)

        // 深层嵌套目录文件。
        try writeJPEG(to: deepDir.appending(path: "deep-写真-2024.jpg"), hue: 0.25)

        // ZIP 压缩包。
        let zipSrc = temporary.appending(path: "zip-src", directoryHint: .isDirectory)
        try fm.createDirectory(at: zipSrc, withIntermediateDirectories: true)
        try writeJPEG(to: zipSrc.appending(path: "zip-01.jpg"), hue: 0.4)
        try writePNG(to: zipSrc.appending(path: "zip-02.png"), hue: 0.6)
        let archiveURL = rootDir.appending(path: "23-archive.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", zipSrc.path, archiveURL.path]
        try ditto.run(); ditto.waitUntilExit()

        // 24-batch：20 张 JPEG。
        for i in 1...20 {
            try writeJPEG(to: batchDir.appending(path: String(format: "batch-%02d.jpg", i)), hue: CGFloat(i) * 0.045)
        }

        // 25-readonly：只读目录与只读 JPEG。
        let roFile = readonlyDir.appending(path: "ro-photo.jpg")
        try writeJPEG(to: roFile, hue: 0.8)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: roFile.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyDir.path)
        self.readonlyDir = readonlyDir
        self.readonlyFile = roFile

        // outside：范围外同名匹配文件。
        try writeJPEG(to: outsideDir.appending(path: "outside-写真-2024.jpg"), hue: 0.15)

        // cancel-dir：用于取消索引测试。
        for i in 1...120 {
            try writeJPEG(to: cancelDir.appending(path: String(format: "c-%03d.jpg", i)), width: 64, height: 64, hue: CGFloat(i % 10) * 0.1)
        }

        return Fixtures(
            rootDir: rootDir, outsideDir: outsideDir, cancelDir: cancelDir,
            firstBookDir: firstBookDir, albumDir: albumDir, batchDir: batchDir,
            readonlyDir: readonlyDir, archiveURL: archiveURL, only2023URL: only2023URL
        )
    }

    private func restoreReadonlyPermissions() {
        if let dir = readonlyDir { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        if let file = readonlyFile { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
    }

    private struct ExifSpec {
        let make: String
        let model: String
        let lens: String
        let focal: Double
        let fNumber: Double
        let exposure: Double
        let iso: Int
    }

    private func writeJPEG(to url: URL, width: Int = 240, height: Int = 180, hue: CGFloat, exif: ExifSpec? = nil) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if let exif {
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: exif.make,
                kCGImagePropertyTIFFModel: exif.model,
            ]
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifLensModel: exif.lens,
                kCGImagePropertyExifFocalLength: exif.focal,
                kCGImagePropertyExifFNumber: exif.fNumber,
                kCGImagePropertyExifExposureTime: exif.exposure,
                kCGImagePropertyExifISOSpeedRatings: [exif.iso],
                kCGImagePropertyExifDateTimeOriginal: "2024:05:10 14:30:00",
            ]
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 35.6762,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.6503,
                kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func writePNG(to url: URL, width: Int = 200, height: Int = 160, hue: CGFloat) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
    }

    // MARK: 事件与视图辅助

    private func tagEditorPopover() -> TagEditorPopover? {
        NSApp.windows.compactMap { $0.contentViewController as? TagEditorPopover }.first
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let field = view as? NSTextField { result.append(field) }
        for sub in view.subviews { result.append(contentsOf: allTextFields(in: sub)) }
        return result
    }

    private func firstBadge(in view: NSView) -> UnavailableBadge? {
        if let badge = view as? UnavailableBadge { return badge }
        for sub in view.subviews { if let found = firstBadge(in: sub) { return found } }
        return nil
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(160)) }

    private func until(_ description: String, attempts: Int = 240, condition: () -> Bool) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        log.check(condition(), "等待超时：\(description)")
    }

    private func sendKey(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) async {
        guard let window = NSApp.keyWindow ?? targetWindow else { return }
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        for down in [true, false] {
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            if NSApp.keyWindow != nil {
                NSApp.sendEvent(event)
            } else if event.type == .keyUp || (!window.performKeyEquivalent(with: event) && NSApp.mainMenu?.performKeyEquivalent(with: event) != true) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func click(_ button: NSButton, in window: NSWindow) async {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        NSApp.sendEvent(event(.leftMouseDown))
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func activateTableRow(_ row: Int, in table: NSTableView, window: NSWindow) async {
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        table.scrollRowToVisible(row)
        if NSApp.isActive {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
            let savedCursor = NSEvent.mouseLocation
            let screenPoint = window.convertPoint(toScreen: point)
            let displayMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: displayMaxY - screenPoint.y))
            defer { CGWarpMouseCursorPosition(CGPoint(x: savedCursor.x, y: displayMaxY - savedCursor.y)) }
            eventNumber += 1
            let num = eventNumber
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: num, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                )!
            }
            NSApp.postEvent(event(.mouseMoved), atStart: false)
            NSApp.postEvent(event(.leftMouseDown), atStart: false)
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            try? await Task.sleep(for: .milliseconds(160))
        } else {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window.makeFirstResponder(table)
            await sendKey(kVK_Return)
        }
    }
}
#endif
