# 设计：把 dry-run 的报告从历史聚合里分出来

## 边界

| 文件 | 改动 |
| --- | --- |
| `scripts/sync.sh` | 报告顶层加 `dry_run` 字段；`fetch_sync_history` 的提取加过滤 |
| `scripts/history.sh` | 把 v1.15.1 的 `split_parsable_reports` 扩成三分类；`main()` 的「没有可聚合报告」分支据此改进 |
| `.github/workflows/ci.yml` | 改一条既有断言（它拿 dry-run 报告当夹具）；新增断言 |
| `CHANGELOG.md` | `[Unreleased]` → `### 修复` |

**不碰** 4 处聚合函数（`aggregate_by_image` / `sync_trend_counts` / `slowest_trend_rows` / 退出码判断）——过滤在文件列表层完成，它们一行不改。

## 核心决策：过滤放在「准备文件列表」层，不是「聚合」层

`history.sh` 有 4 处聚合，每处都要读 `images[]` 或顶层计数。逐个加 `select(.dry_run != true)` 有四个问题：四处要改、容易漏、`sync_trend_counts` 的 `runs: length` 得改成过滤后的计数（不是简单加 select）、以及「跳过了几份」没有自然的落点。

放在文件列表层则：**一处分类，四处受益，告知也在一处**——这与 v1.15.1 处理坏报告的落点完全一致。

而且**不需要额外开销**：v1.15.1 已经加了一个逐文件预检（`split_parsable_reports`，用 `jq -e .` 判能不能解析）。把判定扩成一个三分类，仍是**每个文件一次 jq 调用**——不是两次。

## 落点一：`sync.sh` 的报告加字段

在 `write_report()` 的 jq 构造里，`--argjson dry "$DRY_RUN"`，字段放在 `generated_at` 之后：

```bash
  jq -n --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg dest "${DEST_EXACT:-${DEST_REGISTRIES[*]}}" \
    --argjson dry "$DRY_RUN" \
    --argjson strip "$STRIP_ATTESTATION" \
    ...
    '{generated_at:$at, dry_run:$dry, dest_registry:$dest, strip_attestation:$strip,
      total:$total, ..., rerun:$rerun, images:$images}' > "$json"
```

`$DRY_RUN` 的字面量是 `true` / `false`，`--argjson` 正好产出 boolean（与既有的 `strip_attestation` 同法）。

字段位置放在 `generated_at` 之后：它是**关于这份报告本身**的元信息（「这份报告是怎么来的」），与紧随其后的 `dest_registry` 同属顶层描述，和计数字段分开。

## 落点二：`history.sh` 的三分类

把 `split_parsable_reports` 改名为 `classify_reports`，一次 jq 同时回答两个问题：

```bash
# 把报告文件分成三类，结果经全局变量传出：
#   PARSABLE_REPORTS   —— 能解析、且是真实运行（参与聚合）
#   DRY_RUN_REPORTS    —— 能解析、但是干跑产出的（不参与聚合，但要告知）
#   UNPARSABLE_REPORTS —— 解析不了（不参与聚合，且要告警）
#
# 为什么干跑的报告不能参与聚合：它描述的是「计划」，不是「已发生的事」。
# 混进趋势会让「累计同步 N 个镜像次」虚高；更严重的是清零连续失败计数——
# count_consecutive_failures 遇到任何非 failed 记录即清零，一次干跑的 success
# 足以压掉一个真实存在过的失败序列本该触发的告警。
#
# .dry_run 缺失（v1.16.0 之前的报告）走 else 分支，视为真实运行：
# 升级不该让历史数据失效。
#
# 结果走全局变量：本文件对「命令替换是子 shell、赋值传不回父进程」有过多轮教训。
classify_reports() {
  PARSABLE_REPORTS=()
  DRY_RUN_REPORTS=()
  UNPARSABLE_REPORTS=()

  local f verdict
  for f in "$@"; do
    if verdict="$(jq -r 'if .dry_run == true then "dry" else "real" end' "$f" 2>/dev/null)"; then
      if [[ "$verdict" == "dry" ]]; then
        DRY_RUN_REPORTS+=("$f")
      else
        PARSABLE_REPORTS+=("$f")
      fi
    else
      UNPARSABLE_REPORTS+=("$f")
    fi
  done
}
```

`if verdict="$(jq …)"` 判的是 **jq 的退出码**（命令替换的退出码就是命令的）——解析不了时非零，落进 `else`。与 v1.15.1 的判据一致。

## 落点三：`main()` 的告知与「无可聚合」分支

