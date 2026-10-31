# MacView 架构

状态：2026-10-31 定稿。

相关文档：
- 需求：[requirements.md](plans/requirements.md)
- 阶段与进度：[roadmap.md](plans/roadmap.md)
- 工作约定：[AGENTS.md](../AGENTS.md)

修改公开接口时，同步更新 §4。

## 术语

- 书（Book）：作为一个整体来阅读的文件夹或压缩包；其中的图片和视频是页（Page）。
- 书架（Bookshelf）：一个目录下的全部书，用于书架面板和相邻书导航。
- 页帧（PageFrame）：分页模式下一次显示的内容，可以是一页、两页，或宽页的一半。
- 渲染件（Rendition）：从原文件派生的图像，包括缩略图、浏览图（屏幕尺寸，可持久化）和精确尺寸图。
- 卷（Volume）：一块本地磁盘或一个 NAS 共享的挂载。I/O 调度以卷为单位。
- 会话（ReaderSession）：一个窗口或标签中正在阅读的书及其状态。

## 1. 架构原则

- Core 与 App 分离：
  - Core 是 SwiftPM 包 `Packages/MacViewKit`，不依赖 AppKit，可以用 `swift test` 单独测试。
  - App target 负责界面和图像呈现。
  - 两者以 §4 的契约对接。
- 网络是瓶颈。一次完整读取要同时产出需要的全部渲染件（缩略图、浏览图、元数据），同一个文件不读第二遍。
- 阻塞的文件系统调用不在主线程或 Swift 并发协作线程池上执行，全部交给 I/O 调度器的专用线程。解码只针对内存中的数据，不让 ImageIO 自己读文件。
- 状态可见：卷健康、单项错误、设置文件解析错误都直接显示在界面上，并能重试。
- 不为假设的需求预留结构。P1 已确定的扩展点（数据源、命令、面板、效果）只体现在接口形状上，不提前实现。

## 2. 模块

| 模块 | 职责 | 依赖 |
|---|---|---|
| MVFoundation | Location、ContentIdentity、Entry、PixelSize、JSONValue、错误类型、日志与 signpost、名称比较器 | — |
| MVIO | IOScheduler、卷通道与健康状态、FileSystemProvider、SourceRegistry、ByteSource，以及 URL 与 Location 的互转 | MVFoundation |
| MVArchive | zip/cbz、tar、tar.gz/gz，嵌套，ArchiveProvider，临时解出目录 | MVIO |
| MVMedia | 探测、显示尺寸解码与重采样、原图与分块、动图帧、视频封面与元数据、渲染件编码 | MVFoundation |
| MVCache | 内存缓存 L0/L1、磁盘缓存 L2/L3、元数据索引、目录缓存。存储是泛型的，具体类型由 MVPipeline 指定 | MVFoundation |
| MVPipeline | ImagePipeline：串联各缓存层，一次读取产出多种渲染件，渐进交付，按会话管理预取计划 | MVIO、MVMedia、MVCache |
| MVSettings | 设置模式、分层解析、路径规则、JSON 存储、书记忆 | MVFoundation |
| MVCommands | 命令登记、按键序列与作用域解析，以及默认命令、绑定与菜单模型 | MVFoundation |
| MVReading | Book/Page、BookLoader、Bookshelf、PageFrameEngine、ReaderSession | MVIO、MVPipeline、MVSettings |
| MVServices | 组合根：创建并连接各服务，负责启动、退出和内存压力处理 | 以上全部 |
| MVTestSupport | Mock 与夹具加载。App 的 Debug 构建可以用启动参数 `-MVMockServices YES` 切换到 Mock | 契约 |
| mvbench | 基准测试与夹具生成的命令行工具 | 全部 |
| App（`MacView` target） | 窗口与标签页、停靠面板、集合视图、查看器、输入、菜单、设置界面、本地化 | MVServices 等 |

