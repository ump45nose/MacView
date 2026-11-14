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
    #expect((await service.perform(try #require(remove.inverse))).failures.isEmpty && fixture.exists("folder"))
    let move = await service.perform(.transfer([renamed], into: folder, mode: .move, conflict: .appendNumber))
    #expect(move.failures.isEmpty && fixture.exists("folder/renamed.png"))
    let back = await service.perform(try #require(move.inverse))
    #expect(back.failures.isEmpty && fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(back.inverse))).failures.isEmpty && fixture.exists("folder/renamed.png") && !fixture.exists("renamed.png"))
    let copied = await service.perform(.transfer([folder.appending("renamed.png")], into: root, mode: .copy, conflict: .appendNumber))
    #expect(copied.failures.isEmpty && fixture.exists("renamed.png"))
    let undoCopy = await service.perform(try #require(copied.inverse))
    #expect(undoCopy.failures.isEmpty && !fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(undoCopy.inverse))).failures.isEmpty && fixture.exists("renamed.png") && fixture.exists("folder/renamed.png"))
    let deleted = await service.perform(.delete([renamed]))
    #expect(deleted.failures.isEmpty && !fixture.exists("renamed.png"))
    let restore = await service.perform(try #require(deleted.inverse))
    #expect(restore.failures.isEmpty && fixture.exists("renamed.png"))
    #expect((await service.perform(try #require(restore.inverse))).failures.isEmpty && !fixture.exists("renamed.png"))
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
    let restored = await f.service.perform(try #require(result.inverse))
    #expect(restored.failures.isEmpty && f.exists("a.jpg"))
    let redone = await f.service.perform(try #require(restored.inverse))
    #expect(redone.failures.isEmpty && !f.exists("a.jpg"))
}

@Test func cancellationPreservesCompletedMoves() async throws {
    let f = try await Fixture()
    let dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    var items: [Location] = []
    for i in 0..<50 {
        let item = f.root.appending("\(i).jpg")
        try await f.fs.createFile(at: item)
        try await f.fs.write(Data([UInt8(i)]), at: 0, to: item, priority: .background)
        items.append(item)
    }
    let allItems = items
    let taskBox = Mutex<Task<FileOperationResult, Never>?>(nil)
    let (start, resume) = AsyncStream<Void>.makeStream()
    let task = Task {
        for await _ in start { break }
        return await f.service.perform(.transfer(allItems, into: dest, mode: .move, conflict: .skip)) { progress in
            if progress.completedItems >= 5 { taskBox.withLock { $0?.cancel() } }
        }
    }
    taskBox.withLock { $0 = task }
    resume.yield(())
    resume.finish()
    let result = await task.value
    #expect(result.changes.count >= 5 && result.changes.count < 50)
    #expect(result.inverse != nil && result.failures.isEmpty && result.skipped.isEmpty)
    let completed = Set(result.changes.compactMap { change -> Location? in
        if case let .moved(from, to) = change {
            #expect(to.location == dest.appending(from.name))
            return from
        }
        Issue.record("完成项必须报告移动")
        return nil
    })
    #expect(completed.count == result.changes.count)
    for (index, item) in allItems.enumerated() {
        let sourceURL = f.directory.appending(path: item.name)
        let targetURL = f.directory.appending(path: "dest/\(item.name)")
        if completed.contains(item) {
            #expect(!f.exists(item.name) && f.exists("dest/\(item.name)"))
            #expect(try Data(contentsOf: targetURL) == Data([UInt8(index)]))
        } else {
            #expect(f.exists(item.name) && !f.exists("dest/\(item.name)"))
            #expect(try Data(contentsOf: sourceURL) == Data([UInt8(index)]))
        }
    }
    let reversed = await f.service.perform(try #require(result.inverse))
    #expect(reversed.failures.isEmpty && reversed.changes.count == completed.count)
    for (index, item) in allItems.enumerated() {
        #expect(f.exists(item.name) && !f.exists("dest/\(item.name)"))
        #expect(try Data(contentsOf: f.directory.appending(path: item.name)) == Data([UInt8(index)]))
    }
}

private final class Fixture: Sendable {
    let directory: URL
    let root: Location
    let fs: FileSystemProvider
    let service: FileOperationService
    init(network: Bool = false, forceCrossVolume: Bool = false, corruptCopy: Bool = false, badJournal: Bool = false, transferID: UUID? = nil, failAfterCreate: Bool = false, failCleanup: Bool = false) async throws {
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = work.appending(path: ".mvfileops-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        let registry = FileSourceRegistry(scheduler: IOScheduler(configuration: IOConfiguration(helperExecutable: nil)))
        fs = registry.fileSystem
        root = try await registry.location(for: directory)
        let root = self.root
        let fs = self.fs
        if badJournal {
            let blocked = directory.appending(path: "readonly")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        }
        let journalURL = directory.appending(path: badJournal ? "readonly/transfers.json" : "transfers.json")
        service = try FileOperationService(fileSystem: fs, journalURL: journalURL, forceCrossVolume: forceCrossVolume, corruptCopy: corruptCopy, transferID: { transferID ?? UUID() }, createTemporary: { location in
            try await fs.createFile(at: location)
            if failAfterCreate { throw IOError.underlying("fcntl(F_NOCACHE) failed") }
        }, removeTemporary: { location in
            if failCleanup { throw IOError.underlying("cleanup failed") }
            try await fs.remove(location)
        }, isNetwork: { location in network && location.hasPrefix(root) }, volumeRoot: { _ in root }, networkRoots: { network ? [root] : [] }, trash: { source in
            let trash = root.appending("trash")
            do { try await fs.makeDirectory(at: trash) } catch IOError.alreadyExists {}
            let target = trash.appending(UUID().uuidString + "-" + source.name)
            try await fs.rename(source, to: target, exclusive: true)
            return target
        })
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: directory.appending(path: path).path) }
    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "readonly").path)
        try? FileManager.default.removeItem(at: directory)
    }
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

@Test func symbolicLinksAreNotFollowed() async throws {
    let f = try await Fixture()
    let outside = f.directory.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data([1]).write(to: outside.appending(path: "keep.jpg"))
    let container = f.directory.appending(path: "container")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: container.appending(path: "link.jpg"), withDestinationURL: outside)
    let linked = f.root.appending("container").appending("link.jpg")
    let direct = await f.service.perform(.deletePermanently([linked]))
    #expect(direct.failures.isEmpty && !f.exists("container/link.jpg") && f.exists("outside/keep.jpg"))
    try FileManager.default.createSymbolicLink(at: container.appending(path: "link.jpg"), withDestinationURL: outside)
    let recursive = await f.service.perform(.deletePermanently([f.root.appending("container")]))
    #expect(recursive.failures.isEmpty && f.exists("outside/keep.jpg") && !f.exists("container"))
}

@Test func crossVolumeMoveCopiesVerifiesAndClearsJournal() async throws {
    let f = try await Fixture(forceCrossVolume: true)
    let source = f.root.appending("source.jpg"), folder = f.root.appending("dest")
    try await f.fs.makeDirectory(at: folder)
    try await f.fs.createFile(at: source)
    let data = Data((0..<1_500_000).map { UInt8($0 % 251) })
    try await f.fs.write(data, at: 0, to: source, priority: .background)
    let stamp: Int64 = 1_700_000_000_123_456_789
    try await f.fs.finishFile(at: source, modificationNanos: stamp)
    let result = await f.service.perform(.transfer([source], into: folder, mode: .move, conflict: .skip))
    #expect(result.failures.isEmpty && !f.exists("source.jpg") && f.exists("dest/source.jpg"))
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/source.jpg")) == data)
    #expect(try await f.fs.entry(at: folder.appending("source.jpg")).identity.modificationNanos == stamp)
    let journal = try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: f.directory.appending(path: "transfers.json")))
    #expect(journal.transfers.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appending(path: "dest").path).allSatisfy { !$0.hasSuffix(".macview-part") })
}

