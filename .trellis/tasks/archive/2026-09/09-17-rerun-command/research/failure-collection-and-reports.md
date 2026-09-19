# Research: 失败汇总与结果报告生成（sync 主模式）

- **Query**: 同步结束后失败项在哪里汇总？数据结构？`--report-dir` 的 md/json 由谁写？报告里有哪些失败相关字段？
- **Scope**: internal（`scripts/sync.sh`）
- **Date**: 2026-09-17

## Findings

### 1. 失败项的汇总位置与数据结构（已确认）

**汇总函数**：`emit_summary()`，`scripts/sync.sh:3078-3180`。

计数逻辑 `scripts/sync.sh:3080-3087`：

```bash
for i in "${!R_STATUS[@]}"; do
  case "${R_STATUS[$i]}" in
    success)  ok=$((ok + 1)) ;;
    skipped)  skipped=$((skipped + 1)) ;;
    excluded) excluded=$((excluded + 1)) ;;
    *)        fail=$((fail + 1)) ;;   # 兜底：任何非前三者都计入失败
  esac
done
```

注意 `scripts/sync.sh:3091` 的 `total=$((ok + skipped + fail))` —— **excluded 不计入 total**。

**数据结构：不是单个数组，而是「带序号的独立结果文件 → 并行数组」两层。**

| 层 | 位置 | 形态 |
|---|---|---|
| 落盘 | `WORK_DIR/result-%04d-%02d` | 每个「镜像序号 × 目标序号」一个文件 |
| 内存 | `R_SRC` / `R_DEST` / `R_STATUS` / `R_PLATFORM` / `R_SECONDS` / `R_NOTE` / `R_SRC_DIGEST` / `R_DEST_DIGEST` | 8 个并行数组，声明于 `scripts/sync.sh:131-138` |

- 路径生成：`result_file_for()`，`scripts/sync.sh:1639-1641`，`printf '%s/result-%04d-%02d' "$WORK_DIR" "$1" "$2"`，零填充保证 glob 字典序正确。
- 单条写入：`write_result()`，`scripts/sync.sh:1606-1614`。字段用 `$'\x1f'` 分隔（`readonly FIELD_SEP=$'\x1f'`，`scripts/sync.sh:1452`）。
- 读回：`load_results()`，`scripts/sync.sh:2679-2704`，`IFS="$FIELD_SEP" read -r src dest status platform seconds note src_digest dest_digest`。
- 文件名按序号，因此数组下标 = 结果文件序号，**顺序与输入清单完全一致**。

`note` 字段写入前会做分隔符消毒（`scripts/sync.sh:1612`）：`"${note//$FIELD_SEP/ }"`。

**状态值域**：`success` / `skipped` / `failed` / `excluded`（无 `unknown`）。

**「按序号对齐、标记而非删除」——实际实现确认符合规范：**

- 规范原文：`.trellis/spec/engine/bash-rules.md:63` —— 「结果数组按序号对齐（下标同时决定结果文件序号），**标记而非删除**（`EXCLUDE_REASONS` 是范本）」
- 实现：`apply_filters()` `scripts/sync.sh:1215-1254`，注释 `1213-1214` 明确写了「只做标记，不删除元素……删掉元素会让序号整体前移」。
- 被筛掉的镜像由 `dispatch_all()` `scripts/sync.sh:1811-1815` 写一条 `status=excluded`、`dest="—"`、`note=排除原因` 的结果记录；**仍然占位**。
- 全部被筛掉时 `die`（`scripts/sync.sh:1249-1251`），不会静默成功。

### 2. `--report-dir` 的 md / json 写入函数（已确认）

**同一个函数写两份**：`write_report()`，`scripts/sync.sh:3182-3257`。调用点在 `emit_summary()` 内 `scripts/sync.sh:3166-3168`。

文件名：`${REPORT_DIR}/${REPORT_NAME}.md` 与 `.json`（`scripts/sync.sh:3191`、`3228`）。`REPORT_NAME` 默认 `sync-report`（`scripts/sync.sh:45`），**无命令行参数可改**（`parse_args` 里没有 `--report-name`；这是 `history.sh` 才有的参数）。

#### JSON 真实字段名与嵌套结构（`scripts/sync.sh:3229-3253`）

