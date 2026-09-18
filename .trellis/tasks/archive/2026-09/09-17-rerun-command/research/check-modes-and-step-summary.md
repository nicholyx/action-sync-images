# Research: Step Summary 与只读检查模式（audit / check-updates / audit-lock / verify）

- **Query**: Step Summary 谁写？结构是什么？三种只读检查的「需要关注的项」如何表示、报告 json 结构？检查模式有无「重跑」语义？
- **Scope**: internal（`scripts/sync.sh`）+ 工作流（`.github/workflows/`）
- **Date**: 2026-09-17

## Findings

### 4. Step Summary 的写入位置（已确认）

**全部在 `scripts/sync.sh` 内写，工作流 YAML 不写 Step Summary。** 五处写入点，全部以 `if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]` 守卫：

| 模式 | 函数 | 行号 |
|---|---|---|
| 同步（默认） | `emit_summary` | `scripts/sync.sh:3122-3163` |
| dry-run 计划 | `print_dry_run_plan` | `scripts/sync.sh:1581-1603` |
| `--audit` | `emit_audit_summary` | `scripts/sync.sh:2096-2098` |
| `--check-updates` | `check_updates_all` | `scripts/sync.sh:2344-2354` |
| `--audit-lock` | `emit_lock_summary` | `scripts/sync.sh:2630-2632` |

`grep -rn GITHUB_STEP_SUMMARY .github/scripts` 确认：sync/check 类工作流里**没有** `>> "$GITHUB_STEP_SUMMARY"` 的步骤。其他出现处均属别的功能：

- `.github/workflows/release.yml:264,275`（发布结果）
- `.github/workflows/history-trend.yml:86`（`cat "$out_file" >> ...` 趋势报告）
- `.github/workflows/ci.yml:146,202`（测试时用 `GITHUB_STEP_SUMMARY="$summary"` 注入临时文件做断言）
- `.github/workflows/ci.yml:1952-1971`（CI 自检汇总）

### 5. 同步 Step Summary 的当前结构（`scripts/sync.sh:3123-3162`）

```
## 镜像同步报告

| 源镜像 | 目标镜像 | 结果 | 平台 | Digest | 耗时 |
| --- | --- | :---: | --- | --- | --- |
（结果列：✅ / ⤼ 已存在 / ⊘ 已排除 / ❌；Digest 列用 short_digest 截断）

**合计**：N 个镜像 · 成功 x · 跳过 y · 失败 z
> 另有 e 个镜像被 `--filter` / `--exclude` 排除，未参与本次同步。      ← 条件

### 最慢的同步记录                                                   ← 条件，duration_ranking_rows 5
| 耗时 | 镜像 → 目标 |
| ---: | --- |

> ⚠️ 本次为 dry-run，未实际推送任何镜像。                             ← 仅 dry-run
```

- 表格**没有「说明/失败原因」列**（与 md 报告一致）。
- dry-run 的 Summary 是另一套（`scripts/sync.sh:1583-1601`）：`## Dry-run 同步计划` + `| 源镜像 | 目标镜像 | 执行路径 | 平台策略 |` + `**预计命令**：N 条`。

### 6. 三种只读检查的「需要关注的项」与报告结构（已确认）

| 模式 | 结果数组 | 结果文件 | 状态值域 | 「需要关注」 |
|---|---|---|---|---|
| `--audit` | `A_SRC/A_DEST/A_STATE/A_NOTE` | `WORK_DIR/audit-%04d-%02d` | `current/stale/missing/unknown/excluded` | `stale` + `missing` + `unknown` |
| `--check-updates` | 无（直接输出） | 无 | `covered/updates/empty/error`（逐仓库） | `with_updates` + `failed` |
| `--audit-lock` | `L_REF/L_STATE/L_NOTE` | `WORK_DIR/lock-%04d` | `match/drift/unknown/nodigest/marker` | `drift` + `unknown` |
| `--verify` | — | — | 不是模式，是同步的开关 | 见下 |

**`--audit`**
- 结果文件：`audit_result_file_for()` `scripts/sync.sh:1917-1919`；写入 `write_audit_result()` `scripts/sync.sh:1921-1926`，字段 `src<FS>dest<FS>state<FS>note`。
- 逐目标各出一行，不合并状态（注释 `scripts/sync.sh:1930-1932`）。
- 汇总/报告：`emit_audit_summary()` `scripts/sync.sh:2044-2147`。
- records（JSONL）：`{source, dest, state, note}`，`scripts/sync.sh:2104-2106`。
- summary：`{"current":n,"stale":n,"missing":n,"unknown":n,"excluded":n}`，`scripts/sync.sh:2108-2110`。
- 退出码：`stale|missing|unknown > 0` → `2`（`scripts/sync.sh:2143-2145`）。
- 通知只列 `stale/missing/unknown`，最多 20 条（`scripts/sync.sh:2117-2134`）。

