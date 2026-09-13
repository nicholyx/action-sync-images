# 审计趋势：把 history.sh 聚合能力扩展到检查报告

## Goal

给 `history.sh` 增加 `--check` 查询模式：把历次**检查报告**（v1.8.0 起 `--audit` /
`--audit-lock` 经 `--report-dir` 落盘的 JSON）摊在一起看趋势，回答
「哪个镜像一直落后 / 一直缺失」「哪个锁条目一直在漂移」。
不引入新的存储——数据源就是已经在落的报告与 Artifact。

背景：Roadmap（Issue #4）「计划中」的既定候选方向；Issue #72 的明确非目标
（「本 Issue 不改 history.sh——审计趋势是自然的下一步，但依赖本 Issue 先产出数据」）。

## 已定决策（2026-09-13 与用户确认）

1. **范围 = `audit` + `lock-audit` 两种检查**。`check-updates` 不做趋势：
   其记录是「一个仓库一堆未收录 tag」，趋势口径是未收录集合的增减，
   价值最弱（未收录建议本来就要人判断，连续出现只说明「还没处理」）。
2. **lock-audit 的云端数据源**：给体检工作流加 `lock` 模式——已拆为独立任务
   [[../09-13-check-workflow-lock]]。本任务与它**无实现依赖**
   （趋势用 `--dir` 本地报告即可开发验证；云端路径等 lock 模式合入后自然接通）。
   发布叙事上 lock 模式先合。
3. **接口 = 扩展 history.sh**（加 `--check` 参数），不建新脚本：
   下载、收集、「最近一次按记录内时间」的机制全部复用。
4. **退出码**：趋势的 2 = 存在**确定异常**的历史记录（audit: stale/missing；
   lock-audit: drift）。unknown 不触发——趋势窗口里的 unknown 多为网络抖动或
   匿名访问（查不成 ≠ 落后/漂移），绑上它会让退出码失去「需要处理」的含义；
   unknown 在表格中独立可见，不与异常混淆（检查模式的分类命根子）。

## 确认的事实（来自代码与 Issue）

### 数据源

- 检查报告 JSON 顶层：`{generated_at, check, summary, records}`
  （`write_check_report_files`，scripts/sync.sh:2858）
- `audit`：records = `{source, dest, state, note}`，state ∈
  `current / stale / missing / unknown / excluded`（scripts/sync.sh:1852-1892）
- `lock-audit`：records = `{entry, state, note}`，state ∈
  `match / drift / unknown / nodigest / marker`（scripts/sync.sh:2337-2466）；
  `marker` = 锁文件标注行不参与校验，`nodigest` = 未锁 digest 无法校验
- Artifact：体检工作流上传 `check-report`（保留 30 天，if-no-files-found: ignore）；
  一次体检只跑一种模式，但本地 `--dir` 目录可能混放多种报告与同步报告
- 同步报告 `images[]` 同样含 `dest` 字段（scripts/sync.sh:3126），但现有
  `aggregate_by_image` 只按 `.source` 分组（既有取舍）；audit 的状态绑定
  （source, dest) 二元组，趋势分组不能照搬
- `history.sh` 现状（387 行）：下载/收集/`max_by(.at)` 取最近一次/退出码 0-1-2；
  聚合全在 jq；bash 3.2 兼容规则全适用（禁 declare -A / mapfile，空数组先判长度）

### 项目设计判断（必须延续）

- 不引入新的存储；历史趋势读报告 Artifact
- 被排除/筛掉的东西必须可见（excluded 不进趋势表，但要有统计可见）
- 无法判定与真实异常不得混淆
- CLI 断言不匹配裸状态词（表头永远含状态词）——匹配图标行或数值

## Requirements

1. `--check <audit|lock-audit>`：切换数据源与聚合口径；
   传入后 Artifact 名默认改为 `check-report`（显式 `--report-name` 仍以用户为准）；
   其余值报参数错误退出 1（`check-updates` 明确不支持，报错信息说明口径原因）
2. 数据识别按 JSON 顶层 `.check` 字段过滤——`--dir` 下混放的同步报告、
   check-updates 报告不误读；一份都不匹配时报错退出 1
3. audit 趋势表：分组键 `source + dest`（状态绑定目标，多目标不能合并）；
   列 = 源镜像 | 目标 | 最新 | 落后 | 缺失 | 无法判定 | 最近一次；
   按「落后 + 缺失」降序；`excluded` 记录不进表，表后统计行说明数量与原因
4. lock-audit 趋势表：分组键 `entry`；列 = 条目 | 一致 | 漂移 | 无法判定 | 最近一次；
   按「漂移」降序；`nodigest` / `marker` 不进表，表后统计行可见
5. 总览段：报告份数、覆盖时间范围、各状态累计（与同步趋势的总览同构）
6. `--image` 过滤在 `--check` 模式下匹配对应分组键（audit: source；lock-audit: entry）
7. 退出码 2 按决策 4；0 = 无确定异常历史（含窗口内全部一致）；1 = 参数/环境错误
8. 输出走 stdout 的 Markdown 表格、日志走 stderr（与 history.sh 现有约定一致）
9. 文档：docs/USAGE.md 的 history.sh 用法与体检场景补趋势说明；README 功能一句话；
   CHANGELOG `[Unreleased]` 记入（锚点校验在正确段落）

## Acceptance Criteria

- [ ] 伪造 N 份 audit 报告 fixture，`--check audit --dir` 输出的表格行、计数、
      排序正确；多 dest 同 source 分成两行；excluded 只出现在统计行
- [ ] 伪造 N 份 lock-audit 报告 fixture，`--check lock-audit --dir` 的漂移计数、
      nodigest/marker 统计行正确
- [ ] 窗口内存在 stale → 退出码 2；全 current → 0；lock-audit 存在 drift → 2，
      全 match → 0；unknown 存在但不触发 2
- [ ] `--check check-updates` → 参数错误退出 1；`--dir` 下无匹配报告 → 退出 1
- [ ] `--dir` 混放 sync-report / check-updates 报告时过滤生效，不误读
- [ ] `--image` 单条过滤正确；找不到时给出与现有同款的「写完整名字」提示
- [ ] 在 macOS 自带 bash 3.2 下跑通（空数组判长度等硬规则逐条自查）
- [ ] CI 内联断言（fixture 驱动）；断言匹配图标行或具体数值，不匹配裸状态词
- [ ] `./scripts/lint.sh` 全绿；全仓 U+FFFD 扫描通过
- [ ] docs/USAGE.md、README、CHANGELOG 更新到位

## Out of Scope

- `check-updates` 趋势（口径无趋势价值，决策 1）
- 体检工作流的 lock 模式（[[../09-13-check-workflow-lock]]）
- 不给任何工作流加自动触发器（红线）
- 不改检查报告落盘格式、不新增存储、不做跨 30 天保留期的长期归档

## Notes

- 与 [[../09-13-check-workflow-lock]] 的顺序：无实现依赖，发布叙事上 lock 模式先合
- 本任务是复杂任务：design.md + implement.md 见同目录
