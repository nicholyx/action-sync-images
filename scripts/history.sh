#!/usr/bin/env bash
#
# history.sh —— 从历次同步报告中汇总趋势
#
# 为什么需要它：每份报告都只讲「这一次」。想知道「某个镜像最近失败过几次」
# 「哪个镜像最容易出问题」，得把历次报告摊在一起看——手工翻 Artifact 是翻不动的，
# 翻不动就等于没有。
#
# 数据从哪来：同步报告本身就是现成的数据源。每次运行都会产出 sync-report.json，
# 由 Actions 作为 Artifact 保存。这个脚本只是把它们**读回来**做聚合，
# 不引入任何新的存储——因此也不会给仓库留下持续增长的提交历史。
# 这是刻意的取舍：历史的价值在于趋势，而趋势不需要永久保存。
#
# 用法：
#   ./scripts/history.sh                     下载最近 20 次运行并汇总
#   ./scripts/history.sh --dir ./reports     用本地已有的报告目录
#   ./scripts/history.sh --image nginx:1.27  看某个镜像的历史
#   ./scripts/history.sh --top-failures 5    只看失败最多的 5 个镜像
#
# 需要 gh CLI（下载模式）与 jq。

set -euo pipefail

LIMIT=20
LOCAL_DIR=""
DO_DOWNLOAD="true"
IMAGE_FILTER=""
TOP_FAILURES=10
SLOWEST=""
REPORT_NAME="sync-report-aliyuncs"
REPORT_NAME_EXPLICIT="false"
WORKFLOW_FILTER=""
WORKFLOW_EXPLICIT="false"
CHECK_MODE=""
REPORT_DIR=""
TREND_NAME=""
WORK_DIR=""

# ---------------------------------------------------------------------------
# 输出辅助（与 sync.sh 保持同一套约定：日志走 stderr，stdout 只放结果）
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

