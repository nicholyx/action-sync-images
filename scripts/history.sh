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
history.sh —— 从历次同步报告中汇总趋势

数据来源（默认从 GitHub Actions 下载）：
      --dir <目录>        使用本地已有的报告目录，不访问 GitHub。
                           目录下可以是报告文件本身，也可以是含报告的各级子目录
      --limit <N>         下载最近 N 次运行的报告，默认 20（仅在下载模式下有意义）
      --report-name <名>  Artifact 名称，默认 sync-report-aliyuncs

查询：
      --image <镜像>      只看某个镜像的历史
      --top-failures <N>  只看失败次数最多的 N 个镜像，默认 10
      --slowest <N>       只看平均耗时最慢的 N 个镜像（跨运行的平均值，
                          同时给出波动范围——单次异常拉高平均时，看范围
                          就能分辨「一直慢」还是「偶尔慢」）
  -h, --help              显示本帮助

输出：
  stdout 是 Markdown 表格，可直接粘进 Issue 或文档；日志走 stderr。

退出码：
  0  正常（没有失败记录也算正常）
  1  参数或环境错误（缺依赖、目录不存在、没有任何报告）
  2  历史中存在失败记录——便于在脚本里据此告警

示例：
  # 看看最近的同步整体情况
  ./scripts/history.sh

  # 某个镜像是不是一直在失败
  ./scripts/history.sh --image registry.k8s.io/pause:3.9

  # 失败的镜像里，哪些最值得先处理
  ./scripts/history.sh --top-failures 5

  # 同步速度被谁拖慢了
  ./scripts/history.sh --slowest 5
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
        REPORT_NAME="$2"; shift 2 ;;
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
}

# ---------------------------------------------------------------------------
# 数据获取
# ---------------------------------------------------------------------------

# 从 Actions 下载最近的报告附件。
#
# 每次运行的附件都放进各自的子目录，否则同名文件会互相覆盖——而覆盖掉的
# 恰好是除最后一次以外的全部数据。
download_reports() {
  command -v gh >/dev/null 2>&1 || die "未找到 gh CLI。安装：https://cli.github.com —— 或用 --dir 指定本地报告目录"
  command -v jq >/dev/null 2>&1 || die "未找到 jq"

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "${WORK_DIR}"' EXIT

  log_info "正在获取最近 ${LIMIT} 次运行..."

  local -a run_ids=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && run_ids+=("$id")
  done < <(gh run list --limit "$LIMIT" --json databaseId --jq '.[].databaseId' 2>/dev/null || true)

  [[ ${#run_ids[@]} -gt 0 ]] || die "没有取到任何运行记录。请确认当前目录在一个 GitHub 仓库中，且 gh 已登录"

  local got=0
  for id in "${run_ids[@]}"; do
    # 下载失败是正常的：不是每次运行都在做同步（还有 CI、Release 等工作流），
    # 那些运行自然没有这个附件。因此这里只计数，不报错。
    if gh run download "$id" -n "$REPORT_NAME" -D "${WORK_DIR}/${id}" >/dev/null 2>&1; then
      got=$((got + 1))
    fi
  done

  log_info "本次运行列表中有 ${got} 次带同步报告"
  [[ "$got" -gt 0 ]] || die "这 ${#run_ids[@]} 次运行里没有任何「${REPORT_NAME}」附件。换一个 --report-name 或用 --dir 指定本地报告目录"
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
  totals="$(jq -s '{
      runs: length,
      first: (map(.generated_at) | min),
      last: (map(.generated_at) | max),
      total: (map(.total) | add),
      success: (map(.success) | add),
      skipped: (map(.skipped) | add),
      failed: (map(.failed) | add)
    }' "${files[@]}")"

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
  rows="$(jq -s --argjson n "$SLOWEST" '
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
  ' "${files[@]}")"

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

  log_info "共读取 ${#files[@]} 份报告"
  echo ""

  # --slowest 是独立的查询模式：只看耗时，不再叠加失败排行
  if [[ -n "$SLOWEST" ]]; then
    print_slowest "${files[@]}"
  else
    print_summary "${files[@]}"
  fi
  echo ""

  # 历史里有失败就返回 2，便于在脚本或 CI 里据此判断。
  # 注意这是「历史中有过失败」，不代表本次运行失败。
  local any_fail
  any_fail="$(jq -s 'map(.failed // 0) | add' "${files[@]}")"
  if [[ "${any_fail:-0}" -gt 0 ]]; then
    return 2
  fi
  return 0
}

main "$@"
