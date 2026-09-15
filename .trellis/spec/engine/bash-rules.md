# bash 硬规则（全部真实踩过）

兼容 macOS 自带 bash 3.2。CI 是 bash 5，**所以违反这些规则的缺陷只在本地暴露**——CI 绿不代表没问题。

## 语言禁忌（bash 3.2 没有）

- 禁 `declare -A`（关联数组）、`mapfile` / `read -a`、`wait -n`、`tac`
- 去重用 `awk '!seen[$0]++'`，排序用外部 `sort`，倒序遍历用下标循环
- 多键数据用**下标对齐的并行数组**（`DEST_REGISTRIES`/`DEST_MODES`、`UPD_REPOS`/`UPD_KNOWN_TAGS` 是范本）

## 空数组与 `set -u`

- `"${arr[@]}"` 在数组为空时的展开，bash 3.2 + `set -u` 会抛 **unbound variable**（bash 4.4+ 才改掉）。触发条件真实发生过：配了 webhook 的同步在 macOS 上「同步成功却非零退出」（v1.7.0 修复，PR #64）
- 遍历前必须 `if [[ ${#arr[@]} -gt 0 ]]`。`collect_images` 里早有同源注释，仍漏过一处——**改完全文件搜一遍遍历**

## 退出码与进程模型（同一类问题的四个面孔）

- **包装函数不得吞退出码**：结尾不写 `return 0`，写 `return $?` 或什么都不写。曾让 401 失败的同步被记成成功（CI 当场抓到）
- **命令替换是子 shell**：`var="$(fn)"` 里 fn 对全局变量的赋值传不回父进程，`set -u` 下读会炸。多值传出用全局变量 + 返回码
- **`output="$(cmd)"` 的退出码就是 cmd 的退出码**：errexit 下 cmd 失败会在 `echo "$output"` 之前中断步骤、吞掉全部输出。可能失败的命令用 `set +e` 包裹后再捕获
- **`if state="$(a | b)"` 的管道退出码默认只看最后一个命令**：a 失败而 b 对空输入「成功」时，整条管道按成功处理——除非调用方恰好开了 `pipefail`。「失败时输出 unknown、成功时输出判定值」这类语义不能依赖调用方的 shell 选项（函数会被 CI 单测提取到独立上下文执行，行为随上下文翻转）。分段查退出码，让失败有显式输出值：

  ```bash
  # 错：gh api 失败时 jq 对空输入照样成功，unknown 永远走不到
  if state="$(gh api "$url" | jq -r '...')"; then
    :
  else
    state="unknown"
  fi

  # 对：分段判，unknown 是保守默认
  state="unknown"
  if api_out="$(gh api "$url" 2>/dev/null)"; then
    state="$(printf '%s\n' "$api_out" | jq -r '...')" || state="unknown"
  fi
  ```

  （Issue #87 的质量检查阶段发现：`confirm_artifact_exists` 若整条管道一起判，「API 查不动」会静默落成 `absent`——无法判定冒充正常，恰是那个任务要消除的混淆。范本见 `scripts/history.sh`）
- **`find` 的退出码只表示「遍历成功」**，与是否匹配无关；按「有没有匹配」判断要看输出非空

## printf 与字段分隔

- `printf '%s'` **不输出结尾换行**，配 `while IFS= read -r` 会**丢掉最后一段**（read 遇 EOF 返回非零）。必须 `printf '%s\n'`。曾导致 regctl 路径静默丢平台（Issue #27）
- 结果文件字段分隔用 `$'\x1f'`（`FIELD_SEP`，见 `scripts/sync.sh` 的 `readonly FIELD_SEP`）。tab 是 IFS 空白，空字段会让后续字段整体左移
- 结果数组按序号对齐（下标同时决定结果文件序号），**标记而非删除**（`EXCLUDE_REASONS` 是范本）
- bash 内嵌 Markdown 反引号写在 `printf` 的**双引号**格式串里，避免 shellcheck SC2016

## dry-run 的铁律

`--dry-run` 的输出必须复述**真正会执行的参数数组**，不是拿输入重新拼一遍。两者看似一样，脱节时 dry-run 就失去了全部意义——丢平台缺陷长期未被发现正是因为它。

## 静态检查

- 本地新版 shellcheck 与 CI 旧版报错不一致：`A && B || C` 不是 if-then-else（SC2015），用 `if` 表达意图
- 注释里出现 shellcheck 指令字样会被当成真指令，触发莫名的 SC1073——改措辞
- 数组下标在算术上下文里不带 `$`（`arr[idx]` 不是 `arr[$idx]`，SC2004）
