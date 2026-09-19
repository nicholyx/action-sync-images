# 执行计划：write_report 的 json 改由 jq 构造

## 前置

```bash
git switch main && git pull
git switch -c fix/report-json-escape
./scripts/lint.sh          # 基线必须全绿
```

**本任务是本轮三个子任务里必须先做的那个**——`09-19-report-failure-note` 要往同一段 json 代码里加字段，必须等这里改完。

设计片段已实测通过（见 `design.md` 的「设计原型已验证」），照抄即可，不需要重新论证方案。

## 步骤

### 1. `task.py start`，状态转 `in_progress`

### 2. 先写断言，先看它红

```bash
rm -rf /tmp/rep103 && mkdir -p /tmp/rep103
./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
  --report-dir /tmp/rep103 --dry-run
jq -e . /tmp/rep103/sync-report.json      # 预期：jq: parse error（红）
```

不需要 registry、不需要网络、不需要凭证——dry-run 同样会走 `write_report`。

### 3. 记录修复前的类型基线

```bash
jq -r 'keys[] as $k | "\($k) \(.[$k]|type)"' /tmp/rep103/sync-report.json > /tmp/types-before.txt
jq -r '.images[] | to_entries[] | "\(.key) \(.value|type)"' /tmp/rep103/sync-report.json | sort -u >> /tmp/types-before.txt
cat /tmp/types-before.txt
```

**这一步必须在改代码之前做**，否则没有可比对的基线。

### 4. 改 `write_report()` 的 json 分支

按 `design.md` 的两段式：

- 每条镜像 `jq -n --arg ... --argjson seconds ...` 写一行 JSON Lines
- 顶层 `jq -n ... --slurpfile images` 组装
- 删除 `:3411-3423` 的手工转义注释与 `${RERUN_FILTER//\\/\\\\}`

注意 `design.md` 里标出的两个坑：`$ARGS.positional`（不是 `$ARGS`）、`rerun` 两个分支都要写全 `filter` / `not_rerunnable`。

### 5. 复跑，转绿

```bash
./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
  --report-dir /tmp/rep103 --dry-run
jq -e . /tmp/rep103/sync-report.json
jq -r '.images[0].source' /tmp/rep103/sync-report.json    # 必须逐字符等于 ngi"nx:1.0
```

### 6. 类型不变性回归（对应 PRD R2，不可省）

```bash
jq -r 'keys[] as $k | "\($k) \(.[$k]|type)"' /tmp/rep103/sync-report.json > /tmp/types-after.txt
jq -r '.images[] | to_entries[] | "\(.key) \(.value|type)"' /tmp/rep103/sync-report.json | sort -u >> /tmp/types-after.txt
diff /tmp/types-before.txt /tmp/types-after.txt && echo "类型无变化 ✓"
```

`diff` 输出必须为空。这是「修了转义但把 number 改成 string」的唯一防线——那种破坏会让 `history.sh` 的 `map(.total) | add` 直接崩，比原缺陷更严重。

### 7. 反斜杠场景

```bash
./scripts/sync.sh --src 'ngi\x:1.0' --dest registry.example.com/smoke \
  --report-dir /tmp/rep103b --dry-run
jq -e . /tmp/rep103b/sync-report.json
```

### 8. 零值语义（PRD R4）

```bash
jq -e '.rerun.images == []' /tmp/rep103/sync-report.json
jq -e '.rerun | has("filter") and has("not_rerunnable")' /tmp/rep103/sync-report.json
```

### 9. 补 CI 断言到 `smoke-test` job

dry-run 不需要额外依赖，该 job 已装 skopeo，直接加步骤。

### 10. macOS bash 3.2 跑一遍

```bash
/bin/bash --version     # 3.2.57
```

## 审查门

- [ ] `jq -e .` 通过，`source` 与输入逐字符相等
- [ ] 类型 diff 为空
- [ ] 反斜杠场景同样通过
- [ ] `rerun.images == []`，且 `filter` / `not_rerunnable` 都在
- [ ] `./scripts/lint.sh` 全绿；`shellcheck -x scripts/*.sh` 干净
- [ ] CI 全绿
- [ ] macOS bash 3.2 下跑过
- [ ] CHANGELOG `[Unreleased]` → `### 修复` 已加条目

## 合并后

**合并进 main 之后才能开 `09-19-report-failure-note`**（它要从合并后的 main 切分支）。

## 回滚

单函数改动，`git revert` 即可。无状态、无数据迁移。报告文件是一次性产物，已写出的历史文件无需处理。
