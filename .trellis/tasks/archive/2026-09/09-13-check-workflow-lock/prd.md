# 体检工作流支持 lock 模式（锁文件时效校验上云）

## Goal

Check-Registry 工作流的 `mode` 增加 `lock` 选项：传入锁文件跑 `--audit-lock`，
报告进入 `check-report` Artifact，为「哪个镜像一直在漂移」的趋势
（[[../09-13-audit-trend]]）提供云端数据源。

背景：`--audit-lock`（v1.8.0）目前只有本地入口，报告只能本地积累；
趋势功能确认后（2026-09-13），云端数据源由本任务补齐。

## 确认的事实

- `--audit-lock <文件>` 直接接锁文件路径（scripts/sync.sh:452-454），
  **不碰目标仓库**（scripts/sync.sh:3183-3184：与 `--check-updates` 同样
  「只查上游」），因此工作流 lock 模式**不需要登录目标仓库**
- 与 `--audit` / `--check-updates` 互斥（scripts/sync.sh:3244-3248），一次运行只跑一种
- 锁文件由 `--write-lock <路径>` 产出，文档典型名 `images.lock.resolved.txt`
  （docs/USAGE.md:386,398）；锁文件应提交进仓库（它本来就是精确复现的依据）
- 体检工作流的 `lockfile` 输入传给 `--file` 的是**镜像清单**，与锁文件是两个文件
  ——lock 模式需要**新增独立输入**，不能复用 `lockfile`
- 报告落盘与 Artifact 均为现成机制：`--report-dir ./reports` → `check-report`
  Artifact（`.github/workflows/check-registry.yml`「上传体检报告」步骤，if: always()）
- 通知：检查模式下 `--notify-on failure` 表示「有需要关注的项」，
  lock-audit 的关注项 = drift / unknown（脚本侧已实现，工作流只是传参）
- 退出码 2 = 未得出「全部一致」（有漂移或没查成），工作流 step 就是要让它失败
  ——与 audit/updates 模式的「绿 = 正常，红 = 需要看看」同一呈现策略

## Requirements

- `mode` 的 choice options 增加 `lock`，default 保持 `audit` 不变
- 新增 `lock_file` 输入（锁文件路径，默认 `images.lock.resolved.txt`），
  description 写明「仅 lock 模式需要」；`lockfile`（清单）对 lock 模式不传
- 「执行体检」step 的 case 增加 lock 分支：`args=(--audit-lock "$LOCK_FILE")`；
  不传 `--dest` / `--file`（传了会被脚本告警「不生效」）
- 「Login to Registry」step 的条件保持仅 audit（lock 与 updates 一样只查上游）
- filter / exclude 输入对 lock 模式不适用（脚本校验层会处理互斥/告警，
  工作流侧不传即可）；`updates_limit` 同理
- run-name 的模式显示随 `inputs.mode` 自动生效，无需改

## Acceptance Criteria

- [ ] `mode: lock` 触发体检工作流：step 调用
      `./scripts/sync.sh --audit-lock <lock_file> --report-dir ./reports`（+通知参数按输入）
- [ ] lock 模式下不执行 Login to Registry（`if:` 条件不命中）
- [ ] 报告 Artifact `check-report` 内含 `lock-audit-report.md` 与 `lock-audit-report.json`
- [ ] 锁文件不存在时 step 报错并失败（与清单缺失同款 `::error::` 处理）
- [ ] `./scripts/lint.sh` 与 zizmor（基线 0 findings）通过；不新增 `uses:` 引用，
      所有 checkout 保持 `persist-credentials: false` 不回退
- [ ] docs/USAGE.md 的 Check-Registry 输入表格与模式说明补 lock 行/段
- [ ] 涉及 YAML 结构的修改逐个手工 Edit（不写批量脚本），改完本地
      `actionlint` 复现通过后再提交
- [ ] CHANGELOG `[Unreleased]` 记入（注意锚点校验在正确段落）

## Out of Scope

- 不改 `--audit-lock` 脚本侧行为（参数、退出码、报告格式全部沿用 v1.8.0）
- 不给工作流加任何自动触发器（红线）
- 趋势查询本身 → [[../09-13-audit-trend]]

## 入手位置

- `.github/workflows/check-registry.yml`：inputs.mode（options 列表）、
  inputs.lock_file（新增）、env（LOCK_FILE 中转——`${{ }}` 不进 run:，必须经 env）、
  「执行体检」step 的 case 块

## 难度

简单。主要是工作流输入与 case 分支的接线，脚本侧零改动。
