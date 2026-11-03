import AppKit
import MVFoundation
import MVMedia
import MVReading
import MVSettings
import Observation

/// 页面列表：当前书的页。排序只改面板内的显示顺序，翻页顺序不变。
@MainActor
final class PageListPanel: CollectionPanel {
    /// 显示顺序到书内页码。
    private var order: [Int] = []
    private var observedSession: SessionID?

    override var followsBook: Bool { true }

    override func windowChanged() {
        observedSession = boundSession
        observeBook()
        observeCurrent()
    }

    override func sortChanged() {
        refresh()
    }

    /// 书变化（页到达、元数据到达）时重建；翻页不重建。
    private func observeBook() {
        guard let owner, let id = observedSession else {
            refresh()
            return
        }
        withObservationTracking {
            _ = owner.session.book
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

    override func reload() {
        guard let session = owner?.session, let book = session.book else {
            order = []
            collection?.setItems([], current: nil)
            collection?.message = String(localized: "没有打开的书")
            setInfo(path: nil, count: "", canGoUp: false, onUp: nil)
            return
        }
        let pages = book.pages
        if let sort = settings.sort {
            var indices: [Location: Int] = [:]
            indices.reserveCapacity(pages.count)
            for (index, page) in pages.enumerated() { indices[page.id] = index }
            order = ReadingOrder.sorted(pages.map(\.entry), by: sort).compactMap { indices[$0.location] }
        } else {
            order = Array(pages.indices)
        }
        let items = order.map { Self.item(pages[$0]) }
        let wasEmpty = collection?.items.isEmpty ?? true
        collection?.setItems(items, current: order.firstIndex(of: session.currentPage))
        collection?.message = pages.isEmpty && book.isEnumerated ? String(localized: "这本书没有页") : nil
        let total = pages.reduce(Int64(0)) { $0 + $1.entry.identity.size }
        setInfo(path: book.location.name, count: String(localized: "\(pages.count) 页 · \(CollectionFormat.bytes(total))"), canGoUp: false, onUp: nil)
        if wasEmpty, !items.isEmpty { collection?.revealCurrentItem() }
    }

    override func activate(_ index: Int) {
        guard order.indices.contains(index) else { return }
        owner?.session.go(.index(order[index]))
    }

    private static func item(_ page: Page) -> CollectionItem {
        let metadata = page.metadata
        let size = metadata.map { "\($0.pixelSize.width)×\($0.pixelSize.height)" } ?? ""
        let bytes = CollectionFormat.bytes(page.entry.identity.size)
        let canvas = CanvasItem(
            identity: page.entry.identity,
            aspectRatio: metadata.flatMap { $0.pixelSize.height > 0 ? Double($0.pixelSize.width) / Double($0.pixelSize.height) : nil },
            badge: CollectionFormat.badge(entry: page.entry, metadata: metadata)
        )
        return CollectionItem(canvas: canvas, name: page.entry.name, detail: size.isEmpty ? bytes : "\(size) · \(bytes)", column: size, size: bytes)
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