log_info()  { printf '%s[信息]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

die() {
  log_error "$@"
  exit 1
}

usage() {
  cat <<'EOF'
history.sh —— 从历次同步/检查报告中汇总趋势

数据来源（默认从 GitHub Actions 下载）：
      --dir <目录>        使用本地已有的报告目录，不访问 GitHub。
                           目录下可以是报告文件本身，也可以是含报告的各级子目录
      --limit <N>         下载最近 N 次运行的报告，默认 20（仅在下载模式下有意义）
      --report-name <名>  Artifact 名称，默认 sync-report-aliyuncs
                           （--check 模式下默认 check-report）
      --workflow <名>     只在该工作流的运行里找报告，默认不限
                           （--check 模式下默认 Check-Registry——体检是低频的
                           手动触发工作流，不限工作流的话窗口会被 CI 等高频
                           运行挤占，一份报告都捞不到）

查询：
      --check <类型>      检查报告趋势，类型：audit / lock-audit。
                          audit 回答「哪个镜像一直落后/一直缺失」，
                          lock-audit 回答「哪个锁条目一直在漂移」。
                          数据来自 v1.8.0+ 检查模式的 --report-dir 报告
                          （体检工作流会上传为 check-report Artifact）。
                          check-updates 不支持：未收录 tag 的增减没有趋势价值
      --image <镜像>      只看某个镜像的历史（--check 模式下匹配源镜像
                          或锁条目，要写完整名字）
      --top-failures <N>  只看失败/落后最多的 N 个镜像，默认 10
      --slowest <N>       只看平均耗时最慢的 N 个镜像（跨运行的平均值，
                          同时给出波动范围——单次异常拉高平均时，看范围
                          就能分辨「一直慢」还是「偶尔慢」）
      --report-dir <目录> 把本次趋势结果落盘为 .md（与 stdout 同源）与
                          .json（generated_at / query / summary / rows，
                          机器可读）两份文件；文件按查询模式命名
                          （sync-trend / audit-trend / lock-audit-trend /
                          slowest-trend）。History-Trend 工作流靠它留档
  -h, --help              显示本帮助

输出：
  stdout 是 Markdown 表格，可直接粘进 Issue 或文档；日志走 stderr。
  加 --report-dir 时同时落盘 .md 与 .json。

退出码：
  0  正常（没有失败记录也算正常）
  1  参数或环境错误（缺依赖、目录不存在、没有任何报告）
  2  历史中存在需要处理的记录——默认模式是失败记录；--check audit
     是落后/缺失，--check lock-audit 是漂移。「无法判定」不触发 2
     （查不成不等于出问题），但会在表格中独立可见

示例：
  # 看看最近的同步整体情况
  ./scripts/history.sh

  # 某个镜像是不是一直在失败
  ./scripts/history.sh --image registry.k8s.io/pause:3.9

  # 失败的镜像里，哪些最值得先处理
  ./scripts/history.sh --top-failures 5

  # 同步速度被谁拖慢了
  ./scripts/history.sh --slowest 5

  # 哪个镜像一直落后（体检报告趋势，本地报告目录）
  ./scripts/history.sh --check audit --dir ./reports

  # 哪个锁条目一直在漂移（体检工作流 check-report Artifact）
  ./scripts/history.sh --check lock-audit
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        LOCAL_DIR="$2"; DO_DOWNLOAD="false"; shift 2 ;;
      --limit)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        LIMIT="$2"; shift 2 ;;
      --report-name)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        REPORT_NAME="$2"; REPORT_NAME_EXPLICIT="true"; shift 2 ;;
      --workflow)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        WORKFLOW_FILTER="$2"; WORKFLOW_EXPLICIT="true"; shift 2 ;;
      --check)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        case "$2" in
          audit | lock-audit) CHECK_MODE="$2" ;;
          check-updates)
            die "--check 不支持 check-updates：未收录 tag 的增减没有趋势价值（收不收本来就要人判断），请分别查看每次检查的报告"
            ;;
          *)
            die "--check 的类型必须是 audit 或 lock-audit，当前为「$2」"
            ;;
        esac
        shift 2 ;;
      --image)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        IMAGE_FILTER="$2"; shift 2 ;;
      --top-failures)
        # 允许省略参数：--top-failures 后面若是另一个选项或结尾，就用默认值
        if [[ -n "${2:-}" && "$2" != -* ]]; then
          TOP_FAILURES="$2"; shift 2
        else
          shift
        fi ;;
      --slowest)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SLOWEST="$2"; shift 2 ;;
      --report-dir)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        REPORT_DIR="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        log_error "未知参数：$1"
        echo "" >&2
        usage >&2
        exit 1 ;;
    esac
  done

  if [[ ! "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]]; then
    die "--limit 必须是正整数，当前为「${LIMIT}」"
  fi
  if [[ ! "$TOP_FAILURES" =~ ^[0-9]+$ ]] || [[ "$TOP_FAILURES" -lt 1 ]]; then
    die "--top-failures 必须是正整数，当前为「${TOP_FAILURES}」"
  fi
  if [[ -n "$SLOWEST" && ! "$SLOWEST" =~ ^[0-9]+$ ]]; then
    die "--slowest 必须是正整数，当前为「${SLOWEST}」"
  fi

  # --check 与 --slowest 都是独立查询模式，同时传无法判断想要哪个
  if [[ -n "$CHECK_MODE" && -n "$SLOWEST" ]]; then
    die "--check 与 --slowest 不能同时使用：一个是检查报告趋势，一个是同步耗时排行，请分开运行"
  fi

  # --check 读的是检查报告，Artifact 名也跟着换；
  # 显式传过 --report-name 的以用户为准（自建工作流可能改了名字）
  if [[ -n "$CHECK_MODE" && "$REPORT_NAME_EXPLICIT" == "false" ]]; then
    REPORT_NAME="check-report"
  fi

  # --check 只关心体检工作流的运行：不限工作流的话，最近 N 次运行几乎全是
  # CI / Scorecard 这类高频运行，体检又只有手动触发——窗口里一份检查报告
  # 都捞不到（这不是数据不存在，是取数范围选错了）。
  # 同步工作流有多个名字（Sync-Images-to-Aliyuncs / Harbor / Batch），
  # 没有唯一合理默认，保持不限、支持显式过滤
  if [[ -n "$CHECK_MODE" && "$WORKFLOW_EXPLICIT" == "false" ]]; then
    WORKFLOW_FILTER="Check-Registry"
  fi

  # --report-dir 的产物按查询模式命名（与 sync.sh 的 <check_name>-report 同一约定）
  if [[ "$CHECK_MODE" == "audit" ]]; then
    TREND_NAME="audit-trend"
  elif [[ "$CHECK_MODE" == "lock-audit" ]]; then
    TREND_NAME="lock-audit-trend"
  elif [[ -n "$SLOWEST" ]]; then
    TREND_NAME="slowest-trend"
  else
    TREND_NAME="sync-trend"
  fi
}

# ---------------------------------------------------------------------------
# 数据获取
# ---------------------------------------------------------------------------

# 从 Actions 下载最近的报告附件。
#
# 每次运行的附件都放进各自的子目录，否则同名文件会互相覆盖——而覆盖掉的
# 恰好是除最后一次以外的全部数据。

# 分类 gh run download 的失败原因。$1 = 该次运行的合并输出（stderr 为主）。
# 输出 no-artifact（运行本来就没有可下载的报告，正常现象）或
# suspicious（多半是网络 / 传输问题，需要二次确认）。
# 匹配的两条文案是 gh 2.x 的报错原文；分错了也无害——suspicious 会走
# artifacts API 二次确认纠正，不会把「无附件」误报成「下载失败」。
classify_download_failure() {
  case "$1" in
    *"no valid artifacts found"* | *"no artifact matches"*) printf '%s\n' 'no-artifact' ;;
    *) printf '%s\n' 'suspicious' ;;
  esac
}

# 确认一次运行是否真有名为 $2 的附件。$1 = run id。
# 输出 yes / expired / absent；API 也查不动（网络抖动）时输出 unknown。
confirm_artifact_exists() {
  local id="$1" name="$2" state="unknown" api_out
  # API 调用与 jq 解析分开查退出码：gh api 失败时 jq 对空输入照样成功，
  # 整条管道一起判的话，「查不动」能不能落到 unknown 就得看调用方有没有
  # 开 pipefail——而 unknown（计入下载失败）与 absent（静默跳过）在调用方
  # 语义不同，这里不能有这种隐含前提
  if api_out="$(gh api "repos/{owner}/{repo}/actions/runs/${id}/artifacts" 2>/dev/null)"; then
    state="$(printf '%s\n' "$api_out" | jq -r --arg name "$name" \
      '[.artifacts[] | select(.name == $name)][0]
       | if . == null then "absent" elif .expired then "expired" else "yes" end')" || state="unknown"
  fi
  [[ -n "$state" ]] || state="absent"
  printf '%s\n' "$state"
}

