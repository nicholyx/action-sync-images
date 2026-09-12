---
name: oss-bootstrap
description: 把一个新项目（或只有代码的裸仓库）快速落实为符合主流规范的开源项目——CI、治理文件、Issue/PR 模板、仓库自动化、文档体系、看板与发布流程。当用户说「新建开源项目」「给项目加上 CI / 规范」「按热门开源项目的标准搭基建」时使用。项目已具备这些基建后，日常迭代请改用 maintain-loop skill。
---

# 开源项目 Bootstrap（oss-bootstrap）

把一个裸仓库变成结构完整的开源项目。**参考实现就在本仓库**——action-sync-images 从裸工作流
起步，已经完整走过一遍这条路，本仓库的每个文件都是可直接借鉴的成品。下面以它为参照
（路径均相对本仓库根），把流程沉淀为六个阶段。

## 与 maintain-loop 的关系

- 本 skill：从 0 到 1 搭基建（只做一次，或大改时回来对照）
- `maintain-loop` skill：基建就位后，日常迭代的闭环（规划 → 实现 → 发布）

搭完基建后，一切开发工作都应切换到 maintain-loop 的流程。

## 第零步：先判断，再动手

1. **项目类型与工具链**：语言、构建工具、测试框架——决定 CI 里静态检查与测试的内容。
   常见映射：bash → shellcheck + bash -n；YAML → yamllint；Go → golangci-lint + go test；
   JS/TS → eslint + vitest/jest；Python → ruff + pytest。
2. **仓库现状**：`gh repo view`、已有文件清单、是否 fork（fork 需要先在网页端脱离
   fork network，操作见记忆/文档，API 做不了）、已有 Secrets 与变量。
3. **权限**：`gh auth status` 确认 scopes（repo / workflow）；操作 Projects 看板需要
   `project, read:project` scope，缺失时请用户执行
   `gh auth refresh -s project,read:project`。

**不要一次性问用户一堆问题**。语言与现状自己判断；只有 LICENSE 选择（MIT / Apache-2.0 …）
和「是否已有用户/破坏性变更」这类真正属于用户的决定才需要确认。

**实施节奏**：按阶段推进，每个组件独立分支 + 独立 PR（小批量提交，CI 全绿再合并），
遵循 maintain-loop 的分支与合并规范。

---

## 阶段一：地基 —— CI 与提交规范

这是其他一切的前提：先让「每次改动都被自动检查」跑起来。

1. **CI 工作流**（参考 `.github/workflows/ci.yml`），骨架固定为四层：
   - 静态检查：按语言选工具，固定版本号（可复现）
   - 测试：冒烟（快、无外部依赖）+ 集成（真实路径，能发现 mock 发现不了的问题）
   - 提交信息校验：Conventional Commits，脚本方式实现（参考 `scripts/check-commit-msg.sh`），
     同时校验区间内的提交与 PR 标题（squash 后标题即提交信息）
   - **ci-summary 汇总 job**：`needs: [全部检查]` + `if: always()`，把所有检查汇总成一个
     结果——分支保护规则只需要盯这一个 check，增删检查项不用改保护规则
2. **本地统一入口** `scripts/lint.sh`（参考 `scripts/lint.sh`）：一条命令跑完 CI 的全部
   静态检查。CI 与本地跑的是同一套，避免「本地能过 CI 不过」。
3. **最小权限**：CI 声明 `permissions: contents: read`；需要写权限的工作流在各自文件里
   单独声明。所有 `run:` 块开头 `set -euo pipefail` + `#!/usr/bin/env bash`。

## 阶段二：治理文件与模板

| 文件 | 参考 | 要点 |
| --- | --- | --- |
| `LICENSE` | 根目录 | 用户选型；**纯许可证文本，不加附加段落**（否则 GitHub 无法识别，显示 NOASSERTION） |
| `CONTRIBUTING.md` | 根目录 | 流程、提交规范、本地检查入口 |
| `CODE_OF_CONDUCT.md` | 根目录 | Contributor Covenant 即可 |
| `SECURITY.md` | 根目录 | 漏洞报告渠道 + 威胁模型（本项目把「什么是威胁」写清楚了，值得照做） |
| `SUPPORT.md` | 根目录 | 获取帮助的分流路径：文档 → Discussions Q&A → Bug → 安全报告 |
| `CODEOWNERS` | `.github/` | 关键路径指定 reviewer |
| Issue/PR 模板 | `.github/ISSUE_TEMPLATE/` | YAML forms 而非 markdown；Issue 至少分 bug / feature / docs 三类；config.yml 指向 Discussions 并关闭空白 Issue |
| `.gitignore` | 根目录 | 语言惯例 + 编辑器目录 |
| 多语言 README | `README.md` / `README.en.md` | 顶部互相链接做语言切换；次要语言注明「完整文档以主语言为准」 |

