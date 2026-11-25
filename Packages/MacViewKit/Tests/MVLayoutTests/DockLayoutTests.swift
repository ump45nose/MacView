import Foundation
import MVFoundation
import Testing
@testable import MVLayout

private let a = PanelID("a"), b = PanelID("b"), c = PanelID("c"), d = PanelID("d")
private let frame = DockFrame(x: 100, y: 200, width: 260, height: 360)

/// 左：a b（标签页，选中 b），右：c，底：空。
private func sample() -> DockLayout {
    DockLayout(
        left: DockArea(panels: [a, b], selected: b, size: 240),
        right: DockArea(panels: [c], size: 260),
        bottom: DockArea(size: 180),
        settings: [a: .string("a-settings"), c: .number(3)]
    )
}

private func panels(_ layout: DockLayout) -> [[String]] {
    DockEdge.allCases.map { layout[$0].panels.map(\.rawValue) } + [layout.floating.map(\.panel.rawValue)]
}

// MARK: - 移动

@Test func movingBetweenAreasInsertsAtTheVisiblePositionAndCarriesSettings() {
    let moved = sample().moving(a, to: .area(.right, index: 0))
    #expect(panels(moved) == [["b"], ["a", "c"], [], []])
    #expect(moved.settings[a] == .string("a-settings"))
    #expect(moved.right.selected == a)
    #expect(moved.currentTab(in: .left) == b)
    // 左区原来选中的是 b，不受影响。
    #expect(moved.left.selected == b)
}

@Test func movingToTheEndOfAnArea() {
    let moved = sample().moving(a, to: .area(.right, index: 1))
    #expect(panels(moved) == [["b"], ["c", "a"], [], []])
}

@Test func movingWithinTheSameAreaKeepsTheDropPosition() {
    var layout = sample().moving(c, to: .area(.left, index: 2))
    #expect(panels(layout) == [["a", "b", "c"], [], [], []])
    // 把 a 拖到 c 之前（可见位置 2）：落在 b 与 c 之间，而不是错一格。
    layout = layout.moving(a, to: .area(.left, index: 2))
    #expect(panels(layout) == [["b", "a", "c"], [], [], []])
    // 拖到自己之前或之后：位置不变。
    #expect(panels(layout.moving(a, to: .area(.left, index: 1))) == [["b", "a", "c"], [], [], []])
    #expect(panels(layout.moving(a, to: .area(.left, index: 2))) == [["b", "a", "c"], [], [], []])
    // 拖到最前与最后。
    #expect(panels(layout.moving(c, to: .area(.left, index: 0))) == [["c", "b", "a"], [], [], []])
    #expect(panels(layout.moving(b, to: .area(.left, index: 3))) == [["a", "c", "b"], [], [], []])
}

@Test func visibleIndexSkipsHiddenPanels() {
    // 左：a（隐藏）b c；可见的是 b c。
    var layout = sample().moving(c, to: .area(.left, index: 2))
    layout = layout.togglingPanel(a, defaultEdge: .left)
    #expect(layout.visiblePanels(in: .left) == [b, c])
    let moved = layout.moving(d, to: .area(.left, index: 1))
    #expect(panels(moved) == [["a", "b", "d", "c"], [], [], []])
    let atEnd = layout.moving(d, to: .area(.left, index: 2))
    #expect(panels(atEnd) == [["a", "b", "c", "d"], [], [], []])
}

@Test func movingIntoACollapsedAreaExpandsItAndShowsThePanel() {
    var layout = sample().settingCollapsed(.bottom, true).togglingPanel(a, defaultEdge: .left)
    #expect(layout.hidden == [a])
    layout = layout.moving(a, to: .area(.bottom, index: 0))
    #expect(layout.isShowing(.bottom))
    #expect(layout.hidden.isEmpty)
    #expect(layout.isPanelVisible(a))
}

// MARK: - 标签页与上下分割

@Test func togglingStyleKeepsPanelsSelectionAndWeights() {
    var layout = sample().reweighting(.left, [a: 2, b: 1])
    layout = layout.togglingStyle(.left)
    #expect(layout.left.style == .split)
    #expect(layout.left.panels == [a, b])
    #expect(layout.left.weights == [a: 2, b: 1])
    layout = layout.togglingStyle(.left)
    #expect(layout.left.style == .tabs)
    #expect(layout.currentTab(in: .left) == b)
    #expect(layout.left.weights == [a: 2, b: 1])
}

