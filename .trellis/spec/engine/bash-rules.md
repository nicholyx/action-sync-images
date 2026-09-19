# bash 硬规则（全部真实踩过）

兼容 macOS 自带 bash 3.2。CI 是 bash 5，**所以违反这些规则的缺陷只在本地暴露**——CI 绿不代表没问题。

## 语言禁忌（bash 3.2 没有）

- 禁 `declare -A`（关联数组）、`mapfile` / `read -a`、`wait -n`、`tac`
- 去重用 `awk '!seen[$0]++'`，排序用外部 `sort`，倒序遍历用下标循环
- 多键数据用**下标对齐的并行数组**（`DEST_REGISTRIES`/`DEST_MODES`、`UPD_REPOS`/`UPD_KNOWN_TAGS` 是范本）

## 空数组与 `set -u`

- `"${arr[@]}"` 在数组为空时的展开，bash 3.2 + `set -u` 会抛 **unbound variable**（bash 4.4+ 才改掉）。触发条件真实发生过：配了 webhook 的同步在 macOS 上「同步成功却非零退出」（v1.7.0 修复，PR #64）
- 遍历前必须 `if [[ ${#arr[@]} -gt 0 ]]`。`collect_images` 里早有同源注释，仍漏过一处——**改完全文件搜一遍遍历**

## 退出码与进程模型（同一类问题的不同面孔）

- **包装函数不得吞退出码**：结尾不写 `return 0`，写 `return $?` 或什么都不写。曾让 401 失败的同步被记成成功（CI 当场抓到）
- **命令替换是子 shell**：`var="$(fn)"` 里 fn 对全局变量的赋值传不回父进程，`set -u` 下读会炸。多值传出用全局变量 + 返回码
- **`output="$(cmd)"` 的退出码就是 cmd 的退出码**：errexit 下 cmd 失败会在 `echo "$output"` 之前中断步骤、吞掉全部输出。可能失败的命令用 `set +e` 包裹后再捕获
- **`if cmd | tail -1; then` 判断的是 tail 的退出码，不是 cmd 的**：管道接 `tail` / `head` / `wc` 后，无论 `cmd` 成败，if 恒真——「显示失败、远端已成功」与「显示成功、实际没执行」都会被吞掉。2026-09-16 发布 v1.14.0 时同款错误连犯两次：`gh pr merge | tail -1` 让合并没有发生却报了成功，tag 因此打在错误提交上；重推 `git push | tail -1` 让 push 失败被误读为成功，release 空窗了一个小时。判断成败用 `if out="$(cmd 2>&1)"`，输出用完再处理；对 push / merge 这类非幂等操作，判断之后再用 `ls-remote` / `gh pr view` 复核远端真实状态
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
- **进程替换 `< <(...)` 不传递退出码**。`done < <(cmd 2>/dev/null || true)` 里 `$?` 是 `while` 的、不是 `cmd` 的，`|| true` 又把失败吞掉——**「请求失败」与「结果为空」混成一种**。网络故障于是被报成「数据不存在」，把排查引到完全错误的方向：`gh run list` 失败时报的是「没有取到任何运行记录，请确认工作流至少跑过一次」，而实际上换一次网络就查到了（#98，2026-09-16 验证 #97 时踩到，2026-09-19 修）。
  需要退出码就**重定向到文件再读**：`cmd > out 2> err || rc=$?`，**判完退出码再决定怎么解释输出**（顺序反了，失败仍会掉进「空结果」分支）。stdout 与 stderr 也要分开落文件——合到一处，报错文本会被下游的 `read` 循环当成数据。范本见 `scripts/history.sh` 的 `download_reports`

## 函数会被单独抽取执行

CI 用 `sed -n "/^${fn}()/,/^}/p"` 把生产函数整段抽到独立上下文里跑（`write_report`、`emit_summary`、`collect_rerun_items`、`duration_ranking_rows` 等，见 `.github/workflows/ci.yml` 的「验证重跑指引」「验证耗时排行」）。**被抽取的函数必须自包含**：

- **不能依赖运行级全局变量**。`write_report` 的中间记录文件曾按检查模式的样子写成 `${WORK_DIR}/...`——在抽取上下文里没有 `WORK_DIR`，`set -u` 下当场 unbound variable。平时运行完全不报错，只有 CI 那一步会炸（#103，2026-09-19）。同一个文件里 `duration_ranking_rows` 也引用 `FIELD_SEP`，但它在命令替换的子 shell 里且报错被吞，所以不致命——**父 shell 展开与子 shell 展开的危险程度不同**
- **需要临时文件就自己 `mktemp` + `rm -f`**，不要借用运行期的临时目录：函数的一次性中间文件不该依赖别人创建、别人清理的目录
- 改测试夹具补一个全局变量也能让它过——**但那是让生产代码迁就测试**。抽取面的存在本身就是提醒：这个函数要能被独立调起

自检：写完一个函数，先想「把它单独 source 进一个只有我自己声明变量的脚本里，还能跑吗」。

## printf 与字段分隔

- `printf '%s'` **不输出结尾换行**，配 `while IFS= read -r` 会**丢掉最后一段**（read 遇 EOF 返回非零）。必须 `printf '%s\n'`。曾导致 regctl 路径静默丢平台（Issue #27）
- 结果文件字段分隔用 `$'\x1f'`（`FIELD_SEP`，见 `scripts/sync.sh` 的 `readonly FIELD_SEP`）。tab 是 IFS 空白，空字段会让后续字段整体左移
- 结果数组按序号对齐（下标同时决定结果文件序号），**标记而非删除**（`EXCLUDE_REASONS` 是范本）
- bash 内嵌 Markdown 反引号写在 `printf` 的**双引号**格式串里，避免 shellcheck SC2016

## dry-run 的铁律

`--dry-run` 的输出必须复述**真正会执行的参数数组**，不是拿输入重新拼一遍。两者看似一样，脱节时 dry-run 就失去了全部意义——丢平台缺陷长期未被发现正是因为它。

**dry-run 报出的耗时必须如实为 0。** 它没有真的搬过任何东西，但 `process_one` 的 `elapsed=$((end - start))` 照常计时，于是偶发报出「1s」——这个数字会进报告、进耗时排行，并让「耗时全为 0 时排行应隐去」那条断言偶发误报（2026-09-19 在 #103 的 PR 上把整个 smoke-test job 带崩过一次，重跑即绿）。判据是「**有没有真的搬过**」，不是「这段代码跑了多久」。

**本条的落实状态：尚未修改**（截至 2026-09-19）。记录在此，是为了让下一个碰到那条断言的人知道它的脆弱是有原因的，而不是随机的 flaky。

## 静态检查

- 本地新版 shellcheck 与 CI 旧版报错不一致：`A && B || C` 不是 if-then-else（SC2015），用 `if` 表达意图
- 注释里出现 shellcheck 指令字样会被当成真指令，触发莫名的 SC1073——改措辞
- 数组下标在算术上下文里不带 `$`（`arr[idx]` 不是 `arr[$idx]`，SC2004）
