import Foundation
import MVCommands
import MVFoundation
import MVScripting
import Synchronization
import Testing
@testable import MVServices

private final class ScriptServiceHost: ScriptHost, Sendable {
    let called = Mutex(false)
    func call(_ method: ScriptAPI.Method, _ args: [JSONValue], context: ScriptCallContext) async throws -> JSONValue {
        called.withLock { $0 = true }
        return .null
    }
}

@Test @MainActor func scriptServicesMakeAndShutdown() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ScriptServicesTests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("support"), cache = root.appendingPathComponent("cache")
    let configuration = CoreConfiguration(supportDirectory: support, cacheDirectory: cache, browseBounds: PixelSize(width: 320, height: 320))
    let services = try await CoreServices.make(configuration: configuration)
    let library = try #require(services.scriptLibrary)
    let runtime = try #require(services.scriptRuntime)
    #expect(services.scriptLog != nil && services.scriptStorage != nil && services.externalCommands != nil)
    #expect(Set(library.scripts().map(\.id)) == ["jump-middle", "ask-next-book"])
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("external-commands.json").path))
    try "mv.toast('running'); while(true) {}".write(to: library.directory.appendingPathComponent("shutdown.js"), atomically: true, encoding: .utf8)
    for _ in 0..<100 where !library.scripts().contains(where: { $0.id == "shutdown" }) { try await Task.sleep(for: .milliseconds(20)) }
    let host = ScriptServiceHost(); runtime.setHost(host)
    runtime.run("shutdown", arguments: nil, context: ScriptCallContext(caller: "script.shutdown", callerName: "shutdown", session: nil, selection: []))
    for _ in 0..<100 where !host.called.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(host.called.withLock { $0 })
    await services.shutdown()
    for _ in 0..<100 where !runtime.runStates().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(runtime.runStates().isEmpty)
    let mock = CoreServices(sources: services.sources, pipeline: services.pipeline, settings: services.settings, commands: services.commands, bookshelf: services.bookshelf, loader: services.loader)
    #expect(mock.scriptLibrary == nil && mock.scriptRuntime == nil && mock.externalCommands == nil && mock.scriptStorage == nil && mock.scriptLog == nil)
    await mock.shutdown()
}
