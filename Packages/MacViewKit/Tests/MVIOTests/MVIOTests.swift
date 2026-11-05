import AVFoundation
import Darwin
import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVIO

@Test func visibleIsTheHighestPriority() {
    let priorities: [IOPriority] = [.background, .visible, .book, .adjacent, .near]
    #expect(priorities.sorted(by: >) == [.visible, .near, .book, .adjacent, .background])
}

// MARK: 挂载与位置

@Test func networkRootsComeFromTheMountSource() {
    #expect(VolumeTable.root(fileSystem: "smbfs", source: "//yuwk@192.168.31.201/Picture") == .network(scheme: "smb", host: "192.168.31.201", share: "Picture"))
    #expect(VolumeTable.root(fileSystem: "smbfs", source: "//WORK;me@NAS.local/My%20Share") == .network(scheme: "smb", host: "nas.local", share: "My Share"))
    #expect(VolumeTable.root(fileSystem: "nfs", source: "192.168.31.201:/fs/1000/nfs") == .network(scheme: "nfs", host: "192.168.31.201", share: "fs/1000/nfs"))
    #expect(VolumeTable.root(fileSystem: "apfs", source: "/dev/disk3s1") == nil)
    let root = Location.Root.network(scheme: "nfs", host: "192.168.31.201", share: "fs/1000/nfs")
    #expect(root.mountURL?.absoluteString == "nfs://192.168.31.201/fs/1000/nfs")
    #expect(Location.Root.local.mountURL == nil)
}

@Test func volumePathsRoundTrip() {
    let network = Volume(mountPoint: "/Volumes/Picture", fileSystem: "smbfs", root: .network(scheme: "smb", host: "h", share: "Picture"), isLocal: false)
    #expect(network.components(ofPath: "/Volumes/Picture/YY/a.jpg") == ["YY", "a.jpg"])
    #expect(network.path(of: ["YY", "a.jpg"]) == "/Volumes/Picture/YY/a.jpg")
    #expect(network.path(of: []) == "/Volumes/Picture")
    let local = Volume(mountPoint: "/", fileSystem: "apfs", root: .local, isLocal: true)
    #expect(local.components(ofPath: "/Users/me/a.jpg") == ["Users", "me", "a.jpg"])
    #expect(local.path(of: ["Users", "me"]) == "/Users/me")
    #expect(local.path(of: []) == "/")
}

@Test func localFileURLsBecomeLocalLocations() async throws {
    let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
    let location = try await registry.location(for: URL(fileURLWithPath: "/Users/me/../me/书/001.jpg"))
    #expect(location == Location(root: .local, layers: [["Users", "me", "书", "001.jpg"]]))
    #expect(try await registry.fileSystem.fileLease(for: location).url.path == "/Users/me/书/001.jpg")
}

@Test func entryKindsFollowTheExtension() {
    #expect(EntryKind(fileName: "a.JPG") == .image)
    #expect(EntryKind(fileName: "b.tar.gz") == .archive(.tarGzip))
    #expect(EntryKind(fileName: "c.gz") == .archive(.gzip))
    #expect(EntryKind(fileName: "d.cbz") == .archive(.zip))
    #expect(EntryKind(fileName: "e.mov") == .video)
    #expect(EntryKind(fileName: ".DS_Store") == .other)
    #expect(EntryKind(fileName: "README") == .other)
}

// MARK: 辅助进程协议

@Test func helperMessagesRoundTrip() throws {
    let attributes = FileAttributes(name: "页 1.jpg", type: .regular, size: 12_345, modificationNanos: 1_700_000_000_123_456_789, creationNanos: nil)
    let requests: [HelperRequest] = [
        .stat(path: "/Volumes/Picture/页.jpg"),
        .read(ReadRequest(path: "/a", offset: 4 << 20, length: 1 << 20, expectedSize: 9, expectedModificationNanos: nil, noCache: true, retryByReopening: false)),
        .list(path: "/b"),
        .probe(mountPoint: "/Volumes/Picture"),
        .cancel(id: 7),
    ]
    for request in requests {
        let frame = HelperCodec.encode(id: 42, request)
        let (id, decoded) = try HelperCodec.decodeRequest(frame.dropFirst(4))
        #expect(id == 42)
        #expect(decoded == request)
    }
    let responses: [HelperResponse] = [
        .attributes(attributes),
        .data(Data([1, 2, 3])),
        .batch([attributes, FileAttributes(name: "d", type: .directory, size: 0, modificationNanos: 1, creationNanos: 2)]),
        .done,
        .failure(.system(call: "open", code: ENOENT)),
        .failure(.changed),
    ]
    for response in responses {
        let frame = HelperCodec.encode(id: 9, response)
        #expect(Int(UInt32(littleEndian: frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })) == frame.count - 4)
        let (id, decoded) = try HelperCodec.decodeResponse(frame.dropFirst(4))
        #expect(id == 9)
        #expect(decoded == response)
    }
}

