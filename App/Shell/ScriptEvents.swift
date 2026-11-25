import AppKit
import Foundation
import MVFoundation
import MVPlugins
import MVReading
import MVScripting
import MVServices

/// 将 App 的五个生命周期与阅读事件按需分发给 `ScriptRuntime` 与 `PluginHost`。
/// 无订阅者时不构造事件载荷、不调用运行时，确保翻页热路径零额外开销。
@MainActor
final class ScriptEvents {
    private weak var app: AppDelegate?
    private let services: CoreServices

    private var initialScanCompleted = false
    private var initialPluginsScanned = false
    private var startupPending = false
    private var startupDispatched = false
    private var pluginStartupDispatched = false

    /// 供自检验证：记录实际调用 `ScriptRuntime.dispatch` 与 `PluginHost.dispatch` 的次数。
    private(set) var dispatchCount = 0
    private(set) var dispatchCounts: [ScriptEventName: Int] = [:]
    private(set) var pluginDispatchCount = 0
    private(set) var pluginDispatchCounts: [ScriptEventName: Int] = [:]

    init(app: AppDelegate, services: CoreServices) {
        self.app = app
        self.services = services
    }

    func resetDispatchCounts() {
        dispatchCount = 0
        dispatchCounts.removeAll()
        pluginDispatchCount = 0
        pluginDispatchCounts.removeAll()
    }

    /// 首次异步脚本扫描完成后由 `ExtensionCommands` 调用，补发等待中的 `startup` 事件。
    func noteInitialScanCompleted() {
        guard !initialScanCompleted else { return }
        initialScanCompleted = true
        if startupPending && !startupDispatched {
            dispatchScriptStartupNow()
        }
    }

    /// 首次异步插件扫描完成后由 `PluginCoordinator` 调用，补发等待中的插件 `startup` 事件。
    func noteInitialPluginsScanned() {
        guard !initialPluginsScanned else { return }
        initialPluginsScanned = true
        if startupPending && !pluginStartupDispatched {
            dispatchPluginStartupNow()
        }
    }

    /// 全部窗口恢复且启动流程完成后调用一次。
    func notifyStartup() {
        startupPending = true
        if services.scriptLibrary != nil, services.scriptRuntime != nil, initialScanCompleted, !startupDispatched {
            dispatchScriptStartupNow()
        }
        if services.pluginLibrary != nil, services.pluginHost != nil, initialPluginsScanned, !pluginStartupDispatched {
            dispatchPluginStartupNow()
        }
    }

    func notifyBookOpened(location: Location, title: String, pageCount: Int, session: SessionID) {
        dispatch(.bookOpened, session: session) {
            [
                "location": .string(ScriptLocationCodec.token(for: location)),
                "title": .string(title),
                "pageCount": .number(Double(pageCount)),
            ]
        }
    }

    func notifyPageChanged(index: Int, location: Location, session: SessionID) {
        dispatch(.pageChanged, session: session) {
            [
                "index": .number(Double(index)),
                "location": .string(ScriptLocationCodec.token(for: location)),
            ]
        }
    }

    /// 翻页越界：`pageEnd` 有订阅者时分发事件，否则播放系统提示音保留原有反馈。
    func notifyPageEnd(direction: NavigationDirection, session: SessionID) {
        let dispatched = dispatch(.pageEnd, session: session) {
            [
                "direction": .string(direction == .forward ? "forward" : "backward"),
            ]
        }
        if !dispatched {
            NSSound.beep()
        }
    }

    func notifyWindowStateChanged(isFullScreen: Bool, session: SessionID) {
        dispatch(.windowStateChanged, session: session) {
            [
                "state": .string(isFullScreen ? "fullScreen" : "normal"),
            ]
        }
    }

    private func dispatchScriptStartupNow() {
        guard !startupDispatched else { return }
        startupDispatched = true
        guard let runtime = services.scriptRuntime, runtime.hasSubscribers(for: .startup) else { return }
        let session = (app?.mainController ?? app?.activeReaderController)?.session.id
        dispatchCount += 1
        dispatchCounts[.startup, default: 0] += 1
        runtime.dispatch(.startup, payload: [:], session: session)
    }

    private func dispatchPluginStartupNow() {
        guard !pluginStartupDispatched else { return }
        pluginStartupDispatched = true
        guard let host = services.pluginHost, host.hasSubscribers(for: .startup) else { return }
        let session = (app?.mainController ?? app?.activeReaderController)?.session.id
        pluginDispatchCount += 1
        pluginDispatchCounts[.startup, default: 0] += 1
        host.dispatch(.startup, payload: [:], session: session)
    }

    @discardableResult
    private func dispatch(
        _ event: ScriptEventName,
        session: SessionID?,
        payload: () -> [String: JSONValue]
    ) -> Bool {
        let hasScripts = services.scriptRuntime?.hasSubscribers(for: event) == true
        let hasPlugins = services.pluginHost?.hasSubscribers(for: event) == true
        guard hasScripts || hasPlugins else {
            return false
        }
        let data = payload()
        if hasScripts, let runtime = services.scriptRuntime {
            dispatchCount += 1
            dispatchCounts[event, default: 0] += 1
            runtime.dispatch(event, payload: data, session: session)
        }
        if hasPlugins, let host = services.pluginHost {
            pluginDispatchCount += 1
            pluginDispatchCounts[event, default: 0] += 1
            host.dispatch(event, payload: data, session: session)
        }
        return true
    }
}
