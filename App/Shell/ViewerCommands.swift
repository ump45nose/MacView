import AppKit
import MVCommands
import MVFoundation
import MVMedia
import MVReading
import MVSettings

/// 查看器的命令：浏览方式、双页、缩放、排序。
extension AppDelegate {
    func registerViewerCommands(in registry: CommandRegistry) {
        func register(
            _ id: CommandID, needsBook: Bool = true,
            perform: @escaping @MainActor (ReaderWindowController, [String: JSONValue]?) -> Void
        ) {
            guard let descriptor = catalog.descriptor(id) else {
                preconditionFailure("命令清单中没有 \(id.rawValue)")
            }
            registry.register(descriptor, isEnabled: { [weak self] context in
                guard let controller = self?.controller(for: context.session) else { return false }
                return !needsBook || controller.session.book != nil
            }) { [weak self] context, arguments in
                guard let controller = self?.controller(for: context.session) else { return }
                perform(controller, arguments)
            }
        }

        register(.bookReveal) { controller, _ in controller.revealBook() }

        let browse: [(CommandID, BrowseMode)] = [
            (.browsePaged, .paged), (.browseWaterfall, .waterfall), (.browseVerticalStrip, .verticalStrip), (.browseHorizontalStrip, .horizontalStrip),
        ]
        for (id, mode) in browse {
            register(id, needsBook: false) { controller, _ in controller.session.update { $0.browseMode = mode } }
        }
        register(.pageModeToggle, needsBook: false) { controller, _ in
            let mode = controller.session.settings.pageMode
            controller.session.update { $0.pageMode = mode == .single ? .double : .single }
        }
        register(.readingDirectionToggle, needsBook: false) { controller, _ in
            let direction = controller.session.settings.direction
            controller.session.update { $0.direction = direction == .leftToRight ? .rightToLeft : .leftToRight }
        }
        register(.firstPageSingleToggle, needsBook: false) { controller, _ in
            let value = controller.session.settings.firstPageSingle
            controller.session.update { $0.firstPageSingle = !value }
        }
        for (id, policy) in [(CommandID.widePageAsIs, WidePagePolicy.asIs), (.widePageSingle, .single), (.widePageSplit, .split)] {
            register(id, needsBook: false) { controller, _ in controller.session.update { $0.widePage = policy } }
        }

        let scales: [(CommandID, ScaleMode)] = [
            (.zoomOriginal, .original), (.zoomFitWindow, .fitWindow), (.zoomFitWidth, .fitWidth), (.zoomFitHeight, .fitHeight),
            (.zoomFill, .fill), (.zoomDevicePixel, .devicePixel),
        ]
        for (id, mode) in scales {
            register(id, needsBook: false) { controller, _ in
                controller.session.update { $0.scaleMode = mode }
                controller.viewer.paged.resetTransform()
            }
        }
        register(.zoomFixed, needsBook: false) { controller, arguments in
            if case let .number(percent)? = arguments?["percent"] {
                controller.applyFixedScale(percent / 100)
            } else {
                controller.askFixedScale()
            }
        }
        register(.zoomIn) { controller, _ in controller.viewer.zoom(by: 1.25) }
        register(.zoomOut) { controller, _ in controller.viewer.zoom(by: 0.8) }
        register(.zoomAllowUpscaleToggle, needsBook: false) { controller, _ in
            let value = controller.session.settings.allowUpscale
            controller.session.update { $0.allowUpscale = !value }
        }
        register(.keepZoomOnPageTurnToggle, needsBook: false) { controller, _ in
            let value = controller.session.settings.keepZoomOnPageTurn
            controller.session.update { $0.keepZoomOnPageTurn = !value }
        }
        register(.magnifierToggle) { controller, _ in controller.viewer.paged.toggleMagnifier() }
        register(.retryFailed) { controller, _ in controller.viewer.retryFailed() }

        let sorts: [(CommandID, SortKey)] = [
            (.sortName, .name), (.sortModified, .modified), (.sortCreated, .created), (.sortSize, .size), (.sortType, .type), (.sortRandom, .random),
        ]
        for (id, key) in sorts {
            register(id, needsBook: false) { controller, _ in
                var sort = controller.session.settings.sort
                sort.key = key
                // 随机排序每次选都换一个种子。
                sort.randomSeed = key == .random ? UInt64.random(in: .min ... .max) : nil
                controller.session.update { $0.sort = sort }
            }
        }
        for (id, ascending) in [(CommandID.sortAscending, true), (.sortDescending, false)] {
            register(id, needsBook: false) { controller, _ in
                var sort = controller.session.settings.sort
                sort.ascending = ascending
                controller.session.update { $0.sort = sort }
            }
        }
        register(.sortFoldersFirstToggle, needsBook: false) { controller, _ in
            var sort = controller.session.settings.sort
            sort.foldersFirst.toggle()
            controller.session.update { $0.sort = sort }
        }
        register(.recursionToggle, needsBook: false) { controller, _ in
            var recursion = controller.session.settings.recursion
            recursion.enabled.toggle()
            controller.session.update { $0.recursion = recursion }
        }
    }
}

extension ReaderWindowController {
    func applyFixedScale(_ scale: Double) {
        session.update {
            $0.scaleMode = .fixed
            $0.fixedScale = scale
        }
        viewer.paged.resetTransform()
    }

    /// `zoom.fixed`：输入百分比。
    func askFixedScale() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "固定百分比")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(Int((session.settings.fixedScale * 100).rounded()))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "好"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let percent = Double(field.stringValue), percent > 0 else { return }
            self?.applyFixedScale(percent / 100)
        }
    }
}
