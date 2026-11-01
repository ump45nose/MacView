import AppKit
import MVCommands
import MVReading

/// App 侧登记的命令处理器：窗口、标签页、全屏、打开、关闭等界面命令，以及最简页面视图用到的翻页、跳页与切书。
///
/// 其余 Core 命令（浏览方式、缩放、排序等）由正式查看器与 Core 在之后的任务中登记，菜单中先显示为不可用。
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
        register(.windowNew, isEnabled: noModal) { [weak self] _ in self?.newWindow() }
        register(.windowNewTab, isEnabled: noModal) { [weak self] context in
            guard let self else { return }
            newTab(beside: controller(for: context.session))
        }
        register(.windowClose, isEnabled: { _ in NSApp.keyWindow != nil }) { _ in
            NSApp.keyWindow?.performClose(nil)
        }
        register(.fullScreenToggle, isEnabled: { [weak self] context in self?.controller(for: context.session) != nil }) { [weak self] context in
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

        for (id, direction) in [(CommandID.bookNext, NavigationDirection.forward), (.bookPrevious, .backward)] {
            register(id, isEnabled: { [weak self] context in
                self?.controller(for: context.session)?.session.book != nil
            }) { [weak self] context in
                self?.controller(for: context.session)?.openNeighbor(direction)
            }
        }
    }
}
