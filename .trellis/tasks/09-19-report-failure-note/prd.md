# 同步报告缺失败原因：三种检查都有 note，唯独同步主模式没有

## Goal

把失败原因 `R_NOTE` 带进 `sync-report.md`（「说明」列）、`sync-report.json`（`images[].note`）、Step Summary 与结果通知——让「为什么失败」在报告和页面上看得见，而不只在终端日志里出现一次。

对应 Issue [#102](https://github.com/nicholyx/action-sync-images/issues/102)。

## Background

### 现状

`R_NOTE` 在整个 `scripts/sync.sh` 里只有 4 处引用：

| 位置 | 用途 |
| --- | --- |
| `:136` | 声明 |
| `:2707` | `load_results` 填充 |
| `:3262-3263` | **仅在终端表格打印** |

三种只读检查（`--audit` / `--check-updates` / `--audit-lock`）的报告**都带** `note`（`A_NOTE`、`L_NOTE` 经 `jq -n --arg` 落进 records，见 `:2111`、`:2645`），同步主模式是唯一没有的。两类报告的信息丰度不对称。

### 已复现（2026-09-19 本地）

dry-run 会走 `load_results` → `emit_summary` → `write_report`（`scripts/sync.sh:3724-3746`），用一条非法引用即可造出真实的失败记录，无需 registry 与网络：

```bash
./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
  --report-dir /tmp/rep102 --dry-run
```

`sync-report.json` 的产出：

```json
{"source": "nginx", "dest": "—", "status": "failed", "platforms": "—", ...}
```

**失败状态在，失败原因不在。** 与此同时终端是打印了的——`[信息] 镜像引用格式错误：镜像引用缺少 tag 或 digest`。同一份运行，终端知道原因，报告和 Step Summary 不知道。

### 为什么这会影响判断

`R_NOTE` 的三条来源语义完全不同（`:1665`、`:1741`、`:1767`）：

| note 文案 | 含义 | 该不该重跑 |
| --- | --- | --- |
| `镜像引用格式错误：…` | 输入就是错的 | **重跑多少次都不会成功** |
| `同步失败，详见上方日志` | 搬运过程失败 | 值得重跑 |
| `完整性校验失败：…` | 推完了但 digest 对不上 | 值得重跑，且更需要看到细节 |

只看到 `❌` 而看不到 note，使用者无法区分「改输入」和「重跑」——而这正是 v1.15 的重跑指引（`collect_rerun_items`，`:3115`）已经在做的区分。报告里缺了这一环，指引就落不了地。

## Requirements

- **R1** `sync-report.json` 的 `images[]` 增加 `note` 字段（string），**字段始终存在**；无原因时为空字符串。与 `rerun` 三字段的既有约定一致（「字段本身始终存在，消费方不必判空」）
- **R2** `sync-report.md` 表格增加「说明」列
- **R3** Step Summary 表格增加「说明」列，与 md 同源同口径——两处不得各写一套渲染
- **R4** 结果通知的「失败详情」带出 note
- **R5** note 写入 md 表格前必须转义 `|` 与换行，否则会破坏表格结构（详见 design 的防御说明）
- **R6** 不改变 `R_NOTE` 的**产生**逻辑——`write_result` 与三条来源一律不动
- **R7** 不影响可重跑判定（`collect_rerun_items` 已依赖 `R_NOTE` 前缀，`:3134`）
- **R8** 空 note 在 md / Summary 里按既有风格显示为 `—`（与 `R_PLATFORM[$i]:-—` 一致）

## 依赖与顺序

**必须在 `09-19-report-json-escape` 之后做。** 两者都改 `write_report()` 的 json 分支：本任务往 json 里加字段，前者换掉 json 的构造方式。先加字段再换构造 = 同一段代码改两遍、断言写两遍；反过来则 `note` 一进去就自带正确转义。

## Acceptance Criteria

- [ ] 失败项的 `sync-report.json` 里 `images[].note` 为该次失败的真实原因（本次复现路径下即 `镜像引用格式错误：…`）
- [ ] `note` 字段始终存在。**成功项为空串 `""`**；跳过项与排除项各自是既有原因（`目标已存在相同镜像`、排除原因，见 `scripts/sync.sh:1715` / `:1836`），会如实进入说明列——这是「排除的东西必须可见」的延续，不是缺陷

  > 订正（2026-09-19，实现阶段发现）：本节初稿写的是「成功项 / 跳过项的 `note` 为 `""`」，**与代码事实不符**。规划时从「note 只在失败时有用」的假设出发，没有核实 `skipped` / `excluded` 也写 note；实际只有 `success` 是空串。R6 禁止改动 note 的产生逻辑，因此行为不变，改的是这条验收标准本身。
- [ ] `sync-report.md` 表格出现「说明」列，失败行显示原因，无原因的行显示 `—`
- [ ] Step Summary 同样出现「说明」列
- [ ] 通知的「失败详情」每行带出该镜像的 note
- [ ] note 含 `|` 或换行时，md 表格**列数不变**、不串行（渲染层转义，CI 有单测）
- [ ] `history.sh --dir` / `--slowest` / `--check` 均不受影响（`:389` 的 `images[]` 聚合、`:417-435` 的类型累加）
- [ ] 既有 `gather_alert_images` 断言不破（CI `:1105-1130`）
- [ ] CI 有对应断言；断言**先在本地复现过**（先看到红，再看到绿）
- [ ] macOS 自带 bash 3.2 下正常
- [ ] `./scripts/lint.sh` 全绿

## Out of Scope

- **不改 note 的产生逻辑**，也不新增 note 来源
- **不改同步行为与退出码**：本任务只影响输出，不碰搬运与判定
- **不为通知加封顶机制**：调研结论是同步通知**本来就没有** 20 条封顶（那个封顶在审计 / 锁检查的通知里，`:2660`），issue 里「需评估 20 条封顶策略是否适用」的答案是**不适用**——本任务不新增封顶，也不把审计的封顶逻辑搬过来
- 不修 `R_SRC` 含 `|` 时破坏 md「源镜像」列的既有问题（那是引用列，与本任务的说明列是两回事，需单独评估）
- 不改检查报告（它们已有 note）
