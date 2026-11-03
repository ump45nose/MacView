import MVFoundation
import MVMedia
import MVSettings

/// 一个页帧元素在视口中占的设备像素，以及向管线请求的尺寸。宽高比未知时两者都为 0×0。
public struct FittedPage: Sendable, Hashable {
    public var element: PageFrameElement
    public var pixelSize: PixelSize
    /// 请求的总是整页，半页由查看器裁出，所以这里的宽高比与源图一致。
    public var decodeSize: PixelSize

    public init(element: PageFrameElement, pixelSize: PixelSize, decodeSize: PixelSize) {
        self.element = element
        self.pixelSize = pixelSize
        self.decodeSize = decodeSize
    }
}

/// 页帧在给定视口和缩放设置下的显示尺寸。查看器和预解码共用这一结果，L1 的键才能对上。
///
/// `original` 与 `fixed` 按点（1 源像素 × 比例 = 1 点），`devicePixel` 按设备像素（1 源像素 = 1 设备像素）；
/// 这三种模式超过源尺寸的部分不解码，由图层放大。适合类模式按布局尺寸解码。
public struct PageFrameFit: Sendable, Hashable {
    public var pages: [FittedPage]
    /// 整个页帧在视口中的设备像素。
    public var size: PixelSize

    public init(pages: [FittedPage], size: PixelSize) {
        self.pages = pages
        self.size = size
    }

    /// 元素顺序与 `frame.elements` 相同，不再按阅读方向重排。
    public static func fit(frame: PageFrame, pages: [Page], viewport: PixelSize, backingScale: Double, settings: ResolvedBookSettings) -> PageFrameFit {
        let zero = PixelSize(width: 0, height: 0)
        let sources = frame.elements.map { sourcePixels(of: pages[$0.page], part: $0.part) }
        let wholes = frame.elements.map { pages[$0.page].metadata?.pixelSize ?? zero }
        let known = sources.compactMap { $0 }
        var sizes = Array(repeating: zero, count: sources.count)
        var decodes = Array(repeating: zero, count: sources.count)
        var frameSize = zero
        if !known.isEmpty {
            switch settings.scaleMode {
            case .original, .devicePixel, .fixed:
                let scale: Double
                switch settings.scaleMode {
                case .original: scale = backingScale
                case .fixed: scale = settings.fixedScale * backingScale
                default: scale = 1
                }
                for index in sources.indices {
                    guard let source = sources[index] else { continue }
                    sizes[index] = PixelSize(width: scaledSide(source.width, scale), height: scaledSide(source.height, scale))
                    let decodeScale = min(scale, 1)
                    decodes[index] = PixelSize(width: scaledSide(wholes[index].width, decodeScale), height: scaledSide(wholes[index].height, decodeScale))
                }
                frameSize = composed(sizes)
            case .fitWindow, .fitWidth, .fitHeight, .fill:
                (sizes, frameSize) = fitted(sources, known: known, viewport: viewport, settings: settings, zero: zero)
                for index in sources.indices where sizes[index].height > 0 {
                    let whole = wholes[index]
                    let height = sizes[index].height
                    decodes[index] = PixelSize(width: max(1, Int((Double(whole.width) * Double(height) / Double(whole.height)).rounded())), height: height)
                }
            }
        }
        var fittedPages: [FittedPage] = []
        fittedPages.reserveCapacity(frame.elements.count)
        for index in frame.elements.indices {
            fittedPages.append(FittedPage(element: frame.elements[index], pixelSize: sizes[index], decodeSize: decodes[index]))
        }
        return PageFrameFit(pages: fittedPages, size: frameSize)
    }

    /// 跳过 0×0。长边用 `fitting(longSide:)` 压到上限。
    public func displayTargets(settings: ResolvedBookSettings, maxDecodeLongSide: Int) -> [(element: PageFrameElement, target: DisplayTarget)] {
        pages.compactMap { page in
            guard page.decodeSize.width != 0 || page.decodeSize.height != 0 else { return nil }
            return (
                page.element,
                DisplayTarget(
                    pixelSize: page.decodeSize.fitting(longSide: maxDecodeLongSide),
                    filter: settings.resample,
                    sharpen: settings.sharpen
                )
            )
        }
    }

    private static func sourcePixels(of page: Page, part: PagePart) -> PixelSize? {
        guard let size = page.metadata?.pixelSize, size.width > 0, size.height > 0 else { return nil }
        let width: Int
        switch part {
        case .whole: width = size.width
        case .leftHalf: width = size.width / 2
        case .rightHalf: width = size.width - size.width / 2
        }
        guard width > 0 else { return nil }
        return PixelSize(width: width, height: size.height)
    }

    /// 源边为正时，乘比例四舍五入后至少为 1。
    private static func scaledSide(_ source: Int, _ scale: Double) -> Int {
        max(1, Int((Double(source) * scale).rounded()))
    }

    private static func composed(_ sizes: [PixelSize]) -> PixelSize {
        PixelSize(width: sizes.reduce(0) { $0 + $1.width }, height: sizes.reduce(0) { max($0, $1.height) })
    }

    private static func fitted(
        _ sources: [PixelSize?], known: [PixelSize], viewport: PixelSize, settings: ResolvedBookSettings, zero: PixelSize
    ) -> (pages: [PixelSize], size: PixelSize) {
        let aspects = known.map { Double($0.width) / Double($0.height) }
        let unitWidth = aspects.reduce(0, +)
        let scale: Double
        switch settings.scaleMode {
        case .fitWindow: scale = min(Double(viewport.width) / unitWidth, Double(viewport.height))
        case .fitWidth: scale = Double(viewport.width) / unitWidth
        case .fitHeight: scale = Double(viewport.height)
        case .fill: scale = max(Double(viewport.width) / unitWidth, Double(viewport.height))
        case .original, .devicePixel, .fixed: scale = 0
        }
        let minSourceHeight = known.reduce(Int.max) { min($0, $1.height) }
        var shared = scale
        if !settings.allowUpscale { shared = min(shared, Double(minSourceHeight)) }
        guard viewport.width != 0, viewport.height != 0, shared.isFinite, shared > 0 else {
            return (Array(repeating: zero, count: sources.count), zero)
        }
        // 先四舍五入，不允许放大时再与最小源高取较小值，最后至少为 1。
        var height = Int(shared.rounded())
        if !settings.allowUpscale { height = min(height, minSourceHeight) }
        height = max(1, height)
        var pages: [PixelSize] = []
        pages.reserveCapacity(sources.count)
        var cursor = aspects.startIndex
        for source in sources {
            guard source != nil else {
                pages.append(zero)
                continue
            }
            let width = max(1, Int((aspects[cursor] * Double(height)).rounded()))
            cursor += 1
            pages.append(PixelSize(width: width, height: height))
        }
        return (pages, composed(pages))
    }
}
