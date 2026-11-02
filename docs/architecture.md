# MacView 架构

状态：2026-10-31 定稿；2026-11-01 并入关口 G0 的决定。

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
| MVCache | 泛型内存缓存 L0/L1、字节磁盘缓存 L2/L3、按容器查询的图像元数据索引、目录缓存 | MVFoundation、GRDB.swift |
| MVPipeline | ImagePipeline：串联各缓存层，一次读取产出多种渲染件，渐进交付，按会话管理预取计划 | MVIO、MVMedia、MVCache |
| MVSettings | 设置模式、分层解析、路径规则、JSON 存储、书记忆 | MVFoundation、GRDB.swift |
| MVCommands | 命令登记、按键序列与作用域解析，以及默认命令、绑定与菜单模型 | MVFoundation |
| MVReading | Book/Page、BookLoader、Bookshelf、PageFrameEngine、ReaderSession | MVIO、MVMedia、MVCache、MVPipeline、MVSettings |
| MVServices | 组合根：创建并连接各服务，负责启动、退出和内存压力处理 | 以上全部 |
| MVTestSupport | Mock 与夹具清单（`Fixtures/manifest.json`）的读取。App 的 Debug 构建可以用启动参数 `-MVMockServices YES` 切换到 Mock | 契约 |
| mvbench | 基准测试与夹具生成的命令行工具 | 全部 |
| MVLayout | App 侧的纯计算：画布的四种布局与锚点、停靠布局及其变换。App 没有测试目标，放进包里才能用 `make test` 测 | MVFoundation、MVSettings |
| App（`MacView` target） | 窗口与标签页、停靠面板、集合视图、查看器、输入、菜单、设置界面、本地化 | MVServices 等 |

- 任务 ID 中，T 表示 Core 任务，F 表示 App 任务。
- P1 的新模块到对应阶段再建：MVLibraryData（书签、播放列表、历史）、MVFileOps、MVSearch、MVMetadata（评分与标签）、MVEffects、MVScripting、MVPlugins。
- 依赖选型：SQLite 统一用 GRDB.swift（MIT 许可），由第一个用到它的任务引入，MVCache 与 MVSettings 共用。其余依赖由各任务按需选用。
- 已引入的依赖（版本以 `Packages/MacViewKit/Package.resolved` 为准）：

  | 依赖 | 用途 | 许可证 | 引入任务 |
  |---|---|---|---|
  | swift-argument-parser 1.8.2 | mvbench 的子命令与参数解析 | Apache-2.0 | S0-T1 |
  | GRDB.swift 7.11.1 | MVCache 的 `index.sqlite` 与 MVSettings 的 `state.sqlite`，各自使用 WAL 数据库 | MIT | S1-T4、S1-T7 |
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
  - SMB/NFS 挂载路径按挂载来源（statfs 的 `f_mntfromname`）归一成 network 根，书记忆和历史因此不依赖 `/Volumes/xxx` 这个挂载名：
    - smbfs 的 `//user@server/share` → `network(smb, server, share)`。
    - nfs 的 `server:/export/path` → `network(nfs, server, export/path)`。
    - 挂载表用 `getfsstat(MNT_NOWAIT)` 读取，不访问卷本身，网络卷卡住时也不阻塞。不用 `volumeURLForRemountingKey`，它要查询卷。
  - 持久化时存结构化 JSON，字符串形式只用于显示。
  - 根没有挂载时返回 `volumeUnavailable`，界面提供“连接”按钮：用 NSWorkspace 打开 `smb://` 或 `nfs://` URL，由系统挂载。
- `ContentIdentity` 由位置、大小、修改时间（纳秒整数）和可选的校验值（如 zip 条目的 CRC32）组成，其稳定哈希就是缓存键。文件一变，缓存自然失效，不需要另做失效逻辑。

### 3.2 I/O 模型

- 访问方式（G0 决定，依据见 [S0-T2 报告](reports/S0-T2.md)）：
  - NAS 走系统挂载，不内置 SMB。推荐 NFS（`nfs://192.168.31.201/fs/1000/nfs`），小读延迟和冷枚举都优于 SMB。
  - NFS 和 SMB 用同一套代码。协议定下后不要再换：Location 的根随协议而变，换了以后书记忆、历史和缓存键都对不上。
- 通道：
  - 每个卷一条通道，内分两个子通道：元数据（枚举、stat、文件头探测）和大块读取。小请求因此不会排在 20 MB 的读取后面。
  - NAS 的取值：大块读取 4 并发、每次读 4 MB；元数据 4 并发。NFS 保持默认挂载参数，不调大 rsize（吞吐只高 4–14%，64 KB 小读却慢 4 倍）。
- 优先级：visible > near > book > adjacent > background。请求带 `IORequestGroup`，预取计划变更时可以整批取消或重排。
- 取消：排队中的请求直接移除；执行中的读取按 4 MB 分块，在块与块之间检查取消。
- 超时与卷健康：
  - 每次调用都有期限，默认 10 秒，不短于 5 秒。硬挂载在故障期间一直阻塞、不报错，所以期限是唯一的超时来源。
  - 超时后向调用方抛出 `.timeout`。底层被卡住的调用仍占着槽位，计为 stuck。
  - stuck 或超时次数超过阈值时，卷标为 degraded：新请求立即失败，只保留定期的健康探测，探测成功即恢复。
  - 卷状态以流的形式提供给界面显示。
  - 网络卷上的读失败时，重新打开文件再试一次：断开较久（实测 60 秒）后恢复时，故障中的那次读会返回错误。