@Test func droppingIntoASplitStackUsesTheSplitPosition() {
    let layout = sample().togglingStyle(.left).moving(c, to: .area(.left, index: 1))
    #expect(layout.left.style == .split)
    #expect(panels(layout) == [["a", "c", "b"], [], [], []])
}

@Test func removingAPanelDropsItsWeightAndSelection() {
    let layout = sample().reweighting(.left, [a: 2, b: 3]).moving(b, to: .area(.right, index: 0))
    #expect(layout.left.weights == [a: 2])
    #expect(layout.left.selected == nil)
    #expect(layout.currentTab(in: .left) == a)
}

// MARK: - 浮动

@Test func floatingOutAndDockingBack() {
    let floated = sample().moving(a, to: .floating(frame))
    #expect(panels(floated) == [["b"], ["c"], [], ["a"]])
    #expect(floated.floating == [FloatingPanel(panel: a, frame: frame, home: .left, settings: .string("a-settings"))])
    #expect(floated.settings[a] == nil)
    #expect(floated.settings(of: a) == .string("a-settings"))
    #expect(floated.isPanelVisible(a))

    // 移动浮动面板只改 frame。
    let moved = floated.movingFloating(a, to: DockFrame(x: 0, y: 0, width: 300, height: 300))
    #expect(moved.floating[0].frame.width == 300)

    // 拖回到右区最前。
    let back = moved.moving(a, to: .area(.right, index: 0))
    #expect(panels(back) == [["b"], ["a", "c"], [], []])
    #expect(back.settings[a] == .string("a-settings"))
    #expect(back.floating.isEmpty)

    // “停靠”回原来的区，排在最后。
    let home = moved.docking(a)
    #expect(panels(home) == [["b", "a"], ["c"], [], []])
    #expect(home.left.selected == a)
}

@Test func floatingAFloatingPanelAgainKeepsItsHome() {
    let layout = sample().moving(c, to: .floating(frame)).moving(c, to: .floating(DockFrame(x: 1, y: 2, width: 3, height: 4)))
    #expect(layout.floating.count == 1)
    #expect(layout.floating[0].home == .right)
    #expect(layout.floating[0].frame == DockFrame(x: 1, y: 2, width: 3, height: 4))
}

@Test func floatingSettingsFollowThePanel() {
    var layout = sample().moving(a, to: .floating(frame))
    layout = layout.settingSettings(.bool(true), for: a)
    #expect(layout.floating[0].settings == .bool(true))
    #expect(layout.settings[a] == nil)
    layout = layout.settingSettings(.bool(false), for: b)
    #expect(layout.settings[b] == .bool(false))
}

@Test func adoptingFloatingRemovesDockedCopies() {
    // 窗口 1 把 a 拖出浮动；窗口 2 原来把 a 停靠在底部。
    let first = sample().moving(a, to: .floating(frame))
    let second = DockLayout(
        left: DockArea(panels: [b], size: 200), right: DockArea(size: 200),
        bottom: DockArea(panels: [a], size: 150), hidden: [a], settings: [a: .null]
    )
    let adopted = second.adoptingFloating(of: first)
    #expect(panels(adopted) == [["b"], [], [], ["a"]])
    #expect(adopted.hidden.isEmpty)
    #expect(adopted.settings[a] == nil)
    // 浮动面板带的是窗口 1 的设置。
    #expect(adopted.settings(of: a) == .string("a-settings"))
    // 停靠回窗口 2 后，窗口 1 采用新的（空的）浮动列表，也不再有 a。
    let docked = adopted.moving(a, to: .area(.right, index: 0))
    #expect(panels(first.adoptingFloating(of: docked)) == [["b"], ["c"], [], []])
}

@Test func crossWindowMoveRemovesFromTheSourceAndInsertsWithItsSettings() {
    let source = sample()
    let target = DockLayout(left: DockArea(size: 200), right: DockArea(size: 200), bottom: DockArea(size: 150))
    let removed = source.removing(c)
    let inserted = target.inserting(c, at: .area(.bottom, index: 0), settings: source.settings(of: c))
    #expect(panels(removed) == [["a", "b"], [], [], []])
    #expect(removed.settings[c] == nil)
    #expect(panels(inserted) == [[], [], ["c"], []])
    #expect(inserted.settings[c] == .number(3))
}

// MARK: - 显示与隐藏

