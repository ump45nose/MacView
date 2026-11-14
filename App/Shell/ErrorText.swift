import Foundation
import MVFoundation
import MVIO
import MVMedia
import MVServices

/// 把 Core 的错误转成界面上显示的一句话。
enum ErrorText {
    private static func describe(_ error: MediaError) -> String {
        switch error {
        case .unsupported, .decodeFailed: String(localized: "无法解码：文件已损坏或格式不受支持")
        case .requiresTiling: String(localized: "图片太大，无法整张解码")
        }
    }

    private static func describe(_ error: FileOpsError) -> String {
        switch error {
        case .readOnly: String(localized: "压缩包内的项不能移动")
        case let .invalidName(name):
            if name.isEmpty { String(localized: "名称不能为空") }
            else if name.contains("/") { String(localized: "名称不能包含“/”") }
            else if name.hasPrefix(".") { String(localized: "名称不能以“.”开头") }
            else { String(localized: "名称“\(name)”无效") }
        case let .recycleUnavailable(reason): String(localized: "无法创建回收目录：\(reason)")
        case .verificationFailed: String(localized: "读回校验不一致，源文件保留")
        case .intoItself: String(localized: "不能把文件夹移进它自己或子文件夹")
        }
    }

    /// 视频打不开或放不了时的文字。
    static let videoFailure = String(localized: "无法播放：视频编码不受支持")

    static func describe(_ error: any Error) -> String {
        if let error = error as? MediaError { return describe(error) }
        if let error = error as? FileOpsError { return describe(error) }
        guard let error = error as? IOError else { return error.localizedDescription }
        switch error {
        case .timeout: return String(localized: "读取超时")
        case .cancelled: return String(localized: "已取消")
        case .volumeUnavailable: return String(localized: "所在的卷不可用")
        case .volumeDegraded: return String(localized: "所在的卷响应缓慢，已暂停访问")
        case let .notFound(location): return String(localized: "找不到“\(location.description)”")
        case let .alreadyExists(location): return String(localized: "“\(location.description)”已存在")
        case .crossVolume: return String(localized: "不能跨卷改名")
        case let .unsupported(location): return String(localized: "不支持打开“\(location.description)”")
        case let .unsupportedFormat(location, format): return String(localized: "不支持 \(format) 格式：“\(location.description)”")
        case let .corrupted(location, reason): return String(localized: "“\(location.description)”已损坏：\(reason)")
        case let .underlying(message): return message
        }
    }
}
