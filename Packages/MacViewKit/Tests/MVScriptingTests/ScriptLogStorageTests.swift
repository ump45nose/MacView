import Foundation
import MVFoundation
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
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/MVScriptingTests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("script-storage.json")
    let storage = try ScriptStorage(fileURL: url)
    #expect(storage.get("script.a", "missing") == .null)
    try await storage.set("script.a", "key", .object(["value": .array([.number(2), .null])]))
    let second = try ScriptStorage(fileURL: url)
    #expect(second.get("script.a", "key") == .object(["value": .array([.number(2), .null])]))
    try await storage.set("script.b", "external", .bool(true))
    for _ in 0..<20 {
        if second.get("script.b", "external") == .bool(true) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(second.get("script.b", "external") == .bool(true))
    try "{broken".write(to: url, atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(300))
    #expect(second.get("script.a", "key") == .object(["value": .array([.number(2), .null])]))
    try await second.remove("script.a", "key")
    #expect(second.get("script.a", "key") == .null)
}
