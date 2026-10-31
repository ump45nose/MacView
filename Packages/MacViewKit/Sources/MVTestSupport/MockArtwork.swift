import CoreGraphics
import CoreText
import Foundation
import MVFoundation

/// 合成图：底色由种子决定，带边框和对角线，中间是编号，底部是说明。
enum MockArtwork {
    static func image(title: String, caption: String, size: PixelSize, seed: UInt64) -> CGImage {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { preconditionFailure("无法创建 \(width)×\(height) 的位图") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let short = CGFloat(min(width, height))
        context.setFillColor(color(seed: seed, brightness: 0.85))
        context.fill(bounds)
        context.setStrokeColor(color(seed: seed, brightness: 0.45))
        context.setLineWidth(max(1, short / 300))
        context.move(to: .zero)
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        context.move(to: CGPoint(x: 0, y: bounds.maxY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: 0))
        context.strokePath()
        context.setLineWidth(max(1, short / 80))
        context.stroke(bounds.insetBy(dx: short / 40, dy: short / 40))
        let ink = CGColor(gray: 0.1, alpha: 1)
        let titleSize = min(short * 0.32, bounds.width * 0.9 / (0.62 * CGFloat(max(title.count, 1))))
        draw(title, size: titleSize, color: ink, center: CGPoint(x: bounds.midX, y: bounds.midY), in: context)
        draw(caption, size: short * 0.045, color: ink, center: CGPoint(x: bounds.midX, y: short * 0.09), in: context)
        guard let image = context.makeImage() else { preconditionFailure("无法生成合成图") }
        return image
    }

    /// 色相取自种子，饱和度固定。
    private static func color(seed: UInt64, brightness: Double) -> CGColor {
        let sector = Double(seed % 360) / 60
        let chroma = brightness * 0.45
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let base = brightness - chroma
        return CGColor(srgbRed: red + base, green: green + base, blue: blue + base, alpha: 1)
    }

    private static func draw(_ text: String, size: CGFloat, color: CGColor, center: CGPoint, in context: CGContext) {
        guard size >= 4, !text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }
}