@Test func verificationFailureKeepsSourceAndCleansTemporary() async throws {
    let f = try await Fixture(forceCrossVolume: true, corruptCopy: true)
    let source = f.root.appending("source.jpg"), folder = f.root.appending("dest")
    try await f.fs.makeDirectory(at: folder)
    try await f.fs.createFile(at: source)
    try await f.fs.write(Data([1, 2, 3]), at: 0, to: source, priority: .background)
    let result = await f.service.perform(.transfer([source], into: folder, mode: .move, conflict: .skip))
    #expect((result.failures.first?.error as? FileOpsError) == .verificationFailed)
    #expect(f.exists("source.jpg") && !f.exists("dest/source.jpg"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appending(path: "dest").path).allSatisfy { !$0.hasSuffix(".macview-part") })
    let journal = try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: f.directory.appending(path: "transfers.json")))
    #expect(journal.transfers.isEmpty)
}

@Test func journalFailurePreventsMove() async throws {
    let f = try await Fixture(forceCrossVolume: true, badJournal: true)
    let source = f.root.appending("source.jpg"), folder = f.root.appending("dest")
    try await f.fs.makeDirectory(at: folder)
    try await f.fs.createFile(at: source)
    let result = await f.service.perform(.transfer([source], into: folder, mode: .move, conflict: .skip))
    #expect(result.failures.count == 1 && f.exists("source.jpg") && !f.exists("dest/source.jpg") && !f.exists("dest/.source.jpg.macview-part"))
}

