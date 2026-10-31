/// 一组样本的统计摘要。单位由调用方决定，通常是毫秒。
struct Summary: Codable, Equatable, Sendable {
    var count: Int
    var mean: Double
    var min: Double
    var max: Double
    var p50: Double
    var p95: Double
    var p99: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        count = sorted.count
        mean = sorted.reduce(0, +) / Double(sorted.count)
        min = sorted[0]
        max = sorted[sorted.count - 1]
        p50 = Self.percentile(sorted, 0.50)
        p95 = Self.percentile(sorted, 0.95)
        p99 = Self.percentile(sorted, 0.99)
    }

    /// 在相邻两个秩之间线性插值，与 numpy 的默认方法一致。
    static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        let position = quantile * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

/// 重复执行一段代码，返回每次的耗时。
enum Measure {
    static func durations(repeat count: Int, warmup: Int = 0, _ body: () throws -> Void) rethrows -> [Duration] {
        for _ in 0..<warmup { try body() }
        let clock = ContinuousClock()
        var durations: [Duration] = []
        durations.reserveCapacity(count)
        for _ in 0..<count { durations.append(try clock.measure(body)) }
        return durations
    }

    /// 在调用方的执行器上运行 `body`，计时不包含切换执行器的开销。
    nonisolated(nonsending)
    static func durations(repeat count: Int, warmup: Int = 0, _ body: nonisolated(nonsending) () async throws -> Void) async rethrows -> [Duration] {
        for _ in 0..<warmup { try await body() }
        let clock = ContinuousClock()
        var durations: [Duration] = []
        durations.reserveCapacity(count)
        for _ in 0..<count { durations.append(try await clock.measure(body)) }
        return durations
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
