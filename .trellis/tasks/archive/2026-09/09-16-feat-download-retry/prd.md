# feat: history.sh 报告下载的网络韧性（批量重试）

## Goal

`download_reports` 对「确认有附件但下载失败」的运行做**一轮批量重试**：瞬时网络抖动
（Artifact 走 Azure Blob 端点，EOF 是最常见失败形态）不再需要重跑整条命令。
这是 v1.11 下载失败分类的自然延伸——分类解决了「如实报告」，本轮解决「可自动挽回」。

## Background

2026-09-15 验证 v1.11 时真实数据：本机对 Azure Blob 端点连续 5 次下载失败
（每次间隔 8s 的整命令重跑也全败），瞬时抖动把「重试一次就好」变成「重跑整条命令，
还要自己记着再来一次」。v1.11 把这类失败如实报了出来（正确），但没有挽回手段。

### 已核实的前提

- `download_reports` 现状没有任何重试逻辑（v1.11 引入的分类 / API 确认之后直接计数）
- `gh` 对 API 请求有内部重试，但对 Artifact 内容下载的 EOF 不足以应对实测抖动
  （本机 5 连败为证）；`confirm_artifact_exists` 的 API 查询同样会抖，但其失败
  走 unknown 分支如实计入，不在本轮范围

## Requirements

1. 主下载循环中，经分类 + API 确认为「有附件但下载失败」（yes）或「无法判定」
   （unknown）的 run id 收集进 `retry_ids`；no-artifact 与 expired 不重试
   （快速失败是正确的）
2. 主循环结束后若 `retry_ids` 非空：`log_info` 提示将重试，逐个再次
   `gh run download`——**批量重试天然形成退避**（主循环还要下载其余运行），
   每个 run 之间固定间隔 5s
3. 重试成功 → `got` 计数（`failed_downloads` 相应不增加）；仍失败 → 计入
   `failed_downloads` 并保留现有 log_warn；重试的结果同样走汇总与 got=0 报错逻辑
4. 重试只做**一轮**：持续抖动不是脚本该解决的（实测 5 连败属于极端网络环境），
   如实报错 + `--dir` 兜底已经足够
5. 不新增命令行参数：重试次数 / 间隔不做参数化——为极少调整的值增加表面积不划算，
   且新参数要进「显式传入不生效告警」矩阵，复杂度不成比例
6. 退出码语义不变（0 / 1 / 2）；bash 3.2 兼容（bash-rules.md 全部硬规则）

## Acceptance Criteria

- [ ] 「有附件但下载失败」的 run 在重试成功后计入 got，汇总行如实（不再有 warn 或
      warn 数与实际一致）
- [ ] no-artifact / expired 的 run 不触发重试（零额外下载尝试）
- [ ] 重试全部失败时行为与 v1.11 一致（failed_downloads + 区分文案）
- [ ] 重试逻辑可单测：CI 内联单测覆盖「重试成功」「重试仍失败」「不重试的类别」
      三类（mock gh，沿用 v1.11 的 test-download step 模式）
- [ ] `./scripts/lint.sh` 全绿；U+FFFD 扫描 OK
- [ ] CHANGELOG [Unreleased] 新增条目（锚点断言在正确段落）

## Notes

- 入手位置：`scripts/history.sh` 的 `download_reports`（主循环 + 汇总之间插入重试块）
- CI 单测：扩展现有「验证报告下载失败的分类判定」step（mock gh 的 download 首败后成
  功模式：用计数器模拟第一次调用失败、第二次成功）
- 真实冒烟：本机网络对 Blob 端点仍不稳，正好可以验证「有附件但下载失败 → 重试」
  的真实路径
