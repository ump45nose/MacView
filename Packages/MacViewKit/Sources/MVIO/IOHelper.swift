import Darwin
import Foundation
import Synchronization

/// I/O 辅助进程的入口。网络卷上的阻塞调用在这里执行，卡住时只拖住这个进程，主进程照常退出。
///
/// 辅助进程由 `posix_spawn` 启动，可执行文件就是宿主自己（App、mvbench）或测试用的 `mvio-helper`。
/// 宿主要在 `main` 的最开头调用 `runIfRequested()`：环境变量 `MVIO_HELPER` 存在时进入请求循环，不再返回。
public enum IOHelper {
    static let environmentKey = "MVIO_HELPER"

    public static func runIfRequested() {
        guard getenv(environmentKey) != nil else { return }
        run(input: STDIN_FILENO, output: STDOUT_FILENO)
    }

    /// 从 input 读请求，每个请求在自己的线程上执行，回复写到 output。input 关闭（主进程退出）时立即退出。
    static func run(input: Int32, output: Int32) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let writer = Mutex(())
        let reader = FileReader()
        let cancelled = Mutex(Set<UInt64>())
        @Sendable func reply(_ id: UInt64, _ response: HelperResponse) {
            let frame = HelperCodec.encode(id: id, response)
            writer.withLock { _ in
                if !FrameIO.write(output, frame) { _exit(0) }
            }
        }
        while let body = FrameIO.read(input) {
            guard let (id, request) = try? HelperCodec.decodeRequest(body) else { _exit(1) }
            if case let .cancel(target) = request {
                cancelled.withLock { _ = $0.insert(target) }
                continue
            }
            Thread.detachNewThread {
                switch request {
                case let .stat(path):
                    do throws(FileOperationError) {
                        reply(id, .attributes(try FileOperations.stat(path)))
                    } catch {
                        reply(id, .failure(error))
                    }
                case let .read(read):
                    do throws(FileOperationError) {
                        reply(id, .data(try reader.read(read)))
                    } catch {
                        reply(id, .failure(error))
                    }
                case let .list(path):
                    do throws(FileOperationError) {
                        try FileOperations.list(path) { batch in
                            guard !cancelled.withLock({ $0.contains(id) }) else { return false }
                            reply(id, .batch(batch))
                            return true
                        }
                        reply(id, .done)
                    } catch {
                        reply(id, .failure(error))
                    }
                    cancelled.withLock { _ = $0.remove(id) }
                case let .probe(mountPoint):
                    do throws(FileOperationError) {
                        try FileOperations.probe(mountPoint)
                        reply(id, .done)
                    } catch {
                        reply(id, .failure(error))
                    }
                case .cancel:
                    break
                }
            }
        }
        _exit(0)
    }
}
