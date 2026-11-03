import AppKit
import MVIO
import MVSettings
import Observation
import SwiftUI

/// 窗口的状态：当前页。
@MainActor
@Observable
final class SettingsWindowState {
    var page = SettingsPage.browse
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }
}

/// 全应用一个设置窗口。
@MainActor
final class SettingsWindowController: NSWindowController {
    let state: SettingsWindowState

    init(store: any SettingsStore, sources: any SourceRegistry, supportDirectory: URL, cacheDirectory: URL) {
        state = SettingsWindowState(model: SettingsModel(store: store, sources: sources, supportDirectory: supportDirectory, cacheDirectory: cacheDirectory))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true
        )
        window.title = String(localized: "设置")
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SettingsRootView(state: state))
        window.setContentSize(NSSize(width: 680, height: 620))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        Task { await state.model.loadAll() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
