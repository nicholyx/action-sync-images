# 技术设计：重跑指引

## 1. 边界与落点

**只动 `scripts/sync.sh` 一个文件。** 不碰工作流 YAML、不碰 `history.sh`、不碰通知路径。

| 类型 | 位置 | 说明 |
| --- | --- | --- |
| 新增 | `collect_rerun_items()` | 唯一聚合函数，产出失败集与计数（全局变量传出） |
| 新增 | `ere_escape()` | ERE 元字符转义 |
| 新增 | `render_rerun_section()` | 渲染 markdown 片段，Step Summary 与 md 报告共用 |
| 新增 | `rerun_style()` | 依据当前工作流决定形态（清单 / 正则） |
| 修改 | `emit_summary()`（`scripts/sync.sh:3078`） | Step Summary 在「合计」之后插入重跑节 |
| 修改 | `write_report()`（`scripts/sync.sh:3182`） | md 插入同一片段；json 在 `"images"` 之前插入 `"rerun"` 字段 |

**不新增命令行参数**——因此无需维护 `main()` 里的「显式传入不生效」告警矩阵（`spec/engine/modes.md:38-40`）。这是刻意的：新参数的表面积不值当。

## 2. 数据流与单一来源

```
R_SRC / R_STATUS / R_NOTE / R_DEST        （并行数组，emit_summary 时已在内存）
              │
              ▼
      collect_rerun_items()               ← 唯一一次计算
              │  全局变量传出：
              │   RERUN_IMAGES[]          可重跑的源镜像（去重、保序）
              │   RERUN_FILTER            锚定正则（Batch 形态用）
              │   RERUN_NOT_RERUNNABLE    被排除的计数
              ▼
      render_rerun_section()              ← 唯一一次渲染
              │
     ┌────────┼────────┐
     ▼        ▼        ▼
  Step Summary  md 报告  json 字段
```

`R_*` 数组是全局的（`scripts/sync.sh:131-138`），`emit_summary` 与 `write_report` 同进程同调用链，因此聚合结果可安全用全局变量传出（**不用命令替换**——那是子 shell，赋值传不回父进程，这是本仓库已确立的规则）。

## 3. 契约

### 3.1 可重跑的判定

一条记录可重跑，当且仅当：

1. `R_STATUS[i] == failed`
2. 且 `R_NOTE[i]` **不以** `镜像引用格式错误` 开头

第 2 条的覆盖面已经过核对——`sync.sh` 里失败只有三种来源：

| 出处 | `note` 内容 | 可重跑 |
| --- | --- | --- |
| `scripts/sync.sh:1657` | `镜像引用格式错误：${reason}` | ❌ 重跑必然同样失败 |
| `scripts/sync.sh:1733` | `同步失败，详见上方日志` | ✅ |
| `scripts/sync.sh:1759` | `完整性校验失败：${detail}` | ✅（源可能已变，或属瞬时问题） |

### 3.2 清单条目

- 取 `R_SRC[i]`。它是**规范化后**的串（`normalize_ref` 已去掉 `docker://`，`scripts/sync.sh:1649`），与工作流 `images_src`「无需 docker:// 前缀」的约定一致。
- **按 `source` 去重、保序**（取首次出现顺序）。本仓库的工作流都是单目标，去重实际不触发；但 `sync.sh` 支持 `--dest` 重复，保留这一步以免本地多目标场景输出重复行。
- 排除项（`excluded`）与跳过项（`skipped`）不进入清单——它们不是失败。

### 3.3 锚定正则

```
^(docker://)?(<转义后的 ref1>|<转义后的 ref2>|...)$
```

- **必须锚定**：`--filter` 是部分匹配（`grep -Eq`，`scripts/sync.sh:1224`），不锚定则 `nginx:1.27` 会连带命中 `nginx:1.27-alpine`。
- **必须容忍 `docker://` 前缀**：filter 匹配的是 `SOURCE_IMAGES` 里的**未规范化**原始串，而报告里记的是规范化后的串，两者可能差一个前缀。
- **必须转义 ERE 元字符**：镜像引用里 `.` 常见，tag 里 `+` / `-` 常见；不转义则 `.` 变成通配。
  `ere_escape()` 覆盖：`\ ^ $ . [ ] | ( ) * + ? { }`
- 转义后用作 `grep -E` 模式，`|` 作为 or 连接符是刻意保留的（在拼接时加入，不参与转义）。

### 3.4 形态选择

依据**工作流文件名**判定（`GITHUB_WORKFLOW_REF` 形如 `owner/repo/.github/workflows/sync-images-batch.yml@refs/heads/main`），比 `GITHUB_WORKFLOW`（工作流 `name:` 字段）更抗改名：

| 当前工作流 | 形态 | 使用者要粘到哪 |
| --- | --- | --- |
| `sync-images-batch.yml` | 锚定正则 | `filter` 输入 |
| 其它 / 未设置（本地 CLI） | 镜像清单 | `images_src` 输入（本地则 `--src`） |

判定失败时**退化为镜像清单**：清单对任何入口都有参考价值，正则会误导。

### 3.5 json 字段

在 `"exclude"` 之后、`"images"` 之前插入（`"images"` 是该对象的最后一个字段，见 `scripts/sync.sh:3237-3254`）：

```json
"rerun": {"images": ["nginx:1.27"], "filter": "^(docker://)?(nginx:1\\.27)$", "not_rerunnable": 1},
```

