/// 把页面排成页帧的纯函数。
///
/// 输入页面宽高比（未知为 nil，按非宽页处理）和布局设置，输出按阅读顺序排好的页帧。
/// 目前一页一帧；双页拼合、首页单页和宽页处理在 S1-T6 实现。
public enum PageFrameEngine {
    public static func frames(aspectRatios: [Double?], layout: PageLayout) -> [PageFrame] {
        aspectRatios.indices.map { PageFrame(elements: [PageFrameElement(page: $0)]) }
    }
}
