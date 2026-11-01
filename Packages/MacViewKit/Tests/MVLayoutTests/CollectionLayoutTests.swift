import Foundation
import MVSettings
import Testing
@testable import MVLayout

/// 确定性的伪随机数（SplitMix64），让失败可以复现。
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let shapes: [Double] = [2.0 / 3, 3.0 / 2, 1, 3.0 / 4, 4.0 / 3, 9.0 / 16, 3, 1.0 / 4]

private func ratios(_ count: Int, seed: UInt64 = 1) -> [Double] {
    var random = SplitMix(state: seed)
    return (0..<count).map { _ in shapes[Int(random.next() % UInt64(shapes.count))] }
}

private func layout(
    _ kind: CollectionLayoutKind, _ ratios: [Double?], viewport: CGSize = CGSize(width: 1200, height: 800),
    extent: Double = 220, direction: ReadingDirection = .leftToRight
) -> CollectionLayout {
    var layout = CollectionLayout(kind: kind, viewportSize: viewport, itemExtent: extent, spacing: 8, direction: direction)
    layout.setAspectRatios(ratios)
    return layout
}

private let allKinds: [(CollectionLayoutKind, ReadingDirection)] = [
    (.masonry, .leftToRight), (.grid, .leftToRight), (.verticalStrip, .leftToRight),
    (.horizontalStrip, .leftToRight), (.horizontalStrip, .rightToLeft),
]

// MARK: - 四种布局

@Test func masonryColumnsFollowItemExtentAndEachItemGoesToTheShortestColumn() {
    let values = ratios(500)
    let layout = layout(.masonry, values)
    // (1200 - 8) / (220 + 8) = 5.2 → 5 列，列宽 (1200 - 6 × 8) / 5。
    #expect(layout.columnCount == 5)
    let width = (1200.0 - 48) / 5
    var ends = Array(repeating: 8.0, count: 5)
    for index in values.indices {
        let column = ends.indices.min { (ends[$0], $0) < (ends[$1], $1) }!
        let expected = CGRect(x: 8 + Double(column) * (width + 8), y: ends[column], width: width, height: (width / values[index]).rounded())
        #expect(layout.frame(of: index) == expected)
        ends[column] += expected.height + 8
    }
    #expect(layout.contentSize == CGSize(width: 1200, height: ends.max()!))
}

@Test func gridUsesSquareCellsAndPlacesItemsWhoseRatioIsUnknown() {
    let layout = layout(.grid, [1, nil, 2, nil, nil, nil, 0.5], viewport: CGSize(width: 700, height: 300), extent: 160)
    // (700 - 8) / 168 = 4.1 → 4 列，单元边长 (700 - 40) / 4 = 165。
    #expect(layout.columnCount == 4)
    #expect(layout.count == 7)
    #expect(layout.frame(of: 0) == CGRect(x: 8, y: 8, width: 165, height: 165))
    #expect(layout.frame(of: 5) == CGRect(x: 8 + 173, y: 8 + 173, width: 165, height: 165))
    #expect(layout.contentSize == CGSize(width: 700, height: 8 + 2 * 173))
    #expect(layout.frame(of: 7) == nil)
}

@Test func verticalStripIsOneCenteredColumnCappedByItemExtent() {
    let capped = layout(.verticalStrip, [0.5, 2], extent: 400)
    #expect(capped.frame(of: 0) == CGRect(x: 400, y: 8, width: 400, height: 800))
    #expect(capped.frame(of: 1) == CGRect(x: 400, y: 816, width: 400, height: 200))
    #expect(capped.contentSize == CGSize(width: 1200, height: 1024))
    // 适合宽度：横截长度为视口宽度减去两侧间距。
    let fitted = layout(.verticalStrip, [1], extent: .infinity)
    #expect(fitted.frame(of: 0) == CGRect(x: 8, y: 8, width: 1184, height: 1184))
}

