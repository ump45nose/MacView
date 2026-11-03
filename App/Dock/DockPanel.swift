import AppKit
import MVCommands
import MVFoundation
import MVLayout

/// 停靠面板。具体面板（书架、页面列表等）实现这个协议，再在 `DockPanels.all` 中登记一个 `DockPanelType`。
///
/// 同一种面板在每个停靠它的窗口里各有一个实例；浮动时全应用只有一个实例，随活动窗口切换 `bind(to:)`。
/// 面板在区之间移动时实例和视图保留，只换父视图。
@MainActor
protocol DockPanel: AnyObject {
    /// 视图设置，存进 layout.json。
    associatedtype Settings: Codable

    var view: NSView { get }
    var settings: Settings { get }
    /// 视图设置改变后由面板调用，框架随后去抖保存。
    var onSettingsChange: (() -> Void)? { get set }
    /// 面板作用的窗口：停靠的面板是所在窗口；浮动面板是当前活动窗口，没有阅读窗口时为 nil。
    func bind(to window: ReaderWindowController?)
    /// 区头 ⋯ 菜单里这个面板的选项。
    func addOptions(to menu: NSMenu)
}

extension DockPanel {
    func encodedSettings() -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
        } catch {
            preconditionFailure("面板的视图设置无法编码为 JSON：\(error)")
        }
    }
}

/// 一种面板的登记：标识、标题、图标、显示/隐藏命令、默认所在的区，以及创建方法与视图设置的解码。
@MainActor
struct DockPanelType {
    let id: PanelID
    let title: String
    /// SF Symbols 名称。
    let symbol: String
    /// 显示或隐藏这个面板的命令，出现在“显示”菜单。
    let toggleCommand: CommandID
    /// 面板不在布局中、又被要求显示时放进的区。
    let defaultEdge: DockEdge
    /// 按 layout.json 中的视图设置创建面板；设置无法解码时用默认设置创建，并返回错误。
    let instantiate: @MainActor (JSONValue?) -> (panel: any DockPanel, error: (any Error)?)

    init<Panel: DockPanel>(
        id: PanelID, title: String, symbol: String, toggleCommand: CommandID, defaultEdge: DockEdge,
        make: @escaping @MainActor (Panel.Settings?) -> Panel
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.toggleCommand = toggleCommand
        self.defaultEdge = defaultEdge
        instantiate = { json in
            guard let json else { return (make(nil), nil) }
            do {
                let settings = try JSONDecoder().decode(Panel.Settings.self, from: JSONEncoder().encode(json))
                return (make(settings), nil)
            } catch {
                return (make(nil), error)
            }
        }
    }
}

/// 登记的面板与默认布局。
@MainActor
enum DockPanels {
    static let bookshelf = PanelID("bookshelf")
    static let pageList = PanelID("pageList")

    static let all: [DockPanelType] = [
        DockPanelType(
            id: bookshelf, title: String(localized: "书架"), symbol: "books.vertical",
            toggleCommand: .bookshelfToggle, defaultEdge: .left, make: BookshelfPanel.init
        ),
        DockPanelType(
            id: pageList, title: String(localized: "页面列表"), symbol: "square.grid.3x3",
            toggleCommand: .pageListToggle, defaultEdge: .right, make: PageListPanel.init
        ),
    ]

    static func type(_ id: PanelID) -> DockPanelType? {
        all.first { $0.id == id }
    }

    /// 没有 layout.json 或它无法解析时使用：书架在左，页面列表在右，底部区为空。
    static let defaultLayout = DockLayout(
        left: DockArea(panels: [bookshelf], size: 240),
        right: DockArea(panels: [pageList], size: 260),
        bottom: DockArea(size: 200)
    )
}
