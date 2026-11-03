import Foundation
import MVFoundation
import MVMedia
import MVPipeline
import MVSettings
import Observation

/// 一个窗口或标签中的阅读会话；加载、设置订阅和预取均按会话取消。
@MainActor @Observable
public final class ReaderSession {
    public let id: SessionID
    public private(set) var book: Book?
    public private(set) var frames: [PageFrame] = []
    public private(set) var currentFrame = 0
    public private(set) var settings: ResolvedBookSettings = .default
    public private(set) var loadError: (any Error)?

    /// 当前页的序号：分页模式下是当前页帧中阅读顺序靠前的一页，连续和瀑布模式下是可见区的第一页。书还没读到这一页时是书记忆中的序号。
    public var currentPage: Int { anchorIndex }
    /// 显示尺寸解码的长边上限，查看器和预解码用同一个值。
    public var maxDecodeLongSide: Int { global.maxDecodeLongSide }
    /// 切相邻书用的排序：书架面板回报的排序，没有书架面板时按名称。
    public var neighborSort: SortSpec { shelfSort ?? SortSpec(key: .name) }
    /// 最近一次 `go` 的时刻，用来统计翻页到上屏的用时。
    @ObservationIgnored public private(set) var lastMoveAt: ContinuousClock.Instant?

    private let loader: any BookLoader
    private let store: any SettingsStore
    private let bookshelf: any Bookshelf
    private let pipeline: any ImagePipeline
    @ObservationIgnored private var resolved: ResolvedBookSettings = .default
    @ObservationIgnored private var bookLayer = BookSettings()
    @ObservationIgnored private var global: GlobalSettings = .default
    @ObservationIgnored private var anchor: Location?
    @ObservationIgnored private var anchorIndex = 0
    @ObservationIgnored private var anchorPart: PagePart = .whole
    @ObservationIgnored private var visiblePages: Range<Int>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var memory: BookMemory?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 前端回报的设备像素。切书保留，直到下一次回报。
    @ObservationIgnored private var viewport: PixelSize?
    @ObservationIgnored private var backingScale = 1.0
    /// 书架面板回报的排序。切书保留，直到下一次回报。
    @ObservationIgnored private var shelfSort: SortSpec?
    /// 最近一次仍有效的相邻书页面与目录封面，并在当前书预取项之后。
    @ObservationIgnored private var adjacentItems: [PrefetchItem] = []
    @ObservationIgnored private var adjacentTask: Task<Void, Never>?
    /// 打开书、书架排序、全局或路径设置变化时递增。当前书重载不递增。
    @ObservationIgnored private var adjacentToken = 0

