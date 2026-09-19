# 报告可信度收尾：让报告与错误信息如实

## Goal

把三个同族缺口收进一轮。它们的共同点是：**输出说的未必是真的**——把「拿不到」说成「没有」，把「不知道」藏起来，或者产出根本解析不了的东西。

前两轮把「失败被看见」（v1.11）、「瞬时失败被挽回」（v1.14）、「失败之后能重跑」（v1.15）做完了；这一轮回头清理报告本身还不可信的地方。

## 任务地图

父任务只负责本轮主题、子任务编排与最终集成验收，**不直接实现**。

| 子任务 | 对应 Issue | 缺口 | 可独立验证的交付 |
| --- | --- | --- | --- |
| `09-19-report-json-escape` | [#103](https://github.com/nicholyx/action-sync-images/issues/103) | `sync-report.json` 是手工 `printf` 拼接、无任何转义，镜像名含 `"` 或 `\` 时产出**非法 JSON** | 含引号的镜像名仍产出可被 `jq` 解析的报告 |
| `09-19-report-failure-note` | [#102](https://github.com/nicholyx/action-sync-images/issues/102) | 失败原因 `R_NOTE` 只在终端打印，不进 md / json / Step Summary / 通知（三种检查模式都带） | 报告与页面能看到「为什么失败」 |
| `09-19-history-runlist-retry` | [#98](https://github.com/nicholyx/action-sync-images/issues/98) | `gh run list` 的退出码被 `2>/dev/null \|\| true` 吞掉，网络失败冒充「没有取到任何运行记录」 | 网络失败与空列表被区分开 |

## 顺序约束

**`report-json-escape` 必须先于 `report-failure-note`。**

两者都改 `write_report()` 的 json 分支：前者换掉 json 的构造方式（改用 `jq`），后者要往里加 `note` 字段。若先加字段再换构造方式，等于同一段代码改两遍、写两遍断言。反过来则 `note` 字段一进去就自带正确转义。

`history-runlist-retry` 改的是 `scripts/history.sh`，与另外两个无交集，可任意时间做。

## 跨子任务验收标准

- [ ] 三个子任务各自的验收标准全部满足
- [ ] 每个子任务对应一个独立的 GitHub Issue 与 PR，CI 全绿后合并
- [ ] 合并后 `history.sh` 能正常消费新格式的 `sync-report.json`（趋势、`--slowest`、`--check` 都不受影响）
- [ ] `./scripts/lint.sh` 全绿；全仓无 U+FFFD
- [ ] 文档与 CHANGELOG 的 `[Unreleased]` 同步

## Out of Scope

- **不改同步行为**：三个子任务都只影响「输出与报错的如实程度」，不碰搬运逻辑、退出码语义
- 不为 `--filter`/`--exclude` 增加新参数
- 不做报告 schema 的版本号机制（当前规模用不上）
- 不引入新的状态存储
