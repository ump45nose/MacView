import AppKit
import MVFoundation
import MVReading
import MVSettings

/// 显示配置组名称、当前值摘要与套用辅助函数。
@MainActor
enum DisplayProfileHelpers {
    static let orderedGroups: [DisplayProfileGroup] = [.layout, .scale, .effects, .background]

    static func title(of group: DisplayProfileGroup) -> String {
        switch group {
        case .layout: String(localized: "浏览方式与页面")
        case .scale: String(localized: "缩放与重采样")
        case .effects: String(localized: "效果")
        case .background: String(localized: "背景")
        }
    }

    static func groupListText(_ groups: Set<DisplayProfileGroup>) -> String {
        let separator = String(localized: "、")
        return orderedGroups.filter { groups.contains($0) }.map(title(of:)).joined(separator: separator)
    }

    static func summary(of group: DisplayProfileGroup, in settings: ResolvedBookSettings) -> String {
        switch group {
        case .layout:
            var parts: [String] = []
            switch settings.browseMode {
            case .paged:
                parts.append(settings.pageMode == .double ? String(localized: "双页") : String(localized: "单页"))
            case .waterfall: parts.append(String(localized: "瀑布流"))
            case .verticalStrip: parts.append(String(localized: "纵向连续"))
            case .horizontalStrip: parts.append(String(localized: "横向连续"))
            }
            parts.append(settings.direction == .rightToLeft ? String(localized: "右开") : String(localized: "左开"))
            if settings.browseMode == .paged && settings.pageMode == .double && settings.firstPageSingle {
                parts.append(String(localized: "首页单页"))
            }
            return parts.joined(separator: " · ")

        case .scale:
            let scaleName: String = switch settings.scaleMode {
            case .original: String(localized: "实际像素")
            case .fitWindow: String(localized: "适合窗口")
            case .fitWidth: String(localized: "适合宽度")
            case .fitHeight: String(localized: "适合高度")
            case .fill: String(localized: "填满裁切")
            case .fixed: "\(Int((settings.fixedScale * 100).rounded()))%"
            case .devicePixel: String(localized: "设备像素 1:1")
            }
            let upscale = settings.allowUpscale ? String(localized: "允许放大") : String(localized: "不放大")
            let resample: String = switch settings.resample {
            case .lanczos: "Lanczos"
            case .nearest: String(localized: "最近邻")
            }
            return "\(scaleName) · \(upscale) · \(resample)"

        case .effects:
            let adjust = settings.effects.colorAdjust
            if adjust.isIdentity { return String(localized: "原值") }
            let parts = EffectsPanelView.AdjustField.allCases.compactMap { field -> String? in
                let value = field.value(in: adjust)
                guard abs(value - field.defaultValue) > 0.0001 else { return nil }
                return "\(field.title) \(field.format(value))"
            }
            return parts.isEmpty ? String(localized: "原值") : parts.joined(separator: " · ")

        case .background:
            switch settings.background {
            case .auto: return String(localized: "自动")
            case .black: return String(localized: "黑")
            case .gray: return String(localized: "灰")
            case .white: return String(localized: "白")
            case .checkerboard: return String(localized: "棋盘格")
            case .frostedGlass: return String(localized: "毛玻璃")
            case .imageColor: return String(localized: "按图取色")
            case .custom: return String(localized: "自定义")
            }
        }
    }

    /// 把显示配置套用到当前书（写入书层）；配置含“效果”组且窗口效果开关关闭时自动打开开关。
    static func applyToBook(_ profile: DisplayProfile, in controller: ReaderWindowController) {
        guard controller.session.book != nil else { return }
        controller.session.update { $0.merge(profile.settings) }
        if profile.groups.contains(.effects), !controller.effectsEnabled {
            controller.setEffectsEnabled(true)
        }
        let groupsText = groupListText(profile.groups)
        controller.content.statusBar.showMessage(
            String(localized: "已把“\(profile.name)”套用到当前书（\(groupsText)）")
        )
    }
}
