# 设计：write_report 的 json 分支改由 jq 构造

## 边界

改动收敛在 `scripts/sync.sh` 的 `write_report()` 一个函数内，且只碰 json 分支（`:3398-3436`）。md 分支（`:3353-3396`）连行号都不变。

不新增函数、不新增参数、不动 `write_check_report_files`。

## 契约：json 报告必须保持的字段与类型

这份 schema 有外部消费方（`history.sh`），因此**逐字段锁死类型**。任何一条从 number 变成 string 都是破坏性变更：

| 字段 | 类型 | 取值来源 |
| --- | --- | --- |
| `generated_at` | string | `date -u` |
| `dest_registry` | string | `${DEST_EXACT:-${DEST_REGISTRIES[*]}}` |
| `strip_attestation` | **boolean** | `$STRIP_ATTESTATION`（字面量 `true`/`false`） |
| `total` / `success` / `skipped` / `failed` / `excluded` | **number** | 函数入参 |
| `filter` / `exclude` | string | `$FILTER_REGEX` / `$EXCLUDE_REGEX` |
| `rerun.images` | string[] | `$RERUN_IMAGES`，无失败项时为 `[]` |
| `rerun.filter` | string | `$RERUN_FILTER` |
| `rerun.not_rerunnable` | **number** | `$RERUN_NOT_RERUNNABLE` |
| `images[]` | object[] | 见下 |

`images[]` 每条：

| 字段 | 类型 |
| --- | --- |
| `source` / `dest` / `status` / `platforms` / `source_digest` / `dest_digest` | string |
| `seconds` | **number** |

**消费方证据**（改动不得破坏）：

- `scripts/history.sh:417-420`：`map(.total) \| add`、`map(.success) \| add`、`map(.failed) \| add`——string 参与 `add` 会得到字符串拼接或直接报错
- `scripts/history.sh:431-435`：`map(.seconds // 0) \| add / max / min`
- `scripts/history.sh:389`：`select(.images != null) \| .images[]`——`images` 必须是数组，不能变 `null`

## 方案：两段式，与检查报告同构

检查报告的做法是「调用方先用 `jq -n --arg` 逐条写 JSON Lines，再 `jq -n --slurpfile` 组装顶层」（`:2111`、`:2645`、`:2992-2995`）。同步报告直接照搬这条路径，理由是同一个文件里不该存在两种构造 json 的方式——现在正是这种并存导致了缺陷。

### 第一步：每条镜像写一行 JSON Lines

```bash
  local records_file="${WORK_DIR}/${REPORT_NAME}.images.jsonl"
  : > "$records_file"
  for i in "${!R_SRC[@]}"; do
    jq -n --arg source "${R_SRC[$i]}" \
          --arg dest "${R_DEST[$i]}" \
          --arg status "${R_STATUS[$i]}" \
          --arg platforms "${R_PLATFORM[$i]:-}" \
          --arg source_digest "${R_SRC_DIGEST[$i]:-}" \
          --arg dest_digest "${R_DEST_DIGEST[$i]:-}" \
          --argjson seconds "${R_SECONDS[$i]:-0}" \
      '{source:$source, dest:$dest, status:$status, platforms:$platforms,
        source_digest:$source_digest, dest_digest:$dest_digest, seconds:$seconds}' \
      >> "$records_file"
  done
```

`--arg` 负责转义字符串，`--argjson` 保住数字类型。键的书写顺序与现状一致，产出的字段顺序不变。

### 第二步：组装顶层

```bash
  local rerun_json
  if [[ ${#RERUN_IMAGES[@]} -gt 0 ]]; then
    rerun_json="$(jq -n --arg filter "$RERUN_FILTER" \
      --argjson not_rerunnable "$RERUN_NOT_RERUNNABLE" \
      --args '{images:$ARGS.positional, filter:$filter, not_rerunnable:$not_rerunnable}' \
      "${RERUN_IMAGES[@]}")"
  else
    rerun_json="$(jq -n --arg filter "$RERUN_FILTER" \
      --argjson not_rerunnable "$RERUN_NOT_RERUNNABLE" \
      '{images:[], filter:$filter, not_rerunnable:$not_rerunnable}')"
  fi
```

三个必须注意的点：

1. **`$ARGS.positional`，不是 `$ARGS`。** `--args` 把位置参数放进 `$ARGS.positional`，`$ARGS` 整个对象是 `{positional:[], named:{}}`——直接写 `$ARGS` 会把 `images` 变成一个对象而不是字符串数组（已实测）。
2. **`filter` 与 `not_rerunnable` 两个字段在两个分支里都要写。** 只填 `images` 会静默丢掉这两个字段，而 R3 要求字段完整。
3. **空数组必须走 `else` 分支分开写。** `"${RERUN_IMAGES[@]}"` 在空数组 + `set -u` + bash 3.2（macOS 自带）下会报 `unbound variable`；CI 的 bash 5 不复现，所以这个坑只在本地暴露。同源教训见 `scripts/sync.sh:3067-3070` 的注释。

