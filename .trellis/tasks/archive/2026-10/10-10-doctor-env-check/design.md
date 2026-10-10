# 设计：--doctor 环境自检

## 边界与定位

- **独立函数群 `doctor_*`**，不与同步主路径、四种模式共用任何状态变更逻辑。
- **只读、零副作用**：不推送、不写文件、不下通知——也**不下载 regctl**（这点与
  `ensure_regctl` 的行为刻意不同，见下节）。
- **不进 modes.md 矩阵**（PRD 拍板 1）：矩阵的「检查对象」行全是「X vs Y」的数据对比，
  doctor 回答的是环境问题。modes.md 加「矩阵之外」一段说明 doctor 的定位与退出码。

## 与 ensure_* 家族的关系（关键决策）

`ensure_skopeo` / `ensure_jq` / `ensure_regctl` 是「**确保**」语义：缺了就 die，regctl 缺了
会**自动下载**。doctor 是「**报告**」语义：缺了要说清楚影响与装法，绝不动手装。

- doctor 自行 `command -v` 探测，失败输出 `[失败]` + 安装指引（URL 与 ensure_* 的文案同源，
  提取成 `readonly` 常量两处引用，避免 URL 漂移）。
- `regctl` 探测挂在 `regctl_path_active` 同一条件上（这是该条件的第四个消费者——
  sync.sh:4558-4561 的「三处必须同源」注释要改成四处）。doctor 模式要进这个条件：
  `--doctor --strip-attestation` 时 regctl 是真实依赖，值得探；不带时探它只会制造噪音。
- ensure_* 的无条件调用（main 里）在 doctor 下**不触发**：doctor 的主分发放在 ensure_*
  之前 return——诊断没通过时，用户拿到的是全貌报告，不是第一项的 die。

## 函数结构

```
doctor_all()                 # 入口：顺序跑五组，每组独立失败，汇总行 + 退出码
  doctor_tools()             # L1 工具链：skopeo / jq（存在+版本）；regctl（条件）
  doctor_sources()           # L2 源侧：解析出的源 host 去重，逐个分类探测
  doctor_dest()              # L3 目标侧：传了 --dest 才探，没传则说明跳过（不算失败）
  doctor_credentials()       # L4 凭证：--src-credentials 可读 + host 覆盖；dest 登录提示
  doctor_disk()              # L5 磁盘：df -Pk 临时目录；并发 >1 时给需求量提示
probe_registry_classify()    # 共用探测：对一个不存在的引用做 inspect，按 stderr 分类
```

计数用三个全局标量（`DOC_OK` / `DOC_WARN` / `DOC_FAIL`），bash 3.2 无关联数组，
host 去重用下标对齐并行数组（仓库既有范本：`UPD_REPOS` / `UPD_KNOWN_TAGS`）。

## registry 探测分类（三分类，新增「未授权」档）

`probe_ref` 现有 ok / missing / unreachable 三分类，**unauthorized 被归进 unreachable**
——doctor 需要它单独成类（「网络问题」与「凭证问题」的修复动作完全不同）。

探测手法：对 `<host>/doctor-probe-nonexistent`（一个不存在的引用）做 `skopeo inspect`，
按 stderr 文案分类（复用 `skopeo_inspect_raw`——它已带 TLS_VERIFY 与 SRC_AUTHFILE 语义，
doctor 探测私有源时自动用上既有凭证装载；stderr 捕获用 `2>&1 >/dev/null` 的顺序，
反了会把 stderr 一起丢掉——probe_ref:2118-2121 的既有手法）：

| stderr 特征 | 判定 | 输出 |
| --- | --- | --- |
| `manifest unknown` / `name unknown` / `repository name not known` / `not found` / `no such manifest`（probe_ref 的 missing 名单） | **应答正常** | `[OK]` registry 应答正常 |
| `unauthorized` / `authentication required`（TROUBLESHOOTING:17 快速定位表同款判据） | **应答但匿名被拒** | `[警告]` registry 活着，匿名探测被拒——若同步走匿名会失败；已有凭证则本项无碍 |
| `connection refused` / `timed out` / DNS / `no route` / `context deadline exceeded` 类（其余全部，同 probe_ref 的兜底档） | **连不上** | `[失败]` + 网络排查指引 + TROUBLESHOOTING `#8` 锚点 |

理由：对不存在引用的 401 也证明 registry 应答了（活着），它本身就是有效的健康信号
（调整为 `[警告]` 而非 `[OK]`：匿名被拒对「同步走匿名」的用户是真实风险）；
真正的连不上（TCP 层）才是 `[失败]`。超时 10s（复用 `setup_timeout` 的 perl 兜底），
**不重试**——诊断不是压测（PRD 约束）。首行错误提取用 probe_ref:2138 同款惯用法
（`tr -d '\r'` + 去空行 + `head -n 1`，不按字节截断以免切半多字节字符）。

## 凭证检查的边界

