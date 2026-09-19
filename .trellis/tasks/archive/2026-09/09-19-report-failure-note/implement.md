# 执行计划：把 R_NOTE 带进报告、Summary 与通知

## 前置

**必须先等 `09-19-report-json-escape` 合并进 main**，然后从**合并后**的 main 切分支：

```bash
git switch main && git pull
git switch -c feat/report-failure-note
./scripts/lint.sh          # 基线必须全绿

# 确认前置已就位：json 已是 jq 构造（否则 note 里的引号会产出坏 JSON）
grep -q 'slurpfile' scripts/sync.sh && echo "前置就绪 ✓"
```

依赖理由：两者改 `write_report()` 的同一段代码。先换构造方式，再加字段——反过来会改两遍、断言写两遍，且中间态里 `note` 在裸 `printf` 下无转义。

## 步骤

### 1. `task.py start`

### 2. 先写断言，先看它红

```bash
rm -rf /tmp/rep102 && mkdir -p /tmp/rep102
./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
  --report-dir /tmp/rep102 --dry-run

jq -e '.images[0].note' /tmp/rep102/sync-report.json   # 预期：null，jq -e 退出码 1（红）
grep -c '说明' /tmp/rep102/sync-report.md              # 预期：0（红）
```

`nginx` 缺 tag，会被 `validate_ref` 判为无效并记为 failed——这正好造出一条**有失败、无原因**的记录，不需要真实 registry 与网络。

### 3. 按 `design.md` 改四个落点

| 落点 | 改动 |
| --- | --- |
| json | records 循环加 `--arg note "${R_NOTE[$i]}"` |
| md 表格 | 表头 + 数据行加「说明」列（走 `md_cell`） |
| Step Summary | 同上 |
| 通知 | `gather_alert_images` 多输出一段 + `send_notification` 按段解析 |

新增 `md_cell()` 纯函数。

**最容易改错的是通知的解析端**：`cnt` 的取值要从 `##*`（取最后一段）改成 `%%*`（取第二段）——不改的话 `cnt` 会拿到 note 文本，`[[ "$cnt" -gt 1 ]]` 静默走错分支。改完必须跑 mock 断言。

### 4. `md_cell` 单测

用 CI 既有的函数抽取手法（`:1151-1152`）：

```bash
sed -n '/^md_cell()/,/^}/p' scripts/sync.sh > /tmp/cell.sh
```

断言覆盖：含 `|` 的输入产出 `\|`、含换行的输入产出单行、两者都含时不产生额外列、空串返回空串。实测结果见 `design.md`，可直接作为期望值。

**不要**试图构造一个真能产出含 `|` 的 note 的同步场景——那个场景造不出来，这也是 `md_cell` 被抽成纯函数的原因。

### 5. 复跑第 2 步，两个断言转绿

```bash
jq -e '.images[].note | startswith("镜像引用格式错误")' /tmp/rep102/sync-report.json
jq -e '.images[0] | has("note")' /tmp/rep102/sync-report.json      # 字段存在性
grep -q '| 说明 |' /tmp/rep102/sync-report.md
grep -q '镜像引用格式错误' /tmp/rep102/sync-report.md              # 真的写了原因
```

### 6. Step Summary

```bash
summary="$(mktemp)"
GITHUB_STEP_SUMMARY="$summary" ./scripts/sync.sh --src 'nginx' \
  --dest registry.example.com/smoke --dry-run >/dev/null 2>&1 || true
grep -q '说明' "$summary"
```

### 7. 通知走 mock

扩展 CI `:1085-1130` 那套骨架。**必须覆盖两种输入**：

- note 非空 → 输出行带出 note
- note 为空 → 输出行不带尾巴（不能留一个孤零零的冒号）

同时确认 `cnt` 解析未错位（阈值判断仍然按连续次数走）。

### 8. 既有断言不破

CI `:1105-1130` 的 `gather_alert_images` 断言用的是子串匹配（`grep -q "$(printf 'a.example.com/x:1\x1f3')"`），新字段追加在末段之后不影响命中——但**必须实跑确认**，不能靠推理。

### 9. 消费方回归

```bash
rm -rf /tmp/rep102b && mkdir -p /tmp/rep102b/run1
set +e
./scripts/sync.sh --src 'nginx:1.27,https://bad.example.com/x:1' --dest r.example.com/x \
  --dry-run --report-dir /tmp/rep102b/run1 >/dev/null 2>&1
set -e
./scripts/history.sh --dir /tmp/rep102b            # 趋势
./scripts/history.sh --dir /tmp/rep102b --slowest 5
```

加到「说明」列之后，`history.sh` 的三条路径都必须正常。

## 审查门

- [ ] json `images[].note` 为真实原因；成功项为 `""`（字段存在，不是缺字段）
- [ ] md 与 Step Summary 都有「说明」列，空值显示 `—`
- [ ] 通知带出 note，且 `cnt` 解析未错位（空/非空两种输入都测过）
- [ ] 既有 `gather_alert_images` 断言实跑通过
- [ ] `history.sh --dir` / `--slowest` / `--check` 三条路径手动跑过
- [ ] `md_cell` 单测覆盖四类输入
- [ ] `./scripts/lint.sh` 全绿；CI 全绿
- [ ] macOS bash 3.2 下跑过
- [ ] CHANGELOG `[Unreleased]` → `### 新增` 已加条目

## 回滚

四个落点互相独立，可整 PR revert。json 里多出的 `note` 是**新增字段**，旧消费方一律忽略，不存在「必须同时回滚」的问题。