```bash
  jq -n --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg dest "${DEST_EXACT:-${DEST_REGISTRIES[*]}}" \
    --argjson strip "$STRIP_ATTESTATION" \
    --argjson total "$total" --argjson success "$ok" \
    --argjson skipped "$skipped" --argjson failed "$fail" \
    --argjson excluded "$excluded" \
    --arg filter "$FILTER_REGEX" --arg exclude "$EXCLUDE_REGEX" \
    --argjson rerun "$rerun_json" \
    --slurpfile images "$records_file" \
    '{generated_at:$at, dest_registry:$dest, strip_attestation:$strip,
      total:$total, success:$success, skipped:$skipped, failed:$failed,
      excluded:$excluded, filter:$filter, exclude:$exclude,
      rerun:$rerun, images:$images}' > "$json"
```

`--argjson rerun "$rerun_json"` 把上一步的 JSON 文本嵌回来——jq 会原样保留其结构，不会二次转义成字符串。

`--slurpfile` 对空文件产出 `[]`（不是 `null`），满足 R4。

### 删除

`:3411-3423` 那段手工转义的注释与 `${RERUN_FILTER//\\/\\\\}` 一并删除——它存在的前提（「没有 jq 兜底」）消失了。

## 权衡

**为什么不继续用 printf 手工转义？** 需要转义的不止引号和反斜杠：控制字符（U+0000–U+001F，含 `\n`、`\t`）在 JSON 字符串里也非法。手工实现一份正确的 JSON 字符串转义函数是重复造 jq 已有的轮子，且 `FIELD_SEP`（`\x1f`，`scripts/sync.sh:1459`）本身就是控制字符——它一旦漏进任何字段就会产出非法 JSON。交给 jq 是唯一能一次性覆盖全部分支的做法。

**为什么不整段改成一个巨型 jq 调用？** 那需要把 bash 并行数组整体序列化成 JSON 再喂给 jq，反而要新增一层「bash 数组 → JSON」的转换——正好又绕回手工拼接。逐条 `jq -n --arg` 写作、整体 `--slurpfile` 组装是检查报告已验证过的形态，照抄即可。

## 行为变化：从「静默产出坏数据」到「尽早失败」

`--argjson` 遇到非法数字会**立即报错**，而 `set -e` 下 `write_report` 的非零返回会让脚本退出。

这是刻意的，且方向正确：

- 现状是写出一份坏 JSON，本地看起来一切正常，问题在**下游解析时**才炸——远离现场
- 新行为是当场失败，附带 jq 的错误信息

`seconds` 的实际来源是 `$((end - start))`（`process_one`）与 `load_results` 的 `${seconds:-0}` 兜底，正常路径上恒为数字，因此这个分支预期打不到。**但如果打到了，让它响。**

## 兼容性核对

| 消费方 | 读取方式 | 是否受影响 |
| --- | --- | --- |
| `history.sh` 同步趋势 | `.total` / `.success` / `.failed`（number） | 否——类型已锁 |
| `history.sh --slowest` | `.images[].seconds`（number） | 否 |
| `history.sh --check` | 走 `write_check_report_files` 的产物 | 否——本任务不碰 |
| `history.sh --dir` 落盘 | 自己 `jq -n` 组装，不读同步报告 | 否 |
| Step Summary 渲染 | 走 md 分支 | 否——md 分支不动 |

## 回滚

单函数改动，回滚 = revert 该 PR，无数据迁移、无状态残留。报告文件是一次性产物，无需回滚已写出的历史文件。

## 设计原型已验证（2026-09-19）

上述两段代码已抽成独立脚本跑通并逐项核对，不是「看起来对」：

| 核对项 | 结果 |
| --- | --- |
| 含 `"` / `\` 的 `source` / `dest` 往返 | 逐字符相等 |
| 顶层字段类型 | `strip_attestation` boolean，计数类全 number，其余 string |
| `images[]` 字段类型 | 除 `seconds` 为 number 外全 string |
| `rerun.not_rerunnable` | number（未被 `--arg` 降级） |
| `rerun.images` 非空分支 | 正确携带 `\` 转义 |
| `rerun.images` 空分支 | `[]`，且 `filter` / `not_rerunnable` 未丢失 |
| 空 records 文件经 `--slurpfile` | 得到 `[]`，非 `null`（满足 R4） |
| `FIELD_SEP`（U+001F）注入字面量 | jq 转义为 `\u001f`；**同一字面量走裸 `printf` 产出非法 JSON** |

最后一行同时印证了「手工转义不够」的论断——控制字符是手工转义最容易漏掉的一类。

## 验证方式

本地复现命令（先红后绿，不需要 registry 与网络）：

```bash
rm -rf /tmp/rep103 && mkdir -p /tmp/rep103
./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
  --report-dir /tmp/rep103 --dry-run
jq -e . /tmp/rep103/sync-report.json          # 修复前：parse error；修复后：通过
jq -r '.images[0].source' /tmp/rep103/sync-report.json   # 必须逐字符等于 ngi"nx:1.0
```

反斜杠用同样的方式造一条（`--src 'ngi\nx:1.0'` 传字面反斜杠，非转义序列）。

类型不变性的回归比对（修复前后各跑一次，diff 输出应为空）：

```bash
jq -r 'keys[] as $k | "\($k) \(.[$k]|type)"' /tmp/rep103/sync-report.json
jq -r '.images[] | to_entries[] | "\(.key) \(.value|type)"' /tmp/rep103/sync-report.json
```

CI 断言加在 `smoke-test` job 内（dry-run 不需要额外依赖，该 job 已装 skopeo）。
