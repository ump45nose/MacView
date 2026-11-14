import Foundation
import MVFoundation
import MVIO
import Synchronization
import Testing
@testable import MVFileOps

@Test func fileOperationsAndTheirInverses() async throws {
    let fixture = try await Fixture()
    let fs = fixture.fs
    let service = fixture.service
    let root = fixture.root
    let source = root.appending("source.jpg")
    try await fs.createFile(at: source)
    let renamed = root.appending("renamed.png")
    let rename = await service.perform(.rename(source, to: "renamed.png"))
    #expect(rename.failures.isEmpty && rename.changes.count == 1)
    if case let .moved(from, to) = try #require(rename.changes.first) {
        #expect(from == source && to.location == renamed && to.kind == .image)
    } else { Issue.record("rename must report moved") }
    let undo = await service.perform(try #require(rename.inverse))
    #expect(undo.failures.isEmpty && fixture.exists("source.jpg"))
    let redo = await service.perform(try #require(undo.inverse))
    #expect(redo.failures.isEmpty && fixture.exists("renamed.png"))

    let folder = root.appending("folder")
    let mkdir = await service.perform(.makeDirectory(in: root, name: "folder"))
    #expect(mkdir.failures.isEmpty && fixture.exists("folder"))
    let remove = await service.perform(try #require(mkdir.inverse))
    #expect(remove.failures.isEmpty && !fixture.exists("folder"))
    #expect((await service.perform(try #require(remove.inverse))).failures.isEmpty)
    let move = await service.perform(.transfer([renamed], into: folder, mode: .move, conflict: .appendNumber))
    #expect(move.failures.isEmpty && fixture.exists("folder/renamed.png"))
    let back = await service.perform(try #require(move.inverse))
    #expect(back.failures.isEmpty && fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(back.inverse))).failures.isEmpty)
    let copied = await service.perform(.transfer([folder.appending("renamed.png")], into: root, mode: .copy, conflict: .appendNumber))
    #expect(copied.failures.isEmpty && fixture.exists("renamed.png"))
    let undoCopy = await service.perform(try #require(copied.inverse))
    #expect(undoCopy.failures.isEmpty && !fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(undoCopy.inverse))).failures.isEmpty)
    let deleted = await service.perform(.delete([renamed]))
    #expect(deleted.failures.isEmpty && !fixture.exists("renamed.png"))
    let restore = await service.perform(try #require(deleted.inverse))
    #expect(restore.failures.isEmpty && fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(restore.inverse))).failures.isEmpty)
    let permanent = await service.perform(.deletePermanently([folder]))
    #expect(permanent.failures.isEmpty && permanent.inverse == nil && !fixture.exists("folder"))
}

@Test func conflictsValidationAndSequence() async throws {
    let f = try await Fixture()
    try await f.fs.makeDirectory(at: f.root.appending("dest"))
    try await f.fs.createFile(at: f.root.appending("a.jpg"))
    try await f.fs.createFile(at: f.root.appending("dest").appending("a.jpg"))
    let skipped = await f.service.perform(.transfer([f.root.appending("a.jpg")], into: f.root.appending("dest"), mode: .move, conflict: .skip))
    #expect(skipped.skipped == [f.root.appending("a.jpg")] && f.exists("a.jpg"))
    let moved = await f.service.perform(.transfer([f.root.appending("a.jpg")], into: f.root.appending("dest"), mode: .move, conflict: .appendNumber))
    #expect(moved.failures.isEmpty && f.exists("dest/a (2).jpg"))
    let conflict = await f.service.perform(.relocate([Relocation(source: f.root.appending("dest").appending("a (2).jpg"), target: f.root.appending("dest").appending("a.jpg"))]))
    #expect(conflict.failures.count == 1)
    let invalid = await f.service.perform(.makeDirectory(in: f.root, name: ".hidden"))
    #expect((invalid.failures.first?.error as? FileOpsError) == .invalidName(".hidden"))
    let archive = f.root.appending("a.zip").appendingLayer(["a.jpg"])
    let readOnly = await f.service.perform(.delete([archive]))
    #expect((readOnly.failures.first?.error as? FileOpsError) == .readOnly)
    let intoItself = await f.service.perform(.transfer([f.root.appending("dest")], into: f.root.appending("dest"), mode: .move, conflict: .skip))
    #expect((intoItself.failures.first?.error as? FileOpsError) == .intoItself)
    let sequence = await f.service.perform(.sequence([.makeDirectory(in: f.root, name: "new"), .transfer([f.root.appending("dest").appending("a.jpg")], into: f.root.appending("new"), mode: .move, conflict: .skip)]))
    #expect(sequence.failures.isEmpty && f.exists("new/a.jpg"))
    let inverse = await f.service.perform(try #require(sequence.inverse))
    #expect(inverse.failures.isEmpty && !f.exists("new") && f.exists("dest/a.jpg"))
    #expect((await f.service.perform(try #require(inverse.inverse))).failures.isEmpty && f.exists("new/a.jpg"))
}

@Test func networkRecycleAndSubscriptions() async throws {
    let f = try await Fixture(network: true)
    let a = f.root.appending("a.jpg")
    try await f.fs.createFile(at: a)
    let stream = f.service.changes()
    let received = Task { for await batch in stream { return batch }; return [] }
    let result = await f.service.perform(.delete([a]))
    #expect(result.failures.isEmpty && !f.exists("a.jpg"))
    #expect(await received.value == result.changes)
    #expect((await f.service.recycleBins()).first?.batchCount == 1)
    #expect((await f.service.perform(try #require(result.inverse))).failures.isEmpty && f.exists("a.jpg"))
}

@Test func cancellationPreservesCompletedMoves() async throws {
    let f = try await Fixture()
    let dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    var items: [Location] = []
    for i in 0..<50 { let item = f.root.appending("\(i).jpg"); try await f.fs.createFile(at: item); items.append(item) }
    let allItems = items
    let taskBox = Mutex<Task<FileOperationResult, Never>?>(nil)
    let task = Task {
        await f.service.perform(.transfer(allItems, into: dest, mode: .move, conflict: .skip)) { progress in
            if progress.completedItems >= 5 { taskBox.withLock { $0?.cancel() } }
        }
    }
    taskBox.withLock { $0 = task }
    let result = await task.value
    #expect(result.changes.count >= 5 && result.changes.count < 50)
    #expect(result.inverse != nil)
    let reversed = await f.service.perform(try #require(result.inverse))
    #expect(reversed.failures.isEmpty && allItems.allSatisfy { f.exists($0.name) })
}

private final class Fixture: Sendable {
    let directory: URL
    let root: Location
    let fs: FileSystemProvider
    let service: FileOperationService
    init(network: Bool = false) async throws {
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = work.appending(path: ".mvfileops-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        fs = registry.fileSystem
        root = try await registry.location(for: directory)
        let root = self.root
        let fs = self.fs
        service = try FileOperationService(fileSystem: fs, journalURL: directory.appending(path: "transfers.json"), isNetwork: { location in network && location.hasPrefix(root) }, volumeRoot: { _ in root }, networkRoots: { network ? [root] : [] }, trash: { source in
            let trash = root.appending("trash")
            do { try await fs.makeDirectory(at: trash) } catch IOError.alreadyExists {}
            let target = trash.appending(UUID().uuidString + "-" + source.name)
            try await fs.rename(source, to: target, exclusive: true)
            return target
        })
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: directory.appending(path: path).path) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Test func directoryCopyConflictAndFailures() async throws {
    let f = try await Fixture()
    let from = f.root.appending("from")
    let into = f.root.appending("into")
    try await f.fs.makeDirectory(at: from)
    try await f.fs.makeDirectory(at: into)
    let source = from.appending("image.jpg")
    try await f.fs.createFile(at: source)
    let data = Data((0..<200_000).map { UInt8($0 % 251) })
    try await f.fs.write(data, at: 0, to: source, priority: .background)
    try await f.fs.finishFile(at: source, modificationNanos: 1_700_000_000_123_456_789)
    let first = await f.service.perform(.transfer([from], into: into, mode: .copy, conflict: .appendNumber))
    #expect(first.failures.isEmpty && f.exists("into/from/image.jpg") && f.exists("from/image.jpg"))
    #expect(try Data(contentsOf: f.directory.appending(path: "into/from/image.jpg")) == data)
    let copied = try await f.fs.entry(at: into.appending("from").appending("image.jpg"))
    #expect(copied.identity.modificationNanos == 1_700_000_000_123_456_789)
    let skip = await f.service.perform(.transfer([from], into: into, mode: .copy, conflict: .skip))
    #expect(skip.skipped == [from] && !f.exists("into/from (2)"))
    let second = await f.service.perform(.transfer([from], into: into, mode: .copy, conflict: .appendNumber))
    #expect(second.failures.isEmpty && f.exists("into/from (2)/image.jpg"))
    let missing = f.root.appending("missing")
    let mixed = await f.service.perform(.transfer([missing, source], into: into, mode: .move, conflict: .skip))
    #expect(mixed.failures.count == 1 && mixed.failures.first?.location == missing && mixed.changes.count == 1)
    #expect((await f.service.perform(try #require(mixed.inverse))).failures.isEmpty && f.exists("from/image.jpg"))
}

@Test func symbolicLinksAreNotFollowedOrDeleted() async throws {
    let f = try await Fixture()
    let outside = f.directory.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data([1]).write(to: outside.appending(path: "keep.jpg"))
    let container = f.directory.appending(path: "container")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: container.appending(path: "link.jpg"), withDestinationURL: outside)
    let linked = f.root.appending("container").appending("link.jpg")
    let direct = await f.service.perform(.deletePermanently([linked]))
    #expect(direct.failures.count == 1 && f.exists("outside/keep.jpg"))
    let recursive = await f.service.perform(.deletePermanently([f.root.appending("container")]))
    #expect(recursive.failures.count == 1 && f.exists("outside/keep.jpg") && f.exists("container"))
}
