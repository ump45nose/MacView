#if DEBUG
import AppKit
import MVCommands
import MVFoundation
import MVReading
import MVSettings

/// 查看器输入与自定义自检（`-MVInputSelfTest viewer`）。
///
/// 覆盖 C2.1（右键手势与右键菜单共存）与 C2.2（点击区域、滚轮分派、自定义滚轮绑定与原有滚轮行为）。
@MainActor
final class InputSelfTest {
    static let launchKey = "MVInputSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary = TestPresentation.scratchDirectory("input")
    private var eventNumber = 1

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return }
        let test = InputSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        guard app.services != nil, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "输入自检需要真实服务与主窗口")
            exit(log.summarize())
        }
        TestPresentation.place(window)
        window.orderFrontRegardless()
        switch mode {
        case "viewer":
            await runViewerSuite(controller: controller, window: window)
        default:
            log.check(false, "未知的 -MVInputSelfTest 模式：\(mode)")
            exit(log.summarize())
        }
        try? FileManager.default.removeItem(at: temporary)
        await app.services?.shutdown()
        exit(log.summarize())
    }

    // MARK: C2.1 查看器右键手势与右键菜单共存

    private func runViewerSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            window.setContentSize(NSSize(width: 1100, height: 760))
            let book = try makeBook(count: 6)
            await openBook(controller, url: book, expectedCount: 6)
            window.makeFirstResponder(controller.viewer)
            controller.session.update {
                $0.browseMode = .paged
                $0.pageMode = .single
                $0.direction = .leftToRight
                $0.scaleMode = .fitWindow
            }
            await settle()

            try await checkRightGestureTurnPage(controller, window: window)
            await checkRightClickContextMenu(controller, window: window)
            await checkRightGestureCancelWithEscape(controller, window: window)
            await checkLeftDragPanAndDragOut(controller, window: window)
            await checkContinuousModeRightGestureAndMenu(controller, window: window)
            await checkClickZonesAndDragExclusion(controller, window: window)
            try await checkWheelDispatchAndCustomBinding(controller, window: window)
        } catch {
            log.check(false, "输入自检异常：\(error)")
        }
    }

    private func checkRightGestureTurnPage(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)

        // 左开模式下，先翻到第 2 帧（index 1），向右拖再向左拖验证 frame.left 换算为上一帧。
        controller.session.go(.index(1))
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.1 初始位于第 2 帧：\(controller.session.currentFrame)")

        let stepsLeft = [
            NSPoint(x: center.x - 15, y: center.y),
            NSPoint(x: center.x - 40, y: center.y),
            NSPoint(x: center.x - 75, y: center.y),
        ]
        sendMouse(.rightMouseDown, at: center, in: window)
        for point in stepsLeft {
            sendMouse(.rightMouseDragged, at: point, in: window)
        }
        log.check(!viewer.gestureTrailView.isHidden, "C2.1 右键向左拖动超过阈值后显示轨迹浮层")
        log.check(viewer.gestureTrailView.displayedDirections == [.left], "C2.1 轨迹浮层方向序列为 ←：\(viewer.gestureTrailView.displayedDirections)")
        log.check(
            viewer.gestureTrailView.displayedCommandTitle == app.catalog.title(of: .frameLeft),
            "C2.1 轨迹浮层显示命令标题“\(viewer.gestureTrailView.displayedCommandTitle ?? "nil")”"
        )
        sendMouse(.rightMouseUp, at: stepsLeft.last!, in: window)
        await settle()
        log.check(viewer.gestureTrailView.isHidden, "C2.1 松开右键后隐藏轨迹浮层")
        log.check(controller.session.currentFrame == 0, "C2.1 左开模式下 ← 手势执行 frame.left 翻回第 1 帧：\(controller.session.currentFrame)")

        // 右开模式下，从第 1 帧向左拖（←）执行 frame.left 应翻到下一帧（index 1）。
        controller.session.update { $0.direction = .rightToLeft }
        await settle()
        sendRightDrag(from: center, to: NSPoint(x: center.x - 80, y: center.y), in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.1 右开模式下 ← 手势执行 frame.left 翻到下一帧：\(controller.session.currentFrame)")

        controller.session.update { $0.direction = .leftToRight }
        await settle()
    }

    private func checkRightClickContextMenu(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)
        var presentedMenu: NSMenu?
        viewer.gestureRecognizer.onPresentContextMenu = { menu, _, _ in
            presentedMenu = menu
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        let beforeFrame = controller.session.currentFrame
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseUp, at: center, in: window)
        await settle()

        let titles = presentedMenu?.items.map(\.title) ?? []
        log.check(presentedMenu != nil, "C2.1 右键原地松开触发查看器右键菜单")
        log.check(
            titles.contains(String(localized: "复制")) && titles.contains(String(localized: "在 Finder 中显示")),
            "C2.1 右键菜单包含预期视图条目：\(titles.filter { !$0.isEmpty }.joined(separator: "、"))"
        )
        log.check(controller.session.currentFrame == beforeFrame, "C2.1 右键原地松开不触发翻页")
    }

    private func checkRightGestureCancelWithEscape(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let center = windowCenter(of: viewer.paged)
        controller.session.go(.index(2))
        await settle()
        let beforeFrame = controller.session.currentFrame

        var presentedMenu = false
        viewer.gestureRecognizer.onPresentContextMenu = { _, _, _ in
            presentedMenu = true
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        let dragged = NSPoint(x: center.x - 80, y: center.y)
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseDragged, at: NSPoint(x: center.x - 40, y: center.y), in: window)
        sendMouse(.rightMouseDragged, at: dragged, in: window)
        log.check(!viewer.gestureTrailView.isHidden, "C2.1 Esc 取消前轨迹浮层已显示")

        sendEscapeKey(in: window)
        log.check(viewer.gestureTrailView.isHidden, "C2.1 按 Esc 后立即隐藏轨迹浮层")

        sendMouse(.rightMouseUp, at: dragged, in: window)
        await settle()

        log.check(controller.session.currentFrame == beforeFrame, "C2.1 Esc 取消后不执行翻页命令：\(controller.session.currentFrame)")
        log.check(!presentedMenu, "C2.1 Esc 取消后不弹出右键菜单")
    }

    private func checkLeftDragPanAndDragOut(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        let paged = viewer.paged
        let center = windowCenter(of: paged)

        // 1. 放大后左键拖动平移。
        paged.zoom(by: 4.0)
        await settle()
        let beforeOffset = paged.transform.offset
        let dragID = nextEventNumber()
        sendMouse(.leftMouseDown, at: center, in: window, eventNumber: dragID)
        sendMouse(.leftMouseDragged, at: NSPoint(x: center.x + 60, y: center.y + 40), in: window, eventNumber: dragID)
        sendMouse(.leftMouseUp, at: NSPoint(x: center.x + 60, y: center.y + 40), in: window, eventNumber: dragID)
        await settle()
        log.check(paged.transform.offset != beforeOffset, "C2.1 左键拖动平移保持正常：\(beforeOffset) → \(paged.transform.offset)")
        log.check(viewer.gestureTrailView.isHidden, "C2.1 左键拖动不显示右键手势浮层")

        // 2. 适合窗口时左键拖出入口保持正常（命中页且可生成拖出粘贴板写入器）。
        paged.resetTransform()
        await settle()
        let pagePoint = paged.convert(center, from: nil)
        let hitPage = paged.page(at: pagePoint)
        let hasWriter: Bool = if let hitPage, let pages = controller.session.book?.pages, pages.indices.contains(hitPage) {
            app.fileOps?.pasteboardWriter(for: pages[hitPage].entry, in: controller) != nil
        } else {
            false
        }
        log.check(hitPage != nil && hasWriter, "C2.1 适合窗口下左键拖出入口保持正常（页 \(hitPage.map(String.init) ?? "nil")）")
    }

    private func checkContinuousModeRightGestureAndMenu(_ controller: ReaderWindowController, window: NSWindow) async {
        let viewer = controller.viewer
        controller.session.update {
            $0.browseMode = .verticalStrip
            $0.direction = .leftToRight
        }
        await settle()
        controller.session.go(.index(2))
        await settle()

        let center = windowCenter(of: viewer.continuous.canvas)
        var presentedMenu: NSMenu?
        viewer.gestureRecognizer.onPresentContextMenu = { menu, _, _ in
            presentedMenu = menu
            return true
        }
        defer { viewer.gestureRecognizer.onPresentContextMenu = nil }

        // 连续模式右键原地松开弹菜单。
        sendMouse(.rightMouseDown, at: center, in: window)
        sendMouse(.rightMouseUp, at: center, in: window)
        await settle()
        log.check(presentedMenu != nil, "C2.1 连续模式下右键原地松开触发右键菜单")

        // 连续模式右键向左拖动执行 frame.left。
        let beforeFrame = controller.session.currentFrame
        sendRightDrag(from: center, to: NSPoint(x: center.x - 80, y: center.y), in: window)
        await settle()
        log.check(controller.session.currentFrame == max(0, beforeFrame - 1), "C2.1 连续模式下 ← 手势执行 frame.left：\(beforeFrame) → \(controller.session.currentFrame)")

        controller.session.update { $0.browseMode = .paged }
        await settle()
    }

    // MARK: C2.2 点击区域、滚轮分派与自定义滚轮绑定

    private func checkClickZonesAndDragExclusion(_ controller: ReaderWindowController, window: NSWindow) async {
        let paged = controller.viewer.paged
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.scaleMode = .fitWindow
        }
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()

        let leftPoint = windowPoint(in: paged, xFraction: 1.0 / 6.0, yFraction: 0.5)
        let centerPoint = windowPoint(in: paged, xFraction: 0.5, yFraction: 0.5)
        let rightPoint = windowPoint(in: paged, xFraction: 5.0 / 6.0, yFraction: 0.5)

        // 1. 从左往右：单击右区域翻下一帧，单击左区域翻上一帧。
        sendLeftClick(at: rightPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 左开模式单击右区域翻到下一帧：\(controller.session.currentFrame)")

        sendLeftClick(at: leftPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 左开模式单击左区域翻到上一帧：\(controller.session.currentFrame)")

        // 2. 单击中间区域（默认未绑定）无动作。
        sendLeftClick(at: centerPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 单击中间区域（默认未绑定）不翻页：\(controller.session.currentFrame)")

        // 3. 从右往左：单击左区域翻下一帧，单击右区域翻上一帧。
        controller.session.update { $0.direction = .rightToLeft }
        await settle()
        sendLeftClick(at: leftPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 右开模式单击左区域翻到下一帧：\(controller.session.currentFrame)")

        sendLeftClick(at: rightPoint, in: window)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 右开模式单击右区域翻到上一帧：\(controller.session.currentFrame)")

        controller.session.update { $0.direction = .leftToRight }
        await settle()

        // 4. 放大后在右区域拖动平移（位移 >= 4 pt），应平移且不触发点击区域翻页。
        paged.zoom(by: 4.0)
        await settle()
        let beforeFrame = controller.session.currentFrame
        let beforeOffset = paged.transform.offset
        let dragID = nextEventNumber()
        let dragEnd = NSPoint(x: rightPoint.x - 24, y: rightPoint.y + 12)
        sendMouse(.leftMouseDown, at: rightPoint, in: window, eventNumber: dragID)
        sendMouse(.leftMouseDragged, at: dragEnd, in: window, eventNumber: dragID)
        sendMouse(.leftMouseUp, at: dragEnd, in: window, eventNumber: dragID)
        await settle()
        log.check(paged.transform.offset != beforeOffset, "C2.2 放大后拖动平移生效：\(beforeOffset) → \(paged.transform.offset)")
        log.check(controller.session.currentFrame == beforeFrame, "C2.2 位移 >= 4 pt 的拖动平移不触发点击区域：\(controller.session.currentFrame)")

        paged.resetTransform()
        await settle()
    }

    private func checkWheelDispatchAndCustomBinding(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let paged = controller.viewer.paged
        let center = windowCenter(of: paged)
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.direction = .leftToRight
            $0.scaleMode = .fitWindow
        }
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()

        // 1. ⌘ + 滚轮触发缩放，且不翻页。
        let zoomBefore = paged.transform.zoom
        let frameBeforeZoom = controller.session.currentFrame
        sendMouseWheel(at: center, in: window, deltaY: 4, modifiers: .maskCommand)
        await settle()
        log.check(paged.transform.zoom > zoomBefore, "C2.2 ⌘ + 滚轮向上触发放大：\(zoomBefore) → \(paged.transform.zoom)")
        log.check(controller.session.currentFrame == frameBeforeZoom, "C2.2 ⌘ + 滚轮缩放不触发翻页：\(controller.session.currentFrame)")

        let zoomedLevel = paged.transform.zoom
        sendMouseWheel(at: center, in: window, deltaY: -2, modifiers: .maskCommand)
        await settle()
        log.check(paged.transform.zoom < zoomedLevel, "C2.2 ⌘ + 滚轮向下触发缩小：\(zoomedLevel) → \(paged.transform.zoom)")

        // 2. 临时写入 keybindings.json 绑定 ⌥ + 滚轮到命令，验证执行后恢复。
        let url = app.supportDirectory.appending(path: "keybindings.json")
        let previousData = try? Data(contentsOf: url)
        let optionWheel = WheelBinding(
            device: .mouse,
            modifiers: .option,
            action: .commands(up: .framePrevious, down: .frameNext)
        )
        let customFile = KeyBindingsFile(bindings: [], wheel: [optionWheel])
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(customFile))
        let encoded = try JSONSerialization.data(withJSONObject: ["version": 1, "value": value])

        do {
            try encoded.write(to: url, options: .atomic)
            for _ in 0..<100 where app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) != optionWheel.action {
                try? await Task.sleep(for: .milliseconds(20))
            }
            log.check(
                app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) == optionWheel.action,
                "C2.2 临时写入 keybindings.json 生效 ⌥ + 滚轮命令绑定"
            )

            // 在放大状态下发 ⌥ + 滚轮向下，确认直接执行 frame.next 而非平移。
            paged.zoom(by: 3.0)
            await settle()
            let frameBeforeOption = controller.session.currentFrame
            sendMouseWheel(at: center, in: window, deltaY: -1, modifiers: .maskAlternate)
            await settle()
            log.check(
                controller.session.currentFrame == frameBeforeOption + 1,
                "C2.2 ⌥ + 滚轮向下执行自定义命令 frame.next：\(frameBeforeOption) → \(controller.session.currentFrame)"
            )

            sendMouseWheel(at: center, in: window, deltaY: 1, modifiers: .maskAlternate)
            await settle()
            log.check(
                controller.session.currentFrame == frameBeforeOption,
                "C2.2 ⌥ + 滚轮向上执行自定义命令 frame.previous：\(controller.session.currentFrame)"
            )
        } catch {
            restoreKeyBindings(at: url, previousData: previousData)
            throw error
        }

        restoreKeyBindings(at: url, previousData: previousData)
        for _ in 0..<100 where app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) != .standard {
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.check(
            app.catalog.inputBindings.wheelAction(device: .mouse, modifiers: .option) == .standard,
            "C2.2 恢复 keybindings.json 后 ⌥ + 滚轮回到默认行为"
        )

        // 3. 未改绑定时滚轮翻页与平移和改动前一致。
        paged.resetTransform()
        controller.session.go(.index(1))
        await settle()
        sendMouseWheel(at: center, in: window, deltaY: -1)
        await settle()
        log.check(controller.session.currentFrame == 2, "C2.2 未改绑定适合窗口下鼠标滚轮向下翻到下一帧：\(controller.session.currentFrame)")

        sendMouseWheel(at: center, in: window, deltaY: 1)
        await settle()
        log.check(controller.session.currentFrame == 1, "C2.2 未改绑定适合窗口下鼠标滚轮向上翻到上一帧：\(controller.session.currentFrame)")

        paged.zoom(by: 4.0)
        await settle()
        let panFrameBefore = controller.session.currentFrame
        let panOffsetBefore = paged.transform.offset
        sendMouseWheel(at: center, in: window, deltaY: -2)
        await settle()
        log.check(paged.transform.offset != panOffsetBefore, "C2.2 未改绑定放大后鼠标滚轮平移：\(panOffsetBefore) → \(paged.transform.offset)")
        log.check(controller.session.currentFrame == panFrameBefore, "C2.2 未改绑定放大后鼠标滚轮平移不翻页：\(controller.session.currentFrame)")

        paged.resetTransform()
        await settle()
    }

    private func restoreKeyBindings(at url: URL, previousData: Data?) {
        if let previousData {
            try? previousData.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: 夹具与事件工具

    private func makeBook(count: Int) throws -> URL {
        let directory = temporary.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            let hue = CGFloat(index) / CGFloat(max(count, 1))
            let url = directory.appending(path: String(format: "p%02d.png", index + 1))
            guard let context = CGContext(
                data: nil, width: 800, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.9, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
            guard let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url)
        }
        return directory
    }

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        for _ in 0..<300 {
            if let book = controller.session.book, book.location.name == url.lastPathComponent,
               book.pages.count == expectedCount, book.pages.allSatisfy({ $0.metadata != nil }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await settle()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func windowCenter(of view: NSView) -> NSPoint {
        windowPoint(in: view, xFraction: 0.5, yFraction: 0.5)
    }

    private func windowPoint(in view: NSView, xFraction: CGFloat, yFraction: CGFloat) -> NSPoint {
        let local = NSPoint(
            x: view.bounds.minX + view.bounds.width * xFraction,
            y: view.bounds.minY + view.bounds.height * yFraction
        )
        return view.convert(local, to: nil)
    }

    private func sendLeftClick(at point: NSPoint, in window: NSWindow) {
        let number = nextEventNumber()
        sendMouse(.leftMouseDown, at: point, in: window, eventNumber: number)
        sendMouse(.leftMouseUp, at: point, in: window, eventNumber: number)
    }

    private static let setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation").map {
            unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self)
        }
    }()

    private func sendMouseWheel(
        at point: NSPoint,
        in window: NSWindow,
        deltaY: Int32,
        deltaX: Int32 = 0,
        modifiers: CGEventFlags = []
    ) {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        cg.flags = modifiers
        cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let screen = window.convertPoint(toScreen: point)
        let height = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        if let field = CGEventField(rawValue: 51) {
            cg.setIntegerValueField(field, value: Int64(window.windowNumber))
        }
        Self.setWindowLocation?(cg, CGPoint(x: point.x, y: window.frame.height - point.y))
        if let event = NSEvent(cgEvent: cg) {
            NSApp.sendEvent(event)
        }
    }

    private func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, eventNumber customNumber: Int? = nil) {
        let number = customNumber ?? nextEventNumber()
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: number,
            clickCount: 1,
            pressure: isUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
    }

    private func sendRightDrag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int = 4) {
        let number = nextEventNumber()
        sendMouse(.rightMouseDown, at: start, in: window, eventNumber: number)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            sendMouse(.rightMouseDragged, at: point, in: window, eventNumber: number)
        }
        sendMouse(.rightMouseUp, at: end, in: window, eventNumber: number)
    }

    private func sendEscapeKey(in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        if NSApp.isActive {
            NSApp.sendEvent(event)
        } else {
            window.sendEvent(event)
        }
    }
}
#endif
