import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVIO
@testable import MVFileOps

@Test func deleteTreeIgnoresChildRemovedAfterListing() async throws {
    let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = work.appending(path: ".mvfileops-delete-race-\(UUID().uuidString)")
    let nested = directory.appending(path: "tree/inner")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data([1, 2, 3]).write(to: nested.appending(path: "photo.jpg"))
    let disappearing = nested.appending(path: "._photo.jpg")
    try Data([4, 5]).write(to: disappearing)

    let backend = DisappearingChildBackend(directory: nested.path, child: disappearing.path)
    let scheduler = IOScheduler(configuration: IOConfiguration(helperExecutable: nil), backend: backend)
    defer { scheduler.shutdown() }
    let registry = FileSourceRegistry(scheduler: scheduler)
    let tree = try await registry.location(for: directory.appending(path: "tree"))
    let service = try FileOperationService(fileSystem: registry.fileSystem, journalURL: directory.appending(path: "transfers.json"))
    let result = await service.perform(.deletePermanently([tree]))

    #expect(backend.removedChild.withLock { $0 })
    #expect(result.failures.isEmpty && result.retry == nil && result.changes == [.removed(tree)])
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "tree").path))
    let missingRoot = await service.perform(.deletePermanently([tree]))
    #expect(missingRoot.changes.isEmpty && missingRoot.failures.count == 1)
    #expect(missingRoot.failures.first?.error as? IOError == .notFound(tree))
}

private final class DisappearingChildBackend: FileBackend {
    private let direct = DirectBackend()
    private let directory: String
    private let child: String
    private let listings = Mutex(0)
    let removedChild = Mutex(false)

    init(directory: String, child: String) { self.directory = directory; self.child = child }
    func execute(_ request: HelperRequest, completion: @escaping @Sendable (Result<String?, FileOperationError>) -> Void) { direct.execute(request, completion: completion) }
    func stat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) { direct.stat(path, completion: completion) }
    func lstat(_ path: String, completion: @escaping @Sendable (Result<FileAttributes, FileOperationError>) -> Void) { direct.lstat(path, completion: completion) }
    func probe(_ mountPoint: String, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) { direct.probe(mountPoint, completion: completion) }
    func read(_ request: ReadRequest, completion: @escaping @Sendable (Result<Data, FileOperationError>) -> Void) { direct.read(request, completion: completion) }
    func abandon() { direct.abandon() }

    func list(_ path: String, batch: @escaping @Sendable ([FileAttributes]) -> Bool, completion: @escaping @Sendable (Result<Void, FileOperationError>) -> Void) {
        // 首次列举用于统计字节；第二次是 removeTree 的子项快照。
        let removeChild = path == directory && listings.withLock { $0 += 1; return $0 == 2 }
        direct.list(path, batch: batch) { [self] result in
            guard removeChild, case .success = result else { completion(result); return }
            let removal = Result { () throws(FileOperationError) in
                _ = try FileOperations.execute(.remove(path: child))
            }
            if case .success = removal { removedChild.withLock { $0 = true } }
            completion(removal)
        }
    }
}
