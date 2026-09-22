# 让 lint.sh 的承诺与实际相符

对应 Issue：nicholyx/action-sync-images#130

## Goal

五处文档（含 `scripts/lint.sh` 自述）承诺 `./scripts/lint.sh` **一键跑完 CI 的全部静态检查**，
而它实际只跑 actionlint / yamllint / shellcheck / `bash -n`——少了 **zizmor** 与 **提交信息规范**。

`CONTRIBUTING.md:204` 据此写「提交前跑一次，能省掉一轮 CI 返工」——**省不掉**。

## 方案（**已修订**）

原方案是「把缺的两样都补上，让承诺成真」。**修订后按证据分两半处理**：

| 缺的那半 | 处理 | 依据 |
| --- | --- | --- |
| **zizmor** | **补上**（本地 100% 可复现） | CI 里就是 `docker run --rm -v "$PWD":/repo:ro ghcr.io/zizmorcore/zizmor:<版本> /repo --no-online-audits`，镜像 pin 到版本，本地跑同一条命令零漂移 |
| **提交信息规范** | **不补，改文档如实说明** | 见下 |

### 为什么提交信息规范补不上

CI 的 `commit-messages` job 校验**两样**：

- `校验 PR 中的提交信息`：`check-commit-msg.sh --range "${BASE_SHA}..${HEAD_SHA}"`
- **`校验 PR 标题`**：`check-commit-msg.sh --message "$PR_TITLE"`

squash merge 之后成为提交信息的正是**标题**，而标题在 PR 建立之前不存在——**本地任何入口都验不了它**。
所以接上 `--last` 最多关掉一半，而「一半」不足以支撑「已在本地验过」这句话。

更糟的是它会引入一个**假绿来源**（已实测）：

```bash
$ ./scripts/check-commit-msg.sh --range nonsense..HEAD   → exit=0 | 全部合规（共检查 0 条）
$ ./scripts/check-commit-msg.sh --range abc123..def456   → exit=0 | 全部合规（共检查 0 条）
```

`check-commit-msg.sh:142` 把 `git log` 的 stderr 丢弃，于是**不区分「区间无效」与「区间内没有提交」**。
而它 header 推荐的本地用法 `--range origin/main..HEAD` 恰好踩这个形态（新 clone / 无 remote-tracking ref /
detached HEAD），`--last` 的 `HEAD~1..HEAD` 在仓库首个提交上同理。

**在一个「宁可不给结论，也不给错结论」的项目里，新增一个假绿来源来兑现一句承诺，是拿更贵的东西换更便宜的。**
这个假绿本身是独立缺陷，另开 issue（见 Out of Scope）。

## Requirements

### R1 补上 zizmor

按 CI 的同一方式调用（docker + 同一镜像 + `--no-online-audits`），保证「本地过 = CI 过」。

**镜像版本必须与 CI 同源**（从 `ci.yml` 抽），不写第二份——写死会在 CI 升级时静默漂移，
而漂移正是这个 issue 本身要消除的那类问题。

### R2 边界不得假报错

- 本机既无 `zizmor` 也无 `docker` → **明确跳过**并给出安装方式（既有 `skip_check` 的形态）
- 有 docker 但镜像拉取失败（离线）→ **如实报失败**。这是「工具在但没跑成」，
  与「工具不在」不是一类（同项目「无法判定必须单独成类」的口径）
- 从 `ci.yml` 抽不到版本 → 不得静默跳过，要说明原因

### R3 文档如实描述

五处：`README.md:72`、`README.en.md:73`、`AGENTS.md:32`、`CONTRIBUTING.md:201`、`scripts/lint.sh:5`。

措辞要**说清边界**，不是把承诺改得更响亮：

- 覆盖：actionlint / yamllint / shellcheck / bash -n / zizmor
- **不覆盖**：提交信息规范（CI 校验的是 PR 标题，本地无从验证）——并指出这一点，
  让贡献者知道「本地绿」不等于 `commit-messages` 会绿

## Acceptance Criteria

- [ ] **AC1** 干净的仓库上跑 `./scripts/lint.sh`，输出里出现 zizmor 一项（通过或明确跳过）
- [ ] **AC2** 无 `docker` 且无 `zizmor` 时该项**明确跳过**并给安装方式，不中断其余检查
- [ ] **AC3** 版本同源：把 `ci.yml` 里的 zizmor 版本临时改成别的值，lint.sh 取到的是**改动后**的值
      （证明不是各写一份）
- [ ] **AC4** 五处文档与实现一致；`grep` 不再有「全部静态检查」这类已不成立的表述，
      且都说明了「提交信息规范不在其中、原因是什么」
- [ ] **AC5** 不出现假绿：lint.sh 里**没有**接入 `check-commit-msg.sh`（它现在会对无效区间 exit 0）
- [ ] **AC6** `bash -n`、`shellcheck`、`./scripts/lint.sh` 自身全绿
- [ ] **AC7** `docs/MAINTAINER_GUIDE.md:107` 的 `ci-summary` 覆盖清单补全为 7 项
      （顺带，同一份调研发现，1 行）

## Constraints

- 兼容 bash 3.2
- `lint.sh` 的既有结构（`run_check` / `skip_check` / 三个计数）保持，不重写
- 退出码语义不变：0 全过，非零有失败；**跳过不算失败**（既有行为）
- 不新增命令行参数

## Out of Scope

- **不修 `check-commit-msg.sh` 的假绿**（`--range` 解析到 0 条时 exit 0）。它是独立缺陷，
  需单独评估「0 条时该报错还是该区分区间无效」——那是另一条取舍
- 不在本地复现 `smoke-test` / `integration-test`（它们不是「静态检查」，且需要网络与容器）
- 不改 `commit-messages` job 的 CI 行为
- 不处理 `lint.sh:73` 的 `-ignore 'SC2086'`（本地比 CI 宽松）——同批调研发现，
  但属独立一条，另开 issue

## Notes

- 判据是**「本地过 = CI 过」在 lint.sh 声明的范围内成立**，而不是「lint.sh 能替代 CI」
- 这个 issue 本身就是「文档承诺与实现不符」的案例。修的时候最容易犯的错是
  **为了让承诺成真而引入新的不诚实**（这里是假绿）——所以方案是「让承诺缩小到真话」