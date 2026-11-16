import Darwin
import Dispatch
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

@Test func writeFailsAndClosesDescriptorWhenNoCacheFails() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appending(path: ".mvio-nocache-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let existing = directory.appending(path: "existing"), created = directory.appending(path: "created")
    try Data([1, 2, 3]).write(to: existing)
    let before = try FileOperations.stat(existing.path).modificationNanos
    for request: HelperRequest in [.create(path: created.path), .write(path: existing.path, offset: 0, data: Data([9])), .finish(path: existing.path, modificationNanos: 1_700_000_000_000_000_000)] {
        var descriptor: Int32 = -1
        var opened = Darwin.stat()
        #expect(throws: FileOperationError.system(call: "fcntl(F_NOCACHE)", code: ENOTSUP)) {
            _ = try FileOperations.execute(request) { fd in descriptor = fd; _ = fstat(fd, &opened); return ENOTSUP }
        }
        #expect(descriptor >= 0)
        // 其他并行测试可能复用已关闭的描述符；只要它不再指向本测试文件即可。
        var after = Darwin.stat()
        let stillOpen = fstat(descriptor, &after) == 0 && after.st_dev == opened.st_dev && after.st_ino == opened.st_ino
        #expect(!stillOpen)
    }
    #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
    #expect(try FileOperations.stat(existing.path).modificationNanos == before)
    #expect(try Data(contentsOf: created).isEmpty)
}

@Test(arguments: [false, true], ["renameFile", "renameParent", "removeFile", "removeParent"])
func mutationsReleaseCachedReadDescriptors(helper: Bool, operation: String) async throws {
    let directory = try makeDescriptorTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appending(path: "book")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let file = parent.appending(path: "page")
    try Data([1, 2, 3]).write(to: file)
    let backend = descriptorTestBackend(helper: helper)
    defer { backend.abandon() }
    #expect(try await readForDescriptorTest(file.path, using: backend) == Data([1, 2, 3]))

    let request: HelperRequest
    switch operation {
    case "renameFile":
        request = .rename(source: file.path, target: parent.appending(path: "renamed").path, exclusive: true)
    case "renameParent":
        request = .rename(source: parent.path, target: directory.appending(path: "renamed").path, exclusive: true)
    case "removeFile":
        request = .remove(path: file.path)
    default:
        // 外部先删掉子项，缓存仍持有该文件；删除空父目录时也必须释放后代描述符。
        try FileManager.default.removeItem(at: file)
        request = .remove(path: parent.path)
    }
    try await executeForDescriptorTest(request, using: backend)
    await #expect(throws: FileOperationError.system(call: "open", code: ENOENT)) {
        _ = try await readForDescriptorTest(file.path, using: backend)
    }
}

@Test(arguments: [false, true])
func cachedReadInvalidationRespectsDirectoryBoundaries(helper: Bool) async throws {
    let directory = try makeDescriptorTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appending(path: "book"), sibling = directory.appending(path: "book-extra")
    for folder in [parent, sibling] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    let file = parent.appending(path: "page"), other = sibling.appending(path: "page")
    for path in [file, other] { try Data([1, 2, 3]).write(to: path) }
    let backend = descriptorTestBackend(helper: helper)
    defer { backend.abandon() }
    for path in [file, other] {
        #expect(try await readForDescriptorTest(path.path, using: backend) == Data([1, 2, 3]))
        try FileManager.default.removeItem(at: path)
    }
    try await executeForDescriptorTest(.remove(path: parent.path), using: backend)
    await #expect(throws: FileOperationError.system(call: "open", code: ENOENT)) {
        _ = try await readForDescriptorTest(file.path, using: backend)
    }
    // 同前缀的相邻目录不受影响，已 unlink 的文件仍能从原有缓存描述符读取。
    #expect(try await readForDescriptorTest(other.path, using: backend) == Data([1, 2, 3]))
}

@Test(arguments: [false, true], [false, true])
func readsDuringFileMutationDoNotLeaveCachedDescriptors(rename: Bool, parent: Bool) async throws {
    let directory = try makeDescriptorTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = directory.appending(path: "book"), file = folder.appending(path: "page")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let bytes = Data([1, 2, 3])
    try bytes.write(to: file)
    let reader = FileReader()
    let read = ReadRequest(path: file.path, offset: 0, length: 3, expectedSize: nil, expectedModificationNanos: nil, noCache: false, retryByReopening: false)
    #expect(try reader.read(read) == bytes)
    let source = parent ? folder.path : file.path
    let mutation: HelperRequest = rename
        ? .rename(source: source, target: directory.appending(path: "renamed").path, exclusive: true)
        : .remove(path: source)
    let completed = DispatchSemaphore(value: 0)
    let concurrentRead = Mutex<Result<Data, FileOperationError>?>(nil)

    // 只有专用线程阻塞等待读取；测试任务挂起，给共享线程池留下执行并发读和超时回调的槽位。
    let mutationResult: Result<Result<Data, FileOperationError>, FileOperationError> = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            let result = Result { () throws(FileOperationError) -> Result<Data, FileOperationError> in
                try reader.withInvalidatedCache(for: mutation) { () throws(FileOperationError) in
                    // 缓存已清除，但系统调用尚未开始：让另一个线程完整读完，固定重缓存的竞态顺序。
                    DispatchQueue.global().async {
                        let result = Result { () throws(FileOperationError) in try reader.read(read) }
                        concurrentRead.withLock { $0 = result }
                        completed.signal()
                    }
                    guard completed.wait(timeout: .now() + 10) == .success else {
                        throw .system(call: "concurrent read timed out", code: ETIMEDOUT)
                    }
                    if parent && !rename, unlink(file.path) != 0 { throw .system(call: "unlink", code: errno) }
                    _ = try FileOperations.execute(mutation)
                    return Result { () throws(FileOperationError) in try reader.read(read) }
                }
            }
            continuation.resume(returning: result)
        }
    }
    // 修改窗口还没结束时，旧路径就应当无法再通过缓存读取。
    let afterMutation = try mutationResult.get()
    #expect(throws: FileOperationError.system(call: "open", code: ENOENT)) { try afterMutation.get() }
    let result = try #require(concurrentRead.withLock { $0 })
    #expect(try result.get() == bytes)
    #expect(throws: FileOperationError.system(call: "open", code: ENOENT)) { try reader.read(read) }

    // 修改结束后恢复正常缓存，新源路径的描述符仍按原规则复用。
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let replacement = Data([4, 5, 6])
    try replacement.write(to: file)
    #expect(try reader.read(read) == replacement)
    try FileManager.default.removeItem(at: file)
    #expect(try reader.read(read) == replacement)
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

private func makeDescriptorTestDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appending(path: ".mvio-descriptor-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func descriptorTestBackend(helper: Bool) -> any FileBackend {
    let helperURL = Bundle(for: WriteBundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "mvio-helper")
    return helper ? HelperBackend(executable: helperURL) : DirectBackend()
}

private func readForDescriptorTest(_ path: String, using backend: any FileBackend) async throws(FileOperationError) -> Data {
    let request = ReadRequest(path: path, offset: 0, length: 3, expectedSize: nil, expectedModificationNanos: nil, noCache: false, retryByReopening: false)
    let result = await withCheckedContinuation { continuation in
        backend.read(request) { continuation.resume(returning: $0) }
    }
    return try result.get()
}

private func executeForDescriptorTest(_ request: HelperRequest, using backend: any FileBackend) async throws(FileOperationError) {
    let result = await withCheckedContinuation { continuation in
        backend.execute(request) { continuation.resume(returning: $0) }
    }
    _ = try result.get()
}

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
