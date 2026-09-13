# implement —— 趋势落盘与 History-Trend 工作流

## 前置

- 基线：main 含 #85（下载窗口修复）；分支 `feat/history-report`
- 读 `.trellis/spec/engine/bash-rules.md`、`.trellis/spec/workflows/index.md`

## 有序清单

1. **重构聚合为共享函数**：从 `print_audit_trend` / `print_lock_trend` 中抽出
   `audit_trend_rows` / `audit_trend_counts` / `lock_trend_rows` / `lock_trend_counts`；
   渲染函数改为调用它们；**先跑 fixture 确认渲染输出与重构前一致**（diff）
2. `parse_args` 加 `--report-dir`；产物名映射（sync-trend / audit-trend /
   lock-audit-trend / slowest-trend）
3. main 分发处：REPORT_DIR 非空时渲染经 tee 落 md；渲染后调
   `write_trend_report_files`（jq --argjson 组装 query/summary/rows → json）
4. fixture 验证四种模式：文件名正确、md 与 stdout 一致、json 字段齐全、
   rows 与表格行一致；回归（不带 --report-dir 输出不变）
5. 新建 `.github/workflows/history-trend.yml`（手工 Edit；新 `uses:` 若有
   ——upload-artifact 复用 check-registry.yml 已 pin 的 SHA）
6. ci.yml 加断言步骤（--check audit + --report-dir；断言 jq 字段与文件存在）
7. 文档：docs/USAGE.md 趋势章节 + README 一句；CHANGELOG（### 新增，
   锚点行号断言在 [Unreleased] 段内）
8. 收尾：`./scripts/lint.sh`、bash 3.2 实跑、U+FFFD 扫描、zizmor（本地无则 CI 把关）

## 验证命令

```bash
# 重构回归（步骤 1 后必须 diff 为空）
./scripts/history.sh --check audit --dir /tmp/trend-fixtures > /tmp/after.txt 2>/dev/null
diff <(git stash list >/dev/null; git show HEAD:scripts/history.sh > /tmp/old-history.sh && bash /tmp/old-history.sh --check audit --dir /tmp/trend-fixtures 2>/dev/null) /tmp/after.txt

# 落盘（步骤 3-4）
./scripts/history.sh --check audit --dir /tmp/trend-fixtures --report-dir /tmp/trend-out
ls /tmp/trend-out && jq -e '.generated_at and .query.mode == "audit" and .rows' /tmp/trend-out/audit-trend-report.json

# bash 3.2
/bin/bash ./scripts/history.sh --check audit --dir /tmp/trend-fixtures --report-dir /tmp/trend-out
```

## 风险点与回滚

- 风险 1：tee 引入管道后渲染函数的退出码语义——脚本已有 `pipefail`，
  但渲染函数内部的 `return 0`（空态提前返回）会覆盖……渲染函数的 return
  就是它的退出码，行为不变；退出码 2 的判定在渲染之外独立计算，不受影响
- 风险 2：`local rows` 捕获共享函数输出时，函数内 jq 失败被 `|| true` 掩盖 →
  不加 `|| true`，让 errexit 直接暴露（聚合输入由 main 保证非空）
- 风险 3：工作流里 stdout 写 Step Summary 与 tee 的组合——`tee` 到临时文件再
  cat 进 Summary，避免 process substitution 兼容性问题
- 回滚：单分支单 PR，revert 即回滚

## task.py start 前检查

- [ ] prd / design / implement 齐备（用户已预授权全自动执行，2026-09-14）
- [ ] implement.jsonl / check.jsonl 填真实条目
