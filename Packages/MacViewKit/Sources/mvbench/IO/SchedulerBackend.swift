import Foundation
import MVFoundation
import MVIO

/// 经 MVIO 的调度器访问：网络卷上的调用在辅助进程（mvbench 自己）中执行。与 posix 方式对照，量出调度和进程隔离的开销。
struct SchedulerBackend: IOBackend {
    func files(in directory: String, limit: Int?) throws -> [SampleFile] {
        try Samples.files(in: directory, limit: limit)
    }

    func read(_ files: [SampleFile], shape: ReadShape) throws -> ReadOutcome {
        let registry = Self.registry(concurrency: shape.concurrency, chunk: shape.chunk)
        let queue = WorkQueue(files)
        let sink = ResultSink<FileOutcome>()
        let clock = ContinuousClock()
        let start = clock.now
        Self.wait {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<shape.concurrency {
                    group.addTask {
                        while let file = queue.take() {
                            let begin = clock.now
                            do {
                                let location = try await registry.location(for: URL(filePath: file.path, directoryHint: .notDirectory))
                                let source = try await registry.provider(for: location).open(location)
                                let data = try await source.read(0..<source.identity.size, priority: .visible, group: nil)
                                sink.append(FileOutcome(milliseconds: (clock.now - begin).milliseconds, bytes: Int64(data.count)))
                            } catch {
                                sink.append(FileOutcome(milliseconds: (clock.now - begin).milliseconds, bytes: 0, error: "\(error)"))
                            }
                        }
                    }
                }
            }
        }
        registry.scheduler.shutdown()
        return ReadOutcome(files: sink.values, seconds: (clock.now - start).milliseconds / 1_000, chunk: shape.chunk)
    }

    func probe(_ files: [SampleFile], concurrency: Int, length: Int) throws -> ProbeOutcome {
        throw ValidationFailure("scheduler 方式只用于 read")
    }

    func list(_ directory: String, method: ListMethod, timeout: Double) throws -> ListAttempt {
        throw ValidationFailure("scheduler 方式只用于 read")
    }

    /// 通道并发与块大小按测量参数设置，与 posix 方式的同名参数对应。
    static func registry(concurrency: Int, chunk: Int) -> FileSourceRegistry {
        var configuration = IOConfiguration(helperExecutable: Bundle.main.executableURL)
        configuration.network.bulk = concurrency
        configuration.network.chunk = chunk
        configuration.local.bulk = concurrency
        configuration.local.chunk = chunk
        return FileSourceRegistry(scheduler: IOScheduler(configuration: configuration))
    }

    /// 在同步的子命令里等一段异步代码完成。
    static func wait(_ body: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task {
            await body()
            done.signal()
        }
        done.wait()
    }
}