```bash
  classify_reports "${files[@]}"
  files=()
  if [[ ${#PARSABLE_REPORTS[@]} -gt 0 ]]; then
    files=("${PARSABLE_REPORTS[@]}")
  fi

  # 干跑的报告被跳过了要说一声——它们不是「坏」，只是不属于真实历史，
  # 不说的话使用者会对不上数（本仓库的既有原则：排除的东西必须可见）
  if [[ ${#DRY_RUN_REPORTS[@]} -gt 0 ]]; then
    log_info "跳过 ${#DRY_RUN_REPORTS[@]} 份 --dry-run 产出的报告（它们描述的是计划，不是已发生的同步）"
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    # 三种「空」的原因不同，说清楚是哪种——原来只有「没有 JSON 报告」与
    # 「没有一份能解析」两种说法，现在多了一种「能解析但都是干跑」
    local empty_detail=""
    if [[ ${#DRY_RUN_REPORTS[@]} -gt 0 ]]; then
      empty_detail+="${#DRY_RUN_REPORTS[@]} 份是 --dry-run 产出的"
    fi
    if [[ ${#UNPARSABLE_REPORTS[@]} -gt 0 ]]; then
      [[ -n "$empty_detail" ]] && empty_detail+="，"
      empty_detail+="${#UNPARSABLE_REPORTS[@]} 份无法解析（首个：${UNPARSABLE_REPORTS[0]}）"
    fi
    die "没有可聚合的报告：${empty_detail}"
  fi
```

三分类让「为什么没有可聚合的报告」这个问题的答案精确了：原来混合场景（1 份坏 + 1 份干跑）只会说「没有一份能解析」，而其中一份其实**能**解析。

## 落点四：`sync.sh` 的 `fetch_sync_history`

```bash
    if out="$(jq -r 'select(.images != null and .dry_run != true) | .generated_at as $at
                       | .images[] | [$at, .source, .status] | join("\u001f")' "$f" 2>/dev/null)"; then
```

只加一个条件。**这一处不能漏**：它是「连续失败 N 次才通知」的数据源，漏了的话前面三处做得再好，告警仍会被一次干跑清零。

## 测试影响：一条既有断言必须改

CI 的「验证 history.sh 能从报告中聚合趋势」**拿 dry-run 报告当夹具**（`--dry-run --report-dir` 造两份），断言「累计同步 **4** 个镜像次」。本改动后那两份会被跳过，断言必然失败。

它原本的目的是「history.sh 能聚合多份报告」，与报告是不是干跑产出的无关。改为**手写 fixture**（与 `--check` 那几条测试同法，那里一直是手写 JSON）：

```bash
cat > "${work}/run1/sync-report.json" <<'JSON'
{"generated_at":"2026-09-01T01:00:00Z","total":2,"success":2,"skipped":0,"failed":0,
 "images":[{"source":"nginx:1.27","dest":"r/x/nginx:1.27","status":"success","seconds":3}, …]}
JSON
```

顺带的好处：夹具**不依赖 dry-run 的语义**，将来再改 dry-run 也不会连带破这条测试。且不再需要 `set +e` 去兜「故意失败」的退出码 2——手写一份带 `failed` 的 fixture 更直接。

## 兼容性

| 影响面 | 说明 |
| --- | --- |
| 旧报告（无 `dry_run`） | 视为真实运行，聚合结果不变（R5） |
| 新报告（有 `dry_run: false`） | 同上——真实同步的报告行为零变化（R6） |
| `--check` / `--audit*` 报告 | 没有 `dry_run` 字段，走 `real` 分支，行为不变 |
| 退出码 | 不变。`--dir` 下全是干跑报告时 `die`（1），与「没有 JSON 报告」同口径 |
| `fetch_sync_history` | 干跑记录不再进入历史文件；全被跳过时 `out_file` 为空 → 走既有「无法获取历史报告」分支（调用方已告警），行为一致 |
| bash 3.2 | 三分类沿用既有的长度判断包裹展开的写法 |

## 回滚

四个落点可分别 revert。若只回退 `sync.sh` 的报告字段（不写 `dry_run`），消费方的过滤会因字段缺失而全部走 `real` 分支——行为回到改动前，不会留下半截状态。

## 验证方式（先红后绿）

| 场景 | 红（改动前） | 绿（改动后） |
| --- | --- | --- |
| `--dir` 下只有 dry-run 报告 | 「共 1 次运行，累计同步 **2** 个镜像次：成功 2」 | `die`，说明「1 份是 --dry-run 产出的」 |
| 混放（真实 fixture + dry-run） | 两者都算进去 | 只算真实的，并 log_info 跳过 1 份 |
| 旧报告（手写，无 `dry_run` 字段） | 正常聚合 | **完全不变**（兼容性回归） |
| `fetch_sync_history`（mock） | 干跑记录混进历史 | 历史里不含它 |

**关键的一条**：`count_consecutive_failures` 的场景——历史里有 3 次 failed + 1 次 dry-run 的 success，改动前计数被清零，改动后仍为 3。
