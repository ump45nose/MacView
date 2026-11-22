#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import MVFoundation
import MVIO
import MVLayout
import MVMedia
import MVPipeline
import MVReading
import MVServices
import MVSettings

/// 视频悬停预览自检（`-MVVideoPreviewSelfTest gallery|viewer|settings`）。
@MainActor
final class VideoPreviewSelfTest {
    static let launchKey = "MVVideoPreviewSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary = TestPresentation.scratchDirectory("video-preview")
    private var eventNumber = 1

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return }
        let test = VideoPreviewSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) { self.app = app; self.mode = mode }

    private func run() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        TestPresentation.activateIfAllowed()
        if TestPresentation.activationAllowed {
            for _ in 0..<30 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard app.services != nil, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "视频预览自检需要真实服务与主窗口")
            exit(log.summarize())
        }
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.acceptsMouseMovedEvents = true
        TestPresentation.place(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        switch mode {
        case "gallery": await runGallerySuite(controller: controller, window: window)
        case "cache-restart-verify": await runCacheRestartVerify(controller: controller, window: window)
        case "viewer": await runViewerSuite(controller: controller, window: window)
        case "settings": await runSettingsSuite()
        default: log.check(false, "未知模式：\(mode)")
        }
        try? FileManager.default.removeItem(at: temporary)
        await app.services?.shutdown()
        exit(log.summarize())
    }

    // MARK: - gallery（C2.1–C2.8）

    private func runGallerySuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            let book = try prepareBook()
            await openBook(controller, url: book, expectedCount: 4)
            controller.session.update { $0.browseMode = .waterfall }
            await settle(200)
            guard let pageList = controller.dock.panels[DockPanels.pageList] as? PageListPanel,
                  let listView = pageList.collection else {
                log.check(false, "找不到页面列表面板"); return
            }

            // C2.1：页面列表网格/瀑布流 + 主区瀑布流
            pageList.setStyle(.grid); pageList.setItemExtent(130); await settle(250)
            scrollToTop(listView.canvas)
            _ = await waitUntil(timeoutMs: 2000) { listView.canvas.frame(of: 0) != nil }
            await settle(150)
            await verifyHoverScrub(in: listView.canvas, window: window, videoIndex: 0, tag: "C2.1 页面列表网格", snapshotPrefix: "gallery-hover")

            pageList.setStyle(.masonry); await settle(150)
            await verifyHoverScrub(in: listView.canvas, window: window, videoIndex: 0, tag: "C2.1 页面列表瀑布流")

            let mainCanvas = controller.viewer.continuous.canvas
            await verifyHoverScrub(in: mainCanvas, window: window, videoIndex: 0, tag: "C2.1 主区瀑布流")

            // C2.1b：悬停期间重取封面不覆盖预览帧；移出恢复封面
            await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.5)
            _ = await waitUntil(timeoutMs: 3000) { mainCanvas.hoverPreviewSnapshot?.frameIndex != nil }
            let beforeReload = mainCanvas.hoverPreviewSnapshot?.frameIndex
            mainCanvas.reloadCoverForTesting(at: 0); await settle(250)
            let duringReload = mainCanvas.hoverPreviewSnapshot?.frameIndex
            moveOutside(canvas: mainCanvas, window: window); await settle(120)
            log.check(beforeReload != nil && duringReload == beforeReload && mainCanvas.hoverPreviewSnapshot == nil, "C2.1b 悬停重取封面不覆盖预览帧且移出恢复")

            // C2.2：移出恢复 + 切到相邻视频项取消旧请求
            await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.5)
            _ = await waitUntil(timeoutMs: 2500) { mainCanvas.hoverPreviewSnapshot?.loadedFrameCount == VideoPreview.frameCount }
            let hadBadge = mainCanvas.hoverPreviewSnapshot?.badgeText != nil
            await hover(canvas: mainCanvas, window: window, index: 1, fraction: 0.5)
            let switched = await waitUntil(timeoutMs: 2500) { mainCanvas.hoverPreviewSnapshot?.index == 1 && mainCanvas.hoverPreviewSnapshot?.isActive == true }
            moveOutside(canvas: mainCanvas, window: window); await settle(80)
            log.check(hadBadge && switched && mainCanvas.hoverPreviewSnapshot == nil, "C2.2 切到相邻视频项激活新请求且移出恢复")

            // C2.3：二次悬停 ≤ 100 ms；C2.5：切帧主线程单次 ≤ 2 ms
            await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.5)
            _ = await waitUntil(timeoutMs: 1500) { mainCanvas.hoverPreviewSnapshot?.isActive == true }
            let t0 = ContinuousClock.now
            let full = await waitUntil(timeoutMs: 1000) { mainCanvas.hoverPreviewSnapshot?.loadedFrameCount == VideoPreview.frameCount }
            let ms = (ContinuousClock.now - t0).milliseconds
            log.check(full && ms <= 100, "C2.3 二次悬停 20 帧就绪 \(String(format: "%.1f", ms)) ms（≤100 ms）")

            var maxUpdateMs = 0.0
            for f in [0.1, 0.3, 0.5, 0.7, 0.9] {
                await move(canvas: mainCanvas, window: window, index: 0, fraction: f)
                maxUpdateMs = max(maxUpdateMs, mainCanvas.hoverPreviewSnapshot?.lastUpdateMilliseconds ?? 99)
            }
            moveOutside(canvas: mainCanvas, window: window)
            log.check(maxUpdateMs <= 2.0, "C2.5 悬停切帧主线程最大耗时 \(String(format: "%.3f", maxUpdateMs)) ms（≤2 ms）")

            // C2.1：主区纵条与横条
            for (mode, tag) in [(BrowseMode.verticalStrip, "C2.1 主区纵条"), (.horizontalStrip, "C2.1 主区横条")] {
                controller.session.update { $0.browseMode = mode }; await settle(200)
                await verifyHoverScrub(in: mainCanvas, window: window, videoIndex: 0, tag: tag)
            }
            controller.session.update { $0.browseMode = .waterfall }; await settle(200)

            await verifyGenerationIsolationAndNoMetadata(window: window)
            await verifyExclusions(controller: controller, pageList: pageList, listView: listView, mainCanvas: mainCanvas, window: window)

            // C2.5b：主区滤镜容器与页面列表无滤镜
            controller.session.update { $0.effects = EffectChain(effects: [.colorAdjust(ColorAdjust(brightness: 0.25))]) }
            await settle(150)
            log.check(mainCanvas.effectFilterCount > 0 && listView.canvas.effectFilterCount == 0, "C2.5b 主区滤镜数=\(mainCanvas.effectFilterCount)，页面列表=\(listView.canvas.effectFilterCount)")
            controller.session.update { $0.effects = .empty }; await settle(100)

            await verifyClickToPlay(controller: controller, pageList: pageList, listView: listView, mainCanvas: mainCanvas, window: window)
            await runCacheRestartSubprocess(book: book)
        } catch {
            log.check(false, "gallery 自检异常：\(error)")
        }
    }

    private func verifyHoverScrub(in canvas: CanvasView, window: NSWindow, videoIndex: Int, tag: String, snapshotPrefix: String? = nil) async {
        await hover(canvas: canvas, window: window, index: videoIndex, fraction: 0.05)
        let loaded = await waitUntil(timeoutMs: 4000) {
            canvas.hoverPreviewSnapshot?.isActive == true && (canvas.hoverPreviewSnapshot?.loadedFrameCount ?? 0) == VideoPreview.frameCount
        }
        guard loaded, let dur = canvas.hoverPreviewSnapshot?.duration, dur > 0 else {
            log.check(false, "\(tag) 未能取齐 20 帧"); moveOutside(canvas: canvas, window: window); return
        }
        var ok = true
        for (fraction, expectedRange) in [(0.05, 0...2), (0.50, 9...11), (0.95, 18...19)] {
            await move(canvas: canvas, window: window, index: videoIndex, fraction: fraction)
            guard let snap = canvas.hoverPreviewSnapshot,
                  let idx = snap.frameIndex, expectedRange.contains(idx),
                  let prog = snap.scrubProgress, abs(prog - fraction) <= 0.06,
                  snap.badgeText == Self.formatTime(fraction * dur, rounded: true) else {
                ok = false; break
            }
            if let prefix = snapshotPrefix, abs(fraction - 0.50) < 0.01 {
                await snapshotLightDark(window, prefix: prefix)
            }
        }
        moveOutside(canvas: canvas, window: window); await settle(80)
        log.check(ok && canvas.hoverPreviewSnapshot == nil, "\(tag) 左中右悬停切帧/角标/进度线一致且移出恢复")
    }

    private func verifyGenerationIsolationAndNoMetadata(window: NSWindow) async {
        let delayed = DelayedMockPipeline()
        let loader = VideoPreviewLoader(pipeline: delayed)
        let idA = Self.dummyIdentity("a.mp4"), idB = Self.dummyIdentity("b.mp4")
        var callbacks = 0
        loader.onFrame = { callbacks += 1 }
        loader.start(idA); await settle(20); loader.start(idB); await settle(20); loader.start(idA); await settle(200)
        log.check(loader.identity == idA && loader.duration == 10.0 && callbacks >= 1, "C2.3b 代次隔离：旧 A 延迟帧被丢弃")
        loader.stop()

        guard let settings = app.services?.settings else { return }
        let probe = CanvasView(pipeline: delayed, settings: settings, kind: .grid, imageSource: .thumbnail, itemExtent: 140)
        probe.frame = CGRect(x: 40, y: 40, width: 320, height: 220)
        window.contentView?.addSubview(probe)
        probe.setItems([CanvasItem(identity: idA, aspectRatio: 16.0 / 9.0, badge: nil, label: nil, isVideo: true)])
        probe.layoutSubtreeIfNeeded(); await settle(80)
        await hover(canvas: probe, window: window, index: 0, fraction: 0.5)
        let arrived = await waitUntil(timeoutMs: 1500) { probe.hoverPreviewSnapshot?.duration == 10.0 && probe.hoverPreviewSnapshot?.badgeText == "0:05" }
        log.check(arrived, "C2.3c 元数据未到视频项首帧到达后角标显示目标时间")
        probe.removeFromSuperview()
    }

    private func verifyExclusions(controller: ReaderWindowController, pageList: PageListPanel, listView: CollectionView, mainCanvas: CanvasView, window: NSWindow) async {
        var styleSilent = true
        for style in [CollectionStyle.list, .table] {
            pageList.setStyle(style); await settle(100)
            warpAndMove(window: window, locationInWindow: pointInWindow(of: listView, x: 0.5, y: 0.2))
            await settle(220)
            if listView.canvas.hoverPreviewSnapshot != nil { styleSilent = false }
        }
        pageList.setStyle(.grid); await settle(100)

        await hover(canvas: mainCanvas, window: window, index: 3, fraction: 0.5); await settle(220)
        let imageSilent = mainCanvas.hoverPreviewSnapshot == nil

        controller.session.update { $0.browseMode = .verticalStrip }; await settle(150)
        await SyntheticScroll.during {
            let center = self.pointInWindow(of: mainCanvas, x: 0.5, y: 0.5)
            for ev in SyntheticScroll.events(at: center, in: window, dx: 0, dy: -120, steps: 4) { NSApp.sendEvent(ev) }
            if mainCanvas.contentView.bounds.origin.y == 0 {
                mainCanvas.contentView.scroll(to: NSPoint(x: 0, y: 80))
                mainCanvas.reflectScrolledClipView(mainCanvas.contentView)
            }
            if let doc = mainCanvas.documentView, let rect = mainCanvas.frame(of: 0) {
                if window.firstResponder !== doc { window.makeFirstResponder(doc) }
                self.warpAndMove(window: window, locationInWindow: doc.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
            }
        }
        let scrollSilent = mainCanvas.hoverPreviewSnapshot == nil
        controller.session.update { $0.browseMode = .waterfall }; await settle(150)

        try? await app.services?.settings.updateGlobal { $0.videoHoverPreview = false }; await settle(120)
        await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.5); await settle(220)
        let offSilent = mainCanvas.hoverPreviewSnapshot == nil
        try? await app.services?.settings.updateGlobal { $0.videoHoverPreview = true }; await settle(120)
        await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.5)
        let onRestored = await waitUntil(timeoutMs: 2000) { mainCanvas.hoverPreviewSnapshot?.isActive == true }
        moveOutside(canvas: mainCanvas, window: window)
        log.check(styleSilent && imageSilent && scrollSilent && offSilent && onRestored, "C2.4 列表/详情、非视频、滚动中、关开关均不触发且开开关恢复")
    }

    private func verifyClickToPlay(controller: ReaderWindowController, pageList: PageListPanel, listView: CollectionView, mainCanvas: CanvasView, window: NSWindow) async {
        // C2.6：主区瀑布流 60% 点击起播
        controller.session.update { $0.browseMode = .waterfall }; await settle(150)
        let (exp26, t26) = await hoverClickPlay(canvas: mainCanvas, window: window, index: 0, fraction: 0.6, paged: controller.viewer.paged)
        log.check(controller.session.settings.browseMode == .paged && t26.map { abs($0 - exp26) <= 0.5 } == true, "C2.6 主区瀑布流 60% 点击起播(\(t26.map { String(format: "%.2f", $0) } ?? "nil")s)")

        // C2.6b：点击 A 后在起播前切到 B → B 从头播
        controller.session.update { $0.browseMode = .waterfall }; await settle(150)
        await hover(canvas: mainCanvas, window: window, index: 0, fraction: 0.6)
        _ = await waitUntil(timeoutMs: 2500) { mainCanvas.previewTime(at: 0) != nil }
        click(canvas: mainCanvas, window: window, index: 0, fraction: 0.6)
        controller.session.go(.index(1))
        let t26b = await waitForVideoPlaybackTime(in: controller.viewer.paged)
        log.check(controller.session.currentPage == 1 && t26b.map { $0 <= 0.6 } == true, "C2.6b 切到视频 B 丢弃 A 起播时间，B 从头播(\(t26b.map { String(format: "%.2f", $0) } ?? "nil")s)")

        // C2.7：页面列表跳页起播 + 同页直接跳转
        controller.session.go(.index(3)); await settle(150)
        pageList.setStyle(.grid); await settle(150); scrollToTop(listView.canvas); await settle(100)
        let (exp27a, t27a) = await hoverClickPlay(canvas: listView.canvas, window: window, index: 0, fraction: 0.6, paged: controller.viewer.paged)

        scrollToTop(listView.canvas); await settle(100)
        await hover(canvas: listView.canvas, window: window, index: 0, fraction: 0.2)
        _ = await waitUntil(timeoutMs: 2500) { listView.canvas.previewTime(at: 0) != nil }
        let exp27b = listView.canvas.previewTime(at: 0) ?? 0.4
        click(canvas: listView.canvas, window: window, index: 0, fraction: 0.2); await settle(250)
        let t27b = firstVideoView(in: controller.viewer.paged)?.player?.currentTime().seconds
        log.check(t27a.map { abs($0 - exp27a) <= 0.5 } == true && t27b.map { abs($0 - exp27b) <= 0.6 } == true, "C2.7 页面列表跳页起播与同页跳转")

        // C2.8：不经悬停直接点击、非悬停切换均从头播
        controller.session.update { $0.browseMode = .waterfall }; await settle(150)
        moveOutside(canvas: mainCanvas, window: window); await settle(80)
        click(canvas: mainCanvas, window: window, index: 1, fraction: 0.7)
        let t28a = await waitForVideoPlaybackTime(in: controller.viewer.paged)
        controller.session.go(.index(0))
        let t28b = await waitForVideoPlaybackTime(in: controller.viewer.paged)
        log.check(t28a.map { $0 <= 0.6 } == true && t28b.map { $0 <= 0.6 } == true, "C2.8 直接点击与非悬停切换均从头播")
    }

    private func hoverClickPlay(canvas: CanvasView, window: NSWindow, index: Int, fraction: Double, paged: NSView) async -> (Double, Double?) {
        await hover(canvas: canvas, window: window, index: index, fraction: fraction)
        _ = await waitUntil(timeoutMs: 2500) { canvas.previewTime(at: index) != nil }
        let expected = canvas.previewTime(at: index) ?? (fraction * 2.0)
        click(canvas: canvas, window: window, index: index, fraction: fraction)
        return (expected, await waitForVideoPlaybackTime(in: paged))
    }

    private func runCacheRestartSubprocess(book: URL) async {
        guard let executable = Bundle.main.executableURL else { log.check(false, "C2.3 找不到可执行文件"); return }
        let subSupport = app.supportDirectory.appending(path: "sub-restart", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: subSupport, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-MVVideoPreviewSelfTest", "cache-restart-verify", "-MVSelfTestFixtures", book.path,
            "-MVSupportDirectory", subSupport.path, "-MVCacheDirectory", app.cacheDirectory.path,
            "-MVLayoutFile", subSupport.appending(path: "layout.json").path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { log.check(false, "C2.3 启动子进程失败：\(error)"); return }
        let (status, output): (Int32, String) = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""))
            }
        }
        if !output.isEmpty { print(output, terminator: output.hasSuffix("\n") ? "" : "\n") }
        log.check(status == 0, "C2.3 同缓存目录子进程重启命中磁盘缓存 ≤ 300 ms（exit=\(status)）")
    }

    private func runCacheRestartVerify(controller: ReaderWindowController, window: NSWindow) async {
        guard let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") else { log.check(false, "缺少夹具参数"); return }
        await openBook(controller, url: URL(fileURLWithPath: path), expectedCount: 4)
        controller.session.update { $0.browseMode = .waterfall }; await settle(200)
        let canvas = controller.viewer.continuous.canvas
        await hover(canvas: canvas, window: window, index: 0, fraction: 0.5)
        _ = await waitUntil(timeoutMs: 1500) { canvas.hoverPreviewSnapshot?.isActive == true }
        let t0 = ContinuousClock.now
        let ok = await waitUntil(timeoutMs: 2000) { canvas.hoverPreviewSnapshot?.loadedFrameCount == VideoPreview.frameCount }
        let ms = (ContinuousClock.now - t0).milliseconds
        log.check(ok && ms <= 300, "C2.3 子进程磁盘缓存 20 帧就绪 \(String(format: "%.1f", ms)) ms（≤300 ms）")
    }

    // MARK: - viewer（C2.9–C2.11b）

    private func runViewerSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            let book = try prepareBook()
            controller.dock.perform { $0.togglingAllAreas() }
            await openBook(controller, url: book, expectedCount: 4)
            controller.session.update { $0.browseMode = .paged; $0.pageMode = .single }
            controller.session.go(.index(0))
            guard let videoView = await waitForVideoView(in: controller.viewer.paged) else { log.check(false, "未出现 VideoPageView"); return }
            _ = await waitUntil(timeoutMs: 4000) { let d = videoView.player?.currentItem?.duration.seconds ?? 0; return d.isFinite && d > 0 }
            if let slider = firstSubview(of: NSSlider.self, in: videoView) { window.makeFirstResponder(slider) }
            await settle(150)

            let track = videoView.sliderTrackFrame
            let sliderPoint: (CGFloat) -> NSPoint = { videoView.convert(NSPoint(x: track.minX + track.width * $0, y: track.midY), to: nil) }
            warpAndMove(window: window, locationInWindow: sliderPoint(0.25))
            let appeared = await waitUntil(timeoutMs: 3500) {
                let s = videoView.scrubPreviewSnapshot; return s.isVisible && s.hasImage && s.loadedFrameCount == VideoPreview.frameCount
            }
            let s25 = videoView.scrubPreviewSnapshot
            warpAndMove(window: window, locationInWindow: sliderPoint(0.75)); await settle(80)
            let s75 = videoView.scrubPreviewSnapshot
            let dur = videoView.player?.currentItem?.duration.seconds ?? 2.0
            let followOK = appeared && (4...6).contains(s25.frameIndex ?? -1) && s25.timeText == Self.formatTime(0.25 * dur, rounded: false)
                && s75.frame.midX > s25.frame.midX && (14...16).contains(s75.frameIndex ?? -1) && s75.timeText == Self.formatTime(0.75 * dur, rounded: false)

            warpAndMove(window: window, locationInWindow: sliderPoint(0.01)); await settle(60)
            let leftSnap = videoView.scrubPreviewSnapshot
            warpAndMove(window: window, locationInWindow: sliderPoint(0.99)); await settle(60)
            let rightSnap = videoView.scrubPreviewSnapshot
            warpAndMove(window: window, locationInWindow: sliderPoint(0.5)); await settle(80)
            await snapshotLightDark(window, prefix: "viewer-scrub")
            let boundsOK = leftSnap.isVisible && leftSnap.frame.width > 0 && leftSnap.frame.minX >= 0
                && rightSnap.isVisible && rightSnap.frame.width > 0 && rightSnap.frame.maxX <= videoView.bounds.width
            log.check(boundsOK, "C2.10 两端浮层可见且不超出视频页")

            warpAndMove(window: window, locationInWindow: videoView.convert(NSPoint(x: 20, y: 20), to: nil)); await settle(80)
            let afterExit = videoView.scrubPreviewSnapshot
            log.check(followOK && !afterExit.isVisible, "C2.9 进度条 25%/75% 浮层帧与时间准确、跟随且移出消失")

            let counting = DelayedMockPipeline()
            let probeLoader = VideoPreviewLoader(pipeline: counting)
            probeLoader.start(Self.dummyIdentity("cancel-test.mp4")); await settle(30); probeLoader.stop(); await settle(120)
            log.check(!afterExit.isLoaderActive && counting.cancelledCount >= 1, "C2.11b 移出进度条后加载器停止且管线请求取消")

            try? await app.services?.settings.updateGlobal { $0.videoHoverPreview = false }; await settle(120)
            warpAndMove(window: window, locationInWindow: sliderPoint(0.5)); await settle(120)
            let hiddenWhenOff = !videoView.scrubPreviewSnapshot.isVisible
            try? await app.services?.settings.updateGlobal { $0.videoHoverPreview = true }
            log.check(hiddenWhenOff, "C2.11 关闭开关后进度条悬停浮层不出现")
        } catch {
            log.check(false, "viewer 自检异常：\(error)")
        }
    }

    // MARK: - settings

    private func runSettingsSuite() async {
        guard let settings = app.openSettings(page: .browse), let settingsWindow = settings.window else {
            log.check(false, "无法打开设置窗口"); return
        }
        await settle(250)
        let model = settings.state.model
        let defaultOn = model.global.videoHoverPreview
        let binding = global(model, \.videoHoverPreview)
        let file = app.supportDirectory.appending(path: "settings.json")
        binding.wrappedValue = false
        let wroteFalse = await waitUntil(timeoutMs: 3000) { (try? String(contentsOf: file, encoding: .utf8))?.contains("\"videoHoverPreview\" : false") == true }
        let reloaded = SettingsWindowController(store: app.services!.settings, sources: app.services!.sources, supportDirectory: app.supportDirectory, cacheDirectory: app.cacheDirectory)
        await reloaded.state.model.loadAll()
        let persistedFalse = !reloaded.state.model.global.videoHoverPreview
        binding.wrappedValue = true
        let wroteTrue = await waitUntil(timeoutMs: 3000) { (try? String(contentsOf: file, encoding: .utf8))?.contains("\"videoHoverPreview\" : true") == true }
        log.check(defaultOn && wroteFalse && persistedFalse && wroteTrue, "settings 浏览页「视频」开关默认开且读写 settings.json 一致")

        let avail = max(260, settingsWindow.frame.width - 140)
        let titleFont = NSFont.systemFont(ofSize: 13), detailFont = NSFont.systemFont(ofSize: 11)
        let lineH = ceil(("Ag" as NSString).size(withAttributes: [.font: detailFont]).height)
        let pairs = [
            ("zh", "悬停预览视频画面", "在画廊里的视频上左右移动鼠标、或停在播放进度条上时显示对应位置的画面。第一次预览会读取视频的多个位置，预览帧存在缩略图缓存里。"),
            ("en", "Hover to preview video", "Move the pointer across a video in the gallery or hover over the playback slider to preview frames. The first preview reads multiple positions and stores them in the thumbnail cache."),
        ]
        let noTruncation = pairs.allSatisfy { lang, title, detail in
            let titleOK = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) <= avail
            let wordsOK = lang != "en" || detail.split(separator: " ").allSatisfy { ceil((String($0) as NSString).size(withAttributes: [.font: detailFont]).width) <= avail }
            let h = (detail as NSString).boundingRect(with: NSSize(width: avail, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: detailFont]).height
            return titleOK && wordsOK && h <= lineH * 4 + 4
        }
        log.check(noTruncation, "settings 中英文「视频」节在设置窗口宽度(\(Int(settingsWindow.frame.width)) pt)下无截断")
        settingsWindow.setContentSize(NSSize(width: settingsWindow.contentLayoutRect.width, height: 820))
        if let root = settingsWindow.contentView, let sv = firstSubview(of: NSScrollView.self, in: root), let doc = sv.documentView {
            sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - sv.contentView.bounds.height)))
            sv.reflectScrolledClipView(sv.contentView)
        }
        await settle(150)
        log.snapshot(settingsWindow, "settings-browse-video")
    }

    // MARK: - 夹具、事件与截图辅助

    private func snapshotLightDark(_ window: NSWindow, prefix: String) async {
        let saved = window.appearance
        for (name, style) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: style); await settle(80)
            log.snapshot(window, "\(prefix)-\(name)")
        }
        window.appearance = saved; await settle(60)
    }

    private func prepareBook() throws -> URL {
        let videoDir = try locateVideoFixtures()
        let book = temporary.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        for (i, name) in ["h264.mp4", "hevc.mp4", "h264.mov"].enumerated() {
            let src = videoDir.appending(path: name), dst = book.appending(path: String(format: "%02d-%@", i + 1, name))
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst); try FileManager.default.copyItem(at: src, to: dst)
            }
        }
        if let data = NSBitmapImageRep(cgImage: Self.solidImage(width: 320, height: 180, rgb: (0.2, 0.65, 0.7))).representation(using: .png, properties: [:]) {
            try data.write(to: book.appending(path: "04-still.png"))
        }
        return book
    }

    private func locateVideoFixtures() throws -> URL {
        let fm = FileManager.default
        if let arg = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") {
            let base = URL(fileURLWithPath: arg)
            for c in [base, base.appending(path: "video"), base.appending(path: "local/generated/video")] where fm.fileExists(atPath: c.appending(path: "h264.mp4").path) { return c }
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let c = dir.appending(path: "Fixtures/local/generated/video")
            if fm.fileExists(atPath: c.appending(path: "h264.mp4").path) { return c }
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appending(path: "Fixtures/local/generated/video")
        if fm.fileExists(atPath: cwd.appending(path: "h264.mp4").path) { return cwd }
        throw NSError(domain: "VideoPreviewSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 Fixtures/local/generated/video"])
    }

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        controller.open([url])
        _ = await waitUntil(timeoutMs: 8000) {
            controller.session.book?.isEnumerated == true && (controller.session.book?.pages.count ?? 0) == expectedCount
                && controller.session.book?.pages.allSatisfy { $0.metadata != nil } == true
        }
        await settle(150)
    }

    private func scrollToTop(_ canvas: CanvasView) {
        canvas.contentView.scroll(to: .zero); canvas.reflectScrolledClipView(canvas.contentView)
    }

    private func hover(canvas: CanvasView, window: NSWindow, index: Int, fraction: Double, dwellMs: Int = 200) async {
        await move(canvas: canvas, window: window, index: index, fraction: fraction)
        if dwellMs > 0 { await settle(dwellMs) }
    }

    private func move(canvas: CanvasView, window: NSWindow, index: Int, fraction: Double) async {
        guard let doc = canvas.documentView, let rect = canvas.frame(of: index) else { return }
        let targetX = rect.minX + rect.width * fraction, vis = canvas.contentView.bounds
        var scrolled = false
        if targetX < vis.minX + 4 || targetX > vis.maxX - 4 {
            let newX = min(max(targetX - vis.width / 2, 0), max(0, doc.bounds.width - vis.width))
            canvas.contentView.scroll(to: NSPoint(x: newX, y: vis.minY))
            canvas.reflectScrolledClipView(canvas.contentView)
            scrolled = true; await settle(80)
        }
        if window.firstResponder !== doc { window.makeFirstResponder(doc) }
        warpAndMove(window: window, locationInWindow: doc.convert(NSPoint(x: targetX, y: rect.midY), to: nil))
        if scrolled {
            _ = await waitUntil(timeoutMs: 2500) {
                let s = canvas.hoverPreviewSnapshot
                return s?.isActive == true && (s?.loadedFrameCount ?? 0) == VideoPreview.frameCount && s?.duration != nil
            }
        } else {
            await settle(25)
        }
    }

    private func moveOutside(canvas: CanvasView, window: NSWindow) {
        if let doc = canvas.documentView, window.firstResponder !== doc { window.makeFirstResponder(doc) }
        warpAndMove(window: window, locationInWindow: canvas.convert(NSPoint(x: -20, y: -20), to: nil))
    }

    private func click(canvas: CanvasView, window: NSWindow, index: Int, fraction: Double) {
        guard let doc = canvas.documentView, let rect = canvas.frame(of: index) else { return }
        let pt = doc.convert(NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY), to: nil)
        let n = nextEventNumber(), ts = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: pt, modifierFlags: [], timestamp: ts, windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pt, modifierFlags: [], timestamp: ts + 0.015, windowNumber: window.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 0) {
            NSApp.sendEvent(down); NSApp.sendEvent(up)
        }
    }

    private func warpAndMove(window: NSWindow, locationInWindow pt: NSPoint) {
        let s = window.convertPoint(toScreen: pt), h = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 900
        CGWarpMouseCursorPosition(CGPoint(x: s.x, y: h - s.y))
        if let ev = NSEvent.mouseEvent(with: .mouseMoved, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 0, pressure: 0) {
            NSApp.sendEvent(ev)
        }
    }

    private func pointInWindow(of view: NSView, x: CGFloat, y: CGFloat) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.minX + view.bounds.width * x, y: view.bounds.minY + view.bounds.height * y), to: nil)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let v = root as? T { return v }
        for sub in root.subviews { if let found = firstSubview(of: type, in: sub) { return found } }
        return nil
    }

    private func firstVideoView(in root: NSView) -> VideoPageView? { firstSubview(of: VideoPageView.self, in: root) }

    private func waitForVideoView(in root: NSView) async -> VideoPageView? {
        _ = await waitUntil(timeoutMs: 4000) { self.firstVideoView(in: root) != nil }
        return firstVideoView(in: root)
    }

    private func waitForVideoPlaybackTime(in root: NSView) async -> Double? {
        guard let view = await waitForVideoView(in: root) else { return nil }
        _ = await waitUntil(timeoutMs: 4000) { (view.player?.rate ?? 0) > 0 }
        return view.player?.currentTime().seconds
    }

    private func nextEventNumber() -> Int { eventNumber += 1; return eventNumber }
    private func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func waitUntil(timeoutMs: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(15)) }
        return condition()
    }

    private static func formatTime(_ seconds: Double, rounded: Bool) -> String {
        let total = max(0, Int(rounded ? seconds.rounded() : seconds.rounded(.down)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func dummyIdentity(_ name: String) -> ContentIdentity {
        ContentIdentity(location: Location(root: .local, layers: [["tmp", name]]), size: 1024, modificationNanos: 1)
    }

    nonisolated fileprivate static func solidImage(width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

/// 专用于 C2.3b、C2.3c 与 C2.11b 的轻量 Mock 管线。
private final class DelayedMockPipeline: ImagePipeline, @unchecked Sendable {
    private let lock = NSLock()
    private var aCalls = 0
    private(set) var cancelledCount = 0

    func videoPreviewFrames(for identity: ContentIdentity, priority: IOPriority) -> AsyncThrowingStream<VideoPreviewFrame, any Error> {
        let isA = identity.location.name == "a.mp4"
        let callIndex: Int = lock.withLock { guard isA else { return 0 }; aCalls += 1; return aCalls }
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                try? await Task.sleep(for: .milliseconds(isA && callIndex == 1 ? 120 : 10))
                guard !Task.isCancelled else { continuation.finish(); return }
                let img = RenderedImage(image: VideoPreviewSelfTest.solidImage(width: 64, height: 36, rgb: (0.9, 0.5, 0.2)), quality: .browse)
                continuation.yield(VideoPreviewFrame(index: 10, time: 5.0, duration: isA && callIndex == 1 ? 999.0 : 10.0, image: img))
                try? await Task.sleep(for: .milliseconds(200))
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in task.cancel(); self?.lock.withLock { self?.cancelledCount += 1 } }
        }
    }

    func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata { ImageMetadata(pixelSize: PixelSize(width: 1280, height: 720), frameCount: 1, duration: 10.0) }
    func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { RenderedImage(image: VideoPreviewSelfTest.solidImage(width: 64, height: 36, rgb: (0.5, 0.5, 0.5)), quality: .browse) }
    func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)> { AsyncStream { $0.finish() } }
    func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error> { AsyncThrowingStream { $0.finish() } }
    func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource { throw MediaError.unsupported }
    func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource { throw MediaError.unsupported }
    func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage { try await thumbnail(for: identity, maxPixel: maxPixel, priority: priority) }
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID) {}
    func cancelAll(session: SessionID) {}
}
#endif