- 源侧：`--src-credentials` 传入时查文件存在 + 可读 + 覆盖全部源 host（漏配 host 列名）。
  覆盖判定**只读解析** `parse_src_credentials` 的映射数据（不调 `setup_src_auth`——它是
  装载语义，会 die / 会写 authfile）；注意 `SYNC_SRC_CREDENTIALS` 环境变量的值是
  **文件内容**而非路径（先落 600 临时文件再解析的既有路径，doctor 同样只读其内容）。
  `setup_src_auth` 已有的预检（混用 / 文件不存在 / 权限过宽 / 行格式 / 空文件）在正常
  运行路径仍由它自己负责，doctor 不重复 die——doctor 把同类问题报成 `[失败]` 行并继续。
- 目标侧：目标凭证来自 `docker login`（脚本不管，:1597-1599 注释明说）。doctor 只做
  **提示级**检查：`${DOCKER_CONFIG:-$HOME/.docker}/config.json` 存在且 `auths` 含 dest
  host → `[OK]`；查不到 → `[警告]`（不是失败——凭证可能在 skopeo 侧其它 authfile），
  指引 `docker login`。文件不存在或不可解析 → 跳过该项并说明，不算失败。

## 输出形态（示例）

```
[信息] 环境自检（--doctor）：只探测，不推送、不写文件

[OK]   skopeo 1.14.0
[OK]   jq 1.7
[警告] regctl 未安装——本次未传 --strip-attestation，不影响运行；需要时脚本会自动下载
[OK]   源 registry.example.com 应答正常
[失败] 源 10.0.0.5:5000 连不上：connection refused
       └ 确认 registry 在跑、地址端口无误；自建 registry 见
         docs/TROUBLESHOOTING.md#自建-registry-连不上
[警告] --src-credentials 未覆盖 host：quay.io（该 host 将走匿名访问）
[警告] 未检测到 docker login 凭证（$HOME/.docker/config.json 无目标条目）——推送前需 docker login
[OK]   临时目录可用 128GB

诊断完成：5 项通过，3 项警告，1 项失败
```

汇总行句式与既有检查的「检查完成：…」对齐；失败项的缩进指引用 `log_dim`。
锚点在输出里以 `docs/TROUBLESHOOTING.md#<slug>` 呈现；**slug 由 GitHub 中文标题规则生成**
（research 确认现有锚点即此形态，sync.sh 目前零引用，doctor 是第一个）。

## 主分发与退出码

- main() 里 doctor 分支放在 ensure_* 无条件调用**之前**：`doctor_all; exit $?`——
  诊断没通过时用户拿到的是全貌报告，不是第一个缺失工具的 die。
- doctor 仍走 `collect_images + apply_filters`（源 host 从 SOURCE_IMAGES 提取，
  `registry_host_of` :747-764 已有 host 推导规则含 docker.io 兜底）；没传 `--src`/`--file`
  时跳过源侧探测并说明（不算失败——只查工具链与磁盘也是一种合法用法）。
- WORK_DIR 与 trap cleanup 照建照挂（doctor 探测的 stderr 临时文件与 `SYNC_SRC_CREDENTIALS`
  落盘的临时凭证文件都依赖它清理；一致性代价为零）。
- `doctor_all` 返回：`DOC_FAIL > 0` → `return 1`（拍板 2：环境没就绪与参数错误同族），
  否则 `return 0`。不占用 2。
- 13 处挂点清单（全局变量区 → parse_args → 目标地址豁免 → sync_ignored 条件 → 互斥
  die 区 → doctor_ignored 列表 → regctl_path_active（第四消费者，注释三处→四处）→
  镜像收集 → 入口日志 → WORK_DIR/trap → dry-run 计划排除 → 主分发 → 汇总退出）
  行号见 research/findings.md，执行序见 implement.md。

## CI 断言设计（smoke-test 新步骤）

- **stub skopeo 按 stderr 分类**：造三类应答（manifest unknown / unauthorized /
  connection refused），断言 doctor 三分类输出与对应指引行。
- **全过场景**：退出码 0，汇总「0 项失败」。
- **混合失败**：连不上的源 + 缺失工具同时存在，断言两项**都**报出（独立失败语义），
  退出码 1。
- **互斥**：`--doctor --audit` → die，措辞含「分两次运行」。
- **不生效告警**：`--doctor --report-dir X` → 「以下参数本次不生效」。
- **锚点有效性**：断言用**标题文本**（不用 slug 规则——bash 里实现 GitHub slug 化是自找
  麻烦）：doctor 输出中每个 `TROUBLESHOOTING.md#xxx` 行，取 slug 前的标题关键词在
  TROUBLESHOOTING.md 里 `grep` 得到对应标题行。更稳的等价做法：doctor 输出锚点的同一行
  同时给出标题原文，断言标题原文存在于 TROUBLESHOOTING.md。
- **回归**：四种模式既有断言不动且全绿。

## 兼容与回滚

- 纯新增模式，不改任何既有路径行为；单提交 revert 即回滚。
- usage() 「可用性」小节加一段；README 参数速查、USAGE.md 新场景（场景十四）、
  TROUBLESHOOTING.md 顶部加「先跑 --doctor」指引、CHANGELOG、modes.md「矩阵之外」。
