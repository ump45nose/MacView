/// 位置当前是否可读；卷未挂载与卷内文件缺失分别处理。
public enum Availability: Sendable, Hashable {
    case available
    case missing
    case volumeUnavailable(Location.Root)
}
