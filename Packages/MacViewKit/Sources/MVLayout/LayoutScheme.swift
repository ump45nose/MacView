import Foundation

/// 命名停靠布局方案，存在 `layout-schemes.json` 中。
public struct LayoutScheme: Codable, Sendable, Hashable {
    public var name: String
    public var layout: DockLayout

    public init(name: String, layout: DockLayout) {
        self.name = name
        self.layout = layout
    }
}

/// `layout-schemes.json` 的文档内容（v1）；版本与原子写入由 `JSONDocumentStore` 管理。
public struct LayoutSchemesFile: Codable, Sendable, Hashable {
    public var schemes: [LayoutScheme]

    public init(schemes: [LayoutScheme] = []) {
        self.schemes = schemes
    }
}