// MARK: 文件操作

@Test func listingReturnsEveryEntryWithAttributes() throws {
    let directory = try TemporaryDirectory()
    try directory.write("a.jpg", bytes: 10)
    try directory.write("b.zip", bytes: 20)
    try FileManager.default.createDirectory(at: directory.url.appending(path: "sub"), withIntermediateDirectories: false)
    var entries: [FileAttributes] = []
    try FileOperations.list(directory.url.path) { batch in
        entries += batch
        return true
    }
    #expect(entries.map(\.name).sorted() == ["a.jpg", "b.zip", "sub"])
    #expect(entries.first { $0.name == "b.zip" }?.size == 20)
    #expect(entries.first { $0.name == "sub" }?.type == .directory)
    let stat = try FileOperations.stat(directory.url.appending(path: "a.jpg").path)
    #expect(stat == entries.first { $0.name == "a.jpg" })
}

@Test func readerDetectsChangedFiles() throws {
    let directory = try TemporaryDirectory()
    let url = try directory.write("a.bin", bytes: 1000)
    let attributes = try FileOperations.stat(url.path)
    let reader = FileReader()
    var request = ReadRequest(path: url.path, offset: 100, length: 50, expectedSize: attributes.size, expectedModificationNanos: attributes.modificationNanos, noCache: false, retryByReopening: true)
    #expect(try reader.read(request) == Data((100..<150).map { UInt8($0 % 251) }))
    request.length = 2000
    #expect(try reader.read(request).count == 900)
    // 原地改写：大小变了，缓存的描述符校验失败，重新打开后仍不一致。
    try Data(count: 10).write(to: url)
    #expect(throws: FileOperationError.changed) { try reader.read(request) }
}

@Test func readerReopensAfterAReadError() throws {
    let directory = try TemporaryDirectory()
    let url = try directory.write("a.bin", bytes: 100)
    let reader = FileReader()
    var request = ReadRequest(path: url.path, offset: 0, length: 10, expectedSize: nil, expectedModificationNanos: nil, noCache: false, retryByReopening: false)
    #expect(try reader.read(request).count == 10)
    // 让缓存的描述符读失败：换成指向目录的描述符，pread 返回 EISDIR，像网络卷断开较久后旧描述符的读。
    let cached = try #require(openDescriptor(for: url.path))
    let folder = open(directory.url.path, O_RDONLY | O_DIRECTORY)
    defer { close(folder) }
    #expect(dup2(folder, cached) == cached)
    #expect(throws: FileOperationError.system(call: "pread", code: EISDIR)) { try reader.read(request) }
    request.retryByReopening = true
    #expect(try reader.read(request) == Data((0..<10).map { UInt8($0) }))
}

@Test func probeLooksUpAMissingNameUnderTheMountPoint() throws {
    let directory = try TemporaryDirectory()
    try FileOperations.probe(directory.url.path)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    let file = try directory.write("a.bin", bytes: 1)
    #expect(throws: FileOperationError.system(call: "stat", code: ENOTDIR)) { try FileOperations.probe(file.path) }
}

// MARK: 调度

@Test func defaultDeadlineIsNineSeconds() {
    #expect(IOConfiguration(helperExecutable: nil).deadline == .seconds(9))
}

@Test func currentVolumeHealthReflectsRunningReads() async throws {
    let backend = ChunkBackend()
    let scheduler = IOScheduler(configuration: .testing(metadata: 1), backend: backend)
    let registry = FileSourceRegistry(scheduler: scheduler)
    let source = FileByteSource(
        identity: ContentIdentity(location: Location(root: .local, layers: [["big.bin"]]), size: 3 << 20, modificationNanos: 1),
        path: "/test/big.bin", volume: testVolume, scheduler: scheduler
    )
    #expect(scheduler.currentVolumeHealth().isEmpty)
    #expect(registry.currentVolumeHealth().isEmpty)

    let reading = Task { try await source.read(0..<source.identity.size, priority: .visible, group: nil) }
    await backend.gate.waitForStarted(1)
    let running = [VolumeHealth(root: .local, state: .healthy, inFlight: 1)]
    #expect(scheduler.currentVolumeHealth() == running)
    #expect(registry.currentVolumeHealth() == running)

    backend.gate.openAll()
    #expect(try await reading.value.count == Int(source.identity.size))
    let idle = [VolumeHealth(root: .local, state: .healthy)]
    #expect(scheduler.currentVolumeHealth() == idle)
    #expect(registry.currentVolumeHealth() == idle)
}

