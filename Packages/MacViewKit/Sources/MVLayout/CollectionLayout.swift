// MVLayout：App 侧的纯计算布局（画布的四种布局与锚点、停靠布局及其变换）。职责见 docs/architecture.md §2、§3.8。
import Foundation
import MVSettings

public enum CollectionLayoutKind: String, Codable, Sendable, CaseIterable {
    case masonry, grid, verticalStrip, horizontalStrip

    /// 横向条沿 x 滚动，其余沿 y 滚动。
    public var isHorizontal: Bool {
        self == .horizontalStrip
    }
}

/// 选中项在画面上移动的方向。
public enum LayoutMove: Sendable {
    case up, down, left, right
}

/// 锚点项与它在视口中的相对位置。
public struct LayoutAnchor: Sendable, Hashable {
    public var index: Int
    /// 沿阅读方向，锚点项前沿到视口前沿的距离（点）。项跨过视口前沿时为负。
    public var offset: Double
    /// 取锚点时锚点项沿滚动方向的长度。项跨过视口前沿时，按它把 `offset` 换算到项的新长度。
    public var extent: Double

    public init(index: Int, offset: Double, extent: Double) {
        self.index = index
        self.offset = offset
        self.extent = extent
    }
}

/// 画布的布局：只排已知宽高比的最长前缀；宽高比到达后在尾部追加，已排的项不移动。
///
/// - 砌体：列数由 `itemExtent`（目标列宽）决定，每项放进当前最矮的一列。
/// - 网格：边长为列宽的正方形单元。位置与宽高比无关，所有项都排。
/// - 纵向条、横向条：单列或单行，项的横截长度为 `itemExtent` 与视口可用长度中较小的一个，居中。横向条右开时第 0 项在最右。
///
/// 坐标是文档视图的坐标（y 向下）。`contentSize` 即文档尺寸：沿滚动方向不小于视口，横截方向等于视口。
/// 宽高比是宽除以高，必须为正的有限值。
public struct CollectionLayout: Sendable {
    public let kind: CollectionLayoutKind
    public let viewportSize: CGSize
    public let itemExtent: Double
    public let spacing: Double
    public let direction: ReadingDirection
    public private(set) var contentSize: CGSize

    /// 砌体和网格的列数；条为 1。
    public let columnCount: Int
    /// 砌体和网格的列宽；条的横截长度。
    private let cellExtent: Double
    /// 已排各项的宽高比（网格不用）。
    private var ratios: [Double] = []
    /// 已排各项在阅读坐标中的位置：横向条从左往右，右开时输出前再翻转。网格按序号计算，不存。
    private var frames: [CGRect] = []
    /// 砌体每列的项（同一列 minY 递增），查询时在每列里二分。
    private var columns: [[Int]]
    /// 砌体每列、或条的下一项的起点。
    private var columnEnds: [Double]
    /// 网格的项数。
    private var gridCount = 0

    public init(kind: CollectionLayoutKind, viewportSize: CGSize, itemExtent: Double, spacing: Double, direction: ReadingDirection) {
        self.kind = kind
        self.viewportSize = viewportSize
        self.itemExtent = itemExtent
        self.spacing = spacing
        self.direction = direction
        let cross = kind.isHorizontal ? viewportSize.height : viewportSize.width
        switch kind {
        case .masonry, .grid:
            columnCount = max(1, Int((cross - spacing) / (itemExtent + spacing)))
            cellExtent = max(1, (cross - spacing * Double(columnCount + 1)) / Double(columnCount))
        case .verticalStrip, .horizontalStrip:
            columnCount = 1
            cellExtent = max(1, min(itemExtent, cross - spacing * 2))
        }
        columns = Array(repeating: [], count: columnCount)
        columnEnds = Array(repeating: spacing, count: columnCount)
        contentSize = viewportSize
    }

    /// 已排的项数。
    public var count: Int {
        kind == .grid ? gridCount : frames.count
    }

    /// 按全部项的宽高比（未知为 nil）更新。已排部分的宽高比不变时只在尾部追加，否则从头重排。
    public mutating func setAspectRatios(_ ratios: [Double?]) {
        if kind == .grid {
            gridCount = ratios.count
            updateContentSize()
            return
        }
        var known = 0
        while known < ratios.count, ratios[known] != nil {
            known += 1
        }
        let placed = frames.count
        if known < placed || !(0..<placed).allSatisfy({ ratios[$0] == self.ratios[$0] }) {
            self.ratios.removeAll(keepingCapacity: true)
            frames.removeAll(keepingCapacity: true)
            columns = Array(repeating: [], count: columnCount)
            columnEnds = Array(repeating: spacing, count: columnCount)
        }
        frames.reserveCapacity(known)
        for index in frames.count..<known {
            place(index, ratio: ratios[index] ?? 1)
        }
        updateContentSize()
    }

