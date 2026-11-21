import Foundation

/// 画面调色参数；各字段均以中性值为默认，解码时越界值夹到合法范围。
public struct ColorAdjust: Codable, Sendable, Hashable {
    public var brightness: Double   // −1…1，0 为原值
    public var contrast: Double     // −1…1
    public var saturation: Double   // −1…1
    public var gamma: Double        // 0.25…4，1 为原值
    public var temperature: Double  // −1…1
    public var tint: Double         // −1…1

    public init(
        brightness: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        gamma: Double = 1,
        temperature: Double = 0,
        tint: Double = 0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.temperature = temperature
        self.tint = tint
    }

    public static let identity = ColorAdjust()

    public var isIdentity: Bool {
        self == .identity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            brightness: clamp(try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0, to: -1...1, default: 0),
            contrast: clamp(try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0, to: -1...1, default: 0),
            saturation: clamp(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0, to: -1...1, default: 0),
            gamma: clamp(try container.decodeIfPresent(Double.self, forKey: .gamma) ?? 1, to: 0.25...4, default: 1),
            temperature: clamp(try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0, to: -1...1, default: 0),
            tint: clamp(try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0, to: -1...1, default: 0)
        )
    }
}

/// 单个实时画面效果；JSON 中将 `type` 与参数字段平铺在同一对象内。
public enum Effect: Codable, Sendable, Hashable {
    case colorAdjust(ColorAdjust)

    public var isIdentity: Bool {
        switch self {
        case let .colorAdjust(adjust): adjust.isIdentity
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "colorAdjust":
            self = .colorAdjust(try ColorAdjust(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown effect type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .colorAdjust(adjust):
            try container.encode("colorAdjust", forKey: .type)
            try adjust.encode(to: encoder)
        }
    }
}

/// 有序效果链；本期每种效果类型最多出现一次。
public struct EffectChain: Codable, Sendable, Hashable {
    public var effects: [Effect]

    public init(effects: [Effect] = []) {
        self.effects = effects
    }

    public static let empty = EffectChain()

    public var isIdentity: Bool {
        effects.allSatisfy(\.isIdentity)
    }

    /// 取/写链里的调色项，没有时取 `identity`；写 `identity` 时移除该项。
    public var colorAdjust: ColorAdjust {
        get {
            for effect in effects {
                if case let .colorAdjust(adjust) = effect { return adjust }
            }
            return .identity
        }
        set {
            if newValue.isIdentity {
                effects.removeAll {
                    if case .colorAdjust = $0 { return true }
                    return false
                }
            } else if let index = effects.firstIndex(where: {
                if case .colorAdjust = $0 { return true }
                return false
            }) {
                effects[index] = .colorAdjust(newValue)
                var seen = false
                effects.removeAll {
                    if case .colorAdjust = $0 {
                        if seen { return true }
                        seen = true
                    }
                    return false
                }
            } else {
                effects.append(.colorAdjust(newValue))
            }
        }
    }
}

/// 阅读画布背景；预设编码为字符串，自定义颜色编码为带 sRGB 分量的对象。
public enum ViewerBackground: Codable, Sendable, Hashable {
    case auto, black, gray, white, checkerboard, frostedGlass, imageColor
    case custom(red: Double, green: Double, blue: Double)   // sRGB 0…1

    private enum CodingKeys: String, CodingKey {
        case type, red, green, blue
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let name = try? single.decode(String.self) {
            switch name {
            case "auto": self = .auto
            case "black": self = .black
            case "gray": self = .gray
            case "white": self = .white
            case "checkerboard": self = .checkerboard
            case "frostedGlass": self = .frostedGlass
            case "imageColor": self = .imageColor
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown viewer background: \(name)"
                )
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "custom" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown viewer background type: \(type)"
            )
        }
        let red = clamp(try container.decode(Double.self, forKey: .red), to: 0...1, default: 0)
        let green = clamp(try container.decode(Double.self, forKey: .green), to: 0...1, default: 0)
        let blue = clamp(try container.decode(Double.self, forKey: .blue), to: 0...1, default: 0)
        self = .custom(red: red, green: green, blue: blue)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .black:
            var container = encoder.singleValueContainer()
            try container.encode("black")
        case .gray:
            var container = encoder.singleValueContainer()
            try container.encode("gray")
        case .white:
            var container = encoder.singleValueContainer()
            try container.encode("white")
        case .checkerboard:
            var container = encoder.singleValueContainer()
            try container.encode("checkerboard")
        case .frostedGlass:
            var container = encoder.singleValueContainer()
            try container.encode("frostedGlass")
        case .imageColor:
            var container = encoder.singleValueContainer()
            try container.encode("imageColor")
        case let .custom(red, green, blue):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("custom", forKey: .type)
            try container.encode(red, forKey: .red)
            try container.encode(green, forKey: .green)
            try container.encode(blue, forKey: .blue)
        }
    }
}

private func clamp(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
    guard !value.isNaN else { return fallback }
    return min(max(value, range.lowerBound), range.upperBound)
}