    public init(id: SessionID = SessionID(), loader: any BookLoader, settings: any SettingsStore, bookshelf: any Bookshelf, pipeline: any ImagePipeline) {
        self.id = id
        self.loader = loader
        self.store = settings
        self.bookshelf = bookshelf
        self.pipeline = pipeline
        let changes = settings.changes()
        settingsTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                switch change {
                case .global, .pathRules: await self?.settingsChanged()
                case .fileError: break // SettingsStore 保留上一份可用配置。
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
        settingsTask?.cancel()
        saveTask?.cancel()
        adjacentTask?.cancel()
        pipeline.cancelAll(session: id)
        if let memory {
            let store = store
            Task { await store.saveBookMemory(memory) }
        }
    }

    /// 加载结束后返回；枚举、排序和元数据的中间结果会持续更新可观察属性。
    public func open(_ location: Location, at page: Location?) async {
        generation += 1
        let current = generation
        loadTask?.cancel()
        saveTask?.cancel()
        cancelAdjacent()
        pipeline.cancelAll(session: id)
        if let memory { await store.saveBookMemory(memory) }
        let remembered = await store.bookMemory(for: location)
        let resolved = await store.resolve(for: location)
        let global = await store.global()
        guard current == generation else { return }
        self.resolved = resolved
        self.global = global
        bookLayer = remembered?.settings ?? BookSettings()
        settings = resolved
        seedRandomOrder()
        openedAt = Date()
        book = Book(location: location)
        frames = []
        currentFrame = 0
        anchor = page ?? remembered?.lastPage
        anchorIndex = page == nil ? remembered?.lastPageIndex ?? 0 : 0
        anchorPart = .whole
        visiblePages = nil
        loadError = nil
        memory = nil
        restartAdjacent()
        let stream = loader.load(location, settings: settings, startingAt: anchor)
        let task = loading(stream, generation: current)
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if current == generation { loadTask = nil }
    }

    public func go(_ move: PageMove) {
        guard !frames.isEmpty, let book else { return }
        lastMoveAt = .now
        let target: Int?
        var pageTarget: Int?
        switch move {
        case .nextFrame: target = currentFrame + 1
        case .previousFrame: target = currentFrame - 1
        case .nextPage:
            pageTarget = (frames[currentFrame].elements.map(\.page).max() ?? anchorIndex) + 1
            target = frameIndex(containing: pageTarget!)
        case .previousPage:
            pageTarget = (frames[currentFrame].elements.map(\.page).min() ?? anchorIndex) - 1
            target = frameIndex(containing: pageTarget!)
        case .first: pageTarget = 0; target = 0
        case .last: pageTarget = book.pages.count - 1; target = frames.count - 1
        case let .index(page):
            pageTarget = min(max(page, 0), book.pages.count - 1)
            target = frameIndex(containing: pageTarget!)
        }
        guard let target else { return }
        currentFrame = min(max(target, 0), frames.count - 1)
        let element = frames[currentFrame].elements.first { $0.page == pageTarget } ?? readingFirst(in: frames[currentFrame])
        if let element {
            anchorIndex = element.page
            anchor = book.pages[element.page].id
            anchorPart = element.part
        }
        remember()
        prefetch()
    }

    public func openNeighborBook(_ direction: NavigationDirection, sort: SortSpec) async {
        guard let location = book?.location else { return }
        do {
            if let neighbor = try await bookshelf.neighbor(of: location, direction, sort: sort) { await open(neighbor, at: nil) }
        } catch { loadError = error }
    }

    public func update(_ change: (inout BookSettings) -> Void) {
        let previous = settings
        change(&bookLayer)
        settings = resolved.applying(bookLayer)
        seedRandomOrder()
        layoutFrames()
        remember()
        prefetch()
        if previous.sort != settings.sort || previous.recursion != settings.recursion { reload() }
    }

    /// 连续和瀑布模式由前端回报可见范围，当前页随可见区的第一页移动并写入书记忆。
    public func visibleRangeChanged(_ pages: Range<Int>) {
        visiblePages = pages
        if let book, settings.browseMode != .paged, book.pages.indices.contains(pages.lowerBound), pages.lowerBound != anchorIndex {
            anchorIndex = pages.lowerBound
            anchor = book.pages[pages.lowerBound].id
            anchorPart = .whole
            if let frame = frameIndex(containing: pages.lowerBound) { currentFrame = frame }
            remember()
        }
        prefetch()
    }

    /// 前端回报视口的设备像素和屏幕缩放倍率。记下后重新生成预取计划；没有回报之前不预解码到显示尺寸。
    public func viewportChanged(_ pixels: PixelSize, backingScale: Double) {
        viewport = pixels
        self.backingScale = backingScale
        prefetch()
    }

    /// 前端回报书架排序。没有回报之前不预取相邻书和封面；切书保留。
    public func shelfSortChanged(_ sort: SortSpec) {
        shelfSort = sort
        restartAdjacent()
    }

    /// 退出时立即保存最新快照，不等一秒去抖；数据库落盘由组合根随后执行。
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        if let memory { await store.saveBookMemory(memory) }
    }

    private func apply(_ event: BookLoadEvent) {
        switch event {
        case let .appended(pages): book?.pages.append(contentsOf: pages)
        case let .sorted(pages):
            // 缓存后的第二次排序也先按位置身份定位；身份消失再回退到原序号。
            let known = Dictionary((book?.pages ?? []).compactMap { page in page.metadata.map { (page.entry.identity, $0) } }, uniquingKeysWith: { _, last in last })
            book?.pages = pages.map { page in var value = page; value.metadata = value.metadata ?? known[page.entry.identity]; return value }
            book?.isEnumerated = true
        case let .metadata(values):
            guard var pages = book?.pages else { return }
            for index in pages.indices { if let value = values[pages[index].id] { pages[index].metadata = value } }
            book?.pages = pages
        }
        layoutFrames()
        remember()
        prefetch()
    }