@Test func resumeAllRecoveryRulesAndUnavailableVolume() async throws {
    let f = try await Fixture(forceCrossVolume: true)
    let dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    let a = f.root.appending("a.jpg"), b = f.root.appending("b.jpg"), c = f.root.appending("c.jpg"), d = f.root.appending("d.jpg")
    for item in [a, b, c] { try await f.fs.createFile(at: item); try await f.fs.write(Data([7, 8]), at: 0, to: item, priority: .background) }
    let aID = UUID()
    let aTemporary = dest.appending(".a.jpg.\(aID.uuidString.prefix(8).lowercased()).macview-part")
    try await f.fs.createFile(at: aTemporary)
    try await f.fs.createFile(at: dest.appending("b.jpg"))
    try await f.fs.write(Data([7, 8]), at: 0, to: dest.appending("b.jpg"), priority: .background)
    let bTime = try await f.fs.entry(at: b).identity.modificationNanos
    try await f.fs.finishFile(at: dest.appending("b.jpg"), modificationNanos: bTime)
    let unavailable = Location(root: .network(scheme: "nfs", host: "missing.invalid", share: "missing"), layers: [["x.jpg"]])
    let records = [
        TransferRecord(id: aID, source: a, target: dest.appending("a.jpg"), temporary: aTemporary),
        TransferRecord(id: UUID(), source: b, target: dest.appending("b.jpg"), temporary: dest.appending(".b.jpg.macview-part")),
        TransferRecord(id: UUID(), source: c, target: dest.appending("c.jpg"), temporary: dest.appending(".c.jpg.macview-part")),
        TransferRecord(id: UUID(), source: d, target: dest.appending("d.jpg"), temporary: dest.appending(".d.jpg.macview-part")),
        TransferRecord(id: UUID(), source: unavailable, target: dest.appending("x.jpg"), temporary: dest.appending(".x.jpg.macview-part"))
    ]
    try JSONEncoder().encode(TransferJournal(version: 1, transfers: records)).write(to: f.directory.appending(path: "transfers.json"))
    let report = await f.service.resumeInterruptedTransfers()
    #expect(report == ResumeReport(completed: 3, pending: 1, failed: 1))
    #expect(!f.exists("a.jpg") && !f.exists("b.jpg") && !f.exists("c.jpg"))
    #expect(f.exists("dest/a.jpg") && f.exists("dest/b.jpg") && f.exists("dest/c.jpg") && !f.exists("dest/\(aTemporary.name)"))
    let journal = try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: f.directory.appending(path: "transfers.json")))
    #expect(journal.transfers == [records.last!])
}

@Test func crossVolumeConflictAndDirectoryCopy() async throws {
    let f = try await Fixture(forceCrossVolume: true)
    let source = f.root.appending("source"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: source)
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.makeDirectory(at: dest.appending("source"))
    let child = source.appending("a.jpg")
    try await f.fs.createFile(at: child)
    try await f.fs.write(Data([1, 2, 3]), at: 0, to: child, priority: .background)
    let result = await f.service.perform(.transfer([source], into: dest, mode: .move, conflict: .appendNumber))
    #expect(result.failures.isEmpty && !f.exists("source") && f.exists("dest/source (2)/a.jpg"))
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/source (2)/a.jpg")) == Data([1, 2, 3]))
    #expect((await f.service.perform(try #require(result.inverse))).failures.isEmpty && f.exists("source/a.jpg"))
}

