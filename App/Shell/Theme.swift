import AppKit

/// 设计稿“设计基础”中的颜色令牌，随系统外观切换浅色（Ivory）与深色（Slate）。只收录外壳用到的几项。
@MainActor
enum Theme {
    static let ground = color(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let canvas = color(light: 0xF0EEE6, dark: 0x1A1918)
    static let raised = color(light: 0xFFFFFF, dark: 0x30302E)
    static let hud = color(light: 0xFFFFFF, lightAlpha: 0.94, dark: 0x141413, darkAlpha: 0.9)
    static let text = color(light: 0x141413, dark: 0xFAF9F5)
    static let text2 = color(light: 0x5E5D59, dark: 0xC2C0B6)
    static let text3 = color(light: 0x73726C, dark: 0x9C9A92)
    static let line = color(light: 0x1F1E1D, lightAlpha: 0.15, dark: 0xDEDCD1, darkAlpha: 0.13)
    static let lineStrong = color(light: 0x1F1E1D, lightAlpha: 0.3, dark: 0xDEDCD1, darkAlpha: 0.26)
    static let primary = color(light: 0x141413, dark: 0xFAF9F5)
    static let onPrimary = color(light: 0xFAF9F5, dark: 0x141413)
    static let danger = color(light: 0xA33B2A, dark: 0xF09C8B)
    static let dangerSoft = color(light: 0xA33B2A, lightAlpha: 0.08, dark: 0xF09C8B, darkAlpha: 0.12)
    static let well = color(light: 0xF5F4ED, dark: 0x262624)
    static let selected = color(light: 0x73726C, lightAlpha: 0.16, dark: 0xF0EEE6, darkAlpha: 0.12)
    /// Clay：只作强调色（放置指示、焦点），浅色模式下不用作文字。
    static let accent = color(light: 0xD97757, dark: 0xD97757)
    static let accentSoft = color(light: 0xD97757, lightAlpha: 0.14, dark: 0xD97757, darkAlpha: 0.2)

    /// 衬线字体（New York / 宋体），用于标题和空状态。
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
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
