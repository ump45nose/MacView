#if DEBUG
import AppKit
import Carbon.HIToolbox
import IOSurface
import MVCommands
import MVFoundation
import MVMedia
import MVReading

/// 外壳自检：Mock 验证菜单与输入；真实服务验证文件入口、取图与配置重载。
///
/// 启动参数：`-MVSelfTest YES` 运行后退出（退出码为失败数）；`-MVSelfTestOutput <目录>` 写入菜单清单与窗口图像。
/// 真实服务另传 `-MVSelfTestFixtures <Fixtures目录>`，并用 `-MVSupportDirectory/-MVCacheDirectory/-MVLayoutFile` 隔离数据。
/// 预期启动失败的场景加 `-MVSelfTestStartupFailure YES`，自动检查错误窗口并退出。
/// 按键经 `NSApp.sendEvent` 分派，走的是真实的菜单快捷键匹配和响应链；不需要辅助功能权限。
@MainActor
final class SelfTest {
    static let launchKey = "MVSelfTest"
    static let outputKey = "MVSelfTestOutput"

    /// 自检不读不写用户的会话，会话自检除外。
    static var isRunningExceptSession: Bool {
        ["MVSelfTest", "MVDockSelfTest", "MVViewerSelfTest", "MVPanelSelfTest", "MVSettingsSelfTest"].contains {
            UserDefaults.standard.object(forKey: $0) != nil
        }
    }

