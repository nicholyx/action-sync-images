# design：`--write-updates` 的输出契约

## 1. 签名

```bash
./scripts/sync.sh --check-updates --write-updates <路径> [--updates-limit N] ...
```

- 新全局：`WRITE_UPDATES=""`（解析于 `parse_args`）
- 写出者是 `check_updates_all()` 内部新增的一段（**与报告同源**：用同一份
  `UPD_REPOS` / `UPD_KNOWN_TAGS` / `missing`，不重算）

## 2. 文件契约

```text
# 由 scripts/sync.sh 生成于 <ISO8601>
#
# 这些是上游存在、而清单里没有的 tag。**本文件不会修改你的清单**——
# 升到哪个版本涉及兼容性判断，由你决定。
# 采用方式：把需要的行复制进清单文件，或直接用它当 --file 的输入。
#
# 注：屏幕上每个仓库最多显示 --updates-limit 条（默认 5），本文件列的是**全部**。

# registry.k8s.io/pause
registry.k8s.io/pause:3.10
registry.k8s.io/pause:3.9.2

# docker.io/library/nginx
docker.io/library/nginx:1.27.3
```

- **与 `--file` 兼容**：`#` 行是注释、空行忽略、每行一个引用 —— 生成的文件可直接喂回 `--file`
- 组内**版本序升序**（`sort -V`），组间按仓库首次出现的顺序（与报告一致，不额外排序）
- 无未收录 tag 时：头部照写，正文为空，并在头部的说明行里注明「本次没有需要补充的 tag」

## 3. 交互矩阵

| 模式 | `--write-updates` 的行为 |
|---|---|
| `--check-updates` | **生效**，写出文件 |
| 同步（默认） | 进「本次不生效」合并告警 |
| `--audit` | 同上（进 `ignored` 列表） |
| `--audit-lock` | 同上（进 `lock_ignored` 列表） |
| 与 `--report-dir` 同用 | 两者都写，互不影响（一个给机器、一个给人粘贴） |
| 与 `--updates-limit` 同用 | `limit` 只影响屏幕；**文件写全部**，并在日志里说明差异 |

## 4. 退出码

不变。写出文件成功与否**不改变** `--check-updates` 的既有退出码语义（0 / 2）。

## 5. 写失败时的处置 —— **实现时必须先核实再选**

两个先例口径不同：`--report-dir` 的落盘失败**中断**（报告是这个模式的产物），
`--write-lock` 的失败**只告警**（锁文件是同步之外的附加产物）。

选哪一个要有理由，并在代码注释与 PR 里写明。**判断依据**：`--write-updates` 与
`--check-updates` 的关系更接近哪一对——它是该模式的**产物**（人就是为它来的），
还是**附加物**（人主要是来看检查结果的）？

## 6. 测试要求

| 落点 | 断言点 |
|---|---|
| stub skopeo 的检查模式步骤（#158 留下的夹具，`/tmp/stub-skopeo`） | ① 文件存在且含全部未收录 tag（**不止 limit 条**，这条钉住 AC2）② 分组注释与升序 ③ 原清单**字节不变**（前后比对）④ 日志的「已写入 …（N 行）」与之一致 |
| 无未收录的场景（清单已覆盖） | 文件仍写出、头部注明「没有需要补充的 tag」 |
| 其他模式 | 各断一条「本次不生效」告警（与既有断言同一手法） |
| 兼容性 | 用生成的文件直接 `--file` 跑一次，断它能被解析（AC1 的实证） |

## 7. Wrong vs Correct

### Wrong

```bash
# 屏幕显示几条就写几条——把「展示口径」当成了「数据口径」
shown="$(printf '%s\n' "$missing" | sort -Vr | head -n "$limit")"
printf '%s:%s\n' "$repo" "$shown" >> "$WRITE_UPDATES"
```

后果：使用者看到文件里 5 行、以为上游只有 5 个新 tag，实际有 23 个——
**文件看起来是完整的，而它不完整**。这正是「错误的信息比没有信息更糟」。

### Correct

```bash
# 文件用**完整**的 missing（与 total_missing 同源），排序方向只影响观感
printf '%s\n' "$missing" | sort -V >> "$WRITE_UPDATES"
```
