# fix: history.sh 下载失败与「无附件」不可区分（#87）

## Goal

`scripts/history.sh` 的 `download_reports` 区分「运行本来就没有报告附件」（正常）与
「有附件但下载失败」（网络抖动，应如实报告），消除误导性报错——此前网络抖动时会把
有附件的体检运行报成「没有任何 check-report 附件」，误导使用者去检查工作流有没有跑过。

## Background

2026-09-14 验证 #83 时真实踩到：`gh run download` 对唯一带 `check-report` 附件的
体检运行下载失败（Artifact 走 Azure Blob 端点，网络间歇性 EOF），现有循环只计数
不报错，最终报出「这 1 次运行里没有任何 check-report 附件」。两种完全不同的情况
被混为一谈，违反项目「无法判定与真实异常不得混淆」的分类原则。

### 本地已验证的事实（gh 2.88.1，2026-09-15）

- 完全无附件的运行：`gh run download` stderr 为 `no valid artifacts found to download`，exit 1
- 有附件但名字不匹配：stderr 为 `no artifact matches any of the names or patterns provided`，exit 1
- 其他 stderr（EOF / SSL / 下载中断）→ 网络 / 传输类可疑失败
- 附件存在性可用 `gh api repos/<owner>/<repo>/actions/runs/<id>/artifacts` 确认
  （`.artifacts[].name`、`.expired` 字段）；**API 请求本身也会遇到 EOF**，重试模式照常适用

## Requirements

1. `download_reports` 对每次下载失败先按 stderr 分类：
   - 命中「无附件」类文案（上述两条）→ 正常跳过，行为与现状一致
   - 其他（网络 / 传输类）→ 用 artifacts API 确认该运行是否真有同名附件：
     - 有 → 计入 `failed_downloads`，`log_warn` 指出可重试
     - 无 → 正常跳过（文案兜底误判时 API 纠正，不误报）
     - 有但 `expired=true` → 附件已过期，如实提示，不算下载失败
2. 汇总行如实报告：成功下载 `got` 次之外，若有 `failed_downloads`，补一行警告
   （如「其中 N 次有附件但下载失败，多为网络原因，可重试」）
3. 报错文案区分（got=0 时）：
   - `failed_downloads > 0` → 报「N 次有附件但下载失败，多为网络原因可重试」
   - `failed_downloads == 0` → 维持现有「没有任何附件」文案
4. 部分失败不毁掉整体：`got > 0` 时无论 `failed_downloads` 多少都继续聚合（现状行为保持）
5. 退出码语义不变（0 / 1 / 2）
6. 新逻辑对 bash 3.2 兼容（禁 `declare -A` / `mapfile`，见 spec/engine/bash-rules.md）

## Acceptance Criteria

- [ ] 「有附件但下载失败」在 got=0 时报错文案明确指向网络原因与重试，不再说「没有任何附件」
- [ ] 混合场景（部分成功 + 部分下载失败）继续聚合，且汇总行如实报告失败次数
- [ ] 「无附件」类失败行为与现状完全一致（静默跳过、汇总不变、got=0 报现有文案）
- [ ] stderr 分类逻辑提取为可单测的纯函数，CI 内联单测覆盖：无附件 / 名字不匹配 / 网络类三类输入
- [ ] `./scripts/lint.sh` 全绿（shellcheck / bash -n / actionlint / yamllint）
- [ ] 全仓 U+FFFD 扫描 OK

## Notes

- 入手位置：`scripts/history.sh` 的 `download_reports`（228 行起）+ `main()` 汇总路径；
  CI 单测参考 `.github/workflows/ci.yml` 既有「提取生产函数 + mock」模式（test-verify / test-notify 步骤）
- 修复类 CHANGELOG 条目写清「此前错在哪、有什么后果」
- 报错原文保留英文文案用于匹配（排错文档保留报错原文的项目惯例），提示语用中文
