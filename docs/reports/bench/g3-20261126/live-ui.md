# G3 实机操作记录

当前源码固定为 `23538a3bc1d59015bdf29ac78811f1a38b3cafee`。MacPro 使用 macOS 27.2（26B123）、M1 Pro、32 GiB。常规 Debug 使用独立支持目录、缓存和窗口布局。系统保存/打开面板、Finder 及 Preview 走 macOS 实际服务；UI 操作用 Peekaboo 前台键鼠，结合窗口画面、辅助功能、NAS 原文件及持久化记录核对。由一个执行者串行操控，没有安装或替换应用。

## 安装版及真实支持目录

安装版源码标识为 `fd7496ab155f9bdf5ac8a7190f2ef6aafab8e8dc`。另起冻结源码的 Release 正常启动，两个 Release 均未传调试参数。操作前通过 `ditto` 私有备份真实支持目录，以路径、类型、权限、文件大小和 SHA-256 对比原件及副本；敏感路径仅保留哈希。目录本身不按文件字节大小比较。两条链分别退出后还原、核准同一份原始状态。最终复核详见 JSON 中的 `cleanup` 与 `restored_support_manifest`。

| 流程 | 原应用 PID → 导入后 → 反导后 | 实际观察 |
|---|---|---|
| 已安装版本 | 41040 → 42558 → 42855 | 系统保存面板写出 8,326 B、0600 的归档；实际打开面板回车进入确认。确认框回车取消，PID 保持。手动确认后重启、返回原导出窗口，再选 before-import 反导。 |
| 冻结 Release | 42967 → 43317 → 43512 | 导出 8,314 B、0600。先用 Book-A 导出，再打开 Book-B；确认导入后 PID 改变并回 Book-A，反导 before-import 后再换 PID 并回 Book-B。 |

AX 读到导出包含来源密码的提醒、确认框的“取消”和“导入并重启”、导入完成提示。选文件与回车、取消时原 PID 保持、确认后两次换 PID 互为核对。主阅读窗截图只显示被模态遮暗的窗口；它不呈现独立确认窗的文字。16 类归档范围内，真实数据有 9 类，含历史 5、脚本 2，书签/列表/插件数为 0。真实数据的页面笔记和已配置 WebDAV 不具备验证条件。MacAir 通过 SSH 实查 macOS 27.0.1，两处标准安装路径、支持目录和同名进程均不存在。没有可操作的 Windows 资源管理器。

## 网络环境与失败边界

起始时受保护的三个 `~/MacViewBench` 路径都未挂载 NFS；既有 `/Volumes/Picture` SMB 保持不动。真实 NFS 与故障代理只使用本轮工作区下的新挂载，远端写入只进入授权树 `macview-fileops-test/{a,b}/g3-20261126-40800`。最早尝试经既有 SMB/初始 NFS 探查或建立本轮目录发生超时，不能据此判 App 错误；随后经 NAS SSH 在授权树创建两个本轮子目录，核实 NFS v4/resvport 独立真实挂载。另用只读挂载访问真实图库。用户的原有挂载、NAS 配置和网络配置没有改动。

