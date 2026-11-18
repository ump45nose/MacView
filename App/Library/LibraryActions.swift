import AppKit
import Foundation
import MVCommands
import MVFoundation
import MVLibraryData
import MVReading

/// 播放列表面板实现：命令“从播放列表移除”作用于它选中的项。
@MainActor
protocol PlaylistSelectionSource: AnyObject {
    /// 面板显示的列表和选中的项；没有选中时为 nil。
    var playlistSelection: (playlist: UUID, items: [Location])? { get }
}

/// 书签与播放列表的加入、移除、打开所在的书，以及各入口共用的菜单项和短提示。
@MainActor
enum LibraryActions {
    /// 播放列表摘要，按列表顺序；订阅资料库变化保持最新，供右键菜单同步读取。
    private(set) static var playlists: [PlaylistSummary] = []
    private static var observeTask: Task<Void, Never>?

    /// 启动时调用一次：读取播放列表并订阅变化。
    static func observe(_ library: any LibraryStore) {
        observeTask?.cancel()
        observeTask = Task {
            let changes = library.changes()
            if let lists = try? await library.playlists() { playlists = lists }
            for await change in changes where change == .playlists {
                if let lists = try? await library.playlists() { playlists = lists }
            }
        }
    }

    /// 最近用的列表：最近加入过项的；都没用过时为 nil。与 `LibraryStore.recentPlaylist()` 的取法一致。
    static func recentPlaylist(in lists: [PlaylistSummary]) -> UUID? {
        var recent: PlaylistSummary?
        for list in lists {
            if let used = list.lastUsedAt, used > (recent?.lastUsedAt ?? .distantPast) { recent = list }
        }
        return recent?.id
    }

    // MARK: 菜单项