- 任务 ID 中，T 表示 Core 任务，F 表示 App 任务。
- P1 的新模块到对应阶段再建：MVLibraryData（书签、播放列表、历史）、MVFileOps、MVSearch、MVMetadata（评分与标签）、MVEffects、MVScripting、MVPlugins。
- 依赖选型：SQLite 统一用 GRDB.swift（MIT 许可），由第一个用到它的任务引入，MVCache 与 MVSettings 共用。其余依赖由各任务按需选用。
- 已引入的依赖（版本以 `Packages/MacViewKit/Package.resolved` 为准）：

  | 依赖 | 用途 | 许可证 | 引入任务 |
  |---|---|---|---|
  | swift-argument-parser 1.8.2 | mvbench 的子命令与参数解析 | Apache-2.0 | S0-T1 |
  | libsmb2 6.3.1 | mvbench 的 SMB 直连原型（`io --transport smb2`）。由 `scripts/build-libsmb2.sh` 构建成动态库，运行时 dlopen，不链接、不入库 | LGPL-2.1 | S0-T2 |

仓库布局：

```
AGENTS.md  project.yml(XcodeGen)  Makefile
App/                      # App target 源码 + Resources（xcstrings、assets）；Info.plist 由 project.yml 生成
Packages/MacViewKit/      # Package.swift，Sources/<模块>，Tests/<模块>Tests
Fixtures/                 # 提交的小夹具；Fixtures/local/ 放生成的大夹具和 NAS 样本副本（不入库）
docs/architecture.md  docs/plans/{requirements,roadmap}.md  docs/plans/tasks/  docs/reports/{<任务>.md,bench/}
```

`MacView.xcodeproj` 由 `make project` 用 XcodeGen 生成，不入库。工程配置只改 `project.yml`，不手工编辑 pbxproj。

NeeView 源码位于源码根目录（MacPro 上为 `/Users/yuwk/WorkSpace/Code/Github`）的 `Others/NeeView/`，移植版的文档在其中的 `portable/` 下。下文引用的路径都相对于 `Others/NeeView/`。

## 3. 关键设计

### 3.1 位置与身份

- `Location` 由根（Root）和层（layers）组成：
  - 根有三种：`.local`、`.network(scheme, host, share)`、`.plugin(id)`（P1）。
  - `layers[0]` 是根下的路径；之后每层是上一层末端压缩包内的路径。
  - 例：`Picture/a.zip!/inner/b.zip!/001.jpg` 的根是 `network(smb, 192.168.31.201, Picture)`，层是 `[["a.zip"], ["inner","b.zip"], ["001.jpg"]]`。
- 挂载路径归一：
  - SMB/NFS 挂载路径通过 `volumeURLForRemountingKey` 归一成 network 根，书记忆和历史因此不依赖 `/Volumes/xxx` 这个挂载名。
  - 持久化时存结构化 JSON，字符串形式只用于显示。
  - 根没有挂载时返回 `volumeUnavailable`，界面提供“连接”按钮：用 NSWorkspace 打开 `smb://` 或 `nfs://` URL，由系统挂载。
- `ContentIdentity` 由位置、大小、修改时间（纳秒整数）和可选的校验值（如 zip 条目的 CRC32）组成，其稳定哈希就是缓存键。文件一变，缓存自然失效，不需要另做失效逻辑。

### 3.2 I/O 模型

- 通道：
  - 每个卷一条通道，内分两个子通道：元数据（枚举、stat、文件头探测）和大块读取。小请求因此不会排在 20 MB 的读取后面。
  - 每个子通道有并发上限，NAS 的取值由 S0-T2 实测确定。
- 优先级：visible > near > book > adjacent > background。请求带 `IORequestGroup`，预取计划变更时可以整批取消或重排。
- 取消：排队中的请求直接移除；执行中的读取按 1–4 MB 分块，在块与块之间检查取消。
- 超时与卷健康：
  - 每次调用都有期限，最长 10 秒，超时后向调用方抛出 `.timeout`。底层被卡住的线程仍占着槽位，计为 stuck。
  - stuck 或超时次数超过阈值时，卷标为 degraded：新请求立即失败，只保留定期的健康探测，探测成功即恢复。
  - 卷状态以流的形式提供给界面显示。