@Test func horizontalStripRunsAlongReadingDirection() {
    let values: [Double?] = [1, 2, 0.5]
    let leftToRight = layout(.horizontalStrip, values, viewport: CGSize(width: 300, height: 216), extent: 1000)
    #expect(leftToRight.frame(of: 0) == CGRect(x: 8, y: 8, width: 200, height: 200))
    #expect(leftToRight.frame(of: 1) == CGRect(x: 216, y: 8, width: 400, height: 200))
    #expect(leftToRight.contentSize == CGSize(width: 8 + 208 + 408 + 108, height: 216))

    let rightToLeft = layout(.horizontalStrip, values, viewport: CGSize(width: 300, height: 216), extent: 1000, direction: .rightToLeft)
    let width = rightToLeft.contentSize.width
    #expect(rightToLeft.frame(of: 0) == CGRect(x: width - 208, y: 8, width: 200, height: 200))
    #expect(rightToLeft.frame(of: 2)?.minX == 8)
    // 内容比视口短时，右开的第 0 项贴着右边。
    let short = layout(.horizontalStrip, [1], viewport: CGSize(width: 900, height: 216), extent: 1000, direction: .rightToLeft)
    #expect(short.frame(of: 0) == CGRect(x: 900 - 208, y: 8, width: 200, height: 200))
}

@Test func itemsInRectMatchesABruteForceScanForEveryKind() {
    let values = ratios(2000, seed: 7)
    var random = SplitMix(state: 99)
    for (kind, direction) in allKinds {
        let layout = layout(kind, values, direction: direction)
        let all = (0..<layout.count).map { ($0, layout.frame(of: $0)!) }
        for _ in 0..<50 {
            let size = layout.contentSize
            let rect = CGRect(
                x: Double(random.next() % UInt64(max(1, size.width))) - 100, y: Double(random.next() % UInt64(max(1, size.height))) - 100,
                width: Double(random.next() % 1500), height: Double(random.next() % 1500)
            )
            let found = layout.items(in: rect).sorted { $0.index < $1.index }
            let expected = all.filter { $0.1.intersects(rect) }
            #expect(found.map(\.index) == expected.map(\.0), "\(kind) \(direction) \(rect)")
            #expect(found.map(\.frame) == expected.map(\.1))
        }
    }
}

// MARK: - 最长前缀与逐步到达

@Test func onlyTheLongestKnownPrefixIsPlaced() {
    for kind in [CollectionLayoutKind.masonry, .verticalStrip, .horizontalStrip] {
        var layout = layout(kind, [1, 1.5, nil, 2, 0.5])
        #expect(layout.count == 2)
        #expect(layout.frame(of: 2) == nil)
        #expect(layout.items(in: CGRect(x: 0, y: 0, width: 1e6, height: 1e6)).map(\.index).sorted() == [0, 1])
        layout.setAspectRatios([1, 1.5, 0.75, 2, 0.5])
        #expect(layout.count == 5)
        #expect(layout.frame(of: 4) != nil)
    }
}

/// 宽高比按随机的批次陆续到达：每一步都与上一步逐项比较，已排的项不动；最终与一次排完的结果相同。
/// 右开的横向条向左增长，比较的是项到内容右端的距离。
@Test func placedItemsNeverMoveWhileRatiosArriveInBatches() {
    let final = ratios(3000, seed: 3)
    for (kind, direction) in allKinds {
        var random = SplitMix(state: 11)
        var known = Array(repeating: false, count: final.count)
        var current = CollectionLayout(kind: kind, viewportSize: CGSize(width: 1100, height: 700), itemExtent: 200, spacing: 8, direction: direction)
        current.setAspectRatios(Array(repeating: nil, count: final.count))
        var previous: [CGRect] = []
        var step = 0
        func readingFrames() -> [CGRect] {
            (0..<current.count).map { index in
                var frame = current.frame(of: index)!
                if direction == .rightToLeft { frame.origin.x = current.contentSize.width - frame.maxX }
                return frame
            }
        }
        while known.contains(false) {
            // 每批随机揭示一些项，顺序不定，所以前缀时长时短。
            for _ in 0..<150 {
                known[Int(random.next() % UInt64(final.count))] = true
            }
            if step > 40 { known = known.map { _ in true } }
            current.setAspectRatios(final.indices.map { known[$0] ? final[$0] : nil })
            let frames = readingFrames()
            #expect(frames.count >= previous.count)
            #expect(Array(frames.prefix(previous.count)) == previous, "\(kind) \(direction) 第 \(step) 步")
            previous = frames
            step += 1
        }
        #expect(step > 5)
        current = layout(kind, final, viewport: CGSize(width: 1100, height: 700), extent: 200, direction: direction)
        #expect(readingFrames() == previous, "\(kind) \(direction)")
    }
}

