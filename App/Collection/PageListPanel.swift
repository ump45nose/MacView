import AppKit
import MVFoundation
import MVMedia
import MVReading
import MVSettings
import Observation

/// 页面列表：当前书的页。排序只改面板内的显示顺序，翻页顺序不变；虚拟书按列表顺序，不能排序，不可用的页变灰。
@MainActor
final class PageListPanel: CollectionPanel {
    /// 显示顺序到书内页码。
    private var order: [Int] = []
    /// 列表失败记录所属的那一轮加载（`ReaderSession.loadID`）。
    private var failuresLoadID = 0
    private var observedSession: SessionID?
    private let availability = LibraryAvailability()
    private var visibleRange = 0..<0

    override var followsBook: Bool { true }
    override var sortNote: String? {
        owner?.session.isVirtualBook == true ? String(localized: "虚拟书：页序就是列表顺序") : nil
    }

    override func windowChanged() {
        availability.view = view
        availability.visibleLocations = { [weak self] in
            guard let self, owner?.session.isVirtualBook == true else { return [] }
            return entries(at: Array(visibleRange.clamped(to: 0..<order.count))).map(\.location)
        }
        availability.onChange = { [weak self] in
            guard let self, owner?.session.isVirtualBook == true else { return }
            owner?.session.setAvailability(availability.states)
        }
        availability.attach(owner?.services)
        observedSession = boundSession
        observeBook()
        observeCurrent()
    }

    override func sortChanged() {
        refresh()
    }