- 枚举优先用 `getattrlistbulk` 分批返回，书和书架因此能渐进显示。
- 退出不等待 I/O 线程。如果 S0-T2 测得被卡住的 smbfs 调用会让进程退出超过 3 秒，就把网络卷上的调用移到 XPC 辅助进程执行，对外接口不变。
- 若 G0 选用内置 SMB（libsmb2），它作为另一个 ContainerProvider 接入，并带来以下影响：
  - libsmb2 使用 LGPL-2.1，只能动态链接。
  - 视频要改用 AVAssetResourceLoader 流式读取。
  - Finder、外部命令和 P1 的文件操作仍然需要系统挂载路径。

### 3.3 媒体与渲染件

- 探测：
  - 增量读取文件头：从 64 KB 开始，不够再扩大，上限 1 MB。
  - 用 `CGImageSourceCreateIncremental` 获取尺寸（按 EXIF 方向换算后）、帧数、拍摄时间和色彩信息。
  - 视频用 AVURLAsset 获取时长和尺寸。
- 显示尺寸解码：
  - 用 `CGImageSourceCreateThumbnailAtIndex` 降采样解码，参数为 MaxPixelSize、WithTransform 和 `ShouldCacheImmediately=true`。
  - 再用选定的滤镜精确缩放到目标尺寸（Lanczos 用 MPS 或 vImage），缩小后可以选择锐化。
  - 输出已解码、由 IOSurface 支撑的图像，主线程不会再触发解码。保留 Display P3 色域。
  - 解码在有并发上限的专用队列上执行。
- 原图与大图：
  - 放大到超过解码上限时，解码原图。
  - 超过纹理上限或内存门限的超大图提供分块源（TiledImageSource），具体实现由 S1-T3 实测确定。
- 渲染件：一次完整读取产出以下几种，编码用 HEIC 还是 JPEG 由 S1-T3 实测决定。
  - 缩略图：暂定长边 1024 px。
  - 浏览图：等比缩放到能放进最大显示器的像素尺寸。
  - 元数据。
- 动图通过帧源按需逐帧解码，播放节奏由前端的显示链接驱动。
- 视频：
  - 封面用 AVAssetImageGenerator 生成，取 1 秒处和 10% 处中较早的一帧。
  - AVFoundation 自己读文件，管线为它占用该卷大块读取通道的一个槽位，使并发上限和卷健康统计保持一致。

### 3.4 缓存与图像管线

| 层 | 介质 | 内容 | 默认预算 |
|---|---|---|---|
| L0 | 内存 | 近期读取的原始文件字节；换尺寸重新解码时不必再读 NAS | 512 MB |
| L1 | 内存 | 显示尺寸图和原图的解码结果 | min(2 GB, 10% 内存) |
| L2 | SSD | 缩略图 | 10 GB |
| L3 | SSD（可关） | 浏览图 | 50 GB |
| 索引 | SQLite | 元数据（尺寸、帧数、时长、拍摄时间）、目录列表、L2/L3 的位置与访问时间 | — |

- L2/L3：
  - 按 LRU 淘汰。
  - 写入时先写临时文件再改名，最后更新索引。
  - 启动时不扫描缓存目录。
- 内存压力：收到系统的内存压力事件时，把 L0/L1 收缩到预算的 50% 或 25%。
- 目录缓存：
  - 先返回上次的结果，同时在后台校验，NAS 目录因此能秒开。
  - 首次枚举时按到达顺序渐进显示，枚举完成后一次性排序，并保持可见锚点不动。
- 取图：
  - `image(for:target:)` 依次交付三个阶段：缩略图放大的占位 → 浏览图 → 精确尺寸。
  - 主区瀑布流按列宽调用它，由管线在缩略图、浏览图和原图之间选择来源；画廊面板用 `thumbnail`。
- 预取计划以会话为单位整体替换：移除的取消，保留的重排，新增的入队。
- 默认预取范围（都可配置，S2-T1 再调优）：
  - 查看器：前后各 2 个页帧预解码；阅读方向上再往前 5 页预读原始字节。
  - 画廊：可见区域再加一屏的余量。
  - 当前书：全部页面的缩略图和元数据。
  - 相邻：书架上后 2 本书，以及当前目录各书的封面。

