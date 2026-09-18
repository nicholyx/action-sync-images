# Research: 现有重跑相关能力（filter/exclude 语义、dry-run 参数数组、history.sh 重试模式）

- **Query**: 重跑失败项现在要手工做什么？`--filter`/`--exclude`/清单文件的语义与正则行为？dry-run 的「真实参数数组」在哪组装？`history.sh` 的重试模式能否复用？
- **Scope**: internal（`scripts/sync.sh`、`scripts/history.sh`）
- **Date**: 2026-09-17

## Findings

### 8. 当前重跑失败项需要手工做什么（已确认）

从报告里挑出失败项后，使用者要**从零重建整条命令**，因为报告里没有任何 invocation 记录。必须自己凑齐：

| 类别 | 参数 | 报告里能否查到 |
|---|---|---|
| 清单来源 | `--file <路径>` 或 `--src <引用>` | ❌ md/json 都没有清单路径 |
| 目标地址形式 | `--dest <前缀>` / `--dest-keep-path <前缀>` / `--dest-exact <完整地址>` | 部分：json 有 `dest_registry`，但**区分不出用的是哪种形式** |
| 筛选 | `--filter` / `--exclude` | ✅ json 有 `filter` / `exclude` 字段 |
| 同步开关 | `--skip-existing` / `--verify` / `--strip-attestation` / `--platforms` | 仅 `strip_attestation` 有；其余无 |
| 调优 | `--concurrency` / `--timeout` / `--retries` / `--retry-delay` / `--tls-verify` | ❌ |
| 凭证 | 环境变量 `SYNC_SRC_USERNAME` / `SYNC_SRC_PASSWORD` / `SYNC_SRC_CREDENTIALS` | ❌（且刻意不进 argv） |
| 报告/通知 | `--report-dir` / `--notify-webhook` / `--history-artifact` | ❌ |

**把结果收窄到失败项本身也只能手工做**：要自己从 `images[]` 或 md 表格里抄出失败镜像，再手写一条正则喂给 `--filter`。

#### `--filter` / `--exclude` 的确切语义（`scripts/sync.sh:1215-1254`）

- **匹配对象**：`SOURCE_IMAGES` 里的**原始引用字符串**，即用户 `--src`/`--file` 给的写法（可能带 `docker://` 前缀）。规范化（`normalize_ref`，`scripts/sync.sh:536-539`）发生在之后、`process_one` 内（`scripts/sync.sh:1649`）。→ **过滤时看到的是未规范化的串**。
- **匹配方式**：`printf '%s\n' "$src" | grep -Eq -- "$re"`（`scripts/sync.sh:1224`、`1230`）。即 **部分匹配（子串搜索），不是全匹配**；ERE 方言。
- **能否组合**：可以。先 filter 后 exclude（`1224-1234` 顺序固定）。usage 明确写了这一点（`scripts/sync.sh:244`）。
- **参数可重复性**：`FILTER_REGEX="$2"` / `EXCLUDE_REGEX="$2"`（`scripts/sync.sh:424`、`427`）是**赋值不是追加**，重复传**后者覆盖前者**。所以「挑出 N 个失败镜像」只能写成**一条 or 正则**（`a|b|c`）。
- **合法性校验**：`validate_regex()` `scripts/sync.sh:1199-1209`，用 `grep` 退出码 2 判定语法错误并 `die`，在 `main()` 早期执行（`scripts/sync.sh:3317-3318`）。
- **副作用**：被筛掉的不删除，标 `EXCLUDE_REASONS[i]`，写一条 `excluded` 结果记录（`scripts/sync.sh:1811-1815`），并计入 `FILTERED_OUT_COUNT`（`1253`）。
- **全筛掉即失败**：`die "全部 N 个镜像都被筛掉了..."`（`scripts/sync.sh:1249-1251`）。
- **反模式的坑**：镜像引用里含大量正则元字符（`.`、`/` 安全，但 `+`、`?` 在 tag 里常见），拼 or 正则时必须转义；且部分匹配意味着 `nginx:1.27` 会同时命中 `library/nginx:1.27` 与 `nginx:1.27-alpine`。

#### 清单文件参数（`--file`）

- `SOURCE_FILES+=("$2")`（`scripts/sync.sh:421`）→ **可重复传入多个清单文件**。
- 解析：`collect_images()` `scripts/sync.sh:1158-1176`。每行一个引用；`#` 之后为行内注释被切掉（`line="${line%%#*}"`，`1168`）、去首尾空白；空行跳过；文件不存在 `die`。
- `--src` 支持逗号/分号/换行分隔（`split_images()` `scripts/sync.sh:1129-1136`），且可重复。
- 所有来源合并后**保序去重**（`scripts/sync.sh:1182-1191`，用 awk 兼容 bash 3.2）。

### 9. dry-run 的「真正会执行的参数数组」在哪里组装（已确认）

**注意区分两件事：**

| 目标 | 函数 | 行号 |
|---|---|---|
| skopeo 路径的真实 argv | `sync_via_skopeo` | `scripts/sync.sh:803-832` |
| regctl 路径的真实 argv | `sync_via_regctl` | `scripts/sync.sh:836-874` |
| OCI 中转推送的真实 argv | `sync_to_dest`（oci 分支） | `scripts/sync.sh:900-905` |
| dry-run 的**计划预览**（不是 argv） | `print_dry_run_plan` | `scripts/sync.sh:1501-1604` |

