import Foundation
import MVFoundation
import MVMetadata
import Synchronization
import Testing
@testable import MVIO
@testable import MVFileOps

@Suite(.serialized)
struct OperationDeadlineTests {
    @Test(arguments: [false, true])
    func deleteStopsAfterOneDeadline(trashExists: Bool) async throws {
        let fixture = try await DeadlineFixture(trashExists: trashExists)
        defer { fixture.clean() }
        let started = ContinuousClock.now
        let result = await fixture.service.perform(.delete([fixture.location]))
        let elapsed = started.duration(to: .now)
        #expect(result.failures.first?.error as? IOError == .timeout)
        #expect(elapsed < .milliseconds(650), "一次操作不能累加等待：\(elapsed)")
        #expect(fixture.backend.blockedCalls == 1)
        fixture.backend.recover()
        let retry = await fixture.service.perform(try #require(result.retry))
        #expect(retry.failures.isEmpty)
        #expect(fixture.backend.prepareCalls == 1)
        let undo = await fixture.service.perform(try #require(retry.inverse))
        #expect(undo.failures.isEmpty)
    }

    @Test func ratingStopsAfterOneDeadline() async throws {
        let fixture = try await DeadlineFixture(trashExists: false, rating: true)
        defer { fixture.clean() }
        let started = ContinuousClock.now
        let result = await fixture.service.perform(.setMetadata([fixture.location], XMPFields(rating: 2)))
        let elapsed = started.duration(to: .now)
        #expect(result.failures.first?.error as? IOError == .timeout)
        #expect(elapsed < .milliseconds(650), "失败清理不能再次等待：\(elapsed)")
        #expect(fixture.backend.blockedCalls == 1)
        fixture.backend.recover()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.contains(".mvtmp-") })
        let retry = await fixture.service.perform(try #require(result.retry))
        #expect(retry.failures.isEmpty)
        #expect(fixture.backend.prepareCalls == 1)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.contains(".mvtmp-") })
    }
}

private final class DeadlineFixture {
    let directory: URL
    let scheduler: IOScheduler
    let backend: DeadlineBackend
    let location: Location
    let service: FileOperationService
    init(trashExists: Bool, rating: Bool = false) async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = workspace.appending(path: "build/deadline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "sample.jpg")
        try FileManager.default.copyItem(at: workspace.appending(path: "Fixtures/image/format/baseline.jpg"), to: file)
        if trashExists { try FileManager.default.createDirectory(at: directory.appending(path: ".macview-trash"), withIntermediateDirectories: false) }
        var config = IOConfiguration(helperExecutable: nil)
        config.setDeadlineForTesting(.milliseconds(400))
        config.degradeAfterTimeouts = 100
        let backend = DeadlineBackend(rating: rating, trashExists: trashExists)
        self.backend = backend
        scheduler = IOScheduler(configuration: config, backend: backend)
        let fs = FileSystemProvider(scheduler: scheduler)
        let registry = FileSourceRegistry(scheduler: scheduler)
        location = try await registry.location(for: file)
        let root = try await registry.location(for: directory)
        service = try FileOperationService(fileSystem: fs, journalURL: directory.appending(path: "journal.json"), prepareRetry: { _ in backend.notePrepare() }, isNetwork: { _ in true }, volumeRoot: { _ in root }, networkRoots: { [root] }, trash: { _ in throw IOError.unsupported(root) })
    }
    func clean() { backend.recover(); scheduler.shutdown(); try? FileManager.default.removeItem(at: directory) }
}

private final class DeadlineBackend: FileBackend {
    private let direct = DirectBackend()
    private struct State {
        var fault = true
        var blocked: [@Sendable () -> Void] = []
        var calls = 0
        var prepareCalls = 0
    }
    private let state = Mutex(State())
    let rating: Bool
    let trashExists: Bool
    init(rating: Bool, trashExists: Bool) { self.rating = rating; self.trashExists = trashExists }
    var blockedCalls: Int { state.withLock { $0.calls } }
    var prepareCalls: Int { state.withLock { $0.prepareCalls } }
    func notePrepare() { state.withLock { $0.prepareCalls += 1 } }
    func recover() {
        let callbacks = state.withLock { s in s.fault = false; let result = s.blocked; s.blocked = []; return result }
        callbacks.forEach { $0() }
    }
    func execute(_ request: HelperRequest, completion: @escaping @Sendable (Result<String?, FileOperationError>) -> Void) {
        let shouldBlock: Bool
        switch request {
        case let .makeDirectory(path): shouldBlock = !rating && (!trashExists || !path.hasSuffix(".macview-trash"))
        case .create, .remove: shouldBlock = rating
        default: shouldBlock = false
        }
        let block = state.withLock { s -> Bool in
            guard s.fault, shouldBlock else { return false }
            s.calls += 1
            s.blocked.append { completion(Result { () throws(FileOperationError) in try FileOperations.execute(request) }) }
            return true
        }
        if !block { direct.execute(request, completion: completion) }
    }
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) { direct.stat(path, completion: completion) }
    func lstat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        let slow = state.withLock { $0.fault }
        if slow { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(140)) { [direct] in direct.lstat(path, completion: completion) } }
        else { direct.lstat(path, completion: completion) }
    }
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {
        let slow = state.withLock { $0.fault }
        if slow { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(140)) { [direct] in direct.read(request, completion: completion) } }
        else { direct.read(request, completion: completion) }
    }
    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) { direct.list(path, batch: batch, completion: completion) }
    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) { direct.probe(mountPoint, completion: completion) }
    func abandon() { direct.abandon() }
}
