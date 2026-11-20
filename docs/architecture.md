# MacView 架构

状态：2026-10-31 定稿；2026-11-01 并入关口 G0 的决定。2026-11-17 同步 S3-T1 阶段 1 资料库接口；2026-11-19 同步 S3-T3/S3-T4 阶段 1 搜索索引、评分标签与变更链接口；Core 集成验收与 App 阶段分别记录。

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
- 性能计时一律用 signpost 记录，由 xctrace 读取；调试接口只读状态，不为计时在正式数据流里加字段或状态机。
- 不为假设的需求预留结构。P1 已确定的扩展点（数据源、命令、面板、效果）只体现在接口形状上，不提前实现。

## 2. 模块

| 模块 | 职责 | 依赖 |
|---|---|---|
| MVFoundation | Location、ContentIdentity、Entry、PixelSize、JSONValue、错误类型、日志与 signpost、名称比较器 | — |
| MVIO | IOScheduler、卷通道与健康状态、FileSystemProvider 读写原语、SourceRegistry、ByteSource，以及 URL 与 Location 的互转 | MVFoundation |
| MVMetadata | XMP 评分与标签读写（JPEG/TIFF/HEIC）、EXIF/XMP 详情解析、格式可写性判定 | MVFoundation |
| MVFileOps | 文件操作、评分与标签写入、反向操作、跨卷复制校验和传输记录；已接入组合根 | MVFoundation、MVIO、MVMetadata、MVMedia |
| MVArchive | zip/cbz、tar、tar.gz/gz，嵌套，ArchiveProvider，临时解出目录 | MVIO |
| MVMedia | 探测（含 XMP 评分与标签）、显示尺寸解码与重采样、原图与分块、动图帧、视频封面与元数据、渲染件编码 | MVFoundation、MVMetadata |
| MVCache | 泛型内存缓存 L0/L1、字节磁盘缓存 L2/L3（含改挂）、按容器查询的图像元数据与标签索引、目录缓存与搜索查询（SearchCatalog） | MVFoundation、GRDB.swift |
| MVPipeline | ImagePipeline：串联各缓存层，一次读取产出多种渲染件，渐进交付，按会话管理预取计划 | MVIO、MVMedia、MVCache |
| MVSettings | 设置模式、效果链与背景模型、显示配置、分层解析、路径规则、JSON 存储、书记忆 | MVFoundation、GRDB.swift |
| MVCommands | 命令登记、按键序列与作用域解析，以及默认命令、绑定与菜单模型 | MVFoundation |
| MVReading | Book/Page、BookLoader、Bookshelf、PageFrameEngine、ReaderSession | MVIO、MVMedia、MVCache、MVPipeline、MVSettings |
| MVLibraryData | 历史、书签、播放列表存储与变更；可用性检查；虚拟书加载 | MVFoundation、MVIO、MVCache、MVReading、GRDB.swift |
| MVSearch | 目录树递归建立搜索索引与增量元数据探测（FolderIndexer） | MVFoundation、MVIO、MVMedia、MVCache |
| MVServices | 组合根：创建并连接各服务，按位置分派加载器，记录历史与迁移资料库，负责启动、退出和内存压力处理 | 以上全部 |
| MVTestSupport | Mock、内存资料库与夹具清单（`Fixtures/manifest.json`）的读取。App 的 Debug 构建可以用启动参数 `-MVMockServices YES` 切换到 Mock | 契约 |
| mvbench | 基准测试与夹具生成的命令行工具；`library seed-playlist` 准备列表夹具，`fileops` 覆盖文件操作网络验收，`search seed/query` 覆盖搜索索引基准 | 现有 Core 模块及 MVFileOps、MVLibraryData |
| MVLayout | App 侧的纯计算：画布的四种布局与锚点、停靠布局及其变换。App 没有测试目标，放进包里才能用 `make test` 测 | MVFoundation、MVSettings |
| App（`MacView` target） | 窗口与标签页、停靠面板、集合视图、查看器、输入、菜单、设置界面、本地化 | MVServices 等 |

- 任务 ID 中，T 表示 Core 任务，F 表示 App 任务。
- P1 的新模块到对应阶段再建：MVScripting、MVPlugins（效果链模型放在 MVSettings，S4-T1 决定）。
- 依赖选型：SQLite 统一用 GRDB.swift（MIT 许可），由第一个用到它的任务引入，MVCache 与 MVSettings 共用。其余依赖由各任务按需选用。
- 已引入的依赖（版本以 `Packages/MacViewKit/Package.resolved` 为准）：

  | 依赖 | 用途 | 许可证 | 引入任务 |
  |---|---|---|---|
  | swift-argument-parser 1.8.2 | mvbench 的子命令与参数解析 | Apache-2.0 | S0-T1 |
  | GRDB.swift 7.11.1 | MVCache 的 `index.sqlite`、MVSettings 的 `state.sqlite` 与 MVLibraryData 的 `library.sqlite`，各自使用 WAL 数据库 | MIT | S1-T4、S1-T7、S3-T1 |
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
  - 每次调用都有期限，默认 9 秒，不短于 5 秒。硬挂载在故障期间一直阻塞、不报错，所以期限是唯一的超时来源。
  - 超时后向调用方抛出 `.timeout`。底层被卡住的调用仍占着槽位，计为 stuck。
  - stuck 或超时次数超过阈值时，卷标为 degraded：新请求立即失败，只保留定期的健康探测，探测成功即恢复。
  - 卷状态以流的形式提供给界面显示；具体调度器和注册表另提供当前快照，调试接口据此读取当下的在途计数，不依赖流的发布时机。
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
  - 辅助进程按路径缓存最多 32 个只读描述符，免得网络卷上每读一块都重新打开。读写同一个辅助进程；执行改名（源路径及覆盖目标路径）、删除、移入废纸篓前，先释放该路径及其下所有路径的缓存描述符，操作期间不让并发读取重新缓存。否则 NFS 会把仍打开的文件改名为 `.nfs.*` 保留，目录删不掉（S3 阶段 2b / S3-T3）。
- 文件写入与移动（S3-T2）：创建、写入、完成、改名、建目录、删除和本机废纸篓经调度器及现有期限；网络卷由辅助进程执行。排他改名在 NFS 返回 ENOTSUP/EINVAL 时回退普通改名，存在检查与改名之间的竞态。
- 跨卷移动先原子写入本机传输记录，记录源、目标、临时位置和冲突策略；临时名为 `.<原名>.<完整传输 ID（32 位十六进制）>.macview-part`，排他创建遇到重名时先删除记录再报错，删除记录失败也报错。复制逐文件读回 SHA-256，排他发布后删除源；复制操作也使用带 ID 的临时名，但不写移动记录。创建后的失败和取消会清理临时项，清理失败时保留移动记录供恢复。
- 组合根启动时恢复中断的移动：临时项存在时删除后重做；没有临时项且目标、源均存在时，逐项比较类型、大小和 SHA-256，匹配才删除源；不匹配或无法读取则保留源，按记录中的冲突策略重做。临时项和源均不存在、目标存在时，删除记录并计入 completed；三者均不存在时，删除记录并计入 failed。该功能尚未发布，不保留旧式临时项迁移逻辑。
- 文件操作用不跟随链接的类型查询；未知扩展名的普通文件可操作，链接同卷改名、移动和删除操作链接本身，复制和跨卷移动拒绝链接。校验读回每次重新打开描述符并设置 F_NOCACHE，读完关闭；创建、写入和完成文件时检查 F_NOCACHE 的设置结果，失败则关闭描述符并返回错误。临时文件创建成功后设置失败时，文件操作层尝试删除空文件，删除失败保留移动记录。只保留文件修改时间，不保留目录自身修改时间。
- 传输记录没有发布阶段，完整 ID 撞名视为不会发生。若排他创建报 EEXIST 后、删除记录前崩溃，或删除记录失败，恢复可能把同名项当作临时项删除；第 4 轮设计答复接受这一残余风险。正式目标不判断归属，源仍存在时只在内容一致后删除源。
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
  - 浏览图：等比缩放到能放进最大显示器的像素尺寸，且不超过基础图尺寸，不放大。基础图解码分别满足浏览图目标的 80% 和显示目标的 90%，取较细的级别；没有显示目标时只按浏览图要求。
  - 元数据。
- 动图通过帧源按需逐帧解码，播放节奏由前端的显示链接驱动。
- 视频：
  - 封面用 AVAssetImageGenerator 生成，取 1 秒处和 10% 处中较早的一帧。
  - 本机卷上 AVFoundation 自己读文件；网络卷上经 AVAssetResourceLoader 走 I/O 调度的大块读取通道（§3.2 进程隔离），并发上限和卷健康统计因此保持一致。

### 3.4 缓存与图像管线

