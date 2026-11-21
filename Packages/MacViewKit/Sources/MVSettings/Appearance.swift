import Foundation

public enum AppearanceMode: String, Codable, Sendable, CaseIterable { case system, light, dark }
public enum AccentColorMode: String, Codable, Sendable, CaseIterable { case clay, system }
public enum FontRole: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable { case panels, overlays, menus }

/// 一组字体；字段为 nil 表示用系统字体或该组默认字号。
public struct FontSpec: Codable, Sendable, Hashable {
    public var family: String?
    public var size: Double?

    public init(family: String? = nil, size: Double? = nil) {
        self.family = family
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let size = try values.decodeIfPresent(Double.self, forKey: .size)
        if let size, !(8...32).contains(size) {
            throw DecodingError.dataCorruptedError(forKey: .size, in: values,
                debugDescription: String(localized: "字体字号必须在 8…32 之间，现在是 \(size)", bundle: .main))
        }
        self.init(family: try values.decodeIfPresent(String.self, forKey: .family), size: size)
    }
}

public enum TitleBarMode: String, Codable, Sendable, CaseIterable { case shown, autoHide, borderless }

public struct WindowAppearance: Codable, Sendable, Hashable {
    public var titleBar: TitleBarMode
    public var keepOnTop: Bool
    public var opacity: Double

    public init(titleBar: TitleBarMode = .shown, keepOnTop: Bool = false, opacity: Double = 1) {
        self.titleBar = titleBar
        self.keepOnTop = keepOnTop
        self.opacity = opacity
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        guard (0.3...1).contains(opacity) else {
            throw DecodingError.dataCorruptedError(forKey: .opacity, in: values,
                debugDescription: String(localized: "窗口不透明度必须在 0.3…1 之间，现在是 \(opacity)", bundle: .main))
        }
        self.init(titleBar: try values.decodeIfPresent(TitleBarMode.self, forKey: .titleBar) ?? .shown,
                  keepOnTop: try values.decodeIfPresent(Bool.self, forKey: .keepOnTop) ?? false,
                  opacity: opacity)
    }
}

public struct AppearanceSettings: Codable, Sendable, Hashable {
    public var mode: AppearanceMode
    public var accent: AccentColorMode
    /// 缺少某组时使用该组默认字体。
    public var fonts: [FontRole: FontSpec]
    public var window: WindowAppearance

    public init(mode: AppearanceMode = .system, accent: AccentColorMode = .clay,
                fonts: [FontRole: FontSpec] = [:], window: WindowAppearance = WindowAppearance()) {
        self.mode = mode
        self.accent = accent
        self.fonts = fonts
        self.window = window
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decodeIfPresent(AppearanceMode.self, forKey: .mode) ?? .system,
                  accent: try values.decodeIfPresent(AccentColorMode.self, forKey: .accent) ?? .clay,
                  fonts: try values.decodeIfPresent([FontRole: FontSpec].self, forKey: .fonts) ?? [:],
                  window: try values.decodeIfPresent(WindowAppearance.self, forKey: .window) ?? WindowAppearance())
    }

    public static let `default` = AppearanceSettings()
}
