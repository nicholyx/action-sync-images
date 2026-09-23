# 给 lint.sh 加 CI 自测 job

对应 Issue：nicholyx/action-sync-images#148

## Goal

**CI 里根本不调用 `scripts/lint.sh`**（`grep` 只命中 `welcome.yml` 的一句提示文案），
也没人断言它的行为。而它偏偏是**唯一一个零覆盖的脚本**——`sync.sh` 的每个参数、
`history.sh` 的每个模式都有断言。

它自己的职责又是「**本地过 = CI 过**」。这条保证的上游没有保障，而近两轮修的
#138 与 #133 **都出在它身上**（一个本地根本跑不起来、一个本地太宽松）。

## 关键决策：另起 job，而不是塞进 smoke-test

`lint.sh` 的 zizmor 那一项会**调 docker**（与 CI 同一条命令），而 `smoke-test` 的
设计前提是**不启容器**（它的 33 个步骤都不启，那是这个 job 的性质）。

**所以另起一个 job `lint-selftest`**：它可以自由用 docker 与网络，
smoke-test 的性质不被破坏。

**代价**：多一个 job（CI 时间 +约 30 秒）。
**收益**：`lint.sh` 从零覆盖变成有回归保护——它此前的每个改动都处在
「改坏了没有 CI 会发现」的状态里（#138/#133 就是这么攒下来的）。

## Requirements

### R1 装 actionlint

`lint.sh` 的 actionlint 那一项是本 job 的两条断言都要用的，而 **smoke-test 的 runner
上不一定有**（CI 里它由独立的 `actionlint` job 自己下载）。

复用 `actionlint` job 的下载方式（`ci.yml` 的「安装 actionlint」步骤），
**版本取同一个 `env.ACTIONLINT_VERSION`**——不要写第二份（写死会漂移）。

**shellcheck**：`ubuntu-latest` 自带，不必装。
**yamllint**：本 job 的断言不依赖它（未装时 `lint.sh` 会 `skip_check`，不影响）。

### R2 断言一：非 git 目录下能跑通（#138 的回归）

`lint.sh` 的 actionlint 此前裸跑、要靠 `.git` 定位项目根，在不含 `.git` 的目录里
报 `no project was found`。用 `tar --exclude=.git` 造一个副本（等价于 GitHub 的
source tarball），断言 **actionlint 那一项不失败**。

**只断 actionlint 那一项**——不要断「lint.sh 整体 rc=0」：别的项（yamllint 未装、
zizmor 拉镜像）会让整体 rc 波动，那样的断言会变成「对正确实现假报错」。

### R3 断言二：引入真实告警时会红（#133 的回归）

在工作流里**精确引入一个真实告警**（SC2086 最直接：把 `cat "$f"` 改成 `cat $f`），
断言 `lint.sh` **红**且**失败项是 actionlint**。

**做完务必还原**，并确认 `git diff .github/workflows/` 干净——本 job 在 CI 里跑，
留下的改动会污染后续步骤。

### R4 加进 ci-summary 的 needs

否则它的失败不会阻止合并，等于白加。`ci-summary` 的 `needs:` 现在是 7 项，
本 job 后是 8 项。

**顺带**：`docs/MAINTAINER_GUIDE.md` 里 `ci-summary` 的覆盖清单也要加（它刚在
#130 被补成 7 项，现在变 8）。

## Acceptance Criteria

- [ ] **AC1** 新 job 在 CI 里跑通；两条断言都有输出
- [ ] **AC2** 断言一只断 actionlint 项，**不断** `lint.sh` 整体 rc（避免对正确实现假报错）
- [ ] **AC3** 断言二的变异**真的被抓住**：本地先把「引入告警 → 红」跑通再进 CI
- [ ] **AC4** 加进 `ci-summary` 的 `needs`；`MAINTAINER_GUIDE.md` 的清单同步
- [ ] **AC5** 不破坏 `smoke-test` 的性质（它仍不启容器）
- [ ] **AC6** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 全部 job 全绿

## Constraints

- 新 job 的名字与既有风格一致（中文显示名，见 `ci.yml` 里各 job 的 `name:`）
- 权限最小化：`permissions: contents: read`（与其它只读 job 一致）
- `persist-credentials: false`（与全仓一致）
- 兼容 bash 3.2（本 job 跑在 ubuntu 上，但脚本写法要与仓库口径一致）

## Out of Scope

- 让 `lint.sh` 去跑 `smoke-test` / `integration-test`（不是静态检查）
- 把 `check-commit-msg.sh` 接进 `lint.sh`（#130 已明确不接）

## Notes

- 判据是「`lint.sh` 的行为**有 CI 保护**」，不是「它覆盖得更多」
- **两条断言的方向是相反的**：一条防「本地太严」（跑不起来），一条防「本地太松」
  （漏报）。这正好对应 #138 与 #133 这两个真实的缺口
- 若发现新 job 的启动时间明显拖慢 CI（例如 zizmor 拉镜像），可以再评估是否让它
  跳过 zizmor——但**先不要**为了省时间牺牲断言的方向性