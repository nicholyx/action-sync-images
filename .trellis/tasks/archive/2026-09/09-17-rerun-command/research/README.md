# Research 索引：失败后的可操作化（重跑命令）

- **Task**: `.trellis/tasks/09-17-rerun-command`
- **Date**: 2026-09-17
- **范围**: 只读调研，未修改任何代码/配置

## 文件

| 文件 | 覆盖问题 | 内容 |
|---|---|---|
| `failure-collection-and-reports.md` | A1–A3 | 失败汇总函数、结果文件/并行数组结构、`--report-dir` 的 md/json 真实字段 |
| `check-modes-and-step-summary.md` | B4–B5、C6–C7 | 五处 Step Summary 写入点与结构、三种检查的状态值域与报告 schema、检查模式的「重跑」语义 |
| `rerun-capabilities-and-filter-semantics.md` | D8–D10 | 手工重跑的缺口、`--filter`/`--exclude`/`--file` 确切语义、dry-run 参数数组组装点、`history.sh` 重试模式 |
| `workflow-layer-parameters.md` | E11–E12 | 四个工作流的实际传参、Summary 归属、CLI 与工作流参数一致性 |

## 结论：重跑命令可以复用哪些现成能力

1. **失败集本身是良构的**：`sync-report.json` 的 `images[] | select(.status=="failed")` 直接给出失败集，且 `source` / `dest` / `status` 逐条完整（`scripts/sync.sh:3241-3250`）。序号对齐、标记而非删除的规范已落地（`.trellis/spec/engine/bash-rules.md:63`）。
2. **目标地址可重新推导**：`resolve_dest_refs()`（`scripts/sync.sh:620-639`）+ `normalize_ref()` 能对任意源引用复现目标地址，无需解析报告里的 `dest` 串。
3. **`--filter` 的排除模型天然安全**：被排除项以 `excluded` 记录保留、不删除元素（`scripts/sync.sh:1213-1214`、`1811-1815`），所以「自动生成一条只含失败项的 filter」不会让报告顺序错乱。
4. **有现成的遍历骨架可参照**：`print_dry_run_plan` 的「跳排除 → normalize → validate → resolve_dest_refs → 逐目标」（`scripts/sync.sh:1543-1564`）就是「枚举真正会跑的组合」的既有实现。
5. **有先例叙事**：`--audit` 已经给出「去掉 `--audit` 重跑同一条命令即可补齐」（`scripts/sync.sh:2080-2082`，文档 `docs/USAGE.md:636`）；「挑出失败项 → 一轮批量重试」的骨架在 `scripts/history.sh:283-341`（#97）已存在，且注释 `321-326` 已确立「只重试一轮、固定间隔、不参数化」的口径。
6. **检查报告的 schema 已统一**，可照抄：`write_check_report_files()`（`scripts/sync.sh:2970-2991`）产出 `{generated_at, check, summary, records[]}`，md 与 Step Summary 同源。

## 结论：哪些信息目前拿不到

1. **失败原因在 sync 模式不可机器读取**（最硬的缺口）。`R_NOTE` 仅在终端打印（`scripts/sync.sh:3113-3114`）；`sync-report.md` 表格无「说明」列，`sync-report.json` 无 `note` 字段，Step Summary 无说明列，通知也不带。三种检查模式的报告都带 `note`，只有 sync 主模式没有。
2. **原始调用参数没有被记录**：清单路径（`--file`）、`--dest` 的三种形式之区分、`--skip-existing` / `--verify` / `--platforms` / `--concurrency` / `--retries` / `--tls-verify` 均不可从报告得知。json 只有 `dest_registry`、`strip_attestation`、`filter`、`exclude`。
3. **凭证永不可复现**：工作流刻意只走 env（`sync-images-batch.yml:106-111`），报告/日志里必然缺失——重跑命令只能提示使用者自行准备。
4. **`--filter` 只能一条 ERE 且是部分匹配**：重复传参后者覆盖前者（`scripts/sync.sh:424`），挑 N 个失败镜像必须拼 `a|b|c` 并转义元字符；镜像引用里的 `.` 等会带来误命中（`nginx:1.27` 命中 `nginx:1.27-alpine`）。
5. **目标维度的失败不可单独寻址**：`sync-report.json` 的 `images[]` 是扁平行，无 index 字段；一个源对多目标时，行与行只能靠 `dest` 串区分。
6. **工作流目标地址的最终值依赖仓库变量** `vars.ALIYUNCS_REGISTRY`（`sync-images-batch.yml:72` 等），代码库外，重跑命令无法自行还原。
7. **不存在渲染 `sync.sh` 调用字符串的现成函数**（全文件确认）；`sync_via_skopeo` / `sync_via_regctl` 里的 `cmd` / `platform_args` 数组是 skopeo/regctl 的 argv，不能直接变成重跑命令。

## 相关规范

- `.trellis/spec/engine/modes.md` — 四模式语义矩阵、状态值域、报告 schema、`unknown` 与 excluded 两条铁律、模式相关参数的「不生效必须告警」矩阵
- `.trellis/spec/engine/bash-rules.md:59-68` — `FIELD_SEP` 分隔、结果数组按序号对齐「标记而非删除」、dry-run 必须复述真实参数数组
- `.trellis/spec/engine/index.md:14` — 并发模型：子进程 + 带序号结果文件
- `docs/ARCHITECTURE.md:158-159`、`:466`、`:582` — Step Summary / 报告落盘 / Artifact 名契约
- `docs/USAGE.md:471-484`（filter 示例与「被排除仍出现在报告里」）、`:620-636`（audit 与重跑提示）、`:824-913`（history.sh 趋势）
