#if DEBUG
import AppKit
import MVFoundation
import MVIO
import MVReading
import MVSettings
import MVTestSupport

/// 会话恢复与错误显示的自检（`-MVSessionSelfTest <阶段>`）。
///
/// 书放在 `-MVSessionBooks <目录>`，配置放在 `-MVSupportDirectory`，同一目录分次启动：
/// `write` 打开窗口、翻页后 `kill -9` 自己；`verify` 检查恢复；`missing` 检查书不在时的显示；
/// `corrupt` 检查 session.json 写坏；`settings` 检查配置错误条；`volume` 用 Mock 检查卷状态。
@MainActor
final class SessionSelfTest {
    private let app: AppDelegate
    private let log = SelfTestLog()
    private let books: URL?
    private static let expected = [(name: "one", page: 2), (name: "two", page: 3), (name: "three", page: 4)]

    static func runIfRequested(app: AppDelegate) {
        guard let phase = UserDefaults.standard.string(forKey: "MVSessionSelfTest") else { return }
        let test = SessionSelfTest(app: app)
        Task {
            await test.run(phase)
            exit(test.log.summarize())
        }
    }

    private init(app: AppDelegate) {
        self.app = app
        books = UserDefaults.standard.string(forKey: "MVSessionBooks").map { URL(fileURLWithPath: $0) }
    }

    private func run(_ phase: String) async {
        TestPresentation.activateIfAllowed()
        do {
            switch phase {
            case "write": try await write()
            case "verify": await verify()
            case "missing": await missing()
            case "corrupt": try await corrupt()
            case "settings": try await settingsErrors()
            case "volume": await volume()
            default: log.check(false, "未知阶段 \(phase)")
            }
        } catch {
            log.check(false, "会话自检失败：\(error)")
        }
    }

    /// 两个窗口，其中一个两个标签，翻到不同的页，kill -9。
    private func write() async throws {
        guard let books, let first = app.controllers.first, let second = app.newWindow() else { throw Failure.setup }
        for book in Self.expected { try makeBook(book.name) }
        guard let tab = app.newTab(beside: first) else { throw Failure.setup }
        // 相对测试屏摆放，不落到用户的主屏上。
        let origin = TestPresentation.screen?.visibleFrame.origin ?? .zero
        tab.window?.setFrame(NSRect(x: origin.x + 80, y: origin.y + 120, width: 1000, height: 700), display: true)
        second.window?.setFrame(NSRect(x: origin.x + 240, y: origin.y + 60, width: 900, height: 640), display: true)
        let targets = zip([first, tab, second], Self.expected)
        for (controller, book) in targets {
            controller.open([books.appending(path: book.name)])
            await until("\(book.name) 打开") { controller.session.book?.isEnumerated == true && !controller.session.frames.isEmpty }
            controller.session.go(.index(book.page))
        }
        await until("翻到目标页") { targets.allSatisfy { $0.0.session.currentPage == $0.1.page } }
        second.window?.makeKeyAndOrderFront(nil)
        // 书记忆去抖 1 秒，会话去抖 500 ms。
        try await Task.sleep(for: .seconds(2.5))
        print("INFO 写入完成，kill -9")
        fflush(stdout)
        kill(getpid(), SIGKILL)
    }

    private func verify() async {
        let controllers = app.controllers
        await until("恢复书和页") {
            Self.expected.allSatisfy { book in
                controllers.contains { $0.session.book?.location.name == book.name && $0.session.currentPage == book.page && !$0.session.frames.isEmpty }
            }
        }
        for book in Self.expected {
            let page = controllers.first { $0.session.book?.location.name == book.name }?.session.currentPage
            log.check(page == book.page, "\(book.name) 恢复到第 \(book.page + 1) 页：\(page.map(String.init) ?? "没有")")
        }
        let opened = UserDefaults.standard.string(forKey: "MVSelfTestOpenAtLaunch") != nil
        log.check(controllers.count == (opened ? 4 : 3), "恢复三个标签\(opened ? "，另开一个" : "")：\(controllers.count)")
        var groups: [[String]] = []
        var seen = Set<ObjectIdentifier>()
        for window in controllers.compactMap(\.window) {
            guard let group = window.tabGroup, seen.insert(ObjectIdentifier(group)).inserted else { continue }
            groups.append(group.windows.compactMap { ($0.windowController as? ReaderWindowController)?.session.book?.location.name })
        }
        log.check(groups.contains(["one", "two"]) && groups.contains(opened ? ["three", "extra"] : ["three"]) && groups.count == 2, "标签分组与顺序：\(groups)")
        let one = controllers.first { $0.session.book?.location.name == "one" }
        let frame = one?.window?.frame ?? .zero
        log.check(frame.width == 1000 && frame.height == 700, "窗口 frame 恢复：\(frame)")
        let front = NSApp.orderedWindows.first?.windowController as? ReaderWindowController
        log.check(["three", "extra"].contains(front?.session.book?.location.name ?? ""), "最前面的窗口仍在最前：\(front?.session.book?.location.name ?? "")")
    }

