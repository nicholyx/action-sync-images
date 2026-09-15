# Journal - nicholyx (Part 1)

> AI development session journal
> Started: 2026-09-13

---

## Session 1: 历史回填——Trellis 接入前的完整迭代史

**Date**: 2026-09-13
**Task**: （回填，无对应任务目录）
**Branch**: `chore/trellis-init`

### Summary

Trellis 初始化时把项目此前 8 个版本的迭代史与关键教训写入记忆，供后续会话注入。

### Main Changes

项目自 2026-09-11 起按真实开源项目流程维护（PR 驱动、CI 门禁、里程碑、语义化版本），
到 v1.8.0 为止的迭代主线：

- **v1.0.0–v1.2.0 · 地基**：阿里云 ACR / 自建 Harbor 同步、多架构完整保留、attestation
  剔除路径（regctl 重建索引）、批量清单、`--dry-run`、多目标同步、TLS 开关、
  CI 真实推送集成测试（本地 registry:2——dry-run 覆盖不到真实路径，v1.1.0 的三个
  缺陷全部发生在真实推送路径上）
- **v1.3.0 · 私有源**：源仓库凭证（不进命令行，600 权限 authfile）、`--filter`/`--exclude`、
  `history.sh` 历史趋势（复用报告 Artifact）、修复 regctl 静默丢平台（printf 无结尾换行）
- **v1.4.0 · 同步质量**：`--verify` 逐平台完整性校验、耗时排行、`--notify-after-failures`
  告警阈值（从历史报告推算，不引入新存储）
- **v1.5.0 · 效率与多源**：多目标本地 OCI 中转（纯优化，失败透明退化）、按仓库映射凭证
- **v1.6.0 · 只读检查**：`--audit`（目标 vs 清单，四态分类，「无法判定」独立成类）、
  `--check-updates`（上游 vs 清单，只报告不替人做判断）、`--dest-keep-path`（每目标
  各自的命名规则）；供应链加固（Actions pin SHA、zizmor 0 findings、OSSF Scorecard）、
  英文版 README、SUPPORT.md
- **v1.7.0 · 检查上页面**：`Check-Registry` 体检工作流（手动触发，不加 schedule）、
  检查结果通知（`notify_send_text` 一条发送路径）；顺带修复 bash 3.2 空数组 +
  `set -u` 的 unbound variable（配 webhook 的 macOS 同步非零退出）
- **v1.8.0 · 锁文件闭环**：`--audit-lock`（上游 tag 是否还是锁定的那份，tag 已删除算漂移）、
  macOS 无 timeout 时 perl alarm 兜底、三种检查支持 `--report-dir`（md + json 与同步对齐）

### 踩坑沉淀（已固化到 .trellis/spec/）

- bash 3.2 + `set -u` 的空数组展开、命令替换的子 shell 传值、包装函数吞退出码、
  printf 无结尾换行丢段——全部在 spec/engine/bash-rules.md
- 中文文档批量编辑用按行索引、CHANGELOG 插入锚点必须校验段落归属（v1.8.0 时
  连续三个 PR 的条目错插进已发布的 [1.7.0] 段，靠 diff tag 版本发现）
- PR 正文写临时文件（嵌套 heredoc 让 `--body-file -` 拿到空 stdin，Closes 失效两次）
- CI 断言不 grep 状态词本身（汇总行里状态词恒在）
- HTTPS 对 github.com 不稳时用 SSH 临时 remote 兜底；`gh` 只认 origin，分支在别的
  remote 时 `gh pr create` 要加 `--head`

### Testing

- [OK] CI 全绿（v1.8.0 发布于 2026-09-13，tag e20feb9 前身）

### Status

[OK] **Completed**

### Next Steps

- 下一轮候选方向见 Roadmap Issue #4「计划中」：审计趋势（history.sh 扩展到检查报告）、
  观察真实使用者反馈
- 后续开发改用 Trellis 工作流：任务走 `task.py`，规范注入走 trellis-before-dev，
  收尾走 /trellis:finish-work；GitHub 侧闭环（Issue/PR/发布）仍按 spec/maintenance/index.md


## Session 2: fix(history): 下载失败与无附件区分（#87，v1.11.0）
<!-- trellis-session: v=2 fp=e0926641cd87090b -->

**Date**: 2026-09-15
**Task**: fix(history): 下载失败与无附件区分（#87，v1.11.0）
**Branch**: `main`

### Summary

立项 #87 为 v1.11.0：download_reports 按 gh 报错文案分类下载失败，可疑失败用 artifacts API 确认（yes/expired/absent/unknown），汇总与报错文案区分「应下载却失败」与「无附件」，退出码不变。冒烟真实复现 #87 场景验证修复；check 阶段抓到 if 条件里整条管道判退出码的 pipefail 隐含依赖（unknown 会静默落成 absent），改为分段判退出码，教训已沉淀进 spec/engine/bash-rules.md。CI 新增 mock 单测 step（分类 4 类 + 确认 4 态），PR #89 全绿合并，#87 随 Closes 自动关闭。

### Git Commits

| Hash | Message |
|------|---------|
| `5877729` | fix(history): 报告附件下载失败不得误报为「没有任何附件」（#87） (#89) |

### Status

[OK] **Completed**


## Session 3: docs: 架构设计记录补到 v1.11（#91，v1.12.0）
<!-- trellis-session: v=2 fp=7c16bf7ad58db245 -->

**Date**: 2026-09-16
**Task**: docs: 架构设计记录补到 v1.11（#91，v1.12.0）
**Branch**: `main`

### Summary

延续 #43/#63 惯例：ARCHITECTURE「关键设计决策」按版本时序补 6 个小节（audit-lock 查上游不查本地、检查报告落盘、lock 校验上云、--check 做趋势而 check-updates 不做、趋势落盘 md+json 与口径单一来源、下载失败与无附件区分），README 路线图补 v1.9/v1.10 条目并修空行。check 阶段修正一处事实精度：检查报告 md 与 Step Summary 同源（非 stdout），「同源」在两个脚本里指的东西不同。逐节对照代码核过事实，PR #92 全绿合并，#91 关闭。

### Git Commits

| Hash | Message |
|------|---------|
| `4b8de49` | docs(architecture): 设计记录补到 v1.11，README 路线图补齐（#91） |

### Status

[OK] **Completed**