```
{
  "generated_at": "<UTC ISO8601 Z>",
  "dest_registry": "<DEST_EXACT 或 DEST_REGISTRIES 以空格连接>",
  "strip_attestation": true|false,        // 裸布尔字面量
  "total": <num>,
  "success": <num>,
  "skipped": <num>,
  "failed": <num>,
  "excluded": <num>,
  "filter": "<FILTER_REGEX 原样，可能为空串>",
  "exclude": "<EXCLUDE_REGEX 原样，可能为空串>",
  "images": [
    {
      "source": "<str>",
      "dest": "<str>",
      "status": "<success|skipped|failed|excluded>",
      "platforms": "<str>",             // 注意是复数名，对应 R_PLATFORM
      "source_digest": "<str|空>",
      "dest_digest": "<str|空>",
      "seconds": <num>                  // 唯一不加引号的数值字段
    }
  ]
}
```

要点：
- 数组名是 `images`（不是 `records`）——这是与三种检查报告的关键区别。
- **顶层没有 `check` / `mode` 字段**，消费方只能靠「有 `images` 还是有 `records`」判别报告类型（`history.sh` 就是这么做的，`scripts/history.sh:389`）。
- 这里**没有** `note`。
- 手工 `printf` 拼接而非 `jq -n --arg`，因此镜像名里若含 `"` 或 `\` 会破坏 JSON 结构（与检查报告走 jq 的做法不同）。

#### Markdown 结构（`scripts/sync.sh:3192-3226`）

```
# 镜像同步报告
- 生成时间：<UTC ISO8601 Z>
- 目标地址：<DEST_EXACT 或 DEST_REGISTRIES[*]>
- 同步模式：regctl（剔除 attestation） | skopeo（保留全部平台）
- 筛选条件：...            ← 仅当 --filter/--exclude 非空
- 结果：共 N 个镜像，成功 x 个，跳过 y 个，失败 z 个[；另有 e 个被筛选排除]

| 源镜像 | 目标镜像 | 结果 | 平台 | 源 Digest | 目标 Digest | 耗时 |
（结果列图标：✅ success / ⤼ skipped / ⊘ excluded / ❌ 其它）

## 最慢的同步记录      ← 条件小节，duration_ranking_rows 5
| 耗时 | 镜像 → 目标 |
```

### 3. 报告里「失败镜像」的字段覆盖情况（逐条，已确认）

| 需求 | 是否记录 | 字段 / 位置 |
|---|---|---|
| 源地址 | ✅ | md 第 1 列 / json `images[].source` |
| 目标地址 | ✅ | md 第 2 列 / json `images[].dest`（excluded 时为 `—`） |
| 平台 | ✅ | md 第 4 列 / json `images[].platforms` |
| 失败原因 | ❌ **完全没有** | 见下 |
| 状态 | ✅ | md 结果列 / json `images[].status` |
| 耗时 | ✅ | md 末列 / json `images[].seconds` |
| digest 凭据 | ✅ | md 两列 / json `source_digest` `dest_digest` |

**失败原因缺失是本主题最关键的发现**：`R_NOTE` 在整份 `scripts/sync.sh` 里只被引用 4 处（`grep -n R_NOTE`）：

- `136` 声明
- `2700` `load_results` 填充
- `3113-3114` **仅在终端表格里打印**

即：`note`（例如 `同步失败，详见上方日志`、`完整性校验失败：<逐平台差异>`、`镜像引用格式错误：<原因>`、排除原因）**不进 md、不进 json、不进 Step Summary、不进通知**。

对比：三种检查模式的报告**都带 note**（见 `check-modes-and-step-summary.md`），所以这是 sync 主模式独有的信息缺口。

失败原因的产生位置（供参考，均在 `process_one`）：
- `scripts/sync.sh:1652-1659` 非法引用 → `failed`，note = `镜像引用格式错误：${reason}`
- `scripts/sync.sh:1733-1737` 同步失败 → `failed`，note = `同步失败，详见上方日志`
- `scripts/sync.sh:1758-1764` `--verify` 校验失败 → 由 `success` 改写为 `failed`，note = `完整性校验失败：${diff_detail//$'\n'/; }`

## Caveats / Not Found

- `write_report` 用字符串拼接生成 JSON，未做转义——镜像引用含特殊字符时 json 可能非法（**推测**风险，未实测验证触发条件）。
- `REPORT_NAME` 固定为 `sync-report`，多份同步报告同名，放进同一 `--report-dir` 会互相覆盖（`history.sh` 靠 Artifact 分目录规避）。
- json 里 `platforms` 与数组名 `R_PLATFORM` 单复数不一致，易误写成 `platform`。
- 未查：CI 是否有断言 sync-report.json 结构的测试用例（`ci.yml` 中见到的是 dry-run / Step Summary 断言）。
