# implement：`--write-pending` + 输出路径守卫

分支 `feat/write-pending-and-guard`，一个 Issue 一个 PR（#173；守卫部分推进 #172 第 1 条）。

## 第 0 步：核实两点（**动手前**）

- [ ] `excluded` 在审计记录里**有没有**自己的行？（遍历写出逻辑即可看出来）若有，必须排除
- [ ] 多目标时记录的形状：确认「源 × 目标」多条，子集里同一个源只能出现一次
- [ ] 顺带确认 `--audit` 下 `SOURCE_FILES` / `SRC_CREDENTIALS_FILE` / `AUDIT_LOCK_FILE` 三个
      读入集合的变量名与生命周期（守卫要用）

## 第 1 步：守卫（先做——它是安全项，且独立于新参数）

- [ ] 按 design.md §4/§5 写 `guard_output_paths`，在启动校验区调用
- [ ] 三个写出参数都注册（`--write-updates` / `--write-pending` / `--write-lock`）
- [ ] 空数组遍历前判长度（bash 3.2 + `set -u`）
- [ ] 变异：把 `-ef` 换成字符串比较 → 「`./x` 与 `x` 指向同一文件」那条断言必须红
- [ ] 变异：去掉 `--write-lock` 的注册 → 它那条断言必须红

## 第 2 步：`--write-pending` 参数与告警

- [ ] 全局 `WRITE_PENDING=""`、`parse_args`、`usage()`（与 `--write-updates` 相邻，一并说明分工）
- [ ] 三种**其他**模式各加一条「本次不生效」（按 `--write-updates` 的既有位置照抄，别只改一处）

## 第 3 步：写出逻辑（在 `audit_all()` 里，与报告同源）

- [ ] 正文：`stale` + `missing` 的**源引用**，按仓库分组、组内 `sort -V` 升序、同源只出现一次
- [ ] 头部：`# 由 scripts/sync.sh 生成于 …` + 「不会修改你的清单」+ 用法一行 +
      **unknown 个数与原因**（AC3）；`excluded` 不在正文
- [ ] 无待同步项时仍写出文件并注明
- [ ] 写失败：**与 `--write-updates` 同一口径**（只告警、不中断、不改变审计退出码）——
      先看 `write_updates_snippet` 的既有实现，风格与语气对齐
- [ ] 日志「已写入 <路径>（N 行）」
- [ ] bash 3.2 兼容；`printf '%s'` 结尾换行处理照抄既有函数

## 第 4 步：文档

- [ ] `docs/USAGE.md`：`--audit` 一节加分工说明（**regctl 路径**与「不想白跑 inspect」时用它）
      + 参数表一行
- [ ] `docs/ARCHITECTURE.md`：设计决策——为什么「无法判定」不入选、为什么与
      `--write-updates` 同形、守卫为什么用 `-ef`
- [ ] `CHANGELOG.md`：`[Unreleased]` 的 `### 新增` + `### 修复`（守卫那条）。
      **插入前断言锚点行号 > `[Unreleased]` 且 < 下一个 `## [`**
- [ ] 全仓 U+FFFD 扫描

## 第 5 步：CI 断言

- [ ] 见 design.md §6 的 ①–⑪，每条都要**正向**判据；负向判据必须成对
- [ ] 夹具要能同时给出「落后 / 缺失 / 无法判定」三种（stub skopeo 既有夹具已在
      `/tmp/stub-skopeo`，`stale` / `miss` / `unreach` 分支都在）——**计数要互不相同**，
      否则「正文把 stale 渲染成 missing」这类串位在等值断言下是隐形的
- [ ] 多目标那条：夹具要有一个源对应两个目标

## 第 6 步：变异验证（每条断言都要能说出哪个单点变异让它红）

- [ ] 把 missing 也算进正文 / 把 unknown 也算进正文 → ① 与 ③ 分别红
- [ ] 去掉「同源去重」→ ② 红
- [ ] 让 excluded 也进正文 → ④ 红
- [ ] 写出逻辑顺带改写原清单 → ⑤ 红（用 mtime 判据，注意时间戳 tick：把参照拨到很久以前）
- [ ] 守卫换字符串比较 / 去掉某个参数的注册 → ⑦–⑩ 对应红
- [ ] 变异精确到单点；删行式变异先过 `bash -n`；同一模式串多处出现时按行号取第一处

## 验证命令

```bash
bash -n scripts/sync.sh
./scripts/lint.sh
# 本机没装 skopeo；stub 夹具在 /tmp/stub-skopeo，且它是步骤内硬编码路径
# （外层 PATH 覆盖无效——测「夹具坏」要改固定路径上的文件）
python3 /tmp/extract_step.py "<步骤名>" > /tmp/s.sh && bash /tmp/s.sh
git diff --stat scripts/sync.sh
```

## 回滚点

每步一次独立改动；变异用 `cp` 备份还原，**不用 `git checkout <文件>`**。

## 复核门

- [ ] #173 的 AC1–AC8 与 #172 第 1 条的 AC9–AC11 逐条有断言
- [ ] 守卫在**任何网络请求与写出之前**执行
- [ ] 「无法判定」与「需要同步」在产物里分得开
- [ ] `./scripts/lint.sh` 8 · 0 · 0