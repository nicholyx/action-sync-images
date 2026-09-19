# 设计：把 R_NOTE 带进报告、Summary 与通知

## 前置

**必须在 `09-19-report-json-escape` 合并之后开工。** json 落点的改动依赖后者引入的 `jq -n --arg` 构造路径；若 json 还是裸 `printf`，`note` 里的引号会直接产出坏 JSON——等于把刚修掉的缺陷重新引入一次。

## 边界

改动分布在四处，全部是**读取** `R_NOTE` 并渲染，不碰它的写入：

| 位置 | 改动 |
| --- | --- |
| `write_report()` json 分支 | records 记录多一个 `note` 字段 |
| `write_report()` md 分支 | 表头与数据行多一列 |
| `emit_summary()` 的 Step Summary | 表头与数据行多一列 |
| `gather_alert_images()` + `send_notification()` | 输出多一个字段、渲染多一段 |

新增一个纯函数 `md_cell()`。

**不动** `load_results()`、`write_result()`、`process_one()`——`R_NOTE` 从哪来不是本任务的问题。

## 数据流

```
process_one / validate_ref
  └─ write_result  ──FIELD_SEP 分隔──> WORK_DIR/result-*
        └─ load_results ──> R_NOTE[]
              ├─> write_report   ├─ md  表格「说明」列   ← md_cell 转义
              │                  └─ json images[].note    ← jq --arg 转义
              ├─> Step Summary   表格「说明」列          ← md_cell 转义
              └─> gather_alert_images ──> send_notification 「失败详情」
```

两个渲染落点（md 与 Summary）取的是**同一个** `R_NOTE[$i]`，不存在两份数据。R3 说的「同源同口径」指这个；**不要求**把两个表格的渲染函数合并——它们的列本来就不同（md 有源/目标两个 digest 列，Summary 只有一个 Digest 列），为了共用而重构渲染是超出本任务范围的改动。

## 落点一：json（`images[].note`）

在 `09-19-report-json-escape` 建立的 records 循环里加一行：

```bash
    jq -n --arg source "${R_SRC[$i]}" \
          ...
          --arg note "${R_NOTE[$i]}" \
      '{source:$source, ..., dest_digest:$dest_digest, seconds:$seconds, note:$note}' \
      >> "$records_file"
```

字段加在**末尾**，保持既有字段相对顺序不变。转义由 jq 负责，note 里的引号、反斜杠、控制字符都不需要额外处理。

`note` 始终存在；无原因时 `R_NOTE[$i]` 为空字符串，产出 `"note": ""`——满足 R1 的「消费方不必判空」。

## 落点二与三：md 表格与 Step Summary

### 渲染层必须先转义

note 有一条来源是**动态的**：`完整性校验失败：${diff_detail//$'\n'/; }`（`:1767`）。`diff_detail` 的内容随失败形态变化，不能假定它永远不含 `|`。而 Markdown 表格里：

- 一个裸 `|` 会多切出一列，**整行错位**
- 一个裸换行会**截断整行**，后面的内容掉出表格

因此新增一个纯函数，两个渲染落点都走它：

```bash
# 把任意文本安全地放进 Markdown 表格单元格。
#
# 竖线会多切出一列、换行会截断整行——两者都会把表格结构弄坏，而 note 的
# 内容随失败形态变化（如 diff_detail），不能假定它不含这些字符。
# 两个替换互不干涉，先后顺序无所谓；这里按「先收敛换行、再转义竖线」写，
# 只为读起来顺。
md_cell() {
  local s="${1//$'\n'/ }"
  printf '%s' "${s//|/\\|}"
}
```

**取舍**：只处理 `|` 与换行这两类「破坏结构」的字符，不处理 `\`。原因是 Markdown 里 `\|` 已是竖线的转义序列，再对反斜杠做一层转义会引入 `\\|` 这种语义含糊的产物，而收益只覆盖「note 里恰好有反斜杠紧跟竖线」这一近乎不存在的场景。当前三条 note 来源中，两条是固定文案，第三条是 digest 比对描述，都不含反斜杠。

**纯函数是为了可测**——CI 已有用 `sed -n '/^fn()/,/^}/p'` 抽取生产函数单测的手法（`:1151-1152`），`md_cell` 沿用，无需为了测它而构造一个真能产出含 `|` note 的同步场景（那个场景造不出来）。

### md 表格

表头加一列「说明」，追加在**末尾**（对既有列顺序扰动最小）：

```markdown
| 源镜像 | 目标镜像 | 结果 | 平台 | 源 Digest | 目标 Digest | 耗时 | 说明 |
```

数据行对应追加：

```bash
note_cell="$(md_cell "${R_NOTE[$i]}")"
[[ -n "$note_cell" ]] || note_cell="—"      # 与 R_PLATFORM[$i]:-— 的既有风格一致
echo "| ... | ${R_SECONDS[$i]}s | ${note_cell} |"
```

### Step Summary

同样的「说明」列追加在末尾。Summary 表格当前列是 `源镜像 | 目标镜像 | 结果 | 平台 | Digest | 耗时`，加完是 7 列。

两处的 `—` 兜底逻辑一致：空 note 显示 `—`，不显示空白单元格。

## 落点四：通知

失败详情当前由 `build_notify_text` 拼装（`:2889`），入参 `alert_detail` 来自 `send_notification` 的循环（`:3050-3059`），而循环的数据源是 `gather_alert_images`（`:2868`）——它只输出 `img<sep>cnt`。

**让 `gather_alert_images` 多输出一个字段**，而不是在 `send_notification` 里按 `img` 反查 `R_SRC`：

```bash
    printf '%s%s%s%s%s\n' "$img" "$FIELD_SEP" "$cnt" "$FIELD_SEP" "${R_NOTE[$i]}"
