# 拍板并实现「上游空 tag 列表」语义：单列一档，退出码如实

## Goal

为 #172 第二条拍板：`--check-updates` 遇到「查询成功、但上游一个 tag 都没返回」的仓库时，
不再折进「清单均已覆盖上游现有 tag」+ 退出码 0，而是与 `--audit` / `--audit-lock` 的
「无法判定」档对齐——屏幕汇总行、Step Summary、报告、通知、json 汇总与退出码全部如实。
补齐 CI 断言与文档后关闭 #172（其第一条 `--ef` 守卫已在 v1.21.0 修掉）。

## 决策（拍板）

**「上游返回空 tag 列表」算「无法判定」，不算「干净」。** 依据：

1. 空列表对「清单是否覆盖上游」给出的既不是「是」也不是「否」——无法区分
   「仓库真的没有 tag」与「匿名拉取被 registry 裁剪后返回空列表」。
2. 同构先例全部站在「可见」一侧：`--audit` 退出码 2 含无法判定（modes.md:427）、
   `--audit-lock` 含漂移或无法判定（modes.md:434）、#87 区分无附件与下载失败、
   #98 网络失败不冒充无记录、v1.16.1 dry-run 不冒充真实运行。四种检查模式里
   唯独 `--check-updates` 把无法判定折进「已覆盖 + 0」，是往乐观方向的漏。
3. 屏幕逐仓库行早已单列（黄字「上游没有返回任何 tag」、`state:"empty"`、
   `--write-updates` 片段头部注明）——汇总层与退出码和它对齐才是自洽的。

**推翻旧注释的拍板**：sync.sh 2757-2759、2817-2819 注释里「不并进 failed、不进退出码」
是当时的临时口径，本轮正式改为「进退出码 2，但**不并入 failed 计数**——它是一次成功的
空回答，措辞上不叫失败，档位上单列」。

## Requirements

- 汇总句（屏幕 / Step Summary / 报告 md / 通知 summary）：
  - 仅当 `with_updates==0 && failed==0 && upd_empty==0` 才说「清单均已覆盖上游现有 tag」；
  - 有空 tag 仓库时，汇总句追加一档「N 个上游返回空 tag 列表」，措辞不使用「查询失败」。
- 退出码：`with_updates>0 || failed>0 || upd_empty>0` → 2；否则 0。
- json 报告（`--report-dir`）的 summary 对象补 `"empty": <N>` 字段。
- 通知 `attention` 计数（`send_check_notification` 第 4 参）把 `upd_empty` 计入
  ——`--notify-on failure` 下「只有空 tag」也应发通知。
- `--write-updates` 片段头部已有的 empty 注明保持不变（#169 已做对）。
- sync.sh 内两处旧拍板注释同步改写，说明新口径与理由。
- `.trellis/spec/engine/modes.md` 语义矩阵 check-updates 列的退出码 2 描述补上
  「上游空 tag 列表」。
- 文档同步：USAGE.md（--check-updates 退出码口径）、README 参数速查（若有退出码表述）、
  CHANGELOG（显式标注为行为变化：空 tag 场景退出码 0 → 2）。

## Constraints

- bash 3.2 兼容（不用 `wait -n` 等新特性；CI 内嵌 shell 断言里 `$var` 不紧贴全角字符）。
- 不改动逐仓库层的既有输出形态（黄字、summary_rows 的「上游返回空列表」、jsonl
  `state:"empty"`）——只动汇总层与退出码。
- 退出码值域不变：仍只有 0 / 2（不引入新码）。

## Acceptance Criteria

- [x] 单一空 tag 仓库（其余均覆盖）场景：退出码 2，汇总行含「1 个上游返回空 tag 列表」，
      不再出现「清单均已覆盖上游现有 tag」。
- [x] 空仓库 + 查询失败混合场景：汇总行两档分列（failed 与 empty 不合并计数）。
- [x] 全部真覆盖（无空 tag、无失败）场景：退出码 0，汇总行仍是「均已覆盖」——回归不破。
- [x] json 报告 summary 含 `"empty": N` 且数值正确。
- [x] CI 新增上述场景断言（stub skopeo 的 list-tags 按 ref 分流出空 Tags 回答），
      既有 check-updates 断言全部保持绿。
- [x] modes.md / USAGE.md / CHANGELOG 同步更新。
- [x] #172 在 PR 合并后关闭（PR #176 正文给出两处处理的落点：第 1 条 #174、第 2 条本 PR；Closes 自动关闭）。
