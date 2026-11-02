#if DEBUG
import AppKit
import Carbon.HIToolbox
import MVCommands
import MVReading

/// 外壳的自检：在 Mock 上打开书，向 NSApp 发送合成的按键，检查菜单、输入路由、翻页、切书与多标签，并把窗口渲染成 PNG。
///
/// 启动参数：`-MVSelfTest YES` 运行后退出（退出码为失败数）；`-MVSelfTestOutput <目录>` 写入菜单清单与窗口图像。
/// 按键经 `NSApp.sendEvent` 分派，走的是真实的菜单快捷键匹配和响应链；不需要辅助功能权限。
@MainActor
final class SelfTest {
    static let launchKey = "MVSelfTest"
    static let outputKey = "MVSelfTestOutput"

    private let app: AppDelegate
    private let log = SelfTestLog()
    /// App 不在前台时接收按键的窗口。
    private var target: NSWindow?

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: launchKey) else { return }
        let test = SelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) {
        self.app = app
    }

    private func run() async {
        NSApp.activate()
        dumpMenu()
        guard let first = app.controllers.first, let window = first.window else {
            log.check(false, "没有窗口")
            exit(log.summarize())
        }
        target = window
        log.check(window.toolbar?.items.map(\.itemIdentifier.rawValue) == ["book.previous", "book.next", "book.title"], "工具栏有上一本、下一本按钮和书名")
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
        window.makeFirstResponder(first.pageView)
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
        for (key, flags) in typing {
            await send(key, flags)
        }
        await settle()
        log.check(first.session.currentFrame == 0 && first.session.book?.location == book, "文本框中的按键没有翻页或切书：帧 \(first.session.currentFrame)")
        log.check(first.pendingView.isHidden, "文本框中按 G 不显示待定提示")
        let editor = field.currentEditor() as? NSTextView
        if NSApp.isActive {
            log.check(editor?.string.contains("agg") == true, "字母进入了文本框：“\(editor?.string ?? "")”")
        } else {
            // 文本输入上下文只对 key window 生效；App 未激活时按键到了输入框但不插入文字。
            print("SKIP 字母进入文本框（App 未激活）")
        }
        log.snapshot(window, "jump-field")
        await edit(kVK_Escape, editor, #selector(NSResponder.cancelOperation(_:)))
        log.check(window.firstResponder === first.pageView, "Esc 取消输入，焦点回到页面")
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
        secondWindow.makeFirstResponder(second.pageView)
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
