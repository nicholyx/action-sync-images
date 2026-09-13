# 四种模式的语义矩阵

`sync.sh` 有一个默认模式 + 三个只读检查模式。改任何模式的行为之前，先在这里对齐语义。

## 矩阵

| | 同步（默认） | `--audit` | `--check-updates` | `--audit-lock <文件>` |
| --- | --- | --- | --- | --- |
| 回答的问题 | 把镜像搬过去 | 目标仓库跟上清单了吗 | 上游有没有新版本 | 上游还是我锁的那份吗 |
| 检查对象 | — | 目标 vs 源 | 上游 vs 清单 | 上游 vs 锁定 digest |
| 需要目标地址 | ✅ | ✅ | ❌ | ❌ |
| 会推送 | ✅ | ❌ | ❌ | ❌ |
| 退出码 2 的含义 | 有镜像失败 | 有落后/缺失/无法判定 | 有未收录 tag 或查询失败 | 有漂移或无法判定 |
| 状态值域 | success/skipped/failed/excluded | current/stale/missing/unknown/excluded | —（逐仓库报告） | match/drift/unknown/nodigest/marker |
| 结果数组 | `R_*` | `A_*` | —（直接输出） | `L_*` |
| 报告落盘 | `sync-report-*` | `audit-report-*` | `check-updates-report-*` | `lock-audit-report-*` |

## 互斥关系（全部 die，不告警后继续）

- `--audit` × `--check-updates`：检查对象不同，报告两套
- `--audit` × `--strip-attestation`：重建索引会让审计给出一排**假的「落后」**——能预见输出会误导时就拒绝执行
- `--audit-lock` × 上两者：三套报告互不混合
- `--audit-lock` × `--src`/`--file`：校验清单以锁文件为准
- `--dest-exact` × `--dest`/`--dest-keep-path`：完整地址 vs 待拼接前缀

## 状态分类的两条铁律

1. **「无法判定」永远单独成类**。查询失败（网络/凭证）和内容不一致是两回事——把网络抖动显示成「落后」会让人排查一个不存在的问题。判据刻意保守（见 `probe_ref`）：只有 registry 明确回答「不存在」才算 missing / 上游已删除，其余一律无法判定。**错误的信息比没有信息更糟，因为它会被当成结论。**
2. **被排除 / 不参与判定的条目必须可见**。审计的 excluded、锁文件的 nodigest/marker 都出现在报告里并标注类别——报告里少一项，看的人会默认它是好的。

## 通知与报告（三种检查共用）

- 通知发送走同一条路径 `notify_send_text`，「要不要发」由各模式判断：`--notify-on failure` 在检查模式下 = 有需要关注的项
- 通知只列需要关注的条目（最多 20 条），全绿安静
- 报告落盘走 `write_check_report_files`：md 与 Step Summary 三方同源；JSON 顶层 `generated_at` + `check` + `summary` + `records[]`
- `--notify-after-failures` 仅同步模式适用（检查没有「连续失败」概念），显式传入告警

## 模式相关参数（显式传入不生效必须告警）

每个模式有自己的「不生效」列表（`upd_ignored` / `ignored` / `lock_ignored`，在 `main()` 的参数约束区）。新增模式行为时同步维护——「参数被接受却不生效」比直接报错更危险。
