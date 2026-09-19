# 设计：让坏报告可见地跳过

## 边界

| 文件 | 改动 |
| --- | --- |
| `scripts/history.sh` | `main()` 里加一道预检；`filter_by_check()` 的告警文案分家 |
| `scripts/sync.sh` | `fetch_sync_history()` 的解析改为成败可见 |
| `.github/workflows/ci.yml` | 两个文件各补断言 |
| `CHANGELOG.md` | `[Unreleased]` → `### 修复` |

不新增函数以外的结构，不动聚合逻辑本身（`aggregate_by_image` 等一行不改）。

## 现状的三个层次

调研发现「坏报告」在代码里的处理其实**已经有过半成品**，但覆盖面与清晰度都不够：

| 位置 | 现状 | 问题 |
| --- | --- | --- |
| `history.sh` 主流程（非 `--check`） | `jq -s` 一次性读全部文件 | **一份坏则全废**，且报错不指出文件 |
| `history.sh` 的 `filter_by_check()` | 已有 `log_warn` 跳过 | 只覆盖 `--check` 模式；文案把「类型不匹配」和「无法解析」**混成一句** |
| `sync.sh` 的 `fetch_sync_history()` | `2>/dev/null \|\| true` | **完全静默**，导致连续失败计数偏小 |

`filter_by_check()` 的注释已经写着「一份坏文件不该毁掉整个趋势」——**这个判断早就有了，只是没推广到全部路径**。本任务做的就是把它提上去、并让两种原因各自可辨。

## 方案一：`history.sh` 加预检

### 落点

`main()` 的 `:936-952`，在 `collect_reports` 之后、`filter_by_check` **之前**：

```bash
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(collect_reports "$base")

  if [[ ${#files[@]} -eq 0 ]]; then
    die "在 ${base} 下没有找到任何 JSON 报告"
  fi

  # 必须先于 filter_by_check：它同样要读这些文件，坏文件在那里会被它的
  # `2>/dev/null || true` 静默吞掉——那是第二处静默，且文案与「类型不匹配」混在一起
  split_parsable_reports "${files[@]}"
  files=()
  if [[ ${#PARSABLE_REPORTS[@]} -gt 0 ]]; then
    files=("${PARSABLE_REPORTS[@]}")
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    die "共 ${#UNPARSABLE_REPORTS[@]} 份 JSON 报告，没有一份能解析。首个无法解析的是 ${UNPARSABLE_REPORTS[0]}"
  fi
  if [[ ${#UNPARSABLE_REPORTS[@]} -gt 0 ]]; then
    log_warn "跳过 ${#UNPARSABLE_REPORTS[@]} 份无法解析的报告：$(printf '%s、' "${UNPARSABLE_REPORTS[@]}")"
  fi
```

### 预检函数

```bash
# 把报告文件分成「能解析」与「不能解析」两组，结果经全局变量传出。
#
# 为什么需要：一份坏文件不该让全部趋势失效（jq -s 是一次读整批，一个坏则全废），
# 也不该被静默丢掉（少算的历史会让「连续失败次数」偏小、该响的告警不响）。
#
# 判据只到「是不是合法 JSON」为止，**不做结构校验**：报告 schema 会演进
# （v1.14 加了 rerun、v1.15 加了 note），旧报告缺新字段是正常的，判成「坏」
# 会让升级本身变成一次数据失效。
#
# 结果走全局变量：本文件对「命令替换是子 shell、赋值传不回父进程」有过多轮教训。
split_parsable_reports() {
  PARSABLE_REPORTS=()
  UNPARSABLE_REPORTS=()

  local f
  for f in "$@"; do
    if jq -e . "$f" >/dev/null 2>&1; then
      PARSABLE_REPORTS+=("$f")
    else
      UNPARSABLE_REPORTS+=("$f")
    fi
  done
}
```

放在 `filter_by_check` 附近（同属「准备文件列表」这一类）。

### bash 3.2 的空数组

上面两处都**显式判长度**后再展开 `"${arr[@]}"`，不是防御性啰嗦——bash 3.2 + `set -u` 下空数组展开会抛 unbound variable（`bash-rules.md` 第一条）。

## 方案二：`filter_by_check()` 的文案分家

预检已经拦下了「无法解析」，因此这里的 `else` 分支只剩一种含义：**类型不匹配**。

```bash
    if [[ -n "$match" ]]; then
      FILTERED_FILES+=("$f")
    else
      # 解析失败的已在 split_parsable_reports 里被拦下并告警，走到这里的
      # 是「能解析、但 check 字段不是我要的那个」——两种跳过原因必须分得开，
      # 否则使用者不知道该删文件还是该换 --check
      log_warn "跳过非 ${check_type} 的报告：${f}"
    fi
```

保留 `2>/dev/null || true`：预检之后它理论上不会失败，但这一层的防御不该因为上游的保证而拆掉。

## 方案三：`fetch_sync_history()` 改为成败可见

现在的写法把「解析失败」与「这个文件里没有 images」混为一谈：

```bash
jq -r 'select(.images != null) | …' "$f" >> "$out_file" 2>/dev/null || true
```

`select(.images != null)` 对**合法但没有 images 字段**的报告会输出空并通过——那是正常的（检查报告混在里面）。真正的失败只有 `jq` 非零退出。改成一次 jq、判退出码：

