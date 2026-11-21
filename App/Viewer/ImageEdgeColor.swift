import CoreGraphics
import Foundation
import MVFoundation

/// 从图像四边边缘带采样得到的 sRGB 平均色。
struct EdgeColor: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// 边缘取色计算：在缩略图的上下左右各约 4% 宽的边缘带内求 alpha 加权 sRGB 平均色。
enum ImageEdgeColor {
    /// 与预取/HUD 缩略图一致的像素上限，命中管线缓存时不读原文件。
    static let thumbnailMaxPixel = 128
    static let edgeFraction = 0.04

    nonisolated static func sample(from image: CGImage) -> EdgeColor? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bandX = max(1, min(width, Int((Double(width) * edgeFraction).rounded())))
        let bandY = max(1, min(height, Int((Double(height) * edgeFraction).rounded())))

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var sumWeight = 0.0

        func accumulate(xRange: Range<Int>, yRange: Range<Int>) {
            for y in yRange {
                let rowOffset = y * bytesPerRow
                for x in xRange {
                    let offset = rowOffset + x * 4
                    let alpha = Double(pixels[offset + 3])
                    if alpha > 0 {
                        // premultipliedLast 下通道值已乘以 alpha/255，直接累加再除以 alpha 总和即得 alpha 加权平均。
                        sumR += Double(pixels[offset])
                        sumG += Double(pixels[offset + 1])
                        sumB += Double(pixels[offset + 2])
                        sumWeight += alpha
                    }
                }
            }
        }

        // 上边缘
        accumulate(xRange: 0..<width, yRange: 0..<bandY)
        // 下边缘（避免与上边缘重叠）
        let bottomStart = max(bandY, height - bandY)
        if bottomStart < height {
            accumulate(xRange: 0..<width, yRange: bottomStart..<height)
        }
        // 中间行的左、右边缘（避免重复计算四角）
        if bandY < bottomStart {
            accumulate(xRange: 0..<bandX, yRange: bandY..<bottomStart)
            let rightStart = max(bandX, width - bandX)
            if rightStart < width {
                accumulate(xRange: rightStart..<width, yRange: bandY..<bottomStart)
            }
        }

        guard sumWeight > 0 else { return nil }
        return EdgeColor(
            red: min(max(sumR / sumWeight, 0), 1),
            green: min(max(sumG / sumWeight, 0), 1),
            blue: min(max(sumB / sumWeight, 0), 1)
        )
    }
}

/// 按页内容标识缓存边缘取色结果的有上限内存缓存。
@MainActor
final class ImageEdgeColorCache {
    static let shared = ImageEdgeColorCache(capacity: 512)

    private final class Key: NSObject {
        let identity: ContentIdentity
        init(_ identity: ContentIdentity) { self.identity = identity }
        override var hash: Int { identity.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? Key)?.identity == identity
        }
    }

    private final class Box {
        let color: EdgeColor
        init(_ color: EdgeColor) { self.color = color }
    }

    private let cache = NSCache<Key, Box>()

    init(capacity: Int) {
        cache.countLimit = max(1, capacity)
    }

    func color(for identity: ContentIdentity) -> EdgeColor? {
        cache.object(forKey: Key(identity))?.color
    }

    func store(_ color: EdgeColor, for identity: ContentIdentity) {
        cache.setObject(Box(color), forKey: Key(identity))
    }

    #if DEBUG
    func removeAll() {
        cache.removeAllObjects()
    }
    #endif
}
