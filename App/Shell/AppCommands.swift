import AppKit
import MVCommands
import MVFoundation
import MVLayout
import MVReading

/// App 侧登记的命令处理器：窗口、标签页、全屏、打开、关闭等界面命令，以及翻页、跳页与切书。查看器的命令见 `registerViewerCommands`。
extension AppDelegate {
    func registerCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID,
            isEnabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true },
            perform: @escaping @MainActor (CommandContext) -> Void
        ) {
            guard let descriptor = catalog.descriptor(id) else {
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
                let window = (controller(for: context.session) ?? mainController ?? controllers.first)?.window
                if let textView = window?.firstResponder as? NSTextView {
                    return (isUndo ? textView.undoManager?.canUndo : textView.undoManager?.canRedo) == true
                }
                return fileOps?.isBusy == false && (isUndo ? fileOps?.undoManager.canUndo : fileOps?.undoManager.canRedo) == true
            }) { [weak self] context in
                guard let self else { return }
                let target = controller(for: context.session) ?? mainController ?? controllers.first
                if !(target?.window?.firstResponder is NSTextView), fileOps?.isBusy == true {
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
                case .nextFrame, .nextPage, .last: return session.currentFrame < session.frames.count - 1
                case .previousFrame, .previousPage, .first: return session.currentFrame > 0
                case .index: return true
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
        for type in DockPanels.all {
            register(type.toggleCommand, isEnabled: hasWindow) { [weak self] context in
                guard let self else { return }
                dock?.togglePanel(type, in: controller(for: context.session)?.dock)
            }
        }

        for (id, direction) in [(CommandID.bookNext, NavigationDirection.forward), (.bookPrevious, .backward)] {
            register(id, isEnabled: { [weak self] context in
                self?.controller(for: context.session)?.session.book != nil
            }) { [weak self] context in
                self?.controller(for: context.session)?.openNeighbor(direction)
            }
        }
        registerViewerCommands(in: registry)
    }

    func activeFileOrigin(for session: SessionID? = nil) -> FileOrigin {
        (controller(for: session) ?? mainController ?? controllers.first)?.fileOrigin() ?? FileOrigin()
    }

    func menuTitle(for id: CommandID) -> String? {
        guard id == .fileDelete, let fileOps else { return nil }
        return fileOps.deleteTitle(for: activeFileOrigin())
    }

    func updateSubmenu(key: String, menu: NSMenu) -> Bool {
        guard let fileOps else { menu.removeAllItems(); return false }
        let origin = activeFileOrigin()
        switch key {
        case "用指定应用打开": return fileOps.populateOpenWithMenu(menu, origin: origin)
        case "移动到": return fileOps.populateTransferMenu(menu, origin: origin, mode: .move)
        case "复制到": return fileOps.populateTransferMenu(menu, origin: origin, mode: .copy)
        default: return false
        }
    }

    private func registerFileCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID,
            isEnabled: @escaping @MainActor (FileOperationController, FileOrigin) -> Bool,
            perform: @escaping @MainActor (FileOperationController, FileOrigin, [String: JSONValue]?) -> Void
        ) {
            guard let descriptor = catalog.descriptor(id) else { preconditionFailure("命令清单中没有 \(id.rawValue)") }
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
        if let recycleDescriptor = catalog.descriptor(.recycleEmpty) {
            registry.register(recycleDescriptor, isEnabled: { [weak self] _ in self?.services?.fileOperations != nil }) { _, _ in }
        }
    }
}
