import Foundation
import MVTestSupport
import Testing
@testable import MVArchive

@Suite("解出缓存启动轮换")
struct ExtractStoreStartupTests {
    @Test("构造只轮换目录，后台回收旧内容和崩溃遗留，预算从空开始")
    func startupRotation() async throws {
        let directory = Fixtures.root.deletingLastPathComponent().appending(path: "build/stage4-repair/extract-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let extract = directory.appending(path: "extract")
        let prefix = ".macview-extract-recycle-"
        func makeDirectory(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let old = extract.appending(path: "nested/old.partial")
        try makeDirectory(old.deletingLastPathComponent())
        try Data(repeating: 1, count: 30).write(to: old)
        let crashed = directory.appending(path: prefix + UUID().uuidString)
        try makeDirectory(crashed.appending(path: "nested"))
        try Data([2]).write(to: crashed.appending(path: "nested/leftover.extract"))

        let unrelated = directory.appending(path: "other-cache")
        let nestedRecycle = unrelated.appending(path: prefix + UUID().uuidString)
        let similar = directory.appending(path: prefix + "not-a-uuid")
        try makeDirectory(nestedRecycle)
        try makeDirectory(similar)
        let matchingFile = directory.appending(path: prefix + UUID().uuidString)
        try Data([3]).write(to: matchingFile)
        let matchingLink = directory.appending(path: prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: matchingLink, withDestinationURL: unrelated)

        // 阻止后台清理，构造必须仍立即返回，且旧内容只能被同级改名。
        let cleanupAllowed = DispatchSemaphore(value: 0)
        ExtractIO.queue.async { cleanupAllowed.wait() }
        let store: ExtractStore
        do {
            defer { cleanupAllowed.signal() }
            store = try ExtractStore(directory: extract, budget: 20)
            #expect(try FileManager.default.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: crashed.path))
            let siblings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let rotated = try #require(siblings.first {
                $0.lastPathComponent.hasPrefix(prefix)
                    && ![crashed, matchingFile, matchingLink, similar].map(\.lastPathComponent).contains($0.lastPathComponent)
            })
            #expect(try Data(contentsOf: rotated.appending(path: "nested/old.partial")) == Data(repeating: 1, count: 30))
        }
        await ExtractIO.drain()
        #expect(!FileManager.default.fileExists(atPath: crashed.path))
        let siblings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(Set(siblings.map(\.lastPathComponent)) == Set([extract, unrelated, similar, matchingFile, matchingLink].map(\.lastPathComponent)))
        #expect(FileManager.default.fileExists(atPath: nestedRecycle.path))
        #expect(try Data(contentsOf: matchingFile) == Data([3]))

        func install(_ key: String) async throws -> URL {
            let partial = store.temporaryURL()
            try Data(repeating: 7, count: 10).write(to: partial)
            let lease = try await store.install(partial, key: key, size: 10)
            return lease.url
        }
        let first = try await install("first")
        let second = try await install("second")
        await ExtractIO.drain()
        // 旧目录的 30 字节不能计入新实例的 20 字节预算。
        #expect(store.acquire("first") != nil)
        #expect(store.acquire("second") != nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(at: extract, includingPropertiesForKeys: nil)) == Set([first, second]))
    }
}
