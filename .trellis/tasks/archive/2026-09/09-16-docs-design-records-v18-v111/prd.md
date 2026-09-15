# docs: 架构设计记录补到 v1.11 与 README 路线图补齐（#91）

## Goal

延续 #43 / #63 惯例，把 v1.8~v1.11 落地时确立的设计决策写进 `docs/ARCHITECTURE.md`
「关键设计决策」节，README 路线图补齐 v1.9 / v1.10 条目——价值：改设计前先确认
不是把记录过的决定改回去（spec/engine/index.md 明确要求）。

## Requirements

1. ARCHITECTURE「关键设计决策」节补以下小节（550 行附近 v1.7 小节之后、「安全模型」
   之前；每节写清动机 + 被否掉的方案，风格对齐既有小节——一个具体问题、一段论证、
   不空谈）：
   - 为什么锁文件时效审计（`--audit-lock`）查上游 tag 的 digest，而不是比对本地文件
   - 为什么检查报告要落盘（`--report-dir`，与同步报告对齐）
   - 为什么锁文件时效校验要上云（体检工作流 lock 模式）
   - 为什么 `--check` 做趋势聚合、`check-updates` 明确不做趋势
   - 为什么趋势结果落盘 md + json 双份、聚合口径要单一来源
   - v1.11 下载失败分类如何延伸「无法判定与真实异常不得混淆」原则
2. README「路线图」节补 v1.9（`--check` 趋势聚合）/ v1.10（趋势落盘与 History-Trend
   工作流）两个条目；修掉已完成清单与「### 计划中」之间缺失的空行
3. 事实核对：决策描述与代码实际行为一致（引用真实函数 / 参数名），被否方案以
   PR 正文与代码注释为准，不虚构
4. 素材来源：Roadmap Issue #4 各版本小节、PR #85/#86/#88/#89 正文、
   `scripts/history.sh` / `scripts/sync.sh` 代码注释、v1.11 的 Trellis 任务 PRD

## Acceptance Criteria

- [ ] ARCHITECTURE 新增小节 ≥ 6 个，每个都有具体动机与至少一个被否方案（或明确的取舍代价）
- [ ] 引用的参数名 / 函数名 / 工作流名与代码一致（grep 可验证）
- [ ] README 补 2 个条目 + 格式修复
- [ ] 全文 U+FFFD 扫描 OK
- [ ] `./scripts/lint.sh` 全绿（markdown 改动不影响，但惯例要跑）

## Notes

- 轻量任务，PRD-only；不改任何行为代码
- 版本主题句参考 CHANGELOG 已归档段（v1.8「锁文件闭环与本地体验」、v1.9「审计趋势」、
  v1.10「趋势可用性」）
- 素材检索提示：决策理由大量分布在 `scripts/history.sh` 的注释（如 parse_args 末尾
  --check 默认工作流的注释、download_reports 分类注释）与 `scripts/sync.sh` 的
  --report-dir / lock 模式注释里