@Test func togglingPanels() {
    var layout = sample()
    // 隐藏 b：位置保留，标签页改显示 a。
    layout = layout.togglingPanel(b, defaultEdge: .left)
    #expect(layout.left.panels == [a, b])
    #expect(!layout.isPanelVisible(b))
    #expect(layout.currentTab(in: .left) == a)
    // 再显示：选中 b。
    layout = layout.togglingPanel(b, defaultEdge: .left)
    #expect(layout.isPanelVisible(b))
    #expect(layout.currentTab(in: .left) == b)
    // 折叠的区里的面板不可见；显示它时区随之展开。
    layout = layout.togglingArea(.right)
    #expect(layout.right.isCollapsed)
    #expect(!layout.isPanelVisible(c))
    layout = layout.togglingPanel(c, defaultEdge: .left)
    #expect(!layout.right.isCollapsed)
    #expect(layout.isPanelVisible(c))
    // 不在布局中的面板放进默认区。
    layout = layout.togglingPanel(d, defaultEdge: .bottom)
    #expect(layout.bottom.panels == [d])
    #expect(layout.isShowing(.bottom))
    // 浮动面板切换隐藏状态。
    layout = layout.moving(d, to: .floating(frame)).togglingPanel(d, defaultEdge: .bottom)
    #expect(layout.floating[0].isHidden)
    #expect(!layout.isPanelVisible(d))
}

@Test func togglingAreas() {
    var layout = sample()
    #expect(layout.isShowing(.left) && layout.isShowing(.right) && !layout.isShowing(.bottom))
    layout = layout.togglingAllAreas()
    #expect(DockEdge.allCases.allSatisfy { layout[$0].isCollapsed })
    layout = layout.togglingAllAreas()
    #expect(DockEdge.allCases.allSatisfy { !layout[$0].isCollapsed })
    // 空的区：显示与隐藏都不改变它不占空间这一点。
    #expect(!layout.togglingArea(.bottom).isShowing(.bottom))
    #expect(layout.togglingArea(.left).left.isCollapsed)
    #expect(layout.resizing(.left, to: 300).left.size == 300)
}

// MARK: - 文件

@Test func codableRoundTripAndKeyedDictionaries() throws {
    let layout = sample().reweighting(.left, [a: 1.5]).moving(c, to: .floating(frame)).togglingPanel(b, defaultEdge: .left)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(layout)
    #expect(try JSONDecoder().decode(DockLayout.self, from: data) == layout)
    // PanelID 作字典的键时编码为对象，便于手工编辑。
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((object["settings"] as? [String: Any])?["a"] as? String == "a-settings")
    #expect(((object["left"] as? [String: Any])?["weights"] as? [String: Any])?["a"] as? Double == 1.5)
}

@Test func sanitizingDropsUnknownAndDuplicatePanels() {
    var layout = sample()
    layout.right.panels = [c, a, PanelID("gone")]
    layout.right.weights = [PanelID("gone"): 2, c: 1]
    layout.right.selected = PanelID("gone")
    layout.floating = [FloatingPanel(panel: c, frame: frame, home: .right), FloatingPanel(panel: d, frame: frame, home: .left)]
    layout.hidden = [PanelID("gone"), b]
    layout.settings[PanelID("gone")] = .null
    let clean = layout.sanitized(knownPanels: [a, b, c, d])
    #expect(panels(clean) == [["a", "b"], ["c"], [], ["d"]])
    #expect(clean.right.weights == [c: 1])
    #expect(clean.right.selected == nil)
    #expect(clean.hidden == [b])
    #expect(clean.settings.keys.sorted { $0.rawValue < $1.rawValue } == [a, c])
}

@Test func sanitizingPreservesPluginPanelsAndDropsDuplicates() {
    // C1.7: 停靠（含隐藏、选中、权重、视图设置）和浮动的 plugin.x.y 面板在 knownPanels 不含它时原样保留；
    // 未知的非插件面板照旧去掉；重复的插件面板只留第一个。
    let pDocked = PanelID("plugin.x.y")
    let pHidden = PanelID("plugin.x.hidden")
    let pFloat = PanelID("plugin.z.float")
    let unknown = PanelID("unknown")

    #expect(pDocked.isPluginPanel)
    #expect(!a.isPluginPanel)

    var layout = sample()
    layout.left.panels = [a, pHidden, unknown]
    layout.right.panels = [c, pDocked, pDocked]
    layout.right.weights = [c: 1, pDocked: 2.5, unknown: 3]
    layout.right.selected = pDocked
    layout.floating = [
        FloatingPanel(panel: pDocked, frame: frame, home: .right), // 与右区重复，应去掉
        FloatingPanel(panel: pFloat, frame: frame, home: .bottom, isHidden: true, settings: .string("f-set")),
        FloatingPanel(panel: unknown, frame: frame, home: .left),
    ]
    layout.hidden = [pHidden, unknown]
    layout.settings = [a: .string("a-settings"), pDocked: .number(9), pHidden: .bool(true), unknown: .null]

    let clean = layout.sanitized(knownPanels: [a, b, c, d])
    #expect(panels(clean) == [["a", "plugin.x.hidden"], ["c", "plugin.x.y"], [], ["plugin.z.float"]])
    #expect(clean.right.weights == [c: 1, pDocked: 2.5])
    #expect(clean.right.selected == pDocked)
    #expect(clean.hidden == [pHidden])
    #expect(clean.settings == [a: .string("a-settings"), pDocked: .number(9), pHidden: .bool(true)])
    #expect(clean.floating == [FloatingPanel(panel: pFloat, frame: frame, home: .bottom, isHidden: true, settings: .string("f-set"))])
}

