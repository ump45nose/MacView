# G3 全量验收场景清单

盘点基线：`main` 冻结提交 `23538a3bc1d59015bdf29ac78811f1a38b3cafee`（2026-11-26）。本文件是验收准备清单，不是验收结果；实际执行和收尾见 `live-ui.md` 与 `live-summary.json`。报告、CI、自检或旧构建上的通过记录只作为覆盖线索，每项仍须绑定本轮被验收构建及实际观察。

登记约束：`max_workers=1`。盘点只读；没有运行自检、构建、NAS 操作或安装版操作。

## 来源与范围

- 路线图：`docs/plans/roadmap.md` §S3 全文（任务行、T5 约定、G3 留项及遗留）及其中引用的 S3 报告。
- 需求：`docs/plans/requirements.md`，特别是 P1 书签/播放列表、文件操作、搜索元数据、用户数据导入导出及性能范围。
- 报告：`docs/reports/S3-{T1,F1,T2,F2,T3,F3}.md`；`docs/reports/G5.md` 用作关口报告结构参考（冻结点、逐场景实际环境表、未闭环原因、手动清单、遗留边界）。
- `docs/plans/tasks/` 中没有对应 S3 任务文档。现有 worktree 里也没有 S3-T1/F1、S3-T2/F2、S3-T3/F3 的 `.spec/requirements.md` 或阶段总结。T1/F1、T2/F2 的明确编号条件从正式报告和冻结路线图恢复；S3-F1/F2 报告及一份现存 worktree 的 `App/Debug/{LibrarySelfTest,FileOpsSelfTest}.swift` 仅用于补充 C2 自检动作映射，不把 C2 编号冒充原 S 编号。
- S3-T5 没有正式的 `docs/reports/S3-T5.md`。补充来源是现存工作树 `.claude/worktrees/practical-hermann-72b584/.spec/{requirements.md,stage-1.md,stage-1-summary.md,stage-2.md,stage-2-summary.md,stages.md}`。该来源不是冻结 main 中的正式报告，矩阵中的 T5 细项明确标注为规格/阶段总结来源；阶段总结的旧通过只表明当时 Debug 自检或冒烟覆盖过，不是当前安装版、本轮 UI 或跨机通过。

## 执行前真实环境条件

| 环境/安全项 | 前置与限制 |
|---|---|
| 版本与构建 | 本轮开始前记录冻结源码 SHA、Debug 自检构建身份和已安装 `/Applications/MacView.app` 的 `MVSourceCommit`/CDHash；旧报告提交、CI 结果、开发自检均不可替代当前验收构建。跨机项目应确认 MacPro、MacAir 使用兼容版本。 |
| Debug 自检 | 使用 `-MVSupportDirectory`、`-MVCacheDirectory`、`-MVLayoutFile` 各自独立目录。要求真实前台的检查通过 `open -n -W -a … --args -MVSelfTestActivate YES`，前台桌面已解锁；点击/拖动必须经真实事件路径。自检模型、CLI 状态和截图分别只能证明其明确覆盖的部分，不能证明真实菜单、系统面板或屏幕效果。 |
| Release 安装版 | Release 忽略所有 `-MV…` 隔离参数，直接使用真实 `~/Library/Application Support/MacView`。实机前备份该目录，场景完成后按计划恢复并核对；不得对 Release 运行自检。安装版菜单目视与真实 NSOpenPanel 必须真实操作。 |
| NAS/网络卷 | NAS 用户文件默认只读，不改 NAS 配置或系统网络。用户本轮明确允许验收方自己新建受控测试挂载；不得卸载现有 `fileops-b`。Library 离线/恢复可用独立新建的等价受控挂载代替，不把触碰现有挂载当作前提。系统首次授权等待时须由用户在场点“允许”，否则 9 秒超时会把卷降级，不能判作产品失败或通过。故障注入挂载须用户 sudo。 |
| 明确的 NAS 测试写入范围 | 既有 S3-T2 报告使用的测试树为 `~/MacViewBench/fileops-a`、`~/MacViewBench/fileops-b`，只允许本次命名的合成测试文件/目录（如 `macview-selftest-*`、`macview-fileops-*`、`.macview-trash`），结束后清理。用户本轮另明确授权验收方自己新建受控测试挂载；禁止卸载现有 `fileops-b`，Library 离线场景用新挂载复现。Windows 元数据互通样本指定为 `\\nas.example\Picture\macview-fileops-test\a\评分样图.jpg`。 |
| 跨设备/真实服务 | MacAir 需有真实数据目录/安装状态；WebDAV 要真实服务和来源密码已配置，验收不记录密码。不得把本机 WebDAV 替身、模拟网络或旧隔离目录当作跨机/真实服务证据。用户已授权真实支持目录备份/还原及指定测试目录操作，可按计划执行并核对，不需再次请求许可。 |

## 场景矩阵

