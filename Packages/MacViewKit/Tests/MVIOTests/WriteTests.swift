import Darwin
import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVIO

@Test func writeRequestsRoundTrip() throws {
    let requests: [HelperRequest] = [
        .create(path: "/a"), .write(path: "/a", offset: 42, data: Data([0, 1, 255])),
        .finish(path: "/a", modificationNanos: nil), .finish(path: "/a", modificationNanos: 123),
        .rename(source: "/a", target: "/b", exclusive: true), .rename(source: "/a", target: "/b", exclusive: false),
        .makeDirectory(path: "/d"), .remove(path: "/a"), .trash(path: "/a"), .lstat(path: "/link"),
        .read(ReadRequest(path: "/a", offset: 0, length: 3, expectedSize: nil, expectedModificationNanos: nil, noCache: true, retryByReopening: false, freshDescriptor: true))
    ]
    for request in requests {
        let (id, decoded) = try HelperCodec.decodeRequest(HelperCodec.encode(id: 17, request).dropFirst(4))
        #expect(id == 17 && decoded == request)
    }
    let response = HelperResponse.path("/trash/a")
    let (_, decoded) = try HelperCodec.decodeResponse(HelperCodec.encode(id: 17, response).dropFirst(4))
    #expect(decoded == response)
}

@Test(arguments: [false, true]) func writePrimitivesThroughBothBackends(helper: Bool) async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appending(path: ".mvio-write-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helperURL = Bundle(for: WriteBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvio-helper")
    let backend: any FileBackend = helper ? HelperBackend(executable: helperURL) : DirectBackend()
    defer { backend.abandon() }
    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil), backend: backend)
    let registry = FileSourceRegistry(scheduler: scheduler)
    let fs = registry.fileSystem
    let folder = try await registry.location(for: directory)
    let a = folder.appending("a"), b = folder.appending("b"), sub = folder.appending("sub")
    try await fs.createFile(at: a)
    await #expect(throws: IOError.alreadyExists(a)) { try await fs.createFile(at: a) }
    try await fs.write(Data([1, 2, 3]), at: 2, to: a, priority: .near)
    let stamp: Int64 = 1_700_000_000_123_456_789
    try await fs.finishFile(at: a, modificationNanos: stamp)
    #expect(try Data(contentsOf: directory.appending(path: "a")) == Data([0, 0, 1, 2, 3]))
    #expect(try FileOperations.stat(directory.appending(path: "a").path).modificationNanos == stamp)
    // 先缓存普通描述符，再以同大小、同修改时间的新文件替换路径；一次性读必须看到新文件。
    let cached = try await fs.open(a)
    #expect(try await cached.read(0..<5, priority: .visible, group: nil) == Data([0, 0, 1, 2, 3]))
    let replacement = directory.appending(path: "replacement")
    try Data([9, 8, 7, 6, 5]).write(to: replacement)
    let replacementFD = Darwin.open(replacement.path, O_WRONLY)
    try #require(replacementFD >= 0)
    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
    try #require(futimens(replacementFD, &times) == 0)
    close(replacementFD)
    try FileManager.default.removeItem(at: directory.appending(path: "a"))
    try FileManager.default.moveItem(at: replacement, to: directory.appending(path: "a"))
    #expect(try await fs.readUncached(a, range: 0..<5, priority: .visible) == Data([9, 8, 7, 6, 5]))
    #expect(try await fs.itemWithoutFollowingLinks(at: a).type == .regular)
    let linkURL = directory.appending(path: "dangling")
    try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "missing")
    let link = folder.appending("dangling")
    #expect(try await fs.itemWithoutFollowingLinks(at: link).type == .symbolicLink)
    try await fs.remove(link)
    try await fs.createFile(at: b)
    await #expect(throws: IOError.alreadyExists(b)) { try await fs.rename(a, to: b, exclusive: true) }
    try await fs.rename(a, to: b, exclusive: false)
    try await fs.makeDirectory(at: sub)
    let child = sub.appending("child")
    try await fs.createFile(at: child)
    await #expect(throws: (any Error).self) { try await fs.remove(sub) }
    try await fs.remove(child)
    try await fs.remove(sub)
    try await fs.remove(b)
    #expect(try !fs.isNetworkVolume(folder))
    #expect(try fs.volumeRoot(of: folder).root == .local)
    #expect(fs.mountedNetworkRoots().allSatisfy { if case .network = $0.root { true } else { false } })
    await #expect(throws: IOError.notFound(a)) { _ = try await fs.moveToTrash(a) }
}