download_reports() {
  command -v gh >/dev/null 2>&1 || die "未找到 gh CLI。安装：https://cli.github.com —— 或用 --dir 指定本地报告目录"
  command -v jq >/dev/null 2>&1 || die "未找到 jq"

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT

  log_info "正在获取最近 ${LIMIT} 次运行..."

  # gh run list 的参数组装：--workflow 过滤可选（--check 模式默认带上，
  # 理由见 parse_args 末尾的注释）
  local -a list_args=(--limit "$LIMIT" --json databaseId --jq '.[].databaseId')
  if [[ -n "$WORKFLOW_FILTER" ]]; then
    log_info "只看工作流「${WORKFLOW_FILTER}」的运行"
    list_args=(--workflow "$WORKFLOW_FILTER" "${list_args[@]}")
  fi

  local -a run_ids=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && run_ids+=("$id")
  done < <(gh run list "${list_args[@]}" 2>/dev/null || true)

  [[ ${#run_ids[@]} -gt 0 ]] || die "没有取到任何运行记录。请确认当前目录在一个 GitHub 仓库中，gh 已登录，且工作流「${WORKFLOW_FILTER:-}」至少跑过一次（--check 模式下这是体检工作流；也可用 --dir 指定本地报告目录）"

  local got=0
  local failed_downloads=0
  local dl_out verdict
  for id in "${run_ids[@]}"; do
    if dl_out="$(gh run download "$id" -n "$REPORT_NAME" -D "${WORK_DIR}/${id}" 2>&1)"; then
      got=$((got + 1))
      continue
    fi
    # 下载失败分两类，不得混淆（Issue #87，2026-09-14 真实踩到）：运行
    # 本来就不做同步或体检、自然没有这个附件，属正常；而带附件的运行被
    # 网络抖动中断，报成「没有附件」会误导排查方向。先按 gh 的报错文案
    # 分类，拿不准的（EOF 等传输错误）用 artifacts API 二次确认。
    verdict="$(classify_download_failure "$dl_out")"
    if [[ "$verdict" == "no-artifact" ]]; then
      continue
    fi
    case "$(confirm_artifact_exists "$id" "$REPORT_NAME")" in
      yes)
        failed_downloads=$((failed_downloads + 1))
        log_warn "运行 ${id} 有「${REPORT_NAME}」附件但下载失败（多为网络原因，可重试）"
        ;;
      expired)
        log_warn "运行 ${id} 的「${REPORT_NAME}」附件已按 GitHub 保留期清理，无法下载"
        ;;
      absent)
        # 文案分类误报，API 纠正：确实没有附件，照旧静默跳过
        ;;
      *)
        # 存在性也确认不了（网络不稳）：如实计入下载失败，不假装知道附件在不在
        failed_downloads=$((failed_downloads + 1))
        log_warn "运行 ${id} 下载失败，且附件存在性确认也失败（网络原因，可重试）"
        ;;
    esac
  done

  if [[ -n "$CHECK_MODE" ]]; then
    log_info "本次运行列表中有 ${got} 次带检查报告"
  else
    log_info "本次运行列表中有 ${got} 次带同步报告"
  fi
  if [[ ${failed_downloads} -gt 0 ]]; then
    log_warn "其中 ${failed_downloads} 次应下载却失败（多为网络原因，可重试）"
  fi
  if [[ "$got" -eq 0 ]]; then
    if [[ ${failed_downloads} -gt 0 ]]; then
      die "这 ${#run_ids[@]} 次运行里没有一次成功下载「${REPORT_NAME}」报告：${failed_downloads} 次应下载却失败，多为网络原因，可重试；也可用 --dir 指定本地报告目录"
    fi
    if [[ -n "$CHECK_MODE" ]]; then
      die "这 ${#run_ids[@]} 次运行里没有任何「${REPORT_NAME}」附件。--check 模式取的是体检工作流（Check-Registry）的运行——请确认它至少跑过一次（Actions 页面手动触发），或用 --dir 指定本地报告目录"
    fi
    die "这 ${#run_ids[@]} 次运行里没有任何「${REPORT_NAME}」附件。换一个 --report-name 或 --workflow，或用 --dir 指定本地报告目录"
  fi
}