“覆盖线索”是静态盘点出的现有入口，不表示已运行或本轮已通过。缺少专用入口的手动场景注明“未见自检覆盖”。

| ID / 来源 | 原始验收条件（按可执行动作拆分） | 要求环境 | 现有自检/CLI 覆盖线索 | 手动阻塞原因候选 / 现场判据 |
|---|---|---|---|---|
| G3-LIB-01 / roadmap S10 | 网络根不可用时书签、历史、列表里的条目变灰；点开显示“网络卷没有连接”；已打开虚拟书里该卷的页变占位；重新连通后恢复。 | MacPro Debug 前台 + 用户本轮新建的受控等价 NFS 挂载；不得卸载现有 `fileops-b`。 | `-MVLibrarySelfTest` 有可用性/占位/恢复路径；自检模拟不能替代真实挂载离线/恢复。 | 用新挂载单独模拟离线与恢复；系统授权弹窗由用户在场处理。 |
| G3-LIB-02 / roadmap S8 | 打开受控网络卷虚拟书，删除其中一页进入卷内回收目录；页面/列表条目变灰；⌘Z 后原条目与页面恢复。 | MacPro Debug 前台、已有授权测试树或本轮新建受控可写 NFS 挂载上的合成页。 | `-MVLibrarySelfTest` 删除/撤销场景；`-MVFileOpsSelfTest net-*` 覆盖文件操作回收，但虚拟书组合需实际走查。 | 只写本次创建的测试树；清理仅本轮产生的文件，保留挂载。 |
| G3-LIB-03 / roadmap S9 | 从虚拟书跨卷移动列表中的一页；书签、历史、列表三处都改指新位置。 | MacPro Debug 前台；源在新建受控网络挂载，目标在另一卷/本机测试目录。 | Library/FileOps 自检有位置变更与迁移检查线索；无证据覆盖三处 UI 的完整联动。 | 需真实跨卷写入，位置项和哈希/页面状态均需核对；现有挂载不卸载。 |
| G3-LIB-04 / roadmap 面板悬停 | 把拖动停在未选中面板标签约 0.35 秒，尚未松手时标签已切换到目标面板，然后完成拖放。 | 解锁 MacPro 前台，真实鼠标拖动。 | 报告指出待核 `DockTabView.draggingEntered`；未见可替代真实悬停的 CLI。 | 需真实 AppKit 拖放计时/事件；屏幕录制或逐帧观察确认松手前切换。 |
| G3-LIB-05 / roadmap S11 | 打开 3000 项播放列表，滚动、拖动排序、虚拟书翻页；确认实际 UI 手感可接受。历史记录约 104 ms/页只作背景。 | MacPro Debug/当前验收构建、3000 项合成目录和真实前台。 | `-MVLibrarySelfTest` 有大列表/虚拟书线索；Core seed/性能数据只测数据层，不代表面板和拖动手感。 | 主观流畅度无模型/CLI 判据；需实际看滚动、排序、连续翻页及交互反馈。 |
| G3-LIB-06 / S3-F1 C2.1（历史） | 历史按最近打开顺序倒序显示；点历史项打开对应书并回到上次页；单项删除；清空历史需确认且不清除书记忆；重启恢复时不把旧会话重新写入已清空历史，之后主动打开仍正常记历史。 | MacPro 当前 Debug 构建，隔离支持目录与前台；清空/重启动作走真实 UI 或真实进程重开。 | `-MVLibrarySelfTest` C2.1；`-MVSessionSelfTest history-write/history-verify` 提供跨进程线索。 | Core 持久化测试不能替代 App 重启与清空确认；历史对应的书签/记忆须分别核对。C2.1 是报告编号，原 S1–S7 未在现存正式材料中逐项留文案。 |
| G3-LIB-07 / S3-F1 C2.2（书签） | 新建多级书签文件夹；将书签移入文件夹并排序；修改显示名、恢复原名；从书签打开并回到上次页；删除书签只移除索引、不删原书。 | MacPro Debug 前台，合成目录/ZIP；真实事件拖放与点击。 | `-MVLibrarySelfTest` C2.2。 | 需逐条核对树形层级、排序和原文件未改；自检状态数据不能替代屏幕上真实拖放。原始任务 S1–S7 的逐条映射在现存正式文档中未保留。 |
| G3-LIB-08 / S3-F1 C2.4–C2.5（播放列表管理） | 新建、重命名、删除播放列表；删除列表前确认且原文件不动；多选条目、拖动排序、从列表移除（文件不变）、双击条目从该页作为书打开、打开所在源书。 | MacPro Debug 前台；多来源合成书/视频/ZIP；确认与拖动真实送达。 | `-MVLibrarySelfTest` C2.4、C2.5。 | 逐项记录列表名、项序和源文件状态；确认框、排序手势不能仅用模型/CLI 通过替代。 |
| G3-LIB-09 / S3-F1 C2.7–C2.8（加入入口） | 从书架、当前书（⌘D）、页面列表多选（含视频/压缩包页）及查看器命令加入书签/播放列表；重复加入给出提示；最近使用列表置顶；顺序和部分重复提示正确。 | MacPro Debug 前台，合成普通书、视频、ZIP；键盘、右键及跨面板拖动事件。 | `-MVLibrarySelfTest` C2.7、C2.8。 | 原报告明确这些组合曾有待复测；按每个入口留屏幕结果。不能把 DebugSocket 的 `library.bookmark.add`/`playlist.addCurrent` 直接算 UI 验收。 |
| G3-LIB-10 / S3-F1 C2.9（虚拟书） | 播放列表按列表顺序显示成书；来源与文件路径可见；图片正常显示、视频可播放、ZIP 内页可打开；播放列表自身不可排序/加入书签、上一/下一本命令不可用；书记忆恢复浏览位置、浏览模式和缩放。 | MacPro Debug 前台，含两本源书、视频与 ZIP 的测试集；关闭并重开会话。 | `-MVLibrarySelfTest` C2.9；Core `ReaderSession`/`LibraryStore` 定向测试仅作模型线索。 | 必须实际核对虚拟书画面、命令灰态和独立重启记忆；单项书或 DebugSocket `hasImage` 不覆盖组合。 |
| G3-LIB-11 / S3-F1 C2.10–C2.11（虚拟书变化） | 删除虚拟书正在显示的原文件后，已缓存图片不应残留：显示占位且列表项变灰；⌘Z 后原图/条目恢复。另一项只从列表移除时原文件不动。改名/移动源书或页后，书签/历史/列表跟随新位置，当前页不中断或错位。 | MacPro Debug 前台，隔离支持目录中的缓存图、普通目录和虚拟书。 | `-MVLibrarySelfTest` C2.10、C2.11；`-MVFileOpsSelfTest` Core/界面线索。 | 需目视缓存失效、占位和恢复；当前书改名后画面历史曾需修复，不能以旧四组合截图当本轮通过。 |
| G3-LIB-12 / S3-F1 C2.12（资料库面板） | 新面板初始隐藏；从窗口菜单加入、勾选；跨停靠区移动、隐藏、保存布局并重启后保持。 | MacPro Debug 前台，独立布局文件，重启 App。 | `-MVLibrarySelfTest` C2.12；既有 Dock `main/restore` 自检。 | 旧报告明确新面板重启保持曾待验；当前要核独立进程恢复，不以同进程恢复代替。 |
| G3-LIB-13 / S3-F1 C2.13（历史上限） | 在设置页真实输入并提交历史上限 3；列表立即裁剪到最近 3 本，继续打开 5 本时保留最新 3 条，书记忆仍可用。 | MacPro Debug 前台，隔离设置/支持目录。 | `-MVLibrarySelfTest` C2.13；Core 旧设置兼容单测。 | 通过真实输入框提交与重开设置检查；Core 上限检查不能替代 App 操作。 |
| G3-LIB-14 / S3-F1 C2.15（状态与外观） | 网络断开、原书/页缺失、瀑布/连续显示时错误原因、移除入口和连接入口可见；切换中英文/明暗时核心行文正确；按规格目视占位、书签、列表及虚拟书截图。 | MacPro Debug 前台；合成缺页和受控网络卷；中英/浅深隔离配置。 | `-MVLibrarySelfTest` C2.15；四组合自检。 | 旧报告提到锁屏时未点移除/连接，部分视觉由状态/截图断言覆盖；本轮需真实操作并区分状态覆盖和屏幕呈现。 |
| G3-LIB-15 / S3-F1 C2.14（四组合与回归） | 当前构建在中文浅色、中文深色、英文浅色、英文深色逐一运行资料库完整自检，记录 `SELFTEST OK` 和每项 SKIP；运行对应外壳、停靠、面板及文件操作回归。 | MacPro 当前 Debug 构建，前台解锁；每组合独立 support/cache/layout。 | `-MVLibrarySelfTest YES`；`-MVSelfTest`；`-MVDockSelfTest main/restore/corrupt`；`-MVFileOpsSelfTest YES`。 | 旧报告的四组合已绑定旧 SHA，不能作本轮证据；需确认自检实际进入前台，零前台采样或 SKIP 不算通过。 |
| G3-FILE-01 / roadmap S11 | 在受控网络故障卷无响应时，对网络文件执行跨卷移动和删除；期限内报错，恢复服务后可重试且 UI 未冻结。 | 独立可写故障代理 NFS 挂载；用户 sudo 启动/恢复；MacPro 前台。 | `-MVFileOpsSelfTest net-kill`/`net-verify` 覆盖进程中断恢复而非网络超时；`mvbench io proxy --nfs-options rw` 是报告中列出的故障代理线索。 | 故障代理需要 sudo 和用户批准的独立写卷；主线程冻结/错误/恢复均需观察。不得在本轮直接改现有 NAS 挂载。 |
| G3-FILE-02 / S3-F2 S1（本机废纸篓/拖出） | 本机文件删除进入系统废纸篓，⌘Z 恢复；普通图片和压缩包内图片均可拖到 Finder，文件名/内容正确；多选拖出时拖出所选项。 | MacPro Debug 前台 + 隔离本机样本 + Finder；真实拖放。 | `-MVFileOpsSelfTest` C2.11 覆盖生产拖出路径；报告记载 S1 本机 Trash/⌘Z 和普通/ZIP 拖出由用户手动通过。 | Finder 真正接收和可读文件必须目视；不只验证拖动载荷写入器。原 S1 的报告动作已确认。 |
| G3-FILE-03 / S3-F2 C2.6（重命名） | 重名时显示表单内错误且不改文件；改成唯一名称后完成、列表按排序更新；⌘Z 恢复原名/顺序。 | MacPro Debug 前台，隔离本机书。 | `-MVFileOpsSelfTest` C2.6。 | 需要真实表单确认与错误呈现；历史通过仅为线索。正式报告未给该动作的原 S 编号。 |
| G3-FILE-04 / S3-F2 C2.7、C2.10（复制/剪贴板/指定应用） | 复制图像到剪贴板同时含文件 URL 和原始图像数据；复制路径返回完整 POSIX 路径，ZIP 内页复制路径为归档路径；“用指定应用打开”依文件类型列出应用，即使路径不存在也不触发文件读取。 | MacPro Debug 前台，隔离图片/ZIP；剪贴板与 Preview/指定应用。 | `-MVFileOpsSelfTest` C2.7、C2.10。 | 实际剪贴板内容和应用启动需确认；模型菜单项不证明系统接收内容。原 S 编号未在正式报告中标明。 |
| G3-FILE-05 / S3-F2 C2.12–C2.15c（分类面板） | 建目标目录/子目录；按数字键移动、切换复制模式、拖动重排目标并按新编号分类；双击分类行等价移动；文本框焦点数字正常输入；压缩包项拒绝移动；新建目录后传输失败可重试，⌘Z 撤掉新目录；浮动面板绑定活动窗口和原页快照。 | MacPro Debug 前台，隔离本机文件与两窗口；真实按键/拖放。 | `-MVFileOpsSelfTest YES` C2.12–C2.15c；中英/浅深已有覆盖线索。 | 分类面板 CoreText 绘制历史崩溃未归因；需观察崩溃和实际数字键/拖动。仅在真实前台测试，避免窗口不可见造成假失败。原 S 编号未逐项保留。 |
| G3-FILE-06 / S3-F2 C2.4c（永久删除） | 当网络回收目录不可用时永久删除确认框出现；取消后原文件不变；确认后文件删除且不进入撤销历史。清空网络卷回收目录要单独选择目标卷并二次确认。 | MacPro Debug 前台；本机合成回收目录不可用和授权的测试卷 `.macview-trash`。 | `-MVFileOpsSelfTest` C2.4c；网络空回收目录路径见 C2.18。 | 永久删除不可逆；只对合成/授权测试项执行，真实确认前核对路径与内容。 |
| G3-FILE-07b / S3-T2 C1.8,C1.11–C1.15（Core 操作合同） | 对 create-folder、rename、copy/move、delete、永久删除执行成功/失败/撤销/重做；核对同名策略（加序号/跳过）、中途取消的完成/未完成项边界、校验失败保留源且清除临时项、日志不可写时不得启动移动、不可用卷恢复规则。符号链接按自身处理，不跟随目录链接，链接复制/跨卷移动拒绝。 | Core 定向测试（当前冻结源码）；真实 NFS 测试仅补真实跨卷/网络条目。 | `make test` 中 `MVFileOpsTests`；报告列出的测试包括 `fileOperationsAndTheirInverses`、`transferModesAndConflictPoliciesUndoAndRedo`、`cancellationPreservesCompletedMoves`、`verificationFailureKeepsSourceAndCleansTemporary`、`journalFailurePreventsMove`、`resumeAllRecoveryRulesAndUnavailableVolume`、符号链接测试。 | Core 单测只证明其构造的本机/模拟输入；不代替 UI、真实网络写、Finder 或 App 重启。未找到这些功能的统一原始 S 编号，不另编号。 |
| G3-FILE-07 / S3-F2 C2.1–C2.4b,C2.23（撤销/重做/取消） | 本次运行内可撤销/重做各可逆操作；跨运行后撤销菜单不可用。长操作显示进度，取消时已完成项保留、未完成项仍在源端且无临时文件；失败项显示错误与重试，部分成功不破坏已完成项。 | MacPro Debug 前台，隔离文件及跨进程重启。 | `-MVFileOpsSelfTest` C2.1–C2.4b、C2.23；`make test` Core `MVFileOpsTests`。 | 完整检查跨进程恢复和 UI 错误条；`deletePermanently` 不可撤销属设计要求。原 S 编号未在正式报告中标出。 |
| G3-FILE-07c / S3-F2 C2.12,C2.15c（copy/new folder） | 分类面板切换“移动/复制”时，复制只在目标出现副本、源仍存在；“新建目标并移入”建立新目录并完成移动；传输失败时目录和错误重试状态可见，⌘Z 撤销后删除本次新建空目录。 | MacPro Debug 前台，隔离文件夹与样本；至少一轮真实按键和表单操作。 | `-MVFileOpsSelfTest` C2.12、C2.15c；Core 同卷/跨卷 copy 规则见 `MVFileOpsTests`。 | 需观察源/目标实际文件及界面状态；失败注入只在合成源文件上进行。原始 S 编号未在正式材料中确认。 |
| G3-FILE-08 / S3-F2 S2（网络卷回收） | 在测试 NFS 卷删除页进 `.macview-trash/<批次>`，书架/页面列表不显示回收目录，⌘Z 恢复；清空回收目录只列目标测试卷，确认后清除。 | 用户新建受控可写 NFS 测试挂载；不得卸载现有 `fileops-b`；限定新建测试文件。 | `-MVFileOpsSelfTest net-kill/net-verify` C2.18。 | 需真实网络写入；只清理由本轮在新挂载上创建的测试数据，保留挂载。 |
| G3-FILE-09 / S3-F2 S5（同卷移动） | 在同一 NFS 卷移动 500 MB 文件；文件原子改名语义正确、源消失、目标存在，低于 1 秒且网络接口传输量低。 | 用户新建受控可写 NFS 测试挂载和合成 500 MB 文件。 | `-MVFileOpsSelfTest net-kill` C2.19 S5；报告历史为 0.113 s。 | 必须排除预读/网络拷贝并绑定本轮计时；历史数据不算当前通过。 |
| G3-FILE-10 / S3-F2 S6（跨卷批量冲突） | 从网络卷移 20 项到本机目标且含一项同名；分别测试“加序号”和“跳过”，源/目标数量、既有目标内容、SHA-256、修改时间与提示准确。 | 用户新建受控 NFS 写挂载 + 本机临时目标，20 个合成 1 MiB 文件。 | `-MVFileOpsSelfTest net-kill` C2.19 S6；报告含两个冲突策略。 | 用全新目标树；结束清理，检查哈希/mtime，不以消息或成功计数单独判通过。 |
| G3-FILE-11 / S3-F2 S7（强杀恢复） | 网络卷到本机移动 1 GiB；复制超过 32 MB 时强制杀掉进程；新进程启动完成移动，源移除、目标只有正式文件、SHA-256 一致、记录清空。 | 用户新建受控可写 NFS 挂载 + 本机隔离 support/cache/layout；合成文件。 | `-MVFileOpsSelfTest net-kill` 后 `net-verify` C2.20。 | 实际强杀不可对用户实例操作；只使用隔离自检进程和本轮生成数据。 |
| G3-FILE-12 / S3-F2 S8（Finder 拖出） | 拖出普通文件、选中多项和压缩包内文件；Finder 实际接收文件承诺并能读取，文件名和内容/哈希一致，租约释放。 | MacPro Debug 前台、Finder 目标、隔离普通/ZIP数据。 | 正式报告称 S8 拖 Finder 用户手动通过但未保留更细动作；`-MVFileOpsSelfTest` C2.11 覆盖普通、多选、ZIP 承诺的详细子动作。 | 只按正式报告可确认 S8 与 Finder 拖出相关；普通/多选/ZIP 是 C2.11 自检拆项，不在清单里声称为 S8 原文逐字条件。 |
| G3-FILE-13 / S3-F2 S9（Reveal/Preview） | 普通页在 Finder 中定位并由 Preview 打开；ZIP 内页先解出后定位到归档并由 Preview 打开；核对 Finder 选中项和 Preview 实际内容。 | MacPro Debug/安装版当前验收构建 + Finder/Preview。 | `-MVFileOpsSelfTest net-verify` C2.21 有程序路径；报告明确 Finder 选中及 Preview 窗口内容尚需目视。 | Finder 和 Preview 必须实际操作/观察；仅 URL 或进程触发不算完成。 |
| G3-FILE-14 / S3-F2 S10（归档只读） | ZIP 内条目删除、改名、移动、复制到分类均禁用/拒绝并保持归档不变；复制、复制路径、Reveal、指定应用仍可用。 | MacPro Debug 前台 + 隔离 ZIP。 | `-MVFileOpsSelfTest` C2.8、C2.15a。 | 逐项核对菜单状态和文件内容；本行编号 S10 由自检注释明确对应。 |
| G3-FILE-15 / S3-F2 S11（网络故障） | 故障网络卷无响应时跨卷移动和删除在期限内报错；界面不冻结；卷恢复后操作可重试。 | 用户本轮授权新建的独立可写故障代理挂载；用户 sudo；不动现有挂载。 | `mvbench io proxy --nfs-options rw`；报告明确 S11 尚未跑。 | 需要 sudo 和可控的故障/恢复时序；只能在刚创建的测试挂载及合成项上执行。 |
| G3-FILE-16 / S3-F2 S12（撤销期限） | 完成文件操作后正常退出并重启；撤销菜单不可用，避免把上次进程撤销记录当作有效操作。 | MacPro Debug 隔离支持目录、真实重启进程。 | `-MVFileOpsSelfTest net-verify` C2.23。 | 必须跨进程验证；本次运行菜单可撤销不覆盖该场景。 |
| G3-FILE-17 / S3-F2 C2.25（界面与截图对照） | 对照文件设置页、分类面板有目标/空状态、归档书、右键菜单、改名成功/失败、永久删除确认、回收目录清空列表/确认、进度与错误条，检查中英文/明暗至少覆盖指定组合，记录与设计稿的差异。 | 当前 Debug 构建，MacPro 前台；合成数据与对应隔离目录。 | `-MVFileOpsSelfTest` 有两组 13 张截图的历史输出；报告指出系统菜单截图不是真实渲染，不能替代 UI。 | 当前构建必须实际目视 UI 和事件；截图只说明其实际渲染路径。原始 S 编号未确认。 |
| G3-FILE-18 / S3-F2 C2.24（构建与自检回归） | 当前源码编译零警告；Core 全量测试；外壳 Mock/真实服务自检、Dock main/restore/corrupt、文件操作本机自检均达成功。 | 冻结源码当前 Debug 构建与本机；自检需独立隔离目录。 | `make build`、`make test`、`-MVSelfTest`、`-MVDockSelfTest main/restore/corrupt`、`-MVFileOpsSelfTest YES`。 | 构建/测试过不能代替真实 Finder、Trash、网络卷与目视场景；报告结果需绑定本轮 HEAD，完整测试按项目 CI/日历要求执行。 |
| G3-SEARCH-01 / roadmap S1–S10 + requirements | 在真实图库建立约 1.5 万项索引；查看两步进度及完成/取消行为。 | MacPro，真实图库，NFS 读写挂载；用户确认目标和写入边界。 | `-MVSearchSelfTest` 覆盖两步索引、取消、深层索引；`mvbench search seed/query` 是合成性能工具，不等同真实图库。 | NFS 元数据探测约 30 项/秒是历史性能背景；确认进度不会阻塞 UI，并记录本轮实际完成量。 |
| G3-SEARCH-02 / roadmap S1–S10 | 在图库进行多词文件名搜索，使用评分/标签/类型筛选与范围限制；匹配显示准确。 | MacPro Debug 前台 + 已索引真实 NFS 图库。 | `-MVSearchSelfTest` 的 C2.1–C2.2。 | 自检合成数据不能证明真实目录索引内容；记录实际查询、筛选和结果。 |
| G3-SEARCH-03 / roadmap S1–S10 | 从搜索结果打开并定位到对应图像；不可用结果灰显并显示原因；卷断开时结果仍能给出正确不可用状态。 | MacPro Debug 前台 + 真实 NFS 图库；断卷子场景由用户控制挂载。 | `-MVSearchSelfTest` C2.3 覆盖合成不可用条目/定位；`-MVLibrarySelfTest` 有网络可用性线索。 | 真实网络身份、Finder 激活重查和卷断开/恢复须真实观察。 |
| G3-SEARCH-04 / roadmap S1–S10 | 对图像按 `⌥4` 写 4 星，重启后重新浏览仍为 4 星；⌘Z 撤销回原值。 | MacPro Debug 前台；真实图库中的获准测试 JPEG；NFS RW。 | `-MVSearchSelfTest` C2.5 覆盖隔离数据写入/重读/撤销；Core `MVFileOps` 测试读写机制。 | 写入为整文件读写与校验，20–47 MB 历史耗时约 6–10 秒；必须使用备份/专用样本，不把合成自检当真实媒体读写证明。 |
| G3-SEARCH-05 / roadmap S1–S10 | 对 20 张图批量设置标签/评分；进度、取消与单次 ⌘Z 整批撤回符合预期。 | MacPro Debug 前台；20 张测试 JPEG，NFS RW。 | `-MVSearchSelfTest` C2.6 覆盖 20 张合成图批量与单次撤销。 | 使用已授权测试目录和其中的合成/指定样本，按约定备份；考虑网络耗时，取消后核对已完成项。 |
| G3-SEARCH-06 / roadmap S1–S10 | 信息面板显示文件、图像、拍摄字段；字段可选择复制；换页后跟随当前图。 | MacPro Debug 前台 + 真实 JPEG/EXIF 样本。 | `-MVSearchSelfTest` C2.8 覆盖合成带 EXIF JPEG 和换页。 | 需要目视核对实际照片字段与复制结果；不得把用户图像写入报告/清单。 |
| G3-SEARCH-07 / roadmap S1–S10 | 对不支持评分/标签的格式或压缩包尝试编辑，界面明确说明不可写、保留旧值；只读文件的失败重试恢复后可成功。 | MacPro Debug 前台；PNG/ZIP或只读测试样本。 | `-MVSearchSelfTest` C2.7 覆盖 PNG、压缩包、只读失败/恢复。 | 真实格式限制需向用户可见；实际用户原图不可用于写失败注入。 |
| G3-SEARCH-08 / roadmap S1–S10 | 改名或移动带评分/标签的图像后，评分与标签跟随新路径并可重新读取。 | MacPro Debug 前台 + NFS RW 测试样本。 | Core `MVServices`/`MVCache` 搜索元数据迁移测试和 `-MVFileOpsSelfTest` 覆盖模型线索；未见搜索 UI 在真实 NFS 的完整覆盖。 | 需执行实际文件改名/移动；核对文件元数据与搜索结果，目标限定测试目录。 |
| G3-SEARCH-09 / roadmap S1–S10 | 在 Windows 资源管理器“属性 › 详细信息”核对指定 `评分样图.jpg` 显示 4 星、“精选”“写真”；核对 MacView 写入的图；Windows 改评分后 MacView 重新浏览读到更新值。 | Windows 资源管理器 + NAS 指定测试样本 + MacPro MacView；SMB/NFS 按既有部署可读写。 | 未见 UI 自检或 CLI 能证明 Windows Shell 元数据展示。 | 必须实际 Windows 客户端及跨系统读写；指定样本路径是唯一明确列出的互通样本，禁止扩展写到其他图库文件。 |
| G3-SEARCH-10 / roadmap S1–S10 | `-MVSearchSelfTest` 中文/英文 × 浅/深四组合均达自检成功；另完成 `-MVFileOpsSelfTest` 与 `-MVLibrarySelfTest` 的前台项。 | 当前冻结构建，解锁 MacPro 前台，四个语言/外观隔离目录；网络项另按授权环境。 | 已有入口：`-MVSearchSelfTest`、`-MVFileOpsSelfTest`、`-MVLibrarySelfTest`；过去的四组合结果只作线索。 | 真实前台/系统弹窗/网络访问可导致 SKIP；必须记录每个 SKIP，不以 SELFTEST 汇总覆盖手动项。 |
| G3-DATA-01 / req S1 | 从安装版“文件 › 导出用户数据…”导出 `.macviewdata`；文件权限 0600；App 不冻结；完成提示说明包含来源密码。 | MacPro 安装版 Release + 真实支持目录（先备份）；导出目标由用户选定。 | `-MVDataTransferSelfTest export` 和 `.spec` 阶段 2 冒烟曾覆盖隔离流程/状态；不能用于安装版真实数据。 | Release 无隔离参数，必须备份 `~/Library/Application Support/MacView`；输出文件含明文来源密码，选择安全位置、不得读出/打印凭据。 |
| G3-DATA-02 / req S2,S4 + roadmap T5 | 把 MacPro 导出文件在 MacAir 安装版导入；确认框的来源/时间/版本/数量正确；重启后窗口与标签、设置/外观、快捷键/手势、菜单/工具栏、布局/方案、显示配置、路径规则、历史、书签、列表、书记忆、脚本/命令、插件状态/面板位置/笔记一致。只在 MacPro 存在的本机路径项变灰，NAS 条目可开。 | MacPro 与 MacAir 两台真实设备、兼容的已安装版本、真实导出文件；MacAir 用户数据先备份。 | `-MVDataTransferSelfTest fresh`、`fresh-verify` 及阶段总结曾以隔离目录覆盖数据项；不证明跨设备路径、硬件窗口位置或真实插件外部依赖。 | 需另一台 Mac；屏幕尺寸可能使窗口被系统挪回可见范围；外部程序依赖需目标机具备。菜单、窗口、书签和插件内容都应实际目视。 |
| G3-DATA-03 / req S2,S5 + roadmap T5 | MacAir 导入后，真实带密码 WebDAV 来源不补填密码即可浏览并打开图像；`plugin-secrets.json` 权限 0600。 | MacAir 安装版 + 用户已配置的真实 WebDAV 服务与凭据；只记录成功/失败，不记录密码。 | `-MVDataTransferSelfTest` 曾以本地 Basic Auth WebDAV 替身覆盖免密访问/0600；没有真实服务证据。 | 本机替身不等于真实 WebDAV；服务端可用性和凭据状态须先确认。不得把密码写入截图、日志或报告。 |
| G3-DATA-04 / req S3 | 在安装版真实数据上执行导出→导入→确认重启→核查数据→再导入 `Backups/before-import.macviewdata`，恢复到导入前状态。 | MacPro 安装版 Release + 真实支持目录的可恢复备份 + 两个可读的归档文件。 | 自检 `export/import-verify/revert-verify` 曾在隔离目录覆盖自动备份/还原；真实数据流程无可替代自检。 | 高风险真实数据替换。严格先备份 `~/Library/Application Support/MacView`，核对备份可读；完成后恢复目录并核验，不对 Release 使用 `-MV…` 参数。 |
| G3-DATA-05 / roadmap T5 | 实际打开安装版「文件」菜单，核实「清空回收目录…」之后存在「导出用户数据…」「导入用户数据…」。 | MacPro 安装版 Release，真实前台窗口。 | Core 命令列表和 Debug `dialogs` 自检有菜单接线线索；阶段总结明确菜单目视未完成。 | 系统菜单栏未被辅助功能读取；必须屏幕目视。 |
| G3-DATA-06 / roadmap T5 | 从实际系统 `NSOpenPanel` 选择 `.macviewdata` 文件并按回车，确认系统面板选中文件且真实导入动作走到确认框；确认框默认“取消”，回车不触发导入。 | MacPro 安装版 Release，真实前台；优先用真实 GUI 键鼠代操作尝试。 | `-MVDataTransferSelfTest dialogs` 可核对面板属性、用 `NSApp.sendEvent` 检查确认框按键；不能覆盖独立系统面板的实际选择。 | 可先用当前已授权 GUI 工具实际点选、回车；只有工具无法控制独立 NSRemoteView/XPC 面板或权限失败时，才转手动。确认“取消”后不得误替换数据。 |
| G3-DATA-07 / req S6 | 对损坏包、改后缀的普通 ZIP、高格式版本归档分别导入；各显示对应原因，不重启，支持目录和窗口保持不变。 | Debug 隔离目录或安装版前置备份后；错误归档为合成文件。 | `-MVDataTransferSelfTest errors` 覆盖三类错误；真实安装版 UI 证据需另行操作。 | 即使归档合成，Release 错误 UI 会访问真实用户数据；优先用隔离 Debug 对 UI 做当前版本检查，避免选中真实归档导入。 |
| G3-DATA-08 / spec C2.9 | 注入导入替换中途失败；重启后显示恢复失败/回滚状态且所有原数据逐文件一致。 | 仅 Debug 隔离目录，自检故障注入。 | `-MVDataTransferSelfTest rollback`/`rollback-verify`。 | 不在安装版真实数据注入失败；检查隔离数据哈希与启动结果。 |

