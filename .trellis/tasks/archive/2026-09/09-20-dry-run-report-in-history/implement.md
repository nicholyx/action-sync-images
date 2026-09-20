# 执行计划：把 dry-run 的报告从历史聚合里分出来

## 前置

```bash
git switch main && git pull
git switch -c fix/dry-run-report-in-history
./scripts/lint.sh          # 基线必须全绿
```

四处改动已实测复现（见 `design.md`），实现照做即可。

## 步骤

### 1. 先复现，先看到红

```bash
# ① dry-run 报告被当成真实运行
rm -rf /tmp/dryhist && mkdir -p /tmp/dryhist/run1
./scripts/sync.sh --src 'nginx:1.27,redis:7.2' --dest r.example.com/x \
  --dry-run --report-dir /tmp/dryhist/run1 >/dev/null 2>&1
./scripts/history.sh --dir /tmp/dryhist
# 预期（红）：共 1 次运行，累计同步 **2** 个镜像次：成功 2

# ② 连续失败计数被干跑清零
# 造一段历史：3 次 failed + 1 次 dry-run 的 success，看 count_consecutive_failures
# 是否被清零（可用 mock，或直接读函数语义验证）
```

### 2. 改 `scripts/sync.sh`（两处）

- `write_report()`：jq 构造加 `--argjson dry "$DRY_RUN"` 与 `dry_run:$dry`（位置见 design）
- `fetch_sync_history()`：jq 提取加 `and .dry_run != true`

**第二处不能漏**——它是「连续失败 N 次才通知」的数据源。

### 3. 改 `scripts/history.sh`（两处）

- `split_parsable_reports` → `classify_reports`（三分类，一次 jq 同时判「能不能解析」与「是不是干跑」）
- `main()`：改用三分类 + 告知跳过的份数 + 「没有可聚合的报告」分支说明具体原因

**4 处聚合函数一行不改**——过滤在文件列表层完成。

### 4. 复跑，转绿

```bash
./scripts/history.sh --dir /tmp/dryhist
# 预期（绿）：die，说明「1 份是 --dry-run 产出的」

# 混放：真实 fixture + dry-run
# 预期：只算真实的，并 log_info 跳过 1 份

# 兼容性回归：手写一份没有 dry_run 字段的旧报告
# 预期：正常聚合，与改动前一致
```

### 5. 改那条既有断言

CI 的「验证 history.sh 能从报告中聚合趋势」拿 dry-run 报告当夹具，本改动后必然失败。改为**手写 fixture**（与 `--check` 那几条测试同法）。

要点：**原目的（「history.sh 能聚合多份报告」）必须仍在覆盖**——断言「累计同步 N 个镜像次」与「列出失败过的镜像」都要保留，只是数据源从 dry-run 换成手写 JSON。

### 6. 补 CI 断言

- dry-run 报告被跳过 + 明确告知
- 混放时只算真实的
- 旧报告（无 `dry_run` 字段）照常聚合
- `fetch_sync_history` 的历史里不含干跑记录

用 `grep -qF` 匹配固定字符串。

### 7. 收尾

- CHANGELOG `[Unreleased]` → `### 修复`
- `./scripts/lint.sh`、`shellcheck -x scripts/*.sh`
- macOS 自带 bash 3.2 下跑一遍
- 全仓 U+FFFD 与控制字符扫描

## 审查门

- [ ] dry-run 报告不再进入趋势，且**明确告知**跳过了几份
- [ ] `fetch_sync_history` 不含干跑记录（连续失败计数不被清零）
- [ ] **旧报告（无 `dry_run` 字段）聚合结果与改动前逐字一致**（兼容性回归，不可省）
- [ ] 非 dry-run 报告聚合结果不变
- [ ] 4 处聚合函数确实一行未改（`git diff` 确认）
- [ ] 被改的既有断言仍覆盖原目的
- [ ] 新断言在本地先红后绿
- [ ] 退出码语义不变（含 `--check` 三条路径）
- [ ] `./scripts/lint.sh` 全绿；CI 全绿
- [ ] macOS bash 3.2 下跑过
- [ ] CHANGELOG 已加条目

## 回滚

四个落点可分别 revert。只回退 `sync.sh` 的报告字段时，消费方因字段缺失全部走 `real` 分支——行为回到改动前，不会留半截状态。
