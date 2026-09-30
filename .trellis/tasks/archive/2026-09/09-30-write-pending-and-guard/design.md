# design：`--write-pending` 的输出契约与输出路径守卫

## 1. 签名

```bash
./scripts/sync.sh --file images.lock.txt --dest <前缀> --audit --write-pending <路径>
```

- 新全局 `WRITE_PENDING=""`（`parse_args` 解析）
- 写出者是 `audit_all()` 内新增的一段，**与报告同源**（用同一批 `A_SRC` / `A_STATE`，
  不重算、不重新推导源引用）

## 2. 文件契约（与 `--write-updates` 同形）

```text
# 由 scripts/sync.sh 生成于 <ISO8601>
#
# 这些是清单与目标仓库存在差距的项（落后 / 缺失），需要重新同步。
# **本文件不会修改你的清单**——它只是一份可直接喂回 --file 的子集。
# 用法：./scripts/sync.sh --file <本文件> --dest <前缀>
#
# 注：另有 N 个「无法判定」未列入——它们是否需要同步无从得知，
#     见报告正文与运行日志。

# registry.k8s.io/pause
registry.k8s.io/pause:3.9
registry.k8s.io/pause:3.10
```

- 正文只有 `落后` + `缺失`；**`无法判定` 不列入**（AC3），但个数必须出现在头部
- `excluded`（被 `--filter` / `--exclude` 排除）**一律不列入**
- 同一个源**只出现一次**（多目标时记录是「源 × 目标」多条）
- 组内 `sort -V` 升序 —— 与 `--write-updates` 同一个方向、同一个理由（给人整段粘贴）

## 3. 交互矩阵

| 模式 | `--write-pending` 的行为 |
|---|---|
| `--audit` | **生效**，写出文件 |
| 同步（默认） | 进「本次不生效」合并告警 |
| `--check-updates` | 同上（`upd_ignored`） |
| `--audit-lock` | 同上（`lock_ignored`） |
| 与 `--report-dir` 同用 | 两者都写，互不影响 |
| 与 `--write-updates` 同用 | **不可能同时生效**（前者要 `--audit`、后者要 `--check-updates`，两模式互斥）——各自在自己模式下走「不生效」告警即可，不必额外校验 |

## 4. 输出路径守卫（AC9 / AC10）

### 规则

**写出参数的目标路径，不得与本次读入的任何文件是同一个文件。**

读入集合：`SOURCE_FILES`（所有 `--file`）、`SRC_CREDENTIALS_FILE`（`--src-credentials`）、
`AUDIT_LOCK_FILE`（`--audit-lock`）。写出参数：`WRITE_UPDATES` / `WRITE_PENDING` / `WRITE_LOCK`。

### 判据用 `-ef`，不用字符串比较

`[[ "$out" -ef "$in" ]]` 按 **inode + device** 比较，因此 `./images.lock.txt`、
`images.lock.txt`、软链接指向同一文件**都能命中**；字符串比较这三种都会漏。

**注意**：`-ef` 要求两侧都存在。输出路径若还不存在（正常情形），`-ef` 为假——正是想要的。
输入侧已由既有的文件存在性校验保证。

### 落点与时机

- 一处函数（如 `guard_output_paths`），在**启动校验区**调用——**动手之前**，
  早于任何网络请求与任何写出（`--write-lock` 的写出在同步循环之后，但守卫必须早于它）
- 命中即 `die`（退出码 1：参数错误），文案要点明「输出路径与输入文件相同」+ 分别是哪个参数

### 为什么一处实现

同一个洞在三个参数上各修一遍是「改一处漏一处」的温床——本仓库反复记过这条。
新增写出参数时只加一行注册，不改判据。

## 5. Wrong vs Correct

### Wrong

```bash
# 字符串比较：同一文件的三种写法里，两种会漏
if [[ "$WRITE_UPDATES" == "${SOURCE_FILES[0]}" ]]; then die ...; fi
```

### Correct

```bash
guard_output_paths() {
  local out_name out_path in_path i
  for spec in "write-updates:$WRITE_UPDATES" "write-pending:$WRITE_PENDING" "write-lock:$WRITE_LOCK"; do
    out_name="${spec%%:*}"; out_path="${spec#*:}"
    [[ -n "$out_path" ]] || continue
    for in_path in "${SOURCE_FILES[@]}" "${SRC_CREDENTIALS_FILE:-}" "${AUDIT_LOCK_FILE:-}"; do
      [[ -n "$in_path" ]] || continue
      if [[ "$out_path" -ef "$in_path" ]]; then
        die "--${out_name} 的输出路径与本次读入的文件是同一个：${out_path}（拒绝覆盖它）"
      fi
    done
  done
}
```

（`SOURCE_FILES` 可能为空 → **遍历前先判长度**，或像上面那样用 `:-` 兜住；
bash 3.2 + `set -u` 下空数组的 `"${arr[@]}"` 会抛 unbound variable。）

## 6. 测试要求

| 落点 | 断言点 |
|---|---|
| stub 驱动的审计步骤（有 registry 的集成测试，或 stub skopeo 的 audit 步骤） | ① 文件含且仅含「落后 + 缺失」的源引用，条数 = 报告里的 stale + missing；② 同一个源出现**一次**（夹具要有「一个源 × 两个目标」）；③ 头部报出 unknown 个数；④ excluded 不在文件里；⑤ 原清单字节不变；⑥ 日志「已写入 …（N 行）」与文件一致 |
| 无待同步项 | 仍写出文件并注明 |
| 其他三种模式 | 各一条「本次不生效」告警 |
| 守卫 | ⑦ `--write-updates <清单路径>` → 退出码 1 且清单字节不变；⑧ `--write-pending <清单路径>` 同上；⑨ `--write-lock <清单路径>` 同上；⑩ **三种写法**（`./x`、`x`、软链接）至少覆盖一种；⑪ 正常路径（输出到别处）不误伤 |