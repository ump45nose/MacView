import AppKit
import Foundation
import MVFoundation
import MVReading
import MVScripting
import MVServices

/// 将 App 的五个生命周期与阅读事件按需分发给 `ScriptRuntime`。
/// 无订阅者时不构造事件载荷、不调用运行时，确保翻页热路径零额外开销。
@MainActor
final class ScriptEvents {
    private weak var app: AppDelegate?
    private let services: CoreServices

    private var initialScanCompleted = false
    private var startupPending = false
    private var startupDispatched = false

    /// 供自检（C2.12）验证：记录实际调用 `ScriptRuntime.dispatch` 的次数。
    private(set) var dispatchCount = 0
    private(set) var dispatchCounts: [ScriptEventName: Int] = [:]

    init(app: AppDelegate, services: CoreServices) {
        self.app = app
        self.services = services
    }

    func resetDispatchCounts() {
        dispatchCount = 0
        dispatchCounts.removeAll()
    }

    /// 首次异步脚本扫描完成后由 `ExtensionCommands` 调用，补发等待中的 `startup` 事件。
    func noteInitialScanCompleted() {
        guard !initialScanCompleted else { return }
        initialScanCompleted = true
        if startupPending && !startupDispatched {
            startupPending = false
            dispatchStartupNow()
        }
    }

    /// 全部窗口恢复且启动流程完成后调用一次。
    func notifyStartup() {
        guard !startupDispatched, services.scriptLibrary != nil, services.scriptRuntime != nil else { return }
        if initialScanCompleted {
            dispatchStartupNow()
        } else {
            startupPending = true
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

    private func dispatchStartupNow() {
        guard !startupDispatched else { return }
        startupDispatched = true
        let session = (app?.mainController ?? app?.activeReaderController)?.session.id
        dispatch(.startup, session: session) { [:] }
    }

    @discardableResult
    private func dispatch(
        _ event: ScriptEventName,
        session: SessionID?,
        payload: () -> [String: JSONValue]
    ) -> Bool {
        guard let runtime = services.scriptRuntime,
              runtime.hasSubscribers(for: event) else {
            return false
        }
        dispatchCount += 1
        dispatchCounts[event, default: 0] += 1
        runtime.dispatch(event, payload: payload(), session: session)
        return true
    }
}