    /// 书变化（页到达、元数据到达、虚拟书的页可用状态）时重建；翻页不重建。
    private func observeBook() {
        guard let owner, let id = observedSession else {
            refresh()
            return
        }
        withObservationTracking {
            _ = owner.session.book
            _ = owner.session.unavailablePages
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeBook()
            }
        }
        refresh()
    }

    private func observeCurrent() {
        guard let owner, let id = observedSession else { return }
        withObservationTracking {
            // `currentPage` 本身不被观察；页变化时 `currentFrame` 随之变化。
            _ = owner.session.currentFrame
            collection?.setCurrent(order.firstIndex(of: owner.session.currentPage), reveal: true)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observedSession == id else { return }
                self.observeCurrent()
            }
        }
    }

    #if DEBUG
    override func visibleThumbnailsArrived() {
        owner?.finishFirstScreenThumbnails(fromPageList: true)
    }
    #endif

    override func reload() {
        #if DEBUG
        if let location = owner?.session.book?.location {
            owner?.noteFirstScreenBook(location)
        }
        #endif
        renderControls()
        if let loadID = owner?.session.loadID, loadID != failuresLoadID {
            // 新一轮加载（如重试打开失败的书）：上一轮读不到的行重新请求。
            failuresLoadID = loadID
            collection?.retryFailed()
        }
        guard let session = owner?.session, let book = session.book else {
            order = []
            collection?.setItems([], current: nil)
            collection?.message = String(localized: "没有打开的书")
            setInfo(path: nil, count: "", canGoUp: false, onUp: nil)
            return
        }
        let pages = book.pages
        if !session.isVirtualBook, let sort = settings.sort {
            var indices: [Location: Int] = [:]
            indices.reserveCapacity(pages.count)
            for (index, page) in pages.enumerated() { indices[page.id] = index }
            order = ReadingOrder.sorted(pages.map(\.entry), by: sort).compactMap { indices[$0.location] }
        } else {
            order = Array(pages.indices)
        }
        let unavailable = session.unavailablePages
        let items = order.map { Self.item(pages[$0], isUnavailable: unavailable.contains(pages[$0].id)) }
        let wasEmpty = collection?.items.isEmpty ?? true
        collection?.setItems(items, current: order.firstIndex(of: session.currentPage))
        collection?.message = pages.isEmpty && book.isEnumerated ? String(localized: "这本书没有页") : nil
        let total = pages.reduce(Int64(0)) { $0 + $1.entry.identity.size }
        if let playlist = book.location.playlistID {
            let name = LibraryActions.playlists.first { $0.id == playlist }?.name ?? String(localized: "播放列表")
            setInfo(path: name, count: String(localized: "\(pages.count) 项"), canGoUp: false, onUp: nil)
        } else {
            setInfo(path: book.location.name, count: String(localized: "\(pages.count) 页 · \(CollectionFormat.bytes(total))"), canGoUp: false, onUp: nil)
        }
        if wasEmpty, !items.isEmpty { collection?.revealCurrentItem() }
        checkVisiblePages()
    }

    override func visibleRangeChanged(_ range: Range<Int>) {
        visibleRange = range
        availability.scrolled()
    }

    override func shown() { availability.recheckAll() }

    #if DEBUG
    func availabilityProbe(_ location: Location) -> [String: String] {
        var result = availability.probe(location)
        result["inCheckedRange"] = String(entries(at: Array(visibleRange.clamped(to: 0..<order.count))).contains { $0.location == location })
        result["range"] = String(describing: visibleRange)
        return result
    }
    #endif

    /// 复用面板检查器的显示、滚动、激活、卷状态和文件变更重查。
    private func checkVisiblePages() {
        let pages = owner?.session.isVirtualBook == true ? owner?.session.book?.pages.map(\.id) ?? [] : []
        availability.retain(Set(pages))
        availability.visibleChanged()
    }

    override func activate(_ index: Int) {
        guard order.indices.contains(index) else { return }
        let isKeyboard = NSApp.currentEvent?.type == .keyDown
        let videoStart = isKeyboard ? nil : collection?.canvas.previewTime(at: index)
        owner?.activatePage(at: order[index], videoStart: videoStart)
    }

    override func entries(at indices: [Int]) -> [Entry] {
        guard let pages = owner?.session.book?.pages else { return [] }
        return indices.compactMap { order.indices.contains($0) && pages.indices.contains(order[$0]) ? pages[order[$0]].entry : nil }
    }

    override func libraryMenuItems(for entries: [Entry]) -> [NSMenuItem] {
        guard let owner, let app = NSApp.delegate as? AppDelegate else { return [] }
        let header = NSMenuItem.sectionHeader(title: entries.count > 1 ? String(localized: "已选 \(entries.count) 页") : entries[0].name)
        return [header] + LibraryActions.pageMenuItems(for: entries, in: owner.session, app: app)
    }

    private static func item(_ page: Page, isUnavailable: Bool) -> CollectionItem {
        let metadata = page.metadata
        let size = metadata.map { "\($0.pixelSize.width)×\($0.pixelSize.height)" } ?? ""
        let bytes = CollectionFormat.bytes(page.entry.identity.size)
        let canvas = CanvasItem(
            identity: page.entry.identity,
            aspectRatio: metadata.flatMap { $0.pixelSize.height > 0 ? Double($0.pixelSize.width) / Double($0.pixelSize.height) : nil },
            badge: CollectionFormat.badge(entry: page.entry, metadata: metadata),
            isFailed: isUnavailable,
            isVideo: page.entry.kind == .video && !isUnavailable
        )
        return CollectionItem(
            canvas: canvas, name: page.entry.name, detail: size.isEmpty ? bytes : "\(size) · \(bytes)", column: size, size: bytes,
            failure: isUnavailable ? String(localized: "不可用") : nil
        )
    }
}

enum CollectionFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// 视频显示时长；时长未知或动图显示扩展名。
    static func badge(entry: Entry, metadata: ImageMetadata?) -> String? {
        let suffix = (entry.name as NSString).pathExtension.uppercased()
        if entry.kind == .video {
            return metadata?.duration.map(duration) ?? suffix
        }
        return (metadata?.frameCount ?? 1) > 1 ? suffix : nil
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
