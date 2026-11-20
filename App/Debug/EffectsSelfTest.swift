#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import MVCommands
import MVFoundation
import MVIO
import MVReading
import MVServices
import MVSettings
import UniformTypeIdentifiers

/// 显示效果与渲染自检（`-MVEffectsSelfTest render`）。
///
/// 覆盖 C2.1–C2.7b：五种浏览方式与面板挂点、视频页、分页层级、六种背景与透明棋盘格、效果开关、复制与拖出调色 PNG。
@MainActor
final class EffectsSelfTest {
    static let launchKey = "MVEffectsSelfTest"

    private let app: AppDelegate
    private let mode: String
    private let log = SelfTestLog()
    private let temporary = TestPresentation.scratchDirectory("effects")

    static func runIfRequested(app: AppDelegate) {
        guard let mode = UserDefaults.standard.string(forKey: launchKey)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !mode.isEmpty else { return }
        let test = EffectsSelfTest(app: app, mode: mode)
        Task { await test.run() }
    }

    private init(app: AppDelegate, mode: String) {
        self.app = app
        self.mode = mode
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        guard app.services != nil, let controller = app.controllers.first, let window = controller.window else {
            log.check(false, "效果自检需要真实服务与主窗口")
            exit(log.summarize())
        }
        switch mode {
        case "render":
            await runRenderSuite(controller: controller, window: window)
        case "panel":
            await runPanelSuite(controller: controller, window: window)
        default:
            log.check(false, "未知的 -MVEffectsSelfTest 模式：\(mode)")
            exit(log.summarize())
        }
        try? FileManager.default.removeItem(at: temporary)
        await app.services?.shutdown()
        exit(log.summarize())
    }

    private func runRenderSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            window.setContentSize(NSSize(width: 1100, height: 760))
            let bookDir = try await makeFixtures()
            await openBook(controller, url: bookDir, expectedCount: 4)
            window.makeFirstResponder(controller.viewer)
            await settle()

            let sampleAdjust = ColorAdjust(
                brightness: 0.35,
                contrast: 0.25,
                saturation: -0.4,
                gamma: 1.4,
                temperature: 0.45,
                tint: -0.25
            )

