# 执行计划：报告可信度收尾

父任务不实现代码。这份计划管的是三个子任务的**开工顺序、验收门与集成收口**。

## 前置：子任务就绪检查

开工前逐个确认，缺什么补什么——**没有 `design.md` 的子任务不得 `task.py start`**：

| 子任务 | prd.md | design.md | implement.md | 状态 |
| --- | --- | --- | --- | --- |
| `09-19-report-json-escape` | ✅ | ✅ | ✅ | 可开工 |
| `09-19-report-failure-note` | ✅ | ✅ | ✅ | 等 #103 合并 |
| `09-19-history-runlist-retry` | ✅ | ✅ | ✅ | 可与阶段一并行 |

三个子任务的 `design.md` 都含**已验证的设计片段**：`json-escape` 的 jq 构造、`failure-note` 的 `md_cell`、`runlist-retry` 的重试片段，都已抽出来实跑并记录结果。实现阶段照抄即可，不需要重新论证方案。

### 三个子任务共同的开工前检查

```bash
git switch main && git pull            # 从最新 main 切工作分支
./scripts/lint.sh                      # 基线必须全绿，红了先查原因
```

每个子任务用**独立分支 + 独立 PR**（父 PRD 的跨子任务验收要求）。分支名沿用仓库惯例，如 `fix/report-json-escape`。

---

## 阶段一：`report-json-escape`（#103）—— 必须最先

**开工门**：`design.md` 的设计原型已验证（该文件「设计原型已验证」一节），无需重新论证方案。

### 步骤

1. `python3 ./.trellis/scripts/task.py start <json-escape>` — 状态转 `in_progress`
2. **先写断言，先看它红**：

   ```bash
   rm -rf /tmp/rep103 && mkdir -p /tmp/rep103
   ./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
     --report-dir /tmp/rep103 --dry-run
   jq -e . /tmp/rep103/sync-report.json     # 预期：parse error（红）
   ```

3. 改 `write_report()` 的 json 分支，按该子任务 `design.md` 的两段式实现
4. 复跑上一条命令，`jq -e .` 通过（绿）
5. **类型不变性回归**：记录修复前后的

   ```bash
   jq -r 'keys[] as $k | "\($k) \(.[$k]|type)"' /tmp/rep103/sync-report.json
   jq -r '.images[] | to_entries[] | "\(.key) \(.value|type)"' /tmp/rep103/sync-report.json
   ```

   两次输出 `diff` 必须为空。**这一步不能省**——它直接对应 PRD 的 R2，是「修了转义但弄坏类型」的唯一防线
6. 反斜杠场景同样跑一遍（`--src 'ngi\x:1.0'`）
7. 补 CI 断言到 `smoke-test` job
8. macOS 本地跑一遍（默认 `/bin/bash` 即 3.2）

### 审查门

- [ ] `jq -e .` 通过，且 `source` 与输入**逐字符相等**
- [ ] 类型 diff 为空
- [ ] `rerun.images` 为空时是 `[]` 且 `filter` / `not_rerunnable` 都在
- [ ] `./scripts/lint.sh` 全绿；`shellcheck -x scripts/*.sh` 干净
- [ ] CI 全绿
- [ ] CHANGELOG `[Unreleased]` → `### 修复` 已加条目

**合并后才允许开阶段二。**

---

## 阶段二：`report-failure-note`（#102）—— 依赖阶段一

**开工门**：阶段一已合并进 main，且分支从**合并后**的 main 切出（否则会和 #103 的改动冲突）。

### 步骤

1. 先复现「有失败、无原因」：

   ```bash
   rm -rf /tmp/rep102 && mkdir -p /tmp/rep102
   ./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
     --report-dir /tmp/rep102 --dry-run
   jq -e '.images[0].note' /tmp/rep102/sync-report.json    # 预期：null（红）
   grep -c '说明' /tmp/rep102/sync-report.md               # 预期：0（红）
   ```

2. 按 `design.md` 改四个落点。**落点四（通知）的解析端最容易改错**——`cnt` 的取值从 `##*` 改成按段取，改完必须跑 mock 断言
3. `md_cell()` 的单测走函数抽取（CI `:1151-1152` 的手法）
4. 复跑第 1 步，两个断言转绿
5. 通知走 mock：既有断言（CI `:1105-1130`）必须仍然通过

### 审查门

- [ ] json `images[].note` 存在且为真实原因；成功项为 `""` 不是缺字段
- [ ] md 与 Step Summary 都出现「说明」列，空值显示 `—`
- [ ] 通知「失败详情」带出 note，且 `cnt` 解析未错位（mock 断言覆盖 note 空/非空两种输入）
- [ ] `history.sh --dir` / `--slowest` / `--check` 三条路径手动各跑一次
- [ ] `./scripts/lint.sh` 全绿；CI 全绿
- [ ] CHANGELOG `[Unreleased]` → `### 新增` 已加条目

---

## 阶段三：`history-runlist-retry`（#98）—— 与阶段一并行

**开工门**：`design.md` + `implement.md` 已就绪。核心技术难点（进程替换 `< <(...)` 拿不到退出码）已在该子任务 design 里给出解法——先落临时文件再读，且代码片段已在 mock 下跑过四个用例。

### 步骤

1. 复现：mock `gh run list` 返回非零 → 观察当前落到「没有取到任何运行记录」
2. 实现重试一轮
3. 断言覆盖四个用例：list 首次失败后成功 / 两次都失败 / 空列表 / 首次即成功
4. **空列表的文案必须逐字不变**（PRD R3）

