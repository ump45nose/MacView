import AppKit
import MVFoundation
import MVMedia
import MVPipeline
import MVReading
import QuartzCore

/// 超大图放大后的分块层，垫在它下面的是整图的适合尺寸。只请求可见的块；移出视口的马上取消，停下 100 ms 后再补发新块。
///
/// 块按 1/2ⁿ 的级别对齐，每块输出约 1024 像素。半页时层比页宽一倍，由页的 `masksToBounds` 裁出。
@MainActor
final class TiledPageLayer {
    private struct Key: Hashable {
        var column: Int
        var row: Int
    }

    private struct Tile {
        var layer: CALayer
        var rect: CGRect
        var task: Task<Void, Never>?
    }

    private static let tileOutput = 1024.0
    let root = CALayer()
    private let identity: ContentIdentity
    private let sourceSize: PixelSize
    private let part: PagePart
    private let pipeline: any ImagePipeline
    private var source: (any TiledImageSource)?
    private var sourceTask: Task<Void, Never>?
    private var level = 0.0
    private var tiles: [Key: Tile] = [:]
    private var whole = CGRect.zero
    private var visible = CGRect.zero
    private var syncTimer: Timer?
    var onFailure: ((any Error) -> Void)?
    /// 累计发出和取消的块请求数，供自检读取。
    private(set) var requestedTiles = 0
    private(set) var cancelledTiles = 0
    /// 累计移出视口而丢弃的块数。
    private(set) var discardedTiles = 0
    var activeTiles: Int { tiles.count }
    /// 仍挂着任务的块数。
    var inFlightTiles: Int { tiles.values.reduce(0) { $0 + ($1.task == nil ? 0 : 1) } }
    /// 最近一批请求里最大的块（原图像素）。
    private(set) var largestRequest = CGSize.zero

    init(identity: ContentIdentity, sourceSize: PixelSize, part: PagePart, pipeline: any ImagePipeline) {
        self.identity = identity
        self.sourceSize = sourceSize
        self.part = part
        self.pipeline = pipeline
    }

    /// `bounds` 是页的范围，`visible` 是视图在页坐标里的范围，都是点。
    func layout(in bounds: CGRect, visible: CGRect, scale: Double) {
        root.frame = bounds
        switch part {
        case .whole: whole = bounds
        case .leftHalf: whole = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
        case .rightHalf: whole = CGRect(x: -bounds.width, y: 0, width: bounds.width * 2, height: bounds.height)
        }
        self.visible = visible.intersection(bounds)
        let perSource = whole.width * scale / Double(sourceSize.width)
        let wanted = perSource >= 1 ? 1 : pow(2, ceil(log2(perSource)))
        if wanted != level {
            level = wanted
            clear()
        }
        for tile in tiles.values { tile.layer.frame = frame(of: tile.rect) }
        cancelOutsideVisible()
        scheduleSync()
    }

    func cancel() {
        syncTimer?.invalidate()
        syncTimer = nil
        sourceTask?.cancel()
        clear()
    }

    private func clear() {
        for tile in tiles.values {
            if tile.task != nil { cancelledTiles += 1 }
            tile.task?.cancel()
            tile.layer.removeFromSuperlayer()
        }
        tiles.removeAll()
    }

    private func frame(of rect: CGRect) -> CGRect {
        let ratio = whole.width / Double(sourceSize.width)
        return CGRect(x: whole.minX + rect.minX * ratio, y: whole.minY + rect.minY * ratio, width: rect.width * ratio, height: rect.height * ratio)
    }

    private func tileSide() -> Double? {
        guard level > 0 else { return nil }
        return Self.tileOutput / level
    }

    /// 当前视口覆盖的块。源或级别还没定下来时返回 nil，调用方先不要动已有的块。
    private func wantedTiles() -> Set<Key>? {
        guard !visible.isEmpty else { return [] }
        guard source != nil, let side = tileSide(), whole.width > 0 else { return nil }
        let ratio = Double(sourceSize.width) / whole.width
        let columns = Int(floor((visible.minX - whole.minX) * ratio / side))..<Int(ceil((visible.maxX - whole.minX) * ratio / side))
        let rows = Int(floor((visible.minY - whole.minY) * ratio / side))..<Int(ceil((visible.maxY - whole.minY) * ratio / side))
        var wanted = Set<Key>()
        for column in columns {
            for row in rows { wanted.insert(Key(column: column, row: row)) }
        }
        return wanted
    }

    private func cancelOutsideVisible() {
        guard let wanted = wantedTiles() else { return }
        cancel(outside: wanted)
    }

    private func cancel(outside wanted: Set<Key>) {
        for (key, tile) in tiles where !wanted.contains(key) {
            if tile.task != nil { cancelledTiles += 1 }
            discardedTiles += 1
            tile.task?.cancel()
            tile.layer.removeFromSuperlayer()
            tiles[key] = nil
        }
    }

    private func scheduleSync() {
        syncTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func sync() {
        guard let source else {
            guard sourceTask == nil else { return }
            let pipeline = pipeline
            let identity = identity
            sourceTask = Task { [weak self] in
                do {
                    let source = try await pipeline.tiledSource(for: identity)
                    guard let self, !Task.isCancelled else { return }
                    self.source = source
                    sync()
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.onFailure?(error)
                }
            }
            return
        }
        guard let wanted = wantedTiles(), let side = tileSide() else { return }
        cancel(outside: wanted)
        let level = level
        largestRequest = .zero
        for key in wanted where tiles[key] == nil {
            let x = Double(key.column) * side
            let y = Double(key.row) * side
            let rect = CGRect(x: x, y: y, width: min(side, Double(sourceSize.width) - x), height: min(side, Double(sourceSize.height) - y))
            guard rect.width > 0, rect.height > 0 else { continue }
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.frame = frame(of: rect)
            root.addSublayer(layer)
            requestedTiles += 1
            largestRequest = CGSize(width: max(largestRequest.width, rect.width), height: max(largestRequest.height, rect.height))
            let task = Task { [weak self] in
                do {
                    let image = try await source.tile(rect, scale: level)
                    guard let self, !Task.isCancelled else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.contents = image.surface ?? image.image
                    CATransaction.commit()
                    tiles[key]?.task = nil
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    tiles[key]?.task = nil
                    onFailure?(error)
                }
            }
            tiles[key] = Tile(layer: layer, rect: rect, task: task)
        }
    }
}
