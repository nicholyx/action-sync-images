# sync-report.json 为裸字符串拼接，镜像名含引号会产出非法 JSON

## Goal

`write_report()` 的 json 分支改由 `jq` 构造，使镜像引用含 `"` 或 `\` 时仍产出合法 JSON；与三种只读检查报告（`write_check_report_files`）收拢到同一条构造路径。

对应 Issue [#103](https://github.com/nicholyx/action-sync-images/issues/103)。

## Background

### 现状

`scripts/sync.sh:3398-3436` 用裸 `printf` 逐字段拼 json，**没有任何转义**：

```bash
printf '    {"source": "%s", "dest": "%s", "status": "%s", ...}' \
  "${R_SRC[$i]}" "${R_DEST[$i]}" "${R_STATUS[$i]}" ...
```

`:3411-3413` 那条注释（`filter` 的反斜杠要手动 `//\\/\\\\`）说明这条路径「没有 jq 兜底」是被知道的事实——只是当时只给 `filter` 一个字段做了手工转义，`images[]` 整段没做。

### 已复现（2026-09-19 本地，无需真实 registry）

dry-run 同样会走 `load_results` → `emit_summary` → `write_report`（`scripts/sync.sh:3724-3746`），因此复现不需要凭证、不需要网络：

```bash
./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
  --report-dir /tmp/rep103 --dry-run
jq . /tmp/rep103/sync-report.json
```

产出的 `sync-report.json`：

```json
{"source": "ngi"nx:1.0", "dest": "registry.example.com/smoke/ngi"nx:1.0", ...}
```

`jq` 的结果：

```
jq: parse error: Invalid numeric literal at line 14, column 23
```

**关键点：全过程零报错。** `ngi"nx:1.0` 通过了 `validate_ref`，dry-run 判定为成功，终端显示 `✓`——报告已经坏了，而没有任何一处提示。

### 影响面

`sync-report.json` 是 `history.sh` 的数据源（`scripts/history.sh:389` 聚合 `images[]`，`:417-435` 累加顶层计数）。一份坏 JSON 会让趋势、`--slowest`、`--check` 整条链路解析失败，且失败点在**下载之后的解析阶段**，排查时不会联想到「某次同步的镜像名里有引号」。

## Requirements

- **R1** json 由 `jq` 构造，转义交给 jq——与 `write_check_report_files`（`scripts/sync.sh:2992-2995`）统一到同一条路径
- **R2** **字段类型不变**：`total` / `success` / `skipped` / `failed` / `excluded` / `seconds` / `not_rerunnable` 保持 number，`strip_attestation` 保持 boolean。若用 `--arg` 传值会退化成 string，`history.sh` 的 `map(.total) | add` 直接崩——这是比原缺陷更严重的破坏
- **R3** 字段名、层级、字段顺序完全不变（`generated_at` / `dest_registry` / … / `images[]` / `rerun{}`）
- **R4** 零值语义不变：无失败项时 `rerun.images` 是 `[]` 而非 `null`；`images` 为空时同样是 `[]`
- **R5** 只改 json 分支；md 分支、终端表格、Step Summary 一律不动
- **R6** 退出码语义不变，不新增命令行参数
- **R7** 不引入新依赖（`jq` 已是既有依赖，见 `:2111`、`:2992`）

## Acceptance Criteria

- [ ] 镜像引用含 `"` 时，产出的 `sync-report.json` 可被 `jq` 解析
- [ ] 含 `\` 时同样可解析
- [ ] 解析出的 `source` / `dest` 与输入**逐字符相等**（不是被静默吃掉或替换掉引号）
- [ ] 修复前后**逐字段比对类型一致**：`jq -r 'keys[] as $k | "\($k) \(.[$k]|type)"'` 的输出无差异
- [ ] 无失败项时 `rerun.images == []`，`jq -e '.rerun.images == []'` 通过
- [ ] `history.sh --dir` 能正常消费新报告（趋势、`--slowest`、`--check` 均不受影响）
- [ ] CI 有对应断言；断言**先在本地复现过**（先看到红，再看到绿）
- [ ] macOS 自带 bash 3.2 下正常（注意空数组展开在 `set -u` 下的行为）
- [ ] `./scripts/lint.sh` 全绿

## Out of Scope

- **不改报告 schema**：不加字段、不加版本号。加 `note` 字段是 `09-19-report-failure-note` 的任务，按父任务的顺序约束排在本任务**之后**
- 不改 `write_check_report_files`（它已经是安全的）
- 不统一 md 与 json 的 `generated_at` 取值时机（当前各调一次 `date`，可能差 1 秒）——属独立的小问题，混进来会污染本任务的验证边界
- 不修 `R_SRC` 含 `|` 时破坏 md 表格的既有问题（与本任务的 json 转义是两回事，见 `09-19-report-failure-note` 的说明列设计）
