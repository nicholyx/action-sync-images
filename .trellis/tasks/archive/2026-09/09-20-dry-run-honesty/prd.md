# dry-run 说了它没做过的事：耗时、锁文件与通知

## Goal

`--dry-run` 没有真的搬过任何东西，因此**任何描述「搬了什么、花了多久、搬完了」的输出都必须为空或零**：耗时如实为 0、不写锁文件、不发通知、不记录目标 digest。与这些参数不生效时一样，按项目既有模式**显式告警**。

## Background

### 四个缺口（2026-09-20 本地全部复现）

**一、耗时：判据错了**

`process_one` 用 `start=$(date +%s)` / `end=$(date +%s)` 包住 `sync_to_dest`。而 dry-run 下 `sync_via_skopeo` 只打印一行 `[dry-run] skopeo copy …` 就 `return 0`——计时区实际测的是「打印一行花了多久」。

判据应是「**有没有真的搬过**」，不是「这段代码跑了多久」。后果：

- `1s` 进了报告 json 的 `images[].seconds`、md 与 Step Summary 的耗时列
- `duration_ranking_rows` 只要任一秒数 > 0 就输出「最慢的同步记录」——一次没搬过东西的 dry-run 也会出排行
- CI 那条「耗时全为 0 时排行应隐去」的断言因此**偶发误报**：2026-09-19 在 #103 的 PR 上把整个 smoke-test job 带崩过一次，重跑即绿

已在 `bash-rules.md` 的「dry-run 的铁律」留下记录，标注「**尚未修改**」——本任务就是去落实它。

**二、锁文件：产出误导性工件**

```bash
./scripts/sync.sh --src 'nginx:1.27' --dest r.example.com/x --dry-run --write-lock /tmp/dry.lock
# >>> 写出了锁文件
```

锁文件头部写着「每行是「镜像@digest」……**可直接用 `--file` 读取本文件实现精确复现**」——而这次运行什么都没推。在 CI（有 skopeo）上 digest 会是**真实的源 digest**，锁文件看起来完全合法，使用者拿它回喂 `--file` 会以为复现的是「当时推上去的那一份」。

**三、通知：对外误导，且已发出**

```bash
./scripts/sync.sh --src 'nginx' --dest r.example.com/x --dry-run --notify-webhook <url>
# >>> 真的发出了通知，正文：「## 镜像同步完成 / 共 1 个镜像｜成功 0｜失败 1」
```

正文说「**镜像同步完成**」并报「失败 1」——收到通知的人会去排查一次**根本没发生**的同步。这是四处里唯一**主动对外推送给其他人**的，也是最严重的一处。

**四、目标 digest：记录的不是本次的产物**

`process_one` 在 `status == "success"` 时调 `compute_digest "$dest"`——查询**目标仓库**。dry-run 里这句会查到上一次真实同步留在那个 tag 上的镜像，把它的 digest 写进报告的「目标 Digest」列，读起来像是本次同步的产物。（`source_digest` 不同：它是源镜像的真实属性，与本次是否同步无关，**保留**。）

### 项目已有的处理模式

`docs/USAGE.md:634` 已经确立了这类情况的处理方式：

> `--dry-run` / `--write-lock` / `--verify` / `--skip-existing` 在审计模式下**没有作用，显式传入时会告警**。

即「某参数在某模式下没有意义 → 不生效 + 告警」。本任务的三个落点（锁文件、通知、以及耗时/digest 的如实化）正是同一模式在 dry-run 上的应用。

### 为什么现在做

这四处是同一主题的第四次出现——前三轮（v1.15.0 的 json 转义 / 失败原因 / 运行列表失败，v1.15.1 的坏报告容错）都在回答「输出说的未必是真的」。dry-run 是这条线上最后一处：**它是唯一一个「预告」形态的输出**，所以它的不诚实最容易被当成事实。

## Requirements

- **R1** dry-run 下 `elapsed` 如实为 0——判据是「有没有真的搬过」
- **R2** dry-run 下**不写锁文件**，且显式告警说明原因与做法
- **R3** dry-run 下**不发送通知**，且显式告警说明原因与做法
- **R4** dry-run 下**不记录目标 digest**（`dest_digest` 留空）；`source_digest` 保留
- **R5** 告警文案与项目既有模式一致（说明「本次不生效」+ 怎么办），风格对齐 `「--audit-lock 只校验锁文件，以下参数本次不生效：…」`
- **R6** **不改变非 dry-run 的任何行为**：真实同步的耗时、锁文件、通知、digest 一律不变
- **R7** 退出码语义不变
- **R8** 不新增命令行参数

## Acceptance Criteria

- [ ] dry-run 报告的 `images[].seconds` **恒为 0**（含并发与慢机器场景——判据不再依赖计时）
- [ ] dry-run 下 md / Step Summary 不出现「最慢的同步记录」节
- [ ] dry-run + `--write-lock` 不产出文件，且有一条告警说明
- [ ] dry-run + `--notify-webhook` 不发出任何请求，且有一条告警说明
- [ ] dry-run 报告的 `dest_digest` 为空；`source_digest` 行为不变
- [ ] **非 dry-run** 四者的行为与改动前逐字/逐字节一致（回归）
- [ ] 既有断言不破，含 CI 里那条**用 dry-run 当夹具**的通知断言——它需改为不加 `--dry-run`（smoke-test job 已装 skopeo，非法引用不联网即可失败）
- [ ] CI 有对应断言；断言**先在本地复现过**（红 → 绿）
- [ ] macOS 自带 bash 3.2 下正常
- [ ] `./scripts/lint.sh` 全绿；全仓无 U+FFFD 与控制字符

## Out of Scope

- **不改 dry-run 报告的 `status` 取值**：它现在恒为 `success`（非法引用除外）。改成别的值会波及 `history.sh` 的聚合与多条既有断言，且「计划会成功」与「已成功」的语义区分需要单独设计——留作后续
- **不给 dry-run 加「只发测试通知」的开关**：需要新参数（违反 R8），且用真实同步验证 webhook 更直接
- **不动 `--skip-existing` / `--verify` 在 dry-run 下的既有语义**（已有各自的告警与说明）
- **不处理 `resolve_platforms` 在 dry-run 下的真实网络探测**：那是既有设计（`--strip-attestation` 时探测平台），且 CI 已有一条断言专门钉住「不虚构探测结果」