@Test func cancellingCrossVolumeCopyCleansTemporaryAndJournal() async throws {
    let f = try await Fixture(forceCrossVolume: true)
    let source = f.root.appending("big.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    try await f.fs.write(Data(repeating: 7, count: 12 << 20), at: 0, to: source, priority: .background)
    let taskBox = Mutex<Task<FileOperationResult, Never>?>(nil)
    let task = Task {
        await f.service.perform(.transfer([source], into: dest, mode: .move, conflict: .skip)) { progress in
            if progress.completedBytes > 0 && progress.completedItems == 0 { taskBox.withLock { $0?.cancel() } }
        }
    }
    taskBox.withLock { $0 = task }
    let result = await task.value
    #expect(result.changes.isEmpty && f.exists("big.jpg") && !f.exists("dest/big.jpg"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appending(path: "dest").path).allSatisfy { !$0.hasSuffix(".macview-part") })
    let journal = try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: f.directory.appending(path: "transfers.json")))
    #expect(journal.transfers.isEmpty)
}

@Test func failedRecoveryCleansRecordAndCanBeRetried() async throws {
    let f = try await Fixture(corruptCopy: true)
    let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    try await f.fs.write(Data([1, 2, 3]), at: 0, to: source, priority: .background)
    let record = TransferRecord(id: UUID(), source: source, target: dest.appending("source.jpg"), temporary: dest.appending(".source.jpg.macview-part"))
    let journalURL = f.directory.appending(path: "transfers.json")
    try JSONEncoder().encode(TransferJournal(version: 1, transfers: [record])).write(to: journalURL)
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 0, pending: 0, failed: 1))
    #expect(f.exists("source.jpg") && !f.exists("dest/.source.jpg.macview-part"))
    #expect(try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: journalURL)).transfers.isEmpty)
    try JSONEncoder().encode(TransferJournal(version: 1, transfers: [record])).write(to: journalURL)
    let retry = try FileOperationService(fileSystem: f.fs, journalURL: journalURL)
    #expect(await retry.resumeInterruptedTransfers() == ResumeReport(completed: 1, pending: 0, failed: 0))
    #expect(!f.exists("source.jpg") && f.exists("dest/source.jpg"))
}

@Test func recoveryNeverDeletesSourceForAnUnrelatedTarget() async throws {
    let f = try await Fixture()
    let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    try await f.fs.write(Data([1, 2, 3]), at: 0, to: source, priority: .background)
    let target = dest.appending("source.jpg")
    try await f.fs.createFile(at: target)
    try await f.fs.write(Data([9, 9, 9]), at: 0, to: target, priority: .background)
    let time = try await f.fs.entry(at: source).identity.modificationNanos
    try await f.fs.finishFile(at: target, modificationNanos: time)
    let record = TransferRecord(id: UUID(), source: source, target: target, temporary: dest.appending(".source.jpg.macview-part"))
    let journalURL = f.directory.appending(path: "transfers.json")
    try JSONEncoder().encode(TransferJournal(version: 1, transfers: [record])).write(to: journalURL)
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 0, pending: 0, failed: 1))
    #expect(f.exists("source.jpg") && f.exists("dest/source.jpg"))
    #expect(try JSONDecoder().decode(TransferJournal.self, from: Data(contentsOf: journalURL)).transfers == [record])
}

