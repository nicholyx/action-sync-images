# 执行计划：dry-run 的四处如实化

## 前置

```bash
git switch main && git pull
git switch -c fix/dry-run-honesty
./scripts/lint.sh          # 基线必须全绿
```

四条缺口都已实测复现（见 `design.md` 的「验证方式」表），实现只需照做守卫。

## 步骤

### 1. 先复现，先看到红

四个复现各一条命令，**都要跑一遍**（这是后面断言的立足点）：

```bash
# ① 耗时：mock date 强制跨秒（三个镜像是必要的，排行要求 >= 3 条）
mkdir -p /tmp/mockdate
cat > /tmp/mockdate/date <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  n=$(cat /tmp/mockdate/counter 2>/dev/null || echo 100)
  n=$((n + 1)); echo "$n" > /tmp/mockdate/counter; printf '%s\n' "$n"
else
  exec /bin/date "$@"
fi
EOF
chmod +x /tmp/mockdate/date
rm -f /tmp/mockdate/counter
PATH="/tmp/mockdate:$PATH" ./scripts/sync.sh \
  --src 'nginx:1.27,redis:7.2,alpine:3.20' --dest r.example.com/x \
  --dry-run --report-dir /tmp/dryrep3
jq -r '.images[].seconds' /tmp/dryrep3/sync-report.json   # 预期全是 1
grep -c '最慢的同步记录' /tmp/dryrep3/sync-report.md       # 预期 1（不该出现）

# ② 锁文件
rm -f /tmp/dry.lock
./scripts/sync.sh --src 'nginx:1.27' --dest r.example.com/x --dry-run --write-lock /tmp/dry.lock >/dev/null 2>&1
test -f /tmp/dry.lock && echo "写出了锁文件（红）"

# ③ 通知：起本地假 webhook，dry-run 应零请求
# ④ 目标 digest：mock skopeo 下 dest_digest 应被写入
```

### 2. 改 `scripts/sync.sh`

四处（`design.md` 有完整片段）：

| 位置 | 改动 |
| --- | --- |
| `process_one()`：`elapsed=$((end - start))` 之后 | dry-run 时 `elapsed=0` |
| `process_one()`：`status == "success"` 的 digest 段 | dry-run 时不查 `dest_digest` |
| `emit_summary()`：锁文件段之前 | 一条合并告警，列出 `--write-lock` / `--notify-webhook` |
| `emit_summary()`：锁文件段与通知段 | 各加 `"$DRY_RUN" != "true"` |

### 3. 复跑，转绿

同上四条，逐条确认行为反转。**特别注意 ①**：`seconds` 必须全 0 且 md 无排行——这条在修改前后都是「跑得出来」的（mock date 保证了确定性），不能只看「没报错」。

### 4. 非 dry-run 回归（R6，不可省）

去掉 `--dry-run` 跑同一组输入，四者行为必须与改动前**逐字一致**：

```bash
# 耗时：真实跑会有真实耗时（非 0），不能被守卫误伤
# 锁文件：照常写出
# 通知：照常发出
# 目标 digest：照常查询
```

用 mock skopeo 可以覆盖后两者；耗时那条用真实（非 mock）跑一次即可。

### 5. 改那条既有断言

CI 里通知断言用的 `--dry-run` 必须去掉（它只是「不联网就能失败」的夹具，不是断言对象）：

```bash
# 改前
./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
  --dry-run --notify-webhook http://127.0.0.1:8898/hook --notify-type generic
# 改后：去掉 --dry-run，引用换成必定失败且不联网的那种
./scripts/sync.sh --src 'https://bad.example.com/x:1' --dest registry.example.com/smoke \
  --notify-webhook http://127.0.0.1:8898/hook --notify-type generic
```

`smoke-test` job 已装 skopeo，所以不带 `--dry-run` 不会在启动检查处 die。改完**实跑该步骤**（原文抽出本地跑需要 mock skopeo）。

### 6. 补 CI 断言

覆盖四条绿线 + 一条告警文案，全部用 `grep -qF`：

- `seconds` 恒 0（配 mock date，否则断言在 CI 上恒绿）
- md 无「最慢的同步记录」
- `--write-lock` 不产出文件
- `--notify-webhook` 零请求（假 webhook 的捕获文件不存在）
- 告警里同时列出两个参数名

### 7. 收尾

- CHANGELOG `[Unreleased]` → **`### 变更`**（这是行为变更，不是纯修复——dry-run 下 `--write-lock` / `--notify-webhook` 从「生效」变成「不生效」）
- `./scripts/lint.sh`、`shellcheck -x scripts/*.sh`
- macOS 自带 bash 3.2 下跑一遍
- 全仓 U+FFFD 与控制字符扫描

## 审查门

- [ ] 四条缺口全部由红转绿，且**红是实测的**（不是「重跑碰运气」）
- [ ] 非 dry-run 的四者行为与改动前一致（R6）
- [ ] 告警只在参数真被传入时出现
- [ ] 既有通知断言改后仍覆盖「失败详情带出原因」（这是它原本的目的，不能改丢）
- [ ] 新断言在 CI 上**不会恒绿**（耗时的断言必须配 mock date）
- [ ] 退出码语义不变
- [ ] `./scripts/lint.sh` 全绿；CI 全绿
- [ ] macOS bash 3.2 下跑过
- [ ] CHANGELOG 用 `### 变更` 而非 `### 修复`

## 回滚

四处守卫互相独立。若仅耗时那条出问题，可单独回退（保留锁文件与通知的守卫）——目前未发现任何依赖 dry-run `seconds` 非 0 的地方。