@Test func queuedRequestsStartByPriority() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 1))
    let gate = Gate()
    let order = Recorder()
    let blocker = Task { try await run(scheduler, "blocker", .visible, gate: gate, order: order) }
    await gate.waitForStarted(1)
    let background = Task { try await run(scheduler, "background", .background, gate: gate, order: order) }
    let visible = Task { try await run(scheduler, "visible", .visible, gate: gate, order: order) }
    let near = Task { try await run(scheduler, "near", .near, gate: gate, order: order) }
    try await waitUntil { scheduler.queuedCount == 3 }
    gate.openAll()
    for task in [blocker, background, visible, near] { _ = try await task.value }
    #expect(order.values == ["blocker", "visible", "near", "background"])
}

@Test func groupsCanBeCancelledAndReprioritized() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 1))
    let gate = Gate()
    let order = Recorder()
    let prefetch = IORequestGroup()
    let old = IORequestGroup()
    let blocker = Task { try await run(scheduler, "blocker", .visible, gate: gate, order: order) }
    await gate.waitForStarted(1)
    let near = Task { try await run(scheduler, "near", .near, gate: gate, order: order) }
    let promoted = Task { try await run(scheduler, "promoted", .background, group: prefetch, gate: gate, order: order) }
    let dropped = Task { try await run(scheduler, "dropped", .visible, group: old, gate: gate, order: order) }
    try await waitUntil { scheduler.queuedCount == 3 }
    scheduler.setPriority(.visible, for: prefetch)
    scheduler.cancel(old)
    await #expect(throws: IOError.cancelled) { try await dropped.value }
    await #expect(throws: IOError.cancelled) { try await run(scheduler, "late", .visible, group: old, gate: gate, order: order) }
    gate.openAll()
    for task in [blocker, near, promoted] { _ = try await task.value }
    #expect(order.values == ["blocker", "promoted", "near"])
}

@Test func cancellingTheCallerRemovesAQueuedRequest() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 1))
    let gate = Gate()
    let order = Recorder()
    let blocker = Task { try await run(scheduler, "blocker", .visible, gate: gate, order: order) }
    await gate.waitForStarted(1)
    let queued = Task { try await run(scheduler, "queued", .visible, gate: gate, order: order) }
    try await waitUntil { scheduler.queuedCount == 1 }
    queued.cancel()
    await #expect(throws: IOError.cancelled) { try await queued.value }
    #expect(scheduler.queuedCount == 0)
    gate.openAll()
    _ = try await blocker.value
    #expect(order.values == ["blocker"])
}

@Test func timeoutsDegradeTheVolumeUntilAProbeSucceeds() async throws {
    let backend = ProbeBackend()
    let scheduler = IOScheduler(configuration: .testing(metadata: 4, deadline: .milliseconds(200)), backend: backend)
    var health = scheduler.volumeHealth().makeAsyncIterator()
    #expect(await health.next() == [])
    let clock = ContinuousClock()
    let start = clock.now
    // 两次调用都卡住：第一次超时后计为 stuck，第二次超时后卷变为 degraded。
    let stuck = Gate()
    await #expect(throws: IOError.timeout) { try await hang(scheduler, gate: stuck) }
    #expect(clock.now - start < .seconds(1))
    await #expect(throws: IOError.timeout) { try await hang(scheduler, gate: stuck) }
    let degraded = try await next(&health) { $0.first.map { if case .degraded = $0.state { true } else { false } } ?? false }
    #expect(degraded.first?.stuck == 2)
    await #expect(throws: IOError.volumeDegraded(.local)) { try await hang(scheduler, gate: stuck) }
    // 探测在“网络恢复”之前一直失败；恢复后卷回到 healthy，新请求照常执行。
    backend.recovered.store(true, ordering: .relaxed)
    _ = try await next(&health) { $0.first?.state == .healthy }
    stuck.openAll()
    _ = try await next(&health) { $0.first?.stuck == 0 }
    let order = Recorder()
    let open = Gate()
    open.openAll()
    try await run(scheduler, "after", .visible, gate: open, order: order)
    #expect(order.values == ["after"])
}

