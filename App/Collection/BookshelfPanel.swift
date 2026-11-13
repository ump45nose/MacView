import AppKit
import MVFoundation
import MVIO
import MVPipeline
import MVReading
import MVSettings
import Observation

/// 书架：当前书所在目录下的书。默认跟随打开的书；可以进入上一层或双击进入子文件夹。
@MainActor
final class BookshelfPanel: CollectionPanel {
    /// 封面的解析结果；排序变化后不用重新解析。读取失败时 `failure` 是错误文字，点击这一项或重新列出目录时重试。
    private struct Cover {
        var identity: ContentIdentity?
        var aspectRatio: Double
        var readTo: Int?
        var failure: String?
    }

    private nonisolated static let unknownRatio = 2.0 / 3
    private static let concurrentCovers = 4

    private var directory: Location?
    private var entries: [Entry] = []
    private var covers: [Location: Cover] = [:]
    private var queue: [Location] = []
    private var running: Set<Location> = []
    private var publishTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var loadError: String?
    private var isListing = false
    /// 最近跟随的书。用户离开这个目录后，只有换了书才跟回去。
    private var followedBook: Location?
    private var observedSession: SessionID?
    /// 列表和表格最近回报的可见范围。
    private var visibleRange = 0..<0

    /// 解析封面用到的服务。
    private struct CoverServices: Sendable {
        let sources: any SourceRegistry
        let pipeline: any ImagePipeline
        let settings: any SettingsStore
        let bookshelf: any Bookshelf
    }

    override var secondColumnTitle: String { String(localized: "类型") }
    override var thumbSize: CGSize { CGSize(width: 30, height: 42) }

    private var sort: SortSpec { settings.sort ?? defaultSort }

    override func windowChanged() {
        observedSession = boundSession
        owner?.session.shelfSortChanged(sort)
        followedBook = nil
        observeBook()
    }