### 3.5 阅读模型

- BookLoader：
  - 流程：渐进枚举 → 按支持的类型过滤（排除 `._*`、`.DS_Store`、`.url`）→ 排序 → 按阅读顺序探测元数据。
  - 宽高比写入元数据索引，重访时可以立即排版。
- 子文件夹：递归展开可以设深度。只含一个子文件夹且没有媒体的目录，自动进入下一层。
- 排序：
  - 名称排序用一个比较器同时实现自然排序和拼音排序：数字感知，加上 ICU zh 排序规则。
  - 其他排序键：修改时间、创建时间、大小、类型、随机（种子固定，记在书记忆里）。
  - 支持升序和降序，文件夹可以排在前面，也可以混排。
- 不跳动的排版：
  - 瀑布流和连续模式只按顺序排已知宽高比的最长前缀。
  - 打开到第 k 页时，先补齐前 k 页的探测，期间显示进度。
  - 宽高比在页面图像加载之前就已确定，所以图像加载后布局不变。
- Bookshelf：
  - 列出目录下的书，即子文件夹和压缩包；散放的媒体属于所在目录这本书。
  - 提供相邻书导航和单层穿透。
  - 封面按需解析，并记入目录缓存。
- PageFrameEngine：
  - 纯函数，输入两项：
    - 页面宽高比：未知时为 nil，按非宽页处理。
    - 布局设置：单页/双页、方向、首页单页，以及宽页按原样、单独或拆分处理。
  - 输出按阅读顺序排好的页帧序列。元数据到达后重新计算时，当前页保持不动。
  - 参考 NeeView：`NeeView/PageFrames/PageFrameFactory.cs`、`PageFrameElement.cs`，以及 `PageFramesMath/AspectRatioTools.cs`。
- 连续模式与瀑布流：
  - 连续模式的纵向和横向都按单页排列，横向条的方向由阅读方向决定。
  - 瀑布流是整本书的砌体视图，点击某页进入分页模式。
- ReaderSession：`@MainActor @Observable`，每个窗口或标签各一个，负责：
  - 导航与切书。
  - 设置变更：写入书层，去抖后持久化。
  - 按浏览模式和位置生成预取计划。
  - 接收前端回报的可见范围（连续和瀑布模式）。

### 3.6 设置与持久化

- `~/Library/Application Support/MacView/`：
  - JSON 文件：
    - `settings.json`：全局设置与默认书设置。
    - `path-rules.json`、`keybindings.json`。
    - `layout.json`：停靠布局和各面板的视图设置。
  - SQLite：`state.sqlite` 存书记忆，P1 的历史也存在这里。
  - P1 再增加 `profiles.json`、`bookmarks.json`、`playlists/`、`menus.json`。
- `~/Library/Caches/MacView/`：`thumbnails/`、`browse/`、`extract/`（压缩包临时解出）、`index.sqlite`。
- JSON 文件：
  - 带版本号，原子写入，外部编辑后自动重载。
  - 解析失败时保留上一份可用的配置，并在界面显示错误和“打开文件”入口。
- 分层解析：
  - 顺序：全局 ⊕ 匹配的路径规则（越具体越靠后）⊕ 书记忆，逐字段合并。
  - 各层的字段都是可选的，只有全局层必须完整。
- 书记忆保存：页位置（页身份加序号）、单双页、方向、排序、递归、缩放和浏览方式；P1 再加显示配置的值。

### 3.7 命令与输入

- 菜单、快捷键、手势、脚本和插件都通过 `CommandRegistry.perform` 执行命令。Core 定义命令清单和默认绑定，App 注册与界面相关的处理器。
- 输入路由：
  - 文本框、弹出层和菜单先在 AppKit 响应链里处理按键。
  - 没被处理的按键由 InputRouter 转成 KeyChord，连同作用域（global/viewer/list/textInput）交给 BindingResolver。这样可以避免移植版那种“在弹出层里按方向键却触发了切书”的问题（`portable/docs/known-issues.md` 的 MAC-INPUT-005）。
  - 多键序列有超时，等待后续按键时界面显示待定提示。