- `sync_via_skopeo`：`local -a cmd=(skopeo copy --all --retry-times "$MAX_RETRIES")`（`807`），按需追加 `--retry-delay` / TLS / `--src-authfile`，最后 `cmd+=("docker://${src}" "docker://${dest}")`（`824`）；dry-run 时打印 `"${cmd[*]}"`（`827`）。
- `sync_via_regctl`：`platform_args` 数组在 `853-858` 逐行组装，dry-run 打印**这个数组本身**（`867`），注释 `862-866` 明确解释了「不能拿输入复述」的原因（对应规范 `.trellis/spec/engine/bash-rules.md:68` 的 dry-run 铁律）。
- `print_dry_run_plan` 的自我定位（注释 `scripts/sync.sh:1495-1500`）：「这不是第二种 dry-run 实现：真实执行的参数仍由 `sync_via_skopeo` / `sync_via_regctl` 输出」。它只渲染 源→目标 映射 + 执行路径 + 平台策略。

**对重跑命令的可复用性判断**：重跑命令是一条 **`sync.sh` 调用**，不是 skopeo 调用，因此 `cmd` / `platform_args` 这两个数组**不可直接复用**。可复用/可参照的是：

- `resolve_dest_refs()` `scripts/sync.sh:620-639` —— 从源引用推导目标地址（重跑若只需列目标，用它）
- `print_dry_run_plan` 里的遍历骨架 `scripts/sync.sh:1543-1564` —— 「跳过被排除项 → normalize_ref → validate_ref → resolve_dest_refs → 逐目标」这套循环，正是「列出真正会跑的组合」的既有实现
- `main()` 的参数校验与「显式传入不生效告警」矩阵 `scripts/sync.sh:3350-3435` —— 重跑命令若带模式无关参数，必须走同一套告警，否则会违反「参数被接受却不生效比报错更危险」的项目原则（`.trellis/spec/engine/modes.md:38-40`）
- **不存在**任何「渲染一条 sync.sh 调用字符串」的函数（已确认：全文件无此类实现）。

### 10. `history.sh` 的下载重试模式（#97）（已确认）

组织方式在 `scripts/history.sh:283-341`，**内联在 `fetch_sync_history` 里，没有抽成独立函数**：

1. 主循环逐个 `gh run download`（`288`）。
2. 失败时分类：`classify_download_failure()`（`scripts/history.sh:234`）先按 gh 报错文案分，拿不准的用 `confirm_artifact_exists` 走 API 二次确认（`scripts/history.sh:300-318`）。
3. 收集待重试 id：`retry_ids+=("$id")`（`286` 声明，`304`、`316` 追加）；同时 `failed_downloads` 计数。
4. **主循环之后**做一轮批量重试（`327-341`）：
   ```bash
   if [[ ${#retry_ids[@]} -gt 0 ]]; then
     log_info "对 ${#retry_ids[@]} 次失败的下载重试（每次间隔 5 秒）..."
     local retried=0
     for id in "${retry_ids[@]}"; do
       sleep 5
       if gh run download "$id" -n "$REPORT_NAME" -D "${WORK_DIR}/${id}" >/dev/null 2>&1; then
         got=$((got + 1)); retried=$((retried + 1))
       fi
     done
     if [[ ${retried} -gt 0 ]]; then
       failed_downloads=$((failed_downloads - retried))
       log_info "重试挽回 ${retried} 次下载"
     fi
   fi
   ```
5. 设计约束写在注释 `321-326`：**只重试一轮**、固定 5 秒、**不做参数化**（理由：为极少调整的值增加表面积不划算，且新参数还得进「显式传入不生效」告警矩阵）。退避来自「先把其余项跑完」的批处理本身。
6. 重试后仍失败才 `die`，并给出 `--dir` 兜底（`348-353`）。

**是否已形成可复用的「挑出失败项 → 重试一轮」模式？**

- **语义层面：是。** 「主流程收集失败集 → 一轮批量重试 → 计数回填 → 仍失败才报错」这个骨架在同文件里已成型，且与「瞬时抖动」的定位一致（`docs/USAGE.md:81` 也把「上游抖动重跑就好」作为既有叙事）。
- **代码层面：否。** 没有抽出 `retry_failed_items` 之类的通用函数，`retry_ids` / `retried` / `failed_downloads` 都是 `fetch_sync_history` 的局部变量，无法被调用。
- 对同步场景的**关键不可移植点**：`history.sh` 重试的是**同一个幂等只读操作**（下载附件）；同步重跑是**写操作**，且 `sync.sh` 当前是「一次进程跑一遍全部镜像」，没有「只跑一个子集」的入口——只能靠 `--filter` 收窄。

## Caveats / Not Found

- `--filter` 部分匹配 + 单值覆盖这两条**未在 `docs/USAGE.md` 的 `--filter` 说明段落里显式写成「部分匹配」**（`docs/USAGE.md:471-484` 给的是示例）；但 `usage()` 的「作用于源镜像的完整引用，ERE 正则」（`scripts/sync.sh:241`）措辞容易被读成全匹配。**推测**这是重跑命令最容易踩的坑。
- 未查：`--filter` 匹配对象是规范化前还是后的串，是否有测试用例固化（只从代码路径推断为「规范化前」）。
- 未查：`history.sh` 是否也消费 `sync-report.json` 的 `images[].note`（从 `scripts/history.sh:389-400` 看只用了 `source`/`status`/`generated_at`，**推测**用不到 note）。