- 枚举优先用 `getattrlistbulk` 分批返回，书和书架因此能渐进显示。
- 路径与 URL 的互转不能访问文件系统：用 `URL(filePath:directoryHint:)`，不用不带 `isDirectory` 的 `URL(fileURLWithPath:)`，后者会在调用线程上 stat 该路径，网络卷卡住时调用方跟着卡住（S1-T1 实测）。
- 进程隔离（G0 决定）：
  - 网络卷（statfs 不带 `MNT_LOCAL`）上的阻塞调用都在辅助进程中执行，本机卷仍在进程内，对外接口不变。
  - 原因：SMB 和 NFS 硬挂载上卡住的调用会让进程无法退出，exit(0) 和 SIGKILL 都无效，直到网络恢复。MacView 不能决定用户怎样挂载。
  - 卡住的辅助进程整体弃用，健康探测时换新的；主进程退出时不等它，它在网络恢复后自行消失。
  - 视频也要隔离：用 AVAssetResourceLoader 从辅助进程按范围取数据，不让 AVFoundation 在进程内读网络卷。
  - 辅助进程由 posix_spawn 起宿主自己的可执行文件（环境变量 `MVIO_HELPER=1`），经 socketpair 收发二进制帧，读到 EOF 即退出（S1-T1）。不用 launchd 托管的 XPC 服务：同一 App 域内只有一个实例，卡住的实例活着时无法换新的。
  - 卡住的辅助进程被弃用时发 SIGKILL 并关闭 socket，下一个请求起新的辅助进程。
- 健康探测在挂载点下查找一个随机的、不存在的名字，得到 ENOENT 即恢复。新名字不在缓存里，查找必须问服务器。不用 stat 挂载点或 statfs：服务器不可达时，前者由属性缓存回答，后者约 10 秒后返回缓存的值，都报成功，卷会在 healthy 与 degraded 之间反复切换（S1-T1 实测）。

### 3.3 媒体与渲染件

- 探测：
  - 增量读取文件头：从 64 KB 开始，不够再扩大，上限 1 MB。
  - 用 `CGImageSourceCreateIncremental` 获取尺寸（按 EXIF 方向换算后）、帧数、拍摄时间和色彩信息。
  - 视频用 AVURLAsset 获取时长和尺寸。
  - 动图（GIF、带 acTL 的 APNG、带动画标志的 WebP）要整个文件才能得到帧数和时长，探测返回 `needsMoreData(nil)`；静态图只要文件头。
- 显示尺寸解码（依据见 [S1-T3 报告](reports/S1-T3.md)）：
  - 用 `CGImageSourceCreateThumbnailAtIndex` 降采样解码，参数为 MaxPixelSize、WithTransform 和 `ShouldCacheImmediately=true`。MaxPixelSize 只取原图的 1、1/2、1/4、1/8，JPEG 因此直接在 DCT 域缩小，不经 ImageIO 自己的重采样；级别可以比目标小 10%。
  - 再用 vImage 的 Lanczos 精确缩放到目标尺寸，缩小后可以选择锐化。MPS 用时相同（含上传和读回），但要和渲染争 GPU，所以用 vImage。
  - 输出是已解码的 32 位 BGRA 位图，写在 IOSurface 里，再用直接访问的 CGDataProvider 把同一块内存包成 CGImage，供绘制和编码使用。
  - 前端把 `RenderedImage.surface` 设为 `CALayer.contents`。在窗口里提交一张长边 2560 的图，主线程用时：惰性图像 40 ms（解码并复制），已解码的 CGImage 16 ms（复制给窗口服务器），IOSurface 0.2 ms。
  - IOSurface 用 `kIOSurfaceColorSpace` 标记色彩空间，CA 按标记做色彩匹配；没有标记时按 sRGB 处理。
  - RGB 图保留自己的色彩空间（Display P3 等），灰度、CMYK 转为 sRGB，16 位转为 8 位。
  - 解码在并发上限为性能核心数的专用队列上执行，等待中的按调用方任务的优先级出队。
- 原图与大图：
  - 放大到超过解码上限时，解码原图。
  - 长边超过 `maxDecodeLongSide` 或纹理上限（16384）的图用分块源。每个缩小级别一张不缓存像素的 CGImage，分块时裁出区域绘制，ImageIO 只解码需要的部分，不预先切块落盘。每个级别第一次取块时 ImageIO 要扫描一遍压缩数据，所以首块之后在后台预热原尺寸级别。
- 渲染件：一次完整读取产出以下几种，编码用 JPEG（质量 0.8）：解码比 HEIC 快 4–6 倍，文件约大一倍。
  - 缩略图：暂定长边 1024 px。
  - 浏览图：等比缩放到能放进最大显示器的像素尺寸。
  - 元数据。
- 动图通过帧源按需逐帧解码，播放节奏由前端的显示链接驱动。
- 视频：
  - 封面用 AVAssetImageGenerator 生成，取 1 秒处和 10% 处中较早的一帧。
  - 本机卷上 AVFoundation 自己读文件；网络卷上经 AVAssetResourceLoader 走 I/O 调度的大块读取通道（§3.2 进程隔离），并发上限和卷健康统计因此保持一致。

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
  - 用 NSWindowRestoration 恢复窗口、书和页（S2-F3）。
- 菜单与快捷键：
  - 菜单由命令清单生成。global 作用域的绑定是真正的菜单快捷键，焦点在文本框里或没有窗口时也可用。
  - 其余作用域的绑定只在菜单打开时（`menuWillOpen`）写到菜单项上，关闭后清除，按键一律经 InputRouter 路由。
  - 原因：菜单项一直带着 →、⌘G 这类快捷键时，AppKit 会在按键到达响应链之前匹配它们，菜单项不可用时还会吞掉按键；`menuHasKeyEquivalent` 返回 false 也拦不住（S1-F1 实测）。