## 阶段三：仓库自动化

参考 `.github/workflows/` 与 `.github/dependabot.yml`：

- **labeler.yml**：按改动路径自动给 PR 打标签（`pull_request_target`，因为它不 checkout
  PR 代码——**任何 checkout PR 代码的场景禁止用 `pull_request_target`**）
- **welcome.yml**：首次贡献者致意（同样 `pull_request_target` 不 checkout 代码）
- **stale.yml**：N 天无响应标 stale，再 M 天自动关闭；给高频使用的标签加 exempt
- **release.yml**：`v*.*.*` tag 触发。发布说明三段式组装——CHANGELOG 手写部分
  （awk 提取版本段）+ GitHub 原生 `releases/generate-notes`（PR 清单与对比链接）+
  可选 AI 摘要（配了 key 才启用，**任何失败都退出 0**，摘要不该成为发布的单点故障）。
  预发布版本（tag 含 `-`）不标 latest；**tag 过滤器末尾要加 `*`**，否则预发布 tag
  根本不触发工作流，预发布逻辑成死代码
- **dependabot.yml**：Actions 生态，每周一次，配 7 天 cooldown（新版本有 bug 或
  tag 被改投恶意代码时，冷却期让它先暴露）

### 供应链加固（对标 OSSF Scorecard——热门项目近两年的标配，缺了 zizmor 会给出一排 high）

| 加固项 | 做法 |
| --- | --- |
| Actions pin 到 commit SHA | `uses: actions/checkout@<40 位 SHA> # v7`——tag 可移动而 SHA 不可；注释保留版本，Dependabot 的 PR 照常更新 SHA。SHA 用 `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha` 查 |
| checkout 不留凭证 | 每个 checkout 加 `persist-credentials: false`——GITHUB_TOKEN 不残留在 runner 上 |
| 工作流安全扫描 | CI 加 **zizmor** job（容器按版本 pin，挂载 `:ro`），基线保持 0 findings；豁免集中在 `.github/zizmor.yml`，**每条豁免必须写明可验证的安全依据**（如 pull_request_target 但不 checkout PR 代码） |
| OSSF Scorecard | 新增 scorecard 工作流（`ossf/scorecard-action`，`publish_results: true` 需要 `id-token: write`），结果发布到公开评分页并上传 code scanning；README 加徽章——供应链安全从「自觉做得好」变成「有公开体检报告」 |
| 最小权限 | 每个工作流显式声明 `permissions`，绝不放任仓库默认（宽）权限 |

注意：给 step **插入** `with:` 块这类结构调整，逐个手工做（批量脚本会算错缩进层级，
详见 maintain-loop 的「修改 YAML 工作流的工具选择」）。

仓库标签体系补齐：在默认标签外建项目标签（如 ci / automation / governance / sync-*），
`gh label create`。

## 阶段四：文档体系

- **README**：面向使用者。结构：这是什么 / 特性 / 快速开始 / 参数速查 / 常见场景
  （`<details>` 折叠）/ 项目结构 / 文档索引 / 路线图（指向 Roadmap Issue）/ 贡献 / 许可证。
  完成后核对两件事：提到的每个参数真实存在、本地链接全部有效（写个十几行的 python
  校验脚本即可，参考 action-sync-images 第 29 号 PR 的做法）
- **docs/ 四件套**：
  - `USAGE.md`：从零跑起来的全部步骤 + 每个参数详解 + 常见场景
  - `ARCHITECTURE.md`：面向想改代码的人，**写「为什么这样设计」并记录被否掉的方案**
  - `TROUBLESHOOTING.md`：现象（保留报错原文）/ 原因 / 解决；写明「什么情况下不该用这个方案」
  - `MAINTAINER_GUIDE.md`：维护者手册 + 项目红线
- **CHANGELOG.md**：Keep a Changelog 格式，`[Unreleased]` 段 + 固定六分类
  （新增/变更/弃用/移除/修复/安全），不自创分类

