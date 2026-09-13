# 趋势结果落盘并上 Actions 页面（--report-dir + History-Trend 工作流）

## Goal

把 v1.9.0 的趋势查询接到项目的既有「结果消费」机制上：`history.sh` 支持
`--report-dir` 落盘（md 与 stdout 同源 + json 机器可读），新增 `History-Trend`
手动工作流——在 Actions 页面就能看趋势、留档、按红绿一眼判断，不再要求
装 CLI。对应 GitHub Issue [#84](https://github.com/nicholyx/action-sync-images/issues/84)；
里程碑 v1.10.0（趋势可用性）。前置缺陷修复（下载窗口按工作流定位）已在
[#85](https://github.com/nicholyx/action-sync-images/pull/85) 合并。

背景：v1.7.0 为体检补过同一断层（「检查结果只在日志里，消费只能截图」→
`--report-dir` + Check-Registry 工作流）；趋势查询刚做完就处在同样的位置，
学费不该交两次。

## 已定决策

1. **`--report-dir` 支持全部查询模式**，产物按模式命名：
   默认 → `sync-trend-report`、`--check audit` → `audit-trend-report`、
   `--check lock-audit` → `lock-audit-trend-report`、`--slowest` → `slowest-trend-report`
2. **md 与 stdout 同源**（渲染输出 tee 进文件），json 机器可读：
   `{generated_at, query, summary, rows}`——`rows` 是聚合行（与 md 表格同一数据），
   `query` 记录查询参数（可复现），不引入新的存储
3. **聚合口径单一来源**：渲染函数与落盘共用同一组 jq 聚合函数
   （先重构出 `*_trend_rows` / `*_trend_counts`），不复制 jq 字符串——两份
   漂移一个先例就会烧掉同源约定
4. **工作流权限最小化**：`contents: read` + `actions: read`（`gh run list/download`
   走 Actions API）；`GH_TOKEN: ${{ github.token }}` 经 env 注入
5. **退出码 2 定红绿**：与体检工作流同一呈现策略（绿 = 窗口内没有需要处理的记录）

## Requirements

1. `history.sh --report-dir <目录>`：产出 `.md`（stdout 同源）与 `.json`
   （generated_at / query / summary / rows）两份文件；不传时行为与现状一致
2. 渲染函数的聚合逻辑重构为共享函数，渲染与落盘同源
3. 新增 `.github/workflows/history-trend.yml`：`workflow_dispatch`，
   输入 `mode`（sync / audit / lock-audit，默认 audit）、`limit`（默认 20）、
   `image`（可选，精确过滤）；运行 history.sh → stdout 写 Step Summary →
   上传 `trend-report` Artifact（`if: always()`，30 天）；无任何自动触发器
4. CI 断言：`--report-dir` 落盘文件存在、JSON 可被 jq 解析、
   `generated_at` / `query.mode` / `rows` 字段存在
5. 文档：docs/USAGE.md 趋势章节补「在 Actions 页面看趋势」；README 一句话；
   CHANGELOG `[Unreleased]`（### 新增）

## Acceptance Criteria

- [ ] `--check audit --dir fixture --report-dir <目录>`：md 与 json 落盘，
      md 内容与 stdout 一致，json 顶层四字段齐全且 `rows` 与表格数据一致
- [ ] 四种查询模式各自产出正确的文件名（sync-trend / audit-trend /
      lock-audit-trend / slowest-trend）
- [ ] 不带 `--report-dir` 时行为逐字节不变（回归）
- [ ] History-Trend 工作流：mode=audit 实跑成功（绿或红都是合法结论——
      检查**有没有结论**，不是结论是什么），Step Summary 含趋势表，
      Artifact `trend-report` 存在
- [ ] CI 断言本地复现；断言匹配字段名与数值，不匹配裸状态词
- [ ] zizmor 基线 0 findings；新增 `uses:` pin 到 SHA + 注释保留版本号；
      checkout `persist-credentials: false` 不回退
- [ ] `./scripts/lint.sh` 全绿；macOS bash 3.2 实跑；U+FFFD 全仓扫描
- [ ] 文档与 CHANGELOG 就位

## Out of Scope

- 给工作流加 schedule（红线）；趋势的 `--state` 过滤与 `--latest` 窗口
  （盘点候选 6，留下一轮）；`--notify-webhook` 接入趋势（体检通知语义
  在趋势上不成立——趋势是回顾性视图，不是需要即时打扰的信号）

## Notes

- bash 3.2 硬规则全适用；tee + pipefail 组合保证渲染退出码不被吞
- 工作流实跑验证在本任务合并到 main 之后进行（workflow_dispatch 显式触发）
