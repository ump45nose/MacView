import CryptoKit
import Foundation
import MVFoundation
import MVTestSupport
import Synchronization
import Testing
@testable import MVArchive
@testable import MVIO

@Suite("压缩包真实夹具")
struct ArchiveFixtureTests {
    @Test("清单中的全部归档、子目录及嵌套内容")
    func manifestContents() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        let fixtures = try Fixtures.manifest().fixtures.filter { $0.archive != nil }
        #expect(fixtures.count == 16)
        for fixture in fixtures {
            let location = try await environment.registry.location(for: Fixtures.url(fixture.path))
            try await check(fixture.archive!, in: location, provider: environment.provider)
        }
    }

    @Test("stored 内包保持范围映射，deflate 内包才解出")
    func nestedArchives() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        let archive = try await environment.registry.location(for: Fixtures.url("archive/zip/nested.zip"))
        let facts = try #require(Fixtures.manifest()["archive/zip/nested.zip"]?.archive)
        for name in ["inner-stored.zip", "inner-deflate.zip"] {
            let inner = archive.appendingLayer([name])
            let expected = try #require(facts.entries.first { $0.path == name }?.archive)
            try await check(expected, in: inner, provider: environment.provider)
            let files = try await environment.extractFiles()
            #expect(files.count == (name == "inner-stored.zip" ? 0 : 1))
        }
    }

    @Test("registry 认领归档容器，entry/open/fileURL 仍指向归档文件")
    func registryDispatch() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        let url = Fixtures.url("archive/zip/stored.zip")
        let location = try await environment.registry.location(for: url)
        let provider = try environment.registry.provider(for: location)
        #expect(provider is ArchiveProvider)
        let listed = try await entries(provider, in: location)
        #expect(Set(listed.map(\.name)) == ["001.jpg", "002.jpg", "sub"])
        #expect(try await provider.entry(at: location).identity == environment.registry.fileSystem.entry(at: location).identity)
        let source = try await provider.open(location)
        #expect(try await source.read(0..<source.identity.size, priority: .visible, group: nil) == Data(contentsOf: url))
        #expect(try await provider.fileLease(for: location).url == url)
        let item = location.appendingLayer(["sub", "003.jpg"])
        #expect(item.parent == location.appendingLayer(["sub"]))
        #expect(try await provider.entry(at: item).name == "003.jpg")
        let extracted = try await provider.fileLease(for: item)
        let data = try Data(contentsOf: extracted.url)
        #expect(Int64(data.count) == (try await provider.entry(at: item)).identity.size)
    }

    @Test("stored 的端到端来源读取量不超过条目加 64 KB")
    func storedReadBudget() async throws {
        let backend = RecordingBackend()
        let environment = try ArchiveEnvironment(backend: backend)
        defer { environment.clean() }
        let location = try await environment.registry.location(for: Fixtures.url("archive/zip/stored.zip"))
        let source = try await environment.provider.open(location.appendingLayer(["001.jpg"]))
        let group = IORequestGroup()
        let data = try await source.read(0..<source.identity.size, priority: .background, group: group)
        #expect(data.count == 27_389)
        #expect(backend.bytesRead <= source.identity.size + (64 << 10))
        #expect(backend.bytesRead < 40_000)
        environment.registry.scheduler.cancel(group)
        await #expect(throws: IOError.self) {
            _ = try await source.read(0..<1, priority: .visible, group: group)
        }
    }

    @Test("deflate 随机区间、EOF 及完整 CRC")
    func deflateRanges() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        let location = try await environment.registry.location(for: Fixtures.url("archive/zip/deflate.zip"))
        let source = try await environment.provider.open(location.appendingLayer(["chapter", "001.jpg"]))
        let full = try await source.read(0..<source.identity.size, priority: .visible, group: nil)
        #expect(try await source.read(777..<4000, priority: .near, group: nil) == full[777..<4000])
        #expect(try await source.read(source.identity.size - 11..<source.identity.size + 100, priority: .near, group: nil) == full.suffix(11))
        #expect(try await source.read(source.identity.size..<source.identity.size + 1, priority: .near, group: nil).isEmpty)
    }

    @Test("gzip 单文件大小来自解压结果")
    func gzipSingleFile() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        let location = try await environment.registry.location(for: Fixtures.url("archive/gzip/image.jpg.gz"))
        let list = try await entries(environment.provider, in: location)
        let entry = try #require(list.first)
        #expect(entry.name == "image.jpg")
        #expect(entry.size == 27_635)
        #expect(entry.size != (try await environment.provider.entry(at: location)).identity.size)
        let source = try await environment.provider.open(entry.location)
        #expect(try await source.read(0..<entry.size, priority: .visible, group: nil).count == 27_635)
    }

    @Test("读中取消 gzip 时移除部分文件")
    func cancelledGzip() async throws {
        let backend = RecordingBackend()
        let environment = try ArchiveEnvironment(backend: backend)
        defer { environment.clean() }
        let location = try await environment.registry.location(for: Fixtures.url("archive/gzip/image.jpg.gz"))
        let original = try await environment.registry.fileSystem.open(location)
        backend.pauseOffset = try await GzipHeader.read(original, priority: .visible).payloadOffset
        let task = Task { try await environment.provider.open(location.appendingLayer(["image.jpg"])) }
        for await _ in backend.paused { break }
        defer { backend.resume() }
        #expect(try await environment.extractFiles().contains { $0.pathExtension == "partial" })
        task.cancel()
        // 执行中的 I/O 完成本块后，解压器才能在块边界观察取消。
        backend.resume()
        do {
            _ = try await task.value
            Issue.record("取消后仍成功解压")
        } catch let error as IOError {
            guard case .cancelled = error else { throw error }
        }
        #expect(try await environment.extractFiles().isEmpty)
    }

    @Test("持有 fileLease 期间，再次交付和超出预算都不淘汰该文件")
    func fileLeaseKeepsFile() async throws {
        let directory = try ArchiveDirectory()
        defer { directory.clean() }
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil))
        defer { scheduler.shutdown() }
        let registry = FileSourceRegistry(scheduler: scheduler)
        let provider = try ArchiveProvider(fileSystem: registry.fileSystem, extractDirectory: directory.url.appending(path: "extract"), extractBudget: 1)
        registry.register(provider)
        let archive = try await registry.location(for: Fixtures.url("archive/zip/deflate.zip"))
        var first: FileLease? = try await provider.fileLease(for: archive.appendingLayer(["chapter", "001.jpg"]))
        let url = try #require(first?.url)
        let second = try await provider.fileLease(for: archive.appendingLayer(["chapter", "002.jpg"]))
        await ExtractIO.drain()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        first = nil
        await ExtractIO.drain()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
    }

    @Test("解出缓存按 LRU 淘汰，租约中的文件不删除")
    func extractLRU() async throws {
        let directory = try ArchiveDirectory()
        defer { directory.clean() }
        let extract = directory.url.appending(path: "extract")
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        let stale = extract.appending(path: "old.partial")
        try Data([1]).write(to: stale)
        let store = try ExtractStore(directory: extract, budget: 20)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        func put(_ key: String) async throws -> ExtractLease {
            let file = store.temporaryURL()
            try Data(repeating: 7, count: 10).write(to: file)
            return try await store.install(file, key: key, size: 10)
        }
        var a: ExtractLease? = try await put("a")
        var b: ExtractLease? = try await put("b")
        let aURL = try #require(a?.url)
        let bURL = try #require(b?.url)
        a = nil
        b = nil
        a = store.acquire("a") // a 比 b 新。
        a = nil
        var c: ExtractLease? = try await put("c")
        #expect(!FileManager.default.fileExists(atPath: bURL.path))
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        b = store.acquire("a") // 固定 a。
        let cURL = try #require(c?.url)
        var d: ExtractLease? = try await put("d") // a、c、d 都固定，可暂时超过预算。
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(FileManager.default.fileExists(atPath: cURL.path))
        c = nil // 释放后在专用 I/O 队列恢复预算。
        await ExtractIO.drain()
        #expect(!FileManager.default.fileExists(atPath: cURL.path))
        #expect(FileManager.default.fileExists(atPath: aURL.path))
        #expect(d?.size == 10)
        b = nil
        d = nil
    }

    @Test("gzip CRC 损坏不留解出文件")
    func corruptGzip() async throws {
        let environment = try ArchiveEnvironment()
        defer { environment.clean() }
        var data = try Data(contentsOf: Fixtures.url("archive/gzip/image.jpg.gz"))
        data[data.count - 8] ^= 1
        let file = environment.directory.url.appending(path: "broken.gz")
        try data.write(to: file)
        let location = try await environment.registry.location(for: file)
        await #expect(throws: IOError.self) { _ = try await entries(environment.provider, in: location) }
        #expect(try await environment.extractFiles().isEmpty)
    }

    private func check(_ facts: ArchiveFacts, in archive: Location, provider: ArchiveProvider) async throws {
        var actual: [String: Entry] = [:]
        func walk(_ container: Location, prefix: String) async throws {
            for entry in try await entries(provider, in: container) {
                let path = prefix + entry.name + (entry.kind == .directory ? "/" : "")
                actual[path] = entry
                if entry.kind == .directory { try await walk(entry.location, prefix: path) }
            }
        }
        try await walk(archive, prefix: "")
        var expectedPaths = Set(facts.entries.map(\.path))
        // 清单只列物理记录；provider 还需补齐缺失的祖先目录。
        for entry in facts.entries {
            let path = entry.path.split(separator: "/")
            for count in 1..<path.count { expectedPaths.insert(path.prefix(count).joined(separator: "/") + "/") }
        }
        #expect(Set(actual.keys) == expectedPaths)
        for fact in facts.entries {
            let entry = try #require(actual[fact.path])
            #expect(entry.size == fact.size)
            #expect(entry.name == fact.path.split(separator: "/").last.map(String.init))
            #expect(try await provider.entry(at: entry.location).identity == entry.identity)
            if fact.isDirectory { #expect(entry.kind == .directory); continue }
            let source = try await provider.open(entry.location)
            #expect(source.identity == entry.identity)
            let data = try await source.read(0..<entry.size, priority: .visible, group: nil)
            #expect(data.count == fact.size)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fact.sha256)
            if facts.format == .zip { #expect(entry.identity.checksum != nil) }
            if let inner = fact.archive { try await check(inner, in: entry.location, provider: provider) }
        }
    }
}

private func entries(_ provider: any ContainerProvider, in container: Location) async throws -> [Entry] {
    var result: [Entry] = []
    for try await batch in provider.children(of: container, priority: .visible) { result.append(contentsOf: batch) }
    return result
}

private struct ArchiveDirectory {
    let url: URL
    init() throws {
        url = Fixtures.root.deletingLastPathComponent().appending(path: "build/stage-1-work/archive-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: url) }
}

private struct ArchiveEnvironment {
    let directory: ArchiveDirectory
    let registry: FileSourceRegistry
    let provider: ArchiveProvider
    init(backend: (any FileBackend)? = nil) throws {
        directory = try ArchiveDirectory()
        let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil), backend: backend)
        registry = FileSourceRegistry(scheduler: scheduler)
        provider = try ArchiveProvider(fileSystem: registry.fileSystem, extractDirectory: directory.url.appending(path: "extract"))
        registry.register(provider)
    }
    func extractFiles() async throws -> [URL] {
        await ExtractIO.drain()
        return try FileManager.default.contentsOfDirectory(at: directory.url.appending(path: "extract"), includingPropertiesForKeys: nil)
    }
    func clean() { registry.scheduler.shutdown(); directory.clean() }
}

/// 装饰真实文件后端，只统计来源字节数，并能暂停指定的 payload 读取以确定性地取消。
private final class RecordingBackend: FileBackend {
    private let direct = DirectBackend()
    private struct State {
        var bytes: Int64 = 0
        var pauseOffset: Int64?
        var pending: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    private let signal = AsyncStream<Void>.makeStream()
    var paused: AsyncStream<Void> { signal.stream }
    var bytesRead: Int64 { state.withLock { $0.bytes } }
    var pauseOffset: Int64? {
        get { state.withLock { $0.pauseOffset } }
        set { state.withLock { $0.pauseOffset = newValue } }
    }
    func resume() { state.withLock { $0.pending.take() }?() }
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        direct.stat(path, completion: completion)
    }
    func probe(_ path: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        direct.probe(path, completion: completion)
    }
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {
        direct.read(request) { [self] result in
            let pause = state.withLock { state in
                if case let .success(data) = result { state.bytes += Int64(data.count) }
                guard request.offset == state.pauseOffset else { return false }
                state.pauseOffset = nil
                state.pending = { completion(result) }
                return true
            }
            if pause { signal.continuation.yield(()) } else { completion(result) }
        }
    }
    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool,
              completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        direct.list(path, batch: batch, completion: completion)
    }
    func abandon() { resume() }
}