| 层 | 介质 | 内容 | 默认预算 |
|---|---|---|---|
| L0 | 内存 | 近期读取的原始文件字节；换尺寸重新解码时不必再读 NAS | 512 MB |
| 解码缓存 | 内存 | `visible` 请求产出或用到的基础图和显示图 | min(1 GB, 5% 内存) |
| 缩略图内存缓存 | 内存 | 任何优先级的缩略图和视频封面 | 512 MB |
| 浏览图预载 | 内存 | `near` 请求产出的基础图和显示图 | 512 MB |
| L2 | SSD | 缩略图 | 10 GB |
| L3 | SSD（可关） | 浏览图 | 50 GB |
| 索引 | SQLite | 元数据（尺寸、帧数、时长、拍摄时间）、目录列表、L2/L3 的位置与访问时间 | — |

- L2/L3：
  - 按 LRU 淘汰。
  - 写入时先写临时文件再改名，最后更新索引。
  - 启动时不扫描缓存目录。
- 元数据索引用定长列，按容器查询，不做泛型存储：泛型 Codable 逐条解码 JSON，1 万项约 28 ms，超出 20 ms 的预算。
- 内存预算：`CacheBudgets.rawBytes`、`decodedBytes`、`thumbnailMemoryBytes`、`preloadBytes` 分别控制以上四块内存。`visible` 命中预载时搬到解码缓存；低于 `near` 的基础图和显示图不进缓存。App 的缩略图 `NSCache` 按图像字节计成本，与管线主要共享图像对象；额度在创建时从 `SettingsStore` 读 `thumbnailMemoryBytes` 设上，收到 `.global` 变更时重设（`followThumbnailMemoryBudget`），不另设下限或默认值。`settings.json` 里非正的容量预算在解析时拒绝（`CacheBudgets.init(from:)`），整份文件按配置错误显示并保留上次的值。
- 内存压力：收到系统的内存压力事件时，把四块内存同时收缩到各自预算的 50% 或 25%。
- 基础图从解码前到衍生件写完计入内部 512 MB 在途额度。低于 `near` 的请求等额度，允许最后一张跨过额度；等待可取消，前台加入时立即提升并准入。`visible`、`near` 不等额度，满额时先交付且不排衍生件，后续前台访问或同键预取补写。
- 目录缓存：
  - 先返回上次的结果，同时在后台校验，NAS 目录因此能秒开。
  - 首次枚举时按到达顺序渐进显示，枚举完成后一次性排序，并保持可见锚点不动。
- 取图：
  - `image(for:target:)` 依次交付三个阶段：缩略图放大的占位 → 浏览图 → 精确尺寸。
  - 主区瀑布流按列宽调用它，由管线在缩略图、浏览图和原图之间选择来源；画廊面板用 `thumbnail`。
  - 未命中磁盘缩略图时，前台 `thumbnail` 取得并缩放基础图后返回；衍生件由管线生命周期管理，在后台完成写入。冷缩略图和浏览图预取以当前基础图实际登记的衍生写入任务判断完成，等该任务写完才算预取完成。超额跳过时，以不高于 `book` 的新请求上下文重新等额度；若再次被前台提升而跳过，继续重试，取消或关闭时退出。
- 预取计划以会话为单位整体替换：移除的取消，保留的重排，新增的入队。
- 前台请求加入预取已启动的工作时，整条链路提升到前台优先级：通过续体等待的地方（`SharedWork`、`ContentWork`）由管线调 `escalatePriority(to:)`，只升不降；`Task.value` 和任务组由运行时传递。已入队的任务提升后仍留在原 QoS 的队列里，所以解码、缩放和编码都走 `ImageDecoder` 的限流器：等待项按当前任务优先级出队，提升后立即前移。任务优先级不能统一成一档，否则可见页的解码要排在预取后面。
- 共享作业的成员在登记表锁内同步加入；只有最后一个成员（含已加入但还没开始等待的）因取消离开、且作业还没有结果时，才放弃作业并取消读取。
- 默认预取范围（都可配置；S2-T1 已按此实现，默认值不变）：
  - 查看器：前后各 2 个页帧预解码到 `PageFrameFit` 给出的显示尺寸，长边不超过 `maxDecodeLongSide`；阅读方向上再往前 5 页预读原始字节。
  - 画廊：可见区域再加一屏的余量。
  - 当前书：全部页面的缩略图和元数据。
  - 相邻：书架排序中当前书之后的 `neighborBooks` 本（默认 2）的全部页面（缩略图和元数据），以及当前目录各书的封面。

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
    - `path-rules.json`、`profiles.json`、`keybindings.json`。
    - `layout.json`：停靠布局和各面板的视图设置。
  - SQLite：`state.sqlite` 只存书记忆；`library.sqlite` 统一存历史、书签和播放列表，WAL、`synchronous = FULL`。
  - P1 再增加 `menus.json`。
- `~/Library/Caches/MacView/`：`thumbnails/`、`browse/`、`extract/`（压缩包临时解出）、`index.sqlite`。
- JSON 文件：
  - 带版本号，原子写入，外部编辑后自动重载。
  - 解析失败时保留上一份可用的配置，并在界面显示错误和“打开文件”入口。
- 分层解析：
  - 顺序：全局 ⊕ 匹配的路径规则（越具体越靠后）⊕ 书记忆，逐字段合并。
  - 各层的字段都是可选的，只有全局层必须完整。
- 书记忆保存：页位置（页身份加序号）、单双页、方向、排序、递归、缩放、浏览方式、效果链与背景。
- `state.sqlite` 打开时，`PRAGMA journal_mode = WAL` 只对 SQLITE_BUSY 显式重试，间隔 20 ms，最长 5 秒。这条切换不走 `busyMode`，退出后立刻重开或两个实例并存时会遇到。

资料库的 `history`、`bookmark`、`playlist`、`playlist_item` 四张表分别存打开时间、树层级与序号、列表摘要、列表顺序及 `Entry` 快照。位置按 `sortedKeys` 编码，并保存带索引的 `prefix_key`。开库沿用 `state.sqlite` 的 SQLITE_BUSY 重试。历史默认保留 1000 本，`historyLimit` 缺失时补默认且不报缺字段，非正值拒绝；缩小立即裁剪。

书记忆与历史独立：清历史不丢页码与阅读设置。文件移动时按前缀迁移资料库及书记忆（含虚拟书的 `lastPage`）；撞到已有目标时保留目标，历史取较晚时间。资料库迁移为单事务，删除文件不删除条目。组合根按“目录缓存 → 冲刷相关会话 → 书记忆与资料库迁移 → 会话 → 广播”处理，广播接收时已能读到新位置。

虚拟书位置使用 `playlist` 插件根，以列表顺序加载，不受书内排序或递归影响；不切相邻书，不请求书架与相邻书预取。`items(id)` 与 `playlistRemoved(id)` 才重载对应会话，`relocated` 只供面板刷新，快照回写无通知。可用性按容器合并检查，未挂载网络根只读挂载表；不可用项保留序号并交付 1:1.414 占位元数据，其他容器独立完成。

公开类型及完整方法签名见 [LibraryTypes.swift](../Packages/MacViewKit/Sources/MVLibraryData/LibraryTypes.swift)；检查器与加载器接口分别见 [AvailabilityChecker.swift](../Packages/MacViewKit/Sources/MVLibraryData/AvailabilityChecker.swift)、[PlaylistBookLoader.swift](../Packages/MacViewKit/Sources/MVLibraryData/PlaylistBookLoader.swift)。§4 只保留行为契约，避免与源码重复维护声明。

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
  - 恢复：`SessionStore` 写 `session.json`（带版本号，原子写入，去抖 500 ms），按窗口存 frame、选中的标签和各标签的书、停靠布局、瀑布流尺寸。页码来自书记忆，关窗和退出前 `flush`。窗口的 `isRestorable` 不用系统恢复。
    - 启动时恢复；同时有要打开的 URL 时，恢复后另开标签。Mock 和其他自检不读不写。
    - 恢复打开由 App 跳过该次历史写入，避免清空或移除的历史在启动后复现；书记忆照常恢复，用户主动打开仍记录历史。Core 的打开回调及资料库接口不变。历史重启自检用 `-MVSessionSelfTest history-write|history-verify` 和同一隔离目录分次启动。
    - 书不在时窗口仍恢复，`session.book` 保留位置，显示错误和重试或连接；书记忆不被覆盖。
    - 文件解析失败时开一个空窗口并显示错误条，不覆盖坏文件，直到用户修好或关掉错误条。
    - 同一本书开在两个标签时，两者共用一份书记忆，恢复到最后保存的页。全屏不进会话，恢复成全屏前的 frame。
- 状态与错误：
  - `VolumeStatusView` 显示当前书所在卷的 degraded 和 unavailable，状态栏同时显示一行；书整本打不开时由查看器的提示显示，不重复。探测成功后自动重试失败项。
  - 配置错误按文件各一条（`settings.json`、`path-rules.json`、`keybindings.json`、`session.json`、`state.sqlite`），修好后消失。`layout.json` 的错误由停靠框架显示。