- 菜单：
  - 菜单模型由命令清单生成默认树，P1 起可以编辑。
  - MenuBuilder 把模型渲染成 NSMenu，单键绑定同步显示为菜单项的快捷键。

### 3.8 前端架构

界面的视觉和交互以设计稿为准，见 [docs/design/README.md](design/README.md)。

- 生命周期用 AppKit（AppDelegate）。SwiftUI 只用于设置窗口和小型弹出层。
- 窗口：
  - 每个窗口或标签一个 `ReaderWindowController`，持有自己的 ReaderSession 和停靠布局。
  - `tabbingMode = .preferred`。
  - 用 NSWindowRestoration 恢复窗口、书和页。
- 停靠框架：
  - NSSplitView 分出左、中、右三栏，底部区在中间栏下方。
  - 每个区放一个面板栈（标签页或上下分割），面板可以拖到别的区。
  - 浮动面板是全应用共享的 NSPanel，作用于当前活动窗口。
  - 全屏时停靠区自动隐藏，鼠标靠近边缘时浮出。
- 画布引擎：
  - 基于 NSScrollView，利用它原生的滚动、惯性和捏合缩放。内容是图层池，不为每一项建一个 NSView。
  - LayoutModel 有砌体、网格、纵向条、横向条四种，布局变化时保持可见锚点。
  - 把可见范围和余量回报给预取计划。
  - 同一个引擎服务连续模式、主区瀑布流和画廊面板。
- 集合组件：列表和详情表格用 NSTableView，网格和瀑布流用画布引擎。
- 查看器：
  - 分页渲染器负责页帧图层、缩放模式计算、设备像素 1:1、放大镜、翻页时保持缩放与位置，以及以光标为中心缩放。
  - 缩放手势结束后，按新的设备像素尺寸重新请求图像；超过上限时请求原图或分块。
  - 视频用 AVPlayerLayer，每个窗口只有一个活动的播放器。
- 观测：用 os_signpost 标记帧时间和请求延迟，用 Instruments 的 Animation Hitches 验收。

### 3.9 P1 扩展点（P0 只体现在接口形状上）

- 数据源插件以 ContainerProvider 的形式注册到 SourceRegistry，按根分派。
- 脚本命令和插件命令注册进 CommandRegistry。
- HTML/JS 面板是一种面板类型。
- 显示配置按模板语义写入设置层，不新增层级。
- 效果链的模型放在 Core，由前端在呈现时用 CALayer 滤镜或 Core Image 在 GPU 上应用。

## 4. Core 协议契约

S0-T4 按下面的签名落成代码。实现时的调整记入 S0-T4 报告，并在 G0 时并入本节。

