import Foundation
import MVFoundation

/// 面板类型的标识，例如 `bookshelf`。JSON 中是一个字符串，也可以作字典的键。
public struct PanelID: RawRepresentable, Hashable, Codable, Sendable, CodingKeyRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum DockEdge: String, Codable, Sendable, CaseIterable {
    case left, right, bottom
}

/// 一个停靠区里面板栈的形式。
public enum DockStackStyle: String, Codable, Sendable {
    case tabs, split
}

/// 一个停靠区：一个面板栈，加上尺寸与折叠状态。
public struct DockArea: Codable, Sendable, Hashable {
    /// 栈中的面板，按显示顺序；包括被隐藏的（隐藏的面板保留位置）。
    public var panels: [PanelID]
    public var style: DockStackStyle
    /// 标签页形式下选中的面板。它被隐藏或移走时，显示第一个可见的面板。
    public var selected: PanelID?
    /// 上下分割时各面板的相对高度；没有记录的按 1。
    public var weights: [PanelID: Double]
    /// 左右区是宽度，底部区是高度（点）。
    public var size: Double
    /// 折叠后整个区不占空间；面板与尺寸保留。
    public var isCollapsed: Bool

    public init(
        panels: [PanelID] = [], style: DockStackStyle = .tabs, selected: PanelID? = nil,
        weights: [PanelID: Double] = [:], size: Double, isCollapsed: Bool = false
    ) {
        self.panels = panels
        self.style = style
        self.selected = selected
        self.weights = weights
        self.size = size
        self.isCollapsed = isCollapsed
    }
}

/// 屏幕坐标中的矩形（原点在左下，与 NSWindow 的 frame 一致）。
public struct DockFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 一个浮动面板。浮动面板全应用共享，作用于当前活动窗口。
public struct FloatingPanel: Codable, Sendable, Hashable {
    public var panel: PanelID
    public var frame: DockFrame
    /// “停靠”时回到的区：浮动之前所在的区。
    public var home: DockEdge
    public var isHidden: Bool
    public var settings: JSONValue?

    public init(panel: PanelID, frame: DockFrame, home: DockEdge, isHidden: Bool = false, settings: JSONValue? = nil) {
        self.panel = panel
        self.frame = frame
        self.home = home
        self.isHidden = isHidden
        self.settings = settings
    }
}

/// 拖放的目的地。
public enum DockTarget: Hashable, Sendable {
    /// 放进停靠区的面板栈，排在第 `index` 个可见面板之前；`index` 等于可见面板数时放在最后。
    /// 标签页形式下是标签的位置，上下分割时是分割的位置。
    case area(DockEdge, index: Int)
    case floating(DockFrame)
}

public enum PanelPlacement: Hashable, Sendable {
    /// `index` 是在区的面板列表（含隐藏的）中的位置。
    case docked(DockEdge, index: Int)
    case floating(index: Int)
}

/// layout.json 中的停靠布局：三个停靠区的面板栈、栈的形式、尺寸、折叠状态、浮动面板，以及各面板的视图设置。
///
/// 一个面板在布局中至多出现一次：停靠在某个区，或者浮动。变换都是纯函数，返回新的布局。
public struct DockLayout: Codable, Sendable, Hashable {
    public var left: DockArea
    public var right: DockArea
    public var bottom: DockArea
    public var floating: [FloatingPanel]
    /// 被隐藏的停靠面板，在栈中的位置保留。
    public var hidden: Set<PanelID>
    /// 停靠面板的视图设置；浮动面板的在 `FloatingPanel.settings` 中，随面板移动。
    public var settings: [PanelID: JSONValue]

    public init(
        left: DockArea, right: DockArea, bottom: DockArea, floating: [FloatingPanel] = [],
        hidden: Set<PanelID> = [], settings: [PanelID: JSONValue] = [:]
    ) {
        self.left = left
        self.right = right
        self.bottom = bottom
        self.floating = floating
        self.hidden = hidden
        self.settings = settings
    }

    public subscript(edge: DockEdge) -> DockArea {
        get {
            switch edge {
            case .left: left
            case .right: right
            case .bottom: bottom
            }
        }
        set {
            switch edge {
            case .left: left = newValue
            case .right: right = newValue
            case .bottom: bottom = newValue
            }
        }
    }

    // MARK: 查询