    private func observeBook() {
        guard let owner, let id = observedSession else {
            directory = nil
            startListing()
            return
        }
        let book = withObservationTracking {
            owner.session.book?.location
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeBook()
            }
        }
        bookChanged(book)
    }

    private func bookChanged(_ book: Location?) {
        guard book != followedBook else { return }
        followedBook = book
        guard let parent = book?.parent else {
            if book == nil, directory != nil {
                directory = nil
                startListing()
            }
            return
        }
        if parent != directory {
            directory = parent
            startListing()
        } else {
            refresh()
            collection?.revealCurrentItem()
        }
    }

    override func sortChanged() {
        owner?.session.shelfSortChanged(sort)
        startListing()
    }

    #if DEBUG
    override func visibleThumbnailsArrived() {
        guard owner?.session.book == nil else { return }
        owner?.finishFirstScreenThumbnails(fromPageList: false)
    }
    #endif

    /// 列出目录。目录缓存命中时立即有结果。
    private func startListing() {
        #if DEBUG
        owner?.beginShelfThumbnails()
        #endif
        listTask?.cancel()
        queue = []
        entries = []
        loadError = nil
        covers = covers.filter { $0.value.failure == nil }
        guard let directory, let bookshelf = owner?.services.bookshelf else {
            isListing = false
            refresh()
            return
        }
        isListing = true
        refresh()
        let sort = sort
        listTask = Task { [weak self] in
            do {
                for try await event in bookshelf.items(in: directory, sort: sort) {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case let .appended(more): entries.append(contentsOf: more)
                    case let .sorted(sorted): entries = sorted
                    }
                    refresh()
                }
                guard !Task.isCancelled, let self else { return }
                isListing = false
                refresh()
                collection?.revealCurrentItem()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                isListing = false
                loadError = ErrorText.describe(error)
                refresh()
            }
        }
    }

    override func reload() {
        let currentBook = owner?.session.book?.location
        let items = entries.map(item)
        collection?.setItems(items, current: currentBook.flatMap { book in entries.firstIndex { $0.location == book } })
        collection?.message = loadError ?? (directory == nil
            ? String(localized: "没有打开的书")
            : entries.isEmpty && !isListing ? String(localized: "这个目录下没有书") : nil)
        requestCovers()
        let path = directory.map { $0.description.split(separator: "/").map(String.init).joined(separator: " › ") }
        setInfo(path: path, count: directory == nil ? "" : String(localized: "\(entries.count) 本"), canGoUp: directory?.parent != nil) { [weak self] in
            self?.goUp()
        }
    }

    func goUp() {
        guard let parent = directory?.parent else { return }
        directory = parent
        startListing()
    }

    private func item(_ entry: Entry) -> CollectionItem {
        let cover = covers[entry.location]
        let canvas = CanvasItem(
            identity: cover?.identity ?? entry.identity,
            aspectRatio: cover?.aspectRatio,
            isPending: cover?.identity == nil
        )
        let suffix = (entry.name as NSString).pathExtension.lowercased()
        let kind: String
        var parts: [String]
        if case .archive = entry.kind {
            kind = suffix
            parts = [suffix, CollectionFormat.bytes(entry.identity.size)]
        } else {
            kind = String(localized: "文件夹")
            parts = [kind]
        }
        if let read = cover?.readTo { parts.append(String(localized: "读到 \(read)")) }
        let size = if case .archive = entry.kind { CollectionFormat.bytes(entry.identity.size) } else { "" }
        return CollectionItem(canvas: canvas, name: entry.name, detail: parts.joined(separator: " · "), column: kind, size: size, failure: cover?.failure)
    }

    /// 点击打开这本书；封面读取失败过的同时重新解析封面。
    override func activate(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let book = entries[index].location
        if covers[book]?.failure != nil {
            covers[book] = nil
            refresh()
        }
        owner?.openBook(book)
    }

    /// 双击文件夹：进入这一层。压缩包是书，单击已经打开了。
    override func doubleClicked(_ index: Int) {
        guard entries.indices.contains(index), entries[index].kind == .directory else { return }
        directory = entries[index].location
        startListing()
    }

    // MARK: 封面

    /// 只解析可见项和余量内的封面。瀑布流要宽高比才能排，范围的末尾再多解析一批。
    override func visibleRangeChanged(_ range: Range<Int>) {
        visibleRange = range
        requestCovers()
    }

    private func requestCovers() {
        let range = collection.map { $0.style.usesCanvas ? $0.canvas.visibleRange.margin : visibleRange } ?? visibleRange
        let upper = min(range.upperBound + Self.concurrentCovers * 4, entries.count)
        guard range.lowerBound < upper else {
            queue = []
            return
        }
        queue = entries[range.lowerBound..<upper].map(\.location).filter { covers[$0] == nil && !running.contains($0) }
        pumpCovers()
    }

    private func pumpCovers() {
        while running.count < Self.concurrentCovers, !queue.isEmpty {
            let book = queue.removeFirst()
            guard let core = owner?.services else { return }
            running.insert(book)
            let services = CoverServices(sources: core.sources, pipeline: core.pipeline, settings: core.settings, bookshelf: core.bookshelf)
            Task { [weak self] in
                let cover = await Self.resolve(book, services: services)
                guard let self else { return }
                running.remove(book)
                covers[book] = cover
                schedulePublish()
                pumpCovers()
            }
        }
    }

    /// 封面到达后合并到下一次刷新，不逐个重建。
    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            publishTask = nil
            refresh()
        }
    }

    /// 封面的身份和宽高比。目录里没有图片时没有封面；没有封面或读取失败时按 2:3 占位，否则瀑布流的前缀会卡住。
    private nonisolated static func resolve(_ book: Location, services: CoverServices) async -> Cover {
        let readTo = await services.settings.bookMemory(for: book)?.lastPageIndex.map { $0 + 1 }
        do {
            guard let location = try await services.bookshelf.cover(of: book, priority: .near) else {
                return Cover(identity: nil, aspectRatio: unknownRatio, readTo: readTo)
            }
            let entry = try await services.sources.provider(for: location).entry(at: location)
            let size = try await services.pipeline.metadata(for: entry.identity, priority: .near).pixelSize
            return Cover(identity: entry.identity, aspectRatio: size.height > 0 ? Double(size.width) / Double(size.height) : unknownRatio, readTo: readTo)
        } catch {
            return Cover(identity: nil, aspectRatio: unknownRatio, readTo: readTo, failure: ErrorText.describe(error))
        }
    }
}