```bash
  : > "$out_file"
  local bad=0
  while IFS= read -r f; do
    # 一次 jq 同时完成「解析」与「提取」：失败就是这份报告读不了。
    # 不用「先 jq -e 预检、再 jq 提取」——那要跑两遍，且两次之间没有
    # 新增的保证（文件不会被中途改写）
    if out="$(jq -r 'select(.images != null) | .generated_at as $at
                       | .images[] | [$at, .source, .status] | join("\u001f")' "$f" 2>/dev/null)"; then
      [[ -n "$out" ]] && printf '%s\n' "$out" >> "$out_file"
    else
      bad=$((bad + 1))
      log_warn "历史报告无法解析，已跳过：$(basename "$f")"
    fi
  done < <(find "$tmpdir" -type f -name '*.json' 2>/dev/null)
  if [[ "$bad" -gt 0 ]]; then
    log_warn "共 ${bad} 份历史报告无法解析，连续失败次数的判断可能偏小"
  fi
```

最后那句是关键：**说清楚后果**。「跳过 3 份」是事实，「判断可能偏小」才是使用者需要据此调整的信息。

注意 `[[ -n "$out" ]] && printf …` 在 `set -e` 下安全（`&&` 列表的末命令未执行时不触发 errexit——`bash-rules.md` 记录过这条，实现时若改动这句话要重新确认）。

## 为什么两处不做成共享函数

`history.sh` 与 `sync.sh` 是两个独立脚本，没有 source 关系（各自可单独下载运行）。为一个 10 行的判断引入第三个共享文件，代价大于收益。两处的**行为**一致（跳过 + 计数 + 告警 + 说后果）比**代码**共享更重要——这也正是本任务的主题。

## 设计原型已验证（2026-09-20，macOS 自带 bash 3.2.57）

上述代码已抽出来实跑，不是「看起来对」：

| 核对项 | 结果 |
| --- | --- |
| `split_parsable_reports` 好+坏 | `good=1 bad=1`，分类正确 |
| 全坏 | `good=0 bad=1`（主流程据此 die 并指出首个坏文件） |
| 全好 | `good=1 bad=0` |
| 空数组赋值（`if [[ ${#arr[@]} -gt 0 ]]` 包裹） | bash 3.2 下安全，不抛 unbound variable |
| 一次 jq + 判退出码：好报告（有 images） | 退出码 0，输出写入 |
| 一次 jq + 判退出码：**合法但无 images**（检查报告混放） | 退出码 0、输出为空、**不写入也不计为坏**——这是最容易误判的一种，`select(.images != null)` 保证它不触发失败分支 |
| 一次 jq + 判退出码：坏 JSON | 非零退出 → 计入 `bad` 并告警 |

**一处写文档时的坑，记下来免得实现时重蹈**：上面 `join()` 的参数在**文档里**必须写成 jq 的字面转义 `\u001f`，而不是真实的 U+001F 字符。第一版草稿落成了真实控制字符——jq 对两种写法都能工作，但真实的控制字符会污染文档（本仓库有全仓字符扫描）。**实现时改的是 `scripts/sync.sh`，那里的 `join("\u001f")` 是字面转义，保持原样即可。**

## 兼容性

| 影响面 | 说明 |
| --- | --- |
| 退出码 | **不变**。坏文件属「无法判定」，按 `history.sh:990-992` 的既有注释不触发 2——网络抖动与匿名访问不该让退出码失去「需要处理」的含义 |
| CJK/路径 | `UNPARSABLE_REPORTS` 里是文件路径，告警用 `printf '%s、'` 拼接 |
| 既有断言 | CI 的三条 history.sh 断言用的都是**正常报告**，不经过坏文件分支；必须实跑确认 |
| `--check` 模式 | 行为变化：原来在 filter 阶段被混着告警，现在在预检阶段被明确告警 |
| 性能 | 预检对每份文件多跑一次 `jq -e .`；报告数受 `--limit`（默认 15）约束，可忽略 |
| bash 3.2 | 无关联数组、无 `mapfile`；空数组展开全部包在长度判断里 |

## 回滚

两个文件各自的改动互相独立，可整 PR revert。无状态、无数据迁移。**已产出的坏报告不受影响**（本任务只改消费方）。

## 验证方式（先红后绿）

构造一份像 v1.15.0 之前产出的坏报告：

```bash
printf '{\n "generated_at": "2026-09-01T00:00:00Z",\n "total": 1, "success": 0, "skipped": 0, "failed": 1,\n "images": [\n  {"source": "a"b:1", "dest": "d", "status": "failed", "seconds": 1}\n ]\n}\n' \
  > /tmp/badhist/run2/sync-report.json
```

| 场景 | 现在（红） | 期望（绿） |
| --- | --- | --- |
| 一份好 + 一份坏，`--dir` | 退出码 5，`jq: parse error` | 退出码 0，输出基于好那份的趋势，另有一行告警 |
| 全部坏 | `jq: parse error` | 明确报「N 份没有一份能解析」，并给出首个文件名 |
| 告警可定位 | 无 | 告警里含坏文件的路径 |

`fetch_sync_history` 走 mock（沿用 CI 里既有的 `download_reports` 骨架）；坏报告用 fixtures 写进 mock 的下载目录。
