import Foundation
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
    private let isNetwork: @Sendable (Location) throws -> Bool
    private let volumeRoot: @Sendable (Location) throws -> Location
    private let networkRoots: @Sendable () -> [Location]
    private let trash: @Sendable (Location) async throws -> Location
    private let gate = OperationGate()
    private let observers = Mutex<[UUID: AsyncStream<[FileChange]>.Continuation]>([:])

    public convenience init(fileSystem: FileSystemProvider, journalURL: URL) throws {
        try self.init(fileSystem: fileSystem, journalURL: journalURL, isNetwork: { try fileSystem.isNetworkVolume($0) }, volumeRoot: { try fileSystem.volumeRoot(of: $0) }, networkRoots: { fileSystem.mountedNetworkRoots() }, trash: { try await fileSystem.moveToTrash($0) })
    }
    init(fileSystem: FileSystemProvider, journalURL: URL, isNetwork: @escaping @Sendable (Location) throws -> Bool, volumeRoot: @escaping @Sendable (Location) throws -> Location, networkRoots: @escaping @Sendable () -> [Location], trash: @escaping @Sendable (Location) async throws -> Location) throws {
        self.fileSystem = fileSystem; self.journalURL = journalURL; self.isNetwork = isNetwork
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
    public func resumeInterruptedTransfers() async -> ResumeReport { ResumeReport() }
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
        case let .delete(locations): return await batch(locations, progress: progress) { entry, context in
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
                    let candidate = batch.appending(Self.numberedName(entry.name, number: number, directory: entry.kind == .directory))
                    do { try await self.fileSystem.rename(entry.location, to: candidate, exclusive: true); target = candidate; break }
                    catch IOError.alreadyExists { number += 1 }
                }
            } else { target = try await self.trash(entry.location) }
            return (.removed(entry.location), .relocate([Relocation(source: target, target: entry.location)]))
        }
        case let .deletePermanently(locations):
            var result = await batch(locations, progress: progress) { entry, _ in
                try await self.validateTree(entry)
                try await self.removeTree(entry.location, entry: entry)
                return (.removed(entry.location), nil)
            }
            result.inverse = nil
            return result
        case let .rename(source, name):
            return await batch([source], progress: progress) { entry, _ in
                try Self.validate(name)
                guard let parent = source.parent else { throw FileOpsError.readOnly }
                let target = parent.appending(name)
                try await self.fileSystem.rename(source, to: target, exclusive: true)
                return (.moved(from: source, to: Self.relocated(entry, to: target)), .relocate([Relocation(source: target, target: source)]))
            }
        case let .transfer(sources, folder, mode, conflict):
            do { try Self.validateLocation(folder) } catch { return FileOperationResult(failures: sources.map { FileFailure(location: $0, error: error) }) }
            return await batch(sources, progress: progress) { entry, _ in
                if entry.kind == .directory && folder.hasPrefix(entry.location) { throw FileOpsError.intoItself }
                var number = 1
                while true {
                    let name = Self.numberedName(entry.name, number: number, directory: entry.kind == .directory)
                    let target = folder.appending(name)
                    do {
                        if mode == .move {
                            try await self.fileSystem.rename(entry.location, to: target, exclusive: true)
                            return (.moved(from: entry.location, to: Self.relocated(entry, to: target)), .relocate([Relocation(source: target, target: entry.location)]))
                        }
                        try await self.copy(entry, to: target)
                        return (.added(Self.relocated(entry, to: target)), .delete([target]))
                    } catch IOError.alreadyExists {
                        if conflict == .skip { throw Skipped() }
                        number += 1
                    }
                }
            }
        case let .relocate(relocations):
            let targets = Dictionary(relocations.map { ($0.source, $0.target) }, uniquingKeysWith: { first, _ in first })
            return await batch(relocations.map(\.source), progress: progress) { entry, _ in
                let target = targets[entry.location]!
                try Self.validateLocation(target)
                if entry.kind == .directory && target.hasPrefix(entry.location) { throw FileOpsError.intoItself }
                try await self.fileSystem.rename(entry.location, to: target, exclusive: true)
                return (.moved(from: entry.location, to: Self.relocated(entry, to: target)), .relocate([Relocation(source: target, target: entry.location)]))
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
            return await batch([location], progress: progress) { entry, _ in
                guard entry.kind == .directory, let parent = location.parent else { throw IOError.unsupported(location) }
                try await self.fileSystem.remove(location)
                return (.removed(location), .makeDirectory(in: parent, name: entry.name))
            }
        }
    }

    private final class BatchContext { var bins: [Location: Location] = [:] }
    private struct Skipped: Error {}
    private func batch(_ locations: [Location], progress: (@Sendable (FileProgress) -> Void)?, body: (Entry, BatchContext) async throws -> (FileChange, FileOperation?)) async -> FileOperationResult {
        var outcome = Outcome()
        var entries: [(Location, Result<Entry, any Error>)] = []
        var listings: [Location: [Entry]] = [:]
        for location in locations {
            if Task.isCancelled { break }
            do {
                try Self.validateLocation(location)
                guard let parent = location.parent else { throw IOError.unsupported(location) }
                let listing: [Entry]
                if let cached = listings[parent] { listing = cached }
                else { listing = try await children(parent); listings[parent] = listing }
                if let item = listing.first(where: { $0.location == location }), item.kind == .other {
                    throw IOError.unsupported(location)
                }
                entries.append((location, .success(try await fileSystem.entry(at: location))))
            } catch { entries.append((location, .failure(error))) }
        }
        var state = FileProgress(totalItems: locations.count, totalBytes: entries.reduce(0) { sum, pair in
            if case let .success(entry) = pair.1 { return sum + max(0, entry.size) }; return sum
        })
        let context = BatchContext()
        progress?(state)
        for (location, result) in entries {
            if Task.isCancelled { break }
            do {
                let entry = try result.get()
                let (change, inverse) = try await body(entry, context)
                outcome.changes.append(change)
                if let inverse { outcome.inverses.append(inverse) } else { outcome.irreversible = true }
                state.completedItems += 1
                state.completedBytes += max(0, entry.size)
                progress?(state)
            } catch is Skipped { outcome.skipped.append(location) }
            catch { outcome.failures.append(FileFailure(location: location, error: error)) }
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
    private static func relocated(_ entry: Entry, to location: Location) -> Entry {
        var entry = entry
        entry.identity.location = location
        entry.name = location.name
        if entry.kind != .directory { entry.kind = EntryKind(fileName: location.name) }
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
    // MVIO 当前无法区分普通未知文件和符号链接，保守拒绝列表中的 other，避免递归删除链接目标。
    private func validateTree(_ entry: Entry) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        if entry.kind == .other { throw IOError.unsupported(entry.location) }
        if entry.kind == .directory {
            for child in try await children(entry.location) { try await validateTree(child) }
        }
    }
    private func removeTree(_ location: Location, entry knownEntry: Entry? = nil) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        let entry: Entry
        if let known = knownEntry { entry = known } else { entry = try await fileSystem.entry(at: location) }
        if entry.kind == .directory {
            for child in try await children(location) { try await removeTree(child.location, entry: child) }
        }
        try await fileSystem.remove(location)
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
    /// W1.4 在此接入带哈希校验和跨卷移动日志的复制流程。
    private func copy(_ entry: Entry, to target: Location) async throws {
        guard let parent = target.parent else { throw FileOpsError.readOnly }
        var temp = parent.appending(".\(target.name).macview-part")
        while true {
            do {
                if entry.kind == .directory { try await fileSystem.makeDirectory(at: temp) }
                else { try await fileSystem.createFile(at: temp) }
                break
            } catch IOError.alreadyExists {
                temp = parent.appending(".\(target.name).macview-part-\(String(UUID().uuidString.prefix(4)).lowercased())")
            }
        }
        do {
            try await copyContents(entry, to: temp)
            try await fileSystem.rename(temp, to: target, exclusive: true)
        } catch {
            let temporary = temp
            await Task.detached { try? await self.removeTree(temporary) }.value
            throw error
        }
    }
    private func copyContents(_ entry: Entry, to target: Location) async throws {
        if Task.isCancelled { throw IOError.cancelled }
        if entry.kind == .directory {
            for child in try await children(entry.location) {
                guard child.kind != .other else { throw IOError.unsupported(child.location) }
                let dest = target.appending(child.name)
                if child.kind == .directory { try await fileSystem.makeDirectory(at: dest) }
                else { try await fileSystem.createFile(at: dest) }
                try await copyContents(child, to: dest)
            }
        } else {
            let source = try await fileSystem.open(entry.location)
            var offset: Int64 = 0
            while offset < entry.size {
                if Task.isCancelled { throw IOError.cancelled }
                let end = min(entry.size, offset + Int64(4 << 20))
                let data = try await source.read(offset..<end, priority: .background, group: nil)
                guard !data.isEmpty else { throw IOError.corrupted(entry.location, "复制时读到文件末尾") }
                try await fileSystem.write(data, at: offset, to: target, priority: .background)
                offset += Int64(data.count)
            }
            try await fileSystem.finishFile(at: target, modificationNanos: entry.identity.modificationNanos)
        }
    }
}