@Test func cancellingAChunkedReadStopsBetweenChunks() async throws {
    let backend = ChunkBackend()
    var configuration = IOConfiguration.testing(metadata: 4)
    configuration.local.chunk = 1 << 20
    let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: configuration, backend: backend))
    let location = try await registry.location(for: URL(filePath: "/MVIOTests/big.bin", directoryHint: .notDirectory))
    let source = try await registry.provider(for: location).open(location)
    let reading = Task { try await source.read(0..<source.identity.size, priority: .visible, group: nil) }
    await backend.gate.waitForStarted(1)
    reading.cancel()
    backend.gate.openAll()
    await #expect(throws: IOError.cancelled) { try await reading.value }
    #expect(backend.reads.load(ordering: .relaxed) == 1)
}

// MARK: 文件系统来源

@Test func childrenArriveInBatchesBeforeTheListingEnds() async throws {
    let directory = Fixtures.root.appending(path: "local/generated/tree/10000")
    try #require(FileManager.default.fileExists(atPath: directory.path), "先运行 mvbench fixtures 生成大夹具")
    let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
    let location = try await registry.location(for: directory)
    var batches: [Int] = []
    for try await batch in try registry.provider(for: location).children(of: location, priority: .visible) {
        batches.append(batch.count)
        #expect(batch.allSatisfy { $0.location.parent == location && $0.kind == .image })
    }
    #expect(batches.reduce(0, +) == 10_000)
    #expect(batches.count > 1)
}

@Test func filesReadInChunksAndReportMissingFiles() async throws {
    let directory = try TemporaryDirectory()
    try directory.write("big.bin", bytes: 3_000_000 + 17)
    var configuration = IOConfiguration(helperExecutable: nil)
    configuration.local.chunk = 1 << 20
    configuration.smallReadLimit = 64 << 10
    let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: configuration))
    let folder = try await registry.location(for: directory.url)
    let provider = try registry.provider(for: folder)
    let source = try await provider.open(folder.appending("big.bin"))
    #expect(source.identity.size == 3_000_017)
    let whole = try await source.read(0..<source.identity.size, priority: .visible, group: nil)
    #expect(whole == Data((0..<3_000_017).map { UInt8($0 % 251) }))
    #expect(try await source.read(10..<20, priority: .visible, group: nil) == whole[10..<20])
    #expect(try await source.read(3_000_000..<4_000_000, priority: .visible, group: nil).count == 17)
    let entry = try await provider.entry(at: folder)
    #expect(entry.kind == .directory)
    await #expect(throws: IOError.notFound(folder.appending("missing.jpg"))) { try await provider.open(folder.appending("missing.jpg")) }
    await #expect(throws: IOError.unsupported(folder)) { try await provider.open(folder) }
}

// MARK: 辅助进程

@Test func helperProcessRunsRequestsAndIsReplacedAfterAbandon() async throws {
    let directory = try TemporaryDirectory()
    let url = try directory.write("a.bin", bytes: 300)
    try FileManager.default.createDirectory(at: directory.url.appending(path: "sub"), withIntermediateDirectories: false)
    let backend = HelperBackend(executable: helperExecutable)
    let attributes = try await call { backend.stat(url.path, completion: $0) }
    #expect(attributes.size == 300)
    let request = ReadRequest(path: url.path, offset: 10, length: 5, expectedSize: 300, expectedModificationNanos: attributes.modificationNanos, noCache: false, retryByReopening: true)
    #expect(try await call { backend.read(request, completion: $0) } == Data((10..<15).map { UInt8($0) }))
    let names = Mutex<[String]>([])
    try await call { completion in
        backend.list(directory.url.path, batch: { batch in
            names.withLock { $0 += batch.map(\.name) }
            return true
        }, completion: completion)
    }
    #expect(names.withLock { $0.sorted() } == ["a.bin", "sub"])
    await #expect(throws: FileOperationError.system(call: "stat", code: ENOENT)) {
        try await call { backend.stat(directory.url.appending(path: "missing").path, completion: $0) }
    }
    backend.abandon()
    #expect(try await call { backend.stat(url.path, completion: $0) }.size == 300)
}

@Test func networkVolumesUseTheHelper() {
    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: helperExecutable))
    #expect(scheduler.backend(for: Volume(mountPoint: "/Volumes/P", fileSystem: "nfs", root: .local, isLocal: false)) is HelperBackend)
    #expect(scheduler.backend(for: Volume(mountPoint: "/", fileSystem: "apfs", root: .local, isLocal: true)) is DirectBackend)
}

// MARK: 视频读取桥

