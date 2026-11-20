import Foundation
import MVFoundation
import Testing
@testable import MVLayout

@Test func layoutSchemesFileEmptyRoundTrip() throws {
    let empty = LayoutSchemesFile()
    #expect(empty.schemes.isEmpty)

    let data = try JSONEncoder().encode(empty)
    let decoded = try JSONDecoder().decode(LayoutSchemesFile.self, from: data)
    #expect(decoded == empty)
    #expect(decoded.schemes.isEmpty)
}

@Test func layoutSchemesFileMultipleSchemesRoundTrip() throws {
    let bookshelf = PanelID("bookshelf")
    let pageList = PanelID("pageList")
    let info = PanelID("info")
    let effects = PanelID("effects")

    let readingLayout = DockLayout(
        left: DockArea(
            panels: [bookshelf, pageList],
            style: .split,
            selected: pageList,
            weights: [bookshelf: 1.5, pageList: 1.0],
            size: 260,
            isCollapsed: false
        ),
        right: DockArea(
            panels: [info],
            style: .tabs,
            selected: info,
            size: 280,
            isCollapsed: true
        ),
        bottom: DockArea(size: 160, isCollapsed: true),
        floating: [
            FloatingPanel(
                panel: effects,
                frame: DockFrame(x: 120, y: 240, width: 320, height: 420),
                home: .right,
                isHidden: false,
                settings: .object(["expanded": .bool(true)])
            ),
        ],
        hidden: [bookshelf],
        settings: [
            pageList: .object(["style": .string("grid"), "itemExtent": .number(128)]),
            info: .bool(true),
        ]
    )

    let minimalLayout = DockLayout(
        left: DockArea(size: 220, isCollapsed: true),
        right: DockArea(size: 220, isCollapsed: true),
        bottom: DockArea(panels: [pageList], style: .tabs, selected: pageList, size: 180, isCollapsed: false)
    )

    let file = LayoutSchemesFile(schemes: [
        LayoutScheme(name: "双栏阅读", layout: readingLayout),
        LayoutScheme(name: "极简模式", layout: minimalLayout),
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(file)
    let decoded = try JSONDecoder().decode(LayoutSchemesFile.self, from: data)
    #expect(decoded == file)
    #expect(decoded.schemes.map(\.name) == ["双栏阅读", "极简模式"])
    #expect(decoded.schemes[0].layout == readingLayout)
    #expect(decoded.schemes[1].layout == minimalLayout)
}