- `NSApp.terminate` 不能在主队列的块或主 actor 任务里直接调用：`terminateLater` 的嵌套循环排不空主队列，退出流程的主线程任务永远跑不了。用 `perform(_:with:afterDelay:)`。
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
    - 只有在 `DockSplitView.mouseDown` 跟踪分隔线期间，尺寸变化才算用户拖动。不能看 `NSApp.currentEvent`：点工具栏后分栏自己调整时，当前事件也是本窗口的鼠标事件，曾把宽度 0 写进布局（S1 手动验收）。读取尺寸时不低于最小值，已保存的 0 能自愈。
    - 浮动面板用 `hidesOnDeactivate`（App 失去焦点时隐藏）和 `fullScreenAuxiliary`（可以浮在全屏窗口之上）。
    - 书架和页面列表是 `CollectionPanel` 的两个子类。面板的样式、尺寸和排序存在 `layout.json` 的面板设置里；区头的 ⋯ 菜单由面板和停靠区共同填充。
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
  - 重排最多两轮（W3.9）：非覆盖式滚动条在临界尺寸上会让视口在宽窄之间来回变（排完出现滚动条，按窄视口排完又隐藏）。第二轮后视口仍在变时，临时关掉 `autohidesScrollers`，按含滚动条的窄视口排，下次重排前恢复。临界尺寸的往复和两轮上限由 `CollectionLayoutTests` 在命令行验证。
  - 项本身失败（如书架封面取不到）时 `CanvasItem.isFailed` 为真，显示与缩略图失败相同的错误标记，不请求缩略图；书架重新列出或点击该项时重试。
- 集合组件：列表和详情表格用 NSTableView，网格和瀑布流用画布引擎。
- 查看器：
  - 分页渲染器负责页帧图层、缩放模式计算、设备像素 1:1、放大镜、翻页时保持缩放与位置，以及以光标为中心缩放。
  - 缩放手势结束后，按新的设备像素尺寸重新请求图像；超过上限时请求原图或分块。
  - 视频用 AVPlayerLayer，每个窗口只有一个活动的播放器。
  - 图层用点，`ViewerTransform` 和 `PageFrameFit` 用设备像素；`decodeSize` 是向管线请求的尺寸（半页时是整页），`pixelSize` 是在视口中占的尺寸。
  - 连续和瀑布模式包 `CanvasView`，分页和连续之间切换时保持当前页。瀑布流尺寸按窗口保存在 `session.json`。
  - `CanvasView` 在 Debug 构建只在合成滚动进行期间（`SyntheticScroll.during`，调试接口的 `scroll` 命令和查看器自检）关掉响应式滚动，否则收不到合成事件；结束后恢复系统默认。开着调试接口时用户的真实滚动（`record-trackpad.sh` 录制）保持响应式滚动，`state` 的 `responsiveScrolling` 为真。
- 调试接口（`App/Debug/DebugSocket.swift`，只在 Debug 构建编译，只在传 `-MVDebugSocket <路径>` 时开启，权限 0600）：
  - Unix 域套接字，一行一个 JSON。请求 `{"id":1,"command":"state","args":{}}`，响应 `{"id":1,"ok":true,"result":{…}}` 或 `{"id":1,"ok":false,"error":"…"}`。一次一个连接，命令按顺序在主线程执行。验收以 `open -n -g` 启动独立实例（`record-trackpad.sh` 给用户录制，仍用 `open -n -a`），套接字使用不超过 103 字节的绝对路径；support、cache 和 layout 均指向隔离目录，按本次实例的 PID 管理，退出结果以进程实际退出为准。测试实例（含 Mock）缺 `-MVSupportDirectory`、`-MVCacheDirectory`、`-MVLayoutFile` 任一项时，`AppDelegate` 的 `#if DEBUG` 分支打印 `FAIL` 后以 64 退出，不碰用户目录。
  - 不干扰用户：调试接口和自检不调用 `NSApp.activate()`。测试实例（传了调试接口或任一自检参数）的第一个窗口放在 `maximumFramesPerSecond` 最大的屏（本机是内置屏）可见区域中央，窗口出现时只用 `orderFrontRegardless` 抬到最上面，见 `App/Debug/TestPresentation.swift`，挂在 `AppDelegate` 的 `#if DEBUG` 分支里，Release 不变。

    | 命令 | 参数 | 结果 |
    |---|---|---|
    | `perform` | `command`（CommandID）、`arguments?` | 经 `CommandRegistry` 在前台窗口执行；`panel.settings` 用 `panel`（`bookshelf` 或 `pageList`）、`style?`、`itemExtent?` 修改面板设置 |
    | `open` | `path`、`page?`（从 0 开始） | 打开完成后返回窗口状态；打不开时 `ok: false` |
    | `resize` | `width`、`height`（点，内容区） | 调整前台窗口，返回窗口状态 |
    | `scroll` | `dx`、`dy`（点，负的 `dy` 向下）、`steps`、`intervalMs`；连续滚动另用 `durationMs` | 按 began、changed、ended 生成滚轮事件，经 `NSApp.sendEvent` 发到查看器中央；`durationMs > 0` 时持续滚动，到边界后反向。返回 `events`、`windowFront`、`responsiveScrolling`（滚动期间的值，应为假），连续滚动还返回 `scrollMovements` |
    | `state` | — | `windows[]`、`volumes[]`、`fileErrors[]`、`residentBytes`、`memory`、`cacheBudgets`、`library` |
    | `quit` | — | 正常退出流程 |

  - `windows[]`：`book`、`page`、`frame`、`frameCount`、`browseMode`、`scaleMode`、`zoom`、`viewport`（点）、`visibleRange`（`[起, 止)`，分页模式是当前页帧）、`loadError`（整本书或当前分页的加载错误）、`lastDisplay`（`{page, quality, milliseconds}`，从翻页调用到目标质量图设到图层的用时，只有分页模式）。
  - `windowFront`：窗口可见、`occlusionState` 含 `.visible`、所在屏是内置屏（`CGDisplayIsBuiltin`），不要求 App 处于激活状态。另有三个只读字段：`windowScreen`（`displayID`、`name`、`builtin`、`frame`、`visibleFrame`、`maximumFramesPerSecond`）、`windowFrame`（`[x, y, 宽, 高]`，全局坐标，点）和 `appActive`。
  - 验收用只读字段：`prefetchIdle`、`prefetchInFlightCount`、`windowFront`、`windowScreen`、`windowFrame`、`appActive`、`responsiveScrolling`、`docksVisible`、`hudVisible`、`firstScreenThumbnailMilliseconds`、`itemCount`、`effects`（`colorAdjust` 六个值或 `null`）、`effectsEnabled`、`background`、`effectFilterCount`（主视图效果挂点上实际挂着的滤镜数）；`volumes[]` 另有 `inFlight` 和 `bulkInFlight`（bulk 通道在途读取数，nas-fault 据此确认在途后注入）；`pageSlots` 返回各页的 `page`、`hasImage` 和 `quality`，可确认初始页图层已就绪。`panels` 返回书架和页面列表的 `style`、`itemExtent`、`sort`，`tiles` 返回当前分块的 `requested`、`cancelled`、`inFlight` 计数。
  - `memory` 返回 `rawBytes`、`decodedBytes`、`thumbnailMemoryBytes`、`preloadBytes`、`inFlightBytes` 和 `waitingTasks`；`cacheBudgets` 返回对应四项内存预算以及 `thumbnailDiskBytes`、`browseDiskBytes` 两项磁盘预算。
  - `library` 返回 `historyCount`、按时间从新到旧的 `history`（`book`、`openedAt`）、完整 `bookmarks` 树（文件夹为 `folder`、`children`，书为 `book`、`label`）、`playlists`（`id`、`name`、`count`、`recent`）。服务没有资料库时为 `null`；读取失败时为含 `error` 的对象。
  - 合成滚动和屏幕状态有关：屏幕锁定时事件不生效。
  - 首屏计时的状态机和可见缩略图回报（`ReaderWindowController` 的 `beginFirstScreenThumbnails` 等、`CollectionView.onVisibleThumbnails`、`CanvasView.onImageApplied`）只在 Debug 编译，Release 二进制里没有这些符号。