**`--check-updates`**
- 无结果文件、无数组，`check_updates_all()` `scripts/sync.sh:2225-2378` 直接渲染。
- records（JSONL，`scripts/sync.sh:2239-2240`，逐条 `2273/2283/2297/2325`）：`{repo, in_manifest, state, latest_tags, note}`，state ∈ `error` / `empty` / `covered` / `updates`。
- summary：`{"checked":n,"with_updates":n,"failed":n,"total_missing":n}`，`scripts/sync.sh:2362-2364`。
- 退出码：`with_updates | failed > 0` → `2`（`scripts/sync.sh:2374-2376`）。

**`--audit-lock`**
- 结果文件：`lock_result_file_for()` `scripts/sync.sh:2480-2482`；`write_lock_result()` `scripts/sync.sh:2484-2491`，字段 `ref<FS>state<FS>note`。
- records：`{entry, state, note}`（注意键名是 `entry` 不是 `ref`），`scripts/sync.sh:2638-2639`。
- summary：`{"match":n,"drift":n,"unknown":n,"nodigest":n,"marker":n}`，`scripts/sync.sh:2641-2643`。
- 退出码：`drift | unknown > 0` → `2`（`scripts/sync.sh:2669-2671`）。
- `nodigest` / `marker` 是「不参与判定但必须可见」的条目（规范 `.trellis/spec/engine/modes.md:29`）。

**`--verify`**（`scripts/sync.sh:444-445`、`1751-1770`）：不是独立模式，是同步的开关。逐平台比对，`verify_integrity` 返回 1 时把已 `success` 的记录改写为 `failed` 并写 note；返回 2（拿不到 digest）只告警、不改状态（`scripts/sync.sh:1765-1768`）。它**没有独立报告**，结果并入 sync 报告。

**三种检查报告的文件与顶层结构**（共用 `write_check_report_files()`，`scripts/sync.sh:2970-2991`）：

- 文件名：`${REPORT_DIR}/${check_name}-report.md` 与 `.json`，`check_name` ∈ `audit` / `check-updates` / `lock-audit`（`scripts/sync.sh:2983,2988`）。
- JSON 顶层：`{generated_at, check, summary, records[]}`（`scripts/sync.sh:2985-2988`，用 `jq -n --slurpfile`，转义安全）。
- md 与 Step Summary **同源**：调用方把渲染好的同一段 markdown 传进来（注释 `scripts/sync.sh:2964-2966`）。
- 规范背书：`.trellis/spec/engine/modes.md:35`。

**两种状态分类铁律**（`.trellis/spec/engine/modes.md:26-29`）：`unknown` 永远单独成类；被排除/未参与判定的条目必须可见。

### 7. 检查模式下的「重跑」天然语义（已确认）

**只存在一句人类可读的提示，没有机器可读的任何东西。**

- `--audit`：`scripts/sync.sh:2080-2082`
  ```bash
  if [[ "$stale" -gt 0 || "$missing" -gt 0 ]]; then
    log_dim "去掉 --audit 重跑同一条命令即可补齐：已经最新的会被 --skip-existing 自动跳过"
  fi
  ```
  → 语义是「重跑**同步**」（把检查降级为搬运），不是「重跑检查」。
- 文档同步口径：`docs/USAGE.md:636`、`README.md:359`、`docs/USAGE.md:277`（每目标独立判定）。
- `--audit-lock`：`scripts/sync.sh:2618-2620` 给的是「把引用中的 tag 换成 @digest 回拉」的手工做法，与重跑无关。
- `--check-updates`：明确只报告、不改清单（`scripts/sync.sh:2339-2342`、`docs/USAGE.md:665`），无重跑语义。
- 这些提示全部走 `log_dim`（stderr），**不进 md / json / Step Summary**。

## Caveats / Not Found

- 检查模式的 `note` 均在 JSONL records 里逐条可达，唯独 sync 主模式没有——两类报告的信息丰度不对称（**已确认**，非推测）。
- `--audit` 的 `unknown` 同时承担「源不可达」「目标不可达」两种原因，只能靠 `note` 文本区分（`scripts/sync.sh:1949-1981`）；靠 `state` 无法机器判别。
- 检查模式的通知正文同样有 20 条封顶（`scripts/sync.sh:2121`、`2653`），**推测**若做重跑命令也要考虑同样的封顶策略。
