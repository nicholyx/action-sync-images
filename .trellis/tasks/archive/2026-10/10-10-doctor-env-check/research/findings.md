# 调研档案：--doctor 挂点与现状（doctor-research 代理交付，2026-10-10）

sync.sh 共 4716 行。以下行号为调研时点。

## 依赖检查现状

| 函数 | ��置 | 行为 |
|---|---|---|
| `ensure_skopeo` | :800-810 | `command -v`；dry-run 只 warn，否则 die（带安装 URL） |
| `ensure_jq` | :812-814 | `command -v`，只 warn 不 die |
| `ensure_regctl` | :817-888 | PATH 有则复用；无则**自动下载**到 `~/.regclient/bin`（v0.11.6），失败重试一次再 die |

调用点 main():4567-4574：skopeo/jq/setup_timeout 无条件；ensure_regctl 仅 `regctl_path_active`。
`regctl_path_active`（:4562-4565）= `STRIP_ATTESTATION && 非 check-updates && 无 AUDIT_LOCK_FILE`；
挂此条件三处（注释 :4558-4561 说「三处必须同源」）：ensure_regctl 调用（4572）、明文 HTTP
告警（4628）、regctl 失效参数告警（4635-4642）。**regctl 唯一消费方 `sync_via_regctl`（:966）**。

die 措辞风格：中文描述 + 冒号 + 修复动作/URL。

## 模式挂点全表（新增 --doctor 按 main() 顺序）

1. 全局变量区 :55-81（AUDIT:58 / CHECK_UPDATES:61 / AUDIT_LOCK_FILE:81）
2. parse_args case :476-586（--audit:507 / --check-updates:509 / --audit-lock:520 带值）
3. 缺目标地址豁免 :4382
4. sync_ignored 条件 :4446-4453（doctor 要加入：写出参数在 doctor 下不生效）
5. 互斥 die 区 :4458-4466（三条两两互斥；措辞含「请分两次运行」）
6. 模式不生效列表：upd_ignored:4479-4501 / ignored:4504-4528 / lock_ignored:4531-4552
7. regctl_path_active :4562-4565（doctor 进条件，成第四消费者，注释三处→四处）
8. 镜像收集 :4579-4595（audit-lock 走 parse_lockfile；else collect_images+apply_filters；
   setup_src_auth:4595 在后）
9. 入口数量日志 :4653-4664（四分支）
10. WORK_DIR 与 trap :4669-4672（mktemp -d + trap cleanup EXIT）
11. dry-run 计划 :4674-4676（条件需排除 doctor）
12. 主分发 :4680-4692（audit-lock → audit → check-updates(set +e 接码) → dispatch_all）
13. 汇总与退出码 :4697-4713（各模式独立 return $?）

另：`--audit-lock × --src/--file` 互斥（4470-4472）不适用 doctor；`guard_output_paths`（4477）
对 doctor 无影响。

## probe_ref 分类（:2113-2139）

- stderr 捕获：`err="$(skopeo_inspect_raw "$ref" 2>&1 >/dev/null)"`——`2>&1` 必须在 `>/dev/null` 前
- **ok**：rc=0
- **missing**：rc≠0 且 stderr 匹配 `manifest unknown|name unknown|repository name not known|not found|no such manifest`
- **unreachable**：其余全部——**unauthorized 目前折在这里**，doctor 新增「未授权」层用
  `unauthorized` / `authentication required` 关键词（TROUBLESHOOTING:17 快速定位表同款判据）
- 首行提取惯用法（:2138）：`printf '%s' "$err" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -n 1 || true`
- 底层 `skopeo_inspect_raw`（:727-740）已带 TLS_VERIFY/SRC_AUTHFILE 语义——**doctor 直接复用**

## 凭证路径

- 三入口：命令行单套（:526-535）/ `--src-credentials` 文件（:536-538）/ 环境变量（main:4356-4379，
  注意 `SYNC_SRC_CREDENTIALS` 的值是**文件内容**非路径，落 600 临时文件）
- `setup_src_auth`（:1516-1590）已有预检：混用 die（1522）/ 文件不存在 die（1536）/
  权限过宽 warn（1541-1545，find -perm -0044 输出非空判，不看退出码）/ 行格式错 die
  （parse_src_credentials:1482-1484）/ 空文件 die（1548）/ 单套多 host 推导+warn（1587-1589）
- **预检缺口**：`--src-credentials` 模式下未匹配 host **静默走匿名**（usage:364 自认）——
  doctor 要列漏配 host
- 装载：`write_src_authfile`（:1493-1514）jq 拼 auth.json（base64 user:pass）
- **目标凭证脚本不管**：来自 docker login（:1597-1599 注释明说）；regctl 路径
  `prepare_regctl_cred_dir`（:1602-1633）jq `*` 合并 DOCKER_CONFIG 与 SRC_AUTHFILE
- cleanup（:1638-1642）删四个临时产物

## 磁盘预检（:1119-1134，内嵌 prepare_oci_staging 非独立函数）

`need = est×12×CONCURRENCY/10 + 104857600`（×1.2 并发放大 + 100MB 底数）对
`df -Pk "$tmpdir" | awk 'NR==2 {print $4*1024}'`。doctor 复用 df 行 + 借鉴公式，
不做网络 inspect 估算。

## TROUBLESHOOTING.md（docs/ 下，712 行 17 条目，锚点=GitHub 中文自动 slug）

doctor 常用：**#3** `错误unauthorized-authentication-required`（:93）、
**#12** `自建-registry密码填对了却始终-unauthorized`（:442）、
**#9** `错误skopeo-command-not-found`（:333）、**#10** `错误regctl-下载失败已重试一次`（:363）、
**#8** `错误context-deadline-exceeded--timeout`（:311，注意双连字符）、
**#4** `错误denied-requested-access-to-the-resource-is-denied`（:179）、
**#7** 限流（:272）、**#5** `错误manifest-unknown`（:205）。
slug 规则：标点删、空格转连字符、`/` 与 `...` 两侧空格各转一连字符（#6/#8/#11 双连字符）。
文档 15-27 行「快速定位」表已内链这些锚点，CI 断言可互为印证。sync.sh 目前零引用。

## usage()（:244-469）与 modes.md（43 行）

- usage 小节：目标地址(252)/镜像来源(271)/筛选(275)/**可用性(281)**/源凭证(353)/
  性能与可靠性(375)/输出与通知(389)。三种检查全在「可用性」（299-351），格式：6 空格缩进
  + 续行 25 空格对齐；首两行一句话「回答什么问题」
- 退出码小节 :419-434（默认 0/1/2 + 各模式单独段）；示例小节 :436-467（检查示例 455-462）
- `--report-dir` 说明 :394-396 写「同步与三种检查均支持」——doctor 不落盘，措辞要顾
- modes.md：「检查对象」行全是「X vs Y」，doctor 进不了矩阵（加「矩阵之外」段）；
  互斥 die 区:19-25；铁律:27-31；四个 ignored 列表点名 :39-43