    public func placement(of panel: PanelID) -> PanelPlacement? {
        for edge in DockEdge.allCases {
            if let index = self[edge].panels.firstIndex(of: panel) { return .docked(edge, index: index) }
        }
        return floating.firstIndex { $0.panel == panel }.map { .floating(index: $0) }
    }

    /// 区中没有被隐藏的面板。
    public func visiblePanels(in edge: DockEdge) -> [PanelID] {
        self[edge].panels.filter { !hidden.contains($0) }
    }

    /// 区是否占据空间：没有折叠，并且有可见的面板。
    public func isShowing(_ edge: DockEdge) -> Bool {
        !self[edge].isCollapsed && !visiblePanels(in: edge).isEmpty
    }

    /// 标签页形式下当前显示的面板。
    public func currentTab(in edge: DockEdge) -> PanelID? {
        let visible = visiblePanels(in: edge)
        if let selected = self[edge].selected, visible.contains(selected) { return selected }
        return visible.first
    }

    /// 面板是否显示在界面上：停靠在显示中的区且没被隐藏，或者是没被隐藏的浮动面板。
    public func isPanelVisible(_ panel: PanelID) -> Bool {
        switch placement(of: panel) {
        case let .docked(edge, _): !hidden.contains(panel) && !self[edge].isCollapsed
        case let .floating(index): !floating[index].isHidden
        case nil: false
        }
    }

    public func settings(of panel: PanelID) -> JSONValue? {
        if case let .floating(index) = placement(of: panel) { return floating[index].settings }
        return settings[panel]
    }

    // MARK: 变换

    /// 在本布局内移动面板：移到停靠区的某个位置（包括从浮动拖回），或者拖出成浮动面板。视图设置随面板移动。
    public func moving(_ panel: PanelID, to target: DockTarget) -> DockLayout {
        inserting(panel, at: target, settings: settings(of: panel))
    }

    /// 放入面板；它已在本布局中时先移走。用于跨窗口拖动的目标一侧，`settings` 来自源窗口。
    ///
    /// 放进停靠区时：面板变为可见，区展开，标签页形式下选中它。
    /// 拖出浮动时：`home` 记为它原来所在的区。
    public func inserting(_ panel: PanelID, at target: DockTarget, settings: JSONValue?) -> DockLayout {
        var next = self
        switch target {
        case let .area(edge, index):
            // 先按移走之前的可见列表找到“排在谁之前”，同区内移动时位置才不会错一格。
            let visible = visiblePanels(in: edge)
            let anchor = visible.indices.contains(index)
                ? visible[index...].first { $0 != panel }
                : nil
            next.remove(panel)
            var area = next[edge]
            let position = anchor.flatMap { area.panels.firstIndex(of: $0) }
                ?? visible.last(where: { $0 != panel }).flatMap { area.panels.firstIndex(of: $0) }.map { $0 + 1 }
                ?? area.panels.count
            area.panels.insert(panel, at: position)
            area.isCollapsed = false
            area.selected = panel
            next[edge] = area
            if let settings { next.settings[panel] = settings }
        case let .floating(frame):
            let home: DockEdge
            switch placement(of: panel) {
            case let .docked(edge, _): home = edge
            case let .floating(index): home = floating[index].home
            case nil: home = .right
            }
            next.remove(panel)
            next.floating.append(FloatingPanel(panel: panel, frame: frame, home: home, settings: settings))
        }
        return next
    }

    /// 从布局中移走面板（跨窗口拖动的源一侧）。它的视图设置一并移走。
    public func removing(_ panel: PanelID) -> DockLayout {
        var next = self
        next.remove(panel)
        return next
    }

    /// 浮动面板停靠回原来的区，排在最后。
    public func docking(_ panel: PanelID) -> DockLayout {
        guard case let .floating(index) = placement(of: panel) else { return self }
        let edge = floating[index].home
        return moving(panel, to: .area(edge, index: visiblePanels(in: edge).count))
    }

    /// 标签页与上下分割互换。面板、选中项和分割比例都保留。
    public func togglingStyle(_ edge: DockEdge) -> DockLayout {
        var next = self
        next[edge].style = self[edge].style == .tabs ? .split : .tabs
        return next
    }

    public func selecting(_ panel: PanelID) -> DockLayout {
        guard case let .docked(edge, _) = placement(of: panel) else { return self }
        var next = self
        next[edge].selected = panel
        return next
    }

