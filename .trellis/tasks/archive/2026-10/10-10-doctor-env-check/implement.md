# 执行清单（行号以 research/findings.md 调研时点为准，落码时以实际为准）

## A. scripts/sync.sh —— doctor 函数群（放在 check_updates_all 与 audit-lock 区之间）

- [x] 全局计数 `DOC_OK / DOC_WARN / DOC_FAIL` + 输出行助手（doctor_ok / doctor_warn /
      doctor_fail：统一前缀 + 计数 + 失败项后由调用方接 `log_dim` 缩进指引）
- [x] `probe_registry_classify <host>`：复用 `skopeo_inspect_raw`（自动带 TLS/authfile），
      三分类（missing 名单→正常 / unauthorized→匿名被拒 / 其余→连不上），首行提取用
      probe_ref:2138 惯用法，超时 10s 不重试
- [x] `doctor_tools`：skopeo、jq（`command -v` + `--version` 首行）；regctl 仅
      `regctl_path_active` 时检查（未激活时一条 dim 说明，不算项）
- [x] `doctor_sources`：SOURCE_IMAGES → `registry_host_of` 提取 host（并行数组去重），
      逐个 `probe_registry_classify`；没传 --src/--file 时说明跳过
- [x] `doctor_dest`：DEST_REGISTRIES 有值才探（同 probe），没值时说明跳过
- [x] `doctor_credentials`：--src-credentials 只读解析 + host 覆盖检查（漏配列名，[警告]）；
      dest 侧查 `${DOCKER_CONFIG:-$HOME/.docker}/config.json` 的 auths（[OK]/[警告]/跳过）
- [x] `doctor_disk`：`df -Pk "$TMPDIR"` 可用值；`--concurrency >1` 时附公式提示
      （借鉴 :1123 的 ×1.2 并发放大 + 100MB，不做网络估算）
- [x] `doctor_all`：顺序调五组（每组失败不中断）→ 汇总行「诊断完成：N 项通过，M 项警告，
      K 项失败」→ `DOC_FAIL>0` return 1 否则 0
- [x] 安装指引 URL 与 ensure_* 文案同源（readonly 常量，两处引用）

## B. scripts/sync.sh —— 13 处挂点（按 main() 顺序）

- [x] 1. 全局变量区 :55-81 加 `DOCTOR="false"`
- [x] 2. parse_args :476-586 加 `--doctor)` 分支（无值，仿 :507）
- [x] 3. 缺目标地址豁免 :4382 加 doctor（目标地址可选）
- [x] 4. sync_ignored 条件 :4446-4453 加 doctor（--write-updates/--write-pending 在 doctor 下不生效）
- [x] 5. 互斥 die 区 :4458-4466 加三条（doctor × audit / check-updates / audit-lock，措辞含「分两次运行」）
- [x] 6. `doctor_ignored` 列表（仿 :4479-4501 句式）：--report-dir、--dry-run、
      --write-lock/--write-updates/--write-pending、通知参数
- [x] 7. `regctl_path_active` :4562-4565 加 doctor 条件；注释「三处同源」改四处
- [x] 8. 镜像收集 :4579-4595 doctor 走 collect_images 分支；**不调 setup_src_auth**
      （凭证只读解析在 doctor_credentials 内）——注意 main 里 setup_src_auth 的调用条件要排除 doctor
- [x] 9. 入口日志 :4653-4664 加 doctor 分支（「环境自检：N 个源仓库的 registry 可达性 + 工具链」）
- [x] 10. WORK_DIR/trap :4669-4672 照常（doctor 也走）
- [x] 11. dry-run 计划 :4674-4676 条件排除 doctor
- [x] 12. 主分发 :4680-4692 前置 doctor 分支（在 ensure_* 无条件调用之前 return）——
       实际落位：doctor 分支放在 main 里 ensure_skopeo（:4567 附近）之前
- [x] 13. 汇总退出 :4697-4713 doctor 已在 12 提前 exit，不进此区
- [x] usage()：「可用性」小节 :299-351 加 --doctor 段（格式仿 --audit）；退出码小节 :419-434
       加「--doctor 模式下的退出码」；示例小节 :436-467 加一条；--report-dir 措辞 :394-396 顾及

## C. CI 断言（ci.yml smoke-test 新步骤「验证 --doctor 环境自检」）

- [x] 专用 stub（按 stderr 分类：manifest unknown / unauthorized / connection refused）
- [x] 全过场景：退出码 0、汇总「0 项失败」
- [x] 混合失败：连不上 + 凭证文件缺失同时报出（独立失败语义）、退出码 1、每失败项有指引行
- [x] 匿名被拒：[警告] 档输出（不冒充正常也不算失败）
- [x] 互斥 die ×1（--doctor --audit）+ 不生效告警 ×1（--doctor --report-dir）
- [x] 锚点有效性：doctor 输出中每个 TROUBLESHOOTING 锚点行的标题原文在
      docs/TROUBLESHOOTING.md 中 grep 得到（不断 slug 规则）
- [x] regctl 条件：不带 --strip-attestation 时 regctl 不进检查项
- [x] 无 --dest：目标侧跳过说明、不算失败、退出码不受影响

## D. 文档

- [x] modes.md 加「矩阵之外：--doctor」段（定位 + 退出码 0/1 + 五个 ignored 列表点名更新）
- [x] USAGE.md 新场景（环境自检）+ 参数速查核对
- [x] TROUBLESHOOTING.md 顶部加「先跑 --doctor」指引
- [x] README：特性列表 + 参数速查提���
- [x] CHANGELOG Unreleased「新增」段

## 断言写法约束（沿用上轮教训）

- `|| fail "..."`（不用 `|| { 诊断; fail; }` 哑弹写法）；`$var` 不紧贴全角字符（加花括号）
- 断言匹配带数值/专名的行，不匹配纯措辞；反断言（if grep … fail）配正断言成对
- 本地复现：bash 显式跑（交互 shell 是 zsh）；bash 3.2 下过一遍

## 验证命令

```bash
./scripts/lint.sh
bash <抽出的 CI 步骤脚本>
```

## 收尾

- PR 标题：`feat: --doctor 环境自检——把被动排障文档变成主动体检`
- PR 正文带设计要点与拍板（退出码 1、不落盘不通知、不进矩阵）；新 Issue 先立项（维护闭环惯例：一 Issue 一分支一 PR）
- 合并后 archive + journal；版本随下次发布归档