@Test func displayedAndMergingPreserveUnavailablePluginPanelPositionSelectionAndState() {
    // C1.7b: 右区 [pageList, plugin.a.x(选中), info]，plugin.a.x 不可用：
    // 显示布局为 [pageList, info]、选中回退到 pageList；
    // 在显示布局上把 info 拖到最前再并回，按原序号插回得到 [info, plugin.a.x, pageList]，选中仍为 plugin.a.x；
    // plugin.a.x 恢复可用后显示布局里它回到该位置且为选中。
    // 浮动与隐藏的不可用插件面板并回后原样保留。
    let pageList = PanelID("pageList")
    let info = PanelID("info")
    let bookshelf = PanelID("bookshelf")
    let pluginAX = PanelID("plugin.a.x")
    let pluginHidden = PanelID("plugin.b.hidden")
    let pluginFloat = PanelID("plugin.c.float")
    let floatingItem = FloatingPanel(panel: pluginFloat, frame: frame, home: .bottom, isHidden: false, settings: .string("float-state"))

    let saved = DockLayout(
        left: DockArea(panels: [bookshelf, pluginHidden], selected: bookshelf, weights: [bookshelf: 1, pluginHidden: 1.5], size: 240),
        right: DockArea(panels: [pageList, pluginAX, info], selected: pluginAX, weights: [pageList: 1, pluginAX: 2, info: 1], size: 260),
        bottom: DockArea(size: 180),
        floating: [floatingItem],
        hidden: [pluginHidden],
        settings: [pluginAX: .string("ax-view"), pluginHidden: .bool(true)]
    )

    let availableWithoutPlugins: Set<PanelID> = [bookshelf, pageList, info]
    let displayed = saved.displayed(available: availableWithoutPlugins)
    #expect(displayed.right.panels == [pageList, info])
    #expect(displayed.right.selected == nil)
    #expect(displayed.currentTab(in: .right) == pageList)
    #expect(displayed.right.weights == [pageList: 1, info: 1])
    #expect(displayed.left.panels == [bookshelf])
    #expect(displayed.floating.isEmpty)
    #expect(displayed.hidden.isEmpty)
    #expect(displayed.settings.isEmpty)

    // 在显示布局上把 info 拖到最前再并回（moving 会清掉被拖面板的旧权重，pluginAX 的权重应从 saved 带回）
    let dragged = displayed.moving(info, to: .area(.right, index: 0))
    let merged = dragged.merging(unavailableFrom: saved, available: availableWithoutPlugins)
    #expect(merged.right.panels == [info, pluginAX, pageList])
    #expect(merged.right.selected == pluginAX)
    #expect(merged.right.weights == [pageList: 1, pluginAX: 2])
    #expect(merged.left.panels == [bookshelf, pluginHidden])
    #expect(merged.left.weights == [bookshelf: 1, pluginHidden: 1.5])
    #expect(merged.hidden == [pluginHidden])
    #expect(merged.settings == [pluginAX: .string("ax-view"), pluginHidden: .bool(true)])
    #expect(merged.floating == [floatingItem])

    // plugin.a.x 恢复可用后显示布局里它回到该位置且为选中
    let restored = merged.displayed(available: [bookshelf, pageList, info, pluginAX])
    #expect(restored.right.panels == [info, pluginAX, pageList])
    #expect(restored.right.selected == pluginAX)
    #expect(restored.currentTab(in: .right) == pluginAX)

    // 若用户显式切到非回退标签（info），并回时尊重用户选中
    let switched = displayed.selecting(info)
    let mergedAfterSwitch = switched.merging(unavailableFrom: saved, available: availableWithoutPlugins)
    #expect(mergedAfterSwitch.right.selected == info)
}
