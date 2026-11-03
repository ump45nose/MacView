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
    private let lifetime: PipelineLifetime
    private let completed: @Sendable () -> Void
    private let group = IORequestGroup()
    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []
    private var task: Task<Void, any Error>?
    private var accepting = true
    private var result: Result<PipelineContent, any Error>?
    private var source: (any ByteSource)?

    init(identity: ContentIdentity, sources: any SourceRegistry, caches: PipelineCaches, lifetime: PipelineLifetime, completed: @escaping @Sendable () -> Void) {
        requested = identity
        self.sources = sources
        self.caches = caches
        self.lifetime = lifetime
        scheduler = (sources as? FileSourceRegistry)?.scheduler
        self.completed = completed
    }

    func value(full: Bool, metadata: Bool, consumer: UUID, priority: IOPriority) async throws -> PipelineContent {
        try await withTaskCancellationHandler {
            try lifetime.checkRunning()
            return try await withCheckedThrowingContinuation { continuation in
                guard accepting else { continuation.resume(throwing: CancellationError()); return }
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
                if task == nil {
                    do { task = try lifetime.start(priority: waiters.values.map(\.priority).max()?.taskPriority) { await self.run() } }
                    catch {
                        for waiter in waiters.values { waiter.continuation.resume(throwing: error) }
                        waiters.removeAll()
                        completed()
                    }
                }
            }
        } onCancel: { Task { await self.cancel(consumer) } }
    }

    func setPriority(_ priority: IOPriority, consumer: UUID) {
        waiters[consumer]?.priority = priority
        updatePriority()
    }

    private func updatePriority() {
        let priority = waiters.values.map(\.priority).max() ?? .background
        scheduler?.setPriority(priority, for: group)
        // 消费者通过续体等待，运行时不会把优先级传给读取任务；任务优先级只升不降。
        task?.escalatePriority(to: priority.taskPriority)
    }

    private func cancel(_ consumer: UUID) {
        guard let waiter = waiters.removeValue(forKey: consumer) else { cancelled.insert(consumer); return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty {
            accepting = false
            scheduler?.cancel(group)
            task?.cancel()
            completed()
        } else { updatePriority() }
    }

    private func run() async {
        do {
            try lifetime.checkRunning()
            let source: any ByteSource
            if let opened = self.source { source = opened }
            else {
                let provider = try sources.provider(for: requested.location)
                let location = requested.location
                source = try await lifetime.value { try await provider.open(location) }
                self.source = source
            }
            let identity = source.identity
            var data = caches.raw.value(for: identity.cacheKey) ?? Data()
            var metadata: ImageMetadata?
            var headerEnd = min(identity.size, Int64(MediaProbe.initialHeaderLength))
            while !waiters.isEmpty {
                try lifetime.checkRunning()
                let needsMetadata = waiters.values.contains { $0.metadata }
                if needsMetadata, metadata == nil, Int64(data.count) >= headerEnd {
                    switch try lifetime.whileRunning({ try MediaProbe.image(data, isComplete: Int64(data.count) >= identity.size) }) {
                    case let .metadata(value):
                        metadata = value
                        if let parent = identity.location.parent {
                            try await lifetime.value { [caches] in try await caches.metadata.store([identity.cacheKey: value], in: parent) }
                        }
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
                let range = Int64(data.count)..<end
                let group = group
                let part = try await lifetime.value { try await source.read(range, priority: priority, group: group) }
                guard !part.isEmpty else { throw MediaError.decodeFailed("文件在读取完成前结束") }
                data.append(part)
                // 前缀也有用；只有长度等于 identity.size 时才当成完整文件。
                try lifetime.whileRunning { caches.raw.insert(data, for: identity.cacheKey, cost: Int64(data.count)) }
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