    public func resizing(_ edge: DockEdge, to size: Double) -> DockLayout {
        var next = self
        next[edge].size = size
        return next
    }

    /// 记录上下分割的比例；只更新给出的面板。
    public func reweighting(_ edge: DockEdge, _ weights: [PanelID: Double]) -> DockLayout {
        var next = self
        next[edge].weights.merge(weights) { _, new in new }
        return next
    }

    public func settingCollapsed(_ edge: DockEdge, _ isCollapsed: Bool) -> DockLayout {
        var next = self
        next[edge].isCollapsed = isCollapsed
        return next
    }

    /// 显示或隐藏一个停靠区。
    public func togglingArea(_ edge: DockEdge) -> DockLayout {
        settingCollapsed(edge, isShowing(edge))
    }

    /// 有显示中的区时全部折叠，否则全部展开。
    public func togglingAllAreas() -> DockLayout {
        let collapse = DockEdge.allCases.contains { isShowing($0) }
        var next = self
        for edge in DockEdge.allCases { next[edge].isCollapsed = collapse }
        return next
    }

    /// 显示或隐藏一个面板。
    /// - 停靠的面板隐藏后保留位置；再显示时所在的区随之展开，标签页形式下选中它。
    /// - 浮动面板切换隐藏状态。
    /// - 不在布局中的面板放进 `defaultEdge` 的最后。
    public func togglingPanel(_ panel: PanelID, defaultEdge: DockEdge) -> DockLayout {
        var next = self
        switch placement(of: panel) {
        case let .docked(edge, _):
            if isPanelVisible(panel) {
                next.hidden.insert(panel)
            } else {
                next.hidden.remove(panel)
                next[edge].isCollapsed = false
                next[edge].selected = panel
            }
        case let .floating(index):
            next.floating[index].isHidden.toggle()
        case nil:
            return moving(panel, to: .area(defaultEdge, index: visiblePanels(in: defaultEdge).count))
        }
        return next
    }

    public func movingFloating(_ panel: PanelID, to frame: DockFrame) -> DockLayout {
        guard case let .floating(index) = placement(of: panel) else { return self }
        var next = self
        next.floating[index].frame = frame
        return next
    }

    /// 更新面板的视图设置：停靠的写进 `settings`，浮动的写进它的 `FloatingPanel`。
    public func settingSettings(_ value: JSONValue, for panel: PanelID) -> DockLayout {
        var next = self
        if case let .floating(index) = placement(of: panel) {
            next.floating[index].settings = value
        } else {
            next.settings[panel] = value
        }
        return next
    }

    /// 采用另一个布局的浮动面板（浮动面板全应用共享）：浮动列表换成对方的，本布局中停靠着的同一面板随之移走。
    public func adoptingFloating(of other: DockLayout) -> DockLayout {
        var next = self
        next.floating = []
        for item in other.floating { next.remove(item.panel) }
        next.floating = other.floating
        return next
    }

    /// 整理从文件读入的布局：去掉未登记的面板；同一面板出现多次时只保留第一次（左、右、底、浮动的顺序）。
    public func sanitized(knownPanels: Set<PanelID>) -> DockLayout {
        var next = self
        var seen: Set<PanelID> = []
        func keep(_ panel: PanelID) -> Bool {
            knownPanels.contains(panel) && seen.insert(panel).inserted
        }
        for edge in DockEdge.allCases {
            next[edge].panels = self[edge].panels.filter(keep)
            next[edge].weights = next[edge].weights.filter { next[edge].panels.contains($0.key) }
            if let selected = next[edge].selected, !next[edge].panels.contains(selected) { next[edge].selected = nil }
        }
        next.floating = floating.filter { keep($0.panel) }
        let docked = Set(DockEdge.allCases.flatMap { next[$0].panels })
        next.hidden = hidden.intersection(docked)
        next.settings = settings.filter { docked.contains($0.key) }
        return next
    }

    // MARK: 内部

    private mutating func remove(_ panel: PanelID) {
        switch placement(of: panel) {
        case let .docked(edge, index):
            self[edge].panels.remove(at: index)
            self[edge].weights[panel] = nil
            if self[edge].selected == panel { self[edge].selected = nil }
            hidden.remove(panel)
            settings[panel] = nil
        case let .floating(index):
            floating.remove(at: index)
        case nil:
            break
        }
    }
}