@Test func videosLoadThroughTheResourceLoader() async throws {
    let video = Fixtures.root.appending(path: "local/generated/video/h264.mp4")
    try #require(FileManager.default.fileExists(atPath: video.path), "先运行 mvbench fixtures 生成大夹具")
    let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
    let location = try await registry.location(for: video)
    let source = try await registry.provider(for: location).open(location)
    let wrapped = ByteSourceAsset(source: source)
    let duration = try await wrapped.asset.load(.duration)
    #expect(abs(duration.seconds - 2) < 0.1)
    let generator = AVAssetImageGenerator(asset: wrapped.asset)
    let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
    #expect(image.width > 0)
}

// MARK: 测试工具

private enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
}

private final class BundleMarker {}

/// `swift build` 把 mvio-helper 放在测试包旁边。
private let helperExecutable = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvio-helper")

extension IOConfiguration {
    static func testing(metadata: Int, deadline: Duration = .seconds(9)) -> IOConfiguration {
        var configuration = IOConfiguration(helperExecutable: nil)
        configuration.local.metadata = metadata
        configuration.setDeadlineForTesting(deadline)
        configuration.probeInterval = .milliseconds(50)
        return configuration
    }
}

private let testVolume = Volume(mountPoint: "/test", fileSystem: "apfs", root: .local, isLocal: true)

private final class Recorder: Sendable {
    private let names = Mutex<[String]>([])

    func append(_ name: String) {
        names.withLock { $0.append(name) }
    }

    var values: [String] {
        names.withLock { $0 }
    }
}

/// 手动放行的调用：开始时登记，`openAll` 之后才结束。
private final class Gate: Sendable {
    private let state = Mutex<(started: Int, open: Bool, waiting: [@Sendable () -> Void])>((0, false, []))

    func enter(_ body: @escaping @Sendable () -> Void) {
        let run = state.withLock { state -> Bool in
            state.started += 1
            if state.open { return true }
            state.waiting.append(body)
            return false
        }
        if run { body() }
    }

    func openAll() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0() }
    }

    func waitForStarted(_ count: Int) async {
        while state.withLock({ $0.started }) < count { await Task.yield() }
    }
}

private func run(_ scheduler: IOScheduler, _ name: String, _ priority: IOPriority, group: IORequestGroup? = nil, gate: Gate, order: Recorder) async throws {
    let _: Void = try await scheduler.perform(on: testVolume, .metadata, priority: priority, group: group) { finish, _ in
        order.append(name)
        gate.enter { finish(.success(())) }
    }
}

private func hang(_ scheduler: IOScheduler, gate: Gate) async throws {
    let _: Void = try await scheduler.perform(on: testVolume, .metadata, priority: .visible, group: nil) { finish, _ in
        gate.enter { finish(.success(())) }
    }
}

/// 健康探测用的后端：`recovered` 之前 stat 一律失败。
private final class ProbeBackend: FileBackend {
    let recovered = Atomic(false)

    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        completion(recovered.load(ordering: .relaxed) ? .success(()) : .failure(.system(call: "statfs", code: ETIMEDOUT)))
    }

    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {}

    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {}
    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {}
    func abandon() {}
}

/// 等到第一个满足条件的健康状态。
/// 3 MB 的文件；第一块读取停在 gate 上，之后的块立即返回。
private final class ChunkBackend: FileBackend {
    let gate = Gate()
    let reads = Atomic(0)

    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        completion(.success(()))
    }

    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) {
        completion(.success(FileAttributes(name: "big.bin", type: .regular, size: 3 << 20, modificationNanos: 1)))
    }

    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) {
        reads.add(1, ordering: .relaxed)
        gate.enter { completion(.success(Data(count: request.length))) }
    }

    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {}
    func abandon() {}
}

/// 本进程中打开 `path` 的文件描述符。
private func openDescriptor(for path: String) -> Int32? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    let target = String(cString: resolved)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
    defer { buffer.deallocate() }
    return (0..<getdtablesize()).first { fd in
        fcntl(fd, F_GETPATH, buffer) == 0 && String(cString: buffer) == target
    }
}

private func next(_ iterator: inout AsyncStream<[VolumeHealth]>.Iterator, _ predicate: ([VolumeHealth]) -> Bool) async throws -> [VolumeHealth] {
    while let value = await iterator.next() {
        if predicate(value) { return value }
    }
    throw CancellationError()
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func call<T: Sendable>(_ body: (@escaping @Sendable (Result<T, FileOperationError>) -> Void) -> Void) async throws(FileOperationError) -> T {
    let result = await withCheckedContinuation { continuation in
        body { continuation.resume(returning: $0) }
    }
    return try result.get()
}

/// 测试结束时删除的临时目录。
private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "MVIOTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 内容为 i % 251，便于校验任意范围。
    @discardableResult
    func write(_ name: String, bytes: Int) throws -> URL {
        let file = url.appending(path: name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: file)
        return file
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