```swift
// MVFoundation
public struct Location: Hashable, Sendable, Codable {
    public enum Root: Hashable, Sendable, Codable { case local; case network(scheme: String, host: String, share: String); case plugin(id: String) }
    public var root: Root
    public var layers: [[String]]
}
public struct ContentIdentity: Hashable, Sendable, Codable { public var location: Location; public var size: Int64; public var modificationNanos: Int64; public var checksum: UInt32?; public var cacheKey: String { get } }
public struct PixelSize: Hashable, Sendable, Codable { public var width: Int; public var height: Int }
public enum ArchiveFormat: String, Sendable, Codable { case zip, tar, tarGzip, gzip }
public enum EntryKind: Hashable, Sendable, Codable { case directory, archive(ArchiveFormat), image, video, other }
public struct Entry: Hashable, Sendable { public var identity: ContentIdentity; public var name: String; public var kind: EntryKind; public var created: Date? }   // location、size、modified 由 identity 计算
public struct SessionID: Hashable, Sendable { public let raw: UUID }
public enum JSONValue: Hashable, Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }

// MVIO
public enum IOPriority: Int, Sendable, Comparable { case visible, near, book, adjacent, background }   // 按声明顺序，visible 最高
public struct IORequestGroup: Hashable, Sendable { public let id: UUID }
public protocol ByteSource: Sendable {
    var identity: ContentIdentity { get }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data
}
public protocol ContainerProvider: Sendable {
    func canHandle(_ location: Location) -> Bool
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error>   // 分批返回
    func entry(at location: Location) async throws -> Entry
    func open(_ location: Location) async throws -> any ByteSource
    func fileURL(for location: Location) async throws -> URL   // 压缩包内的条目解出到 extract/
}
public enum VolumeState: Sendable, Equatable { case healthy, degraded(String), unavailable }
public struct VolumeHealth: Sendable { public var root: Location.Root; public var state: VolumeState; public var inFlight: Int; public var stuck: Int }
public enum IOError: Error, Sendable { case timeout, cancelled, volumeUnavailable(Location.Root), notFound(Location), unsupported(Location), corrupted(Location, String), underlying(String) }
public protocol SourceRegistry: Sendable {
    func provider(for location: Location) throws -> any ContainerProvider
    func location(for fileURL: URL) async throws -> Location   // 打开面板与拖放的入口；要查询卷信息，所以是异步的
    func volumeHealth() -> AsyncStream<[VolumeHealth]>
}

// MVMedia
public struct ImageMetadata: Sendable, Codable, Hashable { public var pixelSize: PixelSize; public var frameCount: Int; public var duration: Double?; public var capturedAt: Date?; public var colorSpace: String? }   // pixelSize 已按 EXIF 方向换算
public enum ResampleFilter: String, Sendable, Codable { case lanczos, nearest }
public struct DisplayTarget: Sendable, Hashable { public var pixelSize: PixelSize; public var filter: ResampleFilter; public var sharpen: Float }
public enum RenditionQuality: Int, Sendable, Comparable { case placeholder, browse, exact, original }
public struct RenderedImage: @unchecked Sendable { public let image: CGImage; public let quality: RenditionQuality }
public protocol AnimatedFrameSource: Sendable { var frameCount: Int { get }; func duration(at index: Int) -> Double; func frame(at index: Int) async throws -> RenderedImage }
public protocol TiledImageSource: Sendable { var pixelSize: PixelSize { get }; func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage }

// MVPipeline
public enum RenditionSpec: Sendable, Hashable { case metadata, thumbnail, browse, display(DisplayTarget) }
public struct PrefetchItem: Sendable, Hashable { public var location: Location; public var renditions: Set<RenditionSpec>; public var priority: IOPriority }
public struct PrefetchPlan: Sendable { public var items: [PrefetchItem] }
public protocol ImagePipeline: Sendable {
    func metadata(for location: Location, priority: IOPriority) async throws -> ImageMetadata
    func thumbnail(for location: Location, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage
    func thumbnails(for locations: [Location], maxPixel: Int, priority: IOPriority) -> AsyncStream<(Location, Result<RenderedImage, any Error>)>
    func image(for location: Location, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error>
    func tiledSource(for location: Location) async throws -> any TiledImageSource
    func animatedFrames(for location: Location, target: DisplayTarget) async throws -> any AnimatedFrameSource
    func videoPoster(for location: Location, maxPixel: Int) async throws -> RenderedImage
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID)
    func cancelAll(session: SessionID)
}

// MVSettings
public enum BrowseMode: String, Codable, Sendable { case paged, waterfall, verticalStrip, horizontalStrip }
public enum PageMode: String, Codable, Sendable { case single, double }
public enum ReadingDirection: String, Codable, Sendable { case leftToRight, rightToLeft }
public enum WidePagePolicy: String, Codable, Sendable { case asIs, single, split }
public enum ScaleMode: String, Codable, Sendable { case original, fitWindow, fitWidth, fitHeight, fill, fixed, devicePixel }
public enum SortKey: String, Codable, Sendable { case name, modified, created, size, type, random }
public struct SortSpec: Codable, Sendable, Hashable { public var key: SortKey; public var ascending: Bool; public var foldersFirst: Bool; public var randomSeed: UInt64? }
public struct RecursionSpec: Codable, Sendable, Hashable { public var enabled: Bool; public var maxDepth: Int }
public struct BookSettings: Codable, Sendable, Hashable {   // 每层只写自己覆盖的字段
    public var browseMode: BrowseMode?; public var pageMode: PageMode?; public var direction: ReadingDirection?
    public var firstPageSingle: Bool?; public var widePage: WidePagePolicy?; public var sort: SortSpec?; public var recursion: RecursionSpec?
    public var scaleMode: ScaleMode?; public var allowUpscale: Bool?; public var fixedScale: Double?; public var keepZoomOnPageTurn: Bool?
    public var resample: ResampleFilter?; public var sharpen: Float?
}   // “仅缩小不放大” = 适合类缩放模式 + allowUpscale=false
public struct ResolvedBookSettings: Codable, Sendable, Hashable { /* 与 BookSettings 字段相同，全部非可选 */ }
public struct GlobalSettings: Codable, Sendable { public var defaultBook: ResolvedBookSettings; public var cache: CacheBudgets; public var prefetch: PrefetchRanges; public var maxDecodeLongSide: Int }   // CacheBudgets、PrefetchRanges 的字段与默认值见 §3.4
public struct PathRule: Codable, Sendable { public var id: UUID; public var name: String; public var prefix: Location; public var settings: BookSettings }
public struct BookMemory: Codable, Sendable { public var book: Location; public var settings: BookSettings; public var lastPage: Location?; public var lastPageIndex: Int?; public var openedAt: Date }
public enum SettingsChange: Sendable { case global, pathRules, keyBindings, fileError(file: String, message: String) }
public protocol SettingsStore: Sendable {
    func resolve(for book: Location) async -> ResolvedBookSettings
    func bookMemory(for book: Location) async -> BookMemory?
    func saveBookMemory(_ memory: BookMemory) async
    func global() async -> GlobalSettings
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws
    func changes() -> AsyncStream<SettingsChange>
}

// MVCommands
public struct CommandID: Hashable, Codable, Sendable { public var rawValue: String }   // 例如 "page.next"
public enum InputScope: String, Codable, Sendable { case global, viewer, list, textInput }
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable { public let rawValue: UInt8 /* command, option, control, shift, function */ }
public struct KeyChord: Hashable, Codable, Sendable { public var key: String; public var modifiers: KeyModifiers }   // key 为逻辑键名，如 "Right"、"a"
public struct KeyBinding: Codable, Sendable { public var sequence: [KeyChord]; public var command: CommandID; public var arguments: [String: JSONValue]?; public var scope: InputScope }
public enum ResolveResult: Sendable { case command(CommandID, [String: JSONValue]?), pending([KeyChord]), unmatched }
public struct BindingResolver: Sendable { public init(bindings: [KeyBinding], sequenceTimeout: Duration); public mutating func feed(_ chord: KeyChord, scope: InputScope, at time: ContinuousClock.Instant) -> ResolveResult }
public struct CommandDescriptor: Sendable { public var id: CommandID; public var title: LocalizedStringResource; public var category: String; public var defaultBindings: [KeyBinding] }
public struct CommandContext: Sendable { public var session: SessionID?; public var scope: InputScope; public var selection: [Location] }
@MainActor public final class CommandRegistry {
    public func register(_ d: CommandDescriptor, isEnabled: @escaping @MainActor (CommandContext) -> Bool, perform: @escaping @MainActor (CommandContext, [String: JSONValue]?) async throws -> Void)
    public func perform(_ id: CommandID, arguments: [String: JSONValue]?, context: CommandContext) async throws
    public func descriptors() -> [CommandDescriptor]
}
public indirect enum MenuNode: Codable, Sendable { case command(CommandID), submenu(titleKey: String, children: [MenuNode]), separator }
public struct MenuModel: Codable, Sendable { public var roots: [MenuNode] }

// MVReading
public struct Page: Sendable, Identifiable { public var entry: Entry; public var metadata: ImageMetadata?; public var id: Location { get } }
public struct Book: Sendable { public var location: Location; public var pages: [Page]; public var isEnumerated: Bool }
public enum BookLoadEvent: Sendable { case appended([Page]), sorted([Page]), metadata([Location: ImageMetadata]) }
// 先按到达顺序 appended，枚举完成后发一次 sorted；metadata 按阅读顺序分批到达；流结束表示全部完成
public protocol BookLoader: Sendable { func load(_ location: Location, settings: ResolvedBookSettings) -> AsyncThrowingStream<BookLoadEvent, any Error> }
public enum ShelfEvent: Sendable { case appended([Entry]), sorted([Entry]) }
public enum NavigationDirection: Sendable { case forward, backward }
public protocol Bookshelf: Sendable {
    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error>   // 书：子文件夹与压缩包
    func cover(of book: Location, priority: IOPriority) async throws -> Location?
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location?
    func passThrough(_ location: Location) async throws -> Location
}
public enum PagePart: Sendable, Hashable { case whole, leftHalf, rightHalf }
public struct PageFrameElement: Sendable, Hashable { public var page: Int; public var part: PagePart }
public struct PageFrame: Sendable, Hashable { public var elements: [PageFrameElement] }   // 已按阅读方向排列
public struct PageLayout: Sendable, Hashable { public var pageMode: PageMode; public var direction: ReadingDirection; public var firstPageSingle: Bool; public var widePage: WidePagePolicy }
public enum PageFrameEngine { public static func frames(aspectRatios: [Double?], layout: PageLayout) -> [PageFrame] }
public enum PageMove: Sendable { case nextFrame, previousFrame, nextPage, previousPage, first, last, index(Int) }
@MainActor @Observable public final class ReaderSession {
    public let id: SessionID
    public private(set) var book: Book?; public private(set) var frames: [PageFrame]; public private(set) var currentFrame: Int
    public private(set) var settings: ResolvedBookSettings; public private(set) var loadError: (any Error)?
    public func open(_ location: Location, at page: Location?) async
    public func go(_ move: PageMove)
    public func openNeighborBook(_ direction: NavigationDirection) async
    public func update(_ change: (inout BookSettings) -> Void)   // 写入书层，去抖后持久化
    public func visibleRangeChanged(_ pages: Range<Int>)        // 连续和瀑布模式由前端回报
}

// MVServices
public struct CoreConfiguration: Sendable { public var supportDirectory: URL; public var cacheDirectory: URL }
@MainActor public final class CoreServices {
    public static func make(configuration: CoreConfiguration) async throws -> CoreServices
    public let sources: any SourceRegistry; public let pipeline: any ImagePipeline; public let settings: any SettingsStore
    public let commands: CommandRegistry; public let bookshelf: any Bookshelf
    public func makeSession() -> ReaderSession
    public func shutdown() async   // 有时限地等待，不等被卡住的 I/O 线程
}
// MVTestSupport：extension CoreServices { static func makeMock(_ options: MockOptions) -> CoreServices }
```

