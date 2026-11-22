import AppKit
import MVSettings
import os

/// 设计稿“设计基础”中的颜色令牌，随系统外观切换浅色（Ivory）与深色（Slate）。只收录外壳用到的几项。
@MainActor
enum Theme {
    private nonisolated static let accentModeLock = OSAllocatedUnfairLock(initialState: AccentColorMode.clay)

    /// 当前强调色模式，由 `AppearanceController` 同步。
    static var accentMode: AccentColorMode {
        get { accentModeLock.withLock { $0 } }
        set { accentModeLock.withLock { $0 = newValue } }
    }
    static let ground = color(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let canvas = color(light: 0xF0EEE6, dark: 0x1A1918)
    static let raised = color(light: 0xFFFFFF, dark: 0x30302E)
    static let hud = color(light: 0xFFFFFF, lightAlpha: 0.94, dark: 0x141413, darkAlpha: 0.9)
    static let text = color(light: 0x141413, dark: 0xFAF9F5)
    static let text2 = color(light: 0x5E5D59, dark: 0xC2C0B6)
    static let line = color(light: 0x1F1E1D, lightAlpha: 0.15, dark: 0xDEDCD1, darkAlpha: 0.13)
    static let lineStrong = color(light: 0x1F1E1D, lightAlpha: 0.3, dark: 0xDEDCD1, darkAlpha: 0.26)
    static let primary = color(light: 0x141413, dark: 0xFAF9F5)
    static let onPrimary = color(light: 0xFAF9F5, dark: 0x141413)
    static let danger = color(light: 0xA33B2A, dark: 0xF09C8B)
    static let onDanger = color(light: 0xFFFFFF, dark: 0x141413)
    static let dangerSoft = color(light: 0xA33B2A, lightAlpha: 0.08, dark: 0xF09C8B, darkAlpha: 0.12)
    static let well = color(light: 0xF5F4ED, dark: 0x262624)
    static let selected = color(light: 0x73726C, lightAlpha: 0.16, dark: 0xF0EEE6, darkAlpha: 0.12)
    /// 强调色（放置指示、焦点等）：按 `accentMode` 返回 Clay 或系统 `controlAccentColor`；浅色模式下不用作文字。
    static let accent = NSColor(name: nil) { appearance in
        switch accentModeLock.withLock({ $0 }) {
        case .clay:
            rgb(0xD97757, 1)
        case .system:
            resolveControlAccent(in: appearance)
        }
    }
    static let accentSoft = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha: CGFloat = isDark ? 0.2 : 0.14
        switch accentModeLock.withLock({ $0 }) {
        case .clay:
            return rgb(0xD97757, alpha)
        case .system:
            return resolveControlAccent(in: appearance).withAlphaComponent(alpha)
        }
    }
    static let star = color(light: 0xC2643F, dark: 0xE39A77)

    /// 衬线字体（New York / 宋体），用于标题和空状态。
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// 当前三组字体设置，由 `AppearanceController` 同步。
    static var fonts: [FontRole: FontSpec] = [:]

    /// `AppearanceController` 在 `fonts` 变化后发出。
    static let fontsDidChange = Notification.Name("MacView.Theme.fontsDidChange")

    /// 各组默认基准字号：panels 12、overlays 12、menus = 系统菜单字号。
    static func defaultSize(_ role: FontRole) -> CGFloat {
        switch role {
        case .panels: 12
        case .overlays: 12
        case .menus: NSFont.menuFont(ofSize: 0).pointSize
        }
    }

    /// 组缩放比 = 组字号 / 组默认字号（未设置时为 1）。
    static func fontScale(_ role: FontRole) -> CGFloat {
        let base = defaultSize(role)
        guard let custom = fonts[role]?.size, base > 0 else { return 1 }
        return CGFloat(custom) / base
    }

    /// 按给定 `FontSpec`（nil 为系统默认）解析字体，供设置页预览与 `font(_:size:weight:monospacedDigits:)` 共用。
    static func resolveFont(
        for role: FontRole,
        spec: FontSpec?,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospacedDigits: Bool = false
    ) -> NSFont {
        let base = defaultSize(role)
        let scale = (spec?.size).flatMap { base > 0 ? CGFloat($0) / base : nil } ?? 1
        let targetSize = scale == 1 ? size : (size * scale * 2).rounded() / 2
        if let rawFamily = spec?.family?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawFamily.isEmpty,
           let custom = customFont(family: rawFamily, size: targetSize, weight: weight) {
            return monospacedDigits ? withMonospacedDigits(custom) : custom
        }
        if monospacedDigits {
            return NSFont.monospacedDigitSystemFont(ofSize: targetSize, weight: weight)
        }
        if role == .menus, weight == .regular {
            return NSFont.menuFont(ofSize: targetSize)
        }
        return NSFont.systemFont(ofSize: targetSize, weight: weight)
    }

    /// 按组返回字体：组内字体族（nil = 系统字体）与缩放比 = 组字号 / 组默认字号。
    static func font(_ role: FontRole, size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        resolveFont(for: role, spec: fonts[role], size: size, weight: weight, monospacedDigits: monospacedDigits)
    }

    /// 递归为菜单（及其子菜单）套用菜单组字体；主菜单栏本身传 `includeRoot: false` 以保持顶层标题不变。
    static func applyMenuFont(to menu: NSMenu, includeRoot: Bool = true) {
        let menuFont = font(.menus, size: defaultSize(.menus))
        if includeRoot {
            menu.font = menuFont
        }
        for item in menu.items {
            if let submenu = item.submenu {
                applyMenuFont(to: submenu, includeRoot: true)
            }
        }
    }

    private static func fontManagerWeight(for weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: 2
        case .thin: 3
        case .light: 4
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 11
        case .black: 12
        default:
            if weight.rawValue <= NSFont.Weight.light.rawValue { 4 }
            else if weight.rawValue < NSFont.Weight.medium.rawValue { 5 }
            else if weight.rawValue < NSFont.Weight.semibold.rawValue { 6 }
            else if weight.rawValue < NSFont.Weight.bold.rawValue { 8 }
            else { 9 }
        }
    }

    private static func customFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let manager = NSFontManager.shared
        guard let members = manager.availableMembers(ofFontFamily: family), !members.isEmpty else {
            return nil
        }
        let targetWeight = fontManagerWeight(for: weight)
        var bestPostScript: String?
        var bestScore = Int.max
        for member in members {
            guard member.count >= 4,
                  let psName = member[0] as? String,
                  let memberWeight = member[2] as? Int,
                  let traitsRaw = member[3] as? UInt else { continue }
            let traits = NSFontTraitMask(rawValue: traitsRaw)
            let italicPenalty = traits.contains(.italicFontMask) ? 1000 : 0
            let condensedPenalty = (traits.contains(.condensedFontMask) || traits.contains(.narrowFontMask)) ? 100 : 0
            let score = italicPenalty + condensedPenalty + abs(memberWeight - targetWeight)
            if score < bestScore {
                bestScore = score
                bestPostScript = psName
            }
        }
        return bestPostScript.flatMap { NSFont(name: $0, size: size) }
    }

    private static func withMonospacedDigits(_ font: NSFont) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Any]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    nonisolated private static func resolveControlAccent(in appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = .controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        }
        return resolved
    }

    nonisolated private static func color(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }

    nonisolated private static func rgb(_ value: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha
        )
    }
}
