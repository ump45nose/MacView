#if DEBUG
import AppKit

/// 测试实例不打扰用户：窗口开在刷新率最高的屏（本机是内置屏），只用 `orderFrontRegardless` 抬到最上面，不抢前台。
/// 离不开键盘焦点的自检检查只在 `-MVSelfTestActivate YES` 时激活 App，默认不激活。
@MainActor
enum TestPresentation {
    static let activateKey = "MVSelfTestActivate"

    static var isTestInstance: Bool {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: "MVDebugSocket") != nil
            || defaults.string(forKey: "MVSessionSelfTest") != nil
            || defaults.string(forKey: DockSelfTest.launchKey) != nil
            || defaults.string(forKey: EffectsSelfTest.launchKey) != nil
            || FileOpsSelfTest.isRequested
            || [SelfTest.launchKey, "MVViewerSelfTest", "MVPanelSelfTest", "MVSettingsSelfTest", LibrarySelfTest.launchKey, SearchSelfTest.launchKey, CanvasTestWindowController.launchKey].contains { defaults.bool(forKey: $0) }
    }

    /// 自检的临时文件放进本次运行的隔离 support 目录（测试实例启动时已检查必须传 `-MVSupportDirectory`），不落系统临时目录。
    static func scratchDirectory(_ name: String) -> URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: AppDelegate.supportDirectoryKey)!)
            .appending(path: "selftest-tmp/\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static var activationAllowed: Bool { UserDefaults.standard.bool(forKey: activateKey) }

    static var screen: NSScreen? { NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond } }

    static func activateIfAllowed() {
        if activationAllowed { NSApp.activate() }
    }

    /// 放到测试屏的可见区域中央。
    static func place(_ window: NSWindow) {
        guard let visible = screen?.visibleFrame else { window.center(); return }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
    }

    /// 测试实例的窗口出现时调用：不在测试屏上就挪过去，再抬到最上面。
    static func present(_ window: NSWindow?) {
        guard let window, isTestInstance else { return }
        if let frame = screen?.frame, !frame.contains(window.frame) { place(window) }
        window.orderFrontRegardless()
    }

    static func isBuiltin(_ screen: NSScreen?) -> Bool {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }

    static func displayID(_ screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
#endif