@Test func linksAndUnknownRegularFilesFollowFileOperationRules() async throws {
    let f = try await Fixture(forceCrossVolume: false)
    let folder = f.root.appending("dest")
    try await f.fs.makeDirectory(at: folder)
    let target = f.directory.appending(path: "target")
    try Data([1, 2, 3]).write(to: target)
    let link = f.root.appending("link.jpg")
    try FileManager.default.createSymbolicLink(atPath: f.directory.appending(path: "link.jpg").path, withDestinationPath: "missing")
    let renamed = await f.service.perform(.rename(link, to: "renamed.png"))
    #expect(renamed.failures.isEmpty)
    if case let .moved(_, to) = try #require(renamed.changes.first) { #expect(to.kind == .other) }
    let moved = await f.service.perform(.transfer([f.root.appending("renamed.png")], into: folder, mode: .move, conflict: .skip))
    #expect(moved.failures.isEmpty)
    #expect(try await f.fs.itemWithoutFollowingLinks(at: folder.appending("renamed.png")).type == .symbolicLink)
    let copy = await f.service.perform(.transfer([folder.appending("renamed.png")], into: f.root, mode: .copy, conflict: .skip))
    #expect((copy.failures.first?.error as? IOError) == .unsupported(folder.appending("renamed.png")))
    let cross = try await Fixture(forceCrossVolume: true)
    try await cross.fs.makeDirectory(at: cross.root.appending("dest"))
    try FileManager.default.createSymbolicLink(atPath: cross.directory.appending(path: "link").path, withDestinationPath: "missing")
    let crossLink = cross.root.appending("link")
    let rejected = await cross.service.perform(.transfer([crossLink], into: cross.root.appending("dest"), mode: .move, conflict: .skip))
    #expect((rejected.failures.first?.error as? IOError) == .unsupported(crossLink))
    #expect(try await cross.fs.itemWithoutFollowingLinks(at: crossLink).type == .symbolicLink)
    let unknown = f.root.appending("unknown.xyzabc")
    try await f.fs.createFile(at: unknown)
    try await f.fs.write(Data([5, 6]), at: 0, to: unknown, priority: .visible)
    let copied = await f.service.perform(.transfer([unknown], into: folder, mode: .copy, conflict: .skip))
    #expect(copied.failures.isEmpty)
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/unknown.xyzabc")) == Data([5, 6]))
}


@Test func temporaryCreationFailureCleansOrRetainsJournal() async throws {
    for failCleanup in [false, true] {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let f = try await Fixture(forceCrossVolume: true, transferID: id, failAfterCreate: true, failCleanup: failCleanup)
        let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
        try await f.fs.makeDirectory(at: dest)
        try await f.fs.createFile(at: source)
        let result = await f.service.perform(.transfer([source], into: dest, mode: .move, conflict: .skip))
        let temp = "dest/.source.jpg.12345678.macview-part"
        #expect(result.failures.count == 1 && f.exists("source.jpg"))
        #expect(f.exists(temp) == failCleanup)
        let records = try JournalStore.load(f.directory.appending(path: "transfers.json")).transfers
        #expect(records.count == (failCleanup ? 1 : 0))
        if failCleanup {
            #expect(records[0].temporary == dest.appending(".source.jpg.12345678.macview-part"))
            #expect(records[0].conflict == .skip)
            let retry = try FileOperationService(fileSystem: f.fs, journalURL: f.directory.appending(path: "transfers.json"))
            #expect(await retry.resumeInterruptedTransfers() == ResumeReport(completed: 1, pending: 0, failed: 0))
            #expect(!f.exists(temp) && !f.exists("source.jpg") && f.exists("dest/source.jpg"))
        }
    }
}

@Test func temporaryNameCollisionDoesNotDeleteOrRetry() async throws {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let f = try await Fixture(forceCrossVolume: true, transferID: id)
    let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    let collision = dest.appending(".source.jpg.12345678.macview-part")
    try await f.fs.createFile(at: collision)
    try await f.fs.write(Data([42]), at: 0, to: collision, priority: .background)
    let result = await f.service.perform(.transfer([source], into: dest, mode: .move, conflict: .appendNumber))
    #expect(result.failures.count == 1 && result.changes.isEmpty && f.exists("source.jpg"))
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/.source.jpg.12345678.macview-part")) == Data([42]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory.appending(path: "dest").path).count == 1)
    #expect(try JournalStore.load(f.directory.appending(path: "transfers.json")).transfers.isEmpty)
}

@Test func recoveryUsesContentAndOriginalConflictPolicy() async throws {
    for policy in [ConflictPolicy.skip, .appendNumber] {
        let f = try await Fixture()
        let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
        try await f.fs.makeDirectory(at: dest)
        try await f.fs.createFile(at: source)
        try await f.fs.write(Data([1, 2, 3]), at: 0, to: source, priority: .background)
        let target = dest.appending("source.jpg")
        try await f.fs.createFile(at: target)
        try await f.fs.write(Data([9, 9, 9]), at: 0, to: target, priority: .background)
        let record = TransferRecord(id: UUID(), source: source, target: target, temporary: dest.appending(".old-part"), conflict: policy)
        let url = f.directory.appending(path: "transfers.json")
        try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: url)
        let report = await f.service.resumeInterruptedTransfers()
        #expect(try Data(contentsOf: f.directory.appending(path: "dest/source.jpg")) == Data([9, 9, 9]))
        if policy == .appendNumber {
            #expect(report == ResumeReport(completed: 1, pending: 0, failed: 0))
            #expect(!f.exists("source.jpg") && f.exists("dest/source (2).jpg"))
            #expect(try JournalStore.load(url).transfers.isEmpty)
        } else {
            #expect(report.completed == 0 && f.exists("source.jpg") && !f.exists("dest/source (2).jpg"))
        }
    }
}