    private mutating func place(_ index: Int, ratio: Double) {
        ratios.append(ratio)
        switch kind {
        case .masonry:
            var column = 0
            for candidate in 1..<columnCount where columnEnds[candidate] < columnEnds[column] {
                column = candidate
            }
            let height = max(1, (cellExtent / ratio).rounded())
            frames.append(CGRect(x: spacing + Double(column) * (cellExtent + spacing), y: columnEnds[column], width: cellExtent, height: height))
            columnEnds[column] += height + spacing
            columns[column].append(index)
        case .verticalStrip:
            let height = max(1, (cellExtent / ratio).rounded())
            frames.append(CGRect(x: ((viewportSize.width - cellExtent) / 2).rounded(), y: columnEnds[0], width: cellExtent, height: height))
            columnEnds[0] += height + spacing
        case .horizontalStrip:
            let width = max(1, (cellExtent * ratio).rounded())
            frames.append(CGRect(x: columnEnds[0], y: ((viewportSize.height - cellExtent) / 2).rounded(), width: width, height: cellExtent))
            columnEnds[0] += width + spacing
        case .grid:
            preconditionFailure("网格按序号计算位置")
        }
    }

    private mutating func updateContentSize() {
        let length: Double
        switch kind {
        case .grid:
            let rows = (gridCount + columnCount - 1) / columnCount
            length = rows == 0 ? 0 : spacing + Double(rows) * (cellExtent + spacing)
        case .masonry, .verticalStrip, .horizontalStrip:
            length = frames.isEmpty ? 0 : columnEnds.max() ?? 0
        }
        contentSize = kind.isHorizontal
            ? CGSize(width: max(length, viewportSize.width), height: viewportSize.height)
            : CGSize(width: viewportSize.width, height: max(length, viewportSize.height))
    }

    // MARK: - 查询

    public func frame(of index: Int) -> CGRect? {
        guard index >= 0, index < count else { return nil }
        return output(readingFrame(index))
    }

    /// 与 `rect` 相交的已排项。
    public func items(in rect: CGRect) -> [(index: Int, frame: CGRect)] {
        let query = output(rect)
        var result: [(index: Int, frame: CGRect)] = []
        switch kind {
        case .grid:
            guard gridCount > 0 else { return [] }
            let step = cellExtent + spacing
            let firstRow = max(0, Int(((query.minY - spacing) / step).rounded(.down)))
            let lastRow = min((gridCount - 1) / columnCount, Int(((query.maxY - spacing) / step).rounded(.down)))
            guard firstRow <= lastRow else { return [] }
            for index in (firstRow * columnCount)..<min(gridCount, (lastRow + 1) * columnCount) {
                let frame = readingFrame(index)
                if frame.intersects(query) { result.append((index, frame)) }
            }
        case .masonry:
            for column in columns {
                var low = 0
                var high = column.count
                while low < high {
                    let middle = (low + high) / 2
                    if frames[column[middle]].maxY < query.minY { low = middle + 1 } else { high = middle }
                }
                while low < column.count, frames[column[low]].minY <= query.maxY {
                    let frame = frames[column[low]]
                    if frame.intersects(query) { result.append((column[low], frame)) }
                    low += 1
                }
            }
        case .verticalStrip, .horizontalStrip:
            let horizontal = kind.isHorizontal
            let (minMain, maxMain) = horizontal ? (query.minX, query.maxX) : (query.minY, query.maxY)
            var low = 0
            var high = frames.count
            while low < high {
                let middle = (low + high) / 2
                if (horizontal ? frames[middle].maxX : frames[middle].maxY) < minMain { low = middle + 1 } else { high = middle }
            }
            while low < frames.count, (horizontal ? frames[low].minX : frames[low].minY) <= maxMain {
                if frames[low].intersects(query) { result.append((low, frames[low])) }
                low += 1
            }
        }
        guard isFlipped else { return result }
        return result.map { ($0.index, output($0.frame)) }
    }

    /// 从 `index` 向 `move` 方向移动到的相邻项：在该方向上与它横向重叠的项中取最近的一个，同样近时取中心最接近的。
    public func index(moving index: Int, _ move: LayoutMove) -> Int? {
        guard let origin = frame(of: index) else { return nil }
        var reach = max(origin.width, origin.height) * 2
        while true {
            let band: CGRect
            switch move {
            case .up: band = CGRect(x: origin.minX, y: origin.minY - reach, width: origin.width, height: reach)
            case .down: band = CGRect(x: origin.minX, y: origin.maxY, width: origin.width, height: reach)
            case .left: band = CGRect(x: origin.minX - reach, y: origin.minY, width: reach, height: origin.height)
            case .right: band = CGRect(x: origin.maxX, y: origin.minY, width: reach, height: origin.height)
            }
            var best: (index: Int, gap: Double, drift: Double)?
            for (candidate, frame) in items(in: band) where candidate != index {
                let gap: Double
                let drift: Double
                switch move {
                case .up: (gap, drift) = (origin.minY - frame.maxY, abs(frame.midX - origin.midX))
                case .down: (gap, drift) = (frame.minY - origin.maxY, abs(frame.midX - origin.midX))
                case .left: (gap, drift) = (origin.minX - frame.maxX, abs(frame.midY - origin.midY))
                case .right: (gap, drift) = (frame.minX - origin.maxX, abs(frame.midY - origin.midY))
                }
                // 只取完全在该方向上、且横向有重叠的项。
                let overlaps = move == .up || move == .down
                    ? min(frame.maxX, origin.maxX) - max(frame.minX, origin.minX) > 0.5
                    : min(frame.maxY, origin.maxY) - max(frame.minY, origin.minY) > 0.5
                guard gap >= -0.5, overlaps else { continue }
                if let current = best, (current.gap, current.drift, current.index) <= (gap, drift, candidate) { continue }
                best = (candidate, gap, drift)
            }
            if let best { return best.index }
            let covered: Bool
            switch move {
            case .up: covered = band.minY <= 0
            case .down: covered = band.maxY >= contentSize.height
            case .left: covered = band.minX <= 0
            case .right: covered = band.maxX >= contentSize.width
            }
            if covered { return nil }
            reach *= 2
        }
    }

