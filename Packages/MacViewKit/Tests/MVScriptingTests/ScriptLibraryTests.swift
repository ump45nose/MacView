import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVScripting

private func testDirectory() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/MVScriptingTests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func write(_ source: String, _ name: String, in directory: URL) throws {
    try source.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

@Test func headerAndSyntax() async throws {
    let dir = try testDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("// @name 中文名\n// @description 描述\n// @event startup pageChanged\n// @event pageEnd\n// @unknown ignored\nlet n = 1;\n// @event windowStateChanged", "a.js", in: dir)
    try write("// @name CRLF\r\n// @event startup\r\n1;", ".hidden.js", in: dir)
    try write("// @event unknown\nlet n = 1;", "bad-event.js", in: dir)
    try write("let n = 1;", "stopAll.js", in: dir)
    try write("let n = 1;", "revealFolder.js", in: dir)
    try write("let n = 1;", "manage.js", in: dir)
    try write("// hello\nconst a = 1;\nconst b = ;\n", "bad-syntax.js", in: dir)
    let library = ScriptLibrary(directory: dir)
    try #require(await nextMatching(library.changes()) { _ in true })
    let scripts = library.scripts()
    let named = try #require(scripts.first { $0.id == "a" })
    #expect(named.name == "中文名")
    #expect(named.summary == "描述")
    #expect(named.events == [.startup, .pageChanged, .pageEnd])
    #expect(named.problem == nil)
    #expect(scripts.first { $0.name == "CRLF" }?.events == [.startup])
    #expect(scripts.first { $0.id == "bad-event" }?.problem?.line == 1)
    for name in ["stopAll", "revealFolder", "manage"] { #expect(scripts.first { $0.id == name }?.problem != nil) }
    #expect(scripts.first { $0.id == "bad-syntax" }?.problem?.line == 3)
    #expect(scripts.first { $0.id == "bad-syntax" }?.name == "bad-syntax")
}

@Test func examplesOnlyForNewDirectory() async throws {
    let root = try testDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    let existingLibrary = ScriptLibrary(directory: existing)
    try #require(await nextMatching(existingLibrary.changes()) { _ in true })
    #expect(existingLibrary.scripts().isEmpty)
    let new = root.appendingPathComponent("new")
    let library = ScriptLibrary(directory: new)
    try #require(await nextMatching(library.changes()) { _ in true })
    #expect(Set(library.scripts().map(\.id)) == ["jump-middle", "ask-next-book"])
    #expect(library.scripts().allSatisfy { $0.problem == nil })
    #expect(try library.source(of: "ask-next-book").contains("pageEnd"))
}

private func nextMatching(_ stream: AsyncStream<[ScriptInfo]>, _ predicate: @escaping @Sendable ([ScriptInfo]) -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { for await scripts in stream { if predicate(scripts) { return true } }; return false }
        group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

@Test func directoryChanges() async throws {
    let dir = try testDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = ScriptLibrary(directory: dir)
    let changes = library.changes()
    try write("// @name First\n1;", "first.js", in: dir)
    #expect(await nextMatching(changes) { $0.first?.name == "First" })
    try write("// @name Changed\n2;", "first.js", in: dir)
    #expect(await nextMatching(changes) { $0.first?.name == "Changed" })
    let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("first.js"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n3;".utf8))
    try handle.close()
    #expect(await nextMatching(changes) { $0.first?.name == "Changed" })
    #expect(try library.source(of: "first").contains("3;"))
    try FileManager.default.moveItem(at: dir.appendingPathComponent("first.js"), to: dir.appendingPathComponent("renamed.js"))
    #expect(await nextMatching(changes) { $0.count == 1 && $0[0].id == "renamed" })
    try FileManager.default.removeItem(at: dir.appendingPathComponent("renamed.js"))
    #expect(await nextMatching(changes) { $0.isEmpty })
}

@Test func libraryChangesKeepLatestSnapshot() async throws {
    let dir = try testDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = ScriptLibrary(directory: dir)
    let changes = library.changes()
    for name in ["First", "Second"] {
        try write("// @name \(name)\n1;", "test.js", in: dir)
        for _ in 0..<40 {
            if library.scripts().first?.name == name { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(library.scripts().first?.name == name)
    }
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next()?.first?.name == "Second")
}

private final class InitialScanHost: ScriptHost, Sendable {
    let called = Mutex(false)
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        called.withLock { $0 = true }
        return .null
    }
}

@Test func initialScanIsAsyncAndReplayedWithoutLosingChanges() async throws {
    let dir = try testDirectory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try write("// @event startup\nmv.toast('first');", "first.js", in: dir)
    let started = Mutex(false)
    let timedOut = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
        timedOut.withLock { $0 = true }
        release.signal()
    }
    let library = ScriptLibrary(directory: dir, beforeInitialScan: { started.withLock { $0 = true }; release.wait() })
    defer { release.signal() }
    for _ in 0..<100 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    try #require(started.withLock { $0 })
    #expect(!timedOut.withLock { $0 })
    #expect(library.scripts().isEmpty)
    #expect(!timedOut.withLock { $0 })
    let runtime = ScriptRuntime(library: library, log: ScriptLog())
    #expect(!runtime.hasSubscribers(for: .startup))
    let changes = library.changes()
    try write("// @event pageChanged\n1;", "second.js", in: dir)
    release.signal()
    try #require(await nextMatching(changes) { Set($0.map(\.id)) == ["first", "second"] })
    #expect(runtime.hasSubscribers(for: .startup))
    #expect(runtime.hasSubscribers(for: .pageChanged))
    let host = InitialScanHost()
    runtime.setHost(host)
    runtime.dispatch(.startup, payload: [:], session: nil)
    for _ in 0..<100 where !host.called.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(host.called.withLock { $0 })
    try #require(await nextMatching(library.changes()) { Set($0.map(\.id)) == ["first", "second"] })
    try write("// @event pageEnd\n1;", "second.js", in: dir)
    try #require(await nextMatching(changes) { $0.first(where: { $0.id == "second" })?.events == [.pageEnd] })
    #expect(!runtime.hasSubscribers(for: .pageChanged))
    #expect(runtime.hasSubscribers(for: .pageEnd))
}
