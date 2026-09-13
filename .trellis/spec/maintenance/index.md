# 维护闭环：Issue / PR / 发布

GitHub 侧的迭代流程。本仓库按真实开源项目的方式维护：小批量提交、PR 驱动、
CI 门禁、Issue 追踪、里程碑与版本发布。

## Pre-Development Checklist

1. 本页全部条目
2. 仓库现状盘点：`gh issue list --state open`、里程碑、`gh run list --branch main --workflow=ci.yml --limit 3`、`git status`

## 迭代闭环

**规划 → 实现 → 发布 → 继续规划**，每轮围绕一个主题（如 v1.8.0 = 锁文件闭环与本地体验）。

1. **规划**：建里程碑（`gh api repos/.../milestones -f title=vX.Y.Z ...`）→ 每个 feature 一个 Issue（结构固定：背景 / 期望带验收标准 checkbox / 入手位置 / 难度，标注是否适合首次贡献）→ Issue 入看板（项目编号 1，owner @me）→ 更新 Roadmap Issue #4（路线图的**单一事实来源**）
2. **实现**：一个 Issue 对应一个分支一个 PR（`feat/*` `fix/*` `docs/*` `chore/*`）。动手前先核实 Issue 的前提——曾有 Issue 断言「重试没有退避」，核实后发现前提不成立，改写范围而不是硬着头皮实现错误的目标
3. **CI 与合并**：`gh pr checks <N>` 全绿才 `gh pr merge <N> --squash --delete-branch`。squash 后 PR 标题即提交信息，标题也要符合规范
4. **发布**：从 main 切 `chore/release-vX.Y.Z` → CHANGELOG 归档（见下）→ 发布 PR → 合并后 `git ls-remote --tags` 确认不存在再 `git tag -a && git push`（幂等，网络抖动重推不会双发）→ `release.yml` 产出三段式说明（CHANGELOG 手写段 + 原生 PR 清单 + 可选 AI 摘要）

## 提交信息

Conventional Commits（CI 用 `scripts/check-commit-msg.sh` 校验提交与 PR 标题）。正文写**为什么**，不只是改了什么。

## PR 正文

结构：为什么 → 做了什么 → 关键取舍（含被否掉的方案）→ 测试策略。
**正文写进临时文件再用 `--body-file <路径>`**——嵌套 heredoc 会让 `--body-file -`
拿到空 stdin，正文静默丢失、`Closes #N` 一起失效（症状：PR 合并了、issue 还开着；
v1.7.0 真实踩过两次）。合并后核对 issue 是否自动关闭。

## CHANGELOG（Keep a Changelog）

- 每个用户可感知的改动记入 `[Unreleased]`，分类固定：新增/变更/弃用/移除/修复/安全，不自创
- 修复类条目写清「此前错在哪、有什么后果」
- **插入锚点必须校验段落归属**：`lines.index('### 新增')` 找全文件第一个——版本刚发布后
  `[Unreleased]` 是空壳，第一个「### 新增」在**上一个已发布段**下，条目会错插（v1.8.0
  真实踩过，连续三个 PR 的条目进错段落）。插入前断言锚点位于 `[Unreleased]` 与下一个
  `## [` 之间
- **已发布段是只读的**：Release 说明在打 tag 时已固化，改文件只会让两者不一致。
  发现错插时，`git show vX.Y.Z:CHANGELOG.md` 是唯一事实来源，条目按行取出搬进新段，不要重打

## 网络与重试

- `gh` / `git push` 失败就重试（间隔递增）。重试前**先读报错原文**——「must first push the current branch to a remote」是分支不在 origin，重试 20 次也不会好；加 `--head <owner>:<branch>` 一次就过
- HTTPS 对 github.com 不稳定时先试 SSH：`ssh -T git@github.com` 十几秒可验证；用临时 remote 兜底（`git remote add ssh-origin ...`，用完删除），不动使用者的 `origin` 配置

## 文档同步

改了行为不改文档等于没有改。参数变化 → `--help` + `docs/USAGE.md`（场景编号顺延）+
两个 README 参数表；新机制的设计取舍 → `docs/ARCHITECTURE.md`（写「为什么」与被否掉的方案）；
新报错 → `docs/TROUBLESHOOTING.md`（保留报错原文，写明什么情况下不该用这个方案）。
