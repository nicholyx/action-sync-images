# regctl 路径的真实推送从未被集成测试覆盖

## Goal

让 `--strip-attestation`（**唯一**走 regctl 路径的选项）的**真实推送**进 CI 覆盖——目前它只在 dry-run 与参数层面被测过。

## Background

### 现状

`sync_via_regctl` 是与默认 skopeo 路径**完全不同的实现**：它用 `regctl index create` 重建索引、逐平台复制子镜像、只保留指定平台（从而排除 attestation manifest）。

而 `integration-test` job（真实推送、本地 `registry:2`）里：

| 检查 | 结果 |
| --- | --- |
| `--strip-attestation` 出现次数 | **0** |
| job 是否装了 regctl | **否** |

所以这条路径的**真实行为**从未被验证过。

### 为什么危险

项目自己记过这条教训，写在两处（`.github/workflows/ci.yml` 与 `.trellis/spec/engine/index.md`）：

> **真实路径**的行为进了 CI 集成测试（用本地 `registry:2`）——dry-run 覆盖不到真实推送，**v1.1.0 的三个缺陷全部发生在那里**

dry-run 能验证的只有「计划怎么渲染」「参数怎么解析」；`regctl index create` 实际执行时的问题——命令拼接、平台参数传递、逐平台复制、索引重建、推送结果——**一概覆盖不到**。

### 触发条件与可测性

入口是 `STRIP_ATTESTATION == "true"` → `sync_one` → `sync_via_regctl`。

**不需要源镜像真的带 attestation**：这条路径的语义是「重建一个只含指定平台的索引」，对普通镜像同样成立。所以用本地 registry 里的普通镜像就能覆盖它——这正是本次补测可行的原因。

## Requirements

- **R1** **不预装 regctl**——脚本的 `ensure_regctl` 内置了获取逻辑：`command -v regctl` 不存在时从 GitHub release 下载到 `$HOME/.regclient/bin` 并 `export PATH`，失败则 `die`。让用例走这条真实路径：它既是使用者在 CI 之外会遇到的样子，也顺带覆盖了 `ensure_regctl` 本身

  > 初稿写的是「job 预装 regctl，版本与 `REGCTL_VERSION` 一致」。查证后发现脚本**自己会下载**（`scripts/sync.sh:738`），预装反而绕开了被测代码。
- **R2** 新增一个用例：**真实推送**走 regctl 路径（`--strip-attestation --platforms <显式平台>`）
- **R3** 断言结果正确：目标存在、且**目标的平台集合等于指定的那个**（这是 regctl 路径区别于 skopeo 路径的核心语义）
- **R4** 与既有用例同风格：真实 `registry:2`、不新增 secret。**注意该 job 本就依赖外网**（既有用例用 `skopeo copy` 从 `docker.io` 拉 `hello-world` 当素材），所以 regctl 从 GitHub release 下载不改变这个前提
- **R5** 不改 `sync.sh`——只补测试

## Acceptance Criteria

- [ ] 用例在**没有预装 regctl** 的环境下能通过（即 `ensure_regctl` 的下载路径真的可用）
- [ ] 新用例真实推送走 regctl 路径并通过
- [ ] 断言覆盖「**目标的平台 = 指定的平台**」（不只是「推送成功」）
- [ ] **反证**：把 `sync_via_regctl` 的产物改坏（例如让它复制全部平台），该用例应当失败——证明断言不是恒真
- [ ] 既有用例不受影响（该 job 其余步骤仍通过）
- [ ] 不新增 secret、不改 job 的其他步骤
- [ ] `actionlint` / `yamllint` / `./scripts/lint.sh` 全绿

## Out of Scope

- **不测「真的带 attestation 的镜像」**：构造那样的源镜像需要 BuildKit 与额外步骤，而它**不改变这条路径的覆盖**——`regctl index create` 的行为与源镜像是否带 attestation 无关（带 attestation 只是现实中触发它的原因）
- **不改 regctl 路径的实现**：本任务只补覆盖，发现缺陷再另开
- **不动 smoke-test**：那里的 dry-run 覆盖（计划渲染、平台列表解析、参数告警）已经足够，重复测没有收益
- **不把 `--strip-attestation` 加进其他 job**
