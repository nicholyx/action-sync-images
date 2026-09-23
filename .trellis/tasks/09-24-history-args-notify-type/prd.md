# 补 history.sh 参数与 notify-type 的断言（#137 零依赖组）

对应 Issue：nicholyx/action-sync-images#137 的「零依赖（纯参数）」组

## Goal

三块**零依赖**（不需要网络、容器、skopeo）的覆盖缺口。它们都在 `#137` 里列着，
本任务只做这一组——其余组依赖 stub skopeo / regctl / 容器，另开任务。

## 要实现覆盖的三块

### ① `--history-artifact` 走 `parse_args` 的通路

它的**本体**覆盖很扎实（`ci.yml` 里 `fetch_sync_history` 的坏报告处理、dry-run 报告
不进历史、连续失败计数不被干跑清零）。缺的只是**CLI 值有没有真的传进全局变量**。

**后果**：CLI 值没传进去时会去下载**默认值** `sync-report-aliyuncs`——于是连续失败
计数在**错误的历史集合**上计算，次数偏小，把该响的告警压掉。

**断言**：传 `--history-artifact X` 后，告警文案里带出 `X`（`sync.sh` 的文案已含
`--history-artifact「${HISTORY_ARTIFACT}」`）。

### ② `history.sh` 的四个参数

| 参数 | 要覆盖什么 |
| --- | --- |
| `--top-failures` | **有一条特例分支**：后面若是另一个选项或结尾，退回默认值（`history.sh:155-161`）——这种「可选参数」最易被改坏，且坏掉是静默的（悄悄用默认值） |
| `--limit` | 默认 20，决定趋势**窗口大小**。窗口是 `history.sh` 的核心语义，大量断言围绕「窗口内全绿 → 退出码 0」构建，唯独**窗口大小的来源**没测 |
| `--report-name` | 与 `--workflow` 一起用于 `--check` 模式定位远端 artifact |
| `--workflow` | 同上 |

**另**：`--check bogus`（未知模式）与 `--limit 0` / `--top-failures 0` / `--slowest abc`
的校验错误也要各有一条断言。

### ③ `--notify-type`

CI 里 5 处 `--notify-type` **全是 `generic`**。未覆盖：

- `detect_notify_type` 的 URL 匹配（`sync.sh:2974-2982`，纯字符串匹配）
- dingtalk / feishu 的 `msgtype` / `msg_type` **外层包装**（正文共用同一份，差异只在包装）
- 未知类型的处理

**平台 URL 的匹配规则**（已实测）：

```text
*oapi.dingtalk.com*          → dingtalk
*feishu.cn* | *larksuite.com* → feishu
*hooks.slack.com*            → slack
其他                          → generic
```

## Requirements

### R1 三块各自独立断言

不要合成一个「大杂烩」用例——那样任何一处坏掉都只会表现为「某条失败」，
无法指出是哪一块。

### R2 「可选参数」的分支两侧都要测

`--top-failures` 的特例分支有**两条路径**：带值（`--top-failures 3`）与不带值
（`--top-failures` 后紧跟另一个选项）。**两条都要断**——只测带值的那条，
「退回默认值」的逻辑坏了不会被发现。

### R3 用本机 webhook 回显

`--notify-type` 的实现断言用**本地 `http.server`** 回显 payload（`ci.yml` 里已有先例，
用 `127.0.0.1` 的 webhook）——不需要外网。

**注意**：dry-run **不发通知**，所以这类用例**不能加 `--dry-run`**。

### R4 断言的落点

- ①②：smoke-test（纯参数 / 手写夹具，`history.sh` 已有 5 处这类写法）
- ③：smoke-test 或 integration-test——按是否需要真实 registry 决定，
  **在 PR 里说明选择**

## Acceptance Criteria

- [ ] **AC1** `--history-artifact` 的 CLI 通路有断言，且能区分「传进去了」与「用的默认值」
- [ ] **AC2** `--top-failures` 的**特例分支两侧**都有断言
- [ ] **AC3** `--limit` 的**窗口大小**有断言（不只是「跑通了」）
- [ ] **AC4** `--report-name` / `--workflow` 各有一条
- [ ] **AC5** 四个校验错误（`--check bogus`、`--limit 0`、`--top-failures 0`、`--slowest abc`）各一条
- [ ] **AC6** `detect_notify_type` 的四种 URL 各一条；dingtalk / feishu 的包装格式各一条
- [ ] **AC7** **每条断言都做单点变异验证**，且**夹具型断言要双向可信**——
      这是本仓库反复踩的地方：夹具里要有**正对照**，断言用**等值**而非「非空」，
      否则「夹具坏 + 实现坏」时两个错会相互抵消（详见 `.trellis/spec/engine/index.md`）
- [ ] **AC8** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 全部 job 全绿

## Constraints

- **不改生产代码**（只加断言）。若发现某条行为本身有问题，报告而不要顺手改
- **不要写「否定式判据」**（如「输出里没有 X 就算过」）——它会把「跳过」「没跑成」
  一起算过。用**正向要求**
- 兼容 bash 3.2
- 新步骤不与 job 内既有步骤争用容器名/端口

## Out of Scope

- `#137` 的其余组（stub skopeo / regctl / 容器）
- `#137` 里那条**代码缺陷**（通知成功判定只看 HTTP 码、响应体被丢弃）——
  它要改代码，另开任务

## Notes

- 判据不是「这些参数有没有被测」，而是「**它们的失败会不会被看见**」——
  `--top-failures` 的特例分支与 `--history-artifact` 的通路都属于「坏了是静默的」
- 本任务的价值一半在 ① 与 ②：它们各自对着一类**静默错账**