import MVFoundation
import MVMedia
import MVSettings
import Testing
@testable import MVReading

struct PageFrameFitTests {
    private let portrait = (800, 1400)
    private let landscape = (1400, 800)

    @Test("七种缩放模式 × 单页、双页、半页 × 竖屏与横屏")
    func scaleModes() {
        let single = [p(1000, 2000)]
        both(single, .original, [1000, 2000], (1000, 2000))
        both(single, .devicePixel, [1000, 2000], (1000, 2000))
        both(single, .fixed, [2000, 4000], (2000, 4000), fixedScale: 2)
        expectFit(single, .fitWindow, portrait, [700, 1400], (700, 1400))
        expectFit(single, .fitWindow, landscape, [400, 800], (400, 800))
        expectFit(single, .fitWidth, portrait, [800, 1600], (800, 1600))
        expectFit(single, .fitWidth, landscape, [1400, 2800], (1400, 2800))
        expectFit(single, .fitHeight, portrait, [700, 1400], (700, 1400))
        expectFit(single, .fitHeight, landscape, [400, 800], (400, 800))
        expectFit(single, .fill, portrait, [800, 1600], (800, 1600))
        expectFit(single, .fill, landscape, [1400, 2800], (1400, 2800))

        let spread = [p(1000, 1000), p(2000, 1000)]
        both(spread, .original, [1000, 1000, 2000, 1000], (3000, 1000))
        both(spread, .devicePixel, [1000, 1000, 2000, 1000], (3000, 1000))
        both(spread, .fixed, [2000, 2000, 4000, 2000], (6000, 2000), fixedScale: 2)
        expectFit(spread, .fitWindow, portrait, [267, 267, 534, 267], (801, 267))
        expectFit(spread, .fitWindow, landscape, [467, 467, 934, 467], (1401, 467))
        expectFit(spread, .fitWidth, portrait, [267, 267, 534, 267], (801, 267))
        expectFit(spread, .fitWidth, landscape, [467, 467, 934, 467], (1401, 467))
        expectFit(spread, .fitHeight, portrait, [1400, 1400, 2800, 1400], (4200, 1400))
        expectFit(spread, .fitHeight, landscape, [800, 800, 1600, 800], (2400, 800))
        expectFit(spread, .fill, portrait, [1400, 1400, 2800, 1400], (4200, 1400))
        expectFit(spread, .fill, landscape, [800, 800, 1600, 800], (2400, 800))

        let left = [p(1001, 1000, .leftHalf)]
        both(left, .original, [500, 1000], (500, 1000))
        both(left, .devicePixel, [500, 1000], (500, 1000))
        both(left, .fixed, [1000, 2000], (1000, 2000), fixedScale: 2)
        expectFit(left, .fitWindow, portrait, [700, 1400], (700, 1400))
        expectFit(left, .fitWindow, landscape, [400, 800], (400, 800))
        expectFit(left, .fitWidth, portrait, [800, 1600], (800, 1600))
        expectFit(left, .fitWidth, landscape, [1400, 2800], (1400, 2800))
        expectFit(left, .fitHeight, portrait, [700, 1400], (700, 1400))
        expectFit(left, .fitHeight, landscape, [400, 800], (400, 800))
        expectFit(left, .fill, portrait, [800, 1600], (800, 1600))
        expectFit(left, .fill, landscape, [1400, 2800], (1400, 2800))

        let right = [p(1001, 1000, .rightHalf)]
        both(right, .original, [501, 1000], (501, 1000))
        both(right, .devicePixel, [501, 1000], (501, 1000))
        both(right, .fixed, [1002, 2000], (1002, 2000), fixedScale: 2)
        expectFit(right, .fitWindow, portrait, [701, 1400], (701, 1400))
        expectFit(right, .fitWindow, landscape, [401, 800], (401, 800))
        expectFit(right, .fitWidth, portrait, [800, 1597], (800, 1597))
        expectFit(right, .fitWidth, landscape, [1400, 2794], (1400, 2794))
        expectFit(right, .fitHeight, portrait, [701, 1400], (701, 1400))
        expectFit(right, .fitHeight, landscape, [401, 800], (401, 800))
        expectFit(right, .fill, portrait, [800, 1597], (800, 1597))
        expectFit(right, .fill, landscape, [1400, 2794], (1400, 2794))
    }