    /// “加到播放列表 ▸”：最近用的列表排第一，末尾“新建播放列表…”。
    static func playlistMenu(for entries: [Entry], app: AppDelegate) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recent = recentPlaylist(in: playlists)
        for list in playlists.filter({ $0.id == recent }) + playlists.filter({ $0.id != recent }) {
            let item = MenuAction(list.name) { Task { await addToPlaylist(entries, playlist: list.id, app: app) } }.item
            if list.id == recent {
                item.badge = NSMenuItemBadge(string: String(localized: "最近用"))
                setShortcut(of: .playlistAddCurrent, on: item, app: app)
            }
            submenu.addItem(item)
        }
        if !playlists.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(MenuAction(String(localized: "新建播放列表…")) { Task { await addToNewPlaylist(entries, app: app) } }.item)
        let holder = NSMenuItem(title: String(localized: "加到播放列表"), action: nil, keyEquivalent: "")
        holder.submenu = submenu
        holder.isEnabled = !entries.isEmpty && app.services?.library != nil
        return holder
    }

    /// 书架右键的“加入书签”。
    static func bookmarkMenuItem(for books: [Location], app: AppDelegate) -> NSMenuItem {
        let item = MenuAction(String(localized: "加入书签")) { Task { await addBookmarks(books, app: app) } }.item
        setShortcut(of: .bookmarkAdd, on: item, app: app)
        item.isEnabled = !books.isEmpty && app.services?.library != nil
        return item
    }

    /// 页面列表和查看器右键的资料库项：“加到播放列表 ▸”；虚拟书里再加“从列表移除”“打开所在的书”。
    static func pageMenuItems(for entries: [Entry], in session: ReaderSession, app: AppDelegate) -> [NSMenuItem] {
        let items = [playlistMenu(for: entries, app: app)]
        guard let playlist = session.book?.location.playlistID else { return items }
        let locations = entries.map(\.location)
        let remove = MenuAction(String(localized: "从列表移除")) {
            Task { await removeFromPlaylist(locations, playlist: playlist, app: app) }
        }.item
        setShortcut(of: .playlistRemoveItem, on: remove, app: app)
        let open = MenuAction(String(localized: "打开所在的书")) {
            Task { await openContainingBook(of: locations[0], app: app) }
        }.item
        open.isEnabled = locations.count == 1
        return items + [remove, open]
    }

    private static func setShortcut(of command: CommandID, on item: NSMenuItem, app: AppDelegate) {
        guard let chord = app.catalog.menuBinding(for: command)?.sequence.first,
              let equivalent = KeyMapping.menuKeyEquivalent(for: chord) else { return }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.mask
    }

    // MARK: 书签

    /// 加入书签并提示结果；虚拟书的位置不能加入。书签面板接收拖入时给出文件夹和位置。
    static func addBookmarks(_ books: [Location], into folder: BookmarkID? = nil, at index: Int? = nil, app: AppDelegate) async {
        guard !books.isEmpty, let library = app.services?.library else { return }
        guard books.allSatisfy({ $0.playlistID == nil }) else {
            showMessage(String(localized: "播放列表不能加入书签"), app: app)
            return
        }
        do {
            let report = try await library.addBookmarks(books, into: folder, at: index)
            showMessage(bookmarkMessage(books, report: report), app: app)
        } catch {
            showMessage(ErrorText.describe(error), app: app)
        }
    }

    private static func bookmarkMessage(_ books: [Location], report: AddReport) -> String {
        if books.count == 1 {
            let name = books[0].name
            return report.added > 0 ? String(localized: "已加入书签：\(name)") : String(localized: "《\(name)》已在书签里")
        }
        if report.added == 0 { return String(localized: "都已在书签里") }
        if report.alreadyPresent == 0 { return String(localized: "已加入书签：\(report.added) 本") }
        return String(localized: "已加入书签 \(report.added) 本，\(report.alreadyPresent) 本已在书签里")
    }

    // MARK: 播放列表

    static func addToPlaylist(_ entries: [Entry], playlist: UUID, app: AppDelegate) async {
        guard !entries.isEmpty, let library = app.services?.library else { return }
        do {
            let name = try await library.playlists().first { $0.id == playlist }?.name ?? ""
            try await add(entries, to: playlist, named: name, library: library, app: app)
        } catch {
            showMessage(ErrorText.describe(error), app: app)
        }
    }

    /// ⌘L：加到最近用的列表；没用过任何列表时加到第一个，一个列表都没有时新建。
    static func addToRecentPlaylist(_ entries: [Entry], app: AppDelegate) async {
        guard !entries.isEmpty, let library = app.services?.library else { return }
        do {
            let lists = try await library.playlists()
            let id = recentPlaylist(in: lists) ?? lists.first?.id
            if let list = lists.first(where: { $0.id == id }) {
                try await add(entries, to: list.id, named: list.name, library: library, app: app)
            } else {
                await addToNewPlaylist(entries, app: app)
            }
        } catch {
            showMessage(ErrorText.describe(error), app: app)
        }
    }

    /// 新建“新播放列表 N”并加入这些项；加入后它成为最近用的列表。
    static func addToNewPlaylist(_ entries: [Entry], app: AppDelegate) async {
        guard let library = app.services?.library else { return }
        do {
            let names = Set(try await library.playlists().map(\.name))
            var number = names.count + 1
            while names.contains(String(localized: "新播放列表 \(number)")) { number += 1 }
            let name = String(localized: "新播放列表 \(number)")
            let id = try await library.createPlaylist(named: name)
            if entries.isEmpty { return }
            try await add(entries, to: id, named: name, library: library, app: app)
        } catch {
            showMessage(ErrorText.describe(error), app: app)
        }
    }

    private static func add(_ entries: [Entry], to playlist: UUID, named name: String, library: any LibraryStore, app: AppDelegate) async throws {
        let report = try await library.addItems(entries, to: playlist)
        let message = if report.added == 0 {
            String(localized: "都已在「\(name)」里")
        } else if report.alreadyPresent == 0 {
            String(localized: "已加 \(report.added) 项到「\(name)」")
        } else {
            String(localized: "已加 \(report.added) 项到「\(name)」，\(report.alreadyPresent) 项已在列表中")
        }
        showMessage(message, app: app)
    }

    /// 从列表移除，只拿掉条目，原文件不动。
    static func removeFromPlaylist(_ items: [Location], playlist: UUID, app: AppDelegate) async {
        guard !items.isEmpty, let library = app.services?.library else { return }
        do {
            let name = try await library.playlists().first { $0.id == playlist }?.name ?? ""
            try await library.removeItems(items, from: playlist)
            showMessage(String(localized: "已从「\(name)」移除 \(items.count) 项，原文件不动"), app: app)
        } catch {
            showMessage(ErrorText.describe(error), app: app)
        }
    }

    /// 拖进播放列表的位置换成条目：从打开的书里取（拖动来源是页面列表），取不到的按位置补一个，加载列表时会重新校验。
    static func entries(for locations: [Location], app: AppDelegate) -> [Entry] {
        var known: [Location: Entry] = [:]
        for controller in app.controllers {
            for page in controller.session.book?.pages ?? [] { known[page.id] = page.entry }
        }
        return locations.map { location in
            known[location] ?? Entry(
                identity: ContentIdentity(location: location, size: 0, modificationNanos: 0),
                name: location.name, kind: EntryKind(fileName: location.name)
            )
        }
    }

    // MARK: 打开所在的书

    /// 压缩包里的页所在的书是压缩包，其余是所在的文件夹。
    static func containingBook(of page: Location) -> Location? {
        page.layers.count > 1 ? Location(root: page.root, layers: Array(page.layers.dropLast())) : page.parent
    }

    /// 在当前窗口打开这一页所在的书，并跳到这一页。
    static func openContainingBook(of page: Location, app: AppDelegate) async {
        guard let book = containingBook(of: page), let session = (app.mainController ?? app.controllers.first)?.session else { return }
        if session.book?.location == book, let index = session.book?.pages.firstIndex(where: { $0.id == page }) {
            session.go(.index(index))
        } else {
            await session.open(book, at: page)
        }
    }

    // MARK: 提示

    /// 加入、移除后的短提示，显示在当前窗口的状态栏。
    static func showMessage(_ text: String, app: AppDelegate) {
        (app.mainController ?? app.controllers.first)?.content.statusBar.showMessage(text)
    }
}