- 停靠框架：
  - NSSplitView 分出左、中、右三栏，底部区在中间栏下方。
  - 每个区放一个面板栈（标签页或上下分割），面板可以拖到别的区。
  - 浮动面板全应用只有一份，是共享的 NSPanel，作用于当前活动窗口。
  - 全屏时停靠区自动隐藏，鼠标靠近边缘时浮出。
  - S1-F2 的结论（[报告](reports/S1-F2.md)）：
    - “折叠”就是隐藏：区不占空间，面板与尺寸保留，没有只剩标题条的形态。区头按钮、显示命令、把分隔线拖到边缘，效果相同。
    - 面板浮动后，其他窗口中停靠着的同一面板随之移走。拖回某个窗口后，其他窗口不会自动出现这个面板。
    - 每个窗口的布局只有停靠区是自己的。`layout.json` 只存一份：最近一次改动所在窗口的完整布局，它也是新窗口的默认布局。
    - 面板在区、窗口、停靠与浮动之间移动时，保留同一实例与视图设置。
    - 只有同时满足三个条件才算用户拖动分隔线：通知带分隔线序号；当前事件是本窗口的鼠标事件；不在窗口缩放中，也不是程序在设置位置。NSSplitView 初次布局时也发带序号的通知。
    - 浮动面板用 `hidesOnDeactivate`（App 失去焦点时隐藏）和 `fullScreenAuxiliary`（可以浮在全屏窗口之上）。
    - 占位面板沿用正式标识 `bookshelf`、`pageList`，S2-F2 只替换面板类型，`layout.json` 和快捷键不变。
- 画布引擎：
  - 基于 NSScrollView，利用它原生的滚动、惯性和捏合缩放。内容是图层池，不为每一项建一个 NSView。
  - LayoutModel 有砌体、网格、纵向条、横向条四种，布局变化时保持可见锚点。
  - 把可见范围和余量回报给预取计划。
  - 同一个引擎服务连续模式、主区瀑布流和画廊面板。
  - S0-F1 的结论（[报告](reports/S0-F1.md)）：
    - 1 万项、120 Hz 下，真实触控板滚动的帧时间 P99 为 8.33 ms。图层数由可见区决定（约 55 个）。
    - 图层内容只用已解码、IOSurface 支撑的图像，避免在提交时复制。
    - 图片突发到达时，每帧设置图层内容的数量有限额。
    - 滚动走 NSScrollView 自己的路径，不在显示链接回调里改滚动位置；卡顿验收用真实的滚动输入。
  - S1-F3 的结论（[报告](reports/S1-F3.md)）：
    - 布局和锚点是纯计算，在 MVLayout。自动场景的 App 侧统计：滚动更新 P99 ≤ 0.33 ms，全量重排 P99 ≤ 0.62 ms。
    - 只排最长前缀的规则适用于砌体和两种条；网格与宽高比无关，所有项都排。
    - 视口尺寸的任何变化都做全量重排，P99 不到 1 ms，不另设只改内容尺寸的路径。
    - 锚点分两种：尺寸、种类、方向变化时取前沿落在视口内的第一项；整体重排时取选中项，没有时取中心项。
    - 缩略图逐项调用 `thumbnail(for:)`，因为项滚出余量时要逐个取消，批量流只能整体取消。请求按项的实际像素尺寸，不封顶 1024。
    - 滚动停止 50 ms 后结算（一个推迟触发时间的计时器），补发请求，并通过闭包 `onVisibleRangeChange` 回报 `visible` 和 `margin` 两个范围，由调用方接到 `ReaderSession.visibleRangeChanged` 或面板的预取。
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

契约已由 S0-T4 落成代码，实现时的调整已在 G0 并入本节。字段与默认值、行为约定等细节以代码和文档注释为准，说明见 [S0-T4 报告](reports/S0-T4.md)。修改公开接口时同步更新本节。

