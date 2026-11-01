// MVReading：书与页、BookLoader、Bookshelf、PageFrameEngine 与 ReaderSession。职责与契约见 docs/architecture.md §2、§4。
import MVFoundation
import MVIO
import MVMedia
import MVSettings

public struct Page: Sendable, Identifiable, Hashable {
    public var entry: Entry
    public var metadata: ImageMetadata?

    public init(entry: Entry, metadata: ImageMetadata? = nil) {
        self.entry = entry
        self.metadata = metadata
    }

    public var id: Location { entry.location }
}

public struct Book: Sendable, Hashable {
    public var location: Location
    public var pages: [Page]
    /// 枚举与排序是否已完成；完成前 `pages` 按到达顺序排列。
    public var isEnumerated: Bool

    public init(location: Location, pages: [Page] = [], isEnumerated: Bool = false) {
        self.location = location
        self.pages = pages
        self.isEnumerated = isEnumerated
    }
}

/// 先按到达顺序 appended，枚举完成后发一次 sorted；metadata 按阅读顺序分批到达；流结束表示全部完成。
public enum BookLoadEvent: Sendable {
    case appended([Page])
    case sorted([Page])
    case metadata([Location: ImageMetadata])
}

public protocol BookLoader: Sendable {
    func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error>
}

/// 先按到达顺序 appended，枚举完成后发一次 sorted。
public enum ShelfEvent: Sendable {
    case appended([Entry])
    case sorted([Entry])
}

public enum NavigationDirection: Sendable {
    case forward, backward
}

public protocol Bookshelf: Sendable {
    /// 目录下的书：子文件夹与压缩包。
    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error>
    func cover(of book: Location, priority: IOPriority) async throws -> Location?
    /// 书架顺序中的相邻书；到头时为 nil。
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location?
    /// 只含一个子文件夹且没有媒体的目录，自动进入下一层。
    func passThrough(_ location: Location) async throws -> Location
}

public enum PagePart: Sendable, Hashable {
    case whole, leftHalf, rightHalf
}

public struct PageFrameElement: Sendable, Hashable {
    public var page: Int
    public var part: PagePart

    public init(page: Int, part: PagePart = .whole) {
        self.page = page
        self.part = part
    }
}

/// 分页模式下一次显示的内容，元素已按阅读方向排列。
public struct PageFrame: Sendable, Hashable {
    public var elements: [PageFrameElement]

    public init(elements: [PageFrameElement]) {
        self.elements = elements
    }
}

public struct PageLayout: Sendable, Hashable {
    public var pageMode: PageMode
    public var direction: ReadingDirection
    public var firstPageSingle: Bool
    public var widePage: WidePagePolicy

    public init(pageMode: PageMode, direction: ReadingDirection, firstPageSingle: Bool, widePage: WidePagePolicy) {
        self.pageMode = pageMode
        self.direction = direction
        self.firstPageSingle = firstPageSingle
        self.widePage = widePage
    }
}

public enum PageMove: Sendable, Equatable {
    case nextFrame, previousFrame, nextPage, previousPage, first, last
    /// 跳到包含该页序号的页帧。
    case index(Int)
}
