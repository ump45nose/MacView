import MVFoundation
import MVPipeline
import MVSettings
import Observation

/// 一个窗口或标签中的阅读会话：当前的书、页帧、位置和设置。
///
/// 目前实现打开书、导航与读取设置。书层设置的持久化、预取计划和可见范围的处理在 S1-T6 实现。
@MainActor @Observable
public final class ReaderSession {
    public let id: SessionID
    public private(set) var book: Book?
    public private(set) var frames: [PageFrame] = []
    public private(set) var currentFrame = 0
    public private(set) var settings: ResolvedBookSettings
    public private(set) var loadError: (any Error)?

    private let loader: any BookLoader
    private let store: any SettingsStore
    private let bookshelf: any Bookshelf
    private let pipeline: any ImagePipeline
    /// 打开书时解析出的设置，书层的改动叠加在它上面。
    @ObservationIgnored private var resolved: ResolvedBookSettings
    @ObservationIgnored private var bookLayer = BookSettings()
    /// 页帧重算时要保持可见的页。
    @ObservationIgnored private var anchor: Location?
    /// 每次 open 加一；旧的加载发现自己过期后停止。
    @ObservationIgnored private var generation = 0

    public init(id: SessionID = SessionID(), loader: any BookLoader, settings: any SettingsStore, bookshelf: any Bookshelf, pipeline: any ImagePipeline) {
        self.id = id
        self.loader = loader
        self.store = settings
        self.bookshelf = bookshelf
        self.pipeline = pipeline
        self.settings = .default
        self.resolved = .default
    }

    /// 打开一本书并定位到 `page`（为 nil 时到第一页）。加载全部完成后返回；期间各属性随事件更新。
    public func open(_ location: Location, at page: Location?) async {
        generation += 1
        let current = generation
        let resolved = await store.resolve(for: location)
        guard current == generation else { return }
        self.resolved = resolved
        bookLayer = BookSettings()
        settings = resolved
        book = Book(location: location)
        frames = []
        currentFrame = 0
        anchor = page
        loadError = nil
        do {
            for try await event in loader.load(location, settings: resolved, startingAt: page) {
                guard current == generation else { return }
                apply(event)
            }
        } catch {
            if current == generation {
                loadError = error
            }
        }
    }

    public func go(_ move: PageMove) {
        guard !frames.isEmpty else { return }
        let target: Int?
        switch move {
        case .nextFrame: target = currentFrame + 1
        case .previousFrame: target = currentFrame - 1
        case .nextPage: target = frameIndex(containing: (frames[currentFrame].elements.map(\.page).max() ?? 0) + 1)
        case .previousPage: target = frameIndex(containing: (frames[currentFrame].elements.map(\.page).min() ?? 0) - 1)
        case .first: target = 0
        case .last: target = frames.count - 1
        case let .index(page): target = frameIndex(containing: min(max(page, 0), (book?.pages.count ?? 1) - 1))
        }
        guard let target else { return }
        currentFrame = min(max(target, 0), frames.count - 1)
        anchor = frames[currentFrame].elements.first.flatMap { book?.pages[$0.page].id }
    }

    /// 打开书架顺序中的相邻书。`sort` 是书架面板当前的排序，与书内页面的排序无关。
    public func openNeighborBook(_ direction: NavigationDirection, sort: SortSpec) async {
        guard let location = book?.location else { return }
        do {
            if let neighbor = try await bookshelf.neighbor(of: location, direction, sort: sort) {
                await open(neighbor, at: nil)
            }
        } catch {
            loadError = error
        }
    }

    /// 修改书层设置。
    public func update(_ change: (inout BookSettings) -> Void) {
        change(&bookLayer)
        settings = resolved.applying(bookLayer)
        layoutFrames()
    }

    /// 连续与瀑布模式由前端回报可见范围，用于生成预取计划（S1-T6）。
    public func visibleRangeChanged(_ pages: Range<Int>) {}

    private func apply(_ event: BookLoadEvent) {
        switch event {
        case let .appended(pages):
            book?.pages.append(contentsOf: pages)
        case let .sorted(pages):
            book?.pages = pages
            book?.isEnumerated = true
        case let .metadata(values):
            guard var pages = book?.pages else { return }
            for index in pages.indices {
                if let metadata = values[pages[index].id] {
                    pages[index].metadata = metadata
                }
            }
            book?.pages = pages
        }
        layoutFrames()
    }

    private func layoutFrames() {
        let pages = book?.pages ?? []
        let layout = PageLayout(pageMode: settings.pageMode, direction: settings.direction, firstPageSingle: settings.firstPageSingle, widePage: settings.widePage)
        frames = PageFrameEngine.frames(
            aspectRatios: pages.map { page in page.metadata.map { Double($0.pixelSize.width) / Double($0.pixelSize.height) } },
            layout: layout
        )
        if let anchor, let page = pages.firstIndex(where: { $0.id == anchor }), let frame = frameIndex(containing: page) {
            currentFrame = frame
        } else {
            currentFrame = min(currentFrame, max(frames.count - 1, 0))
        }
    }

    private func frameIndex(containing page: Int) -> Int? {
        frames.firstIndex { frame in frame.elements.contains { $0.page == page } }
    }
}