```

理由：反查需要「镜像名 → 下标」的映射，而 `R_SRC` 允许重复条目（同一次同步里同一镜像出现两次是合法的，例如两个不同 `--dest`）。反查会取到错的那条 note，且这种错在多数输入下看不出来。按 `i` 直接取则永远对。

note 里不会混入 `FIELD_SEP`：`write_result` 在写入时已把 `FIELD_SEP` 替换为空格（`:1617`）。这一层保证从 `R_NOTE` 的来源就成立了。

### 解析端必须同步改

当前的解析是**取最后一段**：

```bash
img="${line%%"${FIELD_SEP}"*}"     # 第一段
cnt="${line##*"${FIELD_SEP}"}"     # 最后一段
```

加了第三个字段后，`##*` 取到的会是 **note**，不是 `cnt`——这个错很隐蔽：`cnt` 变成 note 文本后 `[[ "$cnt" -gt 1 ]]` 会报「integer expression expected」或静默走 else 分支。必须改成按段取：

```bash
img="${line%%"${FIELD_SEP}"*}"
rest="${line#*"${FIELD_SEP}"}"
cnt="${rest%%"${FIELD_SEP}"*}"
note="${rest#*"${FIELD_SEP}"}"
```

### 渲染

```bash
    if [[ "$cnt" -gt 1 ]]; then
      alert_lines+=("- ${img}（**连续第 ${cnt} 次失败**）")
    else
      alert_lines+=("- ${img}")
    fi
```

改为在行尾按需追加 note（空 note 不追加，不留一个孤零零的冒号）：

```bash
    if [[ -n "$note" ]]; then
      alert_lines+=("${line}：${note}")
    else
      alert_lines+=("${line}")
    fi
```

### 既有断言的兼容性

CI `:1105-1130` 用 `gather_alert_images` 的输出做断言，其中：

```bash
grep -q "$(printf 'a.example.com/x:1\x1f3')" <<<"$out"
```

`grep -q` 是**子串**匹配，新字段追加在 `\x1f3` 之后，子串仍然命中，断言不破。另一条 `grep -c 'example.com'` 数的是行数，同样不受影响。

通知**不新增封顶**——见 PRD 的 Out of Scope：同步通知本来就没有封顶机制，那个 20 条限制在审计 / 锁检查的通知里（`:2660`）。

## 兼容性核对

| 消费方 | 读取方式 | 是否受影响 |
| --- | --- | --- |
| `history.sh` `aggregate_by_image` | `.images[]` 后只取 `source`/`status` | 否——多出的 `note` 被忽略 |
| `history.sh` 趋势计数 | `.total` / `.success` / `.failed` | 否——顶层不动 |
| `history.sh --slowest` | `.images[].seconds` | 否 |
| `collect_rerun_items` | `R_NOTE` 前缀匹配 `镜像引用格式错误*` | 否——只读不写 |
| 通知 `gather_alert_images` 断言 | 子串匹配 | 否——见上 |
| Step Summary / md 渲染 | 自产自销 | 新增列，见 R2/R3 |

## 回滚

四个落点互相独立，可整 PR revert。json 里多出的 `note` 是**新增字段**，旧消费方一律忽略，因此不存在「必须同时回滚数据」的问题——历史报告文件保留原样即可。

## 验证方式（先红后绿）

失败记录用非法引用造，不需要 registry 与网络：

```bash
rm -rf /tmp/rep102 && mkdir -p /tmp/rep102
./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
  --report-dir /tmp/rep102 --dry-run

jq -e '.images[0].note | startswith("镜像引用格式错误")' /tmp/rep102/sync-report.json
jq -e '.images[0] | has("note")' /tmp/rep102/sync-report.json          # 字段存在性
grep -q '| 说明 |' /tmp/rep102/sync-report.md                           # md 新增列
grep -q '镜像引用格式错误' /tmp/rep102/sync-report.md                   # 且真的写了原因
```

Step Summary 用 `GITHUB_STEP_SUMMARY=<临时文件>` 走同一段流程。

`md_cell` 的单测走函数抽取（与 CI `:1151-1152` 同手法）：

```bash
sed -n '/^md_cell()/,/^}/p' scripts/sync.sh > /tmp/cell.sh
# 断言：含 "|" 的输入产出 \|；含换行的输入产出单行；两者都含时列数不变
```

### `md_cell` 已实测（2026-09-19，macOS 自带 bash 3.2.57）

| 输入 | 输出 |
| --- | --- |
| `a\|b` | `a\\\|b`（渲染为字面竖线，不切列） |
| `a<换行>b` | `a b`（收敛为单行） |
| `a\|b<换行>c\|d` | `a\\\|b c\\\|d` |
| 空串 | 空串（调用方据此显示 `—`） |
| `完整性校验失败：sha256:aaa != sha256:bbb` | 原样（真实 note 文案不含待转义字符） |

第 6 项如实记录一处已知取舍：输入 `a\|b`（字面反斜杠紧跟竖线）会产出 `a\\\|b`，多出一个反斜杠。这是「不处理反斜杠」取舍的直接后果，评估见上文——三条真实 note 来源都不会产生这种输入。

通知走 mock（与 CI `:1085-1130` 同一套骨架）：`gather_alert_images` 的输出必须含第三个字段；`send_notification` 需要在 mock 下确认 `cnt` 解析未错位——**这正是最容易改错的一处**，断言必须显式覆盖「note 为空」与「note 非空」两种输入。
