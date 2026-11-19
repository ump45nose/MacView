import Dispatch
import Foundation
import MVFoundation
import Synchronization
import Testing
@testable import MVIO

/// C1.25：等待 next 的消费任务被唤醒时，执行器会同步访问调度器。
/// 用独立线程限时取锁，旧的持锁 yield 会失败而不会把整个测试进程卡死。
@Test func healthPublicationReleasesSchedulerLockBeforeResumingConsumer() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 1))
    let executor = HealthConsumerExecutor()
    let consumer = HealthConsumer()
    let values = Task(executorPreference: executor) { await consumer.twoValues(from: scheduler.volumeHealth()) }
    while !consumer.waiting.load(ordering: .acquiring) { await Task.yield() }
    await executor.afterPendingJobs()

    let checked = Atomic(false)
    let accessible = Atomic(false)
    executor.onEnqueue.withLock { callback in
        callback = {
            guard !checked.exchange(true, ordering: .acquiringAndReleasing) else { return }
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = scheduler.currentVolumeHealth()
                finished.signal()
            }
            accessible.store(finished.wait(timeout: .now() + 1) == .success, ordering: .releasing)
        }
    }
    try await completeHealthRequest(scheduler)
    #expect(await values.value.count == 2)
    #expect(checked.load(ordering: .acquiring) == true)
    #expect(accessible.load(ordering: .acquiring) == true)
}

/// C1.25：与 LibraryAvailability 的析构路径相同，拥有者析构会同步取消消费任务。
/// 同时覆盖消费任务内部取消、多个订阅者并发注册，以及持续发布时的取消。
@Test(.timeLimit(.minutes(1))) func healthSubscriptionsCanCancelDuringConcurrentPublication() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 4))
    let clock = ContinuousClock()
    let started = clock.now
    let running = Atomic(true)
    let published = Atomic(0)
    let producer = Task.detached {
        while running.load(ordering: .acquiring) {
            try await completeHealthRequest(scheduler)
            published.add(1, ordering: .relaxed)
            await Task.yield()
        }
    }
    defer {
        running.store(false, ordering: .releasing)
        producer.cancel()
    }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<40 {
                    var owner: HealthSubscriptionOwner? = HealthSubscriptionOwner(scheduler: scheduler)
                    await owner!.waitUntilConsuming()
                    let task = owner!.task
                    owner = nil
                    await task.value

                    let selfCancelling = Task {
                        var iterator = scheduler.volumeHealth().makeAsyncIterator()
                        #expect(await iterator.next() != nil)
                        withUnsafeCurrentTask { $0?.cancel() }
                        // AsyncStream 可以先交付取消前已经缓冲的值，随后必须结束。
                        while await iterator.next() != nil {}
                    }
                    await selfCancelling.value
                }
            }
        }
    }
    running.store(false, ordering: .releasing)
    _ = try await producer.value
    #expect(published.load(ordering: .relaxed) > 0)
    #expect(clock.now - started < .seconds(10))
    // 取消旧订阅后，独立订阅仍及时收到初始值和后续值。
    var health = scheduler.volumeHealth().makeAsyncIterator()
    #expect(await health.next() == scheduler.currentVolumeHealth())
    try await completeHealthRequest(scheduler)
    #expect(await health.next()?.first?.state == .healthy)
}

/// 第一次发布唤醒消费任务时，同步等另一个卷完成登记和 I/O。
/// 单纯把 yield 移到锁外却未保序，会让尚未收到第一次发布的订阅者先看到第二个卷。
@Test func concurrentHealthPublicationsKeepTheSameOrderForEverySubscriber() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 2))
    let firstExecutor = HealthConsumerExecutor()
    let secondExecutor = HealthConsumerExecutor()
    let first = HealthConsumer()
    let second = HealthConsumer()
    let a = Task(executorPreference: firstExecutor) { await first.fiveValues(from: scheduler.volumeHealth()) }
    let b = Task(executorPreference: secondExecutor) { await second.fiveValues(from: scheduler.volumeHealth()) }
    while !first.waiting.load(ordering: .acquiring) || !second.waiting.load(ordering: .acquiring) { await Task.yield() }
    await firstExecutor.afterPendingJobs()
    await secondExecutor.afterPendingJobs()

    let checked = Atomic(false)
    let completed = Atomic(false)
    let registered = Mutex<AsyncStream<[VolumeHealth]>?>(nil)
    let concurrentChange: @Sendable () -> Void = {
        guard !checked.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            registered.withLock { $0 = scheduler.volumeHealth() }
            do { try await completeHealthRequest(scheduler, volume: publicationVolume("second")) }
            catch { Issue.record(error) }
            finished.signal()
        }
        completed.store(finished.wait(timeout: .now() + 1) == .success, ordering: .releasing)
    }
    firstExecutor.onEnqueue.withLock { $0 = concurrentChange }
    secondExecutor.onEnqueue.withLock { $0 = concurrentChange }
    try await completeHealthRequest(scheduler, volume: publicationVolume("first"))
    let snapshots = await a.value
    #expect(snapshots == (await b.value))
    #expect(snapshots.map(\.count) == [0, 1, 2, 2, 2])
    #expect(completed.load(ordering: .acquiring) == true)
    // 发布途中加入的订阅先收到登记时的快照，再收到之后的变化。
    var c = try #require(registered.withLock { $0 }).makeAsyncIterator()
    for count in [1, 2, 2] { #expect(await c.next()?.count == count) }
}

