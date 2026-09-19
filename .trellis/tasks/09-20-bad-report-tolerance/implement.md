# 执行计划：让坏报告可见地跳过

## 前置

```bash
git switch main && git pull
git switch -c fix/bad-report-tolerance
./scripts/lint.sh          # 基线必须全绿
```

设计片段已实测通过（见 `design.md` 的「设计原型已验证」），照抄即可。

## 步骤

### 1. 先复现，先看到红

```bash
rm -rf /tmp/badhist && mkdir -p /tmp/badhist/run1 /tmp/badhist/run2
./scripts/sync.sh --src 'nginx:1.27' --dest r.example.com/x \
  --dry-run --report-dir /tmp/badhist/run1 >/dev/null 2>&1
# 一份像 v1.15.0 之前产出的坏报告（镜像名含引号）
printf '{\n "generated_at": "2026-09-01T00:00:00Z",\n "total": 1, "success": 0, "skipped": 0, "failed": 1,\n "images": [\n  {"source": "a"b:1", "dest": "d", "status": "failed", "seconds": 1}\n ]\n}\n' \
  > /tmp/badhist/run2/sync-report.json

set +e
out="$(./scripts/history.sh --dir /tmp/badhist 2>&1)"; rc=$?
set -e
echo "退出码=$rc"; echo "$out"
# 预期（红）：退出码 5，含 "jq: parse error"，且看不出是哪份文件坏了
```

### 2. 改 `scripts/history.sh`

- 新增 `split_parsable_reports()`（放在 `filter_by_check` 附近）
- `main()` 里在 `collect_reports` 之后、`filter_by_check` **之前**调用它
- `filter_by_check()` 的告警文案改为只管「类型不匹配」

### 3. 改 `scripts/sync.sh`

`fetch_sync_history()` 的解析循环改为「一次 jq + 判退出码」，坏文件计数并在循环后告警。

**保持 `join()` 的参数原样**（生产代码里是 jq 的字面转义，别改动它）。

### 4. 复跑，转绿

```bash
set +e
out="$(./scripts/history.sh --dir /tmp/badhist 2>&1)"; rc=$?
set -e
echo "退出码=$rc"; echo "$out"
# 预期（绿）：退出码 0，输出基于好那份的趋势 + 一行告警（含坏文件路径）
```

三个附加场景：

```bash
# 全部坏 -> 明确报错并指出首个文件
rm -rf /tmp/allbad && mkdir -p /tmp/allbad/run1
cp /tmp/badhist/run2/sync-report.json /tmp/allbad/run1/
set +e; ./scripts/history.sh --dir /tmp/allbad 2>&1; echo "退出码=$?"; set -e

# 全部好 -> 行为完全不变（回归）
set +e; ./scripts/history.sh --dir /tmp/badhist/run1; echo "退出码=$?"; set -e

# --check 模式：坏文件 + 非本类型的报告，两种跳过原因应分别可辨
```

### 5. 确认退出码语义未变

坏文件**不**触发退出码 2（PRD R4）：上面第一组 `--dir` 场景应返回 **0**——若返回 2 说明把「无法判定」错当成了「需要处理」，与 `history.sh:990-992` 的既有惯例冲突。

### 6. `fetch_sync_history` 走 mock

沿用 CI 里既有的 `download_reports` mock 骨架，往 mock 的下载目录里放一份坏报告，断言出现「无法解析」告警且计数正确。

### 7. 补 CI 断言

两条：`history.sh --dir` 的坏报告容错、`fetch_sync_history` 的告警。

**断言必须先在本地复现**（先红后绿），且匹配固定字符串用 `grep -qF`。

### 8. 跑既有断言

CI 里 history.sh 的三条（趋势聚合、`--check` 聚合、`--report-dir` 落盘）**原文抽出来本地跑**——本任务改了 `main()` 的文件组装，那三条正走这条路径。

### 9. 收尾

- CHANGELOG `[Unreleased]` → `### 修复`
- `./scripts/lint.sh`、`shellcheck -x scripts/*.sh`
- macOS 自带 bash 3.2 下跑一遍
- 全仓 U+FFFD **与控制字符**扫描（本任务的文档里出现过真实 U+001F，实现时若复制粘贴代码片段要留意）

## 审查门

- [ ] 一份好 + 一份坏 → 退出码 0，输出基于好那份，另有一行告警
- [ ] 告警能定位到**具体文件**
- [ ] 全部坏 → 明确报错 + 首个坏文件路径，不是裸的 jq parse error
- [ ] 退出码语义不变（坏文件不触发 2）
- [ ] `filter_by_check` 的两种跳过原因可分
- [ ] `fetch_sync_history` 的告警含「连续失败次数可能偏小」这类后果说明
- [ ] 既有三条 history.sh 断言实跑通过
- [ ] 新增断言在本地先红后绿
- [ ] `./scripts/lint.sh` 全绿；CI 全绿
- [ ] macOS bash 3.2 下跑过
- [ ] CHANGELOG 已加条目

## 回滚

两个文件各自的改动互相独立。若 `history.sh` 的预检引入回归，可只 revert 它、保留 `sync.sh` 的告警（后者是纯增益，不改变任何成功路径的行为）。