@Test func changingAPlacedRatioRelaysOutFromScratch() {
    var incremental = layout(.masonry, ratios(400, seed: 5))
    var changed = ratios(400, seed: 5)
    changed[10] = changed[10] == 1 ? 2 : 1
    incremental.setAspectRatios(changed)
    let fresh = layout(.masonry, changed)
    #expect((0..<400).map { incremental.frame(of: $0) } == (0..<400).map { fresh.frame(of: $0) })
}

// MARK: - 锚点

@Test func leadingAnchorKeepsTheTopItemInPlaceWhenWidthChanges() {
    let values = ratios(5000, seed: 2)
    let wide = layout(.masonry, values, viewport: CGSize(width: 1400, height: 800))
    let viewport = CGRect(x: 0, y: 20_000, width: 1400, height: 800)
    let anchor = try! #require(wide.leadingAnchor(in: viewport))
    // 锚点项的前沿在视口内，且是视口内前沿最靠上的项。
    let frame = wide.frame(of: anchor.index)!
    #expect(frame.minY >= viewport.minY && anchor.offset == frame.minY - viewport.minY)
    #expect(wide.items(in: viewport).allSatisfy { $0.frame.minY < viewport.minY || $0.frame.minY >= frame.minY })

    for width in [800.0, 1000, 1700] {
        let narrow = layout(.masonry, values, viewport: CGSize(width: width, height: 800))
        let origin = try! #require(narrow.viewportOrigin(restoring: anchor))
        let moved = narrow.frame(of: anchor.index)!
        #expect(Double(moved.minY - origin.y) == anchor.offset)
    }
}

@Test func anchorSurvivesLayoutKindChangesAndStaysInsideTheViewport() {
    let values = ratios(5000, seed: 4)
    let start = layout(.masonry, values)
    let viewport = CGRect(x: 0, y: 30_000, width: 1200, height: 800)
    let anchor = try! #require(start.leadingAnchor(in: viewport))
    for (kind, direction) in allKinds {
        let next = layout(kind, values, direction: direction)
        let origin = try! #require(next.viewportOrigin(restoring: anchor), "\(kind)")
        let visible = CGRect(origin: origin, size: next.viewportSize)
        #expect(visible.intersects(next.frame(of: anchor.index)!), "\(kind) \(direction)")
        #expect(CGRect(origin: .zero, size: next.contentSize).contains(visible))
    }
}

@Test func itemCrossingTheLeadingEdgeKeepsItsProportionalPosition() {
    // 纵向条的每项都比视口高：锚点是跨过视口顶部的项，按比例换算。
    let values: [Double?] = Array(repeating: 0.25, count: 20)
    let wide = layout(.verticalStrip, values, viewport: CGSize(width: 1000, height: 800), extent: .infinity)
    let itemTop = wide.frame(of: 3)!.minY
    let length = wide.frame(of: 3)!.height
    let viewport = CGRect(x: 0, y: itemTop + length * 0.4, width: 1000, height: 800)
    let anchor = try! #require(wide.leadingAnchor(in: viewport))
    #expect(anchor.index == 3 && abs(anchor.offset + length * 0.4) < 0.001)

    let narrow = layout(.verticalStrip, values, viewport: CGSize(width: 600, height: 800), extent: .infinity)
    let origin = try! #require(narrow.viewportOrigin(restoring: anchor))
    let frame = narrow.frame(of: 3)!
    #expect(abs((origin.y - frame.minY) / frame.height - 0.4) < 0.001)
}

@Test func restoringClampsSoTheAnchorItemIsFullyVisible() {
    let values = ratios(1000, seed: 6)
    let layout = layout(.grid, values)
    // 偏移超出视口：锚点项贴着视口底部完整显示。
    let origin = try! #require(layout.viewportOrigin(restoring: LayoutAnchor(index: 500, offset: 5000, extent: 10)))
    let frame = layout.frame(of: 500)!
    #expect(origin.y == frame.maxY - 800)
    // 文档起点之前没有内容：原点不小于 0。
    #expect(layout.viewportOrigin(restoring: LayoutAnchor(index: 0, offset: 500, extent: 10)) == .zero)
    #expect(layout.viewportOrigin(restoring: LayoutAnchor(index: 5000, offset: 0, extent: 10)) == nil)
}

