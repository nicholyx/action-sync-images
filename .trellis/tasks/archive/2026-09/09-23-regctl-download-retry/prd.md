# fix: ensure_regctl 的下载没有重试

对应 Issue：nicholyx/action-sync-images#122

## Goal

`ensure_regctl`（`scripts/sync.sh:766`）在找不到 regctl 时从 GitHub release 下载，
**一次失败就 `die`**：

```bash
curl -fsSL "$url" -o "${bindir}/regctl" || die "regctl 下载失败：${url}"
```

而同一份代码里其他网络操作都遵循统一口径——「重试一轮、固定间隔、不做参数化」。
问题在 #121 之后被放大：CI 的 runner 环境是干净的，`command -v regctl` 必然不命中，
于是**每次 CI 都要下载一次**，脚本没有第二次机会，一次网络抖动就整条流水线红。

## Requirements

### R1 与既有口径对齐

失败后**重试一轮**，间隔固定 5 秒，**不做参数化**（不加 `--retry-times` 之类的开关——
取舍理由见 `history.sh` 批量重试处的注释）。

参照 `scripts/history.sh` 的 `gh run list` 那段：

```bash
if [[ "$list_rc" -ne 0 ]]; then
  log_warn "获取运行列表失败，重试一次（多为网络抖动）..."
  sleep 5
  list_rc=0
  <cmd> || list_rc=$?
  [[ "$list_rc" -eq 0 ]] && log_info "重试成功"
fi
```

### R2 重试成功要看得出来

与既有风格一致：重试后成功打印「重试成功」。**不打印的话，「重试过」这件事就消失了**——
使用者看到的是一次平平无奇的下载，而实际发生了一次网络故障。

### R3 仍失败时如实报错

保留下载 URL，并在文案里体现「已重试一次」，与 `history.sh` 的
`die "获取运行列表失败（已重试一次）：..."` 同构。

### R4 失败的下载不得留下可被误用的半成品

`curl -o <目标>` 在失败时会留下**不完整的文件**。当前实现只在成功路径
`chmod +x`，所以半成品不会被执行；但 `$bindir` 下的 `regctl` 是个固定名字，
后续运行（或使用者手工把它加进 PATH）会撞上它。

下载应落到临时文件、成功后再原子替换到目标路径。这不属于「对齐口径」，
而是这个改动**必须**顺带处理的问题——重试让「同一个目标文件被写两次」成为常态。

## Acceptance Criteria

- [ ] **AC1** 第一次 `curl` 失败、第二次成功时，脚本继续正常执行，退出码 0，
      且输出里能看到「重试成功」
- [ ] **AC2** 两次都失败时，`die` 的文案含「已重试一次」与下载 URL（退出码 1）
- [ ] **AC3** 失败的下载不留下目标路径上的文件（断言 `${bindir}/regctl` 不存在）
- [ ] **AC4** 成功路径行为不变：文件可执行、`PATH` 被前置、打印 `regctl 已就绪：<版本>`
- [ ] **AC5** CI 集成测试仍全绿（它每次都要走这条下载路径，是真实回归面）
- [ ] **AC6** 本地 `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿

## Constraints

- 兼容 macOS bash 3.2（见 `.trellis/spec/engine/bash-rules.md`）
- 重试的中间文件要能进 `cleanup()`，中断时不留垃圾
- 不改 `REGCTL_VERSION`、不改下载源 URL
- `dry-run` 下不下载的既有行为保持不变

## Out of Scope

- **不给 CI 加 `actions/cache` 缓存 `$HOME/.regclient/bin`**（Issue #122 期望里的第 4 条，
  评估结论是**不做**）。理由：CI 里这条下载路径**本身是被测代码**——#121 的注释写得很明白，
  「不预装 regctl：脚本的 ensure_regctl 会自己下载，预装反而绕开了它」。加缓存会让
  测试不再走下载路径，用一个长期存在的覆盖缺口换取几十秒，不划算。本 issue 的重试
  已足够降低失败面
- 不做「下载前校验已有文件完整性」（那是另一个能力，没有证据表明需要）

## Notes

- 判定完成看 AC1–AC6。AC1/AC2/AC3 都需要**用 mock `curl` 制造失败**才能验——
  真实网络抖动无法按需复现。mock 时注意：本仓库既有做法是用 PATH 前置的 mock 二进制
- 「重试一轮」是个刻意的上限，不是「重试到成功」：无上限的重试会让真正的
  配置错误（URL 失效、版本不存在）变成一次长时间的挂起