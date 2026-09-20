# dry-run 的报告被当成真实运行，污染历史趋势与连续失败计数

## Goal

让 dry-run 产出的报告不再被历史聚合当成一次真实运行——它描述的是**计划**，不是**已发生的事**。消费方跳过它，并告知跳过了几份。

## Background

### 现状（2026-09-20 本地复现）

dry-run 的报告里每条镜像都是 `status: success`（`.github` 那侧 `sync_via_skopeo` 直接 `return 0`），而 `history.sh` 读报告时**不区分它是不是干跑**：

```bash
./scripts/sync.sh --src 'nginx:1.27,redis:7.2' --dest r.example.com/x \
  --dry-run --report-dir /tmp/dryhist/run1
./scripts/history.sh --dir /tmp/dryhist
# 共 **1** 次运行，覆盖 `2026-09-20T14:59:36Z` ~ …
# 累计同步 **2** 个镜像次：成功 2 ｜ 跳过 0 ｜ 失败 0
```

**一次根本没搬过任何东西的干跑，被记成「成功同步了 2 个镜像次」。**

### 为什么这是真问题

**场景是现成的**：三个同步工作流都暴露了 `dry_run` 输入（`README` 的参数表里就有）。使用者勾选它跑一次，那次运行照样上传 `sync-report-*` artifact；之后任何一次用 `history.sh` 看趋势（或跑 `History-Trend` 工作流），都会把它算进去。

**危害有两层**：

| 层 | 后果 |
| --- | --- |
| 趋势数字 | 「累计同步 N 个镜像次」「成功 N」虚高，而那 N 次里有一部分从没发生过 |
| **连续失败计数** | `count_consecutive_failures` 从最新往回数、**遇到任何非 failed 记录即清零**。一次 dry-run 的 `success` 会把一个真实存在了 4 次的失败序列**清零**，于是 `--notify-after-failures 3` 本该发出的告警被静默压掉 |

第二层与 v1.15.1 修掉的「坏报告让计数偏小」是**同类后果**（都是把该响的告警压掉），但成因完全不同：那次是解析失败被静默丢弃，这次是**数据本身被误读**。

### 两条消费路径都要改

| 消费方 | 读法 |
| --- | --- |
| `scripts/history.sh` | 4 处聚合：`aggregate_by_image`（趋势表）、`sync_trend_counts`（累计计数）、`slowest_trend_rows`（耗时排行）、退出码判断 |
| `scripts/sync.sh` 的 `fetch_sync_history` | 为「连续失败 N 次才通知」提取历史记录，供 `count_consecutive_failures` 使用 |

## Requirements

- **R1** `sync-report.json` 顶层新增 `dry_run` 字段（boolean）
- **R2** `history.sh` 的四处聚合**跳过** `dry_run == true` 的报告
- **R3** `sync.sh` 的 `fetch_sync_history` 同样跳过（否则连续失败计数仍会被清零）
- **R4** 跳过必须**可见**：告知跳过了几份，并说明原因（它们描述的是计划，不是已发生的同步）——与 v1.15.1 处理坏报告的口径一致
- **R5** **向后兼容**：没有该字段的旧报告视为真实运行（`dry_run != true`），不能因为升级而让历史数据失效
- **R6** 非 dry-run 的报告行为**完全不变**
- **R7** 退出码语义不变
- **R8** 不新增命令行参数
- **R9** dry-run 报告**照常落盘**——它是「计划」，有独立价值（给人看）；本任务只改「历史聚合要不要算它」

## Acceptance Criteria

- [ ] dry-run 的报告不再进入趋势：`--dir` 下只有 dry-run 报告时，累计为 0 并**明确告知**
- [ ] 混放（真实 + dry-run）时，只有真实的被聚合，且告知跳过了几份
- [ ] `fetch_sync_history` 提取的历史里不含 dry-run 记录（连续失败计数不被它清零）
- [ ] 旧报告（无 `dry_run` 字段）仍被正常聚合（兼容性回归）
- [ ] 非 dry-run 报告聚合结果与改动前**逐字一致**
- [ ] 退出码语义不变（含 `--check` 三条路径）
- [ ] 既有断言（`history.sh` 能从报告中聚合趋势）**改后仍覆盖原目的**——它现在拿 dry-run 报告当夹具，需改为手写 fixture（与 `--check` 那些测试同法）
- [ ] CI 有对应断言；断言先在本地复现过（红 → 绿）
- [ ] macOS 自带 bash 3.2 下正常
- [ ] `./scripts/lint.sh` 全绿；全仓无 U+FFFD 与控制字符

## Out of Scope

- **不改 dry-run 报告的其他字段**（`status` 仍是 `success`）——改 status 会波及全部消费方与多条既有断言，而「加一个可区分的标记」已经足够回答问题（「这份报告是不是干跑」）
- **不阻止 dry-run 报告落盘**（见 R9）
- **不改 `--check` / `--audit*` 的检查报告**——它们没有 dry-run 语义（`--dry-run` 在那些模式下本就按既有语义忽略）
- **不处理 `sync.sh` 的「总耗时」在 dry-run 下未归零**——它是进程计时、不进报告，v1.16.0 已明确为刻意例外