```swift
// MVFoundation
public struct Location: Hashable, Sendable, Codable {
    public enum Root: Hashable, Sendable, Codable { case local; case network(scheme: String, host: String, share: String); case plugin(id: String) }
    public var root: Root
    public var layers: [[String]]
}
public struct ContentIdentity: Hashable, Sendable, Codable { public var location: Location; public var size: Int64; public var modificationNanos: Int64; public var checksum: UInt32?; public var cacheKey: String { get } }
public struct PixelSize: Hashable, Sendable, Codable { public var width: Int; public var height: Int }
public struct ImageMetadata: Sendable, Codable, Hashable { public var pixelSize: PixelSize; public var frameCount: Int; public var duration: Double?; public var capturedAt: Date?; public var colorSpace: String? }   // pixelSize 已按 EXIF 方向换算
public enum ArchiveFormat: String, Sendable, Codable { case zip, tar, tarGzip, gzip }
public enum EntryKind: Hashable, Sendable, Codable { case directory, archive(ArchiveFormat), image, video, other; public init(fileName: String) }   // init 按扩展名判断，不读内容
public struct Entry: Hashable, Sendable, Codable { public var identity: ContentIdentity; public var name: String; public var kind: EntryKind; public var created: Date? }   // location、size、modified 由 identity 计算
public struct SessionID: Hashable, Sendable { public let raw: UUID }
public enum JSONValue: Hashable, Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public enum ResampleFilter: String, Sendable, Codable { case lanczos, nearest }   // MVSettings 也要用，所以放在这里
public enum NameOrder { public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult }   // 数字感知与中文拼音排序

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
public enum IOError: Error, Sendable { case timeout, cancelled, volumeUnavailable(Location.Root), volumeDegraded(Location.Root), notFound(Location), unsupported(Location), corrupted(Location, String), underlying(String) }   // volumeDegraded：卷连续超时，暂停访问
public protocol SourceRegistry: Sendable {
    func provider(for location: Location) throws -> any ContainerProvider
    func location(for fileURL: URL) async throws -> Location   // 打开面板与拖放的入口；要查询卷信息，所以是异步的
    func volumeHealth() -> AsyncStream<[VolumeHealth]>
}
extension Location.Root { public var mountURL: URL? { get } }   // “连接”按钮交给 NSWorkspace 打开的 smb:// 或 nfs:// URL
public struct IOConfiguration: Sendable { public var local, network: Channels; public var smallReadLimit: Int; public var deadline: Duration; public var degradeAfterTimeouts: Int; public var probeInterval: Duration; public var helperExecutable: URL?; public init(helperExecutable: URL?) }   // Channels：metadata、bulk 并发与 chunk
public final class IOScheduler: Sendable {
    public init(configuration: IOConfiguration)
    public func cancel(_ group: IORequestGroup)                       // 排队中的出队，之后的新请求立即失败
    public func setPriority(_ priority: IOPriority, for group: IORequestGroup)
    public func volumeHealth() -> AsyncStream<[VolumeHealth]>
    public func shutdown()                                            // 杀掉辅助进程，不等卡住的调用
}
public final class FileSystemProvider: ContainerProvider { public init(scheduler: IOScheduler) }   // 一层的 Location：本机与系统挂载
public final class FileSourceRegistry: SourceRegistry { public init(scheduler: IOScheduler); public let scheduler: IOScheduler; public let fileSystem: FileSystemProvider; public func register(_ provider: any ContainerProvider) }   // provider(for:) 先问登记的 provider，再交给 fileSystem；压缩包 provider 由组合根登记
public enum IOHelper { public static func runIfRequested() }   // 宿主 main 开头调用：作为辅助进程启动时进入请求循环，不返回
public final class ByteSourceAsset: Sendable { public let asset: AVURLAsset; public init(source: any ByteSource, priority: IOPriority = .visible) }   // 网络卷视频经 AVAssetResourceLoader 读取；调用方持有它直到不再用 asset

// MVArchive
public final class ArchiveProvider: ContainerProvider {
    public init(fileSystem: FileSystemProvider, extractDirectory: URL, extractBudget: Int64 = 10 << 30) throws
}   // 启动清空 extractDirectory；认领压缩包与多层位置，不持有 registry。压缩包自身的 entry/open/fileURL 交给所在层，children 列出包内条目
// fileURL 最近一次返回的临时路径保留到下一次 fileURL 交付或 provider 释放；ByteSource 存活期间保留对应解出文件

// MVCache：键由调用方用 ContentIdentity.cacheKey 生成；本模块不决定预取策略
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public init(budget: Int64)
    public func value(for key: Key) -> Value?                         // 命中后移到最近使用
    public func insert(_ value: Value, for key: Key, cost: Int64)     // 单项超过预算不存
    public func removeValue(for key: Key)
    public var budget: Int64 { get }; public var totalCost: Int64 { get }
    public func setBudget(_ budget: Int64)                            // 缩小时立即淘汰
    public func trim(toFraction fraction: Double)                     // warning 0.5 / critical 0.25，预算不变；MVServices 统一订阅压力
}
public final class CacheIndex: Sendable { public init(databaseURL: URL) throws; public func flush() async throws }   // 单 DatabasePool/WAL，访问时间批量写回；shutdown 调用 flush
public enum DiskTier: String, Sendable { case thumbnails, browse }
public final class DiskCache: Sendable {
    public init(tier: DiskTier, cacheDirectory: URL, budget: Int64, index: CacheIndex) throws
    public func data(for key: String) async throws -> Data?
    public func data(for keys: [String]) async throws -> [String: Data]   // 先查索引，并发读文件
    public func store(_ data: Data, for key: String) async throws       // 临时文件 → 改名 → 索引，超预算按访问时间淘汰
    public func setBudget(_ budget: Int64) async throws
}   // 文件位于 cacheDirectory/<tier>/<键前两位>/；启动只清 tmp/，不扫描其余分目录；淘汰时抽查孤儿
public final class MetadataIndex: Sendable {
    public init(index: CacheIndex)
    public func values(in container: Location) async throws -> [String: ImageMetadata]   // 一次按容器的索引范围查询，取回该容器内全部条目
    public func values(for keys: [String]) async throws -> [String: ImageMetadata]
    public func store(_ values: [String: ImageMetadata], in container: Location) async throws   // container 为条目所在的容器，即 location.parent
}
public struct DirectoryListing: Codable, Sendable, Hashable { public var entries: [Entry]; public var directoryModificationNanos: Int64?; public init(entries: [Entry], directoryModificationNanos: Int64? = nil) }
public struct ListingDiff: Sendable, Hashable { public var added: [Entry]; public var removed: [Location]; public var changed: [Entry]; public init(added: [Entry], removed: [Location], changed: [Entry]) }   // changed：同一位置的 identity 变了
public final class DirectoryCache: Sendable {
    public init(index: CacheIndex)
    public func cachedChildren(of container: Location) async throws -> DirectoryListing?
    public func update(_ container: Location, listing: DirectoryListing) async throws -> ListingDiff
}

// MVMedia
public struct DisplayTarget: Sendable, Hashable { public var pixelSize: PixelSize; public var filter: ResampleFilter; public var sharpen: Float }
public enum RenditionQuality: Int, Sendable, Comparable { case placeholder, browse, exact, original }
public struct RenderedImage: @unchecked Sendable { public let image: CGImage; public let quality: RenditionQuality; public let surface: IOSurface? }   // surface 与 image 共用像素、带色彩空间标记，设为 CALayer.contents 时用它；Mock 的图像没有
public protocol AnimatedFrameSource: Sendable { var frameCount: Int { get }; var loopCount: Int { get }; func duration(at index: Int) -> Double; func frame(at index: Int) async throws -> RenderedImage }   // loopCount 为文件记录的循环次数，0 为无限
public protocol TiledImageSource: Sendable { var pixelSize: PixelSize { get }; func tile(_ rect: CGRect, scale: Double) async throws -> RenderedImage }   // rect 为显示方向下原图的像素坐标
public enum MediaError: Error, Sendable, Equatable { case unsupported, decodeFailed(String), requiresTiling(PixelSize) }
public enum ProbeResult: Sendable, Equatable { case metadata(ImageMetadata), needsMoreData(Int?) }   // nil：需要整个文件（动图）
public enum MediaProbe {
    public static let initialHeaderLength: Int   // 64 KB
    public static let headerLimit: Int           // 1 MB，超过后改要整个文件
    public static func image(_ data: Data, isComplete: Bool) throws(MediaError) -> ProbeResult
    public static func video(_ asset: AVAsset) async throws -> ImageMetadata
}
public final class ImageDecoder: Sendable {   // 不做 I/O；解码在并发上限为性能核心数的专用队列上，等待中的按调用方任务的优先级出队
    public static let defaultConcurrency: Int; public static let maxTextureSide: Int
    public init(maxConcurrentDecodes: Int = ImageDecoder.defaultConcurrency)
    public static func needsTiling(_ size: PixelSize, maxDecodeLongSide: Int) -> Bool
    public func image(_ data: Data, target: DisplayTarget, quality: RenditionQuality = .exact) async throws -> RenderedImage   // 也用来解码缓存的渲染件
    public func original(_ data: Data, maxDecodeLongSide: Int) async throws -> RenderedImage   // 超限抛出 requiresTiling
    public func tiledSource(_ data: Data) throws(MediaError) -> any TiledImageSource
    public func animatedFrames(_ data: Data, target: DisplayTarget) throws(MediaError) -> any AnimatedFrameSource
    public func videoPoster(_ asset: AVAsset, maxPixel: Int) async throws -> RenderedImage
}
extension PixelSize { public func fitting(longSide: Int) -> PixelSize; public func fitting(within bounds: PixelSize) -> PixelSize }   // 等比缩小，不放大
public enum RenditionEncoding: String, Sendable, Codable, CaseIterable { case heic, jpeg; public static let `default`: RenditionEncoding /* jpeg */; public static let defaultQuality: Double /* 0.8 */; public func encode(_ image: CGImage, quality: Double = defaultQuality) throws(MediaError) -> Data }

// MVPipeline
public enum RenditionSpec: Sendable, Hashable { case metadata, thumbnail, browse, display(DisplayTarget) }
public struct PrefetchItem: Sendable, Hashable { public var identity: ContentIdentity; public var renditions: Set<RenditionSpec>; public var priority: IOPriority; public init(identity: ContentIdentity, renditions: Set<RenditionSpec>, priority: IOPriority) }   // renditions 为空表示仅读取原始字节
public struct PrefetchPlan: Sendable, Equatable { public var items: [PrefetchItem]; public init(items: [PrefetchItem] = []) }
public protocol ImagePipeline: Sendable {
    func metadata(for identity: ContentIdentity, priority: IOPriority) async throws -> ImageMetadata
    func thumbnail(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage
    func thumbnails(for identities: [ContentIdentity], maxPixel: Int, priority: IOPriority) -> AsyncStream<(ContentIdentity, Result<RenderedImage, any Error>)>
    func image(for identity: ContentIdentity, target: DisplayTarget, allowOriginal: Bool, priority: IOPriority) -> AsyncThrowingStream<RenderedImage, any Error>
    func tiledSource(for identity: ContentIdentity) async throws -> any TiledImageSource
    func animatedFrames(for identity: ContentIdentity, target: DisplayTarget) async throws -> any AnimatedFrameSource
    func videoPoster(for identity: ContentIdentity, maxPixel: Int) async throws -> RenderedImage
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID)
    func cancelAll(session: SessionID)
}
public struct PipelineCaches: Sendable {
    public var raw: MemoryCache<String, Data>; public var decoded: MemoryCache<String, RenderedImage>
    public var thumbnails: DiskCache; public var browse: DiskCache?; public var metadata: MetadataIndex
    public init(raw: MemoryCache<String, Data>, decoded: MemoryCache<String, RenderedImage>, thumbnails: DiskCache, browse: DiskCache?, metadata: MetadataIndex)
}   // 生命周期、预算与 flush 由组合根管理
public struct PipelineConfiguration: Sendable {
    public var thumbnailLongSide: Int; public var browseBounds: PixelSize; public var maxDecodeLongSide: Int
    public init(thumbnailLongSide: Int = 1024, browseBounds: PixelSize, maxDecodeLongSide: Int = 16384)
}
public final class FileImagePipeline: ImagePipeline {
    public init(sources: any SourceRegistry, decoder: ImageDecoder, caches: PipelineCaches, configuration: PipelineConfiguration)
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
public enum SettingsChange: Sendable, Equatable { case global, pathRules, fileError(file: String, message: String) }
public protocol SettingsStore: Sendable {
    func resolve(for book: Location) async -> ResolvedBookSettings
    func bookMemory(for book: Location) async -> BookMemory?
    func saveBookMemory(_ memory: BookMemory) async
    func global() async -> GlobalSettings
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws
    func changes() -> AsyncStream<SettingsChange>
}
public enum DocumentChange: Sendable, Equatable { case reloaded, fileError(message: String) }   // 解析错误带行列号，保留上一份可用值
public final class JSONDocumentStore<Value: Codable & Sendable>: Sendable {
    public convenience init(fileURL: URL, version: Int, defaultValue: Value) throws
    public func value() -> Value
    public func update(_ change: @Sendable (inout Value) -> Void) async throws
    public func changes() -> AsyncStream<DocumentChange>
}   // 顶层 {"version": Int, "value": Value}；原子写入并监听外部修改，未来版本报 fileError；缺文件时首次 update 才写出
public final class FileSettingsStore: SettingsStore { public init(directory: URL) throws; public func flush() async throws }   // settings.json、path-rules.json 与 state.sqlite（书记忆），shutdown 调用 flush
// keybindings.json 由 MVServices 用 JSONDocumentStore<KeyBindingsFile> 管理；App 可用同一存储管理 layout.json

// MVCommands
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable { public var rawValue: String; public init(_ rawValue: String) }   // 例如 "page.next"，JSON 中为字符串
public enum InputScope: String, Codable, Sendable { case global, viewer, list, textInput }
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable { public let rawValue: UInt8 /* command, option, control, shift, function */ }
public struct KeyChord: Hashable, Codable, Sendable { public var key: String; public var modifiers: KeyModifiers }   // key 为逻辑键名，如 "Right"、"a"
public struct KeyBinding: Codable, Sendable, Hashable { public var sequence: [KeyChord]; public var command: CommandID; public var arguments: [String: JSONValue]?; public var scope: InputScope }
public enum ResolveResult: Sendable, Equatable { case command(CommandID, [String: JSONValue]?), pending([KeyChord]), unmatched }
public struct BindingResolver: Sendable { public init(bindings: [KeyBinding], sequenceTimeout: Duration = .seconds(1)); public mutating func feed(_ chord: KeyChord, scope: InputScope, at time: ContinuousClock.Instant) -> ResolveResult; public static func conflicts(in bindings: [KeyBinding]) -> [BindingConflict] }   // 同作用域的相同序列或前缀冲突；textInput 不回退全局
public struct KeyBindingsFile: Codable, Sendable, Hashable { public var bindings: [KeyBinding]; public init(bindings: [KeyBinding] = []) }
public struct BindingConflict: Sendable, Hashable { public var scope: InputScope; public var first: KeyBinding; public var second: KeyBinding; public init(scope: InputScope, first: KeyBinding, second: KeyBinding) }
extension KeyBinding { public static func effective(defaults: [CommandDescriptor], user: [KeyBinding]) -> [KeyBinding] }   // 用户按命令覆盖全部默认绑定；空序列可取消默认绑定
public struct CommandDescriptor: Sendable { public var id: CommandID; public var title: LocalizedStringResource; public var category: String; public var defaultBindings: [KeyBinding] }
public struct CommandContext: Sendable { public var session: SessionID?; public var scope: InputScope; public var selection: [Location] }
public enum CommandError: Error, Sendable, Equatable { case unknownCommand(CommandID), disabled(CommandID) }
@MainActor public final class CommandRegistry {
    public init()
    public func register(_ d: CommandDescriptor, isEnabled: @escaping @MainActor (CommandContext) -> Bool, perform: @escaping @MainActor (CommandContext, [String: JSONValue]?) async throws -> Void)
    public func isEnabled(_ id: CommandID, context: CommandContext) -> Bool   // 菜单项和工具栏按钮用
    public func perform(_ id: CommandID, arguments: [String: JSONValue]?, context: CommandContext) async throws   // 没登记或不可用时抛出 CommandError
    public func descriptors() -> [CommandDescriptor]
}
public indirect enum MenuNode: Codable, Sendable, Hashable { case command(CommandID), submenu(titleKey: String, children: [MenuNode]), separator }
public struct MenuModel: Codable, Sendable, Hashable { public var roots: [MenuNode] }
public enum CoreCommands { public static let all: [CommandDescriptor]; public static let defaultMenu: MenuModel }   // P0 命令；文件、显示、翻页、书、窗口；标题用中文键与 .main bundle
extension CommandID {   // 每个默认命令一个常量，rawValue 见 Sources/MVCommands/CoreCommands.swift
    public static let frameNext, framePrevious, pageNext, pagePrevious, pageFirst, pageLast, pageJump: CommandID
    public static let bookNext, bookPrevious, fileOpen, bookReveal: CommandID
    public static let browsePaged, browseWaterfall, browseVerticalStrip, browseHorizontalStrip: CommandID
    public static let pageModeToggle, readingDirectionToggle, firstPageSingleToggle, widePageAsIs, widePageSingle, widePageSplit: CommandID
    public static let zoomOriginal, zoomFitWindow, zoomFitWidth, zoomFitHeight, zoomFill, zoomFixed, zoomDevicePixel, zoomIn, zoomOut: CommandID
    public static let zoomAllowUpscaleToggle, magnifierToggle, keepZoomOnPageTurnToggle: CommandID
    public static let sortName, sortModified, sortCreated, sortSize, sortType, sortRandom, sortAscending, sortDescending, sortFoldersFirstToggle, recursionToggle: CommandID
    public static let windowNew, windowNewTab, fullScreenToggle, bookshelfToggle, pageListToggle, docksToggle, retryFailed, settingsOpen: CommandID
}

// MVReading
public struct Page: Sendable, Identifiable, Hashable { public var entry: Entry; public var metadata: ImageMetadata?; public var id: Location { get }; public init(entry: Entry, metadata: ImageMetadata? = nil) }
public struct Book: Sendable, Hashable { public var location: Location; public var pages: [Page]; public var isEnumerated: Bool; public init(location: Location, pages: [Page] = [], isEnumerated: Bool = false) }
public enum BookLoadEvent: Sendable { case appended([Page]), sorted([Page]), metadata([Location: ImageMetadata]) }
// 缓存未命中时按到达顺序 appended，枚举完成后发 sorted；缓存命中时先发缓存的 sorted，不发 appended，后台刷新有差异时再发 sorted。
// metadata 先交付缓存，再从 startingAt 开始探测；流结束表示全部完成。ReaderSession 收到 sorted 时按页身份保持当前页。
public protocol BookLoader: Sendable { func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> }
public final class FileBookLoader: BookLoader {
    public init(sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex, pipeline: any ImagePipeline)
}
public enum ShelfEvent: Sendable { case appended([Entry]), sorted([Entry]) }
public enum NavigationDirection: Sendable { case forward, backward }
public protocol Bookshelf: Sendable {
    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error>   // 书：子文件夹与压缩包
    func cover(of book: Location, priority: IOPriority) async throws -> Location?
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location?
    func passThrough(_ location: Location) async throws -> Location
}
public final class FileBookshelf: Bookshelf { public init(sources: any SourceRegistry, directories: DirectoryCache) }
public enum PagePart: Sendable, Hashable { case whole, leftHalf, rightHalf }
public struct PageFrameElement: Sendable, Hashable { public var page: Int; public var part: PagePart; public init(page: Int, part: PagePart = .whole) }
public struct PageFrame: Sendable, Hashable { public var elements: [PageFrameElement]; public init(elements: [PageFrameElement]) }   // 元素按画面从左到右，页帧序列按阅读顺序
public struct PageLayout: Sendable, Hashable { public var pageMode: PageMode; public var direction: ReadingDirection; public var firstPageSingle: Bool; public var widePage: WidePagePolicy; public init(pageMode: PageMode, direction: ReadingDirection, firstPageSingle: Bool, widePage: WidePagePolicy) }
public enum PageFrameEngine { public static func frames(aspectRatios: [Double?], layout: PageLayout) -> [PageFrame] }
public enum PageMove: Sendable, Equatable { case nextFrame, previousFrame, nextPage, previousPage, first, last, index(Int) }
@MainActor @Observable public final class ReaderSession {
    public let id: SessionID
    public init(id: SessionID = SessionID(), loader: any BookLoader, settings: any SettingsStore, bookshelf: any Bookshelf, pipeline: any ImagePipeline)   // 由 CoreServices.makeSession() 调用
    public private(set) var book: Book?; public private(set) var frames: [PageFrame]; public private(set) var currentFrame: Int
    public private(set) var settings: ResolvedBookSettings; public private(set) var loadError: (any Error)?
    public func open(_ location: Location, at page: Location?) async
    public func go(_ move: PageMove)
    public func openNeighborBook(_ direction: NavigationDirection, sort: SortSpec) async   // sort 是书架面板当前的排序，与书内页面的排序无关
    public func update(_ change: (inout BookSettings) -> Void)   // 写入书层，去抖后持久化
    public func visibleRangeChanged(_ pages: Range<Int>)        // 连续和瀑布模式由前端回报
}
// 分页模式预读阅读方向上的原始字节，以及全书缩略图和元数据；本阶段不按视口尺寸预解码。

// MVServices
public struct CoreConfiguration: Sendable { public var supportDirectory: URL; public var cacheDirectory: URL }
@MainActor public final class CoreServices {
    public static func make(configuration: CoreConfiguration) async throws -> CoreServices   // S1-T8 实现
    public init(sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore, commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader)   // BookLoader 私有持有，供 makeSession() 使用
    public let sources: any SourceRegistry; public let pipeline: any ImagePipeline; public let settings: any SettingsStore
    public let commands: CommandRegistry; public let bookshelf: any Bookshelf
    public func makeSession() -> ReaderSession
    public func shutdown() async   // 有时限地等待，不等被卡住的 I/O 线程
}
// MVTestSupport：extension CoreServices { static func makeMock(_ options: MockOptions = MockOptions()) -> CoreServices }

// MVLayout：App 侧的纯计算，不依赖 AppKit
public enum CollectionLayoutKind: String, Codable, Sendable, CaseIterable { case masonry, grid, verticalStrip, horizontalStrip; public var isHorizontal: Bool { get } }
public enum LayoutMove: Sendable { case up, down, left, right }
public struct LayoutAnchor: Sendable, Hashable { public var index: Int; public var offset: Double; public var extent: Double; public init(index: Int, offset: Double, extent: Double) }
// offset 是沿阅读方向，锚点项前沿到视口前沿的点数，项跨过视口前沿时为负；此时按 extent 把 offset 换算到项的新长度。
public struct CollectionLayout: Sendable {   // 砌体和两种条只排已知宽高比的最长前缀；网格与宽高比无关，所有项都排
    public let kind: CollectionLayoutKind; public let viewportSize: CGSize; public let itemExtent: Double; public let spacing: Double; public let direction: ReadingDirection
    public private(set) var contentSize: CGSize; public let columnCount: Int
    public init(kind: CollectionLayoutKind, viewportSize: CGSize, itemExtent: Double, spacing: Double, direction: ReadingDirection)
    public var count: Int { get }
    public mutating func setAspectRatios(_ ratios: [Double?])   // 已排部分不变时在尾部追加，变了就从头重排
    public func frame(of index: Int) -> CGRect?
    public func items(in rect: CGRect) -> [(index: Int, frame: CGRect)]
    public func index(moving index: Int, _ move: LayoutMove) -> Int?   // 方向键：按画面几何找相邻项
    public func leadingAnchor(in viewport: CGRect) -> LayoutAnchor?   // 尺寸、种类、方向变化时用
    public func reorderAnchor(in viewport: CGRect, selected: Int?) -> LayoutAnchor?   // 整体重排时用：选中项，没有时取中心项
    public func viewportOrigin(restoring anchor: LayoutAnchor) -> CGPoint?   // 锚点项还没排时为 nil
}
public struct PanelID: RawRepresentable, Hashable, Codable, Sendable, CodingKeyRepresentable { public var rawValue: String; public init(rawValue: String); public init(_ rawValue: String) }
public enum DockEdge: String, Codable, Sendable, CaseIterable { case left, right, bottom }
public enum DockStackStyle: String, Codable, Sendable { case tabs, split }
public struct DockArea: Codable, Sendable, Hashable {
    public var panels: [PanelID]; public var style: DockStackStyle; public var selected: PanelID?; public var weights: [PanelID: Double]; public var size: Double; public var isCollapsed: Bool
    public init(panels: [PanelID] = [], style: DockStackStyle = .tabs, selected: PanelID? = nil, weights: [PanelID: Double] = [:], size: Double, isCollapsed: Bool = false)
}
public struct DockFrame: Codable, Sendable, Hashable { public var x: Double; public var y: Double; public var width: Double; public var height: Double; public init(x: Double, y: Double, width: Double, height: Double) }
public struct FloatingPanel: Codable, Sendable, Hashable {
    public var panel: PanelID; public var frame: DockFrame; public var home: DockEdge; public var isHidden: Bool; public var settings: JSONValue?
    public init(panel: PanelID, frame: DockFrame, home: DockEdge, isHidden: Bool = false, settings: JSONValue? = nil)
}
public enum DockTarget: Hashable, Sendable { case area(DockEdge, index: Int), floating(DockFrame) }   // index 是可见面板中的位置
public enum PanelPlacement: Hashable, Sendable { case docked(DockEdge, index: Int), floating(index: Int) }   // docked 的 index 含隐藏的面板
public struct DockLayout: Codable, Sendable, Hashable {   // layout.json 的内容；变换都是纯函数，返回新的布局
    public var left: DockArea; public var right: DockArea; public var bottom: DockArea
    public var floating: [FloatingPanel]; public var hidden: Set<PanelID>; public var settings: [PanelID: JSONValue]
    public init(left: DockArea, right: DockArea, bottom: DockArea, floating: [FloatingPanel] = [], hidden: Set<PanelID> = [], settings: [PanelID: JSONValue] = [:])
    public subscript(edge: DockEdge) -> DockArea { get }
    public func placement(of panel: PanelID) -> PanelPlacement?
    public func visiblePanels(in edge: DockEdge) -> [PanelID]
    public func isShowing(_ edge: DockEdge) -> Bool
    public func currentTab(in edge: DockEdge) -> PanelID?
    public func isPanelVisible(_ panel: PanelID) -> Bool
    public func settings(of panel: PanelID) -> JSONValue?
    public func moving(_ panel: PanelID, to target: DockTarget) -> DockLayout
    public func inserting(_ panel: PanelID, at target: DockTarget, settings: JSONValue?) -> DockLayout   // 跨窗口移动的两端
    public func removing(_ panel: PanelID) -> DockLayout
    public func docking(_ panel: PanelID) -> DockLayout   // 浮动面板回到原来的区
    public func togglingStyle(_ edge: DockEdge) -> DockLayout
    public func selecting(_ panel: PanelID) -> DockLayout
    public func resizing(_ edge: DockEdge, to size: Double) -> DockLayout
    public func reweighting(_ edge: DockEdge, _ weights: [PanelID: Double]) -> DockLayout
    public func settingCollapsed(_ edge: DockEdge, _ isCollapsed: Bool) -> DockLayout
    public func togglingArea(_ edge: DockEdge) -> DockLayout
    public func togglingAllAreas() -> DockLayout
    public func togglingPanel(_ panel: PanelID, defaultEdge: DockEdge) -> DockLayout
    public func movingFloating(_ panel: PanelID, to frame: DockFrame) -> DockLayout
    public func settingSettings(_ value: JSONValue, for panel: PanelID) -> DockLayout
    public func adoptingFloating(of other: DockLayout) -> DockLayout   // 浮动面板全应用一份：采用对方的浮动列表，并移走自己停靠着的同一面板
    public func sanitized(knownPanels: Set<PanelID>) -> DockLayout   // 整理从文件读入的布局
}
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

G0 已于 2026-11-01 完成：
- 用系统挂载，协议用 NFS，不内置 SMB（§3.2）。
- 网络卷上的阻塞调用放进辅助进程（§3.2）。
- §4 已并入 S0-T4 的差异，§3.8 已写入 S0-F1 的结论。
- S1 的任务文档见 `docs/plans/tasks/S1-*.md`。

在每个关口，向用户汇报结论与证据；需要用户决定的事项先询问。必要时更新本文，再编写下一阶段的任务文档。
