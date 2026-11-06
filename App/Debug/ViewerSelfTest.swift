#if DEBUG
import AppKit
import AVFoundation
import MVCommands
import MVFoundation
import MVIO
import MVMedia
import MVReading
import MVServices
import MVSettings

/// 查看器自检（`-MVViewerSelfTest YES -MVSelfTestFixtures <Fixtures目录>`，用真实服务）。
///
/// 覆盖缩放模式、拆分宽页、预解码命中、浏览方式切换、连续模式、分块、动图和视频。点击和拖动经 `NSApp.sendEvent`。
@MainActor
final class ViewerSelfTest {
    private let app: AppDelegate
    private let log = SelfTestLog()
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewViewerSelfTest-\(UUID().uuidString)")

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "MVViewerSelfTest") else { return }
        let test = ViewerSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) {
        self.app = app
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        guard let services = app.services, let controller = app.controllers.first, let window = controller.window,
              let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") else {
            log.check(false, "查看器自检需要真实服务、窗口与 -MVSelfTestFixtures")
            exit(log.summarize())
        }
        let fixtures = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            window.setContentSize(NSSize(width: 1200, height: 800))
            let book = try makeBook()
            try await checkScaleModes(controller, window: window, book: book)
            try await checkWideSplit(controller, window: window)
            await checkPrefetchHit(controller, window: window, book: book)
            try await checkBrowseModes(controller, window: window, book: book, services: services)
            try await checkTiles(controller, window: window, fixtures: fixtures)
            try await checkAnimation(controller, window: window, fixtures: fixtures)
            try await checkVideo(controller, fixtures: fixtures)
            try await checkMagnifier(controller, window: window, book: book)
        } catch {
            log.check(false, "查看器自检失败：\(error)")
        }
        try? FileManager.default.removeItem(at: temporary)
        await services.shutdown()
        exit(log.summarize())
    }

    // MARK: 夹具

    /// 40 页 1200×1800 的书，每页不同的颜色。
    private func makeBook() throws -> URL {
        let directory = temporary.appending(path: "book")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<40 {
            let hue = CGFloat(index) / 40
            try writePNG(to: directory.appending(path: String(format: "p%03d.png", index + 1)), size: CGSize(width: 1200, height: 1800)) { context in
                context.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            }
        }
        return directory
    }

    private func writePNG(to url: URL, size: CGSize, draw: (CGContext) -> Void) throws {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        draw(context)
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    // MARK: C2.3

    private func checkScaleModes(_ controller: ReaderWindowController, window: NSWindow, book: URL) async throws {
        await open(controller, book) { $0.pages.count == 40 && $0.pages.allSatisfy { $0.metadata != nil } }
        window.makeFirstResponder(controller.viewer)
        controller.session.update { $0.pageMode = .single }
        let paged = controller.viewer.paged
        let commands: [(CommandID, ScaleMode, String)] = [
            (.zoomFitWindow, .fitWindow, "fit-window"), (.zoomFitWidth, .fitWidth, "fit-width"), (.zoomFitHeight, .fitHeight, "fit-height"),
            (.zoomFill, .fill, "fill"), (.zoomOriginal, .original, "original"), (.zoomDevicePixel, .devicePixel, "device-pixel"),
        ]
        let scale = window.backingScaleFactor
        for (id, mode, name) in commands {
            controller.run(id)
            await settle()
            log.check(controller.session.settings.scaleMode == mode, "命令切到 \(mode)")
            checkLayerMatchesFit(controller, scale: scale, name)
            log.snapshot(window, "scale-\(name)")
        }
        // 2x 屏上「原始尺寸」是 1 源像素 = 1 点，「设备像素」是 1 源像素 = 1 设备像素。
        controller.run(.zoomDevicePixel)
        await settle()
        let device = paged.slots.first?.root.frame.width ?? 0
        log.check(abs(device * scale - 1200) <= 1, "设备像素 1:1 的页宽 \(device) 点 × \(scale) = 1200 像素")
        controller.run(.zoomOriginal)
        await settle()
        let original = paged.slots.first?.root.frame.width ?? 0
        log.check(abs(original - 1200) <= 1, "原始尺寸的页宽是 1200 点：\(original)")
        await dispatch(controller, .zoomFixed, ["percent": .number(50)])
        await settle()
        log.check(controller.session.settings.scaleMode == .fixed, "固定比例")
        checkLayerMatchesFit(controller, scale: scale, "fixed")
        log.check(abs((paged.slots.first?.root.frame.width ?? 0) - 600) <= 1, "固定 50% 的页宽是 600 点：\(paged.slots.first?.root.frame.width ?? 0)")
        log.snapshot(window, "scale-fixed")
        controller.run(.zoomFitWindow)
        await settle()
        // 缩放、平移走真实事件。
        controller.viewer.zoom(by: 2)
        await settle()
        log.check(abs(paged.transform.zoom - 2) < 0.001, "放大一倍：\(paged.transform.zoom)")
        log.check(paged.navigator.isHidden == false, "超出视口时显示导航图")
        let before = paged.transform.offset
        drag(paged, in: window, by: CGPoint(x: 30, y: 40))
        await settle()
        let after = paged.transform.offset
        log.check(abs(after.y - before.y - 40 * scale) < 1, "拖动平移：\(before) → \(after)")
        log.snapshot(window, "zoomed-navigator")
        controller.session.go(.nextFrame)
        await settle()
        log.check(paged.transform.zoom == 1, "翻页后缩放重置")
        controller.session.update { $0.keepZoomOnPageTurn = true }
        controller.viewer.zoom(by: 2)
        controller.session.go(.nextFrame)
        await settle()
        log.check(abs(paged.transform.zoom - 2) < 0.001, "keepZoomOnPageTurn 保留缩放")
        controller.session.update { $0.keepZoomOnPageTurn = false }
        controller.run(.zoomFitWindow)
        await settle()
    }

    private func checkLayerMatchesFit(_ controller: ReaderWindowController, scale: CGFloat, _ name: String) {
        let paged = controller.viewer.paged
        for (index, slot) in paged.slots.enumerated() {
            let size = paged.fit.pages[index].pixelSize
            let width = slot.root.frame.width * scale
            let height = slot.root.frame.height * scale
            log.check(abs(width - CGFloat(size.width)) <= 1 && abs(height - CGFloat(size.height)) <= 1, "\(name)：图层 \(width)×\(height) 与 fit \(size.width)×\(size.height) 一致")
        }
    }

    // MARK: 拆分

    private func checkWideSplit(_ controller: ReaderWindowController, window: NSWindow) async throws {
        let directory = temporary.appending(path: "wide")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(to: directory.appending(path: "wide.png"), size: CGSize(width: 2400, height: 1200)) { context in
            context.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
            context.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
            context.fill(CGRect(x: 1200, y: 0, width: 1200, height: 1200))
        }
        await open(controller, directory) { $0.pages.first?.metadata != nil }
        controller.session.update {
            $0.pageMode = .double
            $0.widePage = .split
            $0.direction = .leftToRight
        }
        await settle()
        let paged = controller.viewer.paged
        log.check(controller.session.frames.count == 2, "宽页拆成两帧：\(controller.session.frames.count)")
        guard let slot = paged.slots.first else { return log.check(false, "拆分后没有页") }
        log.check(slot.element.part == .leftHalf && slot.imageLayer.contentsRect == CGRect(x: 0, y: 0, width: 0.5, height: 1), "第一帧显示左半边")
        log.check(pixelColorIsRed(window, in: slot, of: paged), "屏幕上第一帧是左半边的红色")
        let decode = paged.fit.pages[0].decodeSize
        log.check(decode.width == decode.height * 2, "半页的 decodeSize 是整页比例：\(decode.width)×\(decode.height)")
        let width = (slot.contents as? IOSurface).map(IOSurfaceGetWidth) ?? (slot.contents.map { $0 as! CGImage }?.width ?? 0)
        log.check(width >= decode.width, "图层分辨率不低于 decodeSize：\(width) ≥ \(decode.width)")
        log.snapshot(window, "wide-split")
        controller.session.go(.nextFrame)
        await settle()
        log.check(paged.slots.first?.element.part == .rightHalf, "下一帧显示右半边")
        controller.session.update {
            $0.pageMode = .single
            $0.widePage = .asIs
        }
    }

    private func pixelColorIsRed(_ window: NSWindow, in slot: PageSlot, of view: NSView) -> Bool {
        guard let image = view.renderedImage() else { return false }
        let scale = window.backingScaleFactor
        let x = Int(slot.root.frame.midX * scale)
        let y = Int(slot.root.frame.midY * scale)
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        return bytes[offset] > 150 && bytes[offset + 2] < 100
    }

    // MARK: C2.4

    private func checkPrefetchHit(_ controller: ReaderWindowController, window: NSWindow, book: URL) async {
        await open(controller, book) { $0.pages.count == 40 && $0.pages.allSatisfy { $0.metadata != nil } }
        controller.session.go(.index(10))
        // 预取计划在后台解码前后各两帧。
        try? await Task.sleep(for: .seconds(2))
        let paged = controller.viewer.paged
        let budget = 1000.0 / Double(window.screen?.maximumFramesPerSecond ?? 120)
        var durations: [Double] = []
        for _ in 0..<5 {
            controller.session.go(.nextFrame)
            for _ in 0..<40 where paged.lastDisplay?.page != controller.session.currentPage {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let record = paged.lastDisplay, record.page == controller.session.currentPage else {
                log.check(false, "翻到第 \(controller.session.currentPage + 1) 页没有记录")
                continue
            }
            log.check(record.quality >= .exact, "翻到已预载的页，质量 \(record.quality)")
            durations.append(record.duration.milliseconds)
            try? await Task.sleep(for: .milliseconds(800))
        }
        print("INFO 翻到已预载的页：\(durations.map { String(format: "%.2f", $0) }) ms，一帧 \(String(format: "%.2f", budget)) ms")
        log.check(durations.count == 5 && durations.allSatisfy { $0 <= budget }, "翻到已预载的页不超过一帧：\(durations.max() ?? -1) ms ≤ \(budget) ms")
    }

    // MARK: C2.6、C2.7

    private func checkBrowseModes(_ controller: ReaderWindowController, window: NSWindow, book: URL, services: CoreServices) async throws {
        let session = controller.session
        session.go(.index(20))
        await settle()
        let continuous = controller.viewer.continuous
        for (id, mode, name) in [(CommandID.browseWaterfall, BrowseMode.waterfall, "waterfall"), (.browseVerticalStrip, .verticalStrip, "vertical"), (.browseHorizontalStrip, .horizontalStrip, "horizontal"), (.browsePaged, .paged, "paged")] {
            controller.run(id)
            await settle()
            log.check(session.settings.browseMode == mode, "切到 \(mode)")
            log.check(session.currentPage == 20, "\(mode) 保持当前页：\(session.currentPage + 1)")
            if mode != .paged {
                log.check(continuous.canvas.visibleRange.visible.contains(20), "\(mode) 第 21 页在可见范围：\(continuous.canvas.visibleRange.visible)")
            } else {
                log.check(controller.viewer.paged.slots.first?.element.page == 20, "分页显示第 21 页")
            }
            log.snapshot(window, "browse-\(name)")
        }
        // 连续模式滚动：滚轮事件经 NSApp.sendEvent，可见范围和书记忆跟着变。
        controller.run(.browseVerticalStrip)
        await settle()
        let canvas = continuous.canvas
        let frames = (0..<40).map { canvas.frame(of: $0) }
        window.makeFirstResponder(canvas.documentView)
        await sendScroll(in: canvas, window: window, deltaY: -3200, steps: 16)
        try? await Task.sleep(for: .milliseconds(300))
        log.check(session.currentPage > 20, "连续模式滚动后当前页前进：\(session.currentPage + 1)")
        log.check(canvas.visibleRange.visible.contains(session.currentPage), "当前页是可见范围的页：\(canvas.visibleRange.visible)")
        await session.flush()
        let memory = await services.settings.bookMemory(for: session.book!.location)
        log.check(memory?.lastPageIndex == session.currentPage, "书记忆的页随之更新：\(memory?.lastPageIndex ?? -1)")
        log.check((0..<40).map { canvas.frame(of: $0) } == frames, "图片到达前后项的位置不变")
        // 条的末尾。
        canvas.scrollTo(index: 39)
        await settle()
        log.check(canvas.frame(of: 40) != nil, "条的末尾排在最后一页之后")
        canvas.contentView.scroll(to: CGPoint(x: 0, y: canvas.documentView!.frame.height - canvas.contentView.bounds.height))
        canvas.reflectScrolledClipView(canvas.contentView)
        await settle()
        log.snapshot(window, "strip-end")
        // 右开时横向条的方向相反。
        controller.run(.browseHorizontalStrip)
        await settle()
        let leftFirst = (canvas.frame(of: 0)?.minX ?? 0) < (canvas.frame(of: 1)?.minX ?? 0)
        session.update { $0.direction = .rightToLeft }
        await settle()
        let rightFirst = (canvas.frame(of: 0)?.minX ?? 0) > (canvas.frame(of: 1)?.minX ?? 0)
        log.check(leftFirst && rightFirst, "横向条在右开时方向相反")
        session.update { $0.direction = .leftToRight }
        // 瀑布流单击进入分页。
        controller.run(.browseWaterfall)
        await settle()
        session.go(.index(5))
        await settle()
        log.check(canvas.visibleRange.visible.contains(5), "瀑布流按翻页命令滚动到第 6 页：\(canvas.visibleRange.visible)")
        canvas.scrollTo(index: 10)
        await settle()
        if let frame = canvas.frame(of: 10), let document = canvas.documentView {
            click(at: document.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), in: window)
            await settle()
            log.check(session.settings.browseMode == .paged && session.currentPage == 10, "瀑布流单击第 11 页进入分页：\(session.settings.browseMode)、\(session.currentPage + 1)")
        } else {
            log.check(false, "瀑布流第 11 页没有位置")
        }
        // 定位进度：换一本没读过尺寸的书，从第 k 页打开。第一帧画面由手测确认。
        session.update { $0.browseMode = .paged }
        await settle()
    }

    // MARK: C2.8

    private func checkTiles(_ controller: ReaderWindowController, window: NSWindow, fixtures: URL) async throws {
        await open(controller, fixtures.appending(path: "local/generated/image")) { $0.pages.first?.metadata != nil }
        let paged = controller.viewer.paged
        guard let slot = paged.slots.first else { return log.check(false, "超大图没有页") }
        controller.run(.zoomFitWindow)
        await settle()
        log.check(slot.tiled == nil, "适合窗口时不分块")
        controller.viewer.zoom(by: 30)
        try? await Task.sleep(for: .milliseconds(400))
        guard let tiled = slot.tiled else { return log.check(false, "放大后没有分块") }
        log.check(slot.upgradeTarget == nil, "放大后不请求整图")
        log.check(tiled.requestedTiles > 0 && tiled.largestRequest.width <= 4096, "请求的是块：\(tiled.requestedTiles) 块，最大 \(tiled.largestRequest)")
        let requested = tiled.requestedTiles
        // 连续平移，旧块被丢弃，在途的被取消。
        for _ in 0..<4 {
            drag(paged, in: window, by: CGPoint(x: -600, y: -300))
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(300))
        log.check(tiled.requestedTiles > requested, "移动后请求新块：\(tiled.requestedTiles)")
        log.check(tiled.discardedTiles > 0, "移出视口的块被丢弃：\(tiled.discardedTiles)，其中 \(tiled.cancelledTiles) 个在途时取消")
        let visibleCount = tiled.activeTiles
        log.check(visibleCount < tiled.requestedTiles, "只保留可见的块：\(visibleCount) / \(tiled.requestedTiles)")
        for _ in 0..<40 where slot.failure != nil { try? await Task.sleep(for: .milliseconds(50)) }
        log.check(slot.failure == nil, "分块没有错误")
        log.snapshot(window, "tiles")
        controller.run(.zoomFitWindow)
        await settle()
        log.check(slot.tiled == nil, "缩回后撤掉分块")
    }

    // MARK: C2.9

    private func checkAnimation(_ controller: ReaderWindowController, window: NSWindow, fixtures: URL) async throws {
        let directory = temporary.appending(path: "animated")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["loop.gif", "loop.png"] {
            try FileManager.default.copyItem(at: fixtures.appending(path: "animated/\(name)"), to: directory.appending(path: name))
        }
        await open(controller, directory) { $0.pages.count == 2 && $0.pages.allSatisfy { $0.metadata != nil } }
        let paged = controller.viewer.paged
        for page in 0..<2 {
            controller.session.go(.index(page))
            try? await Task.sleep(for: .milliseconds(600))
            guard let slot = paged.slots.first, let animated = slot.animated else {
                log.check(false, "第 \(page + 1) 个动图没有播放")
                continue
            }
            let name = controller.session.book?.pages[page].entry.name ?? ""
            let shown = animated.framesShown
            try? await Task.sleep(for: .seconds(1))
            log.check(animated.framesShown > shown, "\(name) 帧序号前进：\(shown) → \(animated.framesShown)，当前帧 \(animated.frameIndex)")
            log.check(animated.isPlaying, "\(name) 正在播放")
            window.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(500))
            let hidden = animated.framesShown
            log.check(!animated.isPlaying, "\(name) 窗口隐藏后暂停")
            try? await Task.sleep(for: .milliseconds(500))
            log.check(animated.framesShown == hidden, "\(name) 窗口隐藏后帧不再前进：\(hidden)")
            window.makeKeyAndOrderFront(nil)
            TestPresentation.present(window)
            try? await Task.sleep(for: .milliseconds(500))
            log.check(animated.isPlaying, "\(name) 窗口恢复后继续")
        }
        // 连续模式显示第一帧，不播放。
        controller.run(.browseVerticalStrip)
        await settle()
        log.check(paged.slots.isEmpty, "连续模式没有分页的动图")
        controller.run(.browsePaged)
        await settle()
    }

    // MARK: C2.10

    private func checkVideo(_ controller: ReaderWindowController, fixtures: URL) async throws {
        let directory = temporary.appending(path: "video")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = fixtures.appending(path: "local/generated/video/h264.mp4")
        try FileManager.default.copyItem(at: source, to: directory.appending(path: "a.mp4"))
        try FileManager.default.copyItem(at: source, to: directory.appending(path: "b.mp4"))
        await open(controller, directory) { $0.pages.count == 2 && $0.pages.allSatisfy { $0.metadata != nil } }
        await checkPlayback(controller, name: "文件夹里的 mp4")

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-0", "-q", temporary.appending(path: "video.zip").path, "a.mp4", "b.mp4"]
        try zip.run()
        zip.waitUntilExit()
        await open(controller, temporary.appending(path: "video.zip")) { $0.pages.count == 2 && $0.pages.allSatisfy { $0.metadata != nil } }
        await checkPlayback(controller, name: "压缩包内的 mp4")
    }

    private func checkPlayback(_ controller: ReaderWindowController, name: String) async {
        controller.session.go(.index(0))
        let paged = controller.viewer.paged
        for _ in 0..<100 where paged.video?.player?.currentItem?.status != .readyToPlay {
            try? await Task.sleep(for: .milliseconds(50))
        }
        weak let player = paged.video?.player
        log.check(player?.currentItem?.status == .readyToPlay, "\(name) 能播放")
        let start = player?.currentTime().seconds ?? 0
        try? await Task.sleep(for: .milliseconds(500))
        let now = player?.currentTime().seconds ?? 0
        log.check(now > start, "\(name) 播放进度前进：\(start) → \(now)")
        let identity = paged.video?.identity
        controller.session.go(.index(1))
        try? await Task.sleep(for: .milliseconds(300))
        log.check(player == nil, "\(name) 翻页后 AVPlayer 释放")
        log.check(paged.video?.identity != identity, "\(name) 播放器换到下一页")
        controller.session.go(.index(0))
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: 放大镜

    private func checkMagnifier(_ controller: ReaderWindowController, window: NSWindow, book: URL) async throws {
        await open(controller, book) { $0.pages.count == 40 && $0.pages.allSatisfy { $0.metadata != nil } }
        let paged = controller.viewer.paged
        controller.run(.magnifierToggle)
        await settle()
        log.check(paged.isMagnifying, "放大镜打开")
        let slot = paged.slots.first
        log.check(slot?.upgradeTarget?.pixelSize.width == 1200, "放大镜需要时请求原图：\(slot?.upgradeTarget?.pixelSize.width ?? 0)")
        controller.run(.magnifierToggle)
        await settle()
        log.check(!paged.isMagnifying, "放大镜关闭")
    }

    // MARK: 工具

    private func open(_ controller: ReaderWindowController, _ url: URL, until condition: (Book) -> Bool) async {
        controller.open([url])
        for _ in 0..<400 {
            if let book = controller.session.book, book.location.name == url.lastPathComponent, condition(book) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await settle()
    }

    private func dispatch(_ controller: ReaderWindowController, _ id: CommandID, _ arguments: [String: JSONValue]) async {
        try? await app.services?.commands.perform(id, arguments: arguments, context: CommandContext(session: controller.session.id, scope: .viewer))
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        NSApp.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window))
        NSApp.sendEvent(mouseEvent(.leftMouseUp, at: point, in: window))
    }

    private func drag(_ view: NSView, in window: NSWindow, by delta: CGPoint) {
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // 窗口坐标的 y 向上，视图的 y 向下。
        let end = NSPoint(x: start.x + delta.x, y: start.y - delta.y)
        NSApp.sendEvent(mouseEvent(.leftMouseDown, at: start, in: window))
        NSApp.sendEvent(mouseEvent(.leftMouseDragged, at: end, in: window))
        NSApp.sendEvent(mouseEvent(.leftMouseUp, at: end, in: window))
    }

    private func sendScroll(in view: NSView, window: NSWindow, deltaY: Double, steps: Int) async {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for event in SyntheticScroll.events(at: point, in: window, dx: 0, dy: deltaY, steps: steps) {
            NSApp.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}

#endif