- `filter` 里的 `\` 必须转义为 `\\`，否则 JSON 非法（手工 `printf` 拼接，没有 `jq` 兜底）。
- 无失败项时：`images` 为空数组、`filter` 为空串、`not_rerunnable` 为 0。字段**始终存在**，消费方不必判空。
- 镜像名内含 `"` 或 `\` 会破坏 JSON——这是**既有缺陷**（整个 `write_report` 都是裸拼接，`scripts/sync.sh:3229-3253`），不在本任务范围内修复，需另开 Issue 记录。

## 4. 呈现

### 4.1 清单形态（Aliyuncs / Harbor / 本地）

````markdown
### 重跑失败项

本次有 2 个镜像失败。复制下面的镜像列表，粘进本工作流的 `images_src` 输入，重新运行即可只重跑它们：

```
nginx:1.27
redis:7.2
```

> 另有 1 个因镜像引用格式错误，重跑不会成功，未列入。
````

### 4.2 正则形态（Batch）

````markdown
### 重跑失败项

本次有 2 个镜像失败。复制下面的正则，粘进本工作流的 `filter` 输入，重新运行即可只重跑它们：

```
^(docker://)?(nginx:1\.27|redis:7\.2)$
```

> 另有 1 个因镜像引用格式错误，重跑不会成功，未列入。
````

### 4.3 出现规则

- **无失败项 → 整节不出现**（含 json 字段为零值）。全绿不打扰。
- **dry-run → 不出现**。没有真正推送过，谈不上「重跑失败项」。
- **被排除项的计数行仅在计数 > 0 时出现**，措辞说明「为什么没列入」——对应原则 2「排除的东西必须可见」。

## 5. 兼容性

全部是**新增**内容，无迁移：

- json 新字段：`history.sh` 只读 `source` / `status` / `generated_at`（`scripts/history.sh:389-400`），不受影响。
- md 新小节、Step Summary 新小节：纯追加。
- 不新增参数 → 不动告警矩阵，不动 usage。
- 旧报告仍可被 `history.sh` 解析。

## 6. 取舍与被否掉的方案

| 决定 | 理由 |
| --- | --- |
| **不做成 `gh workflow run` 命令** | 受众是页面操作者，他们没装 `gh`；且本地 CLI 形态在私有源场景下必须携带凭证形态的说明，容易踩「凭证不进命令行」的红线。 |
| **不给 Batch 工作流加输入框** | 要动工作流 YAML，而工作流改动有 zizmor / actionlint 门禁，且本仓库历史上批量改 YAML 连续出错过。锚定正则能用现有 `filter` 输入达成同样效果，**没有收益的改动不该做**。 |
| **不把 `note` 写进报告** | 范围控制：那是报告信息丰度的独立缺口，改动面（schema + 三种检查的对称性）与验证方式都不同，另开 Issue。本任务只借用内存里的 `R_NOTE` 做判定，不改变它的落盘行为。 |
| **不沿用 `--filter` 的「被排除即可见」来兜底** | 被 `filter` 多带进来的镜像会显示为 `excluded`，但那是**事后**可见；本设计用锚定 + 转义把它变成**事前**不误命中。 |
| **`R_SRC` 而非 `R_DEST` 作为清单主体** | 重跑的输入是源镜像；目标地址由工作流自身决定（Batch/Harbor 的目标在工作流里拼），使用者不需要、也不应该手填目标。 |

## 7. 风险

| 风险 | 缓解 |
| --- | --- |
| ERE 转义漏字符 → 正则语法错误 | 拼接后**用 `validate_regex` 预先自检**（`scripts/sync.sh:1199-1209`，已有 `grep` 退出码 2 判据）；自检不过则降级为不给正则、只给清单 |
| 失败项极多 → 正则过长 | 正则长度无硬编码上限；`filter` 输入框亦无长度限制。若实际遇到再考虑封顶（不在本轮） |
| 正则误命中导致多同步 | 锚定后不可能误命中同前缀 tag；即使多带，`--skip-existing` 会让已成功的快速跳过 |
| bash 3.2 兼容 | 全文禁用 `declare -A` / `mapfile` / `wait -n`；数组遍历前判长度 |
| `GITHUB_WORKFLOW_REF` 缺失（本地） | 设计上即退化为清单形态，不报错 |

## 8. 回滚

纯新增渲染逻辑，无状态迁移、无存储变更。回滚 = revert 提交，旧行为立即恢复；已落盘的旧报告不受影响。

## 9. 测试策略

- **单元**：`ere_escape` 与锚定正则的拼接——按项目惯例，用 `sed -n '/^fn()/,/^}/p'` 提取生产函数加伪造输入，在 CI 步骤里内联执行。**必须断言**：`nginx:1.27` 锚定后不匹配 `nginx:1.27-alpine`、匹配 `docker://nginx:1.27`。
- **渲染**：`render_rerun_section` 在「有失败 / 无失败 / 有不可重跑项 / dry-run」四种输入下的输出。
- **集成**：`ci.yml` 里用 `GITHUB_STEP_SUMMARY="$summary"` 注入临时文件的既有手法（`.github/workflows/ci.yml:146`、`202`）断言重跑节出现/不出现。**断言匹配带图标的正文行或具体数值，不匹配状态词本身**——本项目在这条上真实翻过车。
- 所有断言**先在本地复现**（含 `bash -e` 语义）再进 CI。