    private let app: AppDelegate
    private let log = SelfTestLog()
    /// App 不在前台时接收按键的窗口。
    private var target: NSWindow?

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
        let test = SelfTest(app: app)
        Task { await test.run() }
    }

    /// 仍显示真实错误窗口；自检在模态 run loop 中检查并点击“退出”。
    static func checkStartupFailureIfRequested(app: AppDelegate, alert: NSAlert) {
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
        let check = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                let log = SelfTestLog()
                log.check(alert.window.isVisible, "真实服务启动失败后显示错误窗口")
                log.check(!app.isMock && app.services == nil && app.controllers.isEmpty, "启动失败没有回落到 Mock")
                guard UserDefaults.standard.bool(forKey: "MVSelfTestStartupFailure") else {
                    log.check(false, "自检遇到非预期的服务启动失败")
                    exit(log.summarize())
                }
                log.snapshot(alert.window, "startup-error")
                let failures = log.summarize()
                if failures != 0 { exit(failures) }
                alert.buttons.first?.performClick(nil)
            }
        }
        RunLoop.main.add(check, forMode: .modalPanel)
    }

    private init(app: AppDelegate) {
        self.app = app
    }

    private func run() async {
        TestPresentation.activateIfAllowed()
        // 激活是异步的：中途才激活时，按键分派的路径会变。
        if TestPresentation.activationAllowed {
            for _ in 0..<30 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
        } else {
            print("INFO 不激活 App（需要焦点的检查加 -\(TestPresentation.activateKey) YES）")
        }
        if !app.isMock { await runReal(); return }
        dumpMenu()
        guard let first = app.controllers.first, let window = first.window else {
            log.check(false, "没有窗口")
            exit(log.summarize())
        }
        target = window
        log.check(text(in: first.content.statusBar).contains(String(localized: "Mock 服务")), "显式 Mock 服务在窗口上标明")
        log.check(window.toolbar?.items.map(\.itemIdentifier.rawValue) == ["dock.left", "book.previous", "book.next", "book.title", "NSToolbarFlexibleSpaceItem", "view.waterfallOptions", "view.browse", "view.options", "window.fullScreen", "dock.right"], "工具栏有停靠区开关、切书、书名、浏览方式、显示和全屏")
        print("INFO 按键分派：\(NSApp.isActive ? "NSApp.sendEvent" : "App 未激活（屏幕可能已锁定），按 NSApplication 的顺序手动分派")")
        await settle()
        let frameNextItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == app.catalog.title(of: .frameNext) }
        log.check(frameNextItem != nil && frameNextItem?.keyEquivalent == "", "菜单关着时“下一帧”没有快捷键，→ 不会被菜单匹配")
        log.snapshot(window, "empty")

        // C5.8：文件 URL 经 SourceRegistry 转成 Location 交给会话；文件夹与 zip。
        first.open([URL(fileURLWithPath: "/Volumes/Mock/画集/系列 A/第 5 卷")])
        await waitForBook(first) { $0.pages.count == 100 }
        log.check(first.session.book?.location.description == "/mock/画集/系列 A/第 5 卷", "文件夹 URL 转成 Location：\(first.session.book?.location.description ?? "nil")")
        log.check(first.session.book?.pages.count == 100, "打开 100 页的书：\(first.session.book?.pages.count ?? 0) 页")
        window.makeFirstResponder(first.viewer)
        await settle()
        log.snapshot(window, "book")

        // C5.6：查看器中方向键翻页，单次触发。
        await send(kVK_RightArrow)
        log.check(first.session.currentFrame == 1, "查看器中 → 翻到下一帧：\(first.session.currentFrame)")
        await send(kVK_RightArrow, [.option])
        log.check(first.session.currentFrame == 2, "⌥→ 下一页：\(first.session.currentFrame)")
        await send(kVK_LeftArrow)
        log.check(first.session.currentFrame == 1, "← 上一帧：\(first.session.currentFrame)")
        await send(kVK_End)
        log.check(first.session.currentFrame == 99, "End 末页：\(first.session.currentFrame)")
        await send(kVK_RightArrow, [.command])
        log.check(first.session.currentFrame == 99, "末页再按 ⌘→ 停在末页：\(first.session.currentFrame)")

        // 两键序列：首键显示待定提示，续键执行。
        await send(kVK_ANSI_G)
        log.check(!first.pendingView.isHidden && first.router.pending?.typed == [KeyChord("g")], "按下 G 后显示待定提示")
        await settle()
        log.snapshot(window, "pending")
        await send(kVK_ANSI_G)
        log.check(first.pendingView.isHidden && first.session.currentFrame == 0, "G G 回到首页并收起提示：\(first.session.currentFrame)")
        await send(kVK_ANSI_G)
        await send(kVK_ANSI_E)
        log.check(first.session.currentFrame == 99, "G E 到末页：\(first.session.currentFrame)")
        await send(kVK_ANSI_G)
        try? await Task.sleep(for: CommandCatalog.sequenceTimeout + .milliseconds(200))
        log.check(first.pendingView.isHidden, "超时后提示消失")
        await send(kVK_Home)
        log.check(first.session.currentFrame == 0, "超时后 Home 仍按首键解析：\(first.session.currentFrame)")

        // C5.6：文本框中的字母和方向键不触发翻页或切书。
        await send(kVK_ANSI_G, [.command])
        let field = first.content.statusBar.jumpField
        log.check(InputRouter.scope(of: window.firstResponder) == .textInput, "⌘G 后焦点在页码输入框（textInput）")
        let book = first.session.book?.location
        let typing: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_ANSI_A, []), (kVK_ANSI_G, []), (kVK_ANSI_G, []), (kVK_RightArrow, []), (kVK_LeftArrow, []),
            (kVK_RightArrow, [.option]), (kVK_DownArrow, [.option]), (kVK_RightArrow, [.command]), (kVK_End, []), (kVK_Space, []),
        ]
        // 先记下用户当前的输入源，再限制这个文本框的输入法；不切换系统输入法。
        let keyboard = currentKeyboardInput()
        // 系统当前是中文输入法时，字母会变成组合文本。
        field.currentEditor()?.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        for (key, flags) in typing {
            await send(key, flags)
        }
        await settle()
        log.check(first.session.currentFrame == 0 && first.session.book?.location == book, "文本框中的按键没有翻页或切书：帧 \(first.session.currentFrame)")
        log.check(first.pendingView.isHidden, "文本框中按 G 不显示待定提示")
        let editor = field.currentEditor() as? NSTextView
        if !NSApp.isActive {
            // 文本输入上下文只对 key window 生效；App 未激活时按键到了输入框但不插入文字。
            print("SKIP 字母进入文本框（App 未激活）")
        } else if keyboard.insertsPlainLetters {
            log.check(editor?.string.contains("agg") == true, "字母进入了文本框：“\(editor?.string ?? "")”")
        } else {
            let languages = keyboard.languages.joined(separator: ",")
            let detail = languages.isEmpty ? keyboard.id : "\(keyboard.id)，\(languages)"
            print("SKIP 字母进入了文本框（\(detail)，字母会进入组合文本）")
        }
        log.snapshot(window, "jump-field")
        await edit(kVK_Escape, editor, #selector(NSResponder.cancelOperation(_:)))
        log.check(window.firstResponder === first.viewer, "Esc 取消输入，焦点回到页面")
        await jump(first, "50")
        log.check(first.session.currentFrame == 49, "输入 50 回车跳到第 50 页：\(first.session.currentFrame)")

        // C5.7：切书。
        await send(kVK_DownArrow, [.option])
        await waitForBook(first) { $0.location.name == "第 6 卷" }
        log.check(first.session.book?.location.name == "第 6 卷", "⌥↓ 下一本书：\(first.session.book?.location.name ?? "nil")")
        await send(kVK_UpArrow, [.option])
        await waitForBook(first) { $0.location.name == "第 5 卷" }
        log.check(first.session.book?.location.name == "第 5 卷" && first.session.currentFrame == 49, "⌥↑ 上一本书，回到记忆的页：\(first.session.book?.location.name ?? "nil")，\(first.session.currentFrame)")
        await jump(first, "49")

        // C5.7：多个标签页各自翻页；global 快捷键由菜单触发。
        let before = app.controllers.count
        await send(kVK_ANSI_T, [.command])
        await settle()
        log.check(app.controllers.count == before + 1, "⌘T 新建标签页：\(app.controllers.count) 个窗口")
        guard let second = app.controllers.last, second !== first, let secondWindow = second.window else {
            log.check(false, "没有新标签页")
            exit(log.summarize())
        }
        log.check(secondWindow.tabGroup === window.tabGroup, "新标签页与第一个窗口在同一个标签组")
        target = secondWindow
        second.open([URL(fileURLWithPath: "/Volumes/Mock/漫画/作品 1.zip")])
        await waitForBook(second) { $0.pages.count == 40 }
        log.check(second.session.book?.location.layers == [["漫画", "作品 1.zip"]], "zip URL 转成 Location：\(second.session.book?.location.description ?? "nil")")
        secondWindow.makeFirstResponder(second.viewer)
        await send(kVK_RightArrow)
        await send(kVK_RightArrow)
        await send(kVK_RightArrow)
        log.check(second.session.currentFrame == 3 && first.session.currentFrame == 48, "两个标签页各自翻页：\(first.session.currentFrame) / \(second.session.currentFrame)")
        await settle()
        log.snapshot(secondWindow, "tab")

        // 移动标签页到新窗口、合并全部窗口、新建独立窗口（系统的标签页动作）。
        secondWindow.moveTabToNewWindow(nil)
        await settle()
        log.check(secondWindow.tabGroup !== window.tabGroup, "移动标签页到新窗口")
        window.mergeAllWindows(nil)
        await settle()
        log.check(secondWindow.tabGroup === window.tabGroup, "合并全部窗口")
        if let third = app.newWindow()?.window {
            await settle()
            log.check(third.tabGroup !== window.tabGroup && (third.tabbedWindows?.count ?? 1) == 1, "新建窗口是独立窗口，不并入标签组")
            third.performClose(nil)
            await settle()
        }

        // 打开失败直接显示：Mock 之外的路径。
        second.open([URL(fileURLWithPath: NSTemporaryDirectory())])
        await settle()
        log.check(secondWindow.attachedSheet != nil, "Mock 之外的路径显示错误")
        log.snapshot(secondWindow, "open-error")
        if let sheet = secondWindow.attachedSheet { secondWindow.endSheet(sheet) }

        if NSApp.isActive {
            await send(kVK_ANSI_W, [.command])
            await settle()
            log.check(app.controllers.count == before, "⌘W 关闭标签页：\(app.controllers.count) 个窗口")
        } else {
            // App 未激活时没有主窗口，菜单命令没有作用对象。
            print("SKIP ⌘W 关闭标签页（App 未激活）")
        }
        exit(log.summarize())
    }

    private func runReal() async {
        guard let services = app.services, let first = app.controllers.first, let window = first.window,
              let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") else {
            log.check(false, "真实服务自检需要窗口与 -MVSelfTestFixtures")
            exit(log.summarize())
        }
        target = window
        let fixtures = URL(fileURLWithPath: path)
        log.check(services.keyBindings != nil, "默认使用真实服务")
        dumpMenu()
        do {
            for (relative, drop) in [("image/aspect", false), ("archive/zip/stored.zip", true)] {
                let url = fixtures.appending(path: relative)
                let expected = try await services.sources.location(for: url)
                if drop { first.content.onDrop?([url]) } else { first.open([url]) }
                await waitForBook(first) { $0.location == expected && $0.pages.count > 1 }
                log.check(first.session.book?.location == expected && (first.session.book?.pages.count ?? 0) > 1,
                          "\(drop ? "拖放" : "打开面板共用")入口正确打开 \(relative)")
                first.session.go(.first)
                window.makeFirstResponder(first.viewer)
                await send(kVK_RightArrow)
                log.check(first.session.currentFrame == 1, "真实书按 → 翻页：\(relative)")
                await checkRealImage(first)
            }
            let outer = try await services.sources.location(for: fixtures.appending(path: "archive/zip/nested.zip"))
            let nested = outer.appendingLayer(["inner-stored.zip"])
            await first.session.open(nested, at: nil)
            log.check(first.session.book?.location == nested && (first.session.book?.pages.count ?? 0) > 1, "嵌套压缩包打开并枚举图片")
            first.session.go(.first)
            await send(kVK_RightArrow)
            log.check(first.session.currentFrame == 1, "嵌套压缩包翻页")
            await checkRealImage(first)
            await checkBindingReload(first)
            log.snapshot(window, "real-book")
        } catch {
            log.check(false, "真实服务场景失败：\(error)")
        }
        await services.shutdown()
        exit(log.summarize())
    }

    private func checkRealImage(_ controller: ReaderWindowController) async {
        guard let services = app.services, let book = controller.session.book,
              controller.session.frames.indices.contains(controller.session.currentFrame),
              let element = controller.session.frames[controller.session.currentFrame].elements.first else {
            return log.check(false, "真实书没有当前页帧")
        }
        do {
            var delivered = false
            let identity = book.pages[element.page].entry.identity
            for try await image in services.pipeline.image(for: identity, target: DisplayTarget(pixelSize: PixelSize(width: 120, height: 180)), allowOriginal: false, priority: .visible) {
                delivered = true
                log.check(image.surface != nil && CanvasImage(image).contents is IOSurface, "真实取图与 CanvasImage 仅交付 IOSurface")
            }
            log.check(delivered, "真实管线取到当前页图片")
            for _ in 0..<100 where controller.viewer.paged.slots.contains(where: { $0.contents is IOSurface }) != true {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let contents = controller.viewer.paged.slots.compactMap(\.contents)
            log.check(!contents.isEmpty && contents.allSatisfy { $0 is IOSurface }, "查看器图层内容全部是 IOSurface")
        } catch { log.check(false, "真实页面取图失败：\(error)") }
    }

    private func checkBindingReload(_ controller: ReaderWindowController) async {
        let url = app.supportDirectory.appending(path: "keybindings.json")
        let binding = KeyBinding(sequence: [KeyChord("j")], command: .frameNext, scope: .viewer)
        do {
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KeyBindingsFile(bindings: [binding])))
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "value": value])
            try data.write(to: url, options: .atomic)
            for _ in 0..<100 where !app.catalog.bindings.contains(binding) { try? await Task.sleep(for: .milliseconds(20)) }
            log.check(app.catalog.bindings.contains(binding) && !app.catalog.bindings.contains { $0.command == .frameNext && $0 != binding }, "外部 keybindings.json 替换默认绑定")
            let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first { menu in menu.items.contains { $0.title == app.catalog.title(of: .frameNext) } }
            if let menu { menu.delegate?.menuWillOpen?(menu) }
            log.check(menu?.items.first { $0.title == app.catalog.title(of: .frameNext) }?.keyEquivalent == "j", "重载后菜单显示新快捷键")
            if let menu { menu.delegate?.menuDidClose?(menu) }
            controller.session.go(.first)
            await send(kVK_ANSI_J)
            log.check(controller.session.currentFrame == 1, "重建的 InputRouter 用新绑定翻页")
            try Data("{ broken".utf8).write(to: url, options: .atomic)
            for _ in 0..<100 where controller.content.fileErrorBanners["keybindings.json"] == nil { try? await Task.sleep(for: .milliseconds(20)) }
            log.check(controller.content.fileErrorBanners["keybindings.json"] != nil && app.catalog.bindings.contains(binding), "坏配置显示错误横幅并保留上次绑定")
            checkBannerLanguage(controller, zh: "行，第", en: "Line ", "语法错误")
            if let window = controller.window { log.snapshot(window, "keybindings-error") }
            let extra = app.newWindow()
            log.check(extra?.content.fileErrorBanners["keybindings.json"] != nil, "坏配置期间新窗口也显示横幅")
            extra?.window?.performClose(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.makeFirstResponder(controller.viewer)
            controller.session.go(.first)
            await send(kVK_ANSI_J)
            log.check(controller.session.currentFrame == 1, "坏配置后旧绑定继续生效")
            let syntaxBanner = controller.content.fileErrorBanners["keybindings.json"]
            try Data(#"{"version":1,"value":{}}"#.utf8).write(to: url, options: .atomic)
            for _ in 0..<100 where controller.content.fileErrorBanners["keybindings.json"] === syntaxBanner { try? await Task.sleep(for: .milliseconds(20)) }
            checkBannerLanguage(controller, zh: "缺少字段 bindings", en: "Missing field bindings", "缺字段")
            try data.write(to: url, options: .atomic)
            for _ in 0..<100 where controller.content.fileErrorBanners["keybindings.json"] != nil { try? await Task.sleep(for: .milliseconds(20)) }
            log.check(controller.content.fileErrorBanners["keybindings.json"] == nil, "修复配置后清除横幅")
        } catch { log.check(false, "按键绑定重载失败：\(error)") }
    }

    /// 横幅文字跟随界面语言，英文环境不混入中文。
    private func checkBannerLanguage(_ controller: ReaderWindowController, zh: String, en: String, _ name: String) {
        let banner = controller.content.fileErrorBanners["keybindings.json"].map { text(in: $0) } ?? ""
        let hasChinese = banner.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let matches = Bundle.main.preferredLocalizations.first == "en" ? banner.contains(en) && !hasChinese : banner.contains(zh)
        log.check(matches, "\(name)的横幅文字跟随界面语言：\(banner)")
    }

    private func text(in view: NSView) -> String {
        (view as? NSTextField)?.stringValue ?? view.subviews.map { text(in: $0) }.joined(separator: " ")
    }

    /// 当前键盘输入源。只读，不调用选择输入源的接口。
    private func currentKeyboardInput() -> (id: String, languages: [String], insertsPlainLetters: Bool) {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ("未取得输入源", [], false)
        }
        let id: String
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        } else {
            id = "未取得输入源标识"
        }
        let languages: [String]
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String] ?? []
        } else {
            languages = []
        }
        let primary = languages.first?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        let chinese = languages.contains { $0.lowercased().contains("zh") }
        // 英文键位（ABC、U.S.）才会把字母直接送进文本框；语言含 zh，或标识不是 keylayout（输入法），都算非 ASCII。
        let insertsPlainLetters = primary == "en" && !chinese && id.hasPrefix("com.apple.keylayout.")
        return (id, languages, insertsPlainLetters)
    }

    // MARK: 工具

    /// 让 AppKit 完成布局、绘制和排队的主线程任务。
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// 等到会话中的书列举完并满足条件，最多 10 秒。
    private func waitForBook(_ controller: ReaderWindowController, until condition: (Book) -> Bool) async {
        for _ in 0..<200 where !(controller.session.book.map { $0.isEnumerated && condition($0) } ?? false) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 合成一次按下与抬起，经 NSApp 分派，与真实键盘输入走同一条路径。
    /// 命令经 Task 异步执行，发送后稍等再检查。
    ///
    /// App 处于前台时经 `NSApp.sendEvent` 分派；屏幕锁定等原因无法激活时，按 NSApplication 的顺序手动分派：
    /// 窗口的 performKeyEquivalent → 菜单栏的 performKeyEquivalent → 窗口的 sendEvent（第一响应者）。
    private func send(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) async {
        guard let window = NSApp.keyWindow ?? target else {
            log.check(false, "没有可以接收按键的窗口")
            return
        }
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        for down in [true, false] {
            // 经 CGEvent 生成，字符按当前键盘布局换算，方向键等自带的 function 标志也由系统补上。
            guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            cgEvent.flags = cgFlags.union(cgEvent.flags.intersection([.maskSecondaryFn, .maskNumericPad]))
            guard let event = NSEvent(cgEvent: cgEvent) else { continue }
            let type = event.type
            if NSApp.keyWindow != nil {
                NSApp.sendEvent(event)
            } else if type == .keyUp {
                window.sendEvent(event)
            } else {
                if !window.performKeyEquivalent(with: event), NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                    window.sendEvent(event)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// ⌘G 打开页码输入框，输入页码并回车。
    private func jump(_ controller: ReaderWindowController, _ number: String) async {
        await send(kVK_ANSI_G, [.command])
        let editor = controller.content.statusBar.jumpField.currentEditor() as? NSTextView
        editor?.selectAll(nil)
        if NSApp.isActive {
            let codes = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            for digit in number.compactMap(\.wholeNumberValue) {
                await send(codes[digit])
            }
        } else {
            editor?.insertText(number, replacementRange: editor?.selectedRange() ?? NSRange())
        }
        await edit(kVK_Return, editor, #selector(NSResponder.insertNewline(_:)))
    }

    /// 输入框中的 Esc 与回车：App 未激活时文本输入上下文不工作，改为直接向字段编辑器发送对应的编辑命令。
    private func edit(_ keyCode: Int, _ editor: NSTextView?, _ command: Selector) async {
        if NSApp.isActive {
            await send(keyCode)
        } else {
            editor?.doCommand(by: command)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func dumpMenu() {
        NSApp.mainMenu?.update()
        var lines: [String] = []
        func walk(_ menu: NSMenu, depth: Int) {
            // 菜单关着时就有的是菜单快捷键；打开时代理才填上的只显示，由 InputRouter 处理。
            let ownedByBuilder = menu.delegate is MenuBuilder
            let live = Set(menu.items.filter { !$0.keyEquivalent.isEmpty }.map(ObjectIdentifier.init))
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            for item in menu.items {
                if item.isSeparatorItem {
                    lines.append(String(repeating: "  ", count: depth) + "—")
                    continue
                }
                var line = String(repeating: "  ", count: depth) + item.title
                if !item.keyEquivalent.isEmpty {
                    line += "\t[" + Self.describe(item.keyEquivalent, item.keyEquivalentModifierMask) + "]"
                    line += !ownedByBuilder || live.contains(ObjectIdentifier(item)) ? "" : " (仅显示)"
                }
                if item.submenu == nil, !item.isEnabled {
                    line += "\t(不可用)"
                }
                lines.append(line)
                if let submenu = item.submenu {
                    walk(submenu, depth: depth + 1)
                }
            }
            menu.delegate?.menuDidClose?(menu)
        }
        if let menu = NSApp.mainMenu {
            walk(menu, depth: 0)
        }
        let text = lines.joined(separator: "\n")
        print("MENU BEGIN\n\(text)\nMENU END")
        if let output = log.output {
            try? text.write(to: output.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        }
    }

    private static func describe(_ key: String, _ mask: NSEvent.ModifierFlags) -> String {
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        let names: [Int: String] = [
            NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→", NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓",
            NSHomeFunctionKey: "Home", NSEndFunctionKey: "End", 0x20: "Space", 0x09: "Tab",
        ]
        let scalar = key.unicodeScalars.first.map { Int($0.value) } ?? 0
        return text + (names[scalar] ?? key.uppercased())
    }
}

/// 自检共用：逐项打印 PASS/FAIL，把窗口（含标题栏）渲染成 PNG 写进 `-MVSelfTestOutput` 目录。
@MainActor
final class SelfTestLog {
    let output = UserDefaults.standard.string(forKey: SelfTest.outputKey).map { URL(fileURLWithPath: $0) }
    private var failures = 0

    init() {
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    }

    func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(message)")
    }

    func snapshot(_ window: NSWindow, _ name: String) {
        guard let output, let view = window.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let image = view.renderedImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
    }

    /// 打印汇总行，返回失败数（用作退出码）。
    func summarize() -> Int32 {
        print("SELFTEST \(failures == 0 ? "OK" : "FAILED \(failures)")")
        fflush(stdout)
        return Int32(failures)
    }
}
#endif
