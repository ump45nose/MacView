import AppKit
import MVCommands
import MVFoundation
import MVLayout
import MVLibraryData
import MVReading

/// App 侧登记的命令处理器：窗口、标签页、全屏、打开、关闭等界面命令，以及翻页、跳页与切书。查看器的命令见 `registerViewerCommands`。
extension AppDelegate {
    func registerCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID,
            isEnabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
            perform: @escaping @MainActor (CommandContext) -> Void
        ) {
            guard let descriptor = CommandCatalog.builtInDescriptor(id) else {
                preconditionFailure("命令清单中没有 \(id.rawValue)")
            }
            registry.register(descriptor, isEnabled: isEnabled) { context, _ in perform(context) }
        }

        let noModal: @MainActor (CommandContext) -> Bool = { _ in NSApp.modalWindow == nil }
        let hasWindow: @MainActor (CommandContext) -> Bool = { [weak self] context in self?.controller(for: context.session) != nil }
        register(.settingsOpen, isEnabled: noModal) { [weak self] _ in _ = self?.openSettings() }
        register(.windowNew, isEnabled: noModal) { [weak self] _ in self?.newWindow() }
        register(.windowNewTab, isEnabled: noModal) { [weak self] context in
            guard let self else { return }
            newTab(beside: controller(for: context.session))
        }
        register(.windowClose, isEnabled: { _ in NSApp.keyWindow != nil }) { _ in
            NSApp.keyWindow?.performClose(nil)
        }
        register(.fullScreenToggle, isEnabled: hasWindow) { [weak self] context in
            self?.controller(for: context.session)?.window?.toggleFullScreen(nil)
        }
        register(.fileOpen, isEnabled: noModal) { [weak self] context in
            guard let self else { return }
            (controller(for: context.session) ?? newWindow())?.chooseBook()
        }
        registerFileCommands(in: registry)
        for (id, action, isUndo) in [(CommandID.editUndo, #selector(ReaderWindow.undo(_:)), true), (.editRedo, #selector(ReaderWindow.redo(_:)), false)] {
            register(id, isEnabled: { [weak self] context in
                guard let self else { return false }
                let window = (controller(for: context.session) ?? mainController ?? controllers.first)?.window as? ReaderWindow
                if window?.isEditingText == true {
                    let manager = window?.firstResponder?.undoManager
                    return (isUndo ? manager?.canUndo : manager?.canRedo) == true
                }
                return fileOps?.isBusy == false && (isUndo ? fileOps?.undoManager.canUndo : fileOps?.undoManager.canRedo) == true
            }) { [weak self] context in
                guard let self else { return }
                let target = controller(for: context.session) ?? mainController ?? controllers.first
                if (target?.window as? ReaderWindow)?.isEditingText != true, fileOps?.isBusy == true {
                    target?.content.statusBar.showMessage(String(localized: "文件操作完成后才能撤销"))
                } else if !NSApp.sendAction(action, to: nil, from: nil) {
                    if isUndo { undo(nil) } else { redo(nil) }
                }
            }
        }

        let moves: [(CommandID, PageMove)] = [
            (.frameNext, .nextFrame), (.framePrevious, .previousFrame), (.pageNext, .nextPage), (.pagePrevious, .previousPage),
            (.pageFirst, .first), (.pageLast, .last),
        ]
        for (id, move) in moves {
            register(id, isEnabled: { [weak self] context in
                guard let session = self?.controller(for: context.session)?.session, !session.frames.isEmpty else { return false }
                switch move {
                case .nextFrame, .nextPage, .previousFrame, .previousPage, .index: return true
                case .last: return session.currentFrame < session.frames.count - 1
                case .first: return session.currentFrame > 0
                }
            }) { [weak self] context in
                self?.controller(for: context.session)?.session.go(move)
            }
        }
        register(.pageJump, isEnabled: { [weak self] context in
            self?.controller(for: context.session)?.session.frames.isEmpty == false
        }) { [weak self] context in
            self?.controller(for: context.session)?.beginPageJump()
        }

        // 停靠区与面板：作用于命令所在的窗口；浮动面板全应用切换。
        let areas: [(CommandID, (DockLayout) -> DockLayout)] = [
            (.dockLeftToggle, { $0.togglingArea(.left) }), (.dockRightToggle, { $0.togglingArea(.right) }),
            (.dockBottomToggle, { $0.togglingArea(.bottom) }), (.docksToggle, { $0.togglingAllAreas() }),
        ]
        for (id, transform) in areas {
            register(id, isEnabled: hasWindow) { [weak self] context in
                self?.controller(for: context.session)?.dock.perform(transform)
            }
        }
        for type in DockPanels.builtins {
            register(type.toggleCommand, isEnabled: hasWindow) { [weak self] context in
                guard let self else { return }
                dock?.togglePanel(type, in: controller(for: context.session)?.dock)
            }
        }

        for (id, direction) in [(CommandID.bookNext, NavigationDirection.forward), (.bookPrevious, .backward)] {
            register(id, isEnabled: { [weak self] context in
                guard let session = self?.controller(for: context.session)?.session else { return false }
                return session.book != nil && !session.isVirtualBook
            }) { [weak self] context in
                self?.controller(for: context.session)?.openNeighbor(direction)
            }
        }
        registerLibraryCommands(in: registry)
        registerSearchCommands(in: registry)
        registerMetadataCommands(in: registry)
        registerViewerCommands(in: registry)
    }

    /// 评分 0–5（⌥0–⌥5）与编辑标签…（⌥T）：作用于查看器当前页，列表有焦点时为选中项；不可评分对象菜单灰掉。
    private func registerMetadataCommands(in registry: CommandRegistry) {
        let ratings: [(CommandID, Int)] = [
            (.ratingSet0, 0), (.ratingSet1, 1), (.ratingSet2, 2),
            (.ratingSet3, 3), (.ratingSet4, 4), (.ratingSet5, 5),
        ]
        for (id, value) in ratings {
            guard let descriptor = CommandCatalog.builtInDescriptor(id) else { continue }
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self, let writer = metadataWriter else { return false }
                return writer.canEdit(activeFileOrigin(for: context.session))
            }) { [weak self] context, _ in
                guard let self, let writer = metadataWriter else { return }
                writer.setRating(value, origin: activeFileOrigin(for: context.session))
            }
        }
        if let descriptor = CommandCatalog.builtInDescriptor(.metadataTagsEdit) {
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self, let writer = metadataWriter else { return false }
                return writer.canEdit(activeFileOrigin(for: context.session))
            }) { [weak self] context, _ in
                guard let self, let writer = metadataWriter else { return }
                writer.presentTagEditor(origin: activeFileOrigin(for: context.session))
            }
        }
    }

    /// 搜索与建立索引：⌘F 聚焦书架搜索框（隐藏时先显示），“为此文件夹建立索引”作用于书架当前或选中的文件夹。
    private func registerSearchCommands(in registry: CommandRegistry) {
        if let descriptor = CommandCatalog.builtInDescriptor(.searchFocus) {
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self else { return false }
                return (controller(for: context.session) ?? mainController ?? controllers.first) != nil
            }) { [weak self] context, _ in
                guard let self, let target = controller(for: context.session) ?? mainController ?? controllers.first else { return }
                target.focusBookshelfSearch()
            }
        }
        if let descriptor = CommandCatalog.builtInDescriptor(.searchIndexFolder) {
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self, services?.indexer != nil, !IndexController.shared.isIndexing,
                      let target = controller(for: context.session) ?? mainController ?? controllers.first else { return false }
                return target.folderForIndexing != nil
            }) { [weak self] context, _ in
                guard let self, let target = controller(for: context.session) ?? mainController ?? controllers.first else { return }
                target.indexCurrentFolder()
            }
        }
    }

    /// 书签与播放列表：⌘D 加入书签，⌘L 加到最近用的列表，从播放列表移除。资料库不可用时都不可用。
    private func registerLibraryCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID,
            isEnabled: @escaping @MainActor (ReaderWindowController) -> Bool,
            perform: @escaping @MainActor (ReaderWindowController, AppDelegate) async -> Void
        ) {
            guard let descriptor = CommandCatalog.builtInDescriptor(id) else { preconditionFailure("命令清单中没有 \(id.rawValue)") }
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self, services?.library != nil, let controller = controller(for: context.session) ?? mainController else { return false }
                return isEnabled(controller)
            }) { [weak self] context, _ in
                guard let self, let controller = controller(for: context.session) ?? mainController else { return }
                await perform(controller, self)
            }
        }
        if let library = services?.library { LibraryActions.observe(library) }

        // 书架有焦点并选中了书时作用于选中的书，否则是当前的书；虚拟书由 LibraryActions 提示不能加入。
        register(.bookmarkAdd, isEnabled: { [weak self] in self?.bookmarkTargets(in: $0).isEmpty == false }) { controller, app in
            await LibraryActions.addBookmarks(app.bookmarkTargets(in: controller), app: app)
        }
        register(.playlistAddCurrent, isEnabled: { [weak self] in self?.pageTargets(in: $0).isEmpty == false }) { controller, app in
            await LibraryActions.addToRecentPlaylist(app.pageTargets(in: controller), app: app)
        }
        register(.playlistRemoveItem, isEnabled: { [weak self] in self?.removalTargets(in: $0) != nil }) { controller, app in
            guard let targets = app.removalTargets(in: controller) else { return }
            await LibraryActions.removeFromPlaylist(targets.items, playlist: targets.playlist, app: app)
        }
    }

    /// 键盘焦点所在的面板：停靠在这个窗口，或浮动着（书架、页面列表须绑定到这个窗口）。
    private func focusedPanel(in controller: ReaderWindowController) -> (any DockPanel)? {
        let key = NSApp.keyWindow
        let responder = (key === controller.window || key is FloatingPanelWindow) ? key?.firstResponder : controller.window?.firstResponder
        guard let view = responder as? NSView else { return nil }
        let panels = Array(controller.dock.panels.values) + controller.dock.coordinator.floatingWindows.values.map(\.panel)
        return panels.first { panel in
            view.isDescendant(of: panel.view) && (panel as? CollectionPanel).map { $0.owner === controller } != false
        }
    }

    private func bookmarkTargets(in controller: ReaderWindowController) -> [Location] {
        if let shelf = focusedPanel(in: controller) as? BookshelfPanel, !shelf.targetEntries.isEmpty {
            return shelf.targetEntries.map(\.location)
        }
        return controller.session.book.map { [$0.location] } ?? []
    }

    /// 页面列表有焦点并选中了页时是选中的页，否则是查看器的当前页。
    private func pageTargets(in controller: ReaderWindowController) -> [Entry] {
        if let pageList = focusedPanel(in: controller) as? PageListPanel, !pageList.targetEntries.isEmpty {
            return pageList.targetEntries
        }
        let session = controller.session
        guard let pages = session.book?.pages, pages.indices.contains(session.currentPage) else { return [] }
        return [pages[session.currentPage].entry]
    }

    /// 播放列表面板有焦点时是它选中的项；否则在虚拟书里是页面列表选中的页或当前页。
    private func removalTargets(in controller: ReaderWindowController) -> (playlist: UUID, items: [Location])? {
        if let source = focusedPanel(in: controller) as? PlaylistSelectionSource { return source.playlistSelection }
        guard let playlist = controller.session.book?.location.playlistID else { return nil }
        let items = pageTargets(in: controller).map(\.location)
        return items.isEmpty ? nil : (playlist, items)
    }

    func activeFileOrigin(for session: SessionID? = nil) -> FileOrigin {
        (controller(for: session) ?? mainController ?? controllers.first)?.fileOrigin() ?? FileOrigin()
    }

    func menuTitle(for id: CommandID) -> String? {
        guard id == .fileDelete, let fileOps else { return nil }
        return fileOps.deleteTitle(for: activeFileOrigin())
    }

    func menuState(for id: CommandID) -> NSControl.StateValue? {
        switch id {
        case .effectsToggle:
            guard let controller = mainController ?? controllers.first else { return nil }
            return controller.effectsEnabled ? .on : .off
        case .windowKeepOnTopToggle:
            return appearance?.current.window.keepOnTop == true ? .on : .off
        case .windowTitleBarAutoHideToggle:
            return appearance?.current.window.titleBar == .autoHide ? .on : .off
        case .windowBorderlessToggle:
            return appearance?.current.window.titleBar == .borderless ? .on : .off
        default:
            return nil
        }
    }

    func updateSubmenu(key: String, menu: NSMenu) -> Bool {
        if key == "套用显示配置" {
            return populateDisplayProfilesMenu(menu)
        }
        guard let fileOps else { menu.removeAllItems(); return false }
        let origin = activeFileOrigin()
        switch key {
        case "用指定应用打开": return fileOps.populateOpenWithMenu(menu, origin: origin)
        case "移动到": return fileOps.populateTransferMenu(menu, origin: origin, mode: .move)
        case "复制到": return fileOps.populateTransferMenu(menu, origin: origin, mode: .copy)
        default: return false
        }
    }

    private func populateDisplayProfilesMenu(_ menu: NSMenu) -> Bool {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let controller = mainController ?? controllers.first
        let hasBook = controller?.session.book != nil
        if cachedProfiles.isEmpty {
            let empty = NSMenuItem(title: String(localized: "还没有显示配置"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return true
        }
        for (index, profile) in cachedProfiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(applyDisplayProfileFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = hasBook
            if index < 9 {
                item.representedObject = MenuDisplayShortcut(key: String(index + 1), mask: .control, payload: profile.id)
            } else {
                item.representedObject = profile.id
            }
            menu.addItem(item)
        }
        return true
    }

    @objc private func applyDisplayProfileFromMenu(_ sender: NSMenuItem) {
        guard let controller = mainController ?? controllers.first, controller.session.book != nil else { return }
        let profileID: UUID?
        if let shortcut = sender.representedObject as? MenuDisplayShortcut {
            profileID = shortcut.payload as? UUID
        } else {
            profileID = sender.representedObject as? UUID
        }
        guard let profileID, let profile = cachedProfiles.first(where: { $0.id == profileID }) else { return }
        DisplayProfileHelpers.applyToBook(profile, in: controller)
    }

    private func registerFileCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID,
            isEnabled: @escaping @MainActor (FileOperationController, FileOrigin) -> Bool,
            perform: @escaping @MainActor (FileOperationController, FileOrigin, [String: JSONValue]?) -> Void
        ) {
            guard let descriptor = CommandCatalog.builtInDescriptor(id) else { preconditionFailure("命令清单中没有 \(id.rawValue)") }
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let self, let fileOps else { return false }
                return isEnabled(fileOps, activeFileOrigin(for: context.session))
            }) { [weak self] context, arguments in
                guard let self, let fileOps else { return }
                perform(fileOps, activeFileOrigin(for: context.session), arguments)
            }
        }
        register(.fileDelete, isEnabled: { $0.canModify($1) }) { fileOps, origin, _ in Task { await fileOps.delete(origin: origin) } }
        register(.fileRename, isEnabled: { $0.canRename($1) }) { fileOps, origin, _ in fileOps.presentRename(origin: origin) }
        register(.fileCopy, isEnabled: { $0.canRead($1) }) { fileOps, origin, _ in Task { await fileOps.copyItems(origin: origin) } }
        register(.fileCopyPath, isEnabled: { $0.canRead($1) }) { fileOps, origin, _ in Task { await fileOps.copyPaths(origin: origin) } }
        register(.fileReveal, isEnabled: { $0.canRead($1) }) { fileOps, origin, _ in Task { await fileOps.revealInFinder(origin: origin) } }
        register(.fileOpenWith, isEnabled: { $0.canRead($1) }) { fileOps, origin, arguments in
            if case let .string(path) = arguments?["application"] {
                fileOps.openWithApplication(URL(fileURLWithPath: path), origin: origin)
            } else if let defaultApp = FileOperationController.applicationsForOpening(origin.items).defaultApp {
                fileOps.openWithApplication(defaultApp, origin: origin)
            } else {
                fileOps.chooseApplicationAndOpen(origin: origin)
            }
        }
        if let recycleDescriptor = CommandCatalog.builtInDescriptor(.recycleEmpty) {
            registry.register(recycleDescriptor, isEnabled: { [weak self] _ in self?.services?.fileOperations != nil }) { _, _ in }
        }
        let canTransferData: @MainActor (CommandContext) -> Bool = { [weak self] _ in
            guard let self, let dataTransfer, !isMock else { return false }
            return dataTransfer.canStart
        }
        if let exportDescriptor = CommandCatalog.builtInDescriptor(.dataExport) {
            registry.register(exportDescriptor, isEnabled: canTransferData) { [weak self] _, _ in
                self?.dataTransfer?.exportUserData()
            }
        }
        if let importDescriptor = CommandCatalog.builtInDescriptor(.dataImport) {
            registry.register(importDescriptor, isEnabled: canTransferData) { [weak self] _, _ in
                self?.dataTransfer?.importUserData()
            }
        }
    }
}