| 独立入口 | 到达的边界 |
|---|---|
| Debug App `net-kill` | 直接启动 PID 47473、前台 false，109.07 秒以 -9 结束。卷内回收→撤销→确认清空成功。同卷 500 MB 用 0.141 s、接口总量 20,480 B。20 项加序号完成，目标 SHA/mtime 一致、源剩 0、既有目标保留。跳过策略等待“移动完成”超时，源仍含 001–020 全部 20 项，既有 001 未被覆盖。1 GB 等待“已记录并复制了一部分”超时；脚本随后确实杀死自己的进程，没有证据证明杀进程前已复制超过 32 MB。 |
| Debug App `net-verify` | 全新 PID 48080，250.01 秒实际退出 2。程序报告需等目标卷下次连接；该次目标正式文件列表为空，源/目标/日志/哈希的组合断言失败。普通页与 ZIP 书等待超时，独立重启撤销禁用成功，最后程序报 240 s 总超时。收尾前 SSH 仍见 S6 源 20 张、S7 源单个 1,000,000,000 B。此时独立读取隔离 transfers.json 已空，不能倒推出失败当时其内容。 |
| Release CLI `mvbench fileops` | 首轮外层 300 s 到期退出 124，未取得完整报告。重试使用相同冻结二进制和相同两个受控 NFS 挂载，延长外层期限并由新进程建各自本轮夹具；缓存冷暖与首轮中断的现场并非完全等价。重试实际退出 0，同卷 0.371 s；真实 NFS→本地及 NFS→NFS 各 20 项，既有冲突目标、mtime、SHA 与日志均正确。1 GiB 在 541,065,216 B 强杀，恢复的 SHA-256 等于预期 `b60db3955d428c0cfcf3a8e2bd06d638f2cc24affa355b8044155bf9752a4810`，源移除、临时项清理、记录清空。 |
| 故障代理 | 真实只转发本轮 NFS，暂停后冻结文件服务移动 9.598 s、删除 5.098 s 分别返回 1 个可重试错误、0 更改。恢复同一代理后，重试分别用 0.394 s、1.030 s 成功。正常 App 另实际看到删除提示 Read timed out、Retry 1 Items；同一 UI 中移动小图却能落到目标。UI 故障采样最早在 13 秒后完成，不能量化整个暂停时间的窗口响应；恢复转发后点 Retry 1 Items，稍后仍显示 Read timed out，原文件仍在。 |
| 真实图库 | NAS 与本机 POSIX 枚举均为 14,964 媒体，本机耗时 418.73 s，目录内普通文件 16,668、错误 0。本轮两个独立 FolderIndexer 调用出现 IOError.timeout（第一套外层未捕获错误，以 -5 结束；第二套捕获错误，exit 1）。普通 App 选择真实目录并点索引，随后 16,669 条中 13,946 张图片和 1,018 段视频均有元数据。不能由条目完整推断探测时错误计数。真实双词得到准确 2 项，打开并定位至第 1975 页。 |

## 本轮分项交叉核对

原先 Core 全集中两个 NFS 挂载 guard 的提前返回单列。新挂载补跑的三项实际通过：49,276,048 B JPEG 的网络元数据写入 7.022 s，300 张 JPEG 索引两阶段合计 7.520 s，两个不同 NFS 根间独占改名合同也经过真实卷。额外回归的实际进程状态和前台采样见 JSON。常规界面、App 内建前台真实事件、Core 和 CLI 的结果按条目说明。

可复核的合成屏幕包括未松手时切换标签的连续帧、网络页离线、NFS 元数据重启后四星、永久删除独立确认窗、文件设置英文与 3,000 项虚拟书。真实 NAS 文件名、图片、导出归档和凭据均不放进报告。

[悬停连帧](live-screens/hover-before-release.png) · 离线占位（截图已移除） · 重启后四星（截图已移除） · 永久删除确认（截图已移除） · 网络删除超时（截图已移除） · [英文设置](live-screens/files-settings-en.png) · [3,000 项虚拟书](live-screens/virtual-3000.png)

收尾已核实受保护的三个路径仍未挂载，原 SMB 保持。七个独立 NFS 挂载均卸载成功，故障代理退出时自行卸载第八个；两个本轮 NAS 子目录及同名 AppleDouble 均不存在。真实支持目录 16 个项目与原始清单一致，安装版二进制 SHA-256 保持。

隐私清理包括本次支持目录备份、导出和反导副本、临时解包和含凭据的合成夹具、真实图库的本地缩略图/浏览缓存与原始搜索内容。安装版真实确认/重启的两张已查看截图只在本机私有工作目录保留；可公开的截图均为本轮合成图。