### 审查门

- [ ] list 失败不再落到「没有取到任何运行记录」
- [ ] 空列表文案与改动前**逐字相同**
- [ ] 重试仍失败时文案指向网络与重试
- [ ] 退出码语义不变
- [ ] macOS bash 3.2 正常
- [ ] CI 全绿；CHANGELOG `[Unreleased]` → `### 修复` 已加条目

---

## 集成验收（三个 PR 全部合并后）

在 main 上跑：

```bash
git switch main && git pull
./scripts/lint.sh

# 1) 跨子任务的关键链路：history.sh 消费新格式报告
#
# --dir 是**递归**扫目录下全部 *.json、再按 JSON 字段过滤（history.sh:553），
# 所以报告直接放在子目录里即可，不需要重命名成 sync-report-aliyuncs.json——
# 重命名反而会让同一份报告被扫到两次，计数翻倍。
rm -rf /tmp/integ && mkdir -p /tmp/integ/run1
# 故意造一条失败记录，脚本返回 2 是预期内的；不兜住的话后面都不会执行
set +e
./scripts/sync.sh --src 'nginx:1.27,https://bad.example.com/x:1' --dest r.example.com/x \
  --dry-run --report-dir /tmp/integ/run1 >/dev/null 2>&1
set -e
./scripts/history.sh --dir /tmp/integ                      # 趋势
./scripts/history.sh --dir /tmp/integ --slowest 5          # 耗时排行
# 用 all(...) 而不是 `.images[] | select(...) | .note`：后者在 jq -e 下只看
# 最后一个输出值，只要有一条失败项带着 note 就通过——多个失败项时会漏报
#（本组场景恰好只有一个失败项，但它不该靠运气成立）
jq -e 'all(.images[] | select(.status=="failed"); .note != "")' /tmp/integ/run1/sync-report.json
jq -e '.rerun.images == []' /tmp/integ/run1/sync-report.json   # #103 的 R4

# 2) 带引号的镜像名同样过一遍 history.sh —— 两处改动的交叉点
rm -rf /tmp/integ2 && mkdir -p /tmp/integ2/run1
./scripts/sync.sh --src 'ngi"nx:1.0' --dest registry.example.com/smoke \
  --dry-run --report-dir /tmp/integ2/run1
./scripts/history.sh --dir /tmp/integ2                    # 不得报解析错

# 3) 全仓无 U+FFFD
# U+FFFD 的 UTF-8 字节序列是 ef bf bd；用字节转义写，避免检查命令自身就含该字符
git grep -nI $'\xef\xbf\xbd' -- . || echo "无 U+FFFD ✓"
```

第 2 组是**本轮唯一的真正交叉点**：`json-escape` 改转义、`failure-note` 改字段，两者叠加后仍要被 `history.sh` 正常消费。

### 这些断言已在当前代码上实测过（2026-09-19）

验收命令不能是「跑一下看看」——**恒真的断言等于没有断言**。三条关键命令的实际状态已确认：

| 断言 | 当前代码（未修复）下的实测结果 | 修复后应变为 |
| --- | --- | --- |
| 第 2 组 `history.sh --dir`（含引号镜像名） | **退出码 5**，输出 `jq: parse error: Invalid numeric literal at line 14, column 23` | 退出码 0，正常输出趋势 |
| 第 1 组 `all(.images[] \| select(.status=="failed"); .note != "")` | `false`，`jq -e` 退出码 **1**（红） | `true`，退出码 0 |
| 第 1 组 `.rerun.images == []` | `true`，退出码 0（已经是绿的） | 保持绿（回归保护，防 #103 改坏） |

第 2 组同时证实了缺陷的**真实影响链路**：坏 JSON 不是「理论上有问题」，而是让 `history.sh` 当场崩溃。

第 3 条是回归断言而非新功能断言——它现在就是绿的，作用是保证 `json-escape` 重构后不把零值语义改坏（PRD R4）。**它的绿灯不构成通过的证据，除非第 1、2 条同时由红转绿。**

### 集成验收门

- [ ] 三组命令全部通过
- [ ] 三个子任务各自的验收清单都已在各自 PR 里勾完
- [ ] CHANGELOG `[Unreleased]` 覆盖全部三项改动，分类正确
- [ ] README / docs 中若有描述报告字段的段落，与实际一致

---

## 发布

1. 按发布时 `[Unreleased]` 的**实际内容**确认版本号（当前 `[Unreleased]` 里已有一条未发版的重跑指引 #104，是本轮并入一起发还是单独切版本，届时按实际情况定）
2. 走既有的发布流程（`chore(release)` 提交 + tag + GitHub Release）
3. 发布后**保持里程碑 open**（仓库既有惯例）

## 回滚点

| 出问题的位置 | 回滚动作 |
| --- | --- |
| 阶段一发现类型被改坏 | revert 该 PR；类型破坏会同时影响 `history.sh`，优先处理 |
| 阶段二 note 破坏表格 | revert 该 PR；md 是给人看的，错列比缺列更糟 |
| 阶段三文案改动引入回归 | revert 该 PR；重试逻辑与分类是两个改动，必要时只回退文案部分 |
| 集成验收失败 | 定位到具体子任务，回滚该子任务后重跑集成验收 |

三个子任务无数据依赖，**任何单点回滚都不需要连带回滚**。
