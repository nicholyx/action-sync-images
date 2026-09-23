# PRD：#137 的其余覆盖组（stub skopeo / regctl / 容器依赖）

对应 issue：[#158](https://github.com/nicholyx/action-sync-images/issues/158)
母 issue：[#137](https://github.com/nicholyx/action-sync-images/issues/137)（零依赖组已完成并合入 #160）

## 共同点

这批缺口的共同点是**坏了是静默的**：要么悄悄用默认值，要么「参数被接受却不起作用」，
要么「该响的时候不响」。每一条都要能说出这句，否则它不值得一条断言。

**本任务只补断言，不改产品行为。**过程中若发现真缺陷，单独开 issue
（#143 就是这样在 #135 的「补断言」任务里被发现的）。

## A. `--updates-limit` 的语义（stub skopeo）

**现状**：零覆盖。`sync.sh` 里 `limit="$UPDATES_LIMIT"`、`total_missing += missing_count`
（用**完整** missing 列表）、`shown = sort -Vr | head -n "$limit"` —— 总数与展示分开算，
语义是「**只限制展示条数，不改变总数**」。

**坏掉会怎样**：哪天 limit 被顺手用在过滤上（`missing` 先 `head -n "$limit"`），
`total_missing` 跟着变小 → 使用者看到「上游只差 3 个 tag」而实际差 6 个，
退出码仍是 2、不告警，**他不会知道还有三个没显示出来**。

**验收**：一条运行里**同时**断两侧 —— 总数（`共 6 个`）与列出条数（恰好 3 个）。
正对照：不传 `--updates-limit`（默认 5）→ 总数仍是 6、列出 5 个。
两次运行合起来才证明 limit **只**影响展示。

**夹具**：stub `skopeo list-tags` 吐 `{"Name":"…","Tags":[7 个]}`，清单里含其中 1 个。

## B. `check-updates` / `lock-audit` 的报告落盘（stub skopeo）

**现状**：`write_check_report_files` 是三种检查共用的一份实现，三处调用点：
`audit` / `check-updates` / `lock-audit`。CI 只断了 `audit-report.{md,json}`；
`lock-audit-report` 全文 0 次，`check-updates-report` 唯一一次出现是手写夹具。

**坏掉会怎样**：`check_name` 传错 → 文件名不对，消费方按名字找不到报告；
而「三种检查共用一份实现」正是「改一处、另外两处没跟上」的高发区。

**验收**：两种模式各自的 `-report.md` / `-report.json` 都落盘；json 顶层形状
（`generated_at` / `check` / `summary` / `records`）成立，且 `check` 字段等于模式名
（`check-updates` / `lock-audit`，不是 `audit`）。

## C. `--audit` 的 `.summary` 从未被断言

**现状**：CI 里出现过的那个 `.summary.stale` 打的是 `history.sh` 的趋势产物，
**不是**检查报告自己的 summary。

**坏掉会怎样**：summary 计数与正文脱节 → 只读 json 的下游得到一个与报告正文矛盾的结论。

**验收**：`audit-report.json` 的 `.summary` 各计数与正文渲染的数字一致（断**具体数值**，
不是「存在」）。

## D. 三条「重定向到别的路径」的告警 —— 方向**各不相同**

| 参数 | 告警门禁 | 说的路径 | 落点 |
|---|---|---|---|
| `--platforms` | `STRIP_ATTESTATION != true` | **skopeo** | `sync.sh` 的启动校验区 |
| `--skip-existing` | `STRIP_ATTESTATION == true` | **regctl** | 同上 |
| `--tls-verify false` | `regctl_path_active == true` | **regctl** | 同上 |

**注意**：issue #158 把 `--platforms` 也归在「需要 regctl」组，这是**错的** ——
它的门禁恰好相反（没开 `--strip-attestation` 时才告警）。放进 regctl 那一步会写成**恒真**。
三条各自的环境不能混着放。

**坏掉会怎样**：`--platforms linux/amd64` 被静默忽略意味着 skopeo 用 `--all` 推了
**所有**平台 —— 推送量与体积远超预期，而没有报错、退出码也是 0。
`--tls-verify false` 那条是自签 HTTPS 仓库走 regctl 时**唯一的指路线索**：丢了它，
使用者会去反复检查证书，而真正要改的是 `~/.regctl/config.json` 的 cacert。

**验收**：三条各断文案（含参数名与「本次将忽略」）。`--platforms` 那条另配**负面**断言
—— 开了 `--strip-attestation` 时不该出现（它在 regctl 路径下是真生效的）。
负面断言必须与正面**成对**，单独写「没有某句」是恒真的。

## E. 同步模式 `--notify-on failure` 的发送门禁（integration-test）

**现状**：**全部断言里唯一一条「该响的时候不响」的门禁**。检查模式那条已经测了，
它在**另一处**且判据不同：`send_check_notification` 判 `attention`（存在落后 / 缺失 /
无法判定），`send_notification` 判 `fail`（失败数）。**两处、两个判据** ——
只测一处等于没测另一半。

**坏掉会怎样**：条件写反 → 失败运行**彻底静默**，没有任何人收到通知，而 CI 依旧全绿。

**验收**（两条**成对**，缺一不可）：
- (a) 真实全绿 + `--notify-on failure` → 断言**无** payload
- (b) 同步失败 + `--notify-on failure` → 断言**有** payload

**(b) 不能加 `--dry-run`**：dry-run 不发送通知（它没真的搬过任何东西）。
(a) 要用真 registry 做一次成功同步，才算「全绿」（放 integration-test job，
那里已有 `registry:2` 容器与既有通知用例）。

## F. feishu / slack 的端到端（#159 检查阶段留下的盲区）

**现状**：#159 的端到端只覆盖了 `dingtalk` 与 `generic`；`feishu` / `slack` 只有抽取式
单测。而 #159 恰是「按平台分别实现」的改动 —— **每多一个平台就多一份实现**，
只测其中一个，其余两个的接线（payload 构造 → 假 webhook → 判定 → 文案）没被穿过。

**坏掉会怎样**：`feishu` 的 `msg_type` 包装或 `slack` 的 `text` 包装改错时，
单测仍绿（它只喂判定函数），而真实发送路径发出去的 payload 平台不认。

**验收**：`--notify-type feishu` 与 `--notify-type slack` 各来一次真实端到端
（假 webhook 按该平台的回执形态应答），断言日志结论为该平台的**正确**结论
（feishu `code:0` → 已确认送达；slack `invalid_payload` → 拒收），
并断请求体里的**包装字段**是该平台的（`msg_type` / `text`）。

## 不做什么

- 不覆盖 #137 已列出的 19 项**已有覆盖**（避免重复劳动）
- 不改产品行为

## 风险

- 新增步骤前先核实该 job 已有的环境与**端口 / 容器名**（job 共享，起同名容器会让既有用例红）
- stub skopeo 要能同时应付 `list-tags` 与 `inspect` 两种调用（`--audit-lock` 走 inspect）