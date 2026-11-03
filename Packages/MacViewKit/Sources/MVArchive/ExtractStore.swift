import Foundation
import MVIO
import Synchronization

/// 解出文件的进程内 LRU。租约随 ByteSource 释放，索引本身不持有租约。
final class ExtractStore: Sendable {
    let directory: URL
    private let budget: Int64
    private struct Item {
        var url: URL
        var size: Int64
        var users: Int
        var access: UInt64
    }
    private struct State {
        var items: [String: Item] = [:]
        var clock: UInt64 = 0
        var cost: Int64 = 0
    }
    private let state = Mutex(State())

    init(directory: URL, budget: Int64) throws {
        self.directory = directory
        self.budget = max(0, budget)
        let parent = directory.deletingLastPathComponent()
        let recyclePrefix = ".macview-" + directory.lastPathComponent + "-recycle-"
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            // 同级改名不访问旧目录内容；新实例的 LRU 与预算从空目录开始。
            try FileManager.default.moveItem(at: directory, to: parent.appending(path: recyclePrefix + UUID().uuidString))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        ExtractIO.queue.async {
            // 只扫描上级这一层，也回收上次进程崩溃留下的目录。
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { return }
            for child in children {
                let name = child.lastPathComponent
                guard name.hasPrefix(recyclePrefix), UUID(uuidString: String(name.dropFirst(recyclePrefix.count))) != nil,
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                // 删除失败仍留在回收目录，下次启动再试。
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    func temporaryURL() -> URL { directory.appending(path: UUID().uuidString + ".partial") }

    func acquire(_ key: String) -> ExtractLease? {
        state.withLock { state in
            guard var item = state.items[key] else { return nil }
            state.clock &+= 1
            item.access = state.clock
            item.users += 1
            state.items[key] = item
            return ExtractLease(store: self, key: key, url: item.url, size: item.size)
        }
    }

    /// `pathExtension` 给按扩展名认格式的读者用（AVFoundation）。
    func install(_ temporary: URL, key: String, size: Int64, pathExtension: String = "") async throws -> ExtractLease {
        let destination = directory.appending(path: UUID().uuidString + "." + (pathExtension.isEmpty ? "extract" : pathExtension))
        try await ExtractIO.run { try FileManager.default.moveItem(at: temporary, to: destination) }
        let result = state.withLock { state in
            // 同一条目的并发解出只留下一个文件，各调用方仍有自己的租约。
            if var item = state.items[key] {
                ExtractIO.remove([destination])
                state.clock &+= 1
                item.access = state.clock
                item.users += 1
                state.items[key] = item
                return ExtractLease(store: self, key: key, url: item.url, size: item.size)
            }
            state.clock &+= 1
            state.items[key] = Item(url: destination, size: size, users: 1, access: state.clock)
            state.cost += size
            trim(&state)
            return ExtractLease(store: self, key: key, url: destination, size: size)
        }
        await ExtractIO.drain()
        return result
    }

    fileprivate func release(_ key: String) {
        state.withLock { state in
            guard state.items[key] != nil else { return }
            state.items[key]!.users -= 1
            trim(&state)
        }
    }

    private func trim(_ state: inout State) {
        while state.cost > budget {
            guard let key = state.items.filter({ $0.value.users == 0 }).min(by: { $0.value.access < $1.value.access })?.key,
                  let item = state.items.removeValue(forKey: key) else { return }
            // 仅清理本实例生成的缓存文件。删除失败在下次启动清空时再次处理。
            ExtractIO.remove([item.url])
            state.cost -= item.size
        }
    }
}

final class ExtractLease: Sendable {
    private let store: ExtractStore
    private let key: String
    let url: URL
    let size: Int64

    init(store: ExtractStore, key: String, url: URL, size: Int64) {
        self.store = store
        self.key = key
        self.url = url
        self.size = size
    }

    deinit { store.release(key) }
}
