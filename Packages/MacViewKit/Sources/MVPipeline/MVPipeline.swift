// MVPipeline：串联各缓存层、一次读取产出多种渲染件、渐进交付与预取计划。职责与契约见 docs/architecture.md §2、§4。
import MVFoundation
import MVIO
import MVMedia

public enum RenditionSpec: Sendable, Hashable {
    case metadata, thumbnail, browse
    case display(DisplayTarget)
}

public struct PrefetchItem: Sendable, Hashable {
    public var identity: ContentIdentity
    public var renditions: Set<RenditionSpec>
    public var priority: IOPriority

    public init(identity: ContentIdentity, renditions: Set<RenditionSpec>, priority: IOPriority) {
        self.identity = identity
        self.renditions = renditions
        self.priority = priority
    }
}

/// 一个会话的全部预取项；每次整体替换。
public struct PrefetchPlan: Sendable, Equatable {
    public var items: [PrefetchItem]

    public init(items: [PrefetchItem] = []) {
        self.items = items
    }
}

public protocol ImagePipeline: Sendable {
    func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata
    func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage
    /// 按完成顺序给出各项的结果。
    func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)>
    /// 依次交付占位图、浏览图和精确尺寸图（允许且需要时为原图）。
    func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error>
    func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource
    func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource
    func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage
    /// 整体替换会话的预取计划：移除的取消，保留的重排，新增的入队。
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID)
    func cancelAll(session: SessionID)
}
