import Foundation

public enum DisplayProfileGroup: String, Codable, Sendable, CaseIterable {
    case layout, scale, effects, background
}

/// 可复用的显示配置，按组保存部分 `BookSettings` 字段。
public struct DisplayProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var settings: BookSettings

    /// 由 `settings` 里非空字段推出的配置组集合。
    public var groups: Set<DisplayProfileGroup> {
        var result: Set<DisplayProfileGroup> = []
        if settings.browseMode != nil
            || settings.pageMode != nil
            || settings.direction != nil
            || settings.firstPageSingle != nil
            || settings.widePage != nil
        {
            result.insert(.layout)
        }
        if settings.scaleMode != nil
            || settings.allowUpscale != nil
            || settings.fixedScale != nil
            || settings.keepZoomOnPageTurn != nil
            || settings.resample != nil
            || settings.sharpen != nil
        {
            result.insert(.scale)
        }
        if settings.effects != nil {
            result.insert(.effects)
        }
        if settings.background != nil {
            result.insert(.background)
        }
        return result
    }

    public init(id: UUID = UUID(), name: String, settings: BookSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }

    public init(
        id: UUID = UUID(),
        name: String,
        capturing resolved: ResolvedBookSettings,
        groups: Set<DisplayProfileGroup>
    ) {
        var captured = BookSettings()
        if groups.contains(.layout) {
            captured.browseMode = resolved.browseMode
            captured.pageMode = resolved.pageMode
            captured.direction = resolved.direction
            captured.firstPageSingle = resolved.firstPageSingle
            captured.widePage = resolved.widePage
        }
        if groups.contains(.scale) {
            captured.scaleMode = resolved.scaleMode
            captured.allowUpscale = resolved.allowUpscale
            captured.fixedScale = resolved.fixedScale
            captured.keepZoomOnPageTurn = resolved.keepZoomOnPageTurn
            captured.resample = resolved.resample
            captured.sharpen = resolved.sharpen
        }
        if groups.contains(.effects) {
            captured.effects = resolved.effects
        }
        if groups.contains(.background) {
            captured.background = resolved.background
        }
        self.init(id: id, name: name, settings: captured)
    }
}
