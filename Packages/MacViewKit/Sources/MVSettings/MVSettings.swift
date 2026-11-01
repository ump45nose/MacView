// MVSettings：设置模式、分层解析、路径规则、JSON 存储与书记忆。职责与契约见 docs/architecture.md §2、§4。
import Foundation
import MVFoundation

public enum BrowseMode: String, Codable, Sendable { case paged, waterfall, verticalStrip, horizontalStrip }
public enum PageMode: String, Codable, Sendable { case single, double }
public enum ReadingDirection: String, Codable, Sendable { case leftToRight, rightToLeft }
public enum WidePagePolicy: String, Codable, Sendable { case asIs, single, split }
public enum ScaleMode: String, Codable, Sendable { case original, fitWindow, fitWidth, fitHeight, fill, fixed, devicePixel }
public enum SortKey: String, Codable, Sendable { case name, modified, created, size, type, random }

public struct SortSpec: Codable, Sendable, Hashable {
    public var key: SortKey
    public var ascending: Bool
    public var foldersFirst: Bool
    /// 随机排序的种子，记在书记忆里，重开时顺序不变。
    public var randomSeed: UInt64?

    public init(key: SortKey, ascending: Bool = true, foldersFirst: Bool = true, randomSeed: UInt64? = nil) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.randomSeed = randomSeed
    }
}

public struct RecursionSpec: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var maxDepth: Int

    public init(enabled: Bool, maxDepth: Int) {
        self.enabled = enabled
        self.maxDepth = maxDepth
    }
}

/// 一层书设置（路径规则或书记忆），只写自己覆盖的字段。
///
/// “仅缩小不放大”是适合类缩放模式加上 `allowUpscale = false`。
public struct BookSettings: Codable, Sendable, Hashable {
    public var browseMode: BrowseMode?
    public var pageMode: PageMode?
    public var direction: ReadingDirection?
    public var firstPageSingle: Bool?
    public var widePage: WidePagePolicy?
    public var sort: SortSpec?
    public var recursion: RecursionSpec?
    public var scaleMode: ScaleMode?
    public var allowUpscale: Bool?
    public var fixedScale: Double?
    public var keepZoomOnPageTurn: Bool?
    public var resample: ResampleFilter?
    public var sharpen: Float?

    public init(
        browseMode: BrowseMode? = nil, pageMode: PageMode? = nil, direction: ReadingDirection? = nil,
        firstPageSingle: Bool? = nil, widePage: WidePagePolicy? = nil, sort: SortSpec? = nil, recursion: RecursionSpec? = nil,
        scaleMode: ScaleMode? = nil, allowUpscale: Bool? = nil, fixedScale: Double? = nil, keepZoomOnPageTurn: Bool? = nil,
        resample: ResampleFilter? = nil, sharpen: Float? = nil
    ) {
        self.browseMode = browseMode
        self.pageMode = pageMode
        self.direction = direction
        self.firstPageSingle = firstPageSingle
        self.widePage = widePage
        self.sort = sort
        self.recursion = recursion
        self.scaleMode = scaleMode
        self.allowUpscale = allowUpscale
        self.fixedScale = fixedScale
        self.keepZoomOnPageTurn = keepZoomOnPageTurn
        self.resample = resample
        self.sharpen = sharpen
    }
}

/// 解析后的书设置：与 BookSettings 字段相同，全部有值。
public struct ResolvedBookSettings: Codable, Sendable, Hashable {
    public var browseMode: BrowseMode
    public var pageMode: PageMode
    public var direction: ReadingDirection
    public var firstPageSingle: Bool
    public var widePage: WidePagePolicy
    public var sort: SortSpec
    public var recursion: RecursionSpec
    public var scaleMode: ScaleMode
    public var allowUpscale: Bool
    public var fixedScale: Double
    public var keepZoomOnPageTurn: Bool
    public var resample: ResampleFilter
    public var sharpen: Float

    public init(
        browseMode: BrowseMode, pageMode: PageMode, direction: ReadingDirection,
        firstPageSingle: Bool, widePage: WidePagePolicy, sort: SortSpec, recursion: RecursionSpec,
        scaleMode: ScaleMode, allowUpscale: Bool, fixedScale: Double, keepZoomOnPageTurn: Bool,
        resample: ResampleFilter, sharpen: Float
    ) {
        self.browseMode = browseMode
        self.pageMode = pageMode
        self.direction = direction
        self.firstPageSingle = firstPageSingle
        self.widePage = widePage
        self.sort = sort
        self.recursion = recursion
        self.scaleMode = scaleMode
        self.allowUpscale = allowUpscale
        self.fixedScale = fixedScale
        self.keepZoomOnPageTurn = keepZoomOnPageTurn
        self.resample = resample
        self.sharpen = sharpen
    }

    /// 内置默认值，S1-T7 可以按需调整。
    public static let `default` = ResolvedBookSettings(
        browseMode: .paged, pageMode: .single, direction: .leftToRight,
        firstPageSingle: true, widePage: .single, sort: SortSpec(key: .name), recursion: RecursionSpec(enabled: false, maxDepth: 1),
        scaleMode: .fitWindow, allowUpscale: false, fixedScale: 1, keepZoomOnPageTurn: false,
        resample: .lanczos, sharpen: 0
    )

