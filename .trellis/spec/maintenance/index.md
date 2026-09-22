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

## 改动 CI 步骤

- **新增步骤前，先搜一遍这个 job 里已经有什么。** 集成测试 job 已经跑着不少脚手架（本地 registry、带 htpasswd 的私有源、多平台源索引），新用例常常应当**复用**而不是重建。2026-09-23 真实踩到：为 regctl 路径的私有源用例新起了一个 `registry-auth` 容器，而 job 里早已有一个同名同端口（5001）的。两条用例都红，报的是 `Conflict. The container name "/registry-auth" is already in use`——**而它看起来像是新用例自己的问题**
- **容器名与端口是 job 内共享的资源**，不是步骤私有的。动手前先 `grep -n 'registry-auth\|<端口>' .github/workflows/ci.yml`
- **`docker run` 失败是 `exit 125`，不是「测试失败」**。名字冲突、端口占用都先炸在这里，日志里只有 docker 的英文报错；新步骤要么用自己的容器名，要么明确复用，别让下一个人再猜一次
- **复用别人启动的容器，位置就必须排在它之后**。写完用下面这条把步骤顺序打出来核对，比肉眼读 YAML 可靠：

  ```bash
  ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")["jobs"]["integration-test"]["steps"].map { |s| s["name"] }.compact.each_with_index { |n,i| puts "#{i+1}. #{n}" }'
  ```

## 文档同步

改了行为不改文档等于没有改。参数变化 → `--help` + `docs/USAGE.md`（场景编号顺延）+
两个 README 参数表；新机制的设计取舍 → `docs/ARCHITECTURE.md`（写「为什么」与被否掉的方案）；
新报错 → `docs/TROUBLESHOOTING.md`（保留报错原文，写明什么情况下不该用这个方案）。

### 自己补写的那句话最危险——落笔前先核实

修文档时**新写的**「补充说明」「修正」最容易带进不实：它们没经过任何审阅，
而作者往往是从上下文**推断**而非**实测**。2026-09-23 一天之内真实踩到三次，全是补写时凭推断落笔：

| 写在哪 | 写的是 | 实际 | 照抄的后果 |
| --- | --- | --- | --- |
| `TROUBLESHOOTING.md` 的手动绕法 | 把二进制放进 `$HOME/.regclient/bin` | **漏了 `export PATH`**——那个目录默认不在 `PATH` 里 | 照抄仍会触发下载，绕不过去 |
| `CONTRIBUTING.md` 的覆盖范围 | 「覆盖 CI 里**除 `smoke-test` / `integration-test` 之外**的检查」 | 漏了第三个例外 `commit-messages`——「除 A、B 之外」等价于宣称「其余全包」 | 以为提交信息验过了，PR 标题不合规而 CI 红 |
| `MAINTAINER_GUIDE.md` 的排查建议 | 「这几处的两个版本 `lint.sh` 都会打出来」 | **只有 zizmor 会**（退回本机二进制那条路径上） | 照它去比对版本，看三项都没有输出 |

**判据**：这与「恒真的断言比没有断言更糟」是同族——**文档里未经核实的事实断言就是恒真的断言**。
它不会报错，只会让读者按一个并不存在的机制去行动。

**做法**：补写完说明性文字后，把其中每个**可验证的事实断言**（某个目录在不在 `PATH` 里、
某个命令会输出什么、有几个例外）单独拎出来跑一遍或 `grep` 一遍。上面第 2 条只要数一遍
CI 的 job 数（7 个）就能发现，第 3 条只要跑一次 `lint.sh` 看有没有版本输出就能发现。

### 反过来：审计文档与实现是否还一致

上面讲的是「改了行为要同步文档」。反方向的漂移不会自己暴露——**文档说的是旧的，而使用者照抄就会撞上**。定期查一次，两个角度实测有效：

**一、站在第一次使用者的位置走一遍。** 按 README 的快速开始逐步做，每一步停下来问「我现在知道该做什么吗」。默认目标仓库是作者的命名空间、而文档把它写成「可选」——就是这样撞出来的：使用者不是看不懂，而是**根本没有被告知某件事存在**。这类缺口只有走一遍才会浮现，读代码和读文档都发现不了（两边各自都自洽）。

**二、能机械检查的就别靠肉眼。** 下面这些不需要判断力，但肉眼永远看不完：

| 检查什么 | 怎么查 | 实际抓到过 |
| --- | --- | --- |
| 文档里的命令行示例，选项是否还在 | 抽出所有 `./scripts/…` 命令，逐个核对选项（**含短选项**） | `-d` 是 `--dest` 的合法短选项，帮助里有 |
| 文档声明的默认值 vs 工作流 YAML 的 `default:` | 从 YAML 抽 `inputs` 块逐个比对 | 参数速查表漏列 `verify` / `notify_after_failures` |
| 所有 markdown 链接（含跨文件锚点） | 提取 `[text](link)`，按 GitHub 的 slug 规则算标题锚点再比对 | ``错误：`platform ... not found` `` 的 slug 是**两个**连字符，链接写的是一个 |

锚点那条尤其值得自动化。GitHub 的规则是「小写、去标点、空格转连字符」，关键在于**连续的标点会留下连续的空段**（`... ` 去掉标点后仍占位），靠肉眼推演几乎必错。
