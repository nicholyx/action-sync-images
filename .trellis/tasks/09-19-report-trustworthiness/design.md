# 设计：报告可信度的集成视角

父任务不实现代码。这份 design 管的是**三个子任务之间**的事：顺序为什么是这个顺序、它们共享哪些技术约束、集成点上谁会被谁影响。

单个子任务内部的技术设计在各自的 `design.md` 里。

## 本轮主线

三个缺口看着是「报告 bug」，共同点是**输出说的不是真的**：

| 子任务 | 输出说了什么 | 实际是什么 |
| --- | --- | --- |
| `report-json-escape` | 一份 `sync-report.json` | 镜像名含 `"` 时它是非法 JSON，且**零报错** |
| `report-failure-note` | `status: failed` | 只说了失败，没说为什么——而原因终端知道 |
| `history-runlist-retry` | 「没有取到任何运行记录」 | 网络失败冒充「数据不存在」 |

前两个是**报告说了假话**，第三个是**报错说了假话**。它们与已完成的 v1.11（失败被看见）、v1.14（瞬时失败被挽回）、v1.15（失败之后能重跑）是同一条线的收尾：先让失败可见，再让失败可挽回、可重跑，最后**让已经说出口的话可信**。

## 任务地图与顺序

```
09-19-report-trustworthiness（父，只做集成验收）
├── 09-19-report-json-escape      #103  ← 必须最先
├── 09-19-report-failure-note     #102  ← 依赖 json-escape
└── 09-19-history-runlist-retry   #98   ← 与另两个无交集，任意时间
```

### 为什么 `json-escape` 必须先于 `failure-note`

两者改的是 `write_report()` 的**同一段代码**（json 分支）：

- `json-escape` 换掉这段的**构造方式**（`printf` 拼接 → `jq -n --arg` + `--slurpfile`）
- `failure-note` 往这段**加一个字段**（`images[].note`）

顺序颠倒的代价：

| | 先加字段 | 先换构造 |
| --- | --- | --- |
| 改动次数 | 同一段写两遍 | 一次 |
| 断言次数 | 同一组断言写两遍 | 一次 |
| note 的转义 | 要手工处理（正是 #103 要消灭的做法） | jq 自动处理 |
| 中间态 | 加了 `note` 但 json 仍无转义——**缺陷窗口被拉长** | 无 |

最后一行是决定性的：`note` 的一条来源含动态内容（`diff_detail`），在裸 `printf` 下它和镜像名一样会让 JSON 变非法。先做 `json-escape` 等于**先把桶补好再接水**。

### 为什么 `runlist-retry` 可以独立

它只改 `scripts/history.sh` 的 `download_reports()`，与 `sync.sh` 的 `write_report()` 没有调用关系。唯一的间接联系是「`history.sh` 消费 `sync-report.json`」——但那是读，且 `json-escape` 承诺的字段类型不变（见该子任务 design 的契约表）就是为这条消费链准备的。

两者可以在同一时间开工、各自合并，互不阻塞。

## 共享技术约束

三个子任务都要遵守，违反任何一条都会在 CI 之外的地方坏掉：

1. **macOS 自带 bash 3.2**：空数组在 `set -u` 下展开 `"${arr[@]}"` 会报 `unbound variable`，CI 的 bash 5 不复现。必须包在长度判断里（既有教训见 `scripts/sync.sh:3067-3070`）
2. **不新增命令行参数**：三个子任务都不加。既有口径见 `scripts/history.sh:321-326` 的注释（「为极少调整的值增加表面积不划算」），新参数还要进「显式传入不生效告警」矩阵
3. **不新增依赖**：`jq`、`gh` 都是既有依赖
4. **转义一律交给 jq 或显式渲染函数**：新代码不得引入裸 `printf` 拼 JSON（`json-escape` 正是在还这笔债）
5. **断言必须先在本地复现过**：先看到红，再看到绿。三个子任务的复现路径都已确认不需要真实 registry 与网络（`sync.sh` 走 `--dry-run`，`history.sh` 走抽出函数 + mock `gh`）
6. **文案风格**：面向使用者、说清「怎么办」，不暴露内部实现（沿用既有错误文案的写法）

## 集成点：谁读谁

| 数据 | 生产方 | 消费方 | 本轮改动影响 |
| --- | --- | --- | --- |
| `sync-report.json` 顶层计数 | `write_report`（json-escape 改） | `history.sh:417-420` 累加 | 类型不变 → 无影响 |
| `sync-report.json` `images[]` | `write_report`（json-escape 改，failure-note 加 `note`） | `history.sh:389`、`:428` | 加字段是新增，旧消费方忽略 → 无影响 |
| `sync-report.md` 表格 | `write_report`（failure-note 加列） | 人看，无程序消费 | 加列 → 无影响 |
| `sync-report.json` 的获取 | `history.sh`（runlist-retry 改） | 内部 | 只改失败分类 → 无影响 |
| 通知正文 | `gather_alert_images` + `build_notify_text`（failure-note 改） | webhook | 加内容 → 无影响 |

**没有一条是「改了必须同步改消费方」的破坏性变更**——这是本轮能拆成三个独立 PR 的前提。唯一打破它的是 `json-escape` 若把字段类型从 number 改成 string（该子任务 design 已把这条锁死为契约）。

## 验收形态

三层，逐层收口：

1. **子任务层**：各自 PR 的 CI 全绿 + 该子任务 PRD 的验收清单
2. **集成层**（父任务负责）：三个 PR 全部合并进 main 之后，在 main 上跑一次合集验收——重点是「`history.sh` 能消费新格式的 `sync-report.json`」，这是唯一跨子任务的真实链路
3. **发布层**：CHANGELOG `[Unreleased]` 与实际改动一致；版本号按发布时 `[Unreleased]` 的实际内容定（详见 implement.md 的发布节）

## 发布形态

三个独立 PR 合并进 main，条目累积在 CHANGELOG 的 `[Unreleased]`。分类按 Keep a Changelog：

- `json-escape` → **修复**（静默产出坏数据）
- `runlist-retry` → **修复**（错误分类误导排查）
- `failure-note` → **新增**（报告信息丰度）

**版本号在发布时定，不预先写死。** 当前 `[Unreleased]` 里已有一条 v1.15 的重跑指引（#104，已合并未发版），本轮三个子任务合并后是并入它一起发布，还是单独切一个版本，取决于发布当时的实际状态——规划阶段硬编码版本号会在 `[Unreleased]` 累积内容变化时变成错的。

## 回滚

三个子任务之间无数据依赖、无状态迁移，**任意一个都可以独立 revert**：

| 回滚对象 | 影响面 |
| --- | --- |
| `json-escape` | `write_report` 的 json 分支退回裸拼接（缺陷回归，但功能不中断） |
| `failure-note` | 报告少一列、json 少一个字段（旧消费方本来就忽略它） |
| `runlist-retry` | `history.sh` 报错文案退回「没有取到任何运行记录」（仅文案与重试行为） |

报告文件是一次性产物，**不存在需要回滚的历史数据**。