- 自检：`-MVSelfTest`（外壳）、`-MVDockSelfTest <阶段>`、`-MVViewerSelfTest`、`-MVPanelSelfTest`、`-MVSettingsSelfTest`、`-MVSessionSelfTest <阶段>`、`-MVFileOpsSelfTest YES|net-kill|net-verify`（后两个是网络卷验收，见 S3-F2 报告）、`-MVLibrarySelfTest YES`（真实服务，历史、书签、播放列表与虚拟书；必须加 `-MVSelfTestActivate YES`，点击、拖放、按键走真实事件，右键菜单取视图的菜单后执行其动作，弹出按钮选择后发送其动作；详见 [S3-F1 报告](reports/S3-F1.md)）、`-MVEffectsSelfTest render`（效果滤镜挂点、背景、开关与复制/拖出调色 PNG）。截图输出到 `-MVSelfTestOutput`，`-MVAppearance dark|light` 选外观，`-AppleLanguages '(en)'` 选语言。依赖事件和前台窗口的项要在屏幕解锁时运行。自检默认不激活 App，离不开键盘焦点的项走未激活的回退或记 `SKIP`；加 `-MVSelfTestActivate YES` 才激活，留给用户键鼠空闲时跑；这时要经 LaunchServices（`open -n`）启动才拿得到前台，进不了前台的自检直接失败，汇总前打印前台采样比例。自检的临时文件放在 `-MVSupportDirectory` 下的 `selftest-tmp/`，不写持久偏好。结果行是 `SELFTEST OK|FAILED n commit=… cdhash=…`。
- 观测：用 os_signpost 标记帧时间和请求延迟，用 Instruments 的 Animation Hitches 验收。
- 构建身份：构建阶段“记录源码提交”把 `git rev-parse HEAD`（工作树有改动时加 `-dirty`）写进 Info.plist 的 `MVSourceCommit`。验收证据和录制都记 App 的 commit 与 CDHash，`run.py --g2` 只认与被验收 App 一致的证据，见 [S2-T2 报告](reports/S2-T2.md)。

### 3.9 P1 扩展点（P0 只体现在接口形状上）

- 数据源插件以 ContainerProvider 的形式注册到 SourceRegistry，按根分派。
- 脚本命令和插件命令注册进 CommandRegistry。
- HTML/JS 面板是一种面板类型。
- 显示配置（S4-T1 已实现）：`DisplayProfile` 存进 `profiles.json`，按所选组保存 `BookSettings` 子集，套用时按模板语义经 `BookSettings.merge(_:)` / `ResolvedBookSettings.applying(_:)` 写入对应设置层，不新增层级。
- 效果链（S4-T1 已实现 Core 模型）：`ColorAdjust`、`Effect`、`EffectChain`、`ViewerBackground` 放在 `MVSettings`，随 `BookSettings` 分层解析并写入书记忆；`ReaderSession` 对只改效果或背景走不重排、不预取快路径；前端在呈现时用 Core Image 滤镜在 GPU 上应用。

## 4. Core 协议契约

契约已由 S0-T4 落成代码，实现时的调整已在 G0 并入本节。字段与默认值、行为约定等细节以代码和文档注释为准，说明见 [S0-T4 报告](reports/S0-T4.md)。修改公开接口时同步更新本节。

