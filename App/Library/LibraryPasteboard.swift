import AppKit
import Foundation
import MVFoundation

extension NSPasteboard.PasteboardType {
    /// App 内部拖放的位置：每个拖动项一份 `[Location]` 的 JSON。书签面板和播放列表面板只认这个类型。
    static let locations = NSPasteboard.PasteboardType("com.macview.locations")
}

/// `com.macview.locations` 的读写。拖出时附在原有的写入（文件 URL 或文件承诺）上，接收时按拖动项的顺序取回位置。
@MainActor
enum LibraryPasteboard {
    /// 在原有写入之外附上这一项的位置；没有原有写入时只写位置。
    static func writer(wrapping base: (any NSPasteboardWriting)?, location: Location) -> any NSPasteboardWriting {
        let data = encode([location])
        switch base {
        case let promise as NSFilePromiseProvider:
            // 文件承诺要保持 NSFilePromiseProvider 本身，系统才会向它的代理要文件。
            guard let delegate = promise.delegate else { return promise }
            let provider = PromiseWithLocations(fileType: promise.fileType, delegate: delegate)
            provider.userInfo = promise.userInfo
            provider.locationsData = data
            return provider
        case let base?:
            return WriterWithLocations(base: base, locationsData: data)
        case nil:
            let item = NSPasteboardItem()
            item.setData(data, forType: .locations)
            return item
        }
    }

    /// 拖动中的全部位置，按拖动项的顺序。
    static func locations(from pasteboard: NSPasteboard) -> [Location] {
        let decoder = JSONDecoder()
        return (pasteboard.pasteboardItems ?? []).flatMap { item in
            item.data(forType: .locations).flatMap { try? decoder.decode([Location].self, from: $0) } ?? []
        }
    }

    private static func encode(_ locations: [Location]) -> Data {
        // Location 只有字符串和枚举，编码不会失败。
        (try? JSONEncoder().encode(locations)) ?? Data()
    }
}

private final class PromiseWithLocations: NSFilePromiseProvider {
    var locationsData = Data()

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.locations]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .locations ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .locations ? locationsData : super.pasteboardPropertyList(forType: type)
    }
}

private final class WriterWithLocations: NSObject, NSPasteboardWriting {
    private let base: any NSPasteboardWriting
    private let locationsData: Data

    init(base: any NSPasteboardWriting, locationsData: Data) {
        self.base = base
        self.locationsData = locationsData
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        base.writableTypes(for: pasteboard) + [.locations]
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .locations ? [] : base.writingOptions?(forType: type, pasteboard: pasteboard) ?? []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .locations ? locationsData : base.pasteboardPropertyList(forType: type)
    }
}
