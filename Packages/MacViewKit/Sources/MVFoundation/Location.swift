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
        guard root == prefix.root, let last = prefix.layers.indices.last, last < layers.count else { return false }
        return layers[..<last] == prefix.layers[..<last] && layers[last].starts(with: prefix.layers[last])
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