@Test func recoveryAcceptsSameContentWithDifferentModificationTime() async throws {
    let f = try await Fixture()
    let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    let target = dest.appending("source.jpg")
    for item in [source, target] {
        try await f.fs.createFile(at: item)
        try await f.fs.write(Data([1, 2, 3]), at: 0, to: item, priority: .background)
    }
    try await f.fs.finishFile(at: source, modificationNanos: 1_600_000_000_000_000_000)
    try await f.fs.finishFile(at: target, modificationNanos: 1_700_000_000_000_000_000)
    let record = TransferRecord(id: UUID(), source: source, target: target, temporary: dest.appending(".old-part"), conflict: .skip)
    try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: f.directory.appending(path: "transfers.json"))
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 1, pending: 0, failed: 0))
    #expect(!f.exists("source.jpg") && f.exists("dest/source.jpg"))
}


@Test func legacyRecordDefaultsToSafeConflictBehavior() async throws {
    let f = try await Fixture()
    let source = f.root.appending("source.jpg"), dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    let record = TransferRecord(id: UUID(), source: source, target: dest.appending("source.jpg"), temporary: dest.appending(".source.jpg.macview-part"))
    let url = f.directory.appending(path: "transfers.json")
    try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: url)
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("conflict"))
    #expect(try JournalStore.load(url).transfers == [record])
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 1, pending: 0, failed: 0))
    #expect(!f.exists("source.jpg") && f.exists("dest/source.jpg"))
}

@Test func recoveryWithMissingSourceCannotVerifyExistingTarget() async throws {
    let f = try await Fixture()
    let dest = f.root.appending("dest")
    try await f.fs.makeDirectory(at: dest)
    let target = dest.appending("source.jpg")
    try await f.fs.createFile(at: target)
    let record = TransferRecord(id: UUID(), source: f.root.appending("source.jpg"), target: target, temporary: dest.appending(".old-part"), conflict: .skip)
    let url = f.directory.appending(path: "transfers.json")
    try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: url)
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 0, pending: 0, failed: 1))
    #expect(f.exists("dest/source.jpg"))
    #expect(try JournalStore.load(url).transfers.isEmpty)
}