| 场景 | 状态 | 本次操作和所见 | 尚缺证据及限制 |
|---|---|---|---|
| LIB-01 | PASS | 本轮受控 NFS 脱挂后，分别进书签、历史、列表，三处均保留远端项并显示不可用。虚拟书正在浏览的远端页出现网络未连接、连接及从列表移除；受控卷同路径重挂后缩略图和远端页重新可读。 | 仅卸载本轮 lib-volume，未改任何原有挂载。 |
| LIB-02 | PASS | 混合虚拟书实际点击网络 01.jpg 所在页；⌘⌫ 后 NAS 源消失、卷内回收目录出现同名文件，当前读者显示不可用。⌘Z 之后同一源重新出现，回收项消失、当前页恢复。 | 首轮点到本地同名行，已保留首轮并用 NAS 互证正确行。 |
| LIB-03 | PASS | 准备同一网络页的书签、历史、播放列表后，在虚拟书实际 File > Move To 并通过系统目录面板跨卷移入本机。NAS 源消失、本机目标存在；三张表相应远端行各 1→0，本机新址各 0→1。⌘Z 后三表均反向恢复，NAS 源出现。 | 三处引用取自同一正常 App 的持久化结果；移动与撤销均走真实界面。 |
| LIB-04 | PARTIAL | 物理拖动 History 的 Book-A 至未选中的 Bookmarks。在 5.5 秒手势中，系统采样确认鼠标在目标区按住共 1.992 秒。录像第 2 帧仍是 History，第 3 帧截图同时见 Bookmarks 与 Book-A 拖影，之后无拖影；手势和录像均 exit 0。 | 相邻保留帧时标为录制后 666 ms、1,077 ms，录像时钟没有与拖入时刻精确对齐，因此无法给出约 0.35 秒的精确触发时延。此次释放在标签本身，新书签列表为空，没有证明同一笔落进内容区。 |
| LIB-05 | PARTIAL | 实际打开 3,000 项，拖动后核持久化顺序、右侧虚拟书页序和页内容。物理滚轮正确送至 Playlist 后视口由 0102–0106 切至 0220–0226；点页面列表翻页并看到对应图。 | 早先滚轮参数被工具拒绝且视口未动，已保留。对滚动手感是否满意留用户主观判断。 |
| LIB-06 | PASS | 本轮 Library 前台检查历史顺序、单删、清空确认、书记忆；正常前台看见最近打开顺序。真实服务 Session 分两个进程实际保存第 3 页、清空历史、重启恢复不转记旧书、主动打开新书后仅新增该书，两次终行通过。 | 首个额外 Session 调用漏独立书目录，两个模式均 exit 1 setup。补齐 MVSessionBooks 后实际进程均 exit 0；跨进程阶段清空使用真实 LibraryStore。 |
| LIB-07 | PASS | 本轮 Library 四组合完成多级书签、真实拖入/排序、改名/恢复、打开记忆页与仅删索引的前台检查。独立正常窗口从 ⌘D 加入和打开书签，随后从书签实际打开 Remote-Book。 | 自检确认部分菜单动作由内部菜单路由调用。独立窗口未重复每个对话框。 |
| LIB-08 | PASS | 本轮 Library 前台覆盖管理弹窗、条目多选/移除、源书、原文件保持及拖动。正常窗口另实际打开混合列表与 3,000 项列表，用真实拖动重排，核 SQLite 顺序及虚拟书。 | 四组合动作细目见自动化摘要，真实键鼠补证覆盖打开和重排。 |
| LIB-09 | PASS | 本轮四组合前台资料库检查含多入口加入、重复和最近使用；真实事件包括书架和多选页面拖入。常规窗口实际按 ⌘D 并从书签打开。 | 部分命令和选择弹窗由自检调用。 |
| LIB-10 | PASS | 正常应用打开真实 NFS/本地混合虚拟书与 3,000 项虚拟书，查看来源、当前图、列表顺序，点页并核页号。四组合前台补实测视频、ZIP、不可用命令和书记忆。 | 扩展格式由本轮前台自检覆盖。 |
| LIB-11 | PASS | 本轮普通前台真实删除已经显示的 NFS 页并进入不可用占位，NAS 卷内回收、缩略图及撤销后恢复互证。另对同一位置实际跨卷搬移，书签/历史/列表三处同步改变。仅移除列表项及不同显示模式由四组合前台补证。 | 离线占位和删除占位是本轮不同动作。 |
| LIB-12 | PASS | 正常窗口新建布局并加入 History、Bookmarks、Playlist；退出重启由 PID 66702 变 66858，两个窗口均看到 New Playlist 和三个标签，布局文件保有三项。本轮 Dock/Library 前台检查另核跨区移动、隐藏及默认布局。 | 恢复前后都在同一个隔离目录。 |
| LIB-13 | PASS | 四组合 Library 前台各在设置输入上限 3 并确认立即裁剪、继续开书保留上限与旧书记忆；正常窗口经实际 History 表看到最近打开。 | 设置交互来自本轮前台自检。 |
| LIB-14 | PARTIAL | 正常应用断开真实受控卷后，虚拟书实见断线原因、连接和从列表移除入口；删除远端页时另见“原文件已删除”和撤销后原图。四主题/语言的本轮资料库前台渲染成功。 | 各主题中文字断行、明暗对比与瀑布布局的主观接受度需人审；截图不能自行给出设计认可。 |
| LIB-15 | PASS | 四组合资料库各 94 PASS、退出 0；每轮 4 个 SKIP 均单列。增补 Shell Mock/real、Dock 三模式均终行通过。 | 资料库自检明确跳过的四类另列对应场景。 |
| FILE-01 | FAIL | 真 NFS 故障代理下，冻结服务移动/删除按时返回可重试错误，恢复代理后两者均成功。正常 App 移动小页时仍能切到本地页，文件最终到达；真实删除 02.jpg 时界面显示 Read timed out 和 Retry 1 Items。恢复代理后实际点该按钮，初看及稍后复查按钮和同一超时仍在，NAS 原图仍在。 | App 删除重试没有完成；移动没有在该次 UI 复现超时。13 秒后才取得首个 GUI 样本，不能确认挂起期间连续响应。 |
| FILE-02 | PASS | 本机真实文件进系统废纸篓又被 ⌘Z 还原；Finder 收到普通图、ZIP 内页，均核 SHA。另用页面表真全选，拖到新的 Finder 目标，收到所选 4/4 且逐张 SHA 一致。 | 首次用 Shift 点两行时 Finder 仅收到一项；完整全选用独立空目标复核。 |
| FILE-03 | PASS | 正常英文 App 将 02.jpg 改为既有 01.jpg 并提交，实际内嵌英文冲突错误可读且确认键禁用；换唯一名后新文件存在、原名消失，⌘Z 后原名恢复。 | 同轮前台自检查列表顺序；纯外部走查未单独量化排序。 |
| FILE-04 | PASS | 普通图片实际 Copy Path 读取完整 POSIX 路径，ZIP 内页真实 Copy Path 的系统剪贴板严格等于归档自身的完整绝对路径；系统 Open With 动态子菜单可见。本轮前台另核文件 URL、原图数据与无效路径不读盘。 | Preview 是否打开真实文档另见 FILE-13。 |
| FILE-05 | PASS | 真实分类目标按钮、Copy/Move 数字 1 与源/目标数量相符。首次建子目录时输入后仍在编辑；重开有当前页的正常窗口，明确点击行内字段，物理 Return 一次即建 Child-G3 并移入当前图。⌘Z 删除新目录、源四张恢复。完整面板其他动作由本轮前台对应检查补证。 | 英语深色首轮 C2.12 失败保留；普通窗口成功发生在独立目录和明确焦点。 |
| FILE-06 | PASS | 独立 NFS 回收目录不可创建时，真正确认窗显示 Cancel、Delete Permanently 和不可撤销提示；取消保留 NAS 原图，确认后删除。含禁用项的 Edit 菜单读到 Undo=false；另在真实 NFS 网络模式选卷二次确认清空。 | 首轮点到被模态遮盖的主窗未删除，改点独立确认窗后才删除。英文浅首轮自检失败保留。 |
| FILE-07b | PASS | 冻结全量 Core 真实运行文件服务合同测试；另在两个真实 NFS 挂载下确认独占改名拒绝、原文件无损。 | 注入校验错误等合同按单测环境，挂载故障另列。 |
| FILE-07 | PARTIAL | 真实复制/移动、删除撤销/重做与跨启动 Undo 状态由前台测试覆盖；NFS 批量取消保留 5/20 已写和其余原值，界面有进度及 Cancel。 | 单个真实 NFS 删除在代理恢复后点 Retry 1 Items 再次 Read timed out，未恢复；该故障详见 FILE-01/15。 |
| FILE-07c | PASS | 普通应用 Copy 后目标新增、源保留；Move 后源数减少。独立新建子目录、移动与 ⌘Z 清理目录均由真实文件核实。失败重试分支由本轮前台文件模式复测补证。 | 英语深首轮 C2.12 失配单列在自动化摘要。 |
| FILE-08 | PASS | 真实受控 NFS 上 net-kill 的 S2 断言确认卷内回收、书架/列表隐藏、⌘Z 恢复、仅所选卷确认后清除。 | 该组来自 App 网络模式直接启动，未计为前台全程。 |
| FILE-09 | PASS | 真实 NFS 同卷 500 MB 移动。App 网络模式 0.141 秒、接口合计 20,480 B；独立 CLI 重跑 0.371 秒且校验通过。 | 计时依运行负载而变。 |
| FILE-10 | FAIL | App 真实网络模式加序号时 20 项目标哈希/时间一致、原同名文件未覆盖。切换跳过时等待完成超时，多项仍在源端，断言失败。 | 独立 CLI 网络到本机、网络到网络的校验通过，不能覆盖 App 的跳过策略失败。 |
| FILE-11 | FAIL | App 真实网络模式在等待「已复制部分」时超时，随后被强杀；重启称需等目标卷连接，目标文件检验未通过。CLI 独立 1 GiB 重跑于 541,065,216 B 强杀，恢复后哈希一致、源移除、记录和临时项清空。 | App 流程没有证实达成 32 MB 强杀前提，不能从 CLI 代判 App 恢复。 |
| FILE-12 | PASS | 普通、ZIP 承诺各给真实 Finder 一份并核 SHA；全选 4 张再拖入新的 Finder 目标，4/4 文件名和 SHA 成功。承诺租约释放由本轮前台 C2.11 检查。 | 首轮误向系统面板拖动、Shift 两项只收到一项均保留；后续正确窗口和全选才形成完整实证。 |
| FILE-13 | PARTIAL | 普通及 ZIP 的 Show in Finder 均在 Finder 中实际选中正确文件；普通 02.jpg 曾在 Preview 实际出现。独立又选择普通 01.jpg、ZIP 内 zip-1.jpg 并打开列出的 Preview 项。 | 两次系统 Preview 文档路径/字节核对均没有得到此次指定项，只仍能确认先前 02.jpg。不能认定 ZIP 的系统 Preview 打开成功。 |
| FILE-14 | PASS | 英文 ZIP 页实际取包括禁用项的菜单：Move To、Copy To、Rename 禁用；Copy、Copy Path、Show in Finder、Open With 可用，归档 SHA 未变且复制路径准确。四组合中的中文前台检查删除/分类写入拒绝；英文旧断言的问题保留。 | 实际 Finder 选中归档；Preview 的实际窗口见 FILE-13。 |
| FILE-15 | FAIL | 受控网络只暂停本轮挂载。真实服务的移动、删除失败后都能恢复；正常 App 删除失败出现明确限时错误，恢复并点 Retry 1 Items 后再次超时，源仍在。 | 与 FILE-01 为同一实际 App 故障链。Core 能重试成功不能证实 App 的按钮重试成功。 |
| FILE-16 | PASS | App 真实网络模式第二个进程实测撤销菜单不可用，本轮本机文件操作检查也通过跨启动撤销为空。 | 不推及同模式其他失败项。 |
| FILE-17 | PARTIAL | 已检查英文文件设置页、真实分类编辑和新目录成功、真实永久删除独立弹窗；另看到实际网络错误横幅、批量进度与取消。四组合自检留有合成截图。 | 原生菜单和全部控件与原稿逐项的观感待人审，英文/页序旧自检断言和正常窗口行为分别记载。 |
| FILE-18 | FAIL | 构建零告警，Core 全集和补跑 Shell Mock/real、Dock main/restore/corrupt 成功；文件操作四种组合的完整自检均未达 SELFTEST OK。 | 多数稳定英文断言及末页顺序属自检期望，非等量产品故障。 |
| SEARCH-01 | PARTIAL | NAS/本地 POSIX 只读均数到 14,964 媒体，本地 418.73 秒且零枚举错误。正常 App 实际点 Index This Folder 并见目标横幅。最终真实目录 16,669 个条目，其中全部 13,946 张图和 1,018 段视频各有对应元数据；保留第二阶段渐进样本。 | 未捕获 GUI 完成提示及独立错误数。冻结 FolderIndexer 独立 helper 和 direct 调用分别遇 IOError.timeout，不能记为零失败。 |
| SEARCH-02 | PARTIAL | 真图库实际输入双词，App queryText/terms 相符，结果 2 项与真实库 SQL 精确一致。实际选最低 1 星后结果为 0，图像类型筛选状态为 image；位置核实属于所选图库。 | 点击标签菜单后 tags 仍为空，未取得这两个真实结果的有效标签筛选。现有证据无法区分没有可选标签与未选中；没有在只读用户图库写入测试标签。 |
| SEARCH-03 | PASS | 真图库匹配两项，实际选第一项后主窗第 1→1975 页，当前元数据位置与真实命中之一相符。恢复不筛选后有 2 条，实际断开本轮只读图库挂载，点击结果后的画面检出不可用说明，随后在原路径重挂成功。 | 用户原有挂载均保留。图片与真实文件名仅在本机私有缓冲区核对；合成前台另查灰显样式。 |
| SEARCH-04 | PASS | 在受控 NFS 的 07.jpg 正常界面设 4 星，服务器读到 4；同进程一次 ⌘Z 回 0、再设 4。换 PID 后重新打开第 7 页，Info 同时显示 07.jpg、四颗橙星；服务器独立读取为 4。 | 初次重启截了首张 01.jpg 的零星画面；重新选择真正更改的第 7 张后核对成功。另有真实 ⌥4 按键与本地 Saved 反馈。 |
| SEARCH-05 | PASS | 真实 NFS 中 20 张合成 JPEG 全选，实际写 3 星，20/20 JPEG 含该 XMP，⌘Z 后 20/20 为 0。真实 Tags · 20 items 编辑器加入 G3-batch 后 20/20 含标签，一次 ⌘Z 后剩 0。另给整批 2 星，点真实 Cancel，仅 5/20 已写。 | 首轮核对程序将 AppleDouble 也计入数量；只读服务器按实际 JPEG 排除点文件后确认 20 张全回零。模式均为真实前台 Debug。 |
| SEARCH-06 | PASS | 真实只读图库当前 JPEG 的 Info 实见文件、图像、相机、镜头、GPS、尺寸、拍摄时间字段；实际正常窗口翻页后名称/尺寸刷新。带 EXIF 合成样图的字段选择复制在本轮四组前台检查通过。 | 真实图库这次外部复制未能证明剪贴板精确命中所选字段；不披露真实 EXIF 值。 |
| SEARCH-07 | PARTIAL | 普通 ZIP 的 Info 有不可写原因，四组 Search 模式覆盖 PNG、归档和权限恢复重试。在授权 NFS 自有 07.jpg 临时设 0444，原 4 星保持，随后恢复原权限。 | 该次物理按键未采到失败提示/Retry，恢复权限后读回仍为 4；真实 NFS 重试写入未得到证实。 |
| SEARCH-08 | PASS | 真实 NFS 选中 07.jpg，设 4 星和 G3-batch 标签。App 原生改名后，旧名消失，新名读到 4 星及标签；File > Move To 跨卷到本机，NFS 原名消失，本机目标字节仍含 4 星与同一标签。 | 单独做过仅带评分的更名/移动；本行取后续两种属性都存在的样本。 |
| SEARCH-09 | MANUAL | 连接设备清单仅 macOS、NAS，SSH 能连接 MacAir；未发现可用 Windows 资源管理器实例。 | Windows 属性读 4 星/两标签及 Windows 反写后 MacView 读取。 |
| SEARCH-10 | FAIL | 四种组合的搜索各 30 PASS；资料库每组终行成功。文件操作四组均报告失败，详见自动化摘要。 | 搜索独立通过；组合判据包含文件操作回归。 |
| DATA-01 | PASS | 安装版及冻结 Release 都从真实 File 菜单启动保存面板，保存实际归档并看到来源密码警示，文件权限均 0600。 | 真实归档仅包含实存的 9 类数据。 |
| DATA-02 | MANUAL | MacAir SSH 在线，标准 /Applications 及用户 Applications 无 MacView，真实支持目录不存在、无正在运行的 MacView。 | 未安装、未更改该机数据；需具备安装版与目标 NAS 的 MacAir 进行跨机导入。 |
| DATA-03 | MANUAL | MacAir 无安装版。本次真实 MacPro 归档的插件计数为 0，不含可用的真实 WebDAV/页面笔记配置。 | 需有现存真实服务的两机核对免输密码及外部依赖。 |
| DATA-04 | PASS | 安装版和冻结 Release 均真导入并换 PID，Book-B 经原导出返回 Book-A，再导入 before-import 回到 Book-B。各自退出后还原外部原始副本，16 个真实文件系统项逐项一致。 | 9 类实存数据；空书签/列表/插件不提供真实笔记、WebDAV 和完整 16 类内容证明。 |
| DATA-05 | PASS | 安装版实际菜单树取得清空回收目录、导出、导入顺序，两项分别启动系统面板；冻结版另走相同入口。 | 菜单实际操作和系统面板已证实，原生菜单展开时的屏幕目视另计。 |
| DATA-06 | PASS | 安装版真实 NSOpenPanel 中通过“前往”选中实际导出文件并按回车，确认框现取消/导入并重启；确认框再回车只关闭，原 PID 保持。 | 备份反导也经实际系统面板；四次选取均有实际进程与结果。 |
| DATA-07 | PARTIAL | 普通 Debug 系统面板分别选中损坏字节、改后缀普通 ZIP、未来格式：前两者收到不是 MacView 数据文件；未来版本明确显示格式 2 需更新；三个原 PID 与书窗保持。另用隔离的完整合成导出只翻转一个载荷字节并保留 ZIP CRC 有效，PID 与支持目录小文件不变。 | 后一次物理系统面板没捕到校验或损坏原因文字，单列为未证实。四个 errors 前台模式成功，记录在 automation-summary.json。 |
| DATA-08 | PASS | 四种组合均实际注入替换中断、重启进入 rollback-verify，确认回滚提示及被测目录文件指纹，所有相应进程实际退出 0。 | 按规格仅 Debug 隔离注入。 |

