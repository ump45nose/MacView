# G3 自动化执行明细

2026-11-26，MacPro，冻结提交 `23538a3bc1d59015bdf29ac78811f1a38b3cafee`。首轮 32 组前台自检，28 组通过、4 组失败。4 个失败全部来自文件操作。完整命令、首轮和重测各自的退出码、断言、前台 PID 采样、签名和日志指纹见 [automation-summary.json](automation-summary.json)。

| 检查 | 结果 | 实测 |
|---|---|---|
| Debug / Release 构建 | PASS | 干净的本地克隆，不含主树未跟踪资源。两种配置均退出 0，0 编译告警，严格签名验证通过，内嵌 SHA 与冻结值一致。Debug CDHash 为 `5ba3c74c466472272081a78368210caa635acc7c`，Release 为 `9f2e3b8dd81369cd3e90331da790411fbddc5fb3`。两种配置的 mvbench、mvio-helper 都实际生成，指纹见 JSON。 |
| 全量 Core | PASS，3 项受真实挂载条件限制 | 不过滤。Swift Testing 19 个目标共 547 项，报告 546 通过、0 失败、1 跳过。另有 2 项 NFS 用例因没有挂载直接返回。剔除两项后为 544。真实 Finder 排序、重生成入库夹具、实际 CLI 建 3000 项均通过。读取 3000 项 52.51 ms、移动 100 项 43.28 ms，属 Debug 实测。 |
| 英文文案 | PASS | 157 个冻结源文件，299 次文案出现，288 个唯一键，缺失 0。 |
| 资料库 | PASS，内含 SKIP | 四组合各 94 个 PASS，实际退出 0。每组另列 4 行 SKIP，分别是跨重启保持、点击「连接」调系统对话框、3000 项流畅度、拖到标签悬停切换。 |
| 文件操作 | FAIL | 中文浅、深各 87 PASS／1 FAIL。英文浅首轮提前结束，25 PASS／8 FAIL；英文深首轮 75 PASS／13 FAIL。4 组实际退出分别等于相应的失败数。 |
| 搜索、评分与标签、信息面板 | PASS | 四组合各 30 PASS，实际退出 0。此处运行于本地合成夹具。 |
| 数据导出导入 | PASS | 各组合分别执行 dialogs、export、fresh、errors、rollback，以及它们真正重启的 dialogs-restarted、import-verify、revert-verify、fresh-verify、rollback-verify。每组合 5 条链、10 个进程、33 条通过，均有对应的进程退出 0、终端标记及前台采样。使用回环 Basic Auth WebDAV、本地合成图片，四个导出文件的权限均为 0600。 |
| 网络自检 | SKIP | 文件操作 net-kill / net-verify、Core 两卷改名、NFS 大 JPEG 评分与 300 JPEG 索引未取得真实 NFS 证据。开测时 nfs、fileops-a、fileops-b 都落在本地 APFS，未创建同名假卷或变更原挂载。 |

文件操作的两种英文外观各用新的支持目录复测，均为 76 PASS／12 FAIL，实际退出 12。核对冻结源码，11 个英文断言匹配中文菜单或原文，例如实际返回英文恢复提示、Undo / Redo 前缀和英文重名错误。其中“移动…”是自检直接传给文件操作的中文标题。第 12 个是所有语言共有的 C2.16，要求「文件」是最后一个设置页，而冻结版实际把「文件」排在 10 页中的第 5 页。因此这些失败要按断言逐条解释，不能推断为用户在英文界面无法撤销或重命名。

首轮另保留两处未稳定复现的现象。英文浅色永久删除确认框取消及确认超时，后续重命名表单未出现，尽管自检前台采样为 180/180。英文深色新建分类子目录并移入后，列表里未出现该目录。相同构建、相同语言与外观重新完整运行，对应步骤通过。中文深色 rollback 首跳的外部采样仅 1/65 在前台，复测为 11/14、后续验证 23/25，仍实际退出 0。首轮和复测均保留。

Core 开测前先读模块边界、S3 路线图、需求及阶段报告。在测试进程内实测 Foundation 忽略单设的 TMPDIR，采用仅影响本轮进程的临时目录查询重定向并复核 home 和临时目录，实际 Swift Testing helper 命中了重定向。GUI 每个入口和组合使用独立的支持目录、缓存和布局，重启链继承同一组。启动用了 LaunchServices，进程退出码独立通过 kqueue 取得；32 条首轮启动命令本身均返回 0，包括 4 条实际失败的文件操作。可代操作的 Peekaboo Bridge 已有录屏、辅助功能及输入合成权限。

本阶段未运行安装版，未替换应用，亦未进入真实支持目录。构建保留在 `.g3-work/execution/dd/Build/Products/{Debug,Release}/MacView.app`，CLI 在 `.g3-work/execution/src/Packages/MacViewKit/.build/{debug,release}/{mvbench,mvio-helper}`。工作区私有临时目录留给真实动作接续与最终统一清理，报告目录没有归档、图片、原始用户数据或凭据。
