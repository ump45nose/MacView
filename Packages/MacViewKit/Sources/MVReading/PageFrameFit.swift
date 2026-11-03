import MVFoundation
import MVMedia
import MVSettings

/// 一个页帧元素在视口中的布局像素。宽高比未知时为 0×0。
public struct FittedPage: Sendable, Hashable {
    public var element: PageFrameElement
    public var pixelSize: PixelSize

    public init(element: PageFrameElement, pixelSize: PixelSize) {
        self.element = element
        self.pixelSize = pixelSize
    }
}

/// 页帧在给定视口和缩放设置下的显示尺寸。查看器和预解码共用这一结果，L1 的键才能对上。
public struct PageFrameFit: Sendable, Hashable {
    public var pages: [FittedPage]
    /// 整个页帧在视口中的像素尺寸。
    public var size: PixelSize

    public init(pages: [FittedPage], size: PixelSize) {
        self.pages = pages
        self.size = size
    }

    /// 元素顺序与 `frame.elements` 相同，不再按阅读方向重排。
    public static func fit(frame: PageFrame, pages: [Page], viewport: PixelSize, settings: ResolvedBookSettings) -> PageFrameFit {
        let zero = PixelSize(width: 0, height: 0)
        let sources = frame.elements.map { sourcePixels(of: pages[$0.page], part: $0.part) }
        let known = sources.compactMap { $0 }
        var sizes = Array(repeating: zero, count: sources.count)
        var frameSize = zero
        if !known.isEmpty {
            switch settings.scaleMode {
            case .original, .devicePixel:
                sizes = sources.map { $0 ?? zero }
                frameSize = composed(sizes)
            case .fixed:
                sizes = sources.map { source in
                    guard let source else { return zero }
                    return PixelSize(width: fixedSide(source.width, settings.fixedScale), height: fixedSide(source.height, settings.fixedScale))
                }
                frameSize = composed(sizes)
            case .fitWindow, .fitWidth, .fitHeight, .fill:
                (sizes, frameSize) = fitted(sources, known: known, viewport: viewport, settings: settings, zero: zero)
            }
        }
        var fittedPages: [FittedPage] = []
        fittedPages.reserveCapacity(frame.elements.count)
        for index in frame.elements.indices {
            fittedPages.append(FittedPage(element: frame.elements[index], pixelSize: sizes[index]))
        }
        return PageFrameFit(pages: fittedPages, size: frameSize)
    }

    /// 跳过 0×0。长边用 `pixelSize.fitting(longSide:)` 压到上限。
    public func displayTargets(settings: ResolvedBookSettings, maxDecodeLongSide: Int) -> [(element: PageFrameElement, target: DisplayTarget)] {
        pages.compactMap { page in
            guard page.pixelSize.width != 0 || page.pixelSize.height != 0 else { return nil }
            return (
                page.element,
                DisplayTarget(
                    pixelSize: page.pixelSize.fitting(longSide: maxDecodeLongSide),
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

    /// 源边为正时，乘 `fixedScale` 四舍五入后至少为 1。
    private static func fixedSide(_ source: Int, _ scale: Double) -> Int {
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