## 关闭判据与已知遗留

1. 每条记录本轮提交 SHA、构建类型、设备、操作路径、看到的画面/状态、结果和原始证据路径；没有执行的场景标“未测/环境阻塞”，不沿用历史通过结论。
2. `G3-SEARCH-01..10` 是 roadmap 中 “NFS 真实图库 S1–S10” 的整理拆项；roadmap 概述了功能条件但没有逐项原文，且当前/现存 worktree 未发现 S3-T3/F3 的 `.spec/requirements.md` 或阶段总结。按路线图和 S3-T3/F3 报告保留这 10 个位置，不把整理拆项说成可恢复的原始逐条编号。
3. 对 Library 原始 S1–S11，冻结路线图逐字保留 S8、S9、S10、S11，另报告补有 C2.1–C2.15 的历史、书签、播放列表、虚拟书动作；早期逐条 S1–S7 原文未找到，以上矩阵使用稳定 `G3-LIB-*` ID 和报告 C2 编号标注，不声称恢复了失落的原 S 编号。
4. 对 FileOps 原始 S1–S12，正式材料明确 S1、S2、S5、S6、S7、S9、S10、S11、S12；S3、S4 的原场景文本未在正式报告/路线图找到。S8 只从报告确认与 Finder 拖出相关，细节按 C2.11 的普通/多选/压缩包承诺路径拆列。rename、clipboard-copy、分类 copy/new-folder、永久删除确认等另外保留为 C2 稳定引用，不把 C2 编号冒充原 S 编号。
5. 搜索/元数据既有遗留：JPEG/TIFF/HEIC 可写；PNG/GIF/WebP/AVIF/视频/压缩包不可评分；大图 NFS 写入约 6–10 秒；全库索引第二步可能很慢。测量或反馈性能，不在验收时擅改门限或把预期限制判作回归。
6. Library 遗留：shutdown 慢锁可超 1 秒；首次网络卷系统授权等待可导致 9 秒超时降级；3000 项切普通书曾一次 0 页而未归因；需在本轮记录是否复现，不能因旧轮未复现而关闭。
7. FileOps 遗留：故障卷 S11 尚未执行；分类面板绘制崩溃历史上未查根因；SMB 文件操作未实测。不得把 NFS 证据扩展成 SMB 结论。
8. 报告建议沿 G5 结构：先列冻结构建与总判定，再分场景列实际环境/操作/结果，独立说明部分完成和阻塞，最后给可执行的手动清单与遗留。对模型自检、CLI、截图的覆盖边界逐项说明。
