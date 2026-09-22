# 补上只读模式与失效参数告警的断言

对应 Issue：nicholyx/action-sync-images#134

## Goal

四组**零依赖**（纯参数与文本比对）的覆盖缺口，全部属「不报错、退出码正常、但结论是错的」那类：

1. 三组「不生效参数」告警（`--check-updates` / `--audit` / `--audit-lock` 的 ignored 列表）
2. 六组互斥组合的 `die`
3. 跨文件常量一致性（`history.sh` 的常量 ↔ `check-registry.yml` 的字面量）
4. `-h` / `--help` 的退出码

## 现状（已实测采集）

```text
① --check-updates：--dry-run --write-lock --concurrency
② --audit       ：--dry-run --write-lock --verify --skip-existing
③ --audit-lock  ：--dry-run --filter / --exclude 目标地址（--dest / --dest-keep-path）
```

三处都在 `main()` 的启动校验区，格式统一为「合并成一条、一次列全」。

## Requirements

### R1 三组告警各断言一次

沿用 dry-run 那条同类告警的严格度（`ci.yml:1642`）：断言告警**存在**，且**合并成一条**（不是每项一行）。

**结构脆弱点要一并覆盖**：`--check-updates` 的列表用 `CONCURRENCY != "1"`、`TIMEOUT != "600"`
直接与**硬编码默认值**比较（`sync.sh:3867-3868`）——默认值一改，该列表静默失效，
使用者传 `--concurrency 4` 跑 `--check-updates` 就收不到任何提示。

### R2 六组互斥组合各断言一次

- `--dest-exact` + `--dest` / `--dest-keep-path`
- `--audit` + `--check-updates`
- `--audit-lock` + `--check-updates` / `--audit` / `--src` / `--file`
- **`--audit` + `--strip-attestation`**（最要紧：源码注释写明它会「产出一排**假的「落后」**」）

复用 `ci.yml` 的「验证非法参数被立即拒绝」里已有的 `check_reject` 辅助函数。

**注意**：互斥判定在**文件存在性检查之前**（`sync.sh:3838-3850` 早于 `3903`），
所以 `--audit-lock` 的用例传路径即可、**无需真实文件**。

### R3 把该步骤现有 4 条只断退出码的用例升级为断文案

`--concurrency abc` / `--concurrency 0` / `--timeout soon` / `--dest-exact` 多镜像——
它们现在只断言退出码 1，而**退出码 1 可能来自任何一条 `die`**，区分度太低。

### R4 跨文件常量一致性

`history.sh` 的 `REPORT_NAME="check-report"` 与 `WORKFLOW_FILTER="Check-Registry"`
（约 `195-205`）对应 `check-registry.yml:2`（`name: Check-Registry`）与 `197`（`name: check-report`）。

**一条文本比对即可**。改名后 `history.sh --check` 会走完整条下载流程再 die，
诊断信息把人指向 GitHub Actions 配置，而真实原因是本地常量过期。

### R5 `-h` / `--help` 的退出码 0

`sync.sh` 与 `history.sh` 的 `-h` 都走 `usage; exit 0`，而未知参数走 `exit 1`，
两者**共用 usage 输出**——值得钉住这个差别。

## Acceptance Criteria

- [ ] **AC1** 三组告警各有一条断言，且断言「合并成一条」而非「每项一行」
- [ ] **AC2** 六组互斥各有一条断言（复用 `check_reject`）
- [ ] **AC3** 现有 4 条只断退出码的用例已升级为断文案
- [ ] **AC4** 跨文件常量一致性有断言；**做变异验证**：把 `check-registry.yml` 里的名字改掉后断言会红
- [ ] **AC5** `-h` / `--help` 退出码 0 有断言（两个脚本）
- [ ] **AC6** **每条断言都做过变异验证**——把被测的那条 `die` 或告警删掉后，断言会红。
      这是本任务的核心：这批缺口之所以存在，正是因为原来的断言「只看退出码」
- [ ] **AC7** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 两个 job 全绿

## Constraints

- **不改生产代码**（本任务只加断言）。若发现某条 `die` 的文案本身有问题，**报告而不是顺手改**
- 兼容 bash 3.2
- 新步骤的容器名/端口/临时文件不得与 job 内既有步骤冲突
  （见 `.trellis/spec/maintenance/index.md` 的「改动 CI 步骤」一节——此前真实撞过一次）
- 断言用 `grep -qF`（固定字符串）

## Out of Scope

- 三组告警之外的其他 ignored 列表（`upd_ignored` / `lock_ignored` 的构造逻辑本身）
- `--platforms` / `--skip-existing` 的「本次将忽略」告警——它们属 #137（需要 regctl 路径）
- 修 `sync.sh:3867-3868` 用硬编码默认值比较这件事——本任务只**断言现状**，
  改它是另一回事（若断言写起来别扭，说明该改的是代码，请在报告里说）

## Notes

- 判据是「**断言要能区分「这条 die 触发了」与「别的 die 触发了」**」——
  这正是原 4 条用例的失效方式
- AC6 是本任务的重点：加断言不难，难的是证明它**不是恒真的**