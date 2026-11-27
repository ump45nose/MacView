import Dispatch
import Foundation
import Synchronization

/// 调度器的时间来源：期限计时与到期回调都经过它，测试可以换成手动推进的时钟。
protocol IOClock: Sendable {
    /// 单调递增的秒数。
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

/// 系统单调时钟；到期回调在调度器自己的串行队列上执行。
struct SystemIOClock: IOClock {
    let queue: DispatchQueue

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// 测试用：只在 `advance` 时前进；到期的回调按到期先后在调用 `advance` 的线程上执行。
final class ManualIOClock: IOClock {
    private struct Timer {
        let due: TimeInterval
        let work: @Sendable () -> Void
    }

    private struct State {
        var now: TimeInterval = 0
        var timers: [Timer] = []
    }

    private let state = Mutex(State())

    var now: TimeInterval { state.withLock { $0.now } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        state.withLock { $0.timers.append(Timer(due: $0.now + max(0, delay), work: work)) }
    }

    func advance(by delta: Duration) {
        let target = state.withLock { $0.now + delta.timeInterval }
        while true {
            // 回调里可能再排新的计时，所以每次只取一个，执行完再取。
            let next = state.withLock { state -> Timer? in
                guard let index = state.timers.indices.filter({ state.timers[$0].due <= target })
                    .min(by: { state.timers[$0].due < state.timers[$1].due })
                else {
                    state.now = target
                    return nil
                }
                let timer = state.timers.remove(at: index)
                state.now = max(state.now, timer.due)
                return timer
            }
            guard let next else { return }
            next.work()
        }
    }
}