            await checkBrowseModesAndPanels(controller, adjust: sampleAdjust)
            await checkVideoEffects(controller, adjust: sampleAdjust)
            await checkPagedHierarchy(controller, window: window)
            await checkBackgrounds(controller, window: window)
            await checkEffectsToggle(controller, window: window, adjust: sampleAdjust)
            await checkCopyAndDragExport(controller, adjust: sampleAdjust)
        } catch {
            log.check(false, "效果自检异常：\(error)")
        }
    }

    // MARK: panel 自检（C3.1–C3.8）

    private func runPanelSuite(controller: ReaderWindowController, window: NSWindow) async {
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            window.setContentSize(NSSize(width: 1160, height: 760))
            let books = try makePanelBooks()

            // 打开效果面板（⌥⌘E / panel.effects.toggle）
            controller.run(.effectsPanelToggle)
            await settle()
            guard let panel = controller.effectsPanel else {
                log.check(false, "C3.1 打开效果面板失败")
                return
            }

            // 打开书 A
            await openBook(controller, url: books.bookA, expectedCount: 2)
            window.contentView?.layoutSubtreeIfNeeded()
            await settle()

            // C3.1：用真实鼠标事件拖亮度滑块
            if let slider = panel.panelView.slider(for: .brightness) {
                let start = slider.convert(NSPoint(x: slider.bounds.minX + slider.bounds.width * 0.62, y: slider.bounds.midY), to: nil)
                let end = slider.convert(NSPoint(x: slider.bounds.minX + slider.bounds.width * 0.78, y: slider.bounds.midY), to: nil)
                sendMouseDrag(from: start, to: end, in: window)
                await settle()
            }
            let draggedBrightness = controller.session.settings.effects.colorAdjust.brightness
            let bookshelfCount = (controller.dock.panels[DockPanels.bookshelf] as? CollectionPanel)?.collection?.canvas.effectFilterCount ?? 0
            log.check(
                draggedBrightness > 0.1 && controller.viewer.effectFilterCount > 0 && bookshelfCount == 0,
                "C3.1 拖亮度滑块后 brightness=\(String(format: "%.2f", draggedBrightness))，主视图滤镜数=\(controller.viewer.effectFilterCount)，书架挂点=\(bookshelfCount)"
            )

            // C3.2：点开关关闭效果 -> 滑块变灰、值不变、滤镜清零
            let sw = panel.panelView.effectsSwitch
            let swPoint = sw.convert(NSPoint(x: sw.bounds.midX, y: sw.bounds.midY), to: nil)
            sendMouseClick(at: swPoint, in: window)
            await settle()
            let sliderDisabled = panel.panelView.slider(for: .brightness)?.isEnabled == false
            let brightnessKept = abs(controller.session.settings.effects.colorAdjust.brightness - draggedBrightness) < 0.001
            log.check(
                !controller.effectsEnabled && sliderDisabled && brightnessKept && controller.viewer.effectFilterCount == 0,
                "C3.2 关闭开关后滑块变灰(\(sliderDisabled))、值保留(\(brightnessKept))、滤镜数=\(controller.viewer.effectFilterCount)"
            )
            // 重新打开开关
            sendMouseClick(at: swPoint, in: window)
            await settle()

            // C3.3：用真实鼠标事件点棋盘格色块
            if let checker = panel.panelView.swatchView(for: .checkerboard) {
                let pt = checker.convert(NSPoint(x: checker.bounds.midX, y: checker.bounds.midY), to: nil)
                sendMouseClick(at: pt, in: window)
                await settle()
            }
            log.check(controller.session.settings.background == .checkerboard, "C3.3 点击棋盘格后 background=\(controller.session.settings.background)")

            // C3.4：只勾“效果”“背景”保存为“夜间”；打开书 B 按 ⌃1 套用
            panel.openSavePopover(from: panel.panelView.profileListView.emptySaveButton)
            await settle()
            if let pop = panel.activeSavePopover {
                pop.setName("夜间")
                pop.setGroup(.layout, checked: false)
                pop.setGroup(.scale, checked: false)
                pop.setGroup(.effects, checked: true)
                pop.setGroup(.background, checked: true)
                pop.submit()
            }
            await settle()
            let savedProfiles = await controller.services.settings.profiles()
            log.check(
                savedProfiles.count == 1 && savedProfiles[0].name == "夜间" && savedProfiles[0].groups == [.effects, .background],
                "C3.4 保存“夜间”配置成功，含组=\(savedProfiles.first?.groups.map(\.rawValue).sorted() ?? [])"
            )
            let originalID = savedProfiles.first?.id

            // 打开书 B 并设为瀑布流
            await openBook(controller, url: books.bookB, expectedCount: 2)
            controller.session.update { $0.browseMode = .waterfall }
            await settle()

            // 经命令注册表触发 displayProfile.apply (slot: 1，即 ⌃1)
            if let services = app.services {
                let ctx = CommandContext(session: controller.session.id, scope: .viewer, selection: [])
                try await services.commands.perform(.displayProfileApply, arguments: ["slot": .number(1)], context: ctx)
            }
            await settle()
            let bApplied = abs(controller.session.settings.effects.colorAdjust.brightness - draggedBrightness) < 0.001
                && controller.session.settings.background == .checkerboard
                && controller.session.settings.browseMode == .waterfall
            log.check(bApplied, "C3.4 书 B 按 ⌃1 仅效果与背景变化，浏览方式保持 waterfall")

            // 切走再重开书 B，确认书记忆生效；切回书 A 确认未受影响
            await controller.session.flush()
            await openBook(controller, url: books.bookA, expectedCount: 2)
            await settle()
            let aUnchanged = controller.session.settings.browseMode == .paged
            log.check(aUnchanged, "C3.4 书 A 浏览方式不受影响：\(controller.session.settings.browseMode)")

            await openBook(controller, url: books.bookB, expectedCount: 2)
            await settle()
            let bPersisted = abs(controller.session.settings.effects.colorAdjust.brightness - draggedBrightness) < 0.001
                && controller.session.settings.background == .checkerboard
                && controller.session.settings.browseMode == .waterfall
            log.check(bPersisted, "C3.4 重开书 B 仍保留套用的效果、背景与浏览方式")

            // C3.5：同名保存就地替换（id 与槽位不变），且效果开关关着时 ⌃1 自动打开开关
            var updatedAdjust = controller.session.settings.effects.colorAdjust
            updatedAdjust.contrast = 0.4
            controller.session.update { $0.effects = EffectChain(effects: [.colorAdjust(updatedAdjust)]) }
            await settle()

            panel.openSavePopover(from: panel.panelView.profileListView.saveButton)
            await settle()
            var showsWarning = false
            if let pop = panel.activeSavePopover {
                pop.setName("夜间")
                showsWarning = pop.isShowingDuplicateWarning
                pop.setGroup(.layout, checked: false)
                pop.setGroup(.scale, checked: false)
                pop.setGroup(.effects, checked: true)
                pop.setGroup(.background, checked: true)
                pop.submit()
            }
            await settle()
            let afterOverwrite = await controller.services.settings.profiles()
            log.check(
                showsWarning && afterOverwrite.count == 1 && afterOverwrite[0].id == originalID
                    && abs((afterOverwrite[0].settings.effects?.colorAdjust.contrast ?? 0) - 0.4) < 0.001,
                "C3.5 同名保存提示覆盖并就地替换：warning=\(showsWarning) count=\(afterOverwrite.count) sameID=\(afterOverwrite.first?.id == originalID)"
            )

            controller.setEffectsEnabled(false)
            await settle()
            if let services = app.services {
                let ctx = CommandContext(session: controller.session.id, scope: .viewer, selection: [])
                try await services.commands.perform(.displayProfileApply, arguments: ["slot": .number(1)], context: ctx)
            }
            await settle()
            log.check(controller.effectsEnabled && controller.viewer.effectFilterCount > 0, "C3.5 效果开关关着时 ⌃1 套用含效果配置自动打开开关")

            // C3.8：在正常配置列表状态下截面板图（供中英文、浅深色四组合核对）
            window.contentView?.layoutSubtreeIfNeeded()
            await settle()
            _ = log.snapshot(window, "effects-panel")

            // C3.6：套用到全局默认 -> 新书 C 打开即为新值；存为路径规则选上一层 -> 同层书 D 生效
            if let profile = afterOverwrite.first {
                panel.applyToGlobal(profile)
                await settle()
                await openBook(controller, url: books.bookC, expectedCount: 2)
                await settle()
                let cGotGlobal = abs(controller.session.settings.effects.colorAdjust.contrast - 0.4) < 0.001
                    && controller.session.settings.background == .checkerboard
                log.check(cGotGlobal, "C3.6 套用到全局默认后新书 C 自动按新值显示")

                // 恢复全局默认后再测路径规则，确保是路径规则生效而非全局默认
                try await controller.services.settings.updateGlobal {
                    $0.defaultBook.effects = .empty
                    $0.defaultBook.background = .auto
                }
                await settle()

                // 在书 C 所在的父目录建路径规则（SavePathRulePopover 默认选中上一层）
                panel.openSavePathRulePopover(for: profile, from: panel.panelView.profileListView)
                await settle()
                panel.activePathRulePopover?.submit()
                await settle()
                let rules = await controller.services.settings.pathRules()
                let hasRule = rules.contains { $0.name == "夜间" }
                await openBook(controller, url: books.bookD, expectedCount: 2)
                await settle()
                let dGotRule = abs(controller.session.settings.effects.colorAdjust.contrast - 0.4) < 0.001
                    && controller.session.settings.background == .checkerboard
                log.check(hasRule && dGotRule, "C3.6 存为路径规则（上一层）后规则列表可见(\(hasRule))且同层书 D 生效(\(dGotRule))")
            }

            // C3.7：写坏 profiles.json -> 列表保留、窗口顶部错误条出现；写回正确内容 -> 错误条消失
            let profilesURL = app.supportDirectory.appending(path: "profiles.json")
            let validData = try Data(contentsOf: profilesURL)
            try Data("{ broken json".utf8).write(to: profilesURL, options: .atomic)
            let errorAppeared = await waitUntil(timeoutSeconds: 4) {
                self.app.fileProblems.contains { $0.file == "profiles.json" }
            }
            let listRetained = panel.profiles.count == 1 && panel.profiles[0].name == "夜间"
            log.check(
                errorAppeared && listRetained,
                "C3.7 profiles.json 写坏后错误条出现(\(errorAppeared))且列表保留(\(listRetained))"
            )

            try validData.write(to: profilesURL, options: .atomic)
            let errorCleared = await waitUntil(timeoutSeconds: 4) {
                !self.app.fileProblems.contains { $0.file == "profiles.json" }
            }
            log.check(errorCleared, "C3.7 profiles.json 写回合法内容后错误条自动消失")
        } catch {
            log.check(false, "效果面板自检异常：\(error)")
        }
    }

    private func makePanelBooks() throws -> (bookA: URL, bookB: URL, bookC: URL, bookD: URL) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeBook(at dir: URL, color: [CGFloat]) throws -> URL {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try writePNG(to: dir.appending(path: "01.png"), width: 320, height: 240, colorSpace: srgb) { ctx in
                ctx.setFillColor(CGColor(colorSpace: srgb, components: color)!)
                ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            }
            try writePNG(to: dir.appending(path: "02.png"), width: 320, height: 240, colorSpace: srgb) { ctx in
                ctx.clear(CGRect(x: 0, y: 0, width: 320, height: 240))
                ctx.setFillColor(CGColor(colorSpace: srgb, components: [0.85, 0.35, 0.25, 1])!)
                ctx.fillEllipse(in: CGRect(x: 80, y: 40, width: 160, height: 160))
            }
            return dir
        }
        let bookA = try makeBook(at: temporary.appending(path: "bookA", directoryHint: .isDirectory), color: [0.5, 0.4, 0.3, 1])
        let bookB = try makeBook(at: temporary.appending(path: "bookB", directoryHint: .isDirectory), color: [0.3, 0.5, 0.6, 1])
        let group = temporary.appending(path: "series", directoryHint: .isDirectory)
        let bookC = try makeBook(at: group.appending(path: "bookC", directoryHint: .isDirectory), color: [0.4, 0.6, 0.4, 1])
        let bookD = try makeBook(at: group.appending(path: "bookD", directoryHint: .isDirectory), color: [0.6, 0.4, 0.5, 1])
        return (bookA, bookB, bookC, bookD)
    }

    private func sendMouseClick(at point: NSPoint, in window: NSWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ) {
            NSApp.postEvent(up, atStart: false)
            if NSApp.isActive {
                NSApp.sendEvent(down)
            } else {
                window.sendEvent(down)
            }
        }
    }

    private func sendMouseDrag(from start: NSPoint, to end: NSPoint, in window: NSWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        let mid = NSPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: start, modifierFlags: [], timestamp: now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ), let drag1 = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: mid, modifierFlags: [], timestamp: now + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ), let drag2 = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: now + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: end, modifierFlags: [], timestamp: now + 0.03,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ) else { return }
        NSApp.postEvent(drag1, atStart: false)
        NSApp.postEvent(drag2, atStart: false)
        NSApp.postEvent(up, atStart: false)
        if NSApp.isActive {
            NSApp.sendEvent(down)
        } else {
            window.sendEvent(down)
        }
    }

    private func waitUntil(timeoutSeconds: Double, condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: 夹具生成

    private func makeFixtures() async throws -> URL {
        let dir = temporary.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 01-solid-srgb.png：400×300 纯色 sRGB (128, 96, 64)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        try writePNG(to: dir.appending(path: "01-solid-srgb.png"), width: 400, height: 300, colorSpace: srgb) { ctx in
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [128.0 / 255, 96.0 / 255, 64.0 / 255, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }

        // 02-transparent.png：400×300 透明底 + 中央彩色圆
        try writePNG(to: dir.appending(path: "02-transparent.png"), width: 400, height: 300, colorSpace: srgb) { ctx in
            ctx.clear(CGRect(x: 0, y: 0, width: 400, height: 300))
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [0.85, 0.35, 0.25, 1])!)
            ctx.fillEllipse(in: CGRect(x: 120, y: 70, width: 160, height: 160))
        }

        // 03-p3.png：320×240 Display P3 色彩空间
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        try writePNG(to: dir.appending(path: "03-p3.png"), width: 320, height: 240, colorSpace: p3) { ctx in
            ctx.setFillColor(CGColor(colorSpace: p3, components: [0.2, 0.7, 0.5, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }

        // 04-clip.mp4：复用生成的 H.264 视频夹具
        let videoSource = resolveVideoFixture()
        if let videoSource {
            try FileManager.default.copyItem(at: videoSource, to: dir.appending(path: "04-clip.mp4"))
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        return dir
    }

    private func resolveVideoFixture() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") {
            let candidate = URL(fileURLWithPath: path).appending(path: "video/h264.mp4")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // 回退到仓库里的 Fixtures/local/generated/video/h264.mp4
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = repoRoot.appending(path: "Fixtures/local/generated/video/h264.mp4")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func writePNG(to url: URL, width: Int, height: Int, colorSpace: CGColorSpace, draw: (CGContext) -> Void) throws {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        draw(ctx)
        guard let cgImage = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: C2.1 五种浏览方式与面板挂点

    private func checkBrowseModesAndPanels(_ controller: ReaderWindowController, adjust: ColorAdjust) async {
        let chain = EffectChain(effects: [.colorAdjust(adjust)])
        controller.session.update { $0.effects = chain }
        await settle()
        let modes: [(String, BrowseMode, PageMode)] = [
            ("单页", .paged, .single),
            ("双页", .paged, .double),
            ("纵向条", .verticalStrip, .single),
            ("横向条", .horizontalStrip, .single),
            ("瀑布流", .waterfall, .single),
        ]
        for (name, browse, page) in modes {
            controller.session.update {
                $0.browseMode = browse
                $0.pageMode = page
            }
            await settle()
            let count = controller.viewer.effectFilterCount
            log.check(
                count > 0 && controller.session.settings.effects.colorAdjust == adjust,
                "C2.1 \(name)：effectFilterCount=\(count) 且 effects 等于设定值"
            )
        }
        // 面板画布挂点必须为 0
        let bookshelfCount = (controller.dock.panels[DockPanels.bookshelf] as? CollectionPanel)?.collection?.canvas.effectFilterCount ?? 0
        let pageListCount = (controller.dock.panels[DockPanels.pageList] as? CollectionPanel)?.collection?.canvas.effectFilterCount ?? 0
        log.check(bookshelfCount == 0 && pageListCount == 0, "C2.1 书架(\(bookshelfCount))与页面列表(\(pageListCount))画布挂点均为 0")
    }

    // MARK: C2.2 视频页

    private func checkVideoEffects(_ controller: ReaderWindowController, adjust: ColorAdjust) async {
        let chain = EffectChain(effects: [.colorAdjust(adjust)])
        controller.session.update {
            $0.browseMode = .paged
            $0.pageMode = .single
            $0.effects = chain
        }
        controller.session.go(.index(3))
        for _ in 0..<80 where controller.viewer.paged.video?.player == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let video = controller.viewer.paged.video
        log.check(video != nil && controller.viewer.effectFilterCount > 0, "C2.2 视频页挂上效果滤镜：count=\(controller.viewer.effectFilterCount)")
        log.check(video?.isDescendant(of: controller.viewer.paged.contentContainer) == true, "C2.2 视频视图位于效果容器内")
        video?.player?.pause()
        await settle()
        var darker = adjust
        darker.brightness = -0.5
        controller.session.update { $0.effects = EffectChain(effects: [.colorAdjust(darker)]) }
        await settle()
        let brightness = (controller.viewer.paged.contentContainer.layer?.filters?.first as? CIFilter)?
            .value(forKey: kCIInputBrightnessKey) as? Double
        log.check(
            controller.viewer.effectFilterCount > 0 && brightness.map { abs($0 - (-0.125)) < 0.001 } == true,
            "C2.2 视频暂停时改值立即生效：inputBrightness=\(brightness.map { String(format: "%.3f", $0) } ?? "nil")"
        )
        controller.session.update { $0.effects = chain }
        controller.session.go(.index(0))
        await settle()
    }

    // MARK: C2.3 分页视图层级

    private func checkPagedHierarchy(_ controller: ReaderWindowController, window: NSWindow) async {
        let paged = controller.viewer.paged
        let container = paged.contentContainer
        controller.viewer.zoom(by: 2)
        await settle()
        log.check(!paged.navigator.isDescendant(of: container), "C2.3 导航图在效果容器外")
        log.check(!controller.viewer.hud.isDescendant(of: container), "C2.3 HUD 在效果容器外")
        let nonContent = container.subviews.filter { !($0 is VideoPageView) }
        log.check(nonContent.isEmpty, "C2.3 效果容器内不含错误/占位等非内容视图：\(nonContent.count)")
        log.check(
            paged.magnifier.root.superlayer !== container.layer && (paged.magnifier.root.filters?.count ?? 0) > 0,
            "C2.3 放大镜在容器外且独立挂滤镜：count=\(paged.magnifier.root.filters?.count ?? 0)"
        )
        paged.resetTransform()
        await settle()
    }

    // MARK: C2.4 六种背景

    private func checkBackgrounds(_ controller: ReaderWindowController, window: NSWindow) async {
        controller.session.go(.index(1)) // 透明图
        await settle()
        let backgrounds: [(String, ViewerBackground)] = [
            ("black", .black),
            ("gray", .gray),
            ("white", .white),
            ("custom", .custom(red: 0.2, green: 0.4, blue: 0.6)),
            ("checkerboard", .checkerboard),
            ("auto", .auto),
        ]
        for (name, bg) in backgrounds {
            controller.session.update { $0.background = bg }
            await settle()
            controller.viewer.displayIfNeeded()
            let layerColor = controller.viewer.layer?.backgroundColor
            let matched: Bool
            switch bg {
            case .black: matched = colorMatches(layerColor, r: 0, g: 0, b: 0)
            case .gray: matched = colorMatches(layerColor, r: 0.5, g: 0.5, b: 0.5)
            case .white: matched = colorMatches(layerColor, r: 1, g: 1, b: 1)
            case .custom: matched = colorMatches(layerColor, r: 0.2, g: 0.4, b: 0.6)
            case .checkerboard: matched = layerColor?.colorSpace?.model == .pattern
            case .auto: matched = layerColor != nil && layerColor?.colorSpace?.model != .pattern
            }
            log.check(controller.session.settings.background == bg && matched, "C2.4 背景 \(name) 与背景层颜色对应")
            if bg == .checkerboard {
                let shot = log.snapshot(window, "background-checkerboard", captureImage: true)
                let hasPattern = shot.map { hasCheckerboardVariation(in: $0) } ?? false
                log.check(hasPattern, "C2.4 透明图在棋盘格下截图可见方格明暗交替")
            }
        }
    }

    // MARK: C2.5 效果开关

    private func checkEffectsToggle(_ controller: ReaderWindowController, window: NSWindow, adjust: ColorAdjust) async {
        controller.session.go(.index(0))
        controller.session.update {
            $0.background = .auto
            $0.effects = EffectChain(effects: [.colorAdjust(adjust)])
        }
        await settle()
        let onImage = captureWindowWithGPUFilters(window, name: "effects-on")
        controller.run(.effectsToggle)
        await settle()
        let offImage = captureWindowWithGPUFilters(window, name: "effects-off")
        let offState = app.menuState(for: .effectsToggle)
        log.check(
            !controller.effectsEnabled && controller.viewer.effectFilterCount == 0
                && controller.session.settings.effects.colorAdjust == adjust
                && offState == .off,
            "C2.5 关闭效果后 effectFilterCount=0、effects 保留原值、菜单取消勾选"
        )
        if let onImage, let offImage {
            let a = centerRGB(onImage)
            let b = centerRGB(offImage)
            let visualDiff = max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
            log.check(visualDiff > 10, "C2.5 效果开关前后窗口画面中心像素明显变化：on=\(a) off=\(b) Δ=\(visualDiff)")
        } else {
            print("INFO 跳过窗口 GPU 截图像素对比（无窗口录屏权限）")
        }
        controller.run(.effectsToggle)
        await settle()
        let onState = app.menuState(for: .effectsToggle)
        log.check(
            controller.effectsEnabled && controller.viewer.effectFilterCount > 0 && onState == .on,
            "C2.5 再打开效果恢复滤镜与菜单勾选"
        )
    }

    /// 经 WindowServer 捕获含 GPU Core Image 滤镜的窗口截图；若当前进程无录屏权限则回退 `log.snapshot` 并返回 nil。
    private func captureWindowWithGPUFilters(_ window: NSWindow, name: String) -> CGImage? {
        let targetURL = (log.output ?? temporary).appending(path: "\(name).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-l", String(window.windowNumber), "-o", "-x", targetURL.path]
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let src = CGImageSourceCreateWithURL(targetURL as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return cg
            }
        }
        _ = log.snapshot(window, name)
        return nil
    }

    // MARK: C2.6 / C2.7 / C2.7b 复制与拖出

    private func checkCopyAndDragExport(_ controller: ReaderWindowController, adjust: ColorAdjust) async {
        guard let fileOps = app.fileOps, let pages = controller.session.book?.pages, pages.count >= 4 else {
            log.check(false, "C2.6 缺少 fileOps 或测试页")
            return
        }
        let solidEntry = pages[0].entry
        let p3Entry = pages[2].entry
        let videoEntry = pages[3].entry
        let chain = EffectChain(effects: [.colorAdjust(adjust)])
        controller.session.update { $0.effects = chain }
        controller.setEffectsEnabled(true)
        await settle()

        // C2.6 单张 sRGB 静态图复制
        await fileOps.copyItems(origin: FileOrigin(window: controller, items: [solidEntry]))
        let pb = NSPasteboard.general
        let pngData = pb.data(forType: .png)
        let urls = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let expectedSuffix = FileOperationController.adjustedFileSuffix + ".png"
        log.check(
            pngData != nil && urls.count == 1 && urls[0].lastPathComponent.hasSuffix(expectedSuffix)
                && urls[0].path.contains("/rendered/"),
            "C2.6 复制产出调色 PNG 与带后缀文件 URL：\(urls.first?.lastPathComponent ?? "nil")"
        )
        if let pngData, let src = CGImageSourceCreateWithData(pngData as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            log.check(cg.width == 400 && cg.height == 300, "C2.6 像素尺寸等于原图：\(cg.width)×\(cg.height)")
            log.check(cg.colorSpace?.model == .rgb, "C2.6 保留 RGB 色彩空间：\(String(describing: cg.colorSpace?.name))")
            let actual = centerRGB(cg)
            let sourceCI = CIImage(color: CIColor(red: 128.0 / 255, green: 96.0 / 255, blue: 64.0 / 255, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            let expectedCI = EffectFilters.apply(chain, to: sourceCI).cropped(to: sourceCI.extent)
            let expectedPNG = CIContext().pngRepresentation(of: expectedCI, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            if let expectedPNG, let esrc = CGImageSourceCreateWithData(expectedPNG as CFData, nil),
               let ecg = CGImageSourceCreateImageAtIndex(esrc, 0, nil) {
                let expected = centerRGB(ecg)
                let delta = max(abs(actual.0 - expected.0), max(abs(actual.1 - expected.1), abs(actual.2 - expected.2)))
                log.check(delta <= 2, "C2.6 中心像素与 EffectFilters.apply 期望值误差 ≤ 2/255：actual=\(actual) expected=\(expected) Δ=\(delta)")
            } else {
                log.check(false, "C2.6 无法渲染期望参考图")
            }
        } else {
            log.check(false, "C2.6 剪贴板 PNG 无法解码")
        }

        // C2.6 Display P3 色彩空间保留
        await fileOps.copyItems(origin: FileOrigin(window: controller, items: [p3Entry]))
        if let p3Data = pb.data(forType: .png), let p3Src = CGImageSourceCreateWithData(p3Data as CFData, nil),
           let p3CG = CGImageSourceCreateImageAtIndex(p3Src, 0, nil) {
            log.check(p3CG.colorSpace?.name == CGColorSpace.displayP3, "C2.6 Display P3 源图保留 Display P3 色彩空间：\(String(describing: p3CG.colorSpace?.name))")
        } else {
            log.check(false, "C2.6 Display P3 复制结果无效")
        }

        // 拖出承诺检查
        let writer = fileOps.pasteboardWriter(for: solidEntry, in: controller)
        log.check(writer is NSFilePromiseProvider, "C2.6 效果开启时拖出返回 PNG 文件承诺")

        // C2.7b 多选两张静态图 + 一个视频
        await fileOps.copyItems(origin: FileOrigin(window: controller, items: [solidEntry, p3Entry, videoEntry]))
        let multiURLs = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        log.check(
            multiURLs.count == 3
                && multiURLs[0].lastPathComponent.hasSuffix(expectedSuffix)
                && multiURLs[1].lastPathComponent.hasSuffix(expectedSuffix)
                && multiURLs[2].pathExtension.lowercased() == "mp4"
                && !multiURLs[2].path.contains("/rendered/"),
            "C2.7b 多选两静态图+一视频得到两个调色 PNG 和视频原文件：\(multiURLs.map(\.lastPathComponent))"
        )

        // C2.7 效果关闭时复制 -> 原文件
        controller.setEffectsEnabled(false)
        await settle()
        await fileOps.copyItems(origin: FileOrigin(window: controller, items: [solidEntry]))
        let offURLs = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        log.check(
            offURLs.count == 1 && offURLs[0].lastPathComponent == "01-solid-srgb.png" && !offURLs[0].path.contains("/rendered/"),
            "C2.7 效果关闭时复制返回原文件：\(offURLs.first?.lastPathComponent ?? "nil")"
        )

        // C2.7 效果打开但恒等时复制 -> 原文件
        controller.setEffectsEnabled(true)
        controller.session.update { $0.effects = .empty }
        await settle()
        await fileOps.copyItems(origin: FileOrigin(window: controller, items: [solidEntry]))
        let idURLs = (pb.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        log.check(
            idURLs.count == 1 && idURLs[0].lastPathComponent == "01-solid-srgb.png" && !idURLs[0].path.contains("/rendered/"),
            "C2.7 效果恒等时复制返回原文件：\(idURLs.first?.lastPathComponent ?? "nil")"
        )
    }

    // MARK: 辅助

    private func openBook(_ controller: ReaderWindowController, url: URL, expectedCount: Int) async {
        let expectedName = url.lastPathComponent
        controller.open([url])
        for _ in 0..<200 {
            if let book = controller.session.book,
               book.location.name == expectedName,
               book.isEnumerated,
               book.pages.count == expectedCount { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    private func colorMatches(_ color: CGColor?, r: CGFloat, g: CGFloat, b: CGFloat) -> Bool {
        guard let color,
              let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return false }
        return abs(components[0] - r) < 0.02 && abs(components[1] - g) < 0.02 && abs(components[2] - b) < 0.02
    }

    private func centerRGB(_ image: CGImage) -> (Int, Int, Int) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return (0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        ctx.draw(image, in: CGRect(x: -(width / 2), y: -(height / 2), width: width, height: height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// 检查窗口截图中央区域附近是否存在棋盘格的明暗交替。
    private func hasCheckerboardVariation(in image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 200, height > 200 else { return false }
        let sampleW = 64, sampleH = 64
        var bytes = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &bytes, width: sampleW, height: sampleH, bitsPerComponent: 8, bytesPerRow: sampleW * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        // 取透明图靠近左上透明区域（避开中央圆）
        let originX = width / 2 - 140
        let originY = height / 2 - 100
        ctx.draw(image, in: CGRect(x: -originX, y: -originY, width: width, height: height))
        var minLuma = 255, maxLuma = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let luma = (Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
        }
        return maxLuma - minLuma >= 12
    }
}
#endif