@Test func healthSubscriptionsShareOrderedSnapshotsAndReleaseScheduler() async throws {
    var scheduler: IOScheduler? = IOScheduler(configuration: .testing(metadata: 1))
    weak let weakScheduler = scheduler
    let first = scheduler!.volumeHealth()
    let second = scheduler!.volumeHealth()
    var a = first.makeAsyncIterator()
    var b = second.makeAsyncIterator()
    #expect(await a.next() == [])
    #expect(await b.next() == [])
    try await completeHealthRequest(scheduler!, volume: publicationVolume("b"))
    try await completeHealthRequest(scheduler!, volume: publicationVolume("a"))
    // 每卷首次登记、调用完成各发布一次；两位订阅者看到完全一致的顺序。
    var snapshots: [[VolumeHealth]] = []
    for _ in 0..<4 {
        let snapshot = await a.next()
        #expect(snapshot == (await b.next()))
        snapshots.append(try #require(snapshot))
    }
    #expect(snapshots.map(\.count) == [1, 1, 2, 2])
    #expect(snapshots.last == scheduler!.currentVolumeHealth())
    scheduler = nil
    #expect(weakScheduler == nil)
}

@Test func healthStreamsReportUnavailableAndRecoveredVolumesInOrder() async throws {
    let scheduler = IOScheduler(configuration: .testing(metadata: 1))
    let root = Location.Root.network(scheme: "nfs", host: "c125.invalid", share: "missing")
    let volume = Volume(mountPoint: "/scheduler-publication/unmounted", fileSystem: "nfs", root: root, isLocal: false)
    var a = scheduler.volumeHealth().makeAsyncIterator()
    var b = scheduler.volumeHealth().makeAsyncIterator()
    #expect(await a.next() == [])
    #expect(await b.next() == [])
    try await completeHealthRequest(scheduler, volume: volume)
    #expect(throws: IOError.volumeUnavailable(root)) {
        try scheduler.volume(for: Location(root: root, layers: [["page.jpg"]]))
    }
    try await completeHealthRequest(scheduler, volume: volume)
    for expected: VolumeState in [.healthy, .healthy, .unavailable, .healthy, .healthy] {
        let snapshot = try #require(await a.next())
        #expect(snapshot == (await b.next()))
        #expect(snapshot.first?.state == expected)
    }
    #expect(scheduler.currentVolumeHealth().first?.state == .healthy)
}

private func publicationVolume(_ name: String = "volume") -> Volume {
    Volume(mountPoint: "/scheduler-publication/\(name)", fileSystem: "apfs", root: .local, isLocal: true)
}

private func completeHealthRequest(_ scheduler: IOScheduler, volume: Volume = publicationVolume()) async throws {
    let _: Void = try await scheduler.perform(on: volume, .metadata, priority: .visible, group: nil) { finish, _ in
        finish(.success(()))
    }
}

private final class HealthSubscriptionOwner: Sendable {
    let task: Task<Void, Never>
    private let consumer = HealthConsumer()
    private let executor = HealthConsumerExecutor()

    init(scheduler: IOScheduler) {
        let consumer = consumer
        task = Task(executorPreference: executor) {
            await consumer.consumeUntilCancelled(from: scheduler.volumeHealth())
        }
    }

    func waitUntilConsuming() async {
        while !consumer.waiting.load(ordering: .acquiring) { await Task.yield() }
        await executor.afterPendingJobs()
    }

    deinit { task.cancel() }
}

private final class HealthConsumerExecutor: TaskExecutor {
    let onEnqueue = Mutex<(@Sendable () -> Void)?>(nil)
    private let queue = DispatchQueue(label: "MacView.tests.health-consumer")

    func enqueue(_ job: consuming ExecutorJob) {
        onEnqueue.withLock { $0 }?()
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    func afterPendingJobs() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

private final class HealthConsumer: Sendable {
    let waiting = Atomic(false)

    func consumeUntilCancelled(from stream: AsyncStream<[VolumeHealth]>) async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        waiting.store(true, ordering: .releasing)
        while await iterator.next() != nil {}
    }

    func twoValues(from stream: AsyncStream<[VolumeHealth]>) async -> [[VolumeHealth]] {
        await values(from: stream, count: 2)
    }

    func fiveValues(from stream: AsyncStream<[VolumeHealth]>) async -> [[VolumeHealth]] {
        await values(from: stream, count: 5)
    }

    private func values(from stream: AsyncStream<[VolumeHealth]>, count: Int) async -> [[VolumeHealth]] {
        var iterator = stream.makeAsyncIterator()
        guard let first = await iterator.next() else { return [] }
        waiting.store(true, ordering: .releasing)
        var result = [first]
        while result.count < count, let next = await iterator.next() { result.append(next) }
        return result
    }
}
