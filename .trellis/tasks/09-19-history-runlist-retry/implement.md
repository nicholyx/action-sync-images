# 执行计划：gh run list 的失败分类与重试

## 前置

```bash
git switch main && git pull
git switch -c fix/history-runlist-retry
./scripts/lint.sh          # 基线必须全绿
```

与 `09-19-report-json-escape` / `09-19-report-failure-note` 无代码依赖，**可以与之并行**，但分支要从最新 main 切、各自独立 PR。

## 步骤

### 1. 先取空列表文案的基线（用例 C 的断言要用）

```bash
sed -n '281p' scripts/history.sh     # die "没有取到任何运行记录。…"
```

把这串文案**原样**记下来。**不要**凭记忆重写——那会让「文案不变」的断言失去意义（断言变成了「我改完之后的文案」，恒真）。

### 2. 先写断言，先看它红

CI `:1202-1290` 已有「抽出 `download_reports` 整体 + mock `gh`」的骨架（`gh()` mock 已经处理 `run list`，`sleep` 已被 mock 成写文件计数）。**扩展它**，不要另起一套：

- 给 mock 的 `run list` 分支加一个行为开关（如 `GH_LIST_BEHAVIOR`），支持 `fail-then-ok` / `always-fail` / `empty` / `ok`
- 用例 A（重试成功）、B（两次都失败）、C（空列表不重试）、D（首次即成功）见 `design.md` 的用例表

先只加用例 B 与 C，在当前代码上跑——**两条都应该红**（当前代码下 list 失败会落到「没有取到任何运行记录」，B 的文案断言不成立；C 恰好会绿，因为它就是现状）。

> 若 C 一开始就是绿的：这正常，它是**回归断言**，作用是守住「空列表文案不被改动」。它的绿灯不构成通过的证据，除非 B 由红转绿。

### 3. 实现

按 `design.md` 的代码片段改 `download_reports()` 的运行列表获取段。**改动前后都必须保持 `run_ids` 的消费方式不变**（仍是逐行读）。

设计片段已在 mock 下跑过四个用例，直接照抄，注意别丢 `head -n1`（否则报错信息会变成临时文件路径）。

### 4. 复跑断言，四条全绿

```bash
bash /tmp/test-runlist.sh        # 断言脚本（与 CI 步骤同一份内容）
```

### 5. 本地人工确认

```bash
# 真实环境下确认没有把正常路径改坏
./scripts/history.sh --dir <任一本地报告目录>     # 走 --dir，完全不碰 gh
# 有 gh 环境时再跑一次真实 list 路径，确认正常获取
```

### 6. macOS bash 3.2

```bash
/bin/bash --version     # 3.2.57
```

本次改动无空数组展开、无 `wait -n`、无关联数组，但仍要在 3.2 下跑一遍断言脚本。

## 审查门

- [ ] 用例 A：重试成功，流程继续，日志能看出「重试过一次」，`sleep` = 1
- [ ] 用例 B：退出码 1，文案指向**网络与重试**，且含 gh 的真实错误文本（不是临时文件路径）
- [ ] 用例 C：空列表文案与基线的**逐字相同**，且 `sleep` = 0（不重试）
- [ ] 用例 D：不重试，`sleep` = 0
- [ ] 退出码语义不变（`die` 仍是 1）
- [ ] `--limit` / `--workflow` 的组装未被动过
- [ ] `./scripts/lint.sh` 全绿；`shellcheck -x scripts/*.sh` 干净
- [ ] CI 全绿
- [ ] CHANGELOG `[Unreleased]` → `### 修复` 已加条目
- [ ] macOS bash 3.2 下跑过

## 回滚

单函数内的一段改动，`git revert` 即回到旧行为。无状态、无数据迁移。

若断言在合并后才暴露出问题（例如某类环境 gh 的退出码行为与预期不同），**优先回退整段**而不是现场加特例——本任务的全部价值在于「如实区分失败与空列表」，加特例会让这个区分重新变得不可信。
