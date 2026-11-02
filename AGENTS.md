# MacView 工作约定

MacView 是对标 NeeView 的 macOS 原生图片浏览器（Swift 6 + AppKit）。本文件是在本仓库工作的约定，Claude 与 Codex 共用。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/plans/requirements.md](docs/plans/requirements.md) | 需求、分层范围、验收标准 |
| [docs/architecture.md](docs/architecture.md) | 架构、模块、Core 协议契约、关口 |
| [docs/plans/roadmap.md](docs/plans/roadmap.md) | 阶段、任务与进度 |
| `docs/plans/tasks/<ID>.md` | 任务文档：目标、范围、不做、参考、验收、交付 |
| `docs/reports/<ID>.md`、`docs/reports/bench/` | 任务报告与基准数据（任务文档要求时才写） |

开始或恢复任务前，先读需求、架构、roadmap 和对应的任务文档。

## 分工

- 2026-11-01 起恢复 Codex，按规格目录分阶段执行：
  - T 任务由 Codex 的阶段主控执行，工作范围是规格目录里的 `stage-<n>.md`。
  - Claude 是设计侧主控：写阶段详细设计、审核阶段总结，负责 F 任务的设计；F 任务的执行方按额度另定。
  - 当前需求 s1-core 的规格目录是 `.worktree/s1-core/.spec/`（不入库），需求 worktree 为 `.worktree/s1-core`，分支 `feat/s1-core`。
- 任务 ID 中，T 表示 Core 任务（`Packages/`、`Fixtures/`、mvbench、脚本），F 表示 App 任务（`App/`）。
- 修改公开接口时，同步更新 architecture.md §4。

## 任务流程

1. 读文档（见上）。
2. 选工作区：
   - 顺序开发时，直接在 main 上进行。
   - 与其他会话并行时，在 `.worktree/<ID>` 建分支 `task/<ID>`。
   - 按规格目录执行时，在需求 worktree 中进行，按阶段合入 main。
3. 实现，补齐测试与基准。大任务按可验证的步骤分次提交。
4. 任务文档要求写报告时，写 `docs/reports/<ID>.md`，内容包括：
   - 做了什么。
   - 证据：命令与结果、基准 JSON 的路径。
   - 新增依赖及其许可证。
   - 与任务文档的偏差。
   - 未决问题。
5. 运行 `make test` 和任务文档里的验收项，全部通过。
6. 更新 roadmap 中本任务的状态，然后提交。使用 worktree 时，按以下步骤合入：
   1. 确认主工作树干净。如果有不属于本任务的未提交改动，停止并说明。
   2. rebase 到最新的 main，用 `git merge --ff-only` 合入。
   3. 删除 worktree 和分支。
7. 阶段结束时，在关口（architecture.md §5）向用户汇报结论与证据。

并行的任务不能同时修改同一个模块。

## 构建与测试

| 命令 | 作用 |
|---|---|
| `make project` | 用 XcodeGen 从 `project.yml` 生成 `MacView.xcodeproj`（不入库） |
| `make build`、`make run` | 构建、运行 App；`build` 每次先重新生成工程 |
| `make test` | 运行全部测试；`Fixtures/local/generated` 缺失时先生成，已存在时不重新生成 |
| `make bench ARGS="…"` | 以 release 构建运行 mvbench，`ARGS` 原样传入，例如 `ARGS="env --path /Volumes/Picture"` |

- Swift 6 语言模式，完整并发检查，零警告。
- 单元测试用 Swift Testing。
- 性能数据来自 mvbench 与 signpost；界面性能用 `xctrace`（Animation Hitches）采集。

## 依赖

- 按需引入成熟的依赖，记录名称、版本与许可证。
- 项目使用 MIT 许可：不引入 GPL/AGPL，LGPL 只能动态链接。
- SQLite 统一用 GRDB.swift。

## NAS 与数据

- NAS fn（192.168.31.201）上的用户文件默认只读。写入只限于任务文档明确授权的测试目录，测完清理。
- 不修改 NAS 配置、系统网络配置和现有挂载。
- 凭据不写入仓库、日志、报告或对话。
- 不提交用户的图片；NAS 样本的本地副本放在 `Fixtures/local/`（不入库）。

## 提交

- 只包含当前任务的改动；不覆盖、回退或提交别人的改动。
- 格式为 `<type>(<scope>): <中文描述>`。scope 可以省略，type 取 feat/fix/perf/test/docs/build/refactor/chore。
- 文档、报告和提交信息用简体中文。
