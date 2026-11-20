import AppKit
import MVFoundation
import MVLayout
import MVReading
import MVSettings
import Observation

struct EffectsPanelSettings: Codable, Equatable {}

/// 停靠面板“效果”：实时调色、阅读背景与显示配置管理。
@MainActor
final class EffectsPanel: DockPanel {
    typealias Settings = EffectsPanelSettings

    private(set) var settings: EffectsPanelSettings
    var onSettingsChange: (() -> Void)?
    private(set) weak var owner: ReaderWindowController?
    let panelView = EffectsPanelView()
    var view: NSView { panelView }

    private var observedSession: SessionID?
    private var effectsObserver: NSObjectProtocol?
    private var colorPanelTarget: ColorPanelRelay?
    private var lastCustomColor = NSColor(srgbRed: 0x3B / 255, green: 0x4A / 255, blue: 0x5C / 255, alpha: 1)

    init(_ settings: EffectsPanelSettings?) {
        self.settings = settings ?? EffectsPanelSettings()
        panelView.onToggleEffects = { [weak self] enabled in
            guard let self, let owner else { return }
            owner.setEffectsEnabled(enabled)
            owner.content.statusBar.showMessage(
                enabled ? String(localized: "效果已打开") : String(localized: "效果已关闭，显示原图")
            )
        }
        panelView.onChangeAdjust = { [weak self] mutation in
            self?.updateColorAdjust(mutation)
        }
        panelView.onResetAll = { [weak self] in
            self?.updateColorAdjust { $0 = .identity }
        }
        panelView.onSelectBackground = { [weak self] background in
            self?.selectBackground(background)
        }
        panelView.onPickCustomColor = { [weak self] in
            self?.openColorPanel()
        }
    }

    isolated deinit {
        if let effectsObserver { NotificationCenter.default.removeObserver(effectsObserver) }
    }

    func bind(to window: ReaderWindowController?) {
        guard window !== owner else { return }
        if let effectsObserver {
            NotificationCenter.default.removeObserver(effectsObserver)
            self.effectsObserver = nil
        }
        owner = window
        observedSession = window?.session.id
        if let window {
            effectsObserver = NotificationCenter.default.addObserver(
                forName: ReaderWindowController.effectsEnabledDidChangeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderState() }
            }
        }
        observeSession()
    }

    func addOptions(to menu: NSMenu) {}

    private func observeSession() {
        guard let owner, let id = observedSession else {
            renderState()
            return
        }
        withObservationTracking {
            _ = owner.session.book
            _ = owner.session.settings
            _ = owner.session.isVirtualBook
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeSession()
            }
        }
        renderState()
    }

    private func renderState() {
        guard let owner else {
            panelView.apply(
                hasBook: false,
                isVirtualBook: false,
                effectsEnabled: true,
                adjust: .identity,
                background: .auto,
                customColor: lastCustomColor
            )
            return
        }
        let settings = owner.session.settings
        if case let .custom(red, green, blue) = settings.background {
            lastCustomColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        panelView.apply(
            hasBook: owner.session.book != nil,
            isVirtualBook: owner.session.isVirtualBook,
            effectsEnabled: owner.effectsEnabled,
            adjust: settings.effects.colorAdjust,
            background: settings.background,
            customColor: lastCustomColor
        )
    }

    private func updateColorAdjust(_ mutation: (inout ColorAdjust) -> Void) {
        guard let owner, owner.session.book != nil else { return }
        var chain = owner.session.settings.effects
        var adjust = chain.colorAdjust
        mutation(&adjust)
        chain.colorAdjust = adjust
        owner.session.update { $0.effects = chain }
    }

    private func selectBackground(_ background: ViewerBackground) {
        guard let owner, owner.session.book != nil else { return }
        if case let .custom(red, green, blue) = background {
            lastCustomColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        owner.session.update { $0.background = background }
    }

    private func openColorPanel() {
        guard let owner, owner.session.book != nil else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = lastCustomColor
        let relay = ColorPanelRelay { [weak self] color in
            guard let self, let srgb = color.usingColorSpace(.sRGB) else { return }
            self.selectBackground(.custom(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            ))
        }
        colorPanelTarget = relay
        panel.setTarget(relay)
        panel.setAction(#selector(ColorPanelRelay.colorChanged(_:)))
        panel.orderFront(nil)
    }
}

@MainActor
private final class ColorPanelRelay: NSObject {
    private let onColor: (NSColor) -> Void

    init(onColor: @escaping (NSColor) -> Void) {
        self.onColor = onColor
    }

    @objc func colorChanged(_ sender: NSColorPanel) {
        onColor(sender.color)
    }
}
