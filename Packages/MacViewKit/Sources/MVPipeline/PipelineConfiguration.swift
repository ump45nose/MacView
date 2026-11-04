import Foundation
import MVCache
import MVFoundation
import MVMedia

/// 各层缓存的生命周期、预算与 flush 由组合根管理。
public struct PipelineCaches: Sendable {
    public var raw: MemoryCache<String, Data>
    public var decoded: MemoryCache<String, RenderedImage>
    public var thumbnailMemory: MemoryCache<String, RenderedImage>
    public var preload: MemoryCache<String, RenderedImage>
    public var thumbnails: DiskCache
    public var browse: DiskCache?
    public var metadata: MetadataIndex

    public init(raw: MemoryCache<String, Data>, decoded: MemoryCache<String, RenderedImage>, thumbnails: DiskCache, browse: DiskCache?, metadata: MetadataIndex,
                thumbnailMemory: MemoryCache<String, RenderedImage> = MemoryCache(budget: 512 << 20),
                preload: MemoryCache<String, RenderedImage> = MemoryCache(budget: 512 << 20)) {
        self.raw = raw
        self.decoded = decoded
        self.thumbnailMemory = thumbnailMemory
        self.preload = preload
        self.thumbnails = thumbnails
        self.browse = browse
        self.metadata = metadata
    }
}

public struct PipelineMemorySnapshot: Sendable {
    public var rawBytes: Int64
    public var decodedBytes: Int64
    public var thumbnailMemoryBytes: Int64
    public var preloadBytes: Int64
    public var inFlightBytes: Int64
    public var waitingTasks: Int
}

public struct PipelineConfiguration: Sendable {
    public var thumbnailLongSide: Int
    public var browseBounds: PixelSize
    public var maxDecodeLongSide: Int

    public init(thumbnailLongSide: Int = 1024, browseBounds: PixelSize, maxDecodeLongSide: Int = 16384) {
        self.thumbnailLongSide = thumbnailLongSide
        self.browseBounds = browseBounds
        self.maxDecodeLongSide = maxDecodeLongSide
    }
}