    @Test("对照样例、宽高比未知、仅缩小与长边上限")
    func documentedAndEdgeCases() {
        let single = [p(1000, 2000)]
        expectFit(single, .fitWindow, (800, 600), [300, 600], (300, 600))
        expectFit([p(100, 200)], .fitWindow, (800, 600), [100, 200], (100, 200), allowUpscale: false)
        expectFit(single, .fitWindow, (800, 600), [300, 600], (300, 600), allowUpscale: false)
        expectFit([p(1000, 1000), p(2000, 1000)], .fitWindow, (1500, 1000), [500, 500, 1000, 500], (1500, 500))
        expectFit([p(1000, 1000), p(2000, 1000)], .original, (1500, 1000), [1000, 1000, 2000, 1000], (3000, 1000))
        expectFit([p(100, 200)], .fixed, (800, 600), [200, 400], (200, 400), fixedScale: 2)
        expectFit([p(100, 200)], .fixed, (10, 10), [200, 400], (200, 400), allowUpscale: false, fixedScale: 2)
        expectFit([p(100, 200)], .fixed, (800, 600), [1, 1], (1, 1), fixedScale: 0.001)
        expectFit(single, .fill, (800, 600), [800, 1600], (800, 1600))
        expectFit(single, .fitWidth, (800, 600), [800, 1600], (800, 1600))
        expectFit([p(1000, 1000, .leftHalf)], .fitHeight, (500, 800), [400, 800], (400, 800))
        expectFit(single, .original, (0, 0), [1000, 2000], (1000, 2000))
        expectFit(single, .devicePixel, (0, 0), [1000, 2000], (1000, 2000))
        expectFit(single, .fitWindow, (0, 600), [0, 0], (0, 0))
        expectFit(single, .fill, (800, 0), [0, 0], (0, 0))
        expectFit(single, .fitWidth, (800, 0), [0, 0], (0, 0))
        expectFit([p(100, 200), p(300, 80)], .original, (1, 1), [100, 200, 300, 80], (400, 200))
        expectFit([p(100, 200), p(300, 80)], .devicePixel, (1, 1), [100, 200, 300, 80], (400, 200))
        expectFit([p(100, 200), p(300, 80)], .fixed, (1, 1), [200, 400, 600, 160], (800, 400), fixedScale: 2)
        expectFit([p(10000, 10)], .fitWindow, (100, 100), [1000, 1], (1000, 1))
        expectFit([p(1000, 1000), p(2000, 1000)], .original, (1500, 1000), [1000, 1000, 2000, 1000], (3000, 1000), direction: .rightToLeft)

        let uneven = [p(100, 200), p(100, 400)]
        for mode in [ScaleMode.fitWindow, .fitWidth, .fitHeight, .fill] {
            expectFit(uneven, mode, (800, 600), [100, 200, 50, 200], (150, 200), allowUpscale: false)
        }

        expectFit([unknown()], .fitWindow, portrait, [0, 0], (0, 0))
        expectFit([(PixelSize(width: 0, height: 10), .whole)], .original, portrait, [0, 0], (0, 0))
        expectFit([(PixelSize(width: -4, height: 10), .whole)], .fill, landscape, [0, 0], (0, 0))
        expectFit([unknown(), unknown()], .original, portrait, [0, 0, 0, 0], (0, 0))
        expectFit([unknown(), p(1000, 2000)], .original, (800, 600), [0, 0, 1000, 2000], (1000, 2000))
        expectFit([unknown(), p(1000, 2000)], .fitWindow, (800, 600), [0, 0, 300, 600], (300, 600))
        expectFit([p(1, 1000, .leftHalf)], .fitHeight, (500, 800), [0, 0], (0, 0))
        expectFit([p(1, 1000, .rightHalf)], .original, (500, 800), [1, 1000], (1, 1000))
        expectFit([p(1, 1000, .rightHalf)], .fitWindow, (800, 600), [1, 600], (1, 600))

        var settings = ResolvedBookSettings.default
        settings.resample = .nearest
        settings.sharpen = 0.35
        let fitted = PageFrameFit(
            pages: [
                FittedPage(element: PageFrameElement(page: 0), pixelSize: PixelSize(width: 4000, height: 2000), decodeSize: PixelSize(width: 4000, height: 2000)),
                FittedPage(element: PageFrameElement(page: 1), pixelSize: PixelSize(width: 0, height: 0), decodeSize: PixelSize(width: 0, height: 0)),
                FittedPage(element: PageFrameElement(page: 2, part: .leftHalf), pixelSize: PixelSize(width: 100, height: 100), decodeSize: PixelSize(width: 200, height: 100)),
                FittedPage(element: PageFrameElement(page: 3), pixelSize: PixelSize(width: 2000, height: 4000), decodeSize: PixelSize(width: 2000, height: 4000)),
            ],
            size: PixelSize(width: 6100, height: 4000)
        )
        let targets = fitted.displayTargets(settings: settings, maxDecodeLongSide: 1000)
        #expect(targets.map(\.element) == [PageFrameElement(page: 0), PageFrameElement(page: 2, part: .leftHalf), PageFrameElement(page: 3)])
        #expect(targets.map(\.target.pixelSize) == [
            PixelSize(width: 1000, height: 500), PixelSize(width: 200, height: 100), PixelSize(width: 500, height: 1000),
        ])
        #expect(targets.allSatisfy { $0.target.filter == .nearest && $0.target.sharpen == 0.35 })
    }

    @Test("original、fixed 随屏幕缩放倍率变化，devicePixel 不变；超过源尺寸的部分不解码")
    func backingScale() {
        let frame = PageFrame(elements: [PageFrameElement(page: 0)])
        let pages = [page(0, pixels: PixelSize(width: 1000, height: 2000))]
        let viewport = PixelSize(width: 800, height: 600)
        func fit(_ mode: ScaleMode, fixedScale: Double = 1, backing: Double = 2) -> FittedPage {
            var settings = ResolvedBookSettings.default
            settings.scaleMode = mode
            settings.fixedScale = fixedScale
            return PageFrameFit.fit(frame: frame, pages: pages, viewport: viewport, backingScale: backing, settings: settings).pages[0]
        }
        let source = PixelSize(width: 1000, height: 2000)
        #expect(fit(.original).pixelSize == PixelSize(width: 2000, height: 4000))
        #expect(fit(.original).decodeSize == source)
        #expect(fit(.devicePixel).pixelSize == source)
        #expect(fit(.devicePixel).decodeSize == source)
        #expect(fit(.fixed, fixedScale: 1.5).pixelSize == PixelSize(width: 3000, height: 6000))
        #expect(fit(.fixed, fixedScale: 1.5).decodeSize == source)
        #expect(fit(.fixed, fixedScale: 0.25).pixelSize == PixelSize(width: 500, height: 1000))
        #expect(fit(.fixed, fixedScale: 0.25).decodeSize == PixelSize(width: 500, height: 1000))
        #expect(fit(.fitHeight).pixelSize == PixelSize(width: 300, height: 600))
        #expect(fit(.fitHeight).pixelSize == fit(.fitHeight, backing: 1).pixelSize)
    }

    @Test("半页的解码尺寸是整页比例，两半共用同一个目标")
    func halfPageDecodesWholePage() {
        let pages = [page(0, pixels: PixelSize(width: 4000, height: 2000))]
        let viewport = PixelSize(width: 3000, height: 1000)
        func fit(_ part: PagePart, _ mode: ScaleMode) -> FittedPage {
            var settings = ResolvedBookSettings.default
            settings.scaleMode = mode
            return PageFrameFit.fit(frame: PageFrame(elements: [PageFrameElement(page: 0, part: part)]), pages: pages, viewport: viewport, backingScale: 1, settings: settings).pages[0]
        }
        #expect(fit(.leftHalf, .fitHeight).pixelSize == PixelSize(width: 1000, height: 1000))
        #expect(fit(.leftHalf, .fitHeight).decodeSize == PixelSize(width: 2000, height: 1000))
        #expect(fit(.rightHalf, .fitHeight).decodeSize == fit(.leftHalf, .fitHeight).decodeSize)
        #expect(fit(.leftHalf, .original).pixelSize == PixelSize(width: 2000, height: 2000))
        #expect(fit(.leftHalf, .original).decodeSize == PixelSize(width: 4000, height: 2000))
    }

    private func both(
        _ parts: [(PixelSize?, PagePart)], _ mode: ScaleMode, _ pages: [Int], _ frame: (Int, Int), fixedScale: Double = 1
    ) {
        expectFit(parts, mode, portrait, pages, frame, fixedScale: fixedScale)
        expectFit(parts, mode, landscape, pages, frame, fixedScale: fixedScale)
    }

    private func expectFit(
        _ parts: [(PixelSize?, PagePart)], _ mode: ScaleMode, _ viewport: (Int, Int), _ pages: [Int], _ frame: (Int, Int),
        allowUpscale: Bool = true, fixedScale: Double = 1, direction: ReadingDirection = .leftToRight
    ) {
        let bookPages = parts.enumerated().map { index, part in page(index, pixels: part.0) }
        let elements = parts.enumerated().map { index, part in PageFrameElement(page: index, part: part.1) }
        var settings = ResolvedBookSettings.default
        settings.scaleMode = mode
        settings.allowUpscale = allowUpscale
        settings.fixedScale = fixedScale
        settings.direction = direction
        let actual = PageFrameFit.fit(
            frame: PageFrame(elements: elements), pages: bookPages,
            viewport: PixelSize(width: viewport.0, height: viewport.1), backingScale: 1, settings: settings
        )
        let expectedPages = stride(from: 0, to: pages.count, by: 2).map { PixelSize(width: pages[$0], height: pages[$0 + 1]) }
        #expect(actual.pages.map(\.pixelSize) == expectedPages, "\(mode) \(viewport) allowUpscale=\(allowUpscale)")
        #expect(actual.size == PixelSize(width: frame.0, height: frame.1), "\(mode) \(viewport)")
        #expect(actual.pages.map(\.element) == elements)
    }

    private func p(_ width: Int, _ height: Int, _ part: PagePart = .whole) -> (PixelSize?, PagePart) {
        (PixelSize(width: width, height: height), part)
    }

    private func unknown(_ part: PagePart = .whole) -> (PixelSize?, PagePart) { (nil, part) }

    private func page(_ index: Int, pixels: PixelSize?) -> Page {
        let name = "\(index).jpg"
        let location = Location(root: .local, layers: [[name]])
        return Page(
            entry: Entry(
                identity: ContentIdentity(location: location, size: Int64(index + 1), modificationNanos: Int64(index + 1)),
                name: name, kind: .image
            ),
            metadata: pixels.map { ImageMetadata(pixelSize: $0) }
        )
    }
}
