#if DEBUG
import AppKit
import MVCommands
import MVFoundation
import MVPipeline
import MVReading
import MVServices
import MVSettings

/// 设置窗口的自检（`-MVSettingsSelfTest YES -MVSelfTestFixtures <Fixtures目录>`，用真实服务）。
///
/// 覆盖全局默认值即时生效、书层不变、路径规则落盘与继承来源、解码上限和外部修改。
@MainActor
final class SettingsSelfTest {
    private let app: AppDelegate
    private let log = SelfTestLog()
    private let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "MacViewSettingsSelfTest-\(UUID().uuidString)", directoryHint: .isDirectory)

    static func runIfRequested(app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "MVSettingsSelfTest") else { return }
        let test = SettingsSelfTest(app: app)
        Task { await test.run() }
    }

    private init(app: AppDelegate) {
        self.app = app
    }

    private func run() async {
        NSApp.activate()
        guard let services = app.services, let controller = app.controllers.first, let window = controller.window,
              let path = UserDefaults.standard.string(forKey: "MVSelfTestFixtures") else {
            log.check(false, "设置自检需要真实服务、窗口与 -MVSelfTestFixtures")
            exit(log.summarize())
        }
        do {
            window.setContentSize(NSSize(width: 1200, height: 800))
            let book = try makeBook(fixtures: URL(fileURLWithPath: path))
            let session = controller.session
            controller.open([book.appending(path: "beta")])
            await until("书打开") { session.book?.isEnumerated == true && session.book?.pages.allSatisfy { $0.metadata != nil } == true }
            session.go(.index(2))
            await until("翻到第 3 页") { session.currentPage == 2 }

            try await singleWindow(services: services)
            guard let settings = app.openSettings() else { throw SelfTestFailure.message("打不开设置窗口") }
            try await globalDefaults(settings.state.model, session: session)
            try await pathRules(settings.state.model, book: book, session: session, services: services)
            try? await Task.sleep(for: .milliseconds(500))
            try await decodeLimit(settings.state.model, controller: controller, services: services)
            try await externalEdit(settings.state.model)
            await screenshots(settings)
        } catch {
            log.check(false, "设置自检失败：\(error)")
        }
        try? FileManager.default.removeItem(at: temporary)
        exit(log.summarize())
    }

    /// 全应用一个窗口，经命令打开。
    private func singleWindow(services: CoreServices) async throws {
        let before = NSApp.windows.count
        try await services.commands.perform(.settingsOpen, arguments: nil, context: CommandContext(session: nil, scope: .global, selection: []))
        let first = app.openSettings()
        try await services.commands.perform(.settingsOpen, arguments: nil, context: CommandContext(session: nil, scope: .global, selection: []))
        log.check(first === app.openSettings() && NSApp.windows.count == before + 1, "app.settings 只开一个窗口")
        log.check(first?.window?.isVisible == true, "设置窗口可见")
    }

    /// C2.14
    private func globalDefaults(_ model: SettingsModel, session: ReaderSession) async throws {
        await until("模型载入") { model.launchBrowseCacheEnabled != nil }
        let page = session.currentPage
        session.update { $0.direction = .rightToLeft }
        model.updateGlobal {
            $0.defaultBook.scaleMode = .fitWidth
            $0.defaultBook.direction = .leftToRight
        }
        await until("全局默认值生效") { session.settings.scaleMode == .fitWidth }
        log.check(session.settings.scaleMode == .fitWidth, "改全局默认值，打开的书立即按新值显示")
        log.check(session.currentPage == page, "改全局默认值后页不变：\(session.currentPage)")
        log.check(session.settings.direction == .rightToLeft, "书层覆盖不变")
        session.update { $0.direction = nil }
        model.updateGlobal { $0.defaultBook.scaleMode = .fitWindow }
    }

    /// C2.15
    private func pathRules(_ model: SettingsModel, book: URL, session: ReaderSession, services: CoreServices) async throws {
        guard let parent = await model.addRule(folder: book), let child = await model.addRule(folder: book.appending(path: "beta")) else {
            throw SelfTestFailure.message("新建规则失败")
        }
        model.rename(parent, to: "上层")
        model.updateOverrides(of: parent) { $0.pageMode = .double }
        await until("规则写入") { self.storedRules().contains { $0.name == "上层" && $0.settings.pageMode == .double } }
        let stored = storedRules()
        log.check(stored.map(\.id).contains(child) && stored.first { $0.id == parent }?.name == "上层", "新建和改名写进 path-rules.json")
        await until("规则对打开的书生效") { session.settings.pageMode == .double }
        log.check(session.settings.pageMode == .double, "规则对打开的书生效")
        let field = try requireField("pageMode")
        guard let childRule = model.rules.first(where: { $0.id == child }), let parentRule = model.rules.first(where: { $0.id == parent }) else {
            throw SelfTestFailure.message("规则不见了")
        }
        let doubleText = String(localized: "双页")
        let singleText = String(localized: "单页")
        log.check(model.origin(of: field, in: childRule).contains("上层") && model.origin(of: field, in: childRule).contains(doubleText), "继承来源是上层规则：\(model.origin(of: field, in: childRule))")
        log.check(model.origin(of: field, in: parentRule).contains(singleText), "上层规则的来源是全局：\(model.origin(of: field, in: parentRule))")
        log.check(model.displayedRules.first { $0.rule.id == child }?.depth == 1, "子规则缩进一层")
        model.delete(parent)
        await until("规则删除") { !self.storedRules().contains { $0.id == parent } }
        log.check(!storedRules().contains { $0.id == parent }, "删除写进 path-rules.json")
        if let rule = model.rules.first(where: { $0.id == child }) {
            log.check(model.origin(of: field, in: rule).contains(singleText), "删除上层后来源回到全局：\(model.origin(of: field, in: rule))")
        }
        await until("页模式回到单页") { session.settings.pageMode == .single }
        log.check(session.settings.pageMode == .single, "删除规则后打开的书回到全局值")
    }

    /// C2.16：预算由 MVServicesTests.memoryPressureAndBudgets 覆盖。
    private func decodeLimit(_ model: SettingsModel, controller: ReaderWindowController, services: CoreServices) async throws {
        let before = controller.viewer.paged.slots.first?.baseTarget.map { max($0.pixelSize.width, $0.pixelSize.height) } ?? 0
        log.check(before > 1024, "改之前的请求超过 1024：\(before)")
        model.setMaxDecodeLongSide(1024)
        let pipeline = services.pipeline as? FileImagePipeline
        await until("解码上限生效") {
            pipeline?.maxDecodeLongSide == 1024 && controller.session.maxDecodeLongSide == 1024
                && controller.viewer.paged.slots.first?.baseTarget.map { max($0.pixelSize.width, $0.pixelSize.height) <= 1024 } == true
        }
        log.check(pipeline?.maxDecodeLongSide == 1024, "管线的解码上限是 1024")
        let target = controller.viewer.paged.slots.first?.baseTarget
        log.check(target.map { max($0.pixelSize.width, $0.pixelSize.height) <= 1024 } == true, "查看器按新上限请求：\(String(describing: target?.pixelSize))")
        model.setMaxDecodeLongSide(10)
        log.check(model.global.maxDecodeLongSide == 1024, "太小的值夹到 1024")
    }

    /// 外部改 settings.json 后窗口内容更新。
    private func externalEdit(_ model: SettingsModel) async throws {
        await until("写入落盘") { (try? self.settingsDocument())?.contains("1024") == true }
        try await Task.sleep(for: .milliseconds(300))
        let file = app.supportDirectory.appending(path: "settings.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "\"maxDecodeLongSide\" : 1024", with: "\"maxDecodeLongSide\" : 2048").write(to: file, atomically: true, encoding: .utf8)
        await until("外部修改更新窗口") { model.global.maxDecodeLongSide == 2048 }
        log.check(model.global.maxDecodeLongSide == 2048, "外部改 settings.json 后窗口内容更新")
    }

    private func screenshots(_ settings: SettingsWindowController) async {
        guard let window = settings.window else { return }
        for page in SettingsPage.allCases {
            settings.state.page = page
            try? await Task.sleep(for: .milliseconds(200))
            log.snapshot(window, "settings-\(page.rawValue)")
        }
    }

    private func storedRules() -> [PathRule] {
        guard let data = try? Data(contentsOf: app.supportDirectory.appending(path: "path-rules.json")),
              let document = try? JSONDecoder().decode(StoredRules.self, from: data) else { return [] }
        return document.value
    }

    private func settingsDocument() throws -> String {
        try String(contentsOf: app.supportDirectory.appending(path: "settings.json"), encoding: .utf8)
    }

    private struct StoredRules: Decodable {
        let value: [PathRule]
    }

    private func requireField(_ id: String) throws -> OverrideField {
        guard let field = OverrideField.all.first(where: { $0.id == id }) else { throw SelfTestFailure.message("没有 \(id)") }
        return field
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        if !condition() { log.check(false, "等待超时：\(what)") }
    }

    private func makeBook(fixtures: URL) throws -> URL {
        let root = temporary.appending(path: "shelf", directoryHint: .isDirectory)
        let beta = root.appending(path: "beta", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        for index in 1...5 {
            guard let context = CGContext(
                data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw SelfTestFailure.message("画不出夹具") }
            context.setFillColor(NSColor(hue: CGFloat(index) / 6, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SelfTestFailure.message("画不出夹具")
            }
            try data.write(to: beta.appending(path: String(format: "%03d.png", index)))
        }
        return root
    }
}

private enum SelfTestFailure: Error {
    case message(String)
}
#endif