文档与代码同步演进：改了行为不改文档，等于没有改。

## 阶段五：仓库设置（gh api / gh 命令）

这些不在代码里，要用 API 落实，并且**记录进 MAINTAINER_GUIDE 的「仓库配置清单」**：

```bash
# 分支保护（与本仓库一致的配置）：要求「CI 总览」通过、严格同步最新、
# 过期评审自动清除、禁止 force push 与删除、必须解决所有对话
gh api repos/{owner}/{repo}/branches/main/protection -X PUT --input - <<'JSON'
{ "required_status_checks": {"strict": true, "contexts": ["CI 总览"]},
  "required_pull_request_reviews": {"dismiss_stale_reviews": true, "required_approving_review_count": 0},
  "enforce_admins": false, "restrictions": null,
  "allow_force_pushes": false, "allow_deletions": false,
  "required_conversation_resolution": true }
JSON
```

注意 `contexts` 用的是**检查的显示名**（ci-summary job 的 `name:`），不是 job id；
单人维护的仓库 `required_approving_review_count: 0`——不要求别人审批，但 CI 仍是硬门禁。

- **Projects 看板**：`gh project create -t "名称" -o @me`；Roadmap Issue 建好后加入
- **Roadmap Issue**：路线图的**单一事实来源**，「计划中」每项链接到对应 Issue
- **第一个里程碑**： vX.Y.Z，把 Roadmap 的条目挂上去
- 需要用户手动配置的（Secrets、变量、网页端开关）列一张清单告知，不要默默跳过

## 阶段六：验证与首个发布

1. **全流程演练**：开一个真实的小 PR（哪怕是文档），完整走一遍
   分支 → PR → CI → review → squash merge → Issue 自动关闭。
   基建只有在第一次真实使用时才算真正搭好。
2. **首个 Release**：CHANGELOG 归档 v1.0.0 → 发布 PR → tag 推送 → 验证 release.yml
   产出的三段式发布说明。
3. 交接：向用户汇报搭建清单（建了什么、在哪、还差什么需要手动配置）。

---

## 搭建阶段的踩坑记录（与 maintain-loop 互补）

- **run-name 里的 `#`**：`run-name: 为 PR #${{ ... }}` 中 `#` 前有空格会被 YAML 当注释，
  表达式被吞掉。含 `#` 的行要加引号。yamllint 能发现。
- **shellcheck 版本差异**：本地新版不报的 SC2015，CI 旧版会报。`A && B || C` 不是
  if-then-else，用 `if` 写意图。
- **`set -u` 下空数组**：`"${arr[@]}"` 在部分 bash 版本展开成一个空字符串元素。
  遍历前先判 `${#arr[@]}`。
- **pipefail + `$(cmd) || return 1`**：命令输出了有效内容但退出码非零时，会把成功当失败。
  判断依据应该是「有没有拿到内容」，而不是退出码。
- **注释里出现 shellcheck 指令字样**会被当成真指令，触发莫名的 SC1073。改措辞。
- **yamllint 报 comment not indented like content**：检查注释块的挂靠位置是否合理
  （修饰的是被注释掉的块时属于既有风格，可接受）。
- **`pull_request_target` + checkout PR 代码** = 任意代码以可写 token 运行，绝对禁止。
- 所有用户输入（workflow_dispatch inputs 等）经 `env:` 中转进脚本，`${{ }}` 不直接写进
  `run:`——表达式注入。

## 完成标准

- [ ] CI 覆盖静态检查、测试、提交规范，且有一个汇总 check
- [ ] 分支保护启用，且只依赖汇总 check
- [ ] 治理文件齐全，LICENSE 能被 GitHub 识别
- [ ] labeler / welcome / stale / release / dependabot 全部就位且跑过至少一次
- [ ] 供应链基线达标：所有 `uses:` pin 到 SHA、checkout 全部 `persist-credentials: false`、
      zizmor 0 findings（豁免有据）、Scorecard 工作流就位
- [ ] docs 四件套 + CHANGELOG 就位，README 的参数与链接经过校验
- [ ] 看板、Roadmap Issue、第一个里程碑就位
- [ ] 一个真实 PR 从头到尾走通过，首个 Release 已发布
- [ ] 移交清单已告知用户（需手动配置的 Secrets、网页端开关）

之后的一切迭代，切换到 `maintain-loop` skill。