    /// 书被删掉：窗口仍恢复，显示错误和重试，位置不丢；书回来后重试能打开。
    private func missing() async {
        let controllers = app.controllers
        await until("恢复 two") { controllers.contains { $0.session.book?.location.name == "two" } }
        guard let controller = controllers.first(where: { $0.session.book?.location.name == "two" }) else {
            return log.check(false, "two 的窗口没有恢复")
        }
        await until("显示错误") { controller.session.loadError != nil }
        log.check(controller.session.loadError != nil, "书不在时有错误：\(controller.session.loadError.map(ErrorText.describe) ?? "")")
        log.check(controller.session.book?.location.name == "two", "书的位置不丢")
        log.check(controllers.count == 3, "窗口仍恢复：\(controllers.count)")
        do { try makeBook("two") } catch { return log.check(false, "恢复书失败：\(error)") }
        controller.viewer.retryFailed()
        await until("重试后打开") { controller.session.loadError == nil && !controller.session.frames.isEmpty }
        log.check(controller.session.loadError == nil && controller.session.currentPage == 3, "重试后回到原来的页：\(controller.session.currentPage)")
    }

    /// session.json 写坏：开一个空窗口并显示错误条，不覆盖坏文件；修好后错误条消失。
    private func corrupt() async throws {
        guard let controller = app.controllers.first else { throw Failure.setup }
        await until("显示 session.json 错误") { controller.content.fileErrorBanners[SessionStore.fileName] != nil }
        log.check(controller.content.fileErrorBanners[SessionStore.fileName] != nil, "session.json 写坏时显示错误条")
        log.check(app.controllers.count == 1 && controller.session.book == nil, "开一个空窗口")
        let file = app.supportDirectory.appending(path: SessionStore.fileName)
        let broken = try Data(contentsOf: file)
        app.scheduleSessionSave()
        try await Task.sleep(for: .seconds(1))
        log.check(try Data(contentsOf: file) == broken, "坏文件没有被覆盖")
        try Data(#"{ "version": 1, "value": { "windows": [] } }"#.utf8).write(to: file, options: .atomic)
        await until("错误条消失") { controller.content.fileErrorBanners[SessionStore.fileName] == nil }
        log.check(controller.content.fileErrorBanners[SessionStore.fileName] == nil, "修好后错误条消失")
    }

    /// C2.18：按文件各一条，含打开文件，修好后消失；缺字段的文字跟随界面语言。
    private func settingsErrors() async throws {
        guard let controller = app.controllers.first else { throw Failure.setup }
        let file = app.supportDirectory.appending(path: "settings.json")
        let rules = app.supportDirectory.appending(path: "path-rules.json")
        let good = try JSONEncoder().encode(GoodSettings(version: 1, value: .default))
        try good.write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(500))
        try Data("{ broken".utf8).write(to: file, options: .atomic)
        try Data("{ broken".utf8).write(to: rules, options: .atomic)
        await until("两条错误") { controller.content.fileErrorBanners.count == 2 }
        log.check(controller.content.fileErrorBanners["settings.json"] != nil && controller.content.fileErrorBanners["path-rules.json"] != nil, "按文件各一条错误条")
        try await Task.sleep(for: .milliseconds(200))
        if let window = controller.window { log.snapshot(window, "file-errors") }
        log.check(texts(in: controller.content.fileErrorBanners["settings.json"]).contains(String(localized: "打开文件")), "错误条有打开文件")
        try Data(#"{ "version": 1, "value": [] }"#.utf8).write(to: rules, options: .atomic)
        await until("规则修好") { controller.content.fileErrorBanners["path-rules.json"] == nil }
        log.check(controller.content.fileErrorBanners["path-rules.json"] == nil && controller.content.fileErrorBanners["settings.json"] != nil, "修好一个只消失一条")
        try good.write(to: file, options: .atomic)
        await until("设置修好") { controller.content.fileErrorBanners["settings.json"] == nil }
        log.check(controller.content.fileErrorBanners.isEmpty, "全部修好后错误条消失")

        try Data(#"{ "version": 1, "value": { "maxDecodeLongSide": 4096 } }"#.utf8).write(to: file, options: .atomic)
        await until("缺字段提示") { controller.content.fileErrorBanners["settings.json"] != nil }
        let detail = texts(in: controller.content.fileErrorBanners["settings.json"]).joined(separator: " ")
        print("INFO 缺字段：\(detail)")
        if Locale.preferredLanguages.first?.hasPrefix("en") == true || Bundle.main.preferredLocalizations.first == "en" {
            log.check(detail.range(of: "\\p{Han}", options: .regularExpression) == nil, "英文界面的错误条是英文")
        }
    }

    private func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var result: [String] = []
        if let field = view as? NSTextField { result.append(field.stringValue) }
        if let button = view as? NSButton { result.append(button.title) }
        for child in view.subviews { result += texts(in: child) }
        return result
    }

    /// C2.19：Mock 的卷切到 degraded、unavailable 时状态可见；失败项重试后显示。
    private func volume() async {
        guard let controller = app.controllers.first, let environment = (app.services?.sources as? MockSourceRegistry)?.environment,
              let window = controller.window else { return log.check(false, "卷自检需要 Mock 服务") }
        window.setContentSize(NSSize(width: 1000, height: 700))
        let book = environment.rootLocation.appending("画集").appending("系列 A").appending("第 1 卷")
        controller.openBook(book)
        await until("书打开") { controller.session.book?.isEnumerated == true && !controller.session.frames.isEmpty }
        log.check(!controller.session.frames.isEmpty, "书打开：\(book)")
        let banner = controller.content.volumeStatus

        environment.setVolumeState(.degraded("超时次数过多"))
        await until("显示响应缓慢") { !banner.isHidden }
        log.check(!banner.isHidden && controller.content.statusBar.volumeStatus != nil, "degraded 状态可见：\(controller.content.statusBar.volumeStatus ?? "")")
        log.snapshot(window, "volume-degraded")

        environment.setVolumeState(.unavailable)
        await until("显示无法访问") { controller.content.statusBar.volumeStatus?.contains(String(localized: "无法访问")) == true || controller.content.statusBar.volumeStatus?.contains("Unavailable") == true }
        log.check(!banner.isHidden, "unavailable 状态可见：\(controller.content.statusBar.volumeStatus ?? "")")
        controller.session.go(.index(6))
        let failed = await waitFailed(controller)
        log.check(failed, "卷不可用时新页失败")
        log.snapshot(window, "volume-unavailable")

        // 手动重试：卷恢复但这里先不走自动恢复的路径。
        environment.setVolumeState(.healthy)
        await until("提示消失") { banner.isHidden }
        log.check(banner.isHidden && controller.content.statusBar.volumeStatus == nil, "恢复后状态消失")
        controller.viewer.retryFailed()
        await until("失败项重试后显示") { controller.viewer.paged.slots.first?.failure == nil && controller.viewer.paged.slots.first?.hasImage == true }
        log.check(controller.viewer.paged.slots.first?.failure == nil && controller.viewer.paged.slots.first?.hasImage == true, "失败项重试后显示")

        // 打开书时卷不可用：错误留在查看器，书的位置不丢。
        environment.setVolumeState(.unavailable)
        await until("状态") { !banner.isHidden }
        controller.openBook(environment.rootLocation.appending("画集").appending("系列 A").appending("第 2 卷"))
        await until("打开失败") { controller.session.loadError != nil }
        log.check(controller.session.loadError != nil && controller.session.book?.location.name == "第 2 卷", "卷不可用时打开：错误显示，位置保留")
        log.check(banner.isHidden, "查看器已显示时不再重复提示条")
        log.snapshot(window, "volume-open-failed")
        environment.setVolumeState(.healthy)
        await until("自动恢复") { controller.session.loadError == nil && !controller.session.frames.isEmpty }
        log.check(controller.session.loadError == nil && !controller.session.frames.isEmpty, "探测成功后自动重开")
    }

    private func waitFailed(_ controller: ReaderWindowController) async -> Bool {
        for _ in 0..<200 {
            if controller.viewer.paged.slots.first?.failure != nil { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func makeBook(_ name: String) throws {
        guard let books else { throw Failure.setup }
        let book = books.appending(path: name)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        for index in 1...6 {
            guard let context = CGContext(
                data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw Failure.setup }
            context.setFillColor(NSColor(hue: CGFloat(index) / 7, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.setup }
            try data.write(to: book.appending(path: String(format: "%03d.png", index)))
        }
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        if !condition() { log.check(false, "等待超时：\(what)") }
    }

    private struct GoodSettings: Encodable {
        let version: Int
        let value: GlobalSettings
    }

    private enum Failure: Error {
        case setup
    }
}
#endif