    /// 逐字段合并：`layer` 中有值的字段覆盖当前值。
    public func applying(_ layer: BookSettings) -> ResolvedBookSettings {
        var result = self
        if let value = layer.browseMode { result.browseMode = value }
        if let value = layer.pageMode { result.pageMode = value }
        if let value = layer.direction { result.direction = value }
        if let value = layer.firstPageSingle { result.firstPageSingle = value }
        if let value = layer.widePage { result.widePage = value }
        if let value = layer.sort { result.sort = value }
        if let value = layer.recursion { result.recursion = value }
        if let value = layer.scaleMode { result.scaleMode = value }
        if let value = layer.allowUpscale { result.allowUpscale = value }
        if let value = layer.fixedScale { result.fixedScale = value }
        if let value = layer.keepZoomOnPageTurn { result.keepZoomOnPageTurn = value }
        if let value = layer.resample { result.resample = value }
        if let value = layer.sharpen { result.sharpen = value }
        return result
    }
}

/// 各级缓存的容量预算，字节。含义见 architecture.md §3.4。
public struct CacheBudgets: Codable, Sendable, Hashable {
    /// L0：近期读取的原始文件字节。
    public var rawBytes: Int64
    /// L1：显示尺寸图与原图的解码结果。
    public var decodedBytes: Int64
    /// L2：缩略图。
    public var thumbnailBytes: Int64
    /// L3：浏览图，可以关闭。
    public var browseBytes: Int64
    public var browseCacheEnabled: Bool

    public init(rawBytes: Int64, decodedBytes: Int64, thumbnailBytes: Int64, browseBytes: Int64, browseCacheEnabled: Bool) {
        self.rawBytes = rawBytes
        self.decodedBytes = decodedBytes
        self.thumbnailBytes = thumbnailBytes
        self.browseBytes = browseBytes
        self.browseCacheEnabled = browseCacheEnabled
    }

    /// L1 取 2 GB 与物理内存 10% 中较小的一个。
    public static let `default` = CacheBudgets(
        rawBytes: 512 << 20,
        decodedBytes: min(2 << 30, Int64(ProcessInfo.processInfo.physicalMemory / 10)),
        thumbnailBytes: 10 << 30,
        browseBytes: 50 << 30,
        browseCacheEnabled: true
    )
}

/// 默认的预取范围，含义见 architecture.md §3.4。
public struct PrefetchRanges: Codable, Sendable, Hashable {
    /// 查看器：前后各预解码几个页帧。
    public var viewerDecodeFrames: Int
    /// 查看器：阅读方向上再往前预读几页的原始字节。
    public var viewerReadAheadPages: Int
    /// 画廊：可见区域外再加几屏的余量。
    public var galleryMarginScreens: Double
    /// 是否预生成当前书全部页面的缩略图和元数据。
    public var currentBookPages: Bool
    /// 预生成书架上之后几本书。
    public var neighborBooks: Int
    /// 是否预生成当前目录各书的封面。
    public var shelfCovers: Bool

    public init(viewerDecodeFrames: Int, viewerReadAheadPages: Int, galleryMarginScreens: Double, currentBookPages: Bool, neighborBooks: Int, shelfCovers: Bool) {
        self.viewerDecodeFrames = viewerDecodeFrames
        self.viewerReadAheadPages = viewerReadAheadPages
        self.galleryMarginScreens = galleryMarginScreens
        self.currentBookPages = currentBookPages
        self.neighborBooks = neighborBooks
        self.shelfCovers = shelfCovers
    }

    public static let `default` = PrefetchRanges(
        viewerDecodeFrames: 2, viewerReadAheadPages: 5, galleryMarginScreens: 1,
        currentBookPages: true, neighborBooks: 2, shelfCovers: true
    )
}

public struct GlobalSettings: Codable, Sendable, Hashable {
    public var defaultBook: ResolvedBookSettings
    public var cache: CacheBudgets
    public var prefetch: PrefetchRanges
    /// 显示尺寸解码的长边上限；放大超过它时解码原图或分块。
    public var maxDecodeLongSide: Int

    public init(defaultBook: ResolvedBookSettings, cache: CacheBudgets, prefetch: PrefetchRanges, maxDecodeLongSide: Int) {
        self.defaultBook = defaultBook
        self.cache = cache
        self.prefetch = prefetch
        self.maxDecodeLongSide = maxDecodeLongSide
    }

    public static let `default` = GlobalSettings(defaultBook: .default, cache: .default, prefetch: .default, maxDecodeLongSide: 8192)
}

/// 路径规则：位置在 `prefix` 下的书套用 `settings`。越具体的规则越靠后应用。
public struct PathRule: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var prefix: Location
    public var settings: BookSettings

    public init(id: UUID = UUID(), name: String, prefix: Location, settings: BookSettings) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.settings = settings
    }
}

/// 一本书的记忆：书层设置与上次的页位置。
public struct BookMemory: Codable, Sendable, Hashable {
    public var book: Location
    public var settings: BookSettings
    public var lastPage: Location?
    public var lastPageIndex: Int?
    public var openedAt: Date

    public init(book: Location, settings: BookSettings = BookSettings(), lastPage: Location? = nil, lastPageIndex: Int? = nil, openedAt: Date = Date()) {
        self.book = book
        self.settings = settings
        self.lastPage = lastPage
        self.lastPageIndex = lastPageIndex
        self.openedAt = openedAt
    }
}

public enum SettingsChange: Sendable, Equatable {
    case global
    case pathRules
    /// 设置文件解析失败；仍沿用上一份可用的配置。
    case fileError(file: String, message: String)
}

public protocol SettingsStore: Sendable {
    /// 全局 ⊕ 匹配的路径规则（越具体越靠后）⊕ 书记忆，逐字段合并。
    func resolve(for book: Location) async -> ResolvedBookSettings
    func bookMemory(for book: Location) async -> BookMemory?
    func saveBookMemory(_ memory: BookMemory) async
    func global() async -> GlobalSettings
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws
    func changes() -> AsyncStream<SettingsChange>
}