@Test func reorderAnchorPrefersTheSelectionThenTheCenterItem() {
    let values = ratios(3000, seed: 8)
    let layout = layout(.masonry, values)
    let viewport = CGRect(x: 0, y: 10_000, width: 1200, height: 800)
    let selected = layout.reorderAnchor(in: viewport, selected: 1234)
    #expect(selected?.index == 1234)
    #expect(selected?.offset == Double(layout.frame(of: 1234)!.minY - viewport.minY))

    let center = try! #require(layout.reorderAnchor(in: viewport, selected: nil))
    // 中心点落在某项里时取它，否则取离中心最近的项（中心可能落在间距里）。
    let distance = { (frame: CGRect) -> Double in
        hypot(max(frame.minX - 600, 0, 600 - frame.maxX), max(frame.minY - 10_400, 0, 10_400 - frame.maxY))
    }
    let nearest = layout.items(in: viewport).min { (distance($0.frame), $0.index) < (distance($1.frame), $1.index) }!
    #expect(center.index == nearest.index)

    // 重排后选中项换了序号：调用方按身份换算序号，原点让它回到原来的相对位置。
    var shuffled = values
    shuffled.swapAt(1234, 20)
    let after = CollectionLayout.make(.masonry, shuffled)
    let moved = LayoutAnchor(index: 20, offset: selected!.offset, extent: selected!.extent)
    let origin = try! #require(after.viewportOrigin(restoring: moved))
    #expect(Double(after.frame(of: 20)!.minY - origin.y) == min(max(selected!.offset, 0), 800 - after.frame(of: 20)!.height))
}

@Test func rightToLeftStripAnchorFollowsTheGrowingLeftEdge() {
    var strip = CollectionLayout(kind: .horizontalStrip, viewportSize: CGSize(width: 1000, height: 300), itemExtent: 284, spacing: 8, direction: .rightToLeft)
    let values = ratios(200, seed: 9)
    strip.setAspectRatios(values.prefix(100).map { $0 } + Array(repeating: nil, count: 100))
    let viewport = CGRect(origin: strip.viewportOrigin(restoring: LayoutAnchor(index: 40, offset: 30, extent: 1))!, size: strip.viewportSize)
    let anchor = try! #require(strip.leadingAnchor(in: viewport))
    let before = strip.frame(of: anchor.index)!.maxX - viewport.minX
    strip.setAspectRatios(values)
    let origin = try! #require(strip.viewportOrigin(restoring: anchor))
    // 右开时项的前沿是右边：右边到视口左边的距离不变。
    #expect(strip.frame(of: anchor.index)!.maxX - origin.x == before)
}

// MARK: - 键盘移动

@Test func movesFollowTheGeometryOfEachLayout() {
    let grid = layout(.grid, Array(repeating: 1, count: 23), viewport: CGSize(width: 700, height: 400), extent: 160)
    #expect(grid.index(moving: 5, .right) == 6)
    #expect(grid.index(moving: 5, .left) == 4)
    #expect(grid.index(moving: 5, .down) == 9)
    #expect(grid.index(moving: 5, .up) == 1)
    #expect(grid.index(moving: 4, .left) == nil)
    #expect(grid.index(moving: 21, .down) == nil)
    #expect(grid.index(moving: 1, .up) == nil)

    let values = ratios(400, seed: 12)
    let masonry = layout(.masonry, values)
    for index in [37, 120, 250] {
        let frame = masonry.frame(of: index)!
        let below = try! #require(masonry.index(moving: index, .down))
        // 同一列中紧接着的下一项。
        let nextInColumn = (0..<masonry.count).filter { masonry.frame(of: $0)!.minX == frame.minX && masonry.frame(of: $0)!.minY > frame.minY }
            .min { masonry.frame(of: $0)!.minY < masonry.frame(of: $1)!.minY }
        #expect(below == nextInColumn)
        if let right = masonry.index(moving: index, .right) {
            let target = masonry.frame(of: right)!
            #expect(target.minX > frame.maxX && target.maxY > frame.minY && target.minY < frame.maxY)
        }
    }

    let rightToLeft = layout(.horizontalStrip, Array(repeating: 1, count: 10), extent: 200, direction: .rightToLeft)
    #expect(rightToLeft.index(moving: 3, .left) == 4)
    #expect(rightToLeft.index(moving: 3, .right) == 2)
    #expect(rightToLeft.index(moving: 3, .up) == nil)
    let vertical = layout(.verticalStrip, Array(repeating: 1, count: 10), extent: 200)
    #expect(vertical.index(moving: 3, .down) == 4)
    #expect(vertical.index(moving: 0, .up) == nil)
}

extension CollectionLayout {
    fileprivate static func make(_ kind: CollectionLayoutKind, _ ratios: [Double]) -> CollectionLayout {
        layout(kind, ratios)
    }
}
