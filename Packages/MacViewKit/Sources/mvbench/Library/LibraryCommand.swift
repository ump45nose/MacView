import ArgumentParser
import Foundation
import MVArchive
import MVFoundation
import MVIO
import MVLibraryData

struct LibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "library", abstract: "准备资料库验收夹具。", subcommands: [LibrarySeedPlaylist.self])
}

struct LibrarySeedPlaylist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seed-playlist", abstract: "从目录及压缩包收集媒体，写入指定项数的播放列表。")
    @Option(help: "MacView 支持目录。") var support: String
    @Option(help: "播放列表名称。") var name: String
    @Option(help: "不重复的媒体项数量。") var count: Int
    @Option(help: "夹具目录（递归枚举压缩包）。") var from: String

    func run() async throws {
        let result = try await Self.seed(support: URL(fileURLWithPath: support), name: name, count: count, from: URL(fileURLWithPath: from))
        try JSONReport.write(result, to: nil)
    }

    struct Result: Encodable { let id: UUID; let name: String; let count: Int }

    static func seed(support: URL, name: String, count: Int, from source: URL) async throws -> Result {
        guard count > 0 else { throw ValidationError("count 必须为正数") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("name 不能为空") }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // 本命令自己的解包租约目录；不触碰 App 的缓存，也不会清空用户指定的夹具目录。
        let extract = support.appending(path: ".seed-extract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: extract) }
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let sources = FileSourceRegistry(scheduler: scheduler)
        sources.register(try ArchiveProvider(fileSystem: sources.fileSystem, extractDirectory: extract))
        let root = try await sources.location(for: source)
        var queue = [root], cursor = 0, entries: [Entry] = [], visited: Set<Location> = []
        while cursor < queue.count, entries.count < count {
            let container = queue[cursor]
            cursor += 1
            guard visited.insert(container).inserted else { continue }
            var children: [Entry] = []
            let provider = try sources.provider(for: container)
            for try await batch in provider.children(of: container, priority: .background) { children += batch }
            for entry in children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                if entry.name.hasPrefix(".") { continue }
                switch entry.kind {
                case .directory, .archive: queue.append(entry.location)
                case .image, .video:
                    entries.append(entry)
                    if entries.count == count { break }
                case .other: break
                }
            }
        }
        guard entries.count == count else { throw ValidationError("夹具只有 \(entries.count) 项，需要 \(count) 项；未创建播放列表") }
        let store = try SQLiteLibraryStore(databaseURL: support.appending(path: "library.sqlite"), historyLimit: 1000)
        let id = try await store.createPlaylist(named: name)
        do {
            _ = try await store.addItems(entries, to: id)
            try await store.flush()
        } catch {
            try? await store.deletePlaylist(id)
            throw error
        }
        return Result(id: id, name: name, count: entries.count)
    }
}
