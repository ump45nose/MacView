#if DEBUG
import AppKit
import MVCommands
import MVFoundation
import MVReading
import MVSettings

/// 查看器输入与自定义自检（`-MVInputSelfTest viewer`）。
///
/// 覆盖 C2.1：右键手势（← 执行 frame.left）、右键原地松开弹出右键菜单、右键拖动中 Esc 取消、左键拖动平移与拖出保持正常。
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
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
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
