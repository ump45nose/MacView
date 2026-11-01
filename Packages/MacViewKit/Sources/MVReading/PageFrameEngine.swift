import MVSettings

/// 输入按阅读顺序排列的页面；双页帧中的元素按画面从左到右排列。
public enum PageFrameEngine {
    public static func frames(aspectRatios: [Double?], layout: PageLayout) -> [PageFrame] {
        var result: [PageFrame] = []
        var pending: [PageFrameElement] = []
        func emit() {
            guard !pending.isEmpty else { return }
            let elements = layout.direction == .rightToLeft ? Array(pending.reversed()) : pending
            result.append(PageFrame(elements: elements))
            pending.removeAll(keepingCapacity: true)
        }
        for index in aspectRatios.indices {
            let wide = (aspectRatios[index] ?? 0) > 1
            if wide, layout.widePage == .split {
                emit()
                let parts: [PagePart] = layout.direction == .leftToRight ? [.leftHalf, .rightHalf] : [.rightHalf, .leftHalf]
                for part in parts { result.append(PageFrame(elements: [PageFrameElement(page: index, part: part)])) }
            } else if layout.pageMode == .single || (wide && layout.widePage == .single) || (index == 0 && layout.firstPageSingle) {
                emit()
                result.append(PageFrame(elements: [PageFrameElement(page: index)]))
            } else {
                pending.append(PageFrameElement(page: index))
                if pending.count == 2 { emit() }
            }
        }
        emit()
        return result
    }
}