## 5. 关口

| 关口 | 时机 | 决定内容 | 依据 |
|---|---|---|---|
| G0 | S0 完成 | 见下方说明 | 见下方说明 |
| G1 | S1 完成 | 契约是否稳定，解码与管线是否满足预算；编写 S2 的任务文档 | 各任务的测试和集成测试 |
| G2 | S2 完成 | P0 是否完成 | requirements.md §5 的验收项全部实测通过 |
| G3–G5 | 各 P1 阶段末 | 阶段功能是否完成 | 阶段任务的验收 |
| G6 | 发布前 | 能否公开仓库 | P1 全部完成，隐私审查通过 |

G0 的决定内容：
- NAS 访问方式：用系统挂载（SMB 或 NFS），还是内置 SMB。
- 是否用 XPC 隔离网络 I/O。
- 契约定稿，把 S0-T4 的差异并入 §4。
- 编写 S1 的任务文档。

G0 的依据：
- S0-T2 的实测数据和复杂度估算。
- 用户的规则：只有在系统挂载上解决延迟的复杂度明显高于内置 SMB 时，才改用内置 SMB。
- 内置 SMB 会牵涉凭据管理、LGPL 动态链接和视频的读取方式，选它之前先征求用户同意。

在每个关口，向用户汇报结论与证据；需要用户决定的事项先询问。必要时更新本文，再编写下一阶段的任务文档。
