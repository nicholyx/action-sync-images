# implement —— history.sh 的 --check 趋势模式

## 前置

- 分支 `feat/check-trend`（自最新 main）
- 读 `.trellis/spec/engine/bash-rules.md` 全文（bash 3.2 硬规则每条真实踩过）
- 实现全部在 `scripts/history.sh`；不动 `scripts/sync.sh` 与 `.github/workflows/check-registry.yml`

## 有序清单

1. **jq 聚合原型先本地手搓验证**（不进脚本）：伪造 2 份最小 audit 报告，
   跑 design.md 的 jq 草案，确认分组/计数/排序正确后再落码
   ——jq 逻辑在脚本外先跑通，能省掉脚本里来回调的时间
2. `parse_args` 增加 `--check`：类型校验（audit / lock-audit 之外报错退出 1，
   信息说明 check-updates 不支持的口径原因）；`--check` 与 `--slowest` 互斥；
   `--check` 且未显式 `--report-name` 时 REPORT_NAME 切为 `check-report`
   （用「是否显式传过」的标志位判断，不要事后比较字符串）
3. `filter_by_check`：collect 之后立即过滤 `.check? == 类型`，
   0 份 → die（提示混放可能，退出 1）
4. `print_audit_trend`：总览段 → 表格（分组键 source+dest，列见 PRD）
   → excluded 统计行；bash 循环前判数组长度
5. `print_lock_trend`：同构（分组键 entry）；nodigest/marker 统计行
6. 退出码：趋势模式的 `any_fail` 等价物 = stale+missing（audit）/ drift（lock）；
   注意 `output="$(cmd)"` 的退出码陷阱（errexit 下先 `set +e` 再捕获）
7. usage 文本：--check 说明 + 两个示例；退出码段落补趋势语义
8. fixture 与 CI 断言：伪造报告 JSON 进临时目录，`--dir` 跑脚本；
   断言图标正文行 / 数值（禁裸状态词）；「故意失败」的命令包 set +e/-e
9. 文档：docs/USAGE.md（history.sh 用法 + 体检场景补一句趋势）、README 一句话；
   CHANGELOG `[Unreleased]` 条目——**插入前断言锚点行号 > [Unreleased] 行号
   且 < 下一个 `## [` 行号**（v1.8.0 教训）
10. 收尾检查：`./scripts/lint.sh`、macOS bash 3.2 实跑 fixture、
    全仓 U+FFFD 扫描、`zizmor` 不涉及（未改工作流则免）

## 验证命令

```bash
# 聚合原型（步骤 1）
jq -s '<design.md 草案>' /tmp/fixtures/audit-*.json

# 脚本行为（步骤 4-6，fixture 就位后）
./scripts/history.sh --check audit --dir /tmp/fixtures; echo "exit=$?"
./scripts/history.sh --check lock-audit --dir /tmp/fixtures; echo "exit=$?"
./scripts/history.sh --check check-updates --dir /tmp/fixtures; echo "exit=$?"   # 应为 1

# 现有行为不变（回归）
./scripts/history.sh --dir <同步报告目录>

# bash 3.2（本机默认 /bin/bash 即 3.2；确认脚本真的跑在它下面）
/bin/bash --version | head -1

# 全量检查
./scripts/lint.sh
```

## 风险点与回滚

- 风险 1：jq `group_by(.source + " " + .dest)` 若字段缺失（手写报告缺 dest）
  → 字符串拼接产生 "x null"。fixture 覆盖缺字段场景；脚本内过滤前先
  `select(.dest != null)`（audit 记录理应有 dest，缺失算数据异常，跳过并在 stderr 提示）
- 风险 2：`--check` 与下载模式的组合在本地无法端到端验证（需要真 Artifact）——
  下载函数零改动，CI 不造云端场景；发布后人工跑一次云端趋势验证
- 风险 3：CI 的 bash 是 5，`set -u` 空数组问题只在本地暴露——
  步骤 4/5 每个新数组遍历前都判长度，写完全文件 grep 一遍 `for .* in "\${`
  复查（skill 硬规则）
- 回滚点：单分支单 PR，revert 即回滚；sync.sh 与工作流零接触

## task.py start 前检查

- [ ] prd.md / design.md / implement.md 齐备且经用户批准
- [ ] implement.jsonl / check.jsonl 已填真实条目（bash-rules、modes、guides）
