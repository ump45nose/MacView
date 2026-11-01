import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia

struct PipelineContent: Sendable {
    var identity: ContentIdentity
    var data: Data
    var metadata: ImageMetadata?
}

/// 在一份顺序读取的前缀上满足文件头和完整文件的消费者。
actor ContentWork {
    struct Waiter {
        var full: Bool
        var metadata: Bool
        var priority: IOPriority
        var continuation: CheckedContinuation<PipelineContent, any Error>
    }
    private let requested: ContentIdentity
    private let sources: any SourceRegistry
    private let caches: PipelineCaches
    private let scheduler: IOScheduler?
    private let completed: @Sendable () -> Void
    private let group = IORequestGroup()
    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var result: Result<PipelineContent, any Error>?
    private var source: (any ByteSource)?

    init(identity: ContentIdentity, sources: any SourceRegistry, caches: PipelineCaches, completed: @escaping @Sendable () -> Void) {
        requested = identity
        self.sources = sources
        self.caches = caches
        scheduler = (sources as? FileSourceRegistry)?.scheduler
        self.completed = completed
    }

    func value(full: Bool, metadata: Bool, consumer: UUID, priority: IOPriority) async throws -> PipelineContent {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if cancelled.remove(consumer) != nil { continuation.resume(throwing: CancellationError()); return }
                if let result {
                    switch result {
                    case let .success(value) where (!full || Int64(value.data.count) == value.identity.size) && (!metadata || value.metadata != nil):
                        continuation.resume(returning: value)
                        return
                    case let .failure(error):
                        continuation.resume(throwing: error)
                        return
                    case .success: self.result = nil
                    }
                }
                waiters[consumer] = Waiter(full: full, metadata: metadata, priority: priority, continuation: continuation)
                updatePriority()
                if task == nil { task = Task { await run() } }
            }
        } onCancel: { Task { await self.cancel(consumer) } }
    }

    func setPriority(_ priority: IOPriority, consumer: UUID) {
        waiters[consumer]?.priority = priority
        updatePriority()
    }

    private func updatePriority() {
        scheduler?.setPriority(waiters.values.map(\.priority).max() ?? .background, for: group)
    }

    private func cancel(_ consumer: UUID) {
        guard let waiter = waiters.removeValue(forKey: consumer) else { cancelled.insert(consumer); return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty {
            scheduler?.cancel(group)
            task?.cancel()
            completed()
        } else { updatePriority() }
    }

    private func run() async {
        do {
            let source: any ByteSource
            if let opened = self.source { source = opened }
            else {
                source = try await sources.provider(for: requested.location).open(requested.location)
                self.source = source
            }
            let identity = source.identity
            var data = caches.raw.value(for: identity.cacheKey) ?? Data()
            var metadata: ImageMetadata?
            var headerEnd = min(identity.size, Int64(MediaProbe.initialHeaderLength))
            while !waiters.isEmpty {
                try Task.checkCancellation()
                let needsMetadata = waiters.values.contains { $0.metadata }
                if needsMetadata, metadata == nil, Int64(data.count) >= headerEnd {
                    switch try MediaProbe.image(data, isComplete: Int64(data.count) >= identity.size) {
                    case let .metadata(value):
                        metadata = value
                        if let parent = identity.location.parent { try await caches.metadata.store([identity.cacheKey: value], in: parent) }
                    case let .needsMoreData(next): headerEnd = min(identity.size, Int64(next ?? Int(identity.size)))
                    }
                }
                let content = PipelineContent(identity: identity, data: data, metadata: metadata)
                let ready = waiters.filter { (!$0.value.full || Int64(data.count) >= identity.size) && (!$0.value.metadata || metadata != nil) }
                for (id, waiter) in ready { waiters[id] = nil; waiter.continuation.resume(returning: content) }
                if waiters.isEmpty {
                    result = .success(content)
                    break
                }
                let full = waiters.values.contains { $0.full }
                let end = full ? min(identity.size, Int64(data.count) + (4 << 20)) : headerEnd
                guard end > Int64(data.count) else { throw MediaError.decodeFailed("文件在读取完成前结束") }
                let priority = waiters.values.map(\.priority).max() ?? .background
                let part = try await source.read(Int64(data.count)..<end, priority: priority, group: group)
                guard !part.isEmpty else { throw MediaError.decodeFailed("文件在读取完成前结束") }
                data.append(part)
                // 前缀也有用；只有长度等于 identity.size 时才当成完整文件。
                caches.raw.insert(data, for: identity.cacheKey, cost: Int64(data.count))
            }
        } catch {
            result = .failure(error)
            for waiter in waiters.values { waiter.continuation.resume(throwing: error) }
            waiters.removeAll()
        }
        task = nil
        completed()
    }
}
