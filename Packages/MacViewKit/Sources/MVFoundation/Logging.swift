import os

/// 日志与 signpost 的统一入口。
public enum MVLog {
    /// 全应用共用的 subsystem，与 App 的 bundle id 一致。
    public static let subsystem = "io.github.ump45nose.MacView"
}

/// signpost 的分类，对应 Instruments 中按类别筛选的 os_signpost 区间。
public enum SignpostCategory: String, CaseIterable, Sendable {
    case io
    case decode
    case cache
    case layout
    case render
}

extension Logger {
    /// 在 MacView 的 subsystem 下创建指定类别的 Logger。
    public init(category: String) {
        self.init(subsystem: MVLog.subsystem, category: category)
    }
}

extension OSSignposter {
    /// 在 MacView 的 subsystem 下创建指定类别的 signposter。
    public init(category: SignpostCategory) {
        self.init(subsystem: MVLog.subsystem, category: category.rawValue)
    }
}