@Test func transferModesAndConflictPoliciesUndoAndRedo() async throws {
    for mode in [TransferMode.move, .copy] {
        for policy in [ConflictPolicy.skip, .appendNumber] {
            let f = try await Fixture()
            let source = f.root.appending("a.jpg"), dest = f.root.appending("dest")
            try await f.fs.makeDirectory(at: dest)
            try await f.fs.createFile(at: source)
            let data = Data([1, 5, 9])
            try await f.fs.write(data, at: 0, to: source, priority: .background)
            if policy == .appendNumber {
                try await f.fs.createFile(at: dest.appending("a.jpg"))
                try await f.fs.write(Data([8]), at: 0, to: dest.appending("a.jpg"), priority: .background)
            }
            let target = policy == .appendNumber ? "dest/a (2).jpg" : "dest/a.jpg"
            let result = await f.service.perform(.transfer([source], into: dest, mode: mode, conflict: policy))
            #expect(result.failures.isEmpty && result.changes.count == 1 && f.exists(target))
            #expect(f.exists("a.jpg") == (mode == .copy))
            #expect(try Data(contentsOf: f.directory.appending(path: target)) == data)
            let undo = await f.service.perform(try #require(result.inverse))
            #expect(undo.failures.isEmpty && f.exists("a.jpg") && !f.exists(target))
            #expect(try Data(contentsOf: f.directory.appending(path: "a.jpg")) == data)
            let redo = await f.service.perform(try #require(undo.inverse))
            #expect(redo.failures.isEmpty && f.exists(target) && f.exists("a.jpg") == (mode == .copy))
            #expect(try Data(contentsOf: f.directory.appending(path: target)) == data)
            if policy == .appendNumber { #expect(try Data(contentsOf: f.directory.appending(path: "dest/a.jpg")) == Data([8])) }
        }
    }
}

@Test func relocateAndRemoveEmptyDirectoryUndoAndRedo() async throws {
    let f = try await Fixture()
    let source = f.root.appending("a.jpg"), target = f.root.appending("b.jpg")
    try await f.fs.createFile(at: source)
    try await f.fs.write(Data([1, 2]), at: 0, to: source, priority: .background)
    let moved = await f.service.perform(.relocate([Relocation(source: source, target: target)]))
    #expect(moved.failures.isEmpty && !f.exists("a.jpg") && f.exists("b.jpg"))
    let undoMove = await f.service.perform(try #require(moved.inverse))
    #expect(undoMove.failures.isEmpty && f.exists("a.jpg") && !f.exists("b.jpg"))
    let redoMove = await f.service.perform(try #require(undoMove.inverse))
    #expect(redoMove.failures.isEmpty && !f.exists("a.jpg") && f.exists("b.jpg"))
    #expect(try Data(contentsOf: f.directory.appending(path: "b.jpg")) == Data([1, 2]))
    let folder = f.root.appending("empty")
    try await f.fs.makeDirectory(at: folder)
    let removed = await f.service.perform(.removeEmptyDirectory(folder))
    #expect(removed.failures.isEmpty && !f.exists("empty"))
    let undoRemove = await f.service.perform(try #require(removed.inverse))
    #expect(undoRemove.failures.isEmpty && f.exists("empty"))
    let redoRemove = await f.service.perform(try #require(undoRemove.inverse))
    #expect(redoRemove.failures.isEmpty && !f.exists("empty"))
}


@Test func legacyAmbiguousTemporaryIsLeftUntouched() async throws {
    let f = try await Fixture()
    let dest = f.root.appending("dest"), source = f.root.appending("source.jpg")
    try await f.fs.makeDirectory(at: dest)
    let target = dest.appending("source.jpg"), temporary = dest.appending(".source.jpg.macview-part")
    for (location, bytes) in [(source, Data([1])), (target, Data([2])), (temporary, Data([3]))] {
        try await f.fs.createFile(at: location)
        try await f.fs.write(bytes, at: 0, to: location, priority: .background)
    }
    let record = TransferRecord(id: UUID(), source: source, target: target, temporary: temporary)
    let url = f.directory.appending(path: "transfers.json")
    try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: url)
    let originalJournal = try Data(contentsOf: url)
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 0, pending: 1, failed: 0))
    #expect(try Data(contentsOf: f.directory.appending(path: "source.jpg")) == Data([1]))
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/source.jpg")) == Data([2]))
    #expect(try Data(contentsOf: f.directory.appending(path: "dest/.source.jpg.macview-part")) == Data([3]))
    #expect(try Data(contentsOf: url) == originalJournal)
}

@Test func legacyRestartUsesIDTemporaryBeforeCreatingIt() async throws {
    let f = try await Fixture(failAfterCreate: true, failCleanup: true)
    let dest = f.root.appending("dest"), source = f.root.appending("source.jpg")
    try await f.fs.makeDirectory(at: dest)
    try await f.fs.createFile(at: source)
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let record = TransferRecord(id: id, source: source, target: dest.appending("source.jpg"), temporary: dest.appending(".source.jpg.macview-part"))
    let url = f.directory.appending(path: "transfers.json")
    try JournalStore.save(TransferJournal(version: 1, transfers: [record]), to: url)
    #expect(await f.service.resumeInterruptedTransfers() == ResumeReport(completed: 0, pending: 0, failed: 1))
    let updated = try #require(JournalStore.load(url).transfers.first)
    #expect(updated.temporary == dest.appending(".source.jpg.12345678.macview-part"))
    #expect(f.exists("source.jpg") && f.exists("dest/.source.jpg.12345678.macview-part"))
    #expect(!f.exists("dest/.source.jpg.macview-part"))
    let retry = try FileOperationService(fileSystem: f.fs, journalURL: url)
    #expect(await retry.resumeInterruptedTransfers() == ResumeReport(completed: 1, pending: 0, failed: 0))
    #expect(!f.exists("source.jpg") && f.exists("dest/source.jpg"))
}
