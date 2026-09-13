# 修复 history.sh 下载模式取数窗口（--check 取不到检查报告）

## Goal

`--check`（及同步趋势）的下载模式取数窗口不按工作流过滤——`gh run list --limit 20`
取的是**所有工作流**的运行，而体检 / 同步工作流都是低频手动触发，窗口几乎总被
CI / Scorecard / Welcome 挤占。实跑验证（2026-09-14，v1.9.0 发布当天）：
最近 20 次运行 0 次带 check-report；最近 60 次运行里同步与体检工作流共 0 次。
`--check` 下载模式当前完全不可用。

对应 GitHub Issue：[#83](https://github.com/nicholyx/action-sync-images/issues/83)；
里程碑 v1.10.0（趋势可用性）。

## 确认的事实

- `download_reports`（scripts/history.sh:188-216）：
  `gh run list --limit "$LIMIT" --json databaseId`（无 `--workflow`）→ 逐 run
  `gh run download -n <REPORT_NAME>`，失败只计数
- `gh run list --workflow <名>` 按 workflow **name**（工作流顶部的 `name:` 字段）
  过滤：体检 = `Check-Registry`；同步有多个（Sync-Images-to-Aliyuncs 等）
  ——所以默认值只对 `--check` 设 `Check-Registry`，同步模式不设默认（多个名字
  没有唯一合理默认），但支持显式传
- `--check` 下文案「本次运行列表中有 N 次带同步报告」不准确（应为「检查报告」）
- `docs/TROUBLESHOOTING.md:216`：「本项目目前**不支持为源仓库配置独立凭证**——
  欢迎提 Issue 讨论」已陈旧：`--src-credentials` / `SYNC_SRC_CREDENTIALS`
  v1.5.0 已实现，docs/USAGE.md「方式二：按仓库映射」有完整说明
- 用户授权全自动执行（2026-09-14 离开前确认，规划批准包含在内）

## Requirements

1. `history.sh` 新增 `--workflow <名>`：透传给 `gh run list --workflow`；
   `--check` 模式下默认 `Check-Registry`（显式 `--workflow` 以用户为准）；
   同步模式默认空（行为不变）
2. `--check` 下进度文案改「带检查报告」；两种模式的 die 文案分别提示
   「确认对应工作流是否跑过 / 换 --workflow / 用 --dir」
3. 顺带修正 TROUBLESHOOTING.md 的源凭证陈旧段落：改为指向 docs/USAGE.md 的
   现有方案（单值凭证与按仓库映射两种方式），保留报错场景的排查上下文
4. usage 文本补 `--workflow` 说明

## Acceptance Criteria

- [ ] `./scripts/history.sh --check audit`（下载模式）在体检工作流至少跑过一次后
      能取到报告并聚合（云端端到端验证：合并本修复前先手动触发一次
      `Check-Registry`（mode=audit），修复分支本地跑通）
- [ ] `--workflow` 参数生效：`gh run list` 请求按工作流过滤（本地实跑
      `--check audit --workflow Check-Registry` 与 `--limit` 组合）
- [ ] 同步模式不带 `--workflow` 时行为与现状一致（回归）
- [ ] `--check` 文案「带检查报告」；`--check audit` 无报告时 die 文案含
      「Check-Registry」「体检工作流」提示
- [ ] TROUBLESHOOTING.md 不再出现「不支持为源仓库配置独立凭证」，
      改为引用 docs/USAGE.md 的两种凭证方式
- [ ] 全仓 U+FFFD 扫描通过；`./scripts/lint.sh` 全绿
- [ ] CHANGELOG `[Unreleased]` 记入（修复类写清「此前错在哪、有什么后果」，
      锚点行号断言在 `[Unreleased]` 段内）

## Out of Scope

- `--report-dir` 落盘与 History-Trend 工作流（[[../09-14-history-report]]，本轮第二个任务）
- 给任何工作流加自动触发器（红线）
- 同步模式的默认 workflow 过滤（多个同步工作流没有唯一合理默认）

## Notes

- bash 3.2 硬规则全适用（.trellis/spec/engine/bash-rules.md）
- 云端端到端验证依赖真实体检运行：本任务合并前由维护会话手动触发
  Check-Registry（mode=audit，显式触发合规，只读检查）
