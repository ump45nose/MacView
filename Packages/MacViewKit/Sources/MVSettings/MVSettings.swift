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
    public var effects: EffectChain?
    public var background: ViewerBackground?

    public init(
        browseMode: BrowseMode? = nil, pageMode: PageMode? = nil, direction: ReadingDirection? = nil,
        firstPageSingle: Bool? = nil, widePage: WidePagePolicy? = nil, sort: SortSpec? = nil, recursion: RecursionSpec? = nil,
        scaleMode: ScaleMode? = nil, allowUpscale: Bool? = nil, fixedScale: Double? = nil, keepZoomOnPageTurn: Bool? = nil,
        resample: ResampleFilter? = nil, sharpen: Float? = nil,
        effects: EffectChain? = nil, background: ViewerBackground? = nil
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
        self.effects = effects
        self.background = background
    }

    /// 用 `other` 里有值的字段覆盖自己（套用配置、存为路径规则共用）。
    public mutating func merge(_ other: BookSettings) {
        if let value = other.browseMode { browseMode = value }
        if let value = other.pageMode { pageMode = value }
        if let value = other.direction { direction = value }
        if let value = other.firstPageSingle { firstPageSingle = value }
        if let value = other.widePage { widePage = value }
        if let value = other.sort { sort = value }
        if let value = other.recursion { recursion = value }
        if let value = other.scaleMode { scaleMode = value }
        if let value = other.allowUpscale { allowUpscale = value }
        if let value = other.fixedScale { fixedScale = value }
        if let value = other.keepZoomOnPageTurn { keepZoomOnPageTurn = value }
        if let value = other.resample { resample = value }
        if let value = other.sharpen { sharpen = value }
        if let value = other.effects { effects = value }
        if let value = other.background { background = value }
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
    public var effects: EffectChain
    public var background: ViewerBackground

    public init(
        browseMode: BrowseMode, pageMode: PageMode, direction: ReadingDirection,
        firstPageSingle: Bool, widePage: WidePagePolicy, sort: SortSpec, recursion: RecursionSpec,
        scaleMode: ScaleMode, allowUpscale: Bool, fixedScale: Double, keepZoomOnPageTurn: Bool,
        resample: ResampleFilter, sharpen: Float,
        effects: EffectChain = .empty, background: ViewerBackground = .auto
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
        self.effects = effects
        self.background = background
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            browseMode: try values.decode(BrowseMode.self, forKey: .browseMode),
            pageMode: try values.decode(PageMode.self, forKey: .pageMode),
            direction: try values.decode(ReadingDirection.self, forKey: .direction),
            firstPageSingle: try values.decode(Bool.self, forKey: .firstPageSingle),
            widePage: try values.decode(WidePagePolicy.self, forKey: .widePage),
            sort: try values.decode(SortSpec.self, forKey: .sort),
            recursion: try values.decode(RecursionSpec.self, forKey: .recursion),
            scaleMode: try values.decode(ScaleMode.self, forKey: .scaleMode),
            allowUpscale: try values.decode(Bool.self, forKey: .allowUpscale),
            fixedScale: try values.decode(Double.self, forKey: .fixedScale),
            keepZoomOnPageTurn: try values.decode(Bool.self, forKey: .keepZoomOnPageTurn),
            resample: try values.decode(ResampleFilter.self, forKey: .resample),
            sharpen: try values.decode(Float.self, forKey: .sharpen),
            effects: try values.decodeIfPresent(EffectChain.self, forKey: .effects) ?? .empty,
            background: try values.decodeIfPresent(ViewerBackground.self, forKey: .background) ?? .auto
        )
    }

    /// 内置默认值，S1-T7 可以按需调整。
    public static let `default` = ResolvedBookSettings(
        browseMode: .paged, pageMode: .single, direction: .leftToRight,
        firstPageSingle: true, widePage: .single, sort: SortSpec(key: .name), recursion: RecursionSpec(enabled: false, maxDepth: 1),
        scaleMode: .fitWindow, allowUpscale: false, fixedScale: 1, keepZoomOnPageTurn: false,
        resample: .lanczos, sharpen: 0, effects: .empty, background: .auto
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
        if let value = layer.effects { result.effects = value }
        if let value = layer.background { result.background = value }
        return result
    }
}

/// 各级缓存的容量预算，字节。含义见 architecture.md §3.4。
public struct CacheBudgets: Codable, Sendable, Hashable {
    /// L0：近期读取的原始文件字节。
    public var rawBytes: Int64
    /// 可见请求的解码结果。
    public var decodedBytes: Int64
    public var thumbnailMemoryBytes: Int64
    public var preloadBytes: Int64
    /// L2：缩略图。
    public var thumbnailBytes: Int64
    /// L3：浏览图，可以关闭。
    public var browseBytes: Int64
    public var browseCacheEnabled: Bool

    public init(rawBytes: Int64, decodedBytes: Int64, thumbnailBytes: Int64, browseBytes: Int64, browseCacheEnabled: Bool,
                thumbnailMemoryBytes: Int64, preloadBytes: Int64) {
        self.rawBytes = rawBytes
        self.decodedBytes = decodedBytes
        self.thumbnailMemoryBytes = thumbnailMemoryBytes
        self.preloadBytes = preloadBytes
        self.thumbnailBytes = thumbnailBytes
        self.browseBytes = browseBytes
        self.browseCacheEnabled = browseCacheEnabled
    }

