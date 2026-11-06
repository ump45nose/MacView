import Foundation
import MVCache
import MVFoundation
import MVIO
import MVMedia
import Synchronization

struct PipelineContent: Sendable {
    var identity: ContentIdentity
    var data: Data
    var metadata: ImageMetadata?
}

/// 在一份顺序读取的前缀上满足文件头和完整文件的消费者。
/// 消费者先在登记表的锁内同步 `join` 成为成员，再调用 `value`。成员登记和「是否已放弃」在同一把锁里，
/// 只有最后一个成员因取消退出时才放弃，放弃后 `join` 返回 false，所以加入和放弃不会交错。
actor ContentWork {
    private struct Membership {
        var members: Set<UUID> = []
        var abandoned = false
    }
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
    private let membership = Mutex(Membership())
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

    /// 在登记表的锁内调用，不回调登记表。返回 false 表示作业已放弃，调用方应换一个新作业。
    nonisolated func join(consumer: UUID) -> Bool {
        membership.withLock { state in
            guard !state.abandoned else { return false }
            state.members.insert(consumer)
            return true
        }
    }

    /// `consumer` 必须已经 `join`；拿到结果、自己被取消、生命周期已停止、作业出错时都会退出成员关系。
    func value(full: Bool, metadata: Bool, consumer: UUID, priority: IOPriority) async throws -> PipelineContent {
        try await withTaskCancellationHandler {
            do { try lifetime.checkRunning() }
            catch {
                leave(consumer, cancelled: true)
                throw error
            }
            return try await withCheckedThrowingContinuation { continuation in
                if cancelled.contains(consumer) {
                    leave(consumer, cancelled: true)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let result {
                    switch result {
                    case let .success(value) where (!full || Int64(value.data.count) == value.identity.size) && (!metadata || value.metadata != nil):
                        leave(consumer, cancelled: false)
                        continuation.resume(returning: value)
                        return
                    case let .failure(error):
                        leave(consumer, cancelled: false)
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
                        for (id, waiter) in waiters {
                            leave(id, cancelled: false)
                            waiter.continuation.resume(throwing: error)
                        }
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
        guard let waiter = waiters.removeValue(forKey: consumer) else {
            // 还没开始等待的成员，由 `value` 看到标记后退出。
            if membership.withLock({ $0.members.contains(consumer) }) { cancelled.insert(consumer) }
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
        if !leave(consumer, cancelled: true) { updatePriority() }
    }

    /// 退出成员关系。因取消退出且没有成员剩下时，在同一把锁里放弃作业，然后取消读取和调度组。
    @discardableResult
    private func leave(_ consumer: UUID, cancelled: Bool) -> Bool {
        self.cancelled.remove(consumer)
        let abandoned = membership.withLock { state in
            state.members.remove(consumer)
            guard cancelled, state.members.isEmpty else { return false }
            state.abandoned = true
            return true
        }
        guard abandoned else { return false }
        scheduler?.cancel(group)
        task?.cancel()
        completed()
        return true
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
                for (id, waiter) in ready {
                    waiters[id] = nil
                    leave(id, cancelled: false)
                    waiter.continuation.resume(returning: content)
                }
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
            for (id, waiter) in waiters {
                leave(id, cancelled: false)
                waiter.continuation.resume(throwing: error)
            }
            waiters.removeAll()
        }
        task = nil
        completed()
    }
}
