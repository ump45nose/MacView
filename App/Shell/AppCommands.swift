import AppKit
import MVCommands
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
}