```swift
// MVFoundation
public struct Location: Hashable, Sendable, Codable {
    public enum Root: Hashable, Sendable, Codable { case local; case network(scheme: String, host: String, share: String); case plugin(id: String) }
    public var root: Root
    public var layers: [[String]]
    public static let playlistRootID: String
    public static func playlist(_ id: UUID) -> Location
    public var playlistID: UUID? { get }
    public var prefixKey: String { get }   // 相等或以 prefix + 分隔符开头，与 hasPrefix 等价
}
public struct ContentIdentity: Hashable, Sendable, Codable { public var location: Location; public var size: Int64; public var modificationNanos: Int64; public var checksum: UInt32?; public var cacheKey: String { get } }
public struct PixelSize: Hashable, Sendable, Codable { public var width: Int; public var height: Int }
public struct ImageMetadata: Sendable, Codable, Hashable { public var pixelSize: PixelSize; public var frameCount: Int; public var duration: Double?; public var capturedAt: Date?; public var colorSpace: String?; public var rating: Int?; public var tags: [String]? }   // pixelSize 已按 EXIF 方向换算；rating 0–5（nil 表示无）；tags nil 表示未读到，[] 表示为空
public enum ArchiveFormat: String, Sendable, Codable { case zip, tar, tarGzip, gzip }
public enum EntryKind: Hashable, Sendable, Codable { case directory, archive(ArchiveFormat), image, video, other; public init(fileName: String) }   // init 按扩展名判断，不读内容
public struct Entry: Hashable, Sendable, Codable { public var identity: ContentIdentity; public var name: String; public var kind: EntryKind; public var created: Date? }   // location、size、modified 由 identity 计算
public struct SessionID: Hashable, Sendable { public let raw: UUID }
public enum JSONValue: Hashable, Sendable, Codable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public enum Availability: Sendable, Hashable { case available, missing, volumeUnavailable(Location.Root) }   // MVLibraryData 重新导出
public enum FileChange: Sendable, Hashable { case added(Entry), removed(Location), moved(from: Location, to: Entry), rewritten(Entry, previous: ContentIdentity, metadata: ImageMetadata) }   // rewritten：仅改写元数据，metadata 由写入时内存字节探测得到
public enum ConflictPolicy: String, Sendable, Codable { case appendNumber, skip }
public enum TransferMode: String, Sendable, Codable { case move, copy }
public enum ResampleFilter: String, Sendable, Codable { case lanczos, nearest }   // MVSettings 也要用，所以放在这里
public enum NameOrder { public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult }   // 数字感知与中文拼音排序

// MVIO
public enum IOPriority: Int, Sendable, Comparable { case visible, near, book, adjacent, background }   // 按声明顺序，visible 最高
public struct IORequestGroup: Hashable, Sendable { public let id: UUID }
public protocol ByteSource: Sendable {
    var identity: ContentIdentity { get }
    func read(_ range: Range<Int64>, priority: IOPriority, group: IORequestGroup?) async throws -> Data
}
public struct FileLease: Sendable { public let url: URL; public init(url: URL, holder: (any Sendable)? = nil) }
public protocol ContainerProvider: Sendable {
    func canHandle(_ location: Location) -> Bool
    func children(of container: Location, priority: IOPriority) -> AsyncThrowingStream<[Entry], any Error>   // 分批返回
    func entry(at location: Location) async throws -> Entry
    func open(_ location: Location) async throws -> any ByteSource
    func fileLease(for location: Location) async throws -> FileLease   // 压缩包内的条目解出到 extract/，持有者释放后才可以淘汰
}
public enum VolumeState: Sendable, Equatable { case healthy, degraded(String), unavailable }
public struct VolumeHealth: Sendable { public var root: Location.Root; public var state: VolumeState; public var inFlight: Int; public var bulkInFlight: Int; public var stuck: Int }   // inFlight 是两个通道执行中的调用数，bulkInFlight 是其中大块读取通道的
public enum IOError: Error, Sendable { case timeout, cancelled, volumeUnavailable(Location.Root), volumeDegraded(Location.Root), notFound(Location), alreadyExists(Location), crossVolume, unsupported(Location), unsupportedFormat(Location, String), corrupted(Location, String), underlying(String) }   // volumeDegraded：卷连续超时，暂停访问；unsupportedFormat：位置和实际格式名（RAR、7z）
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
    public func currentVolumeHealth() -> [VolumeHealth]               // 当下快照，不订阅或发布流
    public func volumeHealth() -> AsyncStream<[VolumeHealth]>   // 锁内只改订阅表并复制要发的值，锁外再 yield/finish；持锁发布会和订阅方取消时的任务锁反转（S3-F1 关窗口卡死）
    public func shutdown()                                            // 杀掉辅助进程，不等卡住的调用
}
public enum FileSystemItemType: Sendable, Equatable { case regular, directory, symbolicLink, other }
public final class FileSystemProvider: ContainerProvider {
    public init(scheduler: IOScheduler)
    public func itemWithoutFollowingLinks(at location: Location) async throws -> (entry: Entry, type: FileSystemItemType) // lstat，返回链接自身
    public func readUncached(_ location: Location, range: Range<Int64>, priority: IOPriority) async throws -> Data // 每次新开、F_NOCACHE、读后关闭
    public func createFile(at location: Location) async throws
    public func write(_ data: Data, at offset: Int64, to location: Location, priority: IOPriority) async throws
    public func finishFile(at location: Location, modificationNanos: Int64?) async throws
    public func rename(_ source: Location, to target: Location, exclusive: Bool) async throws
    public func makeDirectory(at location: Location) async throws
    public func remove(_ location: Location) async throws
    public func moveToTrash(_ location: Location) async throws -> Location
    public func isNetworkVolume(_ location: Location) throws -> Bool
    public func volumeRoot(of location: Location) throws -> Location
    public func mountedNetworkRoots() -> [Location]
}   // 只接受一层 Location；写入经调度器；网络卷不支持系统废纸篓
public final class FileSourceRegistry: SourceRegistry { public init(scheduler: IOScheduler); public let scheduler: IOScheduler; public let fileSystem: FileSystemProvider; public func register(_ provider: any ContainerProvider); public func currentVolumeHealth() -> [VolumeHealth] }   // provider(for:) 先问登记的 provider，再交给 fileSystem；压缩包 provider 由组合根登记；健康快照直接读取调度器
public enum IOHelper { public static func runIfRequested() }   // 宿主 main 开头调用：作为辅助进程启动时进入请求循环，不返回
public final class ByteSourceAsset: Sendable { public let asset: AVURLAsset; public init(source: any ByteSource, priority: IOPriority = .visible) }   // 网络卷视频经 AVAssetResourceLoader 读取；调用方持有它直到不再用 asset

// MVMetadata
public struct XMPFields: Sendable, Hashable, Codable { public var rating: Int?; public var tags: [String]? }   // nil 表示不改；写入时 rating=0 清除评分，tags=[] 清除 dc:subject
public enum MetadataWritability: Sendable, Equatable { case writable, unsupportedFormat(String), insideArchive }
public enum MetadataError: Error, Sendable, Equatable { case unsupportedFormat(String), verificationFailed, encodeFailed }
public struct ImageDetails: Sendable, Hashable {
    public var pixelSize: PixelSize?; public var format: String?; public var colorSpace: String?
    public var cameraMake, cameraModel, lens: String?; public var focalLength, aperture, exposureTime: Double?; public var iso: Int?
    public var capturedAt: Date?; public var latitude, longitude: Double?; public var fields: XMPFields?
}
public enum MetadataFormat { public static func writability(fileName: String, header: Data?) -> MetadataWritability }   // 按文件头识别 JPEG/TIFF/HEIC；无头按扩展名
public enum XMPReader {
    public static func fields(fromHeader data: Data) -> XMPFields?   // 前 64 KB；xmp:Rating 优先，回退 MicrosoftPhoto:Rating（1/25/50/75/99→1–5，0→nil）；dc:subject
    public static func details(fromHeader data: Data) -> ImageDetails?
}
public enum XMPWriter {
    public static func write(_ change: XMPFields, into original: Data) throws(MetadataError) -> Data   // 内存改写并逐字节校验扫描段（JPEG）或首帧像素（TIFF/HEIC），失败抛 verificationFailed
}

// MVFileOps
public struct Relocation: Sendable, Hashable { public var source: Location; public var target: Location }
public indirect enum FileOperation: Sendable, Hashable {
    case delete([Location]), deletePermanently([Location]), rename(Location, to: String)
    case transfer([Location], into: Location, mode: TransferMode, conflict: ConflictPolicy)
    case relocate([Relocation]), makeDirectory(in: Location, name: String), removeEmptyDirectory(Location)
    case setMetadata([Location], XMPFields), sequence([FileOperation])
}   // setMetadata：原子写同目录临时文件、无缓存读回 SHA-256 校验、覆盖 rename（释放目标描述符）；inverse 为各文件原值组成的 .sequence
public enum FileOpsError: Error, Sendable, Equatable { case readOnly, invalidName(String), recycleUnavailable(String), verificationFailed, intoItself, metadataUnsupported(String) }
public struct FileFailure: Sendable { public var location: Location; public var error: any Error }
public struct FileProgress: Sendable, Hashable { public var completedItems, totalItems: Int; public var completedBytes, totalBytes: Int64 }
public struct FileOperationResult: Sendable { public var changes: [FileChange]; public var inverse: FileOperation?; public var skipped: [Location]; public var failures: [FileFailure]; public var retry: FileOperation? }   // retry 只含失败项，不含 skip；sequence 遇失败即停，重试从该步未完成的项接续后续步骤；跨卷已发布目标只核对并删源
public struct RecycleBin: Sendable, Hashable { public var location: Location; public var batchCount: Int }
public struct ResumeReport: Sendable, Hashable { public var completed, pending, failed: Int }
public final class FileOperationService: Sendable {
    public init(fileSystem: FileSystemProvider, journalURL: URL) throws
    public func perform(_ operation: FileOperation, progress: (@Sendable (FileProgress) -> Void)? = nil) async -> FileOperationResult
    public func changes() -> AsyncStream<[FileChange]>
    public func resumeInterruptedTransfers() async -> ResumeReport
    public func recycleBins() async -> [RecycleBin]
    public func setStepDelay(_ delay: Duration?)   // App 自检用的逐项／分块延迟，nil 恢复正常速度
}

// MVArchive
public final class ArchiveProvider: ContainerProvider {
    public init(fileSystem: FileSystemProvider, extractDirectory: URL, extractBudget: Int64 = 10 << 30) throws
}   // 启动清空 extractDirectory；认领压缩包与多层位置，不持有 registry。压缩包自身的 entry/open/fileURL 交给所在层，children 列出包内条目
// fileLease 的文件保留到租约释放；ByteSource 存活期间保留对应解出文件

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
    public func contains(_ key: String) async throws -> Bool          // 仅查当前 tier/key 的 disk_entries 索引行；不读文件、不检查文件存在、不更新访问时间
    public func data(for key: String) async throws -> Data?
    public func data(for keys: [String]) async throws -> [String: Data]   // 先查索引，并发读文件
    public func store(_ data: Data, for key: String) async throws       // 临时文件 → 改名 → 索引，超预算按访问时间淘汰
    public func setBudget(_ budget: Int64) async throws
    public func rekey(prefix old: String, to new: String) async throws  // 以 old 开头的 key（各尺寸后缀）改挂到 new 开头，旧的不在时跳过
}   // 文件位于 cacheDirectory/<tier>/<键前两位>/；启动只清 tmp/，不扫描其余分目录；淘汰时抽查孤儿
public final class MetadataIndex: Sendable {
    public init(index: CacheIndex)
    public func values(in container: Location) async throws -> [String: ImageMetadata]   // 一次按容器的索引范围查询，取回该容器内全部条目
    public func values(for keys: [String]) async throws -> [String: ImageMetadata]
    public func store(_ values: [String: ImageMetadata], in container: Location) async throws   // container 为条目所在的容器，即 location.parent；同事务维护 metadata_tags
    public func remove(for keys: [String]) async throws
    public func move(_ pairs: [(from: String, to: String, container: Location)]) async throws   // 文件改名、移动后元数据（含评分、标签）跟到新 key
}
public struct DirectoryListing: Codable, Sendable, Hashable { public var entries: [Entry]; public var directoryModificationNanos: Int64?; public init(entries: [Entry], directoryModificationNanos: Int64? = nil) }
public struct ListingDiff: Sendable, Hashable { public var added: [Entry]; public var removed: [Location]; public var changed: [Entry]; public init(added: [Entry], removed: [Location], changed: [Entry]) }   // changed：同一位置的 identity 变了
public final class DirectoryCache: Sendable {
    public init(index: CacheIndex)
    public func cachedChildren(of container: Location) async throws -> DirectoryListing?
    public func update(_ container: Location, listing: DirectoryListing) async throws -> ListingDiff   // 同事务维护 search_entries
    public func apply(_ changes: [FileChange]) async throws           // 只更新已有缓存；同事务维护 search_entries（含目录删除/移动按前缀处理与 .rewritten）
}
public enum SearchKind: String, Sendable, Codable { case image, video, archive, directory }
public struct SearchQuery: Sendable, Hashable {
    public var terms: [String]; public var scope: Location; public var minimumRating: Int?   // minimumRating：1–5；0 表示“未评分”
    public var tags: [String]; public var kinds: Set<SearchKind>; public var limit: Int      // 默认 5000；tags 全部命中；kinds 空表示全部
}
public struct SearchHit: Sendable, Hashable { public var entry: Entry; public var rating: Int?; public var tags: [String]? }
public struct SearchResult: Sendable { public var hits: [SearchHit]; public var truncated: Bool; public var indexedCount: Int }
public final class SearchCatalog: Sendable {
    public init(index: CacheIndex)
    public func query(_ query: SearchQuery) async throws -> SearchResult
    public func tagSuggestions(prefix: String, limit: Int) async throws -> [String]   // 按出现次数降序
    public func indexedCount(under scope: Location) async throws -> Int
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
    public static func image(_ data: Data, isComplete: Bool) throws(MediaError) -> ProbeResult   // 同时解析 XMP 评分与标签（XMPReader.fields）
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
    func videoPoster(for identity: ContentIdentity, maxPixel: Int, priority: IOPriority) async throws -> RenderedImage
    func setPrefetchPlan(_ plan: PrefetchPlan, session: SessionID)
    func cancelAll(session: SessionID)
    func carryOver(from old: ContentIdentity, to new: ContentIdentity) async   // 协议扩展有默认空实现；像素未变时改挂磁盘缓存并清理旧内存条目
}
public struct PipelineCaches: Sendable {
    public var raw: MemoryCache<String, Data>; public var decoded: MemoryCache<String, RenderedImage>
    public var thumbnailMemory: MemoryCache<String, RenderedImage>; public var preload: MemoryCache<String, RenderedImage>
    public var thumbnails: DiskCache; public var browse: DiskCache?; public var metadata: MetadataIndex
    public init(raw: MemoryCache<String, Data>, decoded: MemoryCache<String, RenderedImage>, thumbnails: DiskCache, browse: DiskCache?, metadata: MetadataIndex,
                thumbnailMemory: MemoryCache<String, RenderedImage>, preload: MemoryCache<String, RenderedImage>)
}   // 生命周期、预算与 flush 由组合根管理；四块内存预算都由调用方显式给出
public struct PipelineConfiguration: Sendable {
    public var thumbnailLongSide: Int; public var browseBounds: PixelSize; public var maxDecodeLongSide: Int
    public init(thumbnailLongSide: Int = 1024, browseBounds: PixelSize, maxDecodeLongSide: Int = 16384)
}
public final class FileImagePipeline: ImagePipeline {
    public init(sources: any SourceRegistry, decoder: ImageDecoder, caches: PipelineCaches, configuration: PipelineConfiguration)
    public func cancelBackgroundPrefetch()   // 只取消 background 预取，不影响其他优先级的消费者
    public func shutdown() async   // 停止接收新工作，新请求抛 CancellationError；取消并排空读取、解码和缓存写入，包括独立衍生件任务
}

public struct PipelineMemorySnapshot: Sendable {
    public var rawBytes: Int64; public var decodedBytes: Int64; public var thumbnailMemoryBytes: Int64; public var preloadBytes: Int64
    public var inFlightBytes: Int64; public var waitingTasks: Int
}
extension FileImagePipeline {
    public var memory: PipelineMemorySnapshot { get }   // 四块缓存实际字节、基础图在途字节和等额度任务数
    public var thumbnailMemoryBudget: Int64 { get }
    public var maxDecodeLongSide: Int { get }
    public func setMaxDecodeLongSide(_ value: Int)   // 由 MVServices 在全局设置变化时调用
}

// MVSettings
public struct CacheBudgets: Codable, Sendable, Hashable {
    public var rawBytes: Int64; public var decodedBytes: Int64; public var thumbnailMemoryBytes: Int64; public var preloadBytes: Int64
    public var thumbnailBytes: Int64; public var browseBytes: Int64; public var browseCacheEnabled: Bool
    public init(rawBytes: Int64, decodedBytes: Int64, thumbnailBytes: Int64, browseBytes: Int64, browseCacheEnabled: Bool,
                thumbnailMemoryBytes: Int64, preloadBytes: Int64)
}   // 默认值是 `CacheBudgets.default`，见 §3.4；设置文件缺字段时 FileSettingsStore 补默认值
public enum BrowseMode: String, Codable, Sendable { case paged, waterfall, verticalStrip, horizontalStrip }
public enum PageMode: String, Codable, Sendable { case single, double }
public enum ReadingDirection: String, Codable, Sendable { case leftToRight, rightToLeft }
public enum WidePagePolicy: String, Codable, Sendable { case asIs, single, split }
public enum ScaleMode: String, Codable, Sendable { case original, fitWindow, fitWidth, fitHeight, fill, fixed, devicePixel }
public enum SortKey: String, Codable, Sendable { case name, modified, created, size, type, random }
public struct SortSpec: Codable, Sendable, Hashable { public var key: SortKey; public var ascending: Bool; public var foldersFirst: Bool; public var randomSeed: UInt64? }
public struct RecursionSpec: Codable, Sendable, Hashable { public var enabled: Bool; public var maxDepth: Int }
public struct ColorAdjust: Codable, Sendable, Hashable { public var brightness: Double; public var contrast: Double; public var saturation: Double; public var gamma: Double; public var temperature: Double; public var tint: Double; public static let identity: ColorAdjust; public var isIdentity: Bool { get } }   // 除 gamma 为 0.25…4（默认 1）外均为 −1…1（默认 0），解码时夹到范围
public enum Effect: Codable, Sendable, Hashable { case colorAdjust(ColorAdjust) }   // JSON：{"type":"colorAdjust", ...字段}
public struct EffectChain: Codable, Sendable, Hashable { public var effects: [Effect]; public static let empty: EffectChain; public var isIdentity: Bool { get }; public var colorAdjust: ColorAdjust { get set } }   // 写 identity 时移除该项
public enum ViewerBackground: Codable, Sendable, Hashable { case auto, black, gray, white, checkerboard; case custom(red: Double, green: Double, blue: Double) }   // custom sRGB 0…1，解码时夹到范围
public enum DisplayProfileGroup: String, Codable, Sendable, CaseIterable { case layout, scale, effects, background }
public struct DisplayProfile: Codable, Sendable, Hashable, Identifiable { public var id: UUID; public var name: String; public var settings: BookSettings; public var groups: Set<DisplayProfileGroup> { get }; public init(id: UUID = UUID(), name: String, capturing resolved: ResolvedBookSettings, groups: Set<DisplayProfileGroup>) }   // settings 只含所选组字段，groups 由非空字段推出
public struct BookSettings: Codable, Sendable, Hashable {   // 每层只写自己覆盖的字段
    public var browseMode: BrowseMode?; public var pageMode: PageMode?; public var direction: ReadingDirection?
    public var firstPageSingle: Bool?; public var widePage: WidePagePolicy?; public var sort: SortSpec?; public var recursion: RecursionSpec?
    public var scaleMode: ScaleMode?; public var allowUpscale: Bool?; public var fixedScale: Double?; public var keepZoomOnPageTurn: Bool?
    public var resample: ResampleFilter?; public var sharpen: Float?
    public var effects: EffectChain?; public var background: ViewerBackground?
    public mutating func merge(_ other: BookSettings)   // 用 other 里非空字段覆盖自己
}   // “仅缩小不放大” = 适合类缩放模式 + allowUpscale=false
public struct ResolvedBookSettings: Codable, Sendable, Hashable { /* 与 BookSettings 字段相同，全部非可选；effects 默认 .empty，background 默认 .auto；applying(_:) 同步合并 */ }
public struct ClassifyTarget: Codable, Sendable, Hashable { public var location: Location; public var listsSubfolders: Bool }
public struct FileOperationSettings: Codable, Sendable, Hashable { public var nameConflict: ConflictPolicy; public var classifyMode: TransferMode; public var classifyTargets: [ClassifyTarget] }   // 默认 appendNumber、move、空列表
public struct GlobalSettings: Codable, Sendable { public var defaultBook: ResolvedBookSettings; public var cache: CacheBudgets; public var prefetch: PrefetchRanges; public var maxDecodeLongSide: Int; public var fileOperations: FileOperationSettings; public var historyLimit: Int }   // historyLimit 默认 1000；CacheBudgets、PrefetchRanges 的字段与默认值见 §3.4
extension PathRule { public static func matching(_ rules: [PathRule], for book: Location) -> [PathRule] }   // 越具体越靠后，相同时按原顺序；解析和设置窗口共用
public struct PathRule: Codable, Sendable { public var id: UUID; public var name: String; public var prefix: Location; public var settings: BookSettings }
public struct BookMemory: Codable, Sendable { public var book: Location; public var settings: BookSettings; public var lastPage: Location?; public var lastPageIndex: Int?; public var openedAt: Date }
public enum SettingsChange: Sendable, Equatable { case global, pathRules, profiles, fileError(file: String, message: String) }
public protocol SettingsStore: Sendable {
    func resolve(for book: Location) async -> ResolvedBookSettings
    func bookMemory(for book: Location) async -> BookMemory?
    func saveBookMemory(_ memory: BookMemory) async
    func relocateBookMemory(from source: Location, to target: Location) async
    func global() async -> GlobalSettings
    func updateGlobal(_ change: @Sendable (inout GlobalSettings) -> Void) async throws
    func pathRules() async -> [PathRule]
    func updatePathRules(_ change: @Sendable (inout [PathRule]) -> Void) async throws
    func profiles() async -> [DisplayProfile]
    func updateProfiles(_ change: @Sendable (inout [DisplayProfile]) -> Void) async throws
    func changes() -> AsyncStream<SettingsChange>
}
public enum DocumentChange: Sendable, Equatable { case reloaded, fileError(message: String) }   // 解析错误带行列号，保留上一份可用值
public final class JSONDocumentStore<Value: Codable & Sendable>: Sendable {
    public convenience init(fileURL: URL, version: Int, defaultValue: Value) throws
    public func value() -> Value
    public func update(_ change: @Sendable (inout Value) -> Void) async throws
    public func changes() -> AsyncStream<DocumentChange>
}   // 顶层 {"version": Int, "value": Value}；原子写入并监听外部修改，未来版本报 fileError；缺文件时首次 update 才写出
public final class FileSettingsStore: SettingsStore { public init(directory: URL) throws; public func flush() async throws; public func relocateBookMemory(from: Location, to: Location) async }   // settings.json、path-rules.json、profiles.json 与 state.sqlite（书记忆），shutdown 调用 flush
// relocateBookMemory 按前缀迁移书位置及全部记忆中的 lastPage；目标已有记忆时保留目标。FileSettingsStore 与 Mock 一致。
// keybindings.json 由 MVServices 用 JSONDocumentStore<KeyBindingsFile> 管理；App 可用同一存储管理 layout.json

// MVCommands
public struct CommandID: RawRepresentable, Hashable, Codable, Sendable { public var rawValue: String; public init(_ rawValue: String) }   // 例如 "page.next"，JSON 中为字符串
// 资料库：bookmarkAdd = library.bookmark.add（⌘D）、playlistAddCurrent = library.playlist.addCurrent（⌘L），viewer/list，归“书”菜单。
// playlistRemoveItem = library.playlist.removeItem，无默认键；historyToggle / bookmarksToggle / playlistToggle 为 global，⌥⌘4/5/6，归“窗口”菜单。
// file.reveal 默认 ⌥⌘R（viewer、list）；viewer 的 ⇧⌘R 仍用于递归。
// 搜索与评分标签：rating.set.0–5（⌥0–⌥5）、metadata.tags.edit（⌥T）、search.focus（⌘F）、search.indexFolder、panel.info.toggle（⌥⌘I）；zoomDevicePixel 默认绑定调整为 ⌥⇧1 以避免与 rating.set.1（⌥1）冲突。
// 显示配置与效果：displayProfile.apply（⌃1–⌃9，viewer/list，参数 slot 1–9）、effects.toggle（E，viewer）、panel.effects.toggle（⌥⌘E，global）。
public enum InputScope: String, Codable, Sendable { case global, viewer, list, textInput, classify }
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable { public let rawValue: UInt8 /* command, option, control, shift, function */ }
public struct KeyChord: Hashable, Codable, Sendable { public var key: String; public var modifiers: KeyModifiers }   // key 为逻辑键名，如 "Right"、"a"
public struct KeyBinding: Codable, Sendable, Hashable { public var sequence: [KeyChord]; public var command: CommandID; public var arguments: [String: JSONValue]?; public var scope: InputScope }
public enum ResolveResult: Sendable, Equatable { case command(CommandID, [String: JSONValue]?), pending([KeyChord]), unmatched }
public struct BindingResolver: Sendable { public init(bindings: [KeyBinding], sequenceTimeout: Duration = .seconds(1)); public mutating func feed(_ chord: KeyChord, scope: InputScope, overlay: InputScope? = nil, at time: ContinuousClock.Instant) -> ResolveResult; public static func conflicts(in bindings: [KeyBinding]) -> [BindingConflict] }   // 同作用域的相同序列或前缀冲突；textInput 不回退全局
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
    public static let fileDelete, fileRename, fileCopy, fileCopyPath, fileReveal, fileOpenWith, recycleEmpty: CommandID
    public static let classifyTarget, classifyModeToggle, classifyNewTarget, classifyPanelToggle, editUndo, editRedo: CommandID
    public static let browsePaged, browseWaterfall, browseVerticalStrip, browseHorizontalStrip: CommandID
    public static let pageModeToggle, readingDirectionToggle, firstPageSingleToggle, widePageAsIs, widePageSingle, widePageSplit: CommandID
    public static let zoomOriginal, zoomFitWindow, zoomFitWidth, zoomFitHeight, zoomFill, zoomFixed, zoomDevicePixel, zoomIn, zoomOut: CommandID
    public static let zoomAllowUpscaleToggle, magnifierToggle, keepZoomOnPageTurnToggle: CommandID
    public static let sortName, sortModified, sortCreated, sortSize, sortType, sortRandom, sortAscending, sortDescending, sortFoldersFirstToggle, recursionToggle: CommandID
    public static let windowNew, windowNewTab, fullScreenToggle, bookshelfToggle, pageListToggle, docksToggle, retryFailed, settingsOpen: CommandID
    public static let ratingSet0, ratingSet1, ratingSet2, ratingSet3, ratingSet4, ratingSet5, metadataTagsEdit, searchFocus, searchIndexFolder, infoPanelToggle: CommandID
    public static let displayProfileApply, effectsToggle, effectsPanelToggle: CommandID
}

// MVReading
public struct Page: Sendable, Identifiable, Hashable { public var entry: Entry; public var metadata: ImageMetadata?; public var id: Location { get }; public init(entry: Entry, metadata: ImageMetadata? = nil) }
public struct Book: Sendable, Hashable { public var location: Location; public var pages: [Page]; public var isEnumerated: Bool; public init(location: Location, pages: [Page] = [], isEnumerated: Bool = false) }
public enum BookLoadEvent: Sendable { case appended([Page]), sorted([Page]), metadata([Location: ImageMetadata]), availability([Location: Availability]) }
// 缓存未命中时按到达顺序 appended，枚举完成后发 sorted；缓存命中时先发缓存的 sorted，不发 appended，后台刷新有差异时再发 sorted。
// metadata 先交付缓存，再从 startingAt 开始探测；流结束表示全部完成。ReaderSession 收到 sorted 时按页身份保持当前页。
// availability 仅由虚拟书加载器发送：每个容器校验结束（含失败、超时）发一次，覆盖容器内全部列表项；占位元数据只用于排版，不代表来源可用。
public protocol BookLoader: Sendable { func load(_ location: Location, settings: ResolvedBookSettings, startingAt page: Location?) -> AsyncThrowingStream<BookLoadEvent, any Error> }
public final class FileBookLoader: BookLoader {
    public init(sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex, pipeline: any ImagePipeline)
}
public enum ShelfEvent: Sendable { case appended([Entry]), sorted([Entry]) }
public enum NavigationDirection: Sendable { case forward, backward }
public protocol Bookshelf: Sendable {
    func items(in directory: Location, sort: SortSpec) -> AsyncThrowingStream<ShelfEvent, any Error>   // 书：子文件夹与压缩包
    func cover(of book: Location, priority: IOPriority) async throws -> Location?
    func rememberBook(_ book: Location) async   // 存在时记住排序所需信息，协议扩展默认空实现
    func neighbor(of book: Location, _ direction: NavigationDirection, sort: SortSpec) async throws -> Location?
    func passThrough(_ location: Location) async throws -> Location
}
public final class FileBookshelf: Bookshelf { public init(sources: any SourceRegistry, directories: DirectoryCache) }
public enum PagePart: Sendable, Hashable { case whole, leftHalf, rightHalf }
public struct PageFrameElement: Sendable, Hashable { public var page: Int; public var part: PagePart; public init(page: Int, part: PagePart = .whole) }
public struct PageFrame: Sendable, Hashable { public var elements: [PageFrameElement]; public init(elements: [PageFrameElement]) }   // 元素按画面从左到右，页帧序列按阅读顺序
public struct PageLayout: Sendable, Hashable { public var pageMode: PageMode; public var direction: ReadingDirection; public var firstPageSingle: Bool; public var widePage: WidePagePolicy; public init(pageMode: PageMode, direction: ReadingDirection, firstPageSingle: Bool, widePage: WidePagePolicy) }
public enum PageFrameEngine { public static func frames(aspectRatios: [Double?], layout: PageLayout) -> [PageFrame] }
public struct FittedPage: Sendable, Hashable {
    public var element: PageFrameElement
    public var pixelSize: PixelSize     // 在视口中占的设备像素
    public var decodeSize: PixelSize    // 向管线请求的尺寸；半页时是整页尺寸，宽高比与源一致
}
public struct PageFrameFit: Sendable, Hashable {   // 查看器与预解码共用；元素顺序与 frame.elements 相同
    public var pages: [FittedPage]
    public var size: PixelSize
    public init(pages: [FittedPage], size: PixelSize)
    public static func fit(frame: PageFrame, pages: [Page], viewport: PixelSize, backingScale: Double, settings: ResolvedBookSettings) -> PageFrameFit
    public func displayTargets(settings: ResolvedBookSettings, maxDecodeLongSide: Int) -> [(element: PageFrameElement, target: DisplayTarget)]
}
public enum PageMove: Sendable, Equatable { case nextFrame, previousFrame, nextPage, previousPage, first, last, index(Int) }
@MainActor @Observable public final class ReaderSession {
    public let id: SessionID
    public init(id: SessionID = SessionID(), loader: any BookLoader, settings: any SettingsStore, bookshelf: any Bookshelf, pipeline: any ImagePipeline)   // 由 CoreServices.makeSession() 调用
    public private(set) var book: Book?; public private(set) var frames: [PageFrame]; public private(set) var currentFrame: Int
    public private(set) var settings: ResolvedBookSettings; public private(set) var loadError: (any Error)?
    public func open(_ location: Location, at page: Location?) async
    public var onBookOpened: (@MainActor (Location) -> Void)?   // 第一批非空页到达后，每次 open 调用一次
    public var isVirtualBook: Bool { get }
    public private(set) var unavailablePages: Set<Location>
    public func setAvailability(_ results: [Location: Availability])   // 不可用立即占位；available 仅触发重新校验，不直接清除占位
    public func reloadBook()   // 当前页还在则保持身份，否则停在原序号，越界取最后一页
    public func go(_ move: PageMove)
    public func applyFileChanges(_ changes: [FileChange])   // 组合根转发；递归新增页按平铺顺序插入
    public func openNeighborBook(_ direction: NavigationDirection, sort: SortSpec) async   // sort 是书架面板当前的排序，与书内页面的排序无关
    public func update(_ change: (inout BookSettings) -> Void)   // 写入书层，去抖后持久化；只改 effects 或 background 时不重排页帧、不重设预取计划
    public func visibleRangeChanged(_ pages: Range<Int>)        // 连续和瀑布模式由前端回报
    public func viewportChanged(_ pixels: PixelSize, backingScale: Double)   // 设备像素；未回报前不预解码
    public var currentPage: Int { get }   // 分页模式下是当前页帧中阅读顺序靠前的一页，连续和瀑布模式下是回报的当前页
    public var maxDecodeLongSide: Int { get }   // 查看器和预解码用同一个值，设置改变时热生效并通知观察者
    public var neighborSort: SortSpec { get }   // 切相邻书用的排序
    public private(set) var lastMoveAt: ContinuousClock.Instant?   // 最近一次 go 的时刻，统计翻页到上屏的用时
    public func shelfSortChanged(_ sort: SortSpec)             // 书架面板的排序；未回报前不预取相邻书和封面
    public func flush() async   // 立即把最新书记忆快照写入 SettingsStore；数据库落盘由组合根负责
}
// 分页模式在视口回报后，对当前帧前后各 viewerDecodeFrames 个页帧（不含当前帧）按 PageFrameFit.displayTargets 预解码；连续模式仍按可见范围。相邻书与封面在排序回报后以 .adjacent 合进同一份计划。
// 虚拟书打开时即消费加载器可用性；只有加载器明确报 available，或撤销得到真实 Entry 且成功取图，才移出 unavailablePages。文件变更或后续不可用结果使旧的在途结果失效。
// 首批页前发生的变更在页面到达时重放，删除状态随位置迁移，先占位再预取；锚点在页面尚未到达时也随移动更新。
// moved 的对象就是此页时，to 才是该页的真实 Entry，可在成功取图后恢复；目录移动中的不可用子页仅改写快照位置，必须先由加载器重新校验来源。

public struct ReadingListing: Sendable { public static func isVisible(_ entry: Entry) -> Bool }   // 以 . 开头的名字不显示
public enum ReadingOrder { public static func sorted(_ entries: [Entry], by sort: SortSpec) -> [Entry] }   // 书架和页面列表面板自己的排序用它

// MVLibraryData：完整类型和方法签名以 Sources/MVLibraryData/LibraryTypes.swift 为准（见 §3.6 链接）。
// SQLiteLibraryStore(databaseURL:historyLimit:) 实现 LibraryStore；flush() 冲刷 WAL。
// AvailabilityChecker(sources:directories:store:).check(_:) 返回 AsyncStream<[Location: Availability]>。
// PlaylistBookLoader(store:sources:directories:metadata:pipeline:) 符合 BookLoader，缺列表抛 IOError.notFound。
// 快照 sorted → 容器独立校验及 availability → 必要时原序 sorted、静默回写 → 元数据；不可用项交付占位尺寸且流结束。
// apply 只迁移 moved，单事务并仅发 relocated；updateSnapshots 不改顺序、不通知；变化写成后广播给多订阅者。

// MVSearch
public struct IndexProgress: Sendable, Hashable {
    public var phase: Phase; public var listed: Int; public var probed: Int; public var toProbe: Int; public var failures: Int
    public enum Phase: Sendable, Hashable { case listing, probing, finished }
}
public final class FolderIndexer: Sendable {
    public init(sources: any SourceRegistry, directories: DirectoryCache, metadata: MetadataIndex)
    public func index(_ folder: Location) -> AsyncThrowingStream<IndexProgress, any Error>   // 两步索引（递归枚举 + 低优先级增量探测）；取消即停；同卷串行排队；卷降级时整步报错、已写入部分保留
}

// MVServices
public struct LibraryBookLoader: BookLoader {
    public init(files: any BookLoader, playlists: any BookLoader)
}   // playlistID 非 nil 时分派到列表加载器，其余走文件加载器；Mock 共用。
public struct CoreConfiguration: Sendable {
    public var supportDirectory: URL; public var cacheDirectory: URL
    public var browseBounds: PixelSize; public var helperExecutable: URL?
    public init(supportDirectory: URL, cacheDirectory: URL, browseBounds: PixelSize, helperExecutable: URL? = nil)
}   // browseBounds 由 App 提供显示器像素尺寸；helperExecutable 为辅助进程可执行文件
@MainActor public final class CoreServices {
    public static func make(configuration: CoreConfiguration) async throws -> CoreServices
    public convenience init(sources: any SourceRegistry, pipeline: any ImagePipeline, settings: any SettingsStore, commands: CommandRegistry, bookshelf: any Bookshelf, loader: any BookLoader, library: (any LibraryStore)? = nil, search: SearchCatalog? = nil, indexer: FolderIndexer? = nil)   // Mock 等消费方的构造入口
    public let sources: any SourceRegistry; public let pipeline: any ImagePipeline; public let settings: any SettingsStore
    public let commands: CommandRegistry; public let bookshelf: any Bookshelf; public let keyBindings: JSONDocumentStore<KeyBindingsFile>?   // Mock 为 nil
    public let fileOperations: FileOperationService?   // Mock 为 nil
    public let library: (any LibraryStore)?   // make 为 SQLite；makeMock 为内存 MockLibraryStore
    public let availability: AvailabilityChecker?   // Mock 为 nil
    public let search: SearchCatalog?   // make 为真实 SearchCatalog；makeMock 使用临时目录的 CacheIndex 接入真实 SearchCatalog
    public let indexer: FolderIndexer?  // make 与 makeMock 均接入真实 FolderIndexer
    public func appliedFileChanges() -> AsyncStream<[FileChange]>   // 目录缓存、元数据迁移/改挂、书记忆、资料库迁移尝试和活跃会话处理后广播；资料库失败仍交付本批，支持多个订阅者，Mock 为空流
    public func interruptedTransfersReport() async -> ResumeReport?   // 等待启动恢复并返回同一份结果；Mock 为 nil
    public nonisolated func metadataDetails(for entry: Entry) async throws -> ImageDetails   // 经 SourceRegistry 增量读前 64 KB（上限 MediaProbe.headerLimit），压缩包内条目同样可读
    public func makeSession() -> ReaderSession   // 组合根弱引用会话，以便退出时 flush
    public func shutdown() async   // 会话 flush → pipeline.shutdown → 设置 flush → 资料库 flush → 缓存索引 flush → 调度器 shutdown；总时限 1 秒，超时返回且不再开始写入
}
// 组合根订阅文件变更：先收集 moved 涉及的元数据迁移对（含目录后代）→ 目录缓存 → MetadataIndex.move 与 .rewritten 的 store/remove + pipeline.carryOver → 冲刷相关会话及待写历史 → 按每个 moved 迁移书记忆与 library.apply → 会话（.rewritten 仅原位更新 identity 与 metadata，不重载）→ 广播。
// library.apply 失败只记日志，其事务保持三表原样；会话照常跟随真实文件位置并广播本批，不补偿、不重试。旧资料库项由检查器显示找不到，由用户移除或重新加入。
// makeSession 的 onBookOpened 记录历史；退出先等已排队的历史，再冲刷会话与持久化。启动时异步恢复中断传输。
// library.items / playlistRemoved 重载所有打开对应列表的会话；relocated 不重载，快照回写不通知。
// make 创建空 CommandRegistry，命令处理器由 App 登记。组合根统一订阅内存压力和全局设置变化：
// warning/critical 将四块内存缓存收缩至预算的 50%/25% 并取消 background 预取；设置变化更新全部缓存预算，L3 开关下次启动生效。
// MVTestSupport：extension CoreServices { static func makeMock(_ options: MockOptions = MockOptions()) -> CoreServices }

// MVLayout：App 侧的纯计算，不依赖 AppKit
public struct ViewerTransform: Sendable, Hashable {
    public var zoom: Double      // 相对 PageFrameFit 的倍数
    public var offset: CGPoint   // 页帧中心相对视口中心，设备像素
    public func zoomed(by factor: Double, around point: CGPoint, frame: CGSize, viewport: CGSize) -> ViewerTransform   // 光标处的内容不动
    public func panned(by delta: CGPoint, frame: CGSize, viewport: CGSize) -> ViewerTransform
    public func clamped(frame: CGSize, viewport: CGSize) -> ViewerTransform   // 小于视口时居中，大于视口时不留空
}
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
