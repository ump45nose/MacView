import Foundation
import MVFoundation
import MVSettings
import Testing
@testable import MVScripting

@Test func logCapacityAndClear() {
    let log = ScriptLog(capacity: 2)
    log.append(source: "a", level: .info, text: "one")
    log.append(source: "a", level: .warning, text: "two")
    log.append(source: "b", level: .error, text: "three")
    #expect(log.entries().map(\.text) == ["two", "three"])
    #expect(Set(log.entries().map(\.id)).count == 2)
    log.clear()
    #expect(log.entries().isEmpty)
}

@Test func storagePersistenceAndBadExternalFile() async throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/MVScriptingTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("script-storage.json")
    let storage = try ScriptStorage(fileURL: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(storage.get("script.a", "missing") == .null)
    try await storage.set("script.a", "key", .object(["value": .array([.number(2), .null])]))
    #expect(FileManager.default.fileExists(atPath: url.path))
    let second = try ScriptStorage(fileURL: url)
    #expect(second.get("script.a", "key") == .object(["value": .array([.number(2), .null])]))
    let events = StorageChangeRecorder()
    let changes = second.changes()
    let observer = Task {
        for await change in changes { await events.append(change) }
    }
    defer { observer.cancel() }
    try await storage.set("script.b", "external", .bool(true))
    for _ in 0..<20 {
        if await events.containsReloaded(), second.get("script.b", "external") == .bool(true) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await events.containsReloaded())
    #expect(second.get("script.b", "external") == .bool(true))
    try "{broken".write(to: url, atomically: true, encoding: .utf8)
    for _ in 0..<20 {
        if await events.containsFileError() { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await events.containsFileError())
    #expect(second.get("script.a", "key") == .object(["value": .array([.number(2), .null])]))
    #expect(second.get("script.b", "external") == .bool(true))
    try await second.remove("script.a", "key")
    #expect(second.get("script.a", "key") == .null)
}

@Test func logChangesKeepLatestSnapshot() async {
    let log = ScriptLog(capacity: 3)
    let changes = log.changes()
    for value in 1...5 { log.append(source: "test", level: .info, text: "\(value)") }
    var iterator = changes.makeAsyncIterator()
    let latest = await iterator.next()
    #expect(latest?.map(\.text) == ["3", "4", "5"])
}

private actor StorageChangeRecorder {
    private var changes: [DocumentChange] = []

    func append(_ change: DocumentChange) { changes.append(change) }
    func containsReloaded() -> Bool { changes.contains(.reloaded) }
    func containsFileError() -> Bool {
        changes.contains { if case .fileError = $0 { true } else { false } }
    }
}
