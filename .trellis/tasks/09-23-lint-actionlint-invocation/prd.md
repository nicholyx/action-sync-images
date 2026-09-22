# fix: lint.sh 的 actionlint 在非 git 目录必红，且比 CI 宽松

对应 Issue：[#138](https://github.com/nicholyx/action-sync-images/issues/138)、[#133](https://github.com/nicholyx/action-sync-images/issues/133)

**一个 PR 合并处理两个 issue**：它们改的是 `lint.sh` 里**同一个调用点**，分开做会互相冲突。

## Goal

`scripts/lint.sh` 的 actionlint 那一行有两个独立问题：

1. **非 git 目录下必然红**（#138）：actionlint 需要 git 仓库定位项目根，报
   `no project was found in any parent directories of "…"`。**GitHub 的 source tarball 不含 `.git`**——
   从 tarball 解压出来想跑一下本地检查的人，第一项就红，而他什么都没改
2. **比 CI 宽松**（#133）：本地是 `actionlint -color -ignore 'SC2086'`，CI 是 `./actionlint -color`——
   改工作流时引入的 SC2086，本地不报、CI 会报

## 关键调研结论（已实测，方案就建立在它上面）

**actionlint 有不必依赖 git 的调用方式**：

| 调用方式 | 非 git 目录下的结果 |
| --- | --- |
| 裸跑（现状） | ❌ `no project was found` |
| **显式给工作流文件列表** | ✅ **rc=0，真跑** |
| 显式给单个文件 | ✅ rc=0 |

**所以修法不是「非 git 时跳过」，而是显式传文件**——让它在非 git 目录下**真正跑起来**。
跳过只是在缺陷面前退让；显式传文件是把它修好。

（原方案「检测非 git 就跳过」已被此实测推翻，不再考虑。）

## Requirements

### R1 显式传工作流文件列表

**不能直接复用 `YAML_TARGETS`**——它收集的是 `.github` 下**所有** yml/yaml，
里面混着 `.github/dependabot.yml`、`.github/labeler.yml`、`.github/ISSUE_TEMPLATE/*.yml`。

**这一点已实测**（不要重测，直接用结论）：

```text
actionlint .github/dependabot.yml                → rc=1：`.github/dependabot.yml:8:1: "jobs" section is missing in workflow`
actionlint .github/labeler.yml                   → rc=1：同类
actionlint .github/ISSUE_TEMPLATE/bug_report.yml → rc=1：同类
actionlint .github/workflows/*.yml               → rc=0 ✅
```

即传非工作流文件会**报错**（它们本来就不是 workflow），所以 actionlint 要**单独收集**
`.github/workflows/` 下的文件。`lint.sh` 里 yamllint 用的是 `YAML_TARGETS`（它该收全部），
两者目标集**不同**，别合并。

### R2 去掉 `-ignore 'SC2086'`，与 CI 等价

去掉后本地与 CI 都是 `actionlint -color`（CI 还多一个 `./` 前缀，无关）。

**先实测去掉后本地仍绿**（调研阶段跑过，仍绿；你复核一遍）。若出现告警，**不要**用 `-ignore` 盖掉——
那正是 #133 要消除的东西。把告警如实报告，让决策者处理。

### R3 空列表要处理

`${YAML_TARGETS[@]}` 为空时（理论上不会有，但 `find` 失败时可能）不能裸展开——
bash 3.2 + `set -u` 下会抛 unbound variable（见 `.trellis/spec/engine/bash-rules.md`）。
按既有形态处理（同文件里 yamllint / shellcheck 两处已有先例：`if [[ ${#arr[@]} -gt 0 ]]`）。

## Acceptance Criteria

- [ ] **AC1** 在**不含 `.git`** 的目录副本里跑 `./scripts/lint.sh` → actionlint 项**通过**（不再是「失败」）
- [ ] **AC2** 在正常仓库里跑 → 行为不变（仍通过）
- [ ] **AC3** `lint.sh` 里不再有 `-ignore 'SC2086'`；`grep` 确认
- [ ] **AC4** CI 的 actionlint 调用与本地**逐参数等价**（`grep` 两处后并列展示）
- [ ] **AC5** **变异验证**：故意在某个工作流里引入一个真实告警（例如 SC2086 或表达式拼错），
      确认 `lint.sh` **会红**——这是「本地过 = CI 过」的实际检验。
      做完**务必还原**并确认 `git diff` 干净
- [ ] **AC6** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 两个 job 全绿
- [ ] **AC7** `docs/MAINTAINER_GUIDE.md:338` 那句「本地绿而 CI 红，多半是工具版本差异」的归因
      是否需要调整——**先读它，再判断**（#133 提到它可能指错方向）

## Constraints

- 兼容 bash 3.2
- 不改 `lint.sh` 的既有结构（`run_check` / `skip_check` / 三个计数）
- 不新增命令行参数
- 其余检查项（yamllint / shellcheck / bash -n / zizmor）不动

## Out of Scope

- 让 `lint.sh` 去跑 `smoke-test` / `integration-test`（不是静态检查）
- 把 `check-commit-msg.sh` 接进 `lint.sh`（#130 已明确不接）

## Notes

- 判据是「**本地过 = CI 过**」在静态检查范围内成立——#133 与 #138 都是这条的缺口，
  只是一个偏向「本地太宽松」，一个偏向「本地根本跑不起来」
- **AC5 是本任务的重点**：不加变异验证，「两处参数一致」就只是文本比对，
  而不是「它们真的会一起红」