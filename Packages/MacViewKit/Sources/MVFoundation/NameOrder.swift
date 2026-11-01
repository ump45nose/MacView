import Foundation

/// 同一个 ICU zh 比较器处理自然排序、中文拼音和全角数字。
public enum NameOrder {
    private static let locale = Locale(identifier: "zh_Hans_CN")
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let result = lhs.compare(rhs, options: [.numeric, .caseInsensitive, .widthInsensitive, .forcedOrdering], locale: locale)
        return result == .orderedSame ? lhs.compare(rhs, options: .literal) : result
    }
}
