# design —— 趋势落盘与 History-Trend 工作流

## 边界

改 `scripts/history.sh`（输出层 + 聚合重构）、新增 `.github/workflows/history-trend.yml`、
ci.yml 加断言、文档。**不碰 sync.sh**。

## history.sh 侧

### 聚合口径单一来源（重构）

现状：`print_audit_trend` / `print_lock_trend` 内联跑统计与聚合的 jq。落盘需要
同一份数据（rows 进 json）——直接复制 jq 字符串会造成两处漂移。重构：

```
audit_trend_rows    <files...>   # stdout = 聚合行 JSON（现 print_audit_trend 里的 rows jq）
audit_trend_counts  <files...>   # stdout = {stale, missing, unknown, current, excluded, records} 汇总
lock_trend_rows     <files...>
lock_trend_counts   <files...>
```

渲染函数改为调用这些函数拿数据；落盘复用同函数。`--image` 过滤仍在渲染层做
（落盘保留全量 rows——过滤是视图，数据是数据）。

### --report-dir

- 参数：`--report-dir <目录>`，`REPORT_DIR=""`；`--slowest` 与 `--report-dir`
  可同用（slowest-trend-report）
- 产物命名：`{sync-trend|audit-trend|lock-audit-trend|slowest-trend}-report.{md,json}`
- md：渲染函数 stdout 经 `tee "$md_file"`（main 分发处包一层）——**tee + pipefail**
  保证渲染函数的退出码不被管道吞掉（errexit 语义与现状一致）
- json：落盘函数在渲染后调用，顶层：
  ```json
  {"generated_at": "...", "query": {"mode": "...", "image": "...", "limit": N,
   "workflow": "...", "top_failures": N}, "summary": {...}, "rows": [...]}
  ```
  `summary` / `rows` 调用与渲染相同的共享函数；`query` 记录本次查询参数（可复现）
- 写文件用 jq 组装（`--argjson`），转义交给 jq——与 `write_check_report_files`
  同一防坑约定

### 分发（main）

```
渲染:  print_xxx "${files[@]}" →（若 REPORT_DIR 非空）tee 进 md
落盘:  write_trend_report_files  →（若 REPORT_DIR 非空）json
退出码: 现有逻辑不动（渲染后独立计算）
```

## History-Trend 工作流

```yaml
name: History-Trend
on: workflow_dispatch
permissions: {contents: read, actions: read}   # gh run list/download 走 Actions API
inputs: mode (choice: sync/audit/lock-audit, default audit)
        limit (default 20), image (可选)
steps:
  checkout (persist-credentials: false)
  执行趋势查询:
    env: GH_TOKEN: ${{ github.token }}          # gh CLI 认证，经 env 中转
    run: |
      case "$MODE" in
        audit)      args=(--check audit) ;;
        lock-audit) args=(--check lock-audit) ;;
        sync)       args=() ;;                   # 同步趋势，--report-name 默认 sync-report-aliyuncs
      esac
      args+=(--report-dir ./trend --limit "$LIMIT")
      [[ -n "$IMAGE" ]] && args+=(--image "$IMAGE")
      ./scripts/history.sh "${args[@]}" | tee "$(mktemp)"   # 退出码 2 → 步骤红（pipefail）
      cat <stdout 缓存> >> "$GITHUB_STEP_SUMMARY"
  上传趋势报告:
    if: always()
    uses: actions/upload-artifact@<SHA> # v7
    with: {name: trend-report, path: trend/}
```

退出码 2 的语义：步骤要让它失败（与 Check-Registry 同策略：绿 = 没有需要处理的，
红 = 有，看 Summary 分辨）。

## 兼容性

- 不带 `--report-dir`：路径与现状逐字节一致（tee 只在 REPORT_DIR 非空时介入）
- bash 3.2：`tee`、管道、`--argjson` 全部安全；共享函数返回的 jq 输出经
  `local rows` / `local counts` 捕获——`output="$(cmd)"` 的退出码陷阱在此不适用
  （jq 输入由 main 保证非空，die 提前发生）

## 测试策略

- fixture 驱动（/tmp/trend-fixtures 既有模式）：四种模式 × `--report-dir` 断言
  文件名、md=stdout、json 四字段、rows 与表格行数一致
- CI 断言加在「验证 history.sh --check」步骤之后：audit 模式落盘 +
  `jq -e '.query.mode == "audit" and (.rows | length >= 0)'`
- 工作流实跑：合并后 `gh workflow run History-Trend -f mode=audit`（云端验证，
  同时产出第二份体检数据让趋势窗口从 1 → 2）

## 回滚

history.sh 单文件 + 新工作流文件 + ci.yml 断言段，revert 单提交即可；
无迁移状态。