    private func layoutFrames() {
        let allPages = book?.pages ?? []
        let paged = settings.browseMode == .paged
        let pages = paged ? allPages : Array(allPages.prefix { $0.metadata != nil })
        let layout = PageLayout(pageMode: paged ? settings.pageMode : .single, direction: settings.direction, firstPageSingle: paged && settings.firstPageSingle, widePage: paged ? settings.widePage : .asIs)
        frames = PageFrameEngine.frames(aspectRatios: pages.map { page in
            page.metadata.map { Double($0.pixelSize.width) / Double($0.pixelSize.height) }
        }, layout: layout)
        guard !allPages.isEmpty else { currentFrame = 0; return }
        let found = anchor.flatMap { location in allPages.firstIndex { $0.id == location } }
        let index = found ?? min(max(anchorIndex, 0), allPages.count - 1)
        currentFrame = frameIndex(containing: index, part: anchorPart) ?? frameIndex(containing: index) ?? min(currentFrame, max(0, frames.count - 1))
        if found != nil || book?.isEnumerated == true {
            anchorIndex = index
            anchor = allPages[index].id
        }
    }

    private func frameIndex(containing page: Int, part: PagePart? = nil) -> Int? {
        frames.firstIndex { frame in frame.elements.contains { $0.page == page && (part == nil || $0.part == part) } }
    }

    private func readingFirst(in frame: PageFrame) -> PageFrameElement? {
        settings.direction == .leftToRight ? frame.elements.first : frame.elements.last
    }

    private func remember() {
        guard let book, !book.pages.isEmpty else { return }
        let snapshot = BookMemory(book: book.location, settings: bookLayer, lastPage: anchor, lastPageIndex: anchorIndex, openedAt: openedAt)
        memory = snapshot
        saveTask?.cancel()
        let current = generation
        saveTask = Task { [weak self, store] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await store.saveBookMemory(snapshot)
            let resolved = await store.resolve(for: snapshot.book)
            guard !Task.isCancelled, let self, current == self.generation, self.memory == snapshot else { return }
            let previous = self.settings
            self.resolved = resolved
            self.settings = resolved.applying(self.bookLayer)
            self.layoutFrames()
            self.prefetch()
            if previous.sort != self.settings.sort || previous.recursion != self.settings.recursion { self.reload() }
        }
    }

    private func reload() {
        guard let location = book?.location else { return }
        generation += 1
        loadTask?.cancel()
        pipeline.cancelAll(session: id)
        remember()
        book = Book(location: location)
        frames = []
        currentFrame = 0
        loadError = nil
        loadTask = loading(loader.load(location, settings: settings, startingAt: anchor), generation: generation)
    }