# 收集报告文件，按报告内的生成时间排序（而不是文件系统顺序——
# 后者取决于下载顺序，未必与时间一致）。
collect_reports() {
  local base="$1"
  local -a found=()

  local f
  while IFS= read -r f; do
    found+=("$f")
  done < <(find "$base" -type f -name '*.json' 2>/dev/null | sort)

  [[ ${#found[@]} -gt 0 ]] || return 0

  printf '%s\n' "${found[@]}"
}

# ---------------------------------------------------------------------------
# 聚合
# ---------------------------------------------------------------------------

# 把多份报告合成一张「镜像 → 各状态次数」的表。
#
# last_at / last_status 取的是**时间上最后一条**记录，而不是文件顺序里的最后一条：
# 下载顺序与运行时间未必一致，用文件顺序会让「最近一次结果」指向错误的那次运行。
aggregate_by_image() {
  local -a files=("$@")
  jq -s '
    [.[] | select(.images != null) | .generated_at as $at | .images[] | . + {at: $at}]
    | group_by(.source)
    | map({
        source: .[0].source,
        ok:   (map(select(.status == "success"))  | length),
        skip: (map(select(.status == "skipped"))  | length),
        fail: (map(select(.status == "failed"))   | length),
        last_at: (max_by(.at) | .at),
        last_status: (max_by(.at) | .status)
      })
    | sort_by(-.fail, .source)
  ' "${files[@]}"
}

# ---------------------------------------------------------------------------
# 聚合口径（渲染与 --report-dir 落盘共用的单一来源）
#
# 渲染函数与落盘都要同一份数据——在这里各定义一次，调用方只消费结果。
# 直接复制 jq 字符串会让渲染的表格与落盘的 JSON 悄悄漂移。
# ---------------------------------------------------------------------------

# 同步趋势的汇总（总览段与 json 的 summary 同源）
sync_trend_counts() {
  local -a files=("$@")
  jq -s '{
      runs: length,
      first: (map(.generated_at) | min),
      last: (map(.generated_at) | max),
      total: (map(.total) | add),
      success: (map(.success) | add),
      skipped: (map(.skipped) | add),
      failed: (map(.failed) | add)
    }' "${files[@]}"
}

# 同步耗时排行（print_slowest 的数据源）
slowest_trend_rows() {
  local -a files=("$@")
  jq -s --argjson n "$SLOWEST" '
    [.[] | select(.images != null) | .images[]
         | select(.status != "skipped" and .status != "excluded")]
    | group_by(.source)
    | map({
        source: .[0].source,
        runs: length,
        avg: ((map(.seconds // 0) | add) / length),
        max: (map(.seconds // 0) | max),
        min: (map(.seconds // 0) | min)
      })
    | sort_by(-.avg)
    | .[:$n]
  ' "${files[@]}"
}

status_label() {
  case "$1" in
    success)  printf '✅' ;;
    skipped)  printf '⤼' ;;
    excluded) printf '⊘' ;;
    failed)   printf '❌' ;;
    *)        printf '—' ;;
  esac
}

print_summary() {
  local -a files=("$@")

  local totals
  totals="$(sync_trend_counts "${files[@]}")"

  local runs first last total ok skip fail
  runs="$(jq -r '.runs' <<<"$totals")"
  first="$(jq -r '.first // "—"' <<<"$totals")"
  last="$(jq -r '.last // "—"' <<<"$totals")"
  total="$(jq -r '.total // 0' <<<"$totals")"
  ok="$(jq -r '.success // 0' <<<"$totals")"
  skip="$(jq -r '.skipped // 0' <<<"$totals")"
  fail="$(jq -r '.failed // 0' <<<"$totals")"

  printf "共 **%s** 次运行，覆盖 \`%s\` ~ \`%s\`\n\n" "$runs" "$first" "$last"
  printf "累计同步 **%s** 个镜像次：成功 %s ｜ 跳过 %s ｜ 失败 %s\n\n" \
    "$total" "$ok" "$skip" "$fail"

  local rows
  rows="$(aggregate_by_image "${files[@]}")"

  if [[ -n "$IMAGE_FILTER" ]]; then
    rows="$(jq --arg img "$IMAGE_FILTER" '[.[] | select(.source == $img)]' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf "没有找到镜像 \`%s\` 的任何记录。\n" "$IMAGE_FILTER"
      printf "\n> 注意镜像名要写完整（含 registry 与 tag），与 \`--src\` 里填的完全一致。\n"
      return 0
    fi
    printf "### \`%s\` 的历史\n\n" "$IMAGE_FILTER"
  else
    rows="$(jq --argjson n "$TOP_FAILURES" '[.[] | select(.fail > 0)][:$n]' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf '### 没有出现过失败的镜像\n\n'
      printf '这段时间内的每一次同步都成功了。\n'
      return 0
    fi
    printf '### 失败最多的镜像（前 %s 个）\n\n' "$TOP_FAILURES"
  fi

  printf '| 镜像 | 成功 | 跳过 | 失败 | 最近一次 |\n'
  printf '| --- | :---: | :---: | :---: | :---: |\n'

  local n i
  n="$(jq 'length' <<<"$rows")"
  for ((i = 0; i < n; i++)); do
    local src okc skipc failc last_status
    src="$(jq -r ".[$i].source" <<<"$rows")"
    okc="$(jq -r ".[$i].ok" <<<"$rows")"
    skipc="$(jq -r ".[$i].skip" <<<"$rows")"
    failc="$(jq -r ".[$i].fail" <<<"$rows")"
    last_status="$(jq -r ".[$i].last_status" <<<"$rows")"
    printf "| \`%s\` | %s | %s | %s | %s |\n" \
      "$src" "$okc" "$skipc" "$failc" "$(status_label "$last_status")"
  done
}

# 按平均耗时列出最慢的镜像。
#
# 用**平均值**并标注（不用中位数）：样本本来就少（几次运行），平均值的波动
# 反而是想暴露的信息，同时给出 min~max 让波动可见。
# 只统计真正同步过的记录——跳过与被排除的耗时恒为 0，会把平均值整个拉低，
# 让榜单变得毫无意义。
print_slowest() {
  local -a files=("$@")

  local rows
  rows="$(slowest_trend_rows "${files[@]}")"

  if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
    printf '没有可统计耗时的记录。\n'
    return 0
  fi

  printf '### 平均最慢的镜像（前 %s 个，按平均值排序）\n\n' "$SLOWEST"
  printf '| 镜像 | 平均耗时 | 波动范围 | 同步次数 |\n'
  printf '| --- | ---: | --- | :---: |\n'

  local n i src avg maxc minc runs
  n="$(jq 'length' <<<"$rows")"
  for ((i = 0; i < n; i++)); do
    src="$(jq -r ".[$i].source" <<<"$rows")"
    avg="$(jq -r ".[$i].avg" <<<"$rows")"
    maxc="$(jq -r ".[$i].max" <<<"$rows")"
    minc="$(jq -r ".[$i].min" <<<"$rows")"
    runs="$(jq -r ".[$i].runs" <<<"$rows")"
    printf "| \`%s\` | %.1fs | %ss ~ %ss | %s |\n" \
      "$src" "$avg" "$minc" "$maxc" "$runs"
  done

  printf '\n> 平均值对上游抽风很敏感，波动范围比平均更有参考价值。\n'
  printf '> 单次异常拉高平均时，看范围就能分辨「一直慢」还是「偶尔慢」。\n'
}

# ---------------------------------------------------------------------------
# 检查报告趋势（--check audit / --check lock-audit）
# ---------------------------------------------------------------------------

# 从收集到的报告里只留顶层 .check 字段匹配的检查报告。
#
# 按 JSON 字段过滤而不是文件名：--dir 目录下可能混放同步报告与
# 各种检查报告，文件名只是约定，字段才是事实。
# 解析失败的文件在这里告警跳过——一份坏文件不该毁掉整个趋势。
filter_by_check() {
  local check_type="$1"
  shift
  local -a in_files=("$@")

  FILTERED_FILES=()
  local f match
  for f in "${in_files[@]}"; do
    match="$(jq -r --arg t "$check_type" 'select(.check? == $t) | .check // empty' "$f" 2>/dev/null || true)"
    if [[ -n "$match" ]]; then
      FILTERED_FILES+=("$f")
    else
      log_warn "跳过非 ${check_type} 报告或无法解析的文件：${f}"
    fi
  done

  if [[ ${#FILTERED_FILES[@]} -eq 0 ]]; then
    die "没有找到任何 check=${check_type} 的检查报告。检查报告由 sync.sh --report-dir 产出（文件里顶层带 \"check\": \"${check_type}\" 字段）；若目录里混放多种报告，这是正常的，但必须至少有一份匹配"
  fi
}

# 「最近一次」的图标。趋势与检查报告同一套状态语义：
# 无法判定用 ? 与真实异常区分开——查不成不等于出问题
audit_state_icon() {
  case "$1" in
    current)  printf '✅' ;;
    stale)    printf '⚠️' ;;
    missing)  printf '✗' ;;
    unknown)  printf '？' ;;
    excluded) printf '⊘' ;;
    *)        printf '—' ;;
  esac
}

lock_state_icon() {
  case "$1" in
    match)  printf '✅' ;;
    drift)  printf '⚠️' ;;
    unknown) printf '？' ;;
    *)      printf '—' ;;
  esac
}

# audit 趋势的汇总与聚合行（渲染与落盘共用，见「聚合口径」一节的说明）
audit_trend_counts() {
  local -a files=("$@")
  jq -s '
    [.[] | select(.check == "audit")]
    | {
        runs: length,
        first: (map(.generated_at) | min),
        last: (map(.generated_at) | max),
        current: ([.[].records[] | select(.state == "current")]  | length),
        stale:   ([.[].records[] | select(.state == "stale")]    | length),
        missing: ([.[].records[] | select(.state == "missing")]  | length),
        unknown: ([.[].records[] | select(.state == "unknown")]  | length),
        excluded: ([.[].records[] | select(.state == "excluded")] | length)
      }
  ' "${files[@]}"
}

audit_trend_rows() {
  local -a files=("$@")
  jq -s '
    [.[] | select(.check == "audit") | .generated_at as $at | .records[] | select(.dest != null) | . + {at: $at}]
    | group_by(.source + " " + .dest)
    | map({
        source: .[0].source, dest: .[0].dest,
        current: (map(select(.state == "current")) | length),
        stale:   (map(select(.state == "stale"))   | length),
        missing: (map(select(.state == "missing")) | length),
        unknown: (map(select(.state == "unknown")) | length),
        excluded_total: (map(select(.state == "excluded")) | length),
        total: length,
        last_state: (max_by(.at) | .state)
      })
    | sort_by(-(.stale + .missing), .source, .dest)
  ' "${files[@]}"
}

# lock-audit 趋势的汇总与聚合行（同上，渲染与落盘共用）
lock_trend_counts() {
  local -a files=("$@")
  jq -s '
    [.[] | select(.check == "lock-audit")]
    | {
        runs: length,
        first: (map(.generated_at) | min),
        last: (map(.generated_at) | max),
        match:   ([.[].records[] | select(.state == "match")]   | length),
        drift:   ([.[].records[] | select(.state == "drift")]   | length),
        unknown: ([.[].records[] | select(.state == "unknown")] | length),
        nodigest: ([.[].records[] | select(.state == "nodigest")] | length),
        marker:  ([.[].records[] | select(.state == "marker")]  | length)
      }
  ' "${files[@]}"
}

lock_trend_rows() {
  local -a files=("$@")
  jq -s '
    [.[] | select(.check == "lock-audit") | .generated_at as $at | .records[] | . + {at: $at}]
    | group_by(.entry)
    | map({
        entry: .[0].entry,
        match:   (map(select(.state == "match"))   | length),
        drift:   (map(select(.state == "drift"))   | length),
        unknown: (map(select(.state == "unknown")) | length),
        other:   (map(select(.state != "match" and .state != "drift" and .state != "unknown")) | length),
        total: length,
        last_state: (max_by(.at) | .state)
      })
    | sort_by(-.drift, .entry)
  ' "${files[@]}"
}

# 把本次趋势结果落盘为 json（md 已由渲染输出经 tee 写好）。
#
# json 顶层四字段：generated_at / query / summary / rows——与检查报告的
# 「机器可读」同一约定。summary 与 rows 调用渲染所用的同一组聚合函数，
# 两处不会各自漂移；query 记录本次查询参数，趋势可以复现。
# 转义交给 jq，不用手工拼字符串。
write_trend_report_files() {
  local trend_name="$1"
  shift
  local -a files=("$@")

  local mode_name counts rows
  case "$trend_name" in
    audit-trend)
      mode_name="audit"
      counts="$(audit_trend_counts "${files[@]}")"
      rows="$(audit_trend_rows "${files[@]}")" ;;
    lock-audit-trend)
      mode_name="lock-audit"
      counts="$(lock_trend_counts "${files[@]}")"
      rows="$(lock_trend_rows "${files[@]}")" ;;
    slowest-trend)
      mode_name="slowest"
      counts='{}'
      rows="$(slowest_trend_rows "${files[@]}")" ;;
    *)
      mode_name="sync"
      counts="$(sync_trend_counts "${files[@]}")"
      rows="$(aggregate_by_image "${files[@]}")" ;;
  esac

  local query
  query="$(jq -n \
    --arg mode "$mode_name" --arg image "$IMAGE_FILTER" \
    --arg workflow "$WORKFLOW_FILTER" --argjson limit "$LIMIT" \
    --argjson top "$TOP_FAILURES" \
    '{mode: $mode,
      image: (if $image == "" then null else $image end),
      workflow: (if $workflow == "" then null else $workflow end),
      limit: $limit, top_failures: $top}')"

  jq -n --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson q "$query" --argjson s "$counts" --argjson r "$rows" \
    '{generated_at: $at, query: $q, summary: $s, rows: $r}' \
    > "${REPORT_DIR}/${trend_name}-report.json"

  log_info "趋势报告已写入：${REPORT_DIR}/${trend_name}-report.md 与 .json"
}

# audit 趋势：镜像（源+目标）→ 各状态次数。
#
# 分组键是 source + dest，与同步趋势（只按 source）不同：审计的状态绑定
# 目标仓库，「同一个源在 A 目标最新、在 B 目标落后」合并计数就丢了信息。
print_audit_trend() {
  local -a files=("$@")

  # 总览段：报告份数与时间范围、按记录统计的状态累计（口径来自共享聚合函数）
  local counts
  counts="$(audit_trend_counts "${files[@]}")"
  local n_reports first_at last_at current_n stale_n missing_n unknown_n excluded_n
  n_reports="$(jq -r '.runs' <<<"$counts")"
  first_at="$(jq -r '.first' <<<"$counts")"
  last_at="$(jq -r '.last' <<<"$counts")"
  current_n="$(jq -r '.current' <<<"$counts")"
  stale_n="$(jq -r '.stale' <<<"$counts")"
  missing_n="$(jq -r '.missing' <<<"$counts")"
  unknown_n="$(jq -r '.unknown' <<<"$counts")"
  excluded_n="$(jq -r '.excluded' <<<"$counts")"

  printf "共 **%s** 次审计，覆盖 \`%s\` ~ \`%s\`\n\n" "$n_reports" "$first_at" "$last_at"
  printf "累计 **%s** 条记录：最新 %s ｜ 落后 %s ｜ 缺失 %s ｜ 无法判定 %s ｜ 被排除 %s\n\n" \
    "$((stale_n + missing_n + unknown_n + current_n + excluded_n))" \
    "$current_n" "$stale_n" "$missing_n" "$unknown_n" "$excluded_n"

  local rows
  rows="$(audit_trend_rows "${files[@]}")"

  # 全排除组合的计数要在默认视图过滤**之前**做——否则它们被 jq 丢掉后，
  # 统计行就永远凑不出来（悄悄消失会让看的人以为它同步上了）
  local excluded_groups=0

  if [[ -n "$IMAGE_FILTER" ]]; then
    rows="$(jq --arg img "$IMAGE_FILTER" '[.[] | select(.source == $img)]' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf "没有找到源镜像 \`%s\` 的任何记录。\n" "$IMAGE_FILTER"
      printf "\n> 注意镜像名要写完整（含 registry 与 tag），与清单里写的完全一致。\n"
      return 0
    fi
    printf "### \`%s\` 的审计历史\n\n" "$IMAGE_FILTER"
  else
    # 默认只展示有关注项（落后或缺失）的组合——全最新的组合占着榜单没有信息量
    excluded_groups="$(jq '[.[] | select(.excluded_total == .total)] | length' <<<"$rows")"
    rows="$(jq '[.[] | select((.stale + .missing) > 0 and .excluded_total < .total)][:'"$TOP_FAILURES"']' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf '### 没有出现过落后或缺失的镜像\n\n'
      printf '这段窗口内的每一次审计都是最新的（或仅存在排除与无法判定）。\n'
      if [[ "$excluded_groups" -gt 0 ]]; then
        printf '\n> 另有 %s 个（源镜像, 目标）组合在窗口内**始终被排除**（--filter / --exclude 所致），不参与趋势。\n' "$excluded_groups"
      elif [[ "$excluded_n" -gt 0 ]]; then
        printf '\n> 被排除的记录共 %s 条（--filter / --exclude 所致），不参与趋势。\n' "$excluded_n"
      fi
      return 0
    fi
    printf '### 一直落后 / 缺失的镜像（前 %s 个）\n\n' "$TOP_FAILURES"
  fi

  printf '| 源镜像 | 目标 | 最新 | 落后 | 缺失 | 无法判定 | 最近一次 |\n'
  printf '| --- | --- | :---: | :---: | :---: | :---: | :---: |\n'

  local n i
  n="$(jq 'length' <<<"$rows")"
  for ((i = 0; i < n; i++)); do
    local src dest curc stalec missc unknc exclt last_state
    src="$(jq -r ".[$i].source" <<<"$rows")"
    dest="$(jq -r ".[$i].dest" <<<"$rows")"
    curc="$(jq -r ".[$i].current" <<<"$rows")"
    stalec="$(jq -r ".[$i].stale" <<<"$rows")"
    missc="$(jq -r ".[$i].missing" <<<"$rows")"
    unknc="$(jq -r ".[$i].unknown" <<<"$rows")"
    exclt="$(jq -r ".[$i].excluded_total" <<<"$rows")"
    last_state="$(jq -r ".[$i].last_state" <<<"$rows")"

    # 整组被排除的组合不占表格行，但要在统计行里可见——
    # 悄悄消失会让看的人以为它同步上了
    if [[ "$exclt" -eq "$(jq -r ".[$i].total" <<<"$rows")" ]]; then
      excluded_groups=$((excluded_groups + 1))
      continue
    fi

    printf "| \`%s\` | \`%s\` | %s | %s | %s | %s | %s |\n" \
      "$src" "$dest" "$curc" "$stalec" "$missc" "$unknc" "$(audit_state_icon "$last_state")"
  done

  if [[ "$excluded_groups" -gt 0 ]]; then
    printf "\n> 另有 %s 个（源镜像, 目标）组合在窗口内**始终被排除**（--filter / --exclude 所致），不参与趋势。\n" "$excluded_groups"
  fi
  if [[ "$unknown_n" -gt 0 ]]; then
    printf "\n> 「无法判定」共 %s 条，多为网络抖动或匿名访问（私有仓库未配凭证）——查不成不等于落后，不触发退出码 2。\n" "$unknown_n"
  fi
}

# lock-audit 趋势：锁条目 → 各状态次数。
# nodigest（未锁 digest）与 marker（标注行）没有「基准 vs 现状」可言，
# 不进趋势表，但统计行要可见——悄悄吞掉等于假装锁文件很干净
print_lock_trend() {
  local -a files=("$@")

  # 口径来自共享聚合函数（渲染与落盘同源）
  local counts
  counts="$(lock_trend_counts "${files[@]}")"
  local n_reports first_at last_at match_n drift_n unknown_n nodigest_n marker_n
  n_reports="$(jq -r '.runs' <<<"$counts")"
  first_at="$(jq -r '.first' <<<"$counts")"
  last_at="$(jq -r '.last' <<<"$counts")"
  match_n="$(jq -r '.match' <<<"$counts")"
  drift_n="$(jq -r '.drift' <<<"$counts")"
  unknown_n="$(jq -r '.unknown' <<<"$counts")"
  nodigest_n="$(jq -r '.nodigest' <<<"$counts")"
  marker_n="$(jq -r '.marker' <<<"$counts")"

  printf "共 **%s** 次锁文件校验，覆盖 \`%s\` ~ \`%s\`\n\n" "$n_reports" "$first_at" "$last_at"
  printf "累计 **%s** 条记录：一致 %s ｜ 漂移 %s ｜ 无法判定 %s ｜ 未锁定 %s ｜ 标注行 %s\n\n" \
    "$((match_n + drift_n + unknown_n + nodigest_n + marker_n))" \
    "$match_n" "$drift_n" "$unknown_n" "$nodigest_n" "$marker_n"

  local rows
  rows="$(lock_trend_rows "${files[@]}")"

  # 不参与校验条目的计数在默认视图过滤之前做，理由同 audit 的全排除组合
  local other_groups=0

  if [[ -n "$IMAGE_FILTER" ]]; then
    rows="$(jq --arg img "$IMAGE_FILTER" '[.[] | select(.entry == $img)]' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf "没有找到锁条目 \`%s\` 的任何记录。\n" "$IMAGE_FILTER"
      printf "\n> 注意条目要写完整（含 registry、tag 与 @digest），与锁文件里写的完全一致。\n"
      return 0
    fi
    printf "### \`%s\` 的校验历史\n\n" "$IMAGE_FILTER"
  else
    other_groups="$(jq '[.[] | select(.other == .total)] | length' <<<"$rows")"
    rows="$(jq '[.[] | select(.drift > 0 and .other < .total)][:'"$TOP_FAILURES"']' <<<"$rows")"
    if [[ "$(jq 'length' <<<"$rows")" -eq 0 ]]; then
      printf '### 没有出现过漂移的锁条目\n\n'
      printf '这段窗口内的每一次校验都是一致的（或仅存在无法判定与不参与校验的条目）。\n'
      if [[ "$other_groups" -gt 0 ]]; then
        printf '\n> 另有 %s 个条目不参与趋势（未锁定 digest 或锁文件标注行）——没有基准，校验从何谈起；锁上 digest 才能进入趋势。\n' "$other_groups"
      fi
      return 0
    fi
    printf '### 一直在漂移的锁条目（前 %s 个）\n\n' "$TOP_FAILURES"
  fi

  printf '| 锁条目 | 一致 | 漂移 | 无法判定 | 最近一次 |\n'
  printf '| --- | :---: | :---: | :---: | :---: |\n'

  local n i
  n="$(jq 'length' <<<"$rows")"
  for ((i = 0; i < n; i++)); do
    local entry mc dc unknc othert last_state
    entry="$(jq -r ".[$i].entry" <<<"$rows")"
    mc="$(jq -r ".[$i].match" <<<"$rows")"
    dc="$(jq -r ".[$i].drift" <<<"$rows")"
    unknc="$(jq -r ".[$i].unknown" <<<"$rows")"
    othert="$(jq -r ".[$i].other" <<<"$rows")"
    last_state="$(jq -r ".[$i].last_state" <<<"$rows")"

    if [[ "$othert" -eq "$(jq -r ".[$i].total" <<<"$rows")" ]]; then
      other_groups=$((other_groups + 1))
      continue
    fi

    printf "| \`%s\` | %s | %s | %s | %s |\n" \
      "$entry" "$mc" "$dc" "$unknc" "$(lock_state_icon "$last_state")"
  done

  if [[ "$other_groups" -gt 0 ]]; then
    printf "\n> 另有 %s 个条目不参与趋势（未锁定 digest 或锁文件标注行）——没有基准，校验从何谈起；锁上 digest 才能进入趋势。\n" "$other_groups"
  fi
  if [[ "$unknown_n" -gt 0 ]]; then
    printf "\n> 「无法判定」共 %s 条，多为上游访问受限——查不成不等于漂移，不触发退出码 2。\n" "$unknown_n"
  fi
}

# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  if [[ "$DO_DOWNLOAD" == "true" ]]; then
    download_reports
  else
    [[ -d "$LOCAL_DIR" ]] || die "目录不存在：${LOCAL_DIR}"
  fi

  local base="${LOCAL_DIR:-$WORK_DIR}"
  local -a files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(collect_reports "$base")

  if [[ ${#files[@]} -eq 0 ]]; then
    die "在 ${base} 下没有找到任何 JSON 报告"
  fi

  # --check 模式先按顶层 .check 字段过滤（--dir 下混放多种报告是常态），
  # 之后的一切只看过滤结果
  if [[ -n "$CHECK_MODE" ]]; then
    filter_by_check "$CHECK_MODE" "${files[@]}"
    files=("${FILTERED_FILES[@]}")
  fi

  log_info "共读取 ${#files[@]} 份报告"

  # --slowest 是独立的查询模式：只看耗时，不再叠加失败排行
  # --check 同理：audit 趋势 / lock 趋势 / 耗时排行，三选一
  local -a render_cmd=()
  if [[ "$CHECK_MODE" == "audit" ]]; then
    render_cmd=(print_audit_trend)
  elif [[ "$CHECK_MODE" == "lock-audit" ]]; then
    render_cmd=(print_lock_trend)
  elif [[ -n "$SLOWEST" ]]; then
    render_cmd=(print_slowest)
  else
    render_cmd=(print_summary)
  fi

  if [[ -n "$REPORT_DIR" ]]; then
    mkdir -p "$REPORT_DIR"
    # md 与 stdout 同源：首尾空行与渲染输出一起 tee 进文件（只包渲染函数
    # 的话，stdout 的空行会丢，「同源」就成了空话）。pipefail 保证
    # 渲染函数的退出码不会被 tee 吞掉
    {
      echo ""
      "${render_cmd[@]}" "${files[@]}"
      echo ""
    } | tee "${REPORT_DIR}/${TREND_NAME}-report.md"
    write_trend_report_files "$TREND_NAME" "${files[@]}"
  else
    echo ""
    "${render_cmd[@]}" "${files[@]}"
    echo ""
  fi

  # 历史里有「需要处理的记录」就返回 2，便于在脚本或 CI 里据此判断。
  # 注意这是「历史中有过」，不代表本次运行失败。
  if [[ "$CHECK_MODE" == "audit" ]]; then
    # 趋势的 2 只由确定异常触发：落后 / 缺失。无法判定（查不成）不触发——
    # 网络抖动和匿名访问不该让退出码失去「需要处理」的含义
    local bad_n
    bad_n="$(jq -s '
      [.[] | select(.check == "audit") | .records[]
           | select(.state == "stale" or .state == "missing")] | length
    ' "${files[@]}")"
    if [[ "${bad_n:-0}" -gt 0 ]]; then
      return 2
    fi
    return 0
  fi
  if [[ "$CHECK_MODE" == "lock-audit" ]]; then
    local bad_lock
    bad_lock="$(jq -s '
      [.[] | select(.check == "lock-audit") | .records[]
           | select(.state == "drift")] | length
    ' "${files[@]}")"
    if [[ "${bad_lock:-0}" -gt 0 ]]; then
      return 2
    fi
    return 0
  fi

  local any_fail
  any_fail="$(jq -s 'map(.failed // 0) | add' "${files[@]}")"
  if [[ "${any_fail:-0}" -gt 0 ]]; then
    return 2
  fi
  return 0
}

main "$@"
