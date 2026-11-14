import Foundation
import CryptoKit
import MVFoundation
import MVIO
import Synchronization

private actor OperationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

public final class FileOperationService: Sendable {
    let fileSystem: FileSystemProvider
    let journalURL: URL
    private let forceCrossVolume: Bool
    private let corruptCopy: Bool
    private let isNetwork: @Sendable (Location) throws -> Bool
    private let volumeRoot: @Sendable (Location) throws -> Location
    private let networkRoots: @Sendable () -> [Location]
    private let trash: @Sendable (Location) async throws -> Location
    private let gate = OperationGate()
    private let transferID: @Sendable () -> UUID
    private let createTemporary: @Sendable (Location) async throws -> Void
    private let removeTemporary: @Sendable (Location) async throws -> Void
    private let observers = Mutex<[UUID: AsyncStream<[FileChange]>.Continuation]>([:])

    public convenience init(fileSystem: FileSystemProvider, journalURL: URL) throws {
        try self.init(fileSystem: fileSystem, journalURL: journalURL, isNetwork: { try fileSystem.isNetworkVolume($0) }, volumeRoot: { try fileSystem.volumeRoot(of: $0) }, networkRoots: { fileSystem.mountedNetworkRoots() }, trash: { try await fileSystem.moveToTrash($0) })
    }
    init(fileSystem: FileSystemProvider, journalURL: URL, forceCrossVolume: Bool = false, corruptCopy: Bool = false, transferID: @escaping @Sendable () -> UUID = { UUID() }, createTemporary: (@Sendable (Location) async throws -> Void)? = nil, removeTemporary: (@Sendable (Location) async throws -> Void)? = nil, isNetwork: @escaping @Sendable (Location) throws -> Bool, volumeRoot: @escaping @Sendable (Location) throws -> Location, networkRoots: @escaping @Sendable () -> [Location], trash: @escaping @Sendable (Location) async throws -> Location) throws {
        self.fileSystem = fileSystem; self.journalURL = journalURL; self.isNetwork = isNetwork
        self.forceCrossVolume = forceCrossVolume; self.corruptCopy = corruptCopy
        self.transferID = transferID
        self.createTemporary = createTemporary ?? { try await fileSystem.createFile(at: $0) }
        self.removeTemporary = removeTemporary ?? { try await fileSystem.remove($0) }
        self.volumeRoot = volumeRoot; self.networkRoots = networkRoots; self.trash = trash
    }
    public func changes() -> AsyncStream<[FileChange]> {
        AsyncStream { continuation in
            let id = UUID()
            observers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.observers.withLock { _ = $0.removeValue(forKey: id) } }
        }
    }
    public func perform(_ operation: FileOperation, progress: (@Sendable (FileProgress) -> Void)? = nil) async -> FileOperationResult {
        await gate.acquire()
        let result = Task.isCancelled ? FileOperationResult() : await execute(operation, progress: progress)
        if !result.changes.isEmpty { observers.withLock { $0.values.forEach { $0.yield(result.changes) } } }
        await gate.release()
        return result
    }
    public func resumeInterruptedTransfers() async -> ResumeReport {
        await gate.acquire()
        let (report, changes) = await resumeTransfers()
        if !changes.isEmpty { observers.withLock { $0.values.forEach { $0.yield(changes) } } }
        await gate.release()
        return report
    }
    public func recycleBins() async -> [RecycleBin] {
        var bins: [RecycleBin] = []
        for root in networkRoots() {
            let bin = root.appending(".macview-trash")
            do {
                guard try await fileSystem.entry(at: bin).kind == .directory else { continue }
                let entries = try await children(bin)
                bins.append(RecycleBin(location: bin, batchCount: entries.filter { $0.kind == .directory }.count))
            } catch { continue }
        }
        return bins
    }

    private struct Outcome {
        var changes: [FileChange] = []
        var inverses: [FileOperation] = []
        var skipped: [Location] = []
        var failures: [FileFailure] = []
        var irreversible = false
        var result: FileOperationResult {
            let inverse: FileOperation? = irreversible || inverses.isEmpty ? nil : (inverses.count == 1 ? inverses[0] : .sequence(inverses.reversed()))
            return FileOperationResult(changes: changes, inverse: inverse, skipped: skipped, failures: failures)
        }
        mutating func merge(_ result: FileOperationResult, irreversible: Bool = false) {
            changes += result.changes; skipped += result.skipped; failures += result.failures
            if let inverse = result.inverse { inverses.append(inverse) }
            else if irreversible && !result.changes.isEmpty { self.irreversible = true }
        }
    }
    private func execute(_ operation: FileOperation, progress: (@Sendable (FileProgress) -> Void)?) async -> FileOperationResult {
        switch operation {
        case let .sequence(operations):
            var outcome = Outcome()
            for child in operations {
                if Task.isCancelled { break }
                let result = await execute(child, progress: progress)
                outcome.merge(result, irreversible: true)
                if result.changes.isEmpty && !result.failures.isEmpty { break }
            }
            return outcome.result
        case let .delete(locations): return await batch(locations, progress: progress) { entry, type, context in
            let target: Location
            if try self.isNetwork(entry.location) {
                let root = try self.volumeRoot(entry.location)
                let batch: Location
                if let existing = context.bins[root] { batch = existing }
                else {
                    do { batch = try await self.createRecycleBatch(root); context.bins[root] = batch }
                    catch { throw FileOpsError.recycleUnavailable(String(describing: error)) }
                }
                var number = 1
                while true {
                    let candidate = batch.appending(Self.numberedName(entry.name, number: number, directory: type == .directory))
                    do { try await self.fileSystem.rename(entry.location, to: candidate, exclusive: true); target = candidate; break }
                    catch IOError.alreadyExists { number += 1 }
                }
            } else { target = try await self.trash(entry.location) }
            return (.removed(entry.location), .relocate([Relocation(source: target, target: entry.location)]))
        }
        case let .deletePermanently(locations):
            var result = await batch(locations, progress: progress) { entry, _, _ in
                try await self.removeTree(entry.location)
                return (.removed(entry.location), nil)
            }
            result.inverse = nil
            return result
        case let .rename(source, name):
            return await batch([source], progress: progress) { entry, type, _ in
                try Self.validate(name)
                guard let parent = source.parent else { throw FileOpsError.readOnly }
                let target = parent.appending(name)
                try await self.fileSystem.rename(source, to: target, exclusive: true)
                return (.moved(from: source, to: Self.relocated(entry, to: target, type: type)), .relocate([Relocation(source: target, target: source)]))
            }
        case let .transfer(sources, folder, mode, conflict):
            do { try Self.validateLocation(folder) } catch { return FileOperationResult(failures: sources.map { FileFailure(location: $0, error: error) }) }
            return await batch(sources, progress: progress) { entry, type, context in
                if type == .directory && folder.hasPrefix(entry.location) { throw FileOpsError.intoItself }
                var number = 1
                while true {
                    let target = folder.appending(Self.numberedName(entry.name, number: number, directory: type == .directory))
                    do {
                        var destination = target
                        if mode == .move {
                            do {
                                if self.forceCrossVolume { throw IOError.crossVolume }
                                try await self.fileSystem.rename(entry.location, to: target, exclusive: true)
                            } catch IOError.crossVolume {
                                destination = try await self.copy(entry, to: target, moving: true, conflict: conflict, number: number, progress: context.advance)
                            }
                            return (.moved(from: entry.location, to: Self.relocated(entry, to: destination, type: type)), .relocate([Relocation(source: destination, target: entry.location)]))
                        }
                        destination = try await self.copy(entry, to: target, conflict: conflict, number: number, progress: context.advance)
                        return (.added(Self.relocated(entry, to: destination, type: type)), .delete([destination]))
                    } catch IOError.alreadyExists {
                        if conflict == .skip { throw Skipped() }
                        number += 1
                    }
                }
            }
        case let .relocate(relocations):
            let targets = Dictionary(relocations.map { ($0.source, $0.target) }, uniquingKeysWith: { first, _ in first })
            return await batch(relocations.map(\.source), progress: progress) { entry, type, context in
                let target = targets[entry.location]!
                try Self.validateLocation(target)
                if type == .directory && target.hasPrefix(entry.location) { throw FileOpsError.intoItself }
                do {
                    if self.forceCrossVolume { throw IOError.crossVolume }
                    try await self.fileSystem.rename(entry.location, to: target, exclusive: true)
                } catch IOError.crossVolume {
                    _ = try await self.copy(entry, to: target, moving: true, progress: context.advance)
                }
                return (.moved(from: entry.location, to: Self.relocated(entry, to: target, type: type)), .relocate([Relocation(source: target, target: entry.location)]))
            }
        case let .makeDirectory(parent, name):
            do {
                try Self.validateLocation(parent); try Self.validate(name)
                let location = parent.appending(name)
                try await fileSystem.makeDirectory(at: location)
                let entry = try await fileSystem.entry(at: location)
                progress?(FileProgress(completedItems: 1, totalItems: 1))
                return FileOperationResult(changes: [.added(entry)], inverse: .removeEmptyDirectory(location))
            } catch { return FileOperationResult(failures: [FileFailure(location: parent, error: error)]) }
        case let .removeEmptyDirectory(location):
            return await batch([location], progress: progress) { entry, type, _ in
                guard type == .directory, let parent = location.parent else { throw IOError.unsupported(location) }
                try await self.fileSystem.remove(location)
                return (.removed(location), .makeDirectory(in: parent, name: entry.name))
            }
        }
    }

    private final class BatchContext {
        var bins: [Location: Location] = [:]
        var state: FileProgress
        var currentBytes: Int64 = 0
        let callback: (@Sendable (FileProgress) -> Void)?
        init(state: FileProgress, callback: (@Sendable (FileProgress) -> Void)?) { self.state = state; self.callback = callback }
        func advance(_ count: Int64) {
            currentBytes += count
            state.completedBytes += count
            callback?(state)
        }
        func complete(_ bytes: Int64) {
            state.completedItems += 1
            state.completedBytes += max(0, bytes - currentBytes)
            currentBytes = 0
            callback?(state)
        }
        func discard() {
            state.completedBytes -= currentBytes
            currentBytes = 0
            callback?(state)
        }
    }
    private struct Skipped: Error {}
    private struct TemporaryCollision: Error { let error: IOError }
    private func batch(_ locations: [Location], progress: (@Sendable (FileProgress) -> Void)?, body: (Entry, FileSystemItemType, BatchContext) async throws -> (FileChange, FileOperation?)) async -> FileOperationResult {
        var outcome = Outcome()
        var entries: [(Location, Result<(Entry, FileSystemItemType, Int64), any Error>)] = []
        for location in locations {
            if Task.isCancelled { break }
            do {
                try Self.validateLocation(location)
                guard location.parent != nil else { throw IOError.unsupported(location) }
                let (entry, type) = try await fileSystem.itemWithoutFollowingLinks(at: location)
                guard type != .other else { throw IOError.unsupported(location) }
                entries.append((location, .success((entry, type, try await treeBytes(entry)))))
            } catch { entries.append((location, .failure(error))) }
        }
        let total = entries.reduce(Int64(0)) { sum, pair in
            if case let .success((_, _, size)) = pair.1 { return sum + size }; return sum
        }
        let context = BatchContext(state: FileProgress(totalItems: locations.count, totalBytes: total), callback: progress)
        progress?(context.state)
        for (location, result) in entries {
            if Task.isCancelled { break }
            do {
                let (entry, type, size) = try result.get()
                let (change, inverse) = try await body(entry, type, context)
                outcome.changes.append(change)
                if let inverse { outcome.inverses.append(inverse) } else { outcome.irreversible = true }
                context.complete(size)
            } catch is Skipped { context.discard(); outcome.skipped.append(location) }
            catch let collision as TemporaryCollision { context.discard(); outcome.failures.append(FileFailure(location: location, error: collision.error)) }
            catch { context.discard(); outcome.failures.append(FileFailure(location: location, error: error)) }
        }
        return outcome.result
    }
    private static func validateLocation(_ location: Location) throws {
        guard location.layers.count == 1 else { throw FileOpsError.readOnly }
        if case .plugin = location.root { throw FileOpsError.readOnly }
    }
    private static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw FileOpsError.invalidName(name) }
    }
    private static func relocated(_ entry: Entry, to location: Location, type: FileSystemItemType = .regular) -> Entry {
        var entry = entry
        entry.identity.location = location
        entry.name = location.name
        if type == .symbolicLink { entry.kind = .other }
        else if entry.kind != .directory { entry.kind = EntryKind(fileName: location.name) }
        return entry
    }
    private static func numberedName(_ name: String, number: Int, directory: Bool) -> String {
        guard number > 1 else { return name }
        if !directory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[..<dot]) + " (\(number))" + String(name[dot...])
        }
        return name + " (\(number))"
    }
    private func children(_ location: Location) async throws -> [Entry] {
        var all: [Entry] = []
        for try await batch in fileSystem.children(of: location, priority: .background) { all += batch }
        return all
    }
    private func treeBytes(_ entry: Entry) async throws -> Int64 {
        let type = try await fileSystem.itemWithoutFollowingLinks(at: entry.location).type
        guard type != .other else { throw IOError.unsupported(entry.location) }
        guard type == .directory else { return type == .regular ? max(0, entry.size) : 0 }
        var sum: Int64 = 0
        for child in try await children(entry.location) { sum += try await treeBytes(child) }
        return sum
    }
    private func validateCopyTree(_ entry: Entry) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        let type = try await fileSystem.itemWithoutFollowingLinks(at: entry.location).type
        guard type == .regular || type == .directory else { throw IOError.unsupported(entry.location) }
        if type == .directory {
            for child in try await children(entry.location) { try await validateCopyTree(child) }
        }
    }
    private func removeTree(_ location: Location, temporaryRoot: Bool = false) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        let type = try await fileSystem.itemWithoutFollowingLinks(at: location).type
        guard type != .other else { throw IOError.unsupported(location) }
        if type == .directory {
            for child in try await children(location) { try await removeTree(child.location) }
        }
        if temporaryRoot { try await removeTemporary(location) }
        else { try await fileSystem.remove(location) }
    }
    private func createRecycleBatch(_ root: Location) async throws -> Location {
        let trash = root.appending(".macview-trash")
        do { try await fileSystem.makeDirectory(at: trash) } catch IOError.alreadyExists {}
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        while true {
            let suffix = String(UUID().uuidString.prefix(4)).lowercased()
            let batch = trash.appending("\(timestamp)-\(suffix)")
            do { try await fileSystem.makeDirectory(at: batch); return batch } catch IOError.alreadyExists { continue }
        }
    }
    /// 目标先写入独立临时项，逐文件读回校验，再原子改名。跨卷移动先持久化记录。
    private func copy(_ entry: Entry, to target: Location, moving: Bool = false, existingRecord: TransferRecord? = nil, conflict: ConflictPolicy? = nil, number startingNumber: Int = 1, progress: ((Int64) -> Void)? = nil) async throws -> Location {
        try await validateCopyTree(entry)
        let type = try await fileSystem.itemWithoutFollowingLinks(at: entry.location).type
        guard let parent = target.parent else { throw FileOpsError.readOnly }
        let policy = existingRecord?.conflict ?? conflict
        var selectedTarget = target
        var selectedNumber = startingNumber
        if existingRecord != nil && policy == .appendNumber {
            let extensionStart = type == .directory ? nil : entry.name.lastIndex(of: ".")
            let validExtension = extensionStart.flatMap { $0 == entry.name.startIndex ? nil : $0 }
            let stem = validExtension.map { String(entry.name[..<$0]) } ?? entry.name
            let suffix = validExtension.map { String(entry.name[$0...]) } ?? ""
            let prefix = stem + " ("
            let ending = ")" + suffix
            if target.name.hasPrefix(prefix), target.name.hasSuffix(ending), target.name.count >= prefix.count + ending.count {
                let digits = target.name.dropFirst(prefix.count).dropLast(ending.count)
                if let number = Int(digits), number >= 2 { selectedNumber = number }
            }
        }
        if moving {
            while try await exists(selectedTarget) != nil {
                guard policy == .appendNumber else { throw IOError.alreadyExists(selectedTarget) }
                selectedNumber += 1
                selectedTarget = parent.appending(Self.numberedName(entry.name, number: selectedNumber, directory: type == .directory))
            }
        }
        let id = existingRecord?.id ?? transferID()
        let temp = existingRecord?.temporary ?? parent.appending(".\(entry.name).\(id.uuidString.prefix(8).lowercased()).macview-part")
        var record = existingRecord ?? TransferRecord(id: id, source: entry.location, target: selectedTarget, temporary: temp, conflict: conflict)
        if moving {
            if existingRecord == nil { try JournalStore.update(journalURL) { $0.append(record) } }
            else if record.target != selectedTarget {
                record.target = selectedTarget
                try JournalStore.update(journalURL) { records in
                    if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
                }
            }
        }
        var temporaryMayExist = false
        var published = false
        do {
            // 只有 EEXIST 能证明该名字属于他人；其他错误可能发生在创建之后。
            temporaryMayExist = true
            do {
                if type == .directory { try await fileSystem.makeDirectory(at: temp) }
                else { try await createTemporary(temp) }
            } catch let error as IOError {
                if case .alreadyExists = error {
                    temporaryMayExist = false
                    throw TemporaryCollision(error: error)
                }
                throw error
            }
            try await copyContents(entry, type: type, to: temp, progress: progress)
            if Task.isCancelled { throw IOError.cancelled }
            var destination = selectedTarget
            var number = selectedNumber
            while true {
                do { try await fileSystem.rename(temp, to: destination, exclusive: true); break }
                catch IOError.alreadyExists {
                    guard policy == .appendNumber else { throw IOError.alreadyExists(destination) }
                    number += 1
                    destination = parent.appending(Self.numberedName(entry.name, number: number, directory: type == .directory))
                    if moving {
                        record.target = destination
                        try JournalStore.update(journalURL) { records in
                            if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record }
                        }
                    }
                }
            }
            published = true
            if moving {
                // 发布后完成删除，即使调用者取消也不留下目标存在但源未删除的无记录状态。
                try await Task.detached { try await self.removeTree(entry.location) }.value
                try JournalStore.update(journalURL) { $0.removeAll { $0.id == record.id } }
            }
            return destination
        } catch {
            if !published {
                var cleaned = true
                if temporaryMayExist {
                    let temporary = temp
                    cleaned = await Task.detached {
                        do { try await self.removeTree(temporary, temporaryRoot: true); return true }
                        catch IOError.notFound { return true }
                        catch { return false }
                    }.value
                }
                if moving && cleaned { try? JournalStore.update(journalURL) { $0.removeAll { $0.id == record.id } } }
            }
            throw error
        }
    }
    private func copyContents(_ entry: Entry, type: FileSystemItemType, to target: Location, progress: ((Int64) -> Void)?) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        if type == .directory {
            for child in try await children(entry.location) {
                let (child, childType) = try await fileSystem.itemWithoutFollowingLinks(at: child.location)
                guard childType == .regular || childType == .directory else { throw IOError.unsupported(child.location) }
                let dest = target.appending(child.name)
                if childType == .directory { try await fileSystem.makeDirectory(at: dest) }
                else { try await fileSystem.createFile(at: dest) }
                try await copyContents(child, type: childType, to: dest, progress: progress)
            }
        } else {
            let source = try await fileSystem.open(entry.location)
            var sourceHash = SHA256()
            var offset: Int64 = 0
            while offset < entry.size {
                if Task.isCancelled { throw IOError.cancelled }
                let end = min(entry.size, offset + Int64(4 << 20))
                let data = try await source.read(offset..<end, priority: .background, group: nil)
                guard !data.isEmpty else { throw IOError.corrupted(entry.location, "复制时读到文件末尾") }
                sourceHash.update(data: data)
                var output = data
                if corruptCopy && offset == 0 && !output.isEmpty { output[output.startIndex] ^= 0xff }
                try await fileSystem.write(output, at: offset, to: target, priority: .background)
                offset += Int64(data.count)
                progress?(Int64(data.count))
            }
            try await fileSystem.finishFile(at: target, modificationNanos: entry.identity.modificationNanos)
            let written = try await fileSystem.itemWithoutFollowingLinks(at: target)
            guard written.type == .regular, written.entry.size == entry.size else { throw FileOpsError.verificationFailed }
            var targetHash = SHA256()
            offset = 0
            while offset < entry.size {
                if Task.isCancelled { throw IOError.cancelled }
                let end = min(entry.size, offset + Int64(4 << 20))
                let data = try await fileSystem.readUncached(target, range: offset..<end, priority: .background)
                guard !data.isEmpty else { throw FileOpsError.verificationFailed }
                targetHash.update(data: data)
                offset += Int64(data.count)
            }
            guard sourceHash.finalize() == targetHash.finalize() else { throw FileOpsError.verificationFailed }
        }
    }
    private func exists(_ location: Location) async throws -> Entry? {
        do { return try await fileSystem.itemWithoutFollowingLinks(at: location).entry }
        catch IOError.notFound { return nil }
    }
    /// 目标可能由另一个进程创建；确认剩余源文件已存在且内容一致，才在恢复时删除源。
    private func verifyRecoverySource(_ source: Entry, in target: Entry) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        let sourceType = try await fileSystem.itemWithoutFollowingLinks(at: source.location).type
        let targetType = try await fileSystem.itemWithoutFollowingLinks(at: target.location).type
        guard sourceType == targetType, sourceType == .regular || sourceType == .directory else { throw FileOpsError.verificationFailed }
        if sourceType == .directory {
            let destinations = Dictionary(uniqueKeysWithValues: try await children(target.location).map { ($0.name, $0) })
            for child in try await children(source.location) {
                guard let counterpart = destinations[child.name] else { throw FileOpsError.verificationFailed }
                try await verifyRecoverySource(child, in: counterpart)
            }
        } else {
            guard source.size == target.size else { throw FileOpsError.verificationFailed }
            let input = try await fileSystem.open(source.location)
            var sourceHash = SHA256(), targetHash = SHA256()
            var offset: Int64 = 0
            while offset < source.size {
                if Task.isCancelled { throw IOError.cancelled }
                let end = min(source.size, offset + Int64(4 << 20))
                let a = try await input.read(offset..<end, priority: .background, group: nil)
                let b = try await fileSystem.readUncached(target.location, range: offset..<end, priority: .background)
                guard !a.isEmpty, a.count == b.count else { throw FileOpsError.verificationFailed }
                sourceHash.update(data: a); targetHash.update(data: b)
                offset += Int64(a.count)
            }
            guard sourceHash.finalize() == targetHash.finalize() else { throw FileOpsError.verificationFailed }
        }
    }
    private func resumeTransfers() async -> (ResumeReport, [FileChange]) {
        var report = ResumeReport()
        var changes: [FileChange] = []
        let records: [TransferRecord]
        do { records = try JournalStore.load(journalURL).transfers }
        catch { report.failed += 1; return (report, changes) }
        for record in records {
            if Task.isCancelled { report.pending += 1; continue }
            do {
                try Self.validateLocation(record.source)
                try Self.validateLocation(record.target)
                try Self.validateLocation(record.temporary)
                let temporary = try await exists(record.temporary)
                let target = try await exists(record.target)
                let source = try await exists(record.source)
                if temporary != nil {
                    try await removeTree(record.temporary, temporaryRoot: true)
                }
                if temporary == nil, let target, let source {
                    let matches: Bool
                    do { try await verifyRecoverySource(source, in: target); matches = true }
                    catch IOError.cancelled { throw IOError.cancelled }
                    catch { matches = false }
                    if matches {
                        try await removeTree(record.source)
                        try JournalStore.update(journalURL) { $0.removeAll { $0.id == record.id } }
                        changes.append(.moved(from: record.source, to: target))
                        report.completed += 1
                        continue
                    }
                }
                if let source {
                    let destination = try await copy(source, to: record.target, moving: true, existingRecord: record)
                    let type = try await fileSystem.itemWithoutFollowingLinks(at: destination).type
                    changes.append(.moved(from: record.source, to: Self.relocated(source, to: destination, type: type)))
                    report.completed += 1
                } else {
                    try JournalStore.update(journalURL) { $0.removeAll { $0.id == record.id } }
                    report.failed += 1
                }
            } catch IOError.volumeUnavailable { report.pending += 1 }
            catch IOError.volumeDegraded { report.pending += 1 }
            catch IOError.timeout { report.pending += 1 }
            catch IOError.cancelled { report.pending += 1 }
            catch { report.failed += 1 }
        }
        return (report, changes)
    }
}