## 挂载路径与最终清理

下面 8 个挂载点都建立在本轮工作区内。两个名为 fileops-a、fileops-b 的挂载位于隔离 HOME，具体绝对路径如下。

| 本轮挂载的完整本机路径 | 源及身份 | 清理结果 |
|---|---|---|
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/fault` | localhost NFS 故障代理；上游 nas.example:/export/Photos/macview-fileops-test/a/g3-20261126-40800（由本轮 mvbench io proxy 管理） | 本轮代理退出时自行卸载；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/permanent-volume` | nas.example:/export/Photos/macview-fileops-test/a/g3-20261126-40800/permtest（rw,resvport,vers=4） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/lib-volume` | nas.example:/export/Photos/macview-fileops-test/a/g3-20261126-40800/libfixture（rw,resvport,vers=4） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/MacViewBench/fileops-b` | nas.example:/export/Photos/macview-fileops-test/b/g3-20261126-40800（rw,resvport,vers=4） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/MacViewBench/fileops-a` | nas.example:/export/Photos/macview-fileops-test/a/g3-20261126-40800（rw,resvport,vers=4） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/source-b` | nas.example:/export/Photos/macview-fileops-test/b（授权测试父树的初始探查挂载） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/source-a` | nas.example:/export/Photos/macview-fileops-test/a（授权测试父树的初始探查挂载） | 普通 umount 返回 0；最终挂载表无此项 |
| `/Users/yuwk/Developer/Repos/Personal/MacView/.g3-work/execution/live/home/gallery-ro` | nas.example:/export/Photos（ro,resvport,vers=4） | 普通 umount 返回 0；最终挂载表无此项 |

真实用户路径按系统挂载表全路径匹配，结果如下。

| 真实用户路径 | 初检 | 卸载工作区挂载之前 | 工作区清理后及最终复核 | 对该路径的挂载操作 |
|---|---|---|---|---|
| `/Users/yuwk/MacViewBench/nfs` | 未挂载 | 未挂载 | 未挂载 | 无 |
| `/Users/yuwk/MacViewBench/fileops-a` | 未挂载 | 未挂载 | 未挂载 | 无 |
| `/Users/yuwk/MacViewBench/fileops-b` | 未挂载 | 未挂载 | 未挂载 | 无 |

原有 SMB `/Volumes/Picture` 保持挂载。资料库和图库断线场景只操作上表的工作区挂载点。常规卸载命令为 `sudo -n /sbin/umount <完整工作区挂载路径>`，每次具体参数与退出码均记入 `live-summary.json` 的 `cleanup.unmounts`。

本轮 4.8G 的构建、独立源码副本、脚本、日志和缓存已清理。工作区中仅保留原路径的 30 张已查看临时 PNG。文件集合中没有归档、凭据备份或用户图库缓存。按当前 HEAD 检查产品 tracked 差异为空。