@Test func crossVolumeAndDegradedWritesFail() async throws {
    let backend = WriteFailureBackend()
    var config = IOConfiguration(helperExecutable: nil)
    config.setDeadlineForTesting(.milliseconds(30))
    config.degradeAfterTimeouts = 1
    let scheduler = IOScheduler(configuration: config, backend: backend)
    let fs = FileSystemProvider(scheduler: scheduler)
    let folder = Location(root: .local, layers: [["tmp"]])
    let a = folder.appending("a"), b = folder.appending("b")
    await #expect(throws: IOError.crossVolume) { try await fs.rename(a, to: b, exclusive: true) }
    backend.hang.store(true, ordering: .relaxed)
    await #expect(throws: IOError.timeout) { try await fs.createFile(at: a) }
    let count = backend.calls.load(ordering: .relaxed)
    await #expect(throws: IOError.volumeDegraded(.local)) { try await fs.write(Data([1]), at: 0, to: a, priority: .visible) }
    #expect(backend.calls.load(ordering: .relaxed) == count)
    #expect(scheduler.queuedCount == 0)
}

@Test func renameRejectsADegradedTargetBeforeAndAfterQueueing() async throws {
    let backend = WriteFailureBackend()
    var config = IOConfiguration(helperExecutable: nil)
    config.local.metadata = 1
    config.setDeadlineForTesting(.milliseconds(400))
    config.degradeAfterTimeouts = 1
    let scheduler = IOScheduler(configuration: config, backend: backend)
    let fs = FileSystemProvider(scheduler: scheduler)
    let source = Location(root: .local, layers: [["tmp", "mvio-source"]])
    let target = Location(root: .local, layers: [["dev", "mvio-target"]])
    let sourceVolume = try scheduler.volume(for: source)
    let targetVolume = try scheduler.volume(for: target)
    try #require(sourceVolume.mountPoint != targetVolume.mountPoint)

    let targetJob = Task {
        let _: Void = try await scheduler.perform(on: targetVolume, .metadata, priority: .visible, group: nil) { _, _ in }
    }
    try await Task.sleep(for: .milliseconds(200))
    let sourceJob = Task {
        let _: Void = try await scheduler.perform(on: sourceVolume, .metadata, priority: .visible, group: nil) { _, _ in }
    }
    while scheduler.currentVolumeHealth().count < 2 { await Task.yield() }
    let queued = Task { try await fs.rename(source, to: target, exclusive: true) }
    let deadline = ContinuousClock.now + .milliseconds(150)
    while scheduler.queuedCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
    #expect(scheduler.queuedCount == 1)
    await #expect(throws: IOError.timeout) { try await targetJob.value }
    await #expect(throws: IOError.volumeDegraded(targetVolume.root)) { try await queued.value }
    #expect(scheduler.queuedCount == 0)
    await #expect(throws: IOError.volumeDegraded(targetVolume.root)) { try await fs.rename(source, to: target, exclusive: true) }
    #expect(backend.calls.load(ordering: .relaxed) == 0)
    await #expect(throws: IOError.timeout) { try await sourceJob.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MVIO_CROSS_MOUNT_TEST"] == "1"))
func exclusiveRenameAcrossMountedNetworkVolumes() async throws {
    let base = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "MacViewBench")
    let name = ".mvio-cross-volume-\(UUID().uuidString)"
    let sourceURL = base.appending(path: "fileops-a").appending(path: name)
    let targetURL = base.appending(path: "fileops-b").appending(path: name)
    var created = false
    defer {
        if created {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
    }
    let helperURL = Bundle(for: WriteBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvio-helper")
    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: helperURL))
    defer { scheduler.shutdown() }
    let registry = FileSourceRegistry(scheduler: scheduler)
    let source = try await registry.location(for: sourceURL)
    let target = try await registry.location(for: targetURL)
    try #require(try registry.fileSystem.isNetworkVolume(source))
    try #require(try registry.fileSystem.isNetworkVolume(target))
    try #require(source.root != target.root)
    try #require(!FileManager.default.fileExists(atPath: targetURL.path))
    try await registry.fileSystem.createFile(at: source)
    created = true
    await #expect(throws: IOError.crossVolume) { try await registry.fileSystem.rename(source, to: target, exclusive: true) }
    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    try await registry.fileSystem.remove(source)
    #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    created = false
}

private final class WriteBundleMarker {}
private final class WriteFailureBackend: FileBackend {
    let hang = Atomic(false)
    let calls = Atomic(0)
    func execute(_ request: HelperRequest, completion: @escaping @Sendable (Result<String?, FileOperationError>) -> Void) {
        calls.add(1, ordering: .relaxed)
        if !hang.load(ordering: .relaxed) { completion(.failure(.system(call: "rename", code: EXDEV))) }
    }
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {}
    func probe(_ path: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {}
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {}
    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {}
    func abandon() {}
}
