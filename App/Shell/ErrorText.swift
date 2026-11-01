import Foundation
import MVFoundation
import MVIO

/// 把 Core 的错误转成界面上显示的一句话。
enum ErrorText {
    static func describe(_ error: any Error) -> String {
        guard let error = error as? IOError else { return error.localizedDescription }
        switch error {
        case .timeout: return String(localized: "读取超时")
        case .cancelled: return String(localized: "已取消")
        case .volumeUnavailable: return String(localized: "所在的卷不可用")
        case .volumeDegraded: return String(localized: "所在的卷响应缓慢，已暂停访问")
        case let .notFound(location): return String(localized: "找不到“\(location.description)”")
        case let .unsupported(location): return String(localized: "不支持打开“\(location.description)”")
        case let .corrupted(location, reason): return String(localized: "“\(location.description)”已损坏：\(reason)")
        case let .underlying(message): return message
        }
    }
}
