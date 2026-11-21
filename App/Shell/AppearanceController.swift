import AppKit
import MVSettings
import os

/// 外观控制器：唯一把 `GlobalSettings.appearance` 套用到界面的地方。
///
/// 命令和设置页都只通过 `update(_:)` 写 `settings.json`，由本控制器监听 `SettingsChange.global` 后统一套用到
/// 已注册的阅读窗口与浮动面板；外部改文件热重载走同一条路径。
@MainActor
final class AppearanceController {
    private struct Registration {
        weak var controller: ReaderWindowController?
        let closeObserver: NSObjectProtocol
    }

    private let store: any SettingsStore
    private let logger = Logger(category: "appearance")
    private(set) var current: AppearanceSettings = .default
    private(set) var hasApplied = false
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private weak var dock: DockCoordinator?
    private var observeTask: Task<Void, Never>?
    private var systemColorsObserver: NSObjectProtocol?

    init(store: any SettingsStore) {
        self.store = store
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSystemColorsDidChange()
            }
        }
    }

    isolated deinit {
        observeTask?.cancel()
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
        for registration in registrations.values {
            NotificationCenter.default.removeObserver(registration.closeObserver)
        }
    }

    /// 绑定停靠协调者，让浮动面板跟随置顶设置。
    func attach(dock: DockCoordinator) {
        self.dock = dock
        dock.setKeepOnTop(current.window.keepOnTop)
    }

    /// 读取当前全局设置并套用，然后订阅 `SettingsChange.global`。
    func start() {
        observeTask?.cancel()
        let changes = store.changes()
        observeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let initial = await store.global().appearance
            guard !Task.isCancelled else { return }
            apply(initial, animated: false)
            for await change in changes {
                guard !Task.isCancelled else { return }
                guard change == .global else { continue }
                let updated = await store.global().appearance
                guard !Task.isCancelled else { return }
                apply(updated, animated: true)
            }
        }
    }

    /// 注册阅读窗口：立即按当前设置快照套用；窗口关闭时自动移除。
    func register(_ window: ReaderWindowController) {
        let key = ObjectIdentifier(window)
        if registrations[key] != nil {
            window.chrome.apply(current.window, animated: false)
            return
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.unregister(key)
            }
        }
        registrations[key] = Registration(controller: window, closeObserver: token)
        window.chrome.apply(current.window, animated: false)
    }

    /// 命令用：写入 `settings.json`，不直接改界面（等待 `SettingsChange.global` 统一套用）。
    func update(_ change: @escaping @Sendable (inout AppearanceSettings) -> Void) {
        let store = self.store
        let logger = self.logger
        Task {
            do {
                try await store.updateGlobal { settings in
                    change(&settings.appearance)
                }
            } catch {
                logger.error("写入外观设置失败：\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func unregister(_ key: ObjectIdentifier) {
        if let registration = registrations.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(registration.closeObserver)
        }
    }

    private func pruneDeadRegistrations() {
        for (key, registration) in registrations where registration.controller == nil {
            NotificationCenter.default.removeObserver(registration.closeObserver)
            registrations.removeValue(forKey: key)
        }
    }

    private static var hasDebugAppearanceOverride: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "MVAppearance") != nil
        #else
        false
        #endif
    }

    private func apply(_ next: AppearanceSettings, animated: Bool) {
        let previous = current
        let isInitial = !hasApplied
        hasApplied = true
        current = next
        pruneDeadRegistrations()

        if isInitial || previous.mode != next.mode {
            applyMode(next.mode)
        }

        if isInitial || previous.accent != next.accent {
            let accentChanged = Theme.accentMode != next.accent
            Theme.accentMode = next.accent
            if accentChanged {
                refreshAllWindowsAppearance()
            }
        }

        if isInitial || previous.window != next.window {
            for registration in registrations.values {
                registration.controller?.chrome.apply(next.window, animated: animated)
            }
            dock?.setKeepOnTop(next.window.keepOnTop)
        }
    }

    private func applyMode(_ mode: AppearanceMode) {
        guard !Self.hasDebugAppearanceOverride else { return }
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func handleSystemColorsDidChange() {
        guard current.accent == .system else { return }
        refreshAllWindowsAppearance()
    }

    /// 临时切换并恢复每个窗口的外观，触发子视图的 `viewDidChangeEffectiveAppearance` 与 `updateLayer`。
    private func refreshAllWindowsAppearance() {
        for window in NSApp.windows {
            let saved = window.appearance
            let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            window.appearance = NSAppearance(named: isDark ? .aqua : .darkAqua)
            window.appearance = saved
            window.contentView?.needsDisplay = true
        }
    }
}