    /// `settings.json` 是外部输入：容量预算必须为正，否则整份文件按配置错误处理、保留上次的值，缓存层不另设下限。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func positive(_ key: CodingKeys) throws -> Int64 {
            let value = try container.decode(Int64.self, forKey: key)
            guard value > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: String(localized: "\(key.stringValue) 必须大于 0，现在是 \(value)", bundle: .main)
                )
            }
            return value
        }
        self.init(rawBytes: try positive(.rawBytes), decodedBytes: try positive(.decodedBytes),
                  thumbnailBytes: try positive(.thumbnailBytes), browseBytes: try positive(.browseBytes),
                  browseCacheEnabled: try container.decode(Bool.self, forKey: .browseCacheEnabled),
                  thumbnailMemoryBytes: try positive(.thumbnailMemoryBytes), preloadBytes: try positive(.preloadBytes))
    }

    /// 可见解码缓存取 1 GB 与物理内存 5% 中较小的一个。
    public static let `default` = CacheBudgets(
        rawBytes: 512 << 20,
        decodedBytes: min(1 << 30, Int64(ProcessInfo.processInfo.physicalMemory / 20)),
        thumbnailBytes: 10 << 30,
        browseBytes: 50 << 30,
        browseCacheEnabled: true,
        thumbnailMemoryBytes: 512 << 20,
        preloadBytes: 512 << 20
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

public struct ClassifyTarget: Codable, Sendable, Hashable {
    public var location: Location
    public var listsSubfolders: Bool
    public init(location: Location, listsSubfolders: Bool = false) { self.location = location; self.listsSubfolders = listsSubfolders }
}

public struct FileOperationSettings: Codable, Sendable, Hashable {
    public var nameConflict: ConflictPolicy
    public var classifyMode: TransferMode
    public var classifyTargets: [ClassifyTarget]
    public init(nameConflict: ConflictPolicy = .appendNumber, classifyMode: TransferMode = .move, classifyTargets: [ClassifyTarget] = []) {
        self.nameConflict = nameConflict; self.classifyMode = classifyMode; self.classifyTargets = classifyTargets
    }
    public static let `default` = FileOperationSettings()
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(nameConflict: try values.decodeIfPresent(ConflictPolicy.self, forKey: .nameConflict) ?? .appendNumber,
                  classifyMode: try values.decodeIfPresent(TransferMode.self, forKey: .classifyMode) ?? .move,
                  classifyTargets: try values.decodeIfPresent([ClassifyTarget].self, forKey: .classifyTargets) ?? [])
    }
}

public struct GlobalSettings: Codable, Sendable, Hashable {
    public var defaultBook: ResolvedBookSettings
    public var cache: CacheBudgets
    public var prefetch: PrefetchRanges
    /// 显示尺寸解码的长边上限；放大超过它时解码原图或分块。
    public var maxDecodeLongSide: Int
    public var fileOperations: FileOperationSettings
    public var historyLimit: Int
    public var appearance: AppearanceSettings
    public var videoHoverPreview: Bool

    public init(defaultBook: ResolvedBookSettings, cache: CacheBudgets, prefetch: PrefetchRanges, maxDecodeLongSide: Int, fileOperations: FileOperationSettings = .default, historyLimit: Int = 1000, appearance: AppearanceSettings = .default, videoHoverPreview: Bool = true) {
        self.defaultBook = defaultBook
        self.cache = cache
        self.prefetch = prefetch
        self.maxDecodeLongSide = maxDecodeLongSide
        self.fileOperations = fileOperations
        self.historyLimit = historyLimit
        self.appearance = appearance
        self.videoHoverPreview = videoHoverPreview
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(defaultBook: try values.decode(ResolvedBookSettings.self, forKey: .defaultBook),
                  cache: try values.decode(CacheBudgets.self, forKey: .cache),
                  prefetch: try values.decode(PrefetchRanges.self, forKey: .prefetch),
                  maxDecodeLongSide: try values.decode(Int.self, forKey: .maxDecodeLongSide),
                  fileOperations: try values.decodeIfPresent(FileOperationSettings.self, forKey: .fileOperations) ?? .default,
                  historyLimit: try values.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 1000,
                  appearance: try values.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? .default,
                  videoHoverPreview: try values.decodeIfPresent(Bool.self, forKey: .videoHoverPreview) ?? true)
        guard historyLimit > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .historyLimit, in: values,
                debugDescription: String(localized: "\("historyLimit") 必须大于 0，现在是 \(historyLimit)", bundle: .main))
        }
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

    /// 匹配这本书的规则：越具体越靠后，具体程度相同时按原顺序。解析和设置窗口共用。
    public static func matching(_ rules: [PathRule], for book: Location) -> [PathRule] {
        rules.enumerated().filter { book.hasPrefix($0.element.prefix) }
            .sorted {
                let left = $0.element.prefix.layers.reduce(0) { $0 + $1.count }
                let right = $1.element.prefix.layers.reduce(0) { $0 + $1.count }
                return (left, $0.offset) < (right, $1.offset)
            }
            .map(\.element)
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
    case profiles
    /// 设置文件解析失败；仍沿用上一份可用的配置。
    case fileError(file: String, message: String)
}

public protocol SettingsStore: Sendable {
    /// 全局 ⊕ 匹配的路径规则（越具体越靠后）⊕ 书记忆，逐字段合并。
    func resolve(for book: Location) async -> ResolvedBookSettings
    func bookMemory(for book: Location) async -> BookMemory?
    func saveBookMemory(_ memory: BookMemory) async
    func relocateBookMemory(from source: Location, to target: Location) async
    func global() async -> GlobalSettings
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws
    func pathRules() async -> [PathRule]
    func updatePathRules(_ change: @Sendable (inout [PathRule]) -> Void) async throws
    func profiles() async -> [DisplayProfile]
    func updateProfiles(_ change: @Sendable (inout [DisplayProfile]) -> Void) async throws
    func changes() -> AsyncStream<SettingsChange>
}
