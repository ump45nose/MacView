import MVSettings
import Testing
@testable import MVReading

struct PageFrameTests {
    static let layouts = [PageMode.single, .double].flatMap { mode in
        [ReadingDirection.leftToRight, .rightToLeft].flatMap { direction in
            [false, true].flatMap { first in
                [WidePagePolicy.asIs, .single, .split].map { PageLayout(pageMode: mode, direction: direction, firstPageSingle: first, widePage: $0) }
            }
        }
    }
    @Test("单双页×方向×首页单页×全部宽页策略", arguments: layouts)
    func combinations(_ layout: PageLayout) {
        let mode = layout.pageMode, direction = layout.direction, first = layout.firstPageSingle, wide = layout.widePage
        let actual = PageFrameEngine.frames(aspectRatios: [0.7, nil, 1.8, 0.6, 2, 1], layout: layout)
        let whole: (Int) -> PageFrameElement = { PageFrameElement(page: $0) }
        let halves: (Int) -> [[PageFrameElement]] = { index in
            let parts: [PagePart] = direction == .leftToRight ? [.leftHalf, .rightHalf] : [.rightHalf, .leftHalf]
            return parts.map { [PageFrameElement(page: index, part: $0)] }
        }
        var expected: [[PageFrameElement]]
        switch (mode, first, wide) {
        case (.single, _, .asIs), (.single, _, .single): expected = (0..<6).map { [whole($0)] }
        case (.single, _, .split): expected = [[whole(0)], [whole(1)]] + halves(2) + [[whole(3)]] + halves(4) + [[whole(5)]]
        case (.double, false, .asIs): expected = [[whole(0), whole(1)], [whole(2), whole(3)], [whole(4), whole(5)]]
        case (.double, true, .asIs): expected = [[whole(0)], [whole(1), whole(2)], [whole(3), whole(4)], [whole(5)]]
        case (.double, false, .single): expected = [[whole(0), whole(1)], [whole(2)], [whole(3)], [whole(4)], [whole(5)]]
        case (.double, true, .single): expected = (0..<6).map { [whole($0)] }
        case (.double, false, .split): expected = [[whole(0), whole(1)]] + halves(2) + [[whole(3)]] + halves(4) + [[whole(5)]]
        case (.double, true, .split): expected = [[whole(0)], [whole(1)]] + halves(2) + [[whole(3)]] + halves(4) + [[whole(5)]]
        }
        if direction == .rightToLeft { expected = expected.map { Array($0.reversed()) } }
        #expect(actual.map(\.elements) == expected)
    }

    @Test("空书与全未知宽高比")
    func unknownPages() {
        let layout = PageLayout(pageMode: .double, direction: .rightToLeft, firstPageSingle: false, widePage: .single)
        #expect(PageFrameEngine.frames(aspectRatios: [], layout: layout).isEmpty)
        #expect(PageFrameEngine.frames(aspectRatios: [nil, nil, nil], layout: layout).map(\.elements) == [
            [PageFrameElement(page: 1), PageFrameElement(page: 0)], [PageFrameElement(page: 2)],
        ])
    }
}
