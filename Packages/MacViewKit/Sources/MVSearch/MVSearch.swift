import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import Synchronization

public struct IndexProgress: Sendable, Hashable {
    public var phase: Phase
    public var listed: Int
    public var probed: Int
    public var toProbe: Int
    public var failures: Int

    public enum Phase: Sendable, Hashable {
        case listing, probing, finished
    }

    public init(phase: Phase, listed: Int = 0, probed: Int = 0, toProbe: Int = 0, failures: Int = 0) {
        self.phase = phase
        self.listed = listed
        self.probed = probed
        self.toProbe = toProbe
        self.failures = failures
    }
}

/// 递归枚举目录树写入目录缓存与搜索索引，随后低优先级增量探测未缓存或已变更图片的元数据。
public final class FolderIndexer: Sendable {
    private static let recycleDirectoryNames: Set<String> = [
        ".trash", ".trashes", "#recycle", "@recycle", "$recycle.bin",
    ]

    private let sources: any SourceRegistry
    private let directories: DirectoryCache
    private let metadata: MetadataIndex
    private let volumeQueue = VolumeQueue()

    public init(sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex) {
        self.sources = sources
        self.directories = directories
        self.metadata = metadata
    }

    /// 取消即停；同一卷上再次调用时排在前一个之后。
    public func index(_ folder: Location) -> AsyncThrowingStream<IndexProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                do {
                    try await volumeQueue.acquire(folder.root)
                    do {
                        try Task.checkCancellation()
                        try await run(folder, continuation: continuation)
                        await volumeQueue.release(folder.root)
                        continuation.finish()
                    } catch {
                        await volumeQueue.release(folder.root)
                        throw error
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as IOError where error == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ folder: Location,
        continuation: AsyncThrowingStream<IndexProgress, any Error>.Continuation
    ) async throws {
        let root = folder.root
        let volumeError = VolumeErrorBox()
        let healthTask = Task {
            for await states in sources.volumeHealth() {
                guard let health = states.first(where: { $0.root == root }) else { continue }
                switch health.state {
                case .healthy:
                    break
                case .degraded:
                    volumeError.set(.volumeDegraded(root))
                    return
                case .unavailable:
                    volumeError.set(.volumeUnavailable(root))
                    return
                }
            }
        }
        defer { healthTask.cancel() }

        func checkVolume() throws {
            if let error = volumeError.current {
                throw error
            }
        }

        // 第一步：递归枚举目录，写入 DirectoryCache（同步维护 search_entries）。
        var queue: [Location] = [folder]
        var head = 0
        var listed = 0
        var failures = 0
        var images: [Entry] = []

        while head < queue.count {
            try Task.checkCancellation()
            try checkVolume()
            let current = queue[head]
            head += 1
            let isRoot = (head == 1)

            do {
                let provider = try sources.provider(for: current)
                var rawEntries: [Entry] = []
                for try await batch in provider.children(of: current, priority: .background) {
                    try Task.checkCancellation()
                    try checkVolume()
                    rawEntries.append(contentsOf: batch)
                }
                let filtered = rawEntries.filter { !Self.shouldSkip($0) }
                _ = try await directories.update(current, listing: DirectoryListing(entries: filtered))
                listed += filtered.count
                for entry in filtered {
                    switch entry.kind {
                    case .directory:
                        queue.append(entry.location)
                    case .image:
                        images.append(entry)
                    case .archive, .video, .other:
                        break
                    }
                }
                continuation.yield(IndexProgress(phase: .listing, listed: listed, probed: 0, toProbe: 0, failures: failures))
            } catch {
                if Self.isCancellation(error) { throw error }
                if Self.isVolumeError(error) { throw error }
                try checkVolume()
                if isRoot { throw error }
                failures += 1
                continuation.yield(IndexProgress(phase: .listing, listed: listed, probed: 0, toProbe: 0, failures: failures))
            }
        }

        // 第二步：增量探测元数据缺失或 identity 变更的图片。
        try Task.checkCancellation()
        try checkVolume()

        let existing = try await metadata.values(for: images.map(\.identity.cacheKey))
        let pending = images.filter { existing[$0.identity.cacheKey] == nil }
        let toProbe = pending.count
        var probed = 0

        continuation.yield(IndexProgress(phase: .probing, listed: listed, probed: 0, toProbe: toProbe, failures: failures))

        if !pending.isEmpty {
            let maxConcurrency = (root == .local) ? 8 : 4
            let flushThreshold = min(32, max(1, toProbe / 10))
            var pendingStore: [Location: [String: ImageMetadata]] = [:]
            var pendingStoreCount = 0

            func flushMetadata() async throws {
                guard !pendingStore.isEmpty else { return }
                let batch = pendingStore
                pendingStore.removeAll(keepingCapacity: true)
                pendingStoreCount = 0
                for (container, values) in batch {
                    try await metadata.store(values, in: container)
                }
            }

            enum ProbeOutcome: Sendable {
                case success(Entry, ImageMetadata)
                case failure
                case volumeError(any Error)
                case cancelled(any Error)
            }

            var fatalError: (any Error)?
            await withTaskGroup(of: ProbeOutcome.self) { group in
                var nextIndex = 0

                func enqueueOne() {
                    guard nextIndex < pending.count else { return }
                    let entry = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { [self] in
                        do {
                            try Task.checkCancellation()
                            if let error = volumeError.current { return .volumeError(error) }
                            let value = try await self.probeImage(entry, volumeError: volumeError)
                            return .success(entry, value)
                        } catch {
                            if Self.isCancellation(error) { return .cancelled(error) }
                            if Self.isVolumeError(error) { return .volumeError(error) }
                            if let error = volumeError.current { return .volumeError(error) }
                            return .failure
                        }
                    }
                }

                for _ in 0..<min(maxConcurrency, pending.count) {
                    enqueueOne()
                }

                while let outcome = await group.next() {
                    switch outcome {
                    case let .success(entry, value):
                        let container = entry.location.parent ?? folder
                        pendingStore[container, default: [:]][entry.identity.cacheKey] = value
                        pendingStoreCount += 1
                        probed += 1
                        if pendingStoreCount >= flushThreshold {
                            do {
                                try await flushMetadata()
                            } catch {
                                fatalError = error
                                group.cancelAll()
                                break
                            }
                            continuation.yield(IndexProgress(phase: .probing, listed: listed, probed: probed, toProbe: toProbe, failures: failures))
                        }
                    case .failure:
                        failures += 1
                        continuation.yield(IndexProgress(phase: .probing, listed: listed, probed: probed, toProbe: toProbe, failures: failures))
                    case let .volumeError(error):
                        fatalError = error
                        group.cancelAll()
                    case let .cancelled(error):
                        if fatalError == nil { fatalError = error }
                        group.cancelAll()
                    }

                    if fatalError != nil || Task.isCancelled {
                        group.cancelAll()
                    } else if let error = volumeError.current {
                        fatalError = error
                        group.cancelAll()
                    } else {
                        enqueueOne()
                    }
                }
            }

            if !pendingStore.isEmpty {
                do {
                    try await flushMetadata()
                } catch {
                    if fatalError == nil { fatalError = error }
                }
            }

            if let fatalError {
                throw fatalError
            }
            try Task.checkCancellation()
            try checkVolume()

            continuation.yield(IndexProgress(phase: .probing, listed: listed, probed: probed, toProbe: toProbe, failures: failures))
        }

        continuation.yield(IndexProgress(phase: .finished, listed: listed, probed: probed, toProbe: toProbe, failures: failures))
    }

    private func probeImage(_ entry: Entry, volumeError: VolumeErrorBox) async throws -> ImageMetadata {
        let provider = try sources.provider(for: entry.location)
        let byteSource = try await provider.open(entry.location)
        let totalSize = max(0, byteSource.identity.size)
        let maxBytes = min(totalSize, Int64(MediaProbe.headerLimit))
        var targetLength = min(maxBytes, Int64(MediaProbe.initialHeaderLength))
        var data = Data()
        data.reserveCapacity(Int(targetLength))

        while true {
            try Task.checkCancellation()
            if let error = volumeError.current { throw error }

            if Int64(data.count) < targetLength {
                let part = try await byteSource.read(Int64(data.count)..<targetLength, priority: .background, group: nil)
                if part.isEmpty { break }
                data.append(part)
            }

            let isComplete = Int64(data.count) >= totalSize
            switch try MediaProbe.image(data, isComplete: isComplete) {
            case let .metadata(value):
                return value
            case let .needsMoreData(next):
                let requested = next.map(Int64.init) ?? totalSize
                guard requested <= Int64(MediaProbe.headerLimit),
                      requested > Int64(data.count),
                      Int64(data.count) < maxBytes else {
                    throw MediaError.decodeFailed("文件头超过探测上限")
                }
                targetLength = min(maxBytes, requested)
            }
        }

        switch try MediaProbe.image(data, isComplete: true) {
        case let .metadata(value):
            return value
        case .needsMoreData:
            throw MediaError.decodeFailed("文件在读取完成前结束")
        }
    }

    static func shouldSkip(_ entry: Entry) -> Bool {
        if entry.name.hasPrefix("._") { return true }
        if entry.kind == .directory, recycleDirectoryNames.contains(entry.name.lowercased()) {
            return true
        }
        return false
    }

    private static func isVolumeError(_ error: any Error) -> Bool {
        guard let io = error as? IOError else { return false }
        switch io {
        case .volumeDegraded, .volumeUnavailable:
            return true
        default:
            return false
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let io = error as? IOError, io == .cancelled { return true }
        return false
    }
}

private final class VolumeErrorBox: Sendable {
    private let value = Mutex<IOError?>(nil)
    var current: IOError? { value.withLock { $0 } }
    func set(_ error: IOError) { value.withLock { $0 = error } }
}

/// 按卷根串行排队；等待期间可随时取消，释放时按 FIFO 移交所有权。
private actor VolumeQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var active: Set<Location.Root> = []
    private var waiters: [Location.Root: [Waiter]] = [:]

    func acquire(_ root: Location.Root) async throws {
        try Task.checkCancellation()
        if !active.contains(root) {
            active.insert(root)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(root: root, id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(root: root, id: id) }
        }
    }

    private func enqueue(root: Location.Root, id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if !active.contains(root) {
            active.insert(root)
            continuation.resume()
            return
        }
        waiters[root, default: []].append(Waiter(id: id, continuation: continuation))
    }

    private func cancel(root: Location.Root, id: UUID) {
        guard var list = waiters[root], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        if list.isEmpty {
            waiters.removeValue(forKey: root)
        } else {
            waiters[root] = list
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(_ root: Location.Root) {
        if var list = waiters[root], !list.isEmpty {
            let next = list.removeFirst()
            if list.isEmpty {
                waiters.removeValue(forKey: root)
            } else {
                waiters[root] = list
            }
            next.continuation.resume()
        } else {
            active.remove(root)
        }
    }
}
