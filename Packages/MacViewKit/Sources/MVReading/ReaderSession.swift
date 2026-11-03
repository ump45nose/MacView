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
        let stream = loader.load(location, settings: settings, startingAt: anchor)
        let task = loading(stream, generation: current)
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if current == generation { loadTask = nil }
    }

    public func go(_ move: PageMove) {
        guard !frames.isEmpty, let book else { return }
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

    public func visibleRangeChanged(_ pages: Range<Int>) {
        visiblePages = pages
        prefetch()
    }

    /// 前端回报设备像素。记下后重新生成预取计划；没有回报之前不预解码到显示尺寸。
    public func viewportChanged(_ pixels: PixelSize) {
        viewport = pixels
        prefetch()
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
        guard let location = book?.location else { global = await store.global(); return }
        let current = generation
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
        prefetch()
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
        pipeline.setPrefetchPlan(PrefetchPlan(items: items), session: id)
    }

    /// 当前帧前后各 `viewerDecodeFrames` 个页帧，不含当前帧。与缩略图、原始字节分条记录。
    private func appendDisplayPrefetch(to items: inout [PrefetchItem], pages: [Page]) {
        guard let viewport else { return }
        let radius = max(0, global.prefetch.viewerDecodeFrames)
        let lower = max(frames.startIndex, currentFrame - radius)
        let upper = min(frames.endIndex, currentFrame + radius + 1)
        for index in lower..<upper where index != currentFrame {
            let fitted = PageFrameFit.fit(frame: frames[index], pages: pages, viewport: viewport, settings: settings)
            for (element, target) in fitted.displayTargets(settings: settings, maxDecodeLongSide: global.maxDecodeLongSide) {
                items.append(PrefetchItem(identity: pages[element.page].entry.identity, renditions: [.display(target)], priority: .near))
            }
        }
    }
}
