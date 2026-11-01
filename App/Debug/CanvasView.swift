#if DEBUG
import AppKit
import MVFoundation
import MVIO
import MVMedia
import MVPipeline
import os
import QuartzCore

/// 砌体布局：每项放进当前最矮的一列。按列记录项的顺序，同一列里 minY 递增，查询时在每列里二分。
struct MasonryLayout {
    let frames: [CGRect]
    let contentHeight: CGFloat
    private let columns: [[Int]]

    init(aspectRatios: [CGFloat], width: CGFloat, targetColumnWidth: CGFloat, spacing: CGFloat) {
        let count = max(1, Int((width - spacing) / (targetColumnWidth + spacing)))
        let columnWidth = max(1, (width - spacing * CGFloat(count + 1)) / CGFloat(count))
        var heights = Array(repeating: spacing, count: count)
        var columns = Array(repeating: [Int](), count: count)
        var frames: [CGRect] = []
        frames.reserveCapacity(aspectRatios.count)
        for (index, ratio) in aspectRatios.enumerated() {
            var column = 0
            for candidate in 1..<count where heights[candidate] < heights[column] {
                column = candidate
            }
            let height = (columnWidth / ratio).rounded()
            frames.append(CGRect(x: spacing + CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
            columns[column].append(index)
        }
        self.frames = frames
        self.columns = columns
        contentHeight = heights.max() ?? 0
    }

    /// 与 `rect` 相交的项。
    func indices(in rect: CGRect) -> [Int] {
        var result: [Int] = []
        for column in columns {
            var low = 0
            var high = column.count
            while low < high {
                let middle = (low + high) / 2
                if frames[column[middle]].maxY < rect.minY { low = middle + 1 } else { high = middle }
            }
            while low < column.count, frames[column[low]].minY <= rect.maxY {
                result.append(column[low])
                low += 1
            }
        }
        return result
    }
}

/// 画布：只为可见区上下各加一屏余量内的项分配图层，滚出范围的图层回收复用。
/// 缩略图在后台向管线请求，回到主线程后只设置图层的 contents，不做 I/O 和解码。
final class CanvasView: NSView {
    struct Item {
        var location: Location
        var aspectRatio: CGFloat
    }

    struct Counters {
        var activeLayers = 0
        var peakLayers = 0
        var createdLayers = 0
        var loadedImages = 0
        var inFlight = 0
    }

    private let items: [Item]
    private let aspectRatios: [CGFloat]
    private var pipeline: any ImagePipeline
    private var layout: MasonryLayout?
    private var layoutWidth: CGFloat = 0
    private var active: [Int: CALayer] = [:]
    private var spare: [CALayer] = []
    private var loads: [Int: Task<Void, Never>] = [:]
    private let cache = NSCache<NSNumber, CGImage>()
    private let signposter = OSSignposter(category: .layout)
    private(set) var counters = Counters()
    /// 每次更新图层分配与重新排版在主线程上的用时，由测试窗口汇总。
    var onUpdate: ((_ kind: UpdateKind, _ duration: Duration) -> Void)?

    enum UpdateKind {
        case scroll
        case relayout
    }

    init(items: [Item], pipeline: any ImagePipeline) {
        self.items = items
        aspectRatios = items.map(\.aspectRatio)
        self.pipeline = pipeline
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // 约 256 MB 的已解码缩略图，相当于 L1 的一小部分。
        cache.totalCostLimit = 256 << 20
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 换一个管线：丢掉缓存和进行中的请求，可见项重新加载。
    func reset(pipeline: any ImagePipeline) {
        self.pipeline = pipeline
        cache.removeAllObjects()
        for task in loads.values { task.cancel() }
        loads.removeAll()
        recycle(Array(active.keys))
        updateVisible()
    }

    /// 宽度变化时重新排版。全量排版是 O(n) 的纯计算，不涉及 I/O。
    func relayout(width: CGFloat) {
        guard width > 0, width != layoutWidth else { return }
        layoutWidth = width
        let start = ContinuousClock.now
        let state = signposter.beginInterval("relayout")
        let layout = MasonryLayout(aspectRatios: aspectRatios, width: width, targetColumnWidth: 220, spacing: 8)
        self.layout = layout
        setFrameSize(NSSize(width: width, height: max(layout.contentHeight, enclosingScrollView?.contentView.bounds.height ?? 0)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in active {
            layer.frame = layout.frames[index]
        }
        CATransaction.commit()
        signposter.endInterval("relayout", state)
        onUpdate?(.relayout, ContinuousClock.now - start)
        updateVisible()
    }

    /// 按当前可见区分配图层。滚动时每帧调用。
    func updateVisible() {
        guard let layout, let clip = enclosingScrollView?.contentView else { return }
        let start = ContinuousClock.now
        let state = signposter.beginInterval("updateVisible")
        let visible = clip.bounds
        let range = visible.insetBy(dx: 0, dy: -visible.height)
        let wanted = layout.indices(in: range)
        let wantedSet = Set(wanted)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recycle(active.keys.filter { !wantedSet.contains($0) })
        for index in wanted where active[index] == nil {
            let layer = spare.popLast() ?? makeLayer()
            let frame = layout.frames[index]
            layer.frame = frame
            layer.contents = cache.object(forKey: index as NSNumber)
            layer.isHidden = false
            active[index] = layer
            if layer.contents == nil, loads[index] == nil {
                load(index, maxPixel: Int((max(frame.width, frame.height) * (window?.backingScaleFactor ?? 2)).rounded(.up)), priority: visible.intersects(frame) ? .visible : .near)
            }
        }
        CATransaction.commit()
        counters.activeLayers = active.count
        counters.peakLayers = max(counters.peakLayers, active.count)
        counters.inFlight = loads.count
        signposter.endInterval("updateVisible", state)
        onUpdate?(.scroll, ContinuousClock.now - start)
    }

    private func recycle(_ indices: [Int]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in indices {
            guard let layer = active.removeValue(forKey: index) else { continue }
            layer.isHidden = true
            layer.contents = nil
            spare.append(layer)
            loads.removeValue(forKey: index)?.cancel()
        }
        CATransaction.commit()
    }

    private func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer.contentsGravity = .resizeAspectFill
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        self.layer?.addSublayer(layer)
        counters.createdLayers += 1
        return layer
    }

    private func load(_ index: Int, maxPixel: Int, priority: IOPriority) {
        let location = items[index].location
        let pipeline = pipeline
        // 管线调用放在主线程之外；取消会传进管线，排队中的请求直接出队。
        loads[index] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let rendered = try? await pipeline.thumbnail(for: location, maxPixel: min(maxPixel, 1024), priority: priority),
                  !Task.isCancelled
            else { return }
            await self?.apply(rendered, to: index)
        }
    }

    private func apply(_ rendered: RenderedImage, to index: Int) {
        loads[index] = nil
        let image = rendered.image
        cache.setObject(image, forKey: index as NSNumber, cost: image.bytesPerRow * image.height)
        counters.loadedImages += 1
        guard let layer = active[index] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    func cancelAll() {
        for task in loads.values { task.cancel() }
        loads.removeAll()
    }
}
#endif
