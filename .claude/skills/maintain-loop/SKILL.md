---
name: maintain-loop
description: action-sync-images 项目的维护闭环流程——规划、实现、发布、继续规划的完整循环，以及踩坑沉淀的硬规则。当需要在项目中继续迭代（新功能、修缺陷、补文档）、发布新版本、盘点未完成事项，或有人说「继续」「走维护流程」「按开源流程开发」时使用。
---

# 维护闭环（maintain-loop）

本项目（action-sync-images，仓库 `nicholyx/action-sync-images`）按真实开源项目的方式维护：
小批量提交、PR 驱动、CI 门禁、Issue 追踪、里程碑与版本发布。

**核心闭环**：`规划 → 实现 → 发布 → 继续规划`。每一轮迭代围绕一个主题（如 v1.4.0 = 同步质量），
走完一轮再开下一轮。下面是每个阶段的操作规范，以及踩过坑之后沉淀的硬规则——**规则部分优先级最高**。

> 本 skill 假设项目基建（CI、治理文件、自动化、看板）已就位。如果是**新项目**要从零落实

## 与 Trellis 的关系（2026-09-13 起接入）

本项目已初始化 [Trellis](https://github.com/mindfold-ai/Trellis)（`.trellis/` + 平台注入层）。
两者的分工：

- **Trellis 管「知识与任务上下文」**：编码规范在 `.trellis/spec/`（会话自动注入），
  任务 PRD 在 `.trellis/tasks/`（`task.py create/start/finish/archive`），
  会话记忆在 `.trellis/workspace/`（`/trellis:finish-work` 收尾时记录）
- **本 skill 管「GitHub 侧闭环」**：Issue / 里程碑 / 看板 / PR / 发布——Trellis 不覆盖这些

衔接点：

- 动手前读的规范已搬到 spec（`spec/engine/`、`spec/workflows/`、`spec/maintenance/`、
  `spec/guides/`），本 skill 保留的规则是**同一套内容的操作视角**，两边同步维护
- 一个开发任务 = 一个 Trellis task（PRD、上下文清单）+ 一个 GitHub Issue + 一个分支 PR；
  `/trellis:finish-work` 记录会话，Issue 关闭与 CHANGELOG 仍按本 skill 的发布流程走
- 踩坑沉淀的去向：**代码约定** → `trellis-update-spec` 写进 `.trellis/spec/`；
  **流程规则** → 本 skill（两者不重复收藏，交叉引用即可）
> 开源规范，先使用 `oss-bootstrap` skill 完成搭建，再回到这里进入日常迭代。

开始前，若对本项目的设计不熟，先读 `docs/ARCHITECTURE.md` 与 `docs/MAINTAINER_GUIDE.md`。

---

## 一、盘点现状（每轮开始与用户询问「还剩什么没做」时）

```bash
gh issue list --state open --json number,title
gh api repos/nicholyx/action-sync-images/milestones --jq '.[] | "\(.title): 完成 \(.closed_issues) / 待办 \(.open_issues)"'
gh release list
gh run list --branch main --workflow=ci.yml --limit 3
git status --short && git log --oneline -3
```

检查点：本地与远端是否一致、main 的 CI 是否绿、`[Unreleased]` 是否积压了未发布的改动
（积压即说明「发布」这一步欠着，优先补上）。

## 二、规划

1. **建里程碑**：`gh api repos/nicholyx/action-sync-images/milestones -f title="vX.Y.Z" -f state=open -f description="主题"`
2. **建 Issue**，每项一个，结构固定为：
   - **背景**：为什么（引用真实痛点，不写空话）
   - **期望**：做成什么样（带验收标准 checkbox）
   - **入手位置**：涉及哪些文件/函数
   - **难度**：简单 / 中等 / 中偏难，标注「适合首次贡献」
   - `--milestone "vX.Y.Z"`，打上 `enhancement` / `bug` / `documentation` 标签
3. **看板**：Issue 加入 Projects 看板（项目编号 `1`，owner `@me`）：
   `gh project item-add 1 --owner @me --url https://github.com/nicholyx/action-sync-images/issues/N`
4. **更新 Roadmap（Issue #4）**：它是路线图的**单一事实来源**。规划后把新条目写进「计划中」，
   完成后移入「已完成」，已完成条目带上 Issue 链接。README 的路线图段落同步指向 Issue #4。

## 三、实现

- **一个 Issue 对应一个分支、一个 PR**。分支名 `feat/*`、`fix/*`、`docs/*`、`chore/*`。
- **动手前先核实 Issue 的前提**。曾有 Issue 断言「重试没有退避」，核实后发现两条路径本来就有
  指数退避——前提不成立时，在 Issue 里留言说明并改写范围，而不是硬着头皮实现错误的目标。
- 实现中偏离 Issue 计划（如发现了更严重的相关缺陷），先起一个独立 Issue 记录，再决定顺序。

### 设计原则（本项目已确立的判断，新功能必须延续）

- **排除/筛掉的东西必须可见**：被 `--filter`/`--exclude` 排除的镜像仍出现在结果表并标注原因。
  悄悄消失是最危险的——使用者会以为它同步了。
- **参数被接受却不生效必须告警**：静默失效比报错更危险（`--retries` 在 regctl 路径失效的教训）。
  但默认值不生效不值得打扰，只在**显式传入**时告警。
- **不引入新的存储**：历史趋势读报告 Artifact、连续失败次数从历史报告推算。
  需要跨运行状态时先问：已有数据源能不能回答？
- **凭证不进命令行、不进日志**：写进 600 权限临时文件（authfile），脚本退出即删；
  CI 用环境变量传参，因为命令行参数对同机进程可见、也会被日志语句原样打印。
- **退出码语义**：`0` 全部成功（含跳过）、`1` 参数/环境错误、`2` 至少一个镜像失败。
  用户的有意操作（排除）不算失败。

### 测试策略

- **无法端到端构造的场景**（如「目标与源不一致」——校验紧跟同步，同步会覆盖掉不一致；
  「跨运行的连续失败」——需要多次真实失败）：提取生产函数（`sed -n '/^fn()/,/^}/p'`）
  加伪造输入做单测，CI 步骤里内联执行。
- **真实路径**：集成测试 job 用本地 `registry:2` 容器真的推送。dry-run 覆盖不到真实推送路径——
  v1.1.0 的三个缺陷全部发生在那里。
- **每条 CI 断言先在本地复现**再提交，包括 `bash -e` 语义下的行为（GitHub Actions 的 `run:` 默认 errexit）。
- **断言不要匹配状态词本身**。审计类命令的汇总行是「最新 0 ｜ 落后 0 ｜ 缺失 0」，
  几个状态词永远都在里面——直接 `grep -q '缺失'` 等于断言恒真。真实踩过：一条
  「源不可达不得被报成缺失」的关键断言因此红了一次，而它守的正是该功能最要紧的
  分类原则。要么匹配带图标的正文行（`✗ 缺失`），要么断言汇总行的具体数值。
  CI 里没有 TTY，颜色码不会插进图标与状态词之间，这几种模式是稳定的。

### bash 编码硬规则（兼容 macOS 自带 bash 3.2）

- 禁用 `declare -A`、`mapfile`、`wait -n`、`tac`。去重用 `awk '!seen[$0]++'`，倒序用数组下标循环。
- `printf '%s'` **不输出结尾换行**，配 `while IFS= read -r` 会**丢掉最后一段**（read 遇 EOF 返回非零）。
  必须写 `printf '%s\n'`。曾导致 regctl 路径静默丢平台（Issue #27）。
- 结果文件字段分隔用 `$'\x1f'`（Unit Separator）。tab 是 IFS 空白，空字段会让后续字段整体左移。
- 结果数组按序号对齐（下标同时决定结果文件序号），**标记而非删除**。
- bash 内嵌 Markdown 反引号写在 `printf` 的**双引号**格式串里，避免 shellcheck SC2016。
- `--dry-run` 的输出必须复述**真正会执行的参数数组**，不是拿输入重新拼一遍——两者看似一样，
  脱节时 dry-run 就失去了全部意义（丢平台缺陷长期未被发现正是因为它）。
- **空数组的 `"${arr[@]}"` 遍历前必须判长度**。`set -u` 下 bash 3.2（macOS 自带）
  会抛 unbound variable，bash 4.4+ 才改掉这个展开行为——而 CI 用的是 bash 5，
  所以这类缺陷**只在本地暴露**：配了 webhook 的同步在 macOS 上表现为「同步明明
  成功、脚本却以非零退出」。写成 `if [[ ${#arr[@]} -gt 0 ]]; then for x in "${arr[@]}"`。
  `collect_images` 里早有同源注释，仍然漏掉了一处——改完记得全文件搜一遍遍历。

### 退出码与进程模型的硬规则（同一类问题的四个面孔）

bash 里「值」和「状态」跨过进程边界时的流向，必须与进程模型对齐。以下每一条都真实踩过：

- **包装函数不得吞退出码**：`wrapper() { inner; return 0; }` 让 inner 的失败静默消失。
  结尾不写 return，或写 `return $?`。曾让 401 失败的同步被记成成功（CI 的
  「未提供凭证时应失败」断言当场抓到）。
- **命令替换是子 shell**：`var="$(fn)"` 里 fn 对全局变量的赋值传不回父进程，
  `set -u` 下父进程读它会 `unbound variable`。传出多个值用全局变量 + 返回码。
- **并发子进程对数组的修改不传回父进程**——结果收集用带序号的临时文件。
- **`output="$(cmd)"` 的退出码就是 cmd 的退出码**：在 errexit 下 cmd 失败会在
  `echo "$output"` 之前中断整个步骤、吞掉全部输出。可能失败的命令要用
  `set +e` 包裹后再捕获。
- **`find` 的退出码只表示「遍历成功」，与是否匹配无关**（这点和 grep 不同）。
  按「有没有匹配」判断要看输出是否非空。

### 修改 YAML 工作流的工具选择

- **无结构的简单替换**（如把 `@v7` 换成 `@<sha>`）→ 脚本批量安全。
- **涉及缩进/块结构的插入**（如给 step 加 `with:`）→ **逐个手工 Edit**。
  批量脚本曾连续三次算错 `with:` 与 `uses:` 的层级关系弄坏 YAML，恢复后
  手工才稳定。判断依据：修改对象是「字符」还是「结构」。
- 每次改完工作流，跑 `./scripts/lint.sh`（**zizmor 已在其中**，用 docker 跑 `ci.yml`
  里 pin 的那个版本）；zizmor 基线 0 findings，豁免集中在 `.github/zizmor.yml`，
  每条有可验证的安全依据。新增 `uses:` 引用必须 pin 到 commit SHA（注释保留版本号），
  所有 checkout 保持 `persist-credentials: false`——这两条是供应链基线，
  别在后续改动中回退。

### 中文内容质量（本项目高频踩坑）

- **每次编辑中文内容（代码注释、文档、Issue/PR 正文）后，全仓扫描 U+FFFD**：

  ```bash
  python3 -c "
  import pathlib
  bad=[str(p) for p in pathlib.Path('.').rglob('*') if p.is_file() and '.git' not in p.parts
       and chr(0xfffd) in p.read_text(encoding='utf-8', errors='ignore')]
  print(bad if bad else 'OK')
  "
  ```

  多轮迭代中反复出现「写入时混入替换字符」，这条必须执行，不要省。
- 排错文档保留**报错原文**（使用者拿报错搜索），并写明「什么情况下不该用这个方案」。

- **批量改中文文档用「按行索引」，别用长中文串做匹配锚点**。长句里混入一个替换字符
  就会静默匹配失败或匹配错位（本次连踩两次，其中一次还是断言本身报了「未找到」）。
  更稳的做法：先用 `### 标题` 这类含 ASCII 的锚点定位，再按行号切片替换，写入前
  断言新内容不含 U+FFFD。需要复用已有文本时，**直接把行取出来用**，不要凭记忆重打。

### 提交与 PR

- 提交信息遵循 Conventional Commits（校验脚本 `scripts/check-commit-msg.sh`，CI 会查）。
  正文写**为什么**，不只是改了什么。
- 提交前本地跑 `./scripts/lint.sh`（actionlint + yamllint + shellcheck + bash -n + zizmor）。
  它**不验提交信息规范**——CI 校的是 PR 标题，本地无从验证，标题仍要自己按规范写。
- PR 正文结构：为什么 → 做了什么 → 关键取舍（含被否掉的方案）→ 测试策略。
- **CHANGELOG**：每个用户可感知的改动都要记入 `[Unreleased]`，分类固定为
  新增/变更/弃用/移除/修复/安全，不自创分类。修复类条目写清「此前错在哪、有什么后果」。
- **往 [Unreleased] 插条目，锚点必须校验在正确段落里**。`lines.index('### 新增')`
  找的是全文件第一个——版本刚发布后 [Unreleased] 是空壳，第一个「### 新增」在
  **上一个已发布版本**的段下，新条目会错插进已发布段（v1.8.0 发布时真实踩过，
  连续三个 PR 的条目都进错了段落，靠 diff tag 版本才发现）。插入前断言
  「锚点行号 > [Unreleased] 行号 且 < 下一个 ## [ 行号」，或先从 tag 版本恢复基准。
  已发布段的改正方法：`git show vX.Y.Z:CHANGELOG.md` 是唯一事实来源，
  条目按行取出搬进新版本段，不要重打。
- **创建 PR / Issue 的正文写进临时文件，不要用嵌套 heredoc**。把
  `gh pr create --body-file - <<'EOF'` 放进 `$(...)`、同时外层又给循环加一个 heredoc 时，
  `-` 拿到的 stdin 会是空的——**PR 正文静默丢失**，`Closes #N` 一起消失，症状是
  「PR 合并了、issue 还开着」。写成 `--body-file /tmp/pr-body.md`（先用 Write 落盘）不会踩这个。
  合并后养成核对 issue 是否关闭的习惯：没关就先看 PR 正文在不在。

## 四、CI 与合并

- CI 全绿才合并：`gh pr checks <N>` 或 `gh pr view <N> --json statusCheckRollup`。
- 合并用 `gh pr merge <N> --squash --delete-branch`。
- squash 后 PR 标题会成为提交信息，所以标题也要符合规范（CI 会校验）。

### CI 故障排查（真实踩过）

- **「CI 总览」job 卡 in_progress 而 run 汇总显示 success**：GitHub 状态不一致。
  `gh pr close <N> && gh pr reopen <N>` 重新触发即可恢复。
- **分支保护拒绝合并、提示 not up to date**：`git rebase main` 后
  `git push --force-with-lease`。合并远端分支前先 `git fetch --prune`。
- **`gh pr merge --auto` 报 Auto merge is not allowed**：仓库未开启该功能，
  改为等待检查完成后再合并。
- **`gh run view --log` 的输出混着源码行**：过滤 `[36;1m`（ANSI 回显）再看实际输出。
- **日志只显示 `exit code 2` 没有任何输出**：多半是 `set -e` 下某条命令失败导致整个步骤中断。
  「故意要失败的命令」（造失败数据）必须包在 `set +e` / `set -e` 之间。
- **网络抖动是常态**：`gh` / `git push` 失败就重试，模式：

  ```bash
  for i in 1 2 3 4 5; do
    if out="$(<命令> 2>&1)"; then echo "$out" | tail -1; break; fi
    echo "第 ${i} 次失败，重试..."; sleep 5
  done
  ```

  注意非幂等操作的重复执行风险（见发布幂等）。
- **HTTPS 对 github.com 不通时先试 SSH，再考虑重试**。曾有整晚 443 端口间歇性
  超时（`git fetch` 卡满 75 秒才报错），而 SSH 22 端口一直通：
  `ssh -T git@github.com` 十几秒就能验证。用临时 remote 兜底，别动使用者的
  `origin` 配置：`git remote add ssh-origin git@github.com:<owner>/<repo>.git`，
  用完 `git remote remove` 删掉（或事先问过使用者再改 origin）。
- **`gh` 只认 `origin`，分支推在别的 remote 上时用 `--head`**。分支推到
  `ssh-origin` 后，`gh pr create` 会报 `you must first push the current branch
  to a remote`——这不是网络问题，重试 20 次也不会好（真实踩过）。加
  `--head <owner>:<branch>` 一次就过。排查网络类报错前先看报错原文说的是什么。

## 五、发布

1. 从最新 main 切 `chore/release-vX.Y.Z` 分支。
2. 把 CHANGELOG 的 `[Unreleased]` 归入 `[X.Y.Z] - 日期`，段首加一句话概述本轮主题；
   `[Unreleased]` 恢复为空壳。
3. 提交信息 `chore(release): 发布 vX.Y.Z`，建发布 PR 并走完整 CI。
4. squash merge 后打标签并推送：
   `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`
5. `release.yml` 自动生成发布说明：CHANGELOG 手写部分 + GitHub 原生 PR 清单 + 可选 AI 摘要
   （配了 `ANTHROPIC_API_KEY` 才有，未配置走降级路径，不影响发布）。
6. 验证：`gh release view vX.Y.Z` 确认三段式内容齐全、`gh run list --workflow=release.yml` 确认成功。

### 发布幂等（Issue #41 的教训）

网络抖动时 `git push` 可能「显示失败、远端已成功」，重试会重复推送 tag → 触发两次发布工作流，
第二次 `gh release create` 因 Release 已存在而 422。工作流已做「先查后建」（已存在改走 edit），
**推送 tag 前先用 `git ls-remote --tags origin vX.Y.Z` 确认不存在**，避免制造无意义的失败运行。

### 判断成败禁止管道接 tail/head（v1.14.0 发布事故，2026-09-16）

`if gh pr merge N --squash | tail -1; then` 判断的是 **tail 的退出码**——合并没有发生也报成功，
tag 跟着打在错误提交上、release 用错误内容生成；重推时 `git push | tail -1` 又把一次真实的
SSL 失败误读为成功，release 空窗近一小时才发现。同类错误一天内连犯两次，而 spec 里
「包装函数吞退出码」早有记录——教训是具体模式没被点名：

- 判断成败一律 `if out="$(cmd 2>&1)"`，输出打印放在判断**之后**
- merge / push 之后必须复核远端真实状态：`gh pr view N --json state`、
  `git ls-remote --tags origin vX.Y.Z`
- tag 打错时修复顺序：删远端 tag（`git push origin :refs/tags/vX.Y.Z`）→ 删错误
  release（`gh release delete`）→ 确认 main 含归档提交 → 重推 tag → 验证
  release 内容（`gh release view` 正文开头应为本轮主题句）

## 六、发布后：继续规划

- 更新 Roadmap（Issue #4）：本轮条目移入「已完成」。
- 建下一版本里程碑与 Issue（回到第二步）。
- 看板同步（新 Issue 加入、项目状态与里程碑一致）。

---

## 红线（来自 docs/MAINTAINER_GUIDE.md，任何时候不得违反）

- 不给同步工作流添加自动触发器（schedule 等），同步必须显式触发
- `${{ }}` 表达式不直接写进 `run:`，一律经 `env:` 中转（表达式注入）
- 不在日志中输出 Secret；webhook URL 视同凭证
- 不弱化 `pull_request_target` 的安全性
- 凭证 / 内网地址不进代码、不进 Issue、不进日志

## 快速命令参考

| 操作 | 命令 |
| --- | --- |
| 本地全量检查 | `./scripts/lint.sh` |
| 建里程碑 | `gh api repos/nicholyx/action-sync-images/milestones -f title=... -f state=open` |
| Issue 入看板 | `gh project item-add 1 --owner @me --url <issue-url>` |
| 合并 PR | `gh pr merge <N> --squash --delete-branch` |
| 发布 | tag `vX.Y.Z` 推送即触发 release.yml |
| 历史趋势 | `./scripts/history.sh [--image X] [--top-failures N] [--slowest N]` |
| 乱码扫描 | 见「中文内容质量」一节的 python 命令 |