    // MARK: - 锚点

    /// 可见区前沿的项：前沿落在视口内的项中最靠前的一个；没有时取跨过视口前沿的项。用于宽度、尺寸和布局种类变化。
    public func leadingAnchor(in viewport: CGRect) -> LayoutAnchor? {
        let start = readingMain(viewport).min
        var inside: (index: Int, main: (min: Double, max: Double))?
        var crossing: (index: Int, main: (min: Double, max: Double))?
        for (index, frame) in items(in: viewport) {
            let main = readingMain(frame)
            if main.min >= start {
                if inside.map({ (main.min, index) < ($0.main.min, $0.index) }) ?? true { inside = (index, main) }
            } else if crossing.map({ (main.min, index) < ($0.main.min, $0.index) }) ?? true {
                crossing = (index, main)
            }
        }
        guard let chosen = inside ?? crossing else { return nil }
        return anchor(chosen.index, start: start)
    }

    /// 数据整体重排时的锚点：取选中项；没有选中项（或它还没排）时取可见区中心的项。
    public func reorderAnchor(in viewport: CGRect, selected: Int?) -> LayoutAnchor? {
        let start = readingMain(viewport).min
        if let selected, frame(of: selected) != nil {
            return anchor(selected, start: start)
        }
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        var best: (index: Int, distance: Double)?
        for (index, frame) in items(in: viewport) {
            let dx = max(frame.minX - center.x, 0, center.x - frame.maxX)
            let dy = max(frame.minY - center.y, 0, center.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if best.map({ (distance, index) < ($0.distance, $0.index) }) ?? true { best = (index, distance) }
        }
        return best.map { anchor($0.index, start: start) }
    }

    /// 已排的项相对于视口前沿 `start` 的锚点。
    private func anchor(_ index: Int, start: Double) -> LayoutAnchor {
        let main = readingMain(output(readingFrame(index)))
        return LayoutAnchor(index: index, offset: main.min - start, extent: main.max - main.min)
    }

    /// 让锚点项回到它在视口中的相对位置时，视口的原点。锚点项还没排时为 nil。
    ///
    /// 位置按锚点项能完整显示的范围收紧：项比视口短时整项可见，比视口长时铺满视口。
    public func viewportOrigin(restoring anchor: LayoutAnchor) -> CGPoint? {
        guard let frame = frame(of: anchor.index) else { return nil }
        let main = readingMain(frame)
        let length = main.max - main.min
        let viewportLength = kind.isHorizontal ? viewportSize.width : viewportSize.height
        let contentLength = kind.isHorizontal ? contentSize.width : contentSize.height
        var offset = anchor.offset < 0 && anchor.extent > 0 ? anchor.offset * length / anchor.extent : anchor.offset
        offset = min(max(offset, -max(0, length - viewportLength)), max(0, viewportLength - length))
        let start = min(max(main.min - offset, 0), max(0, contentLength - viewportLength))
        guard kind.isHorizontal else { return CGPoint(x: 0, y: start) }
        return CGPoint(x: isFlipped ? contentLength - start - viewportLength : start, y: 0)
    }

    // MARK: - 坐标

    /// 右开的横向条：阅读坐标与文档坐标左右翻转。
    private var isFlipped: Bool {
        kind == .horizontalStrip && direction == .rightToLeft
    }

    private func readingFrame(_ index: Int) -> CGRect {
        guard kind == .grid else { return frames[index] }
        let row = index / columnCount
        let column = index % columnCount
        return CGRect(x: spacing + Double(column) * (cellExtent + spacing), y: spacing + Double(row) * (cellExtent + spacing), width: cellExtent, height: cellExtent)
    }

    /// 阅读坐标与文档坐标互换（翻转是自身的逆）。
    private func output(_ rect: CGRect) -> CGRect {
        guard isFlipped else { return rect }
        var flipped = rect
        flipped.origin.x = contentSize.width - rect.maxX
        return flipped
    }

    /// 文档坐标中的矩形沿阅读方向的起止。
    private func readingMain(_ rect: CGRect) -> (min: Double, max: Double) {
        guard kind.isHorizontal else { return (rect.minY, rect.maxY) }
        let reading = output(rect)
        return (reading.minX, reading.maxX)
    }
}
