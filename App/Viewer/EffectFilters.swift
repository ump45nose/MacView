import CoreImage
import MVSettings

/// 把 `EffectChain` 换算成 Core Image 滤镜链；屏幕实时呈现与离线导出共用这一处换算。
enum EffectFilters {
    /// 恒等链返回空数组；只使用 `CIColorControls`、`CIGammaAdjust`、`CITemperatureAndTint`。
    static func filters(for chain: EffectChain) -> [CIFilter] {
        guard !chain.isIdentity else { return [] }
        var result: [CIFilter] = []
        for effect in chain.effects where !effect.isIdentity {
            switch effect {
            case let .colorAdjust(adjust):
                result.append(contentsOf: colorAdjustFilters(adjust))
            case .plugin:
                break
            }
        }
        return result
    }

    /// 离线导出用：按与屏幕呈现完全一致的滤镜链和参数处理 `CIImage`。
    static func apply(_ chain: EffectChain, to image: CIImage) -> CIImage {
        let list = filters(for: chain)
        guard !list.isEmpty else { return image }
        var current = image
        for filter in list {
            filter.setValue(current, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                current = output
            }
        }
        return current
    }

    private static func colorAdjustFilters(_ adjust: ColorAdjust) -> [CIFilter] {
        var list: [CIFilter] = []
        if adjust.brightness != 0 || adjust.contrast != 0 || adjust.saturation != 0,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setDefaults()
            filter.setValue(adjust.brightness * 0.25, forKey: kCIInputBrightnessKey)
            filter.setValue(1.0 + adjust.contrast * 0.5, forKey: kCIInputContrastKey)
            filter.setValue(1.0 + adjust.saturation, forKey: kCIInputSaturationKey)
            list.append(filter)
        }
        if adjust.gamma != 1, let filter = CIFilter(name: "CIGammaAdjust") {
            filter.setDefaults()
            let gamma = max(adjust.gamma, 0.25)
            filter.setValue(1.0 / gamma, forKey: "inputPower")
            list.append(filter)
        }
        if adjust.temperature != 0 || adjust.tint != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setDefaults()
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(
                CIVector(x: 6500 - adjust.temperature * 2000, y: -adjust.tint * 50),
                forKey: "inputTargetNeutral"
            )
            list.append(filter)
        }
        return list
    }
}
