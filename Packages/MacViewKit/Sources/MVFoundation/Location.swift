import Foundation

/// 一个文件或容器的位置：根加上逐层的路径。
///
/// - `layers[0]` 是根下的路径；之后每层是上一层末端压缩包内的路径。
///   例如 `Picture/a.zip!/inner/b.zip!/001.jpg` 的层是 `[["a.zip"], ["inner", "b.zip"], ["001.jpg"]]`。
/// - 根本身是 `[[]]`；压缩包内第一层的项，所在的容器就是压缩包本身。
/// - 持久化时存结构化 JSON，`description` 只用于显示。
public struct Location: Hashable, Sendable, Codable {
    public enum Root: Hashable, Sendable, Codable {
        case local
        case network(scheme: String, host: String, share: String)
        case plugin(id: String)
    }

    public var root: Root
    public var layers: [[String]]

    public init(root: Root, layers: [[String]] = [[]]) {
        self.root = root
        self.layers = layers
    }

    /// 末端的名称；根的名称为空串。
    public var name: String {
        layers.last?.last ?? ""
    }

    /// 所在的容器。根没有容器。
    public var parent: Location? {
        var layers = self.layers
        guard var last = layers.popLast(), !last.isEmpty else { return nil }
        last.removeLast()
        if last.isEmpty, !layers.isEmpty {
            return Location(root: root, layers: layers)
        }
        layers.append(last)
        return Location(root: root, layers: layers)
    }

    /// 同一层内的下一级，例如目录中的项。
    public func appending(_ name: String) -> Location {
        var layers = self.layers.isEmpty ? [[]] : self.layers
        layers[layers.count - 1].append(name)
        return Location(root: root, layers: layers)
    }

    /// 末端压缩包内的路径，作为新的一层。
    public func appendingLayer(_ path: [String]) -> Location {
        Location(root: root, layers: layers + [path])
    }

    /// 是否等于 `prefix` 或位于其下，包括其下压缩包内的项。
    public func hasPrefix(_ prefix: Location) -> Bool {
        let layers = layers.isEmpty ? [[]] : layers
        let prefixLayers = prefix.layers.isEmpty ? [[]] : prefix.layers
        guard root == prefix.root, let last = prefixLayers.indices.last, last < layers.count else { return false }
        return layers[..<last] == prefixLayers[..<last] && layers[last].starts(with: prefixLayers[last])
    }

    /// 若当前位置以 `old` 为前缀，将其替换为 `new`，保留后缀与更深层路径；否则返回 `nil`。
    public func replacingPrefix(_ old: Location, with new: Location) -> Location? {
        guard hasPrefix(old) else { return nil }
        let locLayers = layers.isEmpty ? [[]] : layers
        let oldLayers = old.layers.isEmpty ? [[]] : old.layers
        var resultLayers = new.layers.isEmpty ? [[]] : new.layers
        let lastIndex = oldLayers.count - 1
        resultLayers[resultLayers.count - 1].append(contentsOf: locLayers[lastIndex].dropFirst(oldLayers[lastIndex].count))
        if lastIndex + 1 < locLayers.count {
            resultLayers.append(contentsOf: locLayers[(lastIndex + 1)...])
        }
        return Location(root: new.root, layers: resultLayers)
    }
}

extension Location {
    public static let playlistRootID = "playlist"

    public static func playlist(_ id: UUID) -> Location {
        Location(root: .plugin(id: playlistRootID), layers: [[id.uuidString]])
    }

    public var playlistID: UUID? {
        guard root == .plugin(id: Self.playlistRootID), layers.count == 1,
              layers[0].count == 1 else { return nil }
        return UUID(uuidString: layers[0][0])
    }

    /// `/` 分隔组件，`!` 单独标识进入压缩包；名称先规范化再编码，不含分隔符。
    /// 可用相等或 `prefix + "/"` 的范围查询代替逐条解码位置。
    public var prefixKey: String {
        func encode(_ string: String) -> String {
            let digits = Array("0123456789abcdef".utf8)
            return String(decoding: string.precomposedStringWithCanonicalMapping.utf8.flatMap {
                [digits[Int($0 >> 4)], digits[Int($0 & 15)]]
            }, as: UTF8.self)
        }
        var components: [String]
        switch root {
        case .local: components = ["l"]
        case let .network(scheme, host, share): components = ["n" + encode(scheme) + ":" + encode(host) + ":" + encode(share)]
        case let .plugin(id): components = ["p" + encode(id)]
        }
        for (index, layer) in layers.enumerated() {
            if index > 0 { components.append("!") }
            components.append(contentsOf: layer.map { "n" + encode($0) })
        }
        return components.joined(separator: "/")
    }
}

extension Location: CustomStringConvertible {
    /// 显示用的路径，例如 `Picture/a.zip!/inner/b.zip!/001.jpg`。
    public var description: String {
        let path = layers.map { $0.joined(separator: "/") }.joined(separator: "!/")
        switch root {
        case .local:
            return "/" + path
        case let .network(_, _, share):
            return path.isEmpty ? share : share + "/" + path
        case let .plugin(id):
            return id + ":" + path
        }
    }
}
