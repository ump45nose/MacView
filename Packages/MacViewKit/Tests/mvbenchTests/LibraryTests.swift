import Foundation
import MVFoundation
import MVLibraryData
import MVTestSupport
import Testing
@testable import mvbench

struct LibraryCommandTests {
    @Test("C1.17 seed-playlist 枚举目录及压缩包，数量不足不留下空列表")
    func seedsDirectoryAndArchive() async throws {
        let root = Fixtures.root.deletingLastPathComponent().appending(path: "build/stage-1-work/seed-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let image = Fixtures.url("image/format/baseline.jpg")
        try FileManager.default.copyItem(at: image, to: source.appending(path: "plain.jpg"))
        try FileManager.default.copyItem(at: Fixtures.url("archive/tar/book.tar.gz"), to: source.appending(path: "book.tar.gz"))
        let support = root.appending(path: "support")
        let result = try await LibrarySeedPlaylist.seed(support: support, name: "夹具", count: 4, from: source)
        let store = try SQLiteLibraryStore(databaseURL: support.appending(path: "library.sqlite"), historyLimit: 1000)
        let entries = try await store.items(of: result.id)
        #expect(result.count == 4 && entries.count == 4)
        #expect(entries.contains { $0.location.layers.count > 1 })
        #expect(entries.contains { $0.location.layers.count == 1 })
        await #expect(throws: (any Error).self) {
            _ = try await LibrarySeedPlaylist.seed(support: support, name: "不够", count: 100, from: source)
        }
        #expect(try await store.playlists().count == 1)
    }

    @Test("C1.17 / C1.6 使用实际命令生成的 3000 项做读取、移动测量",
          .enabled(if: ProcessInfo.processInfo.environment["MV_LIBRARY_SEED_SUPPORT"] != nil))
    func measuresSeededPlaylist() async throws {
        let support = try #require(ProcessInfo.processInfo.environment["MV_LIBRARY_SEED_SUPPORT"])
        let store = try SQLiteLibraryStore(databaseURL: URL(fileURLWithPath: support).appending(path: "library.sqlite"), historyLimit: 1000)
        let summary = try #require(try await store.playlists().first { $0.count == 3000 })
        let start = ContinuousClock.now
        let entries = try await store.items(of: summary.id)
        let read = start.duration(to: .now)
        let moving = Array(entries.prefix(100))
        let moveStart = ContinuousClock.now
        try await store.moveItems(moving.map(\.location), in: summary.id, to: 2900)
        let move = moveStart.duration(to: .now)
        #expect(try await store.items(of: summary.id) == Array(entries.dropFirst(100)) + moving)
        print("C1.17/C1.6 CLI 3000项读取=\(read), 移动100项=\(move)")
        #if !DEBUG
        #expect(read < .milliseconds(50))
        #expect(move < .milliseconds(50))
        #endif
    }
}