    private func loading(_ stream: AsyncThrowingStream<BookLoadEvent, any Error>, generation current: Int) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self, current == self.generation else { return }
                    self.apply(event)
                }
            } catch {
                guard let self, current == self.generation, !Task.isCancelled else { return }
                self.loadError = error
            }
        }
    }

    private func seedRandomOrder() {
        if settings.sort.key == .random && settings.sort.randomSeed == nil {
            settings.sort.randomSeed = UInt64.random(in: .min ... .max)
            bookLayer.sort = settings.sort
        }
    }

    private func settingsChanged() async {
        guard book != nil else { global = await store.global(); return }
        cancelAdjacent()
        prefetch()
        let current = generation
        guard let location = book?.location else { return }
        let resolved = await store.resolve(for: location)
        let global = await store.global()
        guard current == generation else { return }
        let previous = settings
        self.resolved = resolved
        self.global = global
        settings = resolved.applying(bookLayer)
        seedRandomOrder()
        layoutFrames()
        remember()
        restartAdjacent()
        if previous.sort != settings.sort || previous.recursion != settings.recursion { reload() }
    }

    private func prefetch() {
        guard let pages = book?.pages, !pages.isEmpty else { pipeline.setPrefetchPlan(PrefetchPlan(), session: id); return }
        var items: [PrefetchItem] = []
        if settings.browseMode == .paged {
            if global.prefetch.currentBookPages {
                items = pages.map { PrefetchItem(identity: $0.entry.identity, renditions: [.thumbnail, .metadata], priority: .book) }
            }
            let last = min(pages.count, anchorIndex + 1 + max(0, global.prefetch.viewerReadAheadPages))
            if anchorIndex + 1 < last {
                for index in (anchorIndex + 1)..<last { items.append(PrefetchItem(identity: pages[index].entry.identity, renditions: [], priority: .near)) }
            }
            appendDisplayPrefetch(to: &items, pages: pages)
        } else {
            let visible = visiblePages ?? anchorIndex..<(anchorIndex + 1)
            let lower = min(max(visible.lowerBound, 0), pages.count)
            let upper = min(max(visible.upperBound, lower), pages.count)
            let margin = Int((Double(upper - lower) * max(0, global.prefetch.galleryMarginScreens)).rounded(.up))
            let nearby = max(0, lower - margin)..<min(pages.count, upper + margin)
            for index in pages.indices {
                if nearby.contains(index) {
                    items.append(PrefetchItem(identity: pages[index].entry.identity, renditions: [.thumbnail, .browse, .metadata], priority: index >= lower && index < upper ? .visible : .near))
                } else if global.prefetch.currentBookPages {
                    items.append(PrefetchItem(identity: pages[index].entry.identity, renditions: [.thumbnail, .metadata], priority: .book))
                }
            }
        }
        appendAdjacent(to: &items)
        pipeline.setPrefetchPlan(PrefetchPlan(items: items), session: id)
    }

    /// 当前帧前后各 `viewerDecodeFrames` 个页帧，不含当前帧。与缩略图、原始字节分条记录。
    private func appendDisplayPrefetch(to items: inout [PrefetchItem], pages: [Page]) {
        guard let viewport else { return }
        let radius = max(0, global.prefetch.viewerDecodeFrames)
        let lower = max(frames.startIndex, currentFrame - radius)
        let upper = min(frames.endIndex, currentFrame + radius + 1)
        for index in lower..<upper where index != currentFrame {
            let fitted = PageFrameFit.fit(frame: frames[index], pages: pages, viewport: viewport, backingScale: backingScale, settings: settings)
            for (element, target) in fitted.displayTargets(settings: settings, maxDecodeLongSide: global.maxDecodeLongSide) {
                items.append(PrefetchItem(identity: pages[element.page].entry.identity, renditions: [.display(target)], priority: .near))
            }
        }
    }

    /// 同一身份、同一组渲染件只留一条。当前书计划里已有的页（例如 `.book`）不再追加 `.adjacent`。
    private func appendAdjacent(to items: inout [PrefetchItem]) {
        var seen = Set(items.map { PlanKey(identity: $0.identity, renditions: $0.renditions) })
        for item in adjacentItems {
            guard seen.insert(PlanKey(identity: item.identity, renditions: item.renditions)).inserted else { continue }
            items.append(item)
        }
    }

    private func restartAdjacent() {
        cancelAdjacent()
        prefetch()
        startAdjacent()
    }

    private func cancelAdjacent() {
        adjacentToken += 1
        adjacentTask?.cancel()
        adjacentTask = nil
        adjacentItems = []
    }

    private func startAdjacent() {
        guard let sort = shelfSort, let current = book?.location, let parent = current.parent else { return }
        let neighborCount = max(0, global.prefetch.neighborBooks)
        let covers = global.prefetch.shelfCovers
        guard neighborCount > 0 || covers else { return }
        let token = adjacentToken
        let bookshelf = bookshelf
        let loader = loader
        let store = store
        adjacentTask = Task { [weak self] in
            let items = await Self.makeAdjacentItems(
                parent: parent, current: current, sort: sort, neighborCount: neighborCount, covers: covers,
                bookshelf: bookshelf, loader: loader, store: store
            )
            guard let self, let items, self.adjacentToken == token else { return }
            self.adjacentItems = items
            self.prefetch()
        }
    }

    /// 取消时返回 nil，调用方不要写回。目录失败返回空计划，不触碰 `loadError`。
    private static func makeAdjacentItems(
        parent: Location, current: Location, sort: SortSpec, neighborCount: Int, covers: Bool,
        bookshelf: any Bookshelf, loader: any BookLoader, store: any SettingsStore
    ) async -> [PrefetchItem]? {
        if Task.isCancelled { return nil }
        let books: [Entry]
        do {
            guard let sorted = try await firstSorted(bookshelf.items(in: parent, sort: sort)) else { return [] }
            books = sorted
        } catch {
            return abandoned(error) ? nil : []
        }
        var items: [PrefetchItem] = []
        var seen = Set<ContentIdentity>()
        var loaded: [Location: [Page]] = [:]
        func append(_ identity: ContentIdentity) {
            if seen.insert(identity).inserted {
                items.append(PrefetchItem(identity: identity, renditions: Self.adjacentRenditions, priority: .adjacent))
            }
        }
        if neighborCount > 0, let index = books.firstIndex(where: { $0.location == current }) {
            for entry in books.dropFirst(index + 1).prefix(neighborCount) {
                if Task.isCancelled { return nil }
                let settings = await store.resolve(for: entry.location)
                if Task.isCancelled { return nil }
                do {
                    guard let pages = try await lastSortedPages(loader.load(entry.location, settings: settings, startingAt: nil)) else { continue }
                    loaded[entry.location] = pages
                    for page in pages { append(page.entry.identity) }
                } catch {
                    if abandoned(error) { return nil }
                    continue
                }
            }
        }
        if covers {
            for entry in books {
                if Task.isCancelled { return nil }
                let cover: Location?
                do { cover = try await bookshelf.cover(of: entry.location, priority: .adjacent) } catch {
                    if abandoned(error) { return nil }
                    continue
                }
                guard let cover else { continue }
                let identity: ContentIdentity?
                if let page = loaded[entry.location]?.first(where: { $0.id == cover }) {
                    identity = page.entry.identity
                } else {
                    let settings = await store.resolve(for: entry.location)
                    if Task.isCancelled { return nil }
                    do {
                        identity = try await pageIdentity(loader.load(entry.location, settings: settings, startingAt: nil), location: cover)
                    } catch {
                        if abandoned(error) { return nil }
                        continue
                    }
                }
                if let identity { append(identity) }
            }
        }
        return Task.isCancelled ? nil : items
    }

    /// 只取第一次 `.sorted` 后离开循环，从而结束流。目录缓存命中时，FileBookshelf 会因此取消后面的来源刷新。
    private static func firstSorted(_ stream: AsyncThrowingStream<ShelfEvent, any Error>) async throws -> [Entry]? {
        for try await event in stream {
            if case let .sorted(entries) = event { return entries }
        }
        return nil
    }

    /// 流正常结束后采用最后一次 `.sorted`；流里没有则跳过这本书。
    private static func lastSortedPages(_ stream: AsyncThrowingStream<BookLoadEvent, any Error>) async throws -> [Page]? {
        var sorted: [Page]?
        for try await event in stream {
            if case let .sorted(pages) = event { sorted = pages }
        }
        return sorted
    }

    /// 事件里一出现该位置就取这一页并结束流。
    private static func pageIdentity(_ stream: AsyncThrowingStream<BookLoadEvent, any Error>, location: Location) async throws -> ContentIdentity? {
        for try await event in stream {
            let pages: [Page]
            switch event {
            case let .appended(value): pages = value
            case let .sorted(value): pages = value
            case .metadata: continue
            }
            if let page = pages.first(where: { $0.id == location }) { return page.entry.identity }
        }
        return nil
    }

    private static func abandoned(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }

    private static let adjacentRenditions: Set<RenditionSpec> = [.thumbnail, .metadata]

    private struct PlanKey: Hashable {
        var identity: ContentIdentity
        var renditions: Set<RenditionSpec>
    }
}
