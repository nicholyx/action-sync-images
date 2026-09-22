# fix: --strip-attestation 下 --tls-verify 与源仓库凭证不生效

对应 Issue：nicholyx/action-sync-images#120

## Goal

`--strip-attestation` 走 `sync_via_regctl`，它构造的命令既不带 TLS 设置也不带源凭证——
`--tls-verify false` 与 `--src-username` / `--src-password` / `--src-credentials` 在这条路径上
被**静默忽略**。后者让「私有源 + --strip-attestation」必然 401，且日志还照常打印
「源仓库凭证已装载」，把失败原因指向完全错误的方向。

本任务让这两者在 regctl 路径上真正生效，且**不修改使用者的全局配置**。

## Requirements

### R1 显式传入的参数必须生效

- `--tls-verify false` 时，regctl 与源、目标两个仓库的连接都不校验证书
  （与 skopeo 路径的 `--src-tls-verify=false --dest-tls-verify=false` 语义对齐）
- 配了源凭证时，regctl 访问源仓库要带上该凭证
- 两个参数在**未显式传入**时不得改变现状：使用者的 `~/.regctl/config.json` /
  `~/.docker/config.json` 里已配好的 TLS 与凭证必须继续按原样生效

### R2 不得污染使用者的全局配置

- **不写入、不修改** `~/.regctl/config.json`、`~/.docker/config.json`
- 需要临时配置时写进临时目录，退出时清理（纳入既有 `cleanup()`）
- 临时凭证文件权限 `600`、临时目录 `700`

### R3 凭证不进命令行

项目已确立此原则（见 `scripts/sync.sh` 的源凭证构造段注释）：

> 命令行参数对同机其他进程可见（ps aux），而 `--dry-run` 还会把命令原样打印出来。

因此凭证只能经文件传递，不得出现在 `regctl` 的参数表里。

### R4 dry-run 仍然诚实

`--dry-run` 必须复述**真正会执行的参数**。新增的 regctl 参数（TLS 与凭证来源）
都要如实出现在 dry-run 输出里；其中不含敏感信息的部分照常打印，凭证来源只打印
「目录/文件位置」而不打印内容。

### R5 不新增命令行参数

这是一次修复，不是新功能。`--tls-verify` 仍是布尔值，语义不变。

## Acceptance Criteria

- [ ] **AC1** 本地 HTTP 仓库上，`--strip-attestation --tls-verify false` 能完成推送；
      修复前同一命令以 `server gave HTTP response to HTTPS client` 失败
      （先复现红，再验绿）
- [ ] **AC2** 需要 Basic 认证的私有源上，`--strip-attestation` 配 `--src-username` /
      `--src-password` 能读取成功；去掉凭证则失败（证明凭证确实被使用，
      而不是恰好匿名可读）
- [ ] **AC3** 运行前后 `~/.regctl/config.json` 与 `~/.docker/config.json` 逐字节不变
- [ ] **AC4** `--strip-attestation` 运行时 `ps` 看不到源凭证
      （用固定字符串做诱饵，检查进程参数表）
- [ ] **AC5** 临时凭证目录在正常退出与中断（`SIGINT`）后都不残留
- [ ] **AC6** dry-run 输出包含新增的 TLS / 凭证来源参数，且不含凭证内容
- [ ] **AC7** 使用者已在 `~/.docker/config.json` 里登录目标仓库时，regctl 路径下
      该目标凭证**仍然可用**（即临时凭证目录是叠加而非替换）
- [ ] **AC8** 现有测试全绿：`smoke-test` 与 `integration-test` 两个 job
- [ ] **AC9** 集成测试里出现真实的 `--strip-attestation` + HTTP 仓库 + 私有源用例，
      且**不再**依赖手工写 `~/.regctl/config.json`（当前 #121 的步骤就是这么绕过去的，
      那一步的存在本身就是本缺陷的证据）

## Constraints

- 兼容 macOS 自带 bash 3.2（见 `.trellis/spec/engine/bash-rules.md`）
- 退出码语义不变：0 成功 / 1 参数或环境错误 / 2 至少一个镜像失败
- `--tls-verify false` 在 regctl 路径下映射为**明文 HTTP**（`tls=disabled`），
  与 skopeo 的 `--tls-verify=false`（HTTPS 且不校验证书，并会回退 HTTP）**不完全等价**：
  自签 HTTPS 证书的场景在本路径下不适用。这是取舍而非疏漏，必须在使用文档里写明，
  并在该组合生效时给出一条可见的说明（见 R1 与 design.md 的取舍章节）

## Out of Scope

- 不支持 `tls=insecure`（自签证书）——需要它的话应通过使用者自己的
  `~/.regctl/config.json` 表达，本任务只负责不破坏它
- 不处理 `--retries` / `--retry-delay`（已有告警，见 `sync.sh` 的 `_EXPLICIT` 分支）
- 不修改 `ensure_regctl` 的下载重试（那是 Issue #122）

## Notes

- 判定本任务是否完成，看 AC1–AC9；其中 AC1/AC2 必须有「修复前失败」的对照证据
- AC7 是防回归的关键：`DOCKER_CONFIG` 是**替代**语义而非叠加，
  直接指向临时目录会让使用者已有的目标仓库登录凭证消失（详见 design.md）
