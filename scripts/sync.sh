#!/usr/bin/env bash
#
# sync.sh —— 容器镜像同步引擎
#
# 本项目所有镜像同步逻辑的唯一实现。GitHub Actions 工作流与本地命令行
# 调用的是同一份代码，因此不存在「CI 里能跑、本地跑不通」或两处逻辑各自漂移的问题。
#
# 用法：
#   ./scripts/sync.sh --src IMAGES --dest REGISTRY [选项]
#
# 运行 ./scripts/sync.sh --help 查看完整说明。

set -euo pipefail

# ---------------------------------------------------------------------------
# 默认配置
# ---------------------------------------------------------------------------
DEST_REGISTRY=""
DEST_EXACT=""
PLATFORMS=""
STRIP_ATTESTATION="false"
MAX_RETRIES="3"
DRY_RUN="false"
REPORT_DIR=""
REPORT_NAME="sync-report"
REGCTL_VERSION="v0.11.6"
declare -a SOURCE_IMAGES=()
declare -a SOURCE_FILES=()

# 结果收集（与 SOURCE_IMAGES 下标一一对应）
declare -a R_SRC=()
declare -a R_DEST=()
declare -a R_STATUS=()
declare -a R_PLATFORM=()
declare -a R_SECONDS=()
declare -a R_NOTE=()

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET=""
fi

# 日志一律走 stderr，保证 stdout 只承载结构化数据
log_info()  { printf '%s[信息]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_ok()    { printf '%s[成功]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
log_warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_dim()   { printf '%s%s%s\n'        "$C_DIM"               "$*" "$C_RESET" >&2; }

die() {
  log_error "$@"
  exit 1
}

# GitHub Actions 分组折叠，本地运行时退化为普通输出
group_start() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::group::%s\n' "$1" >&2
  else
    log_info "$1"
  fi
}
group_end() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::endgroup::\n' >&2
  fi
}

# 把消息登记为 GitHub Actions 的注解，会直接显示在运行页面与 PR 上。
# 本地运行时静默，不干扰正常输出。
#
# 这里刻意不写成「[[ ... ]] && printf ... || true」：
# A && B || C 并不是 if-then-else —— B 执行失败时 C 同样会跑，
# 静态检查的 SC2015 提示的正是这一点。用 if 表达意图更准确。
gh_annotation() {
  local level="$1" message="$2"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::%s::%s\n' "$level" "$message" >&2
  fi
}
gh_notice()  { gh_annotation notice  "$1"; }
gh_warning() { gh_annotation warning "$1"; }
gh_error()   { gh_annotation error   "$1"; }

usage() {
  cat <<'EOF'
sync.sh —— 容器镜像同步引擎

用法：
  ./scripts/sync.sh --src <镜像> --dest <目标仓库前缀> [选项]
  ./scripts/sync.sh --file <镜像清单文件> --dest <目标仓库前缀> [选项]

目标地址（必填其一）：
  -d, --dest <前缀>        目标仓库前缀。最终目标为「前缀 + 源镜像路径（/ 替换为 _）」，
                           例如 registry.cn-shenzhen.aliyuncs.com/nicholyx
      --dest-exact <地址>  精确指定完整目标地址，不再自动拼接源镜像名。
                           只能搭配单个源镜像使用，例如
                           harbor.example.com/library/nginx:1.27

镜像来源（至少提供一项，可同时使用）：
  -s, --src <镜像>         源镜像，可重复指定；也支持逗号 / 分号 / 换行分隔的多个镜像
  -f, --file <路径>        从文件读取镜像列表，每行一个，# 开头为注释，空行忽略

可选：
  -p, --platforms <列表>   逗号分隔的平台列表。仅在 --strip-attestation 下生效；
                           不指定时会自动探测源镜像的平台
      --strip-attestation  剔除 attestation manifest，改用 regctl 重建索引
                           （源镜像带 provenance/SBOM 时使用，如 netbirdio）
  -r, --retries <次数>     单个镜像的失败重试次数，默认 3
      --dry-run            只打印将要执行的命令，不实际推送
      --report-dir <目录>  把同步报告写入该目录（同时生成 .md 与 .json）
      --regctl-version <v> 指定 regctl 版本，默认 v0.11.6
  -h, --help               显示本帮助

退出码：
  0  全部镜像同步成功
  1  参数或环境错误（缺少依赖、参数非法）
  2  至少一个镜像同步失败（其余镜像仍会继续尝试）

示例：
  # 同步单个镜像
  ./scripts/sync.sh -s registry.k8s.io/pause:3.9 -d registry.cn-shenzhen.aliyuncs.com/nicholyx

  # 批量同步，先看命令对不对
  ./scripts/sync.sh --src "nginx:1.27,redis:7.4" -d harbor.example.com/library --dry-run

  # 剔除 attestation，只保留 amd64 与 arm64
  ./scripts/sync.sh -s ghcr.io/netbirdio/netbird:0.28.0 -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
      --strip-attestation --platforms linux/amd64,linux/arm64
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--src|--source)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SOURCE_IMAGES+=("$2"); shift 2 ;;      -f|--file|--source-file)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SOURCE_FILES+=("$2"); shift 2 ;;
      -d|--dest|--dest-registry)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        DEST_REGISTRY="$2"; shift 2 ;;
      --dest-exact)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        DEST_EXACT="$2"; shift 2 ;;
      -p|--platforms)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        PLATFORMS="$2"; shift 2 ;;
      --strip-attestation)
        STRIP_ATTESTATION="true"; shift ;;
      -r|--retries)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        MAX_RETRIES="$2"; shift 2 ;;
      --dry-run|-n)
        DRY_RUN="true"; shift ;;
      --report-dir)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        REPORT_DIR="$2"; shift 2 ;;
      --regctl-version)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        REGCTL_VERSION="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      --)
        shift; break ;;
      *)
        log_error "未知参数：$1"
        echo "" >&2
        usage >&2
        exit 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 去掉可能误带的 docker:// 前缀，得到干净的镜像引用
normalize_ref() {
  local ref="$1"
  printf '%s' "${ref#docker://}"
}

# 由源镜像推导目标仓库名。
# 阿里云个人版仓库不支持多级路径，因此把 / 全部替换为 _。
dest_repo_for() {
  local ref="$1"
  printf '%s' "${ref//\//_}"
}

# 判断字符串是否符合镜像引用的大致格式。
# 不追求完整实现 OCI 规范，只拦住明显的误填（例如贴了 URL、带了空格）。
validate_ref() {
  local ref="$1"
  [[ -n "$ref" ]]                    || { echo "镜像引用为空"; return 1; }
  [[ "$ref" != *" "* ]]              || { echo "镜像引用中不能包含空格"; return 1; }
  [[ "$ref" != *"://"* ]]            || { echo "镜像引用不应带协议前缀（如 https://）"; return 1; }
  [[ "$ref" =~ ^[a-zA-Z0-9] ]]       || { echo "镜像引用必须以字母或数字开头"; return 1; }
  [[ "$ref" == *:* || "$ref" == *"@"* ]] || { echo "镜像引用缺少 tag 或 digest，例如 nginx:1.27"; return 1; }
  return 0
}

# 探测源镜像包含哪些平台。
# 仅当源是 manifest list / OCI index 时才有意义；单平台镜像返回空。
# 依赖 skopeo 与 jq。
detect_platforms() {
  local ref="$1" raw
  raw="$(skopeo inspect --raw "docker://${ref}" 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -r '
    .manifests[]?.platform
    | select(.architecture != null and .architecture != "unknown")
    | "\(.os)/\(.architecture)"
  ' 2>/dev/null | sort -u | paste -sd, - || true
}

ensure_skopeo() {
  if command -v skopeo >/dev/null 2>&1; then
    return 0
  fi
  # dry-run 不实际执行命令，缺少 skopeo 不应阻断「先看看命令拼得对不对」这个用法
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "未找到 skopeo（dry-run 模式，仅提示不中断）"
    return 0
  fi
  die "未找到 skopeo，请先安装：https://github.com/containers/skopeo/blob/main/install.md"
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || log_warn "未找到 jq，将无法自动探测平台，请用 --platforms 显式指定"
}

# 按需下载 regctl 官方二进制。已在 PATH 中则直接复用。
ensure_regctl() {
  if command -v regctl >/dev/null 2>&1; then
    return 0
  fi

  # dry-run 不需要真的执行 regctl，也就不必下载
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "未找到 regctl（dry-run 模式，仅提示不中断）"
    return 0
  fi

  local os arch bindir url
  bindir="${HOME}/.regclient/bin"

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "regctl 不支持的 CPU 架构：${arch}" ;;
  esac

  url="https://github.com/regclient/regclient/releases/download/${REGCTL_VERSION}/regctl-${os}-${arch}"
  log_info "下载 regctl ${REGCTL_VERSION}（${os}/${arch}）..."
  mkdir -p "$bindir"
  curl -fsSL "$url" -o "${bindir}/regctl" || die "regctl 下载失败：${url}"
  chmod +x "${bindir}/regctl"
  export PATH="${bindir}:${PATH}"
  log_ok "regctl 已就绪：$(regctl version --format '{{.VCSTag}}' 2>/dev/null || echo "$REGCTL_VERSION")"
}

# ---------------------------------------------------------------------------
# 同步实现
# ---------------------------------------------------------------------------

# 常规路径：skopeo 原样搬运，--all 保证 multi-arch 索引完整保留
sync_via_skopeo() {
  local src="$1" dest="$2"
  local -a cmd=(skopeo copy --all --retry-times "$MAX_RETRIES"
                "docker://${src}" "docker://${dest}")
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dim "  [dry-run] ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}"
}

# 特殊路径：用 regctl 重建索引，只包含指定平台，
# 从而绕开阿里云 ACR 对 OCI 1.1 空 blob（attestation）的拒绝。
sync_via_regctl() {
  local src="$1" dest="$2" platforms="$3"
  local -a platform_args=()
  local p

  [[ -n "$platforms" ]] || die "regctl 模式需要平台列表，请用 --platforms 指定"

  # regctl 要求 --platform 重复传递，不能用逗号分隔的单个参数。
  # 这里把逗号换成换行后逐行读取，而不是临时改 IFS——
  # 改 IFS 会连带影响后面 "${cmd[*]}" 的展开，导致日志里的命令被逗号连成一串。
  while IFS= read -r p; do
    p="${p// /}"
    if [[ -n "$p" ]]; then
      platform_args+=(--platform "$p")
    fi
  done < <(printf '%s' "$platforms" | tr ',' '\n')

  [[ ${#platform_args[@]} -gt 0 ]] || die "平台列表解析结果为空：${platforms}"

  local -a cmd=(regctl index create "$dest"
                --ref "$src"
                "${platform_args[@]}")
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dim "  [dry-run] ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}"
}

# 同步单个镜像，返回 0 表示成功
sync_one() {
  local src="$1" dest="$2" platforms="$3"
  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    sync_via_regctl "$src" "$dest" "$platforms"
  else
    sync_via_skopeo "$src" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# 镜像列表收集
# ---------------------------------------------------------------------------

# 把逗号 / 分号 / 换行分隔的输入拆成一行一个
split_images() {
  local raw="$1"
  raw="${raw//,/ }"
  raw="${raw//;/ }"
  raw="${raw//$'\n'/ }"
  raw="${raw//$'\r'/ }"
  printf '%s\n' "$raw" | tr -s ' ' '\n'
}

collect_images() {
  local -a candidates=()
  local item line

  # 注意：这里必须先判断数组长度再遍历。
  # 在 set -u 下，空数组的 "${arr[@]}" 在部分 bash 版本中会展开成一个空字符串元素，
  # 直接遍历会凭空多出一轮循环（曾导致「镜像清单文件不存在：」这种空文件名报错）。
  if [[ ${#SOURCE_IMAGES[@]} -gt 0 ]]; then
    for item in "${SOURCE_IMAGES[@]}"; do
      if [[ -z "$item" ]]; then
        continue
      fi
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          candidates+=("$line")
        fi
      done < <(split_images "$item")
    done
  fi

  if [[ ${#SOURCE_FILES[@]} -gt 0 ]]; then
    for item in "${SOURCE_FILES[@]}"; do
      if [[ -z "$item" ]]; then
        continue
      fi
      if [[ ! -f "$item" ]]; then
        die "镜像清单文件不存在：${item}"
      fi
      while IFS= read -r line; do
        # 去掉行内注释与首尾空白
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "$line" ]]; then
          candidates+=("$line")
        fi
      done < "$item"
    done
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    die "没有提供任何源镜像，请用 --src 或 --file 指定"
  fi

  # 去重（保持原有顺序）。
  # 这里用 awk 而不是关联数组，是为了兼容 macOS 自带的 bash 3.2（不支持 declare -A）。
  local -a unique=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      unique+=("$line")
    fi
  done < <(printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++')

  SOURCE_IMAGES=("${unique[@]}")
}

# ---------------------------------------------------------------------------
# 报告输出
# ---------------------------------------------------------------------------
emit_summary() {
  local total=${#R_SRC[@]} ok=0 fail=0 i
  for i in "${!R_STATUS[@]}"; do
    if [[ "${R_STATUS[$i]}" == "success" ]]; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done

  log_info "同步完成：共 ${total} 个镜像，成功 ${ok} 个，失败 ${fail} 个"

  # ---- 控制台表格 ----
  printf '\n' >&2
  printf '%s\n' "────────────────────────────────────────────────────────" >&2
  for i in "${!R_SRC[@]}"; do
    local mark="${C_GREEN}✓${C_RESET}"
    [[ "${R_STATUS[$i]}" == "success" ]] || mark="${C_RED}✗${C_RESET}"
    printf ' %s %s\n' "$mark" "${R_SRC[$i]}" >&2
    printf '   %s→ %s%s\n' "$C_DIM" "${R_DEST[$i]}" "$C_RESET" >&2
    printf '   %s平台 %s · 耗时 %ss%s\n' "$C_DIM" "${R_PLATFORM[$i]:-未知}" "${R_SECONDS[$i]}" "$C_RESET" >&2
    if [[ -n "${R_NOTE[$i]}" ]]; then
      printf '   %s%s%s\n' "$C_YELLOW" "${R_NOTE[$i]}" "$C_RESET" >&2
    fi
  done
  printf '%s\n' "────────────────────────────────────────────────────────" >&2

  # ---- GitHub Step Summary ----
  # 这是 GitHub 原生的能力：运行结束后在 Actions 页面直接渲染成表格，
  # 不需要点开日志逐行翻找。
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## 镜像同步报告"
      echo ""
      echo "| 源镜像 | 目标镜像 | 结果 | 平台 | 耗时 |"
      echo "| --- | --- | :---: | --- | --- |"
      for i in "${!R_SRC[@]}"; do
        local icon="✅"
        [[ "${R_STATUS[$i]}" == "success" ]] || icon="❌"
        echo "| \`${R_SRC[$i]}\` | \`${R_DEST[$i]}\` | ${icon} | ${R_PLATFORM[$i]:-—} | ${R_SECONDS[$i]}s |"
      done
      echo ""
      echo "**合计**：${total} 个镜像 · 成功 ${ok} · 失败 ${fail}"
      echo ""
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "> ⚠️ 本次为 dry-run，未实际推送任何镜像。"
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  # ---- 报告文件 ----
  if [[ -n "$REPORT_DIR" ]]; then
    write_report "$total" "$ok" "$fail"
  fi

  [[ "$fail" -eq 0 ]] || return 2
  return 0
}

write_report() {
  local total="$1" ok="$2" fail="$3" i
  mkdir -p "$REPORT_DIR"

  local md="${REPORT_DIR}/${REPORT_NAME}.md"
  {
    echo "# 镜像同步报告"
    echo ""
    echo "- 生成时间：$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "- 目标地址：${DEST_EXACT:-$DEST_REGISTRY}"
    echo "- 同步模式：$([[ "$STRIP_ATTESTATION" == "true" ]] && echo 'regctl（剔除 attestation）' || echo 'skopeo（保留全部平台）')"
    echo "- 结果：共 ${total} 个镜像，成功 ${ok} 个，失败 ${fail} 个"
    echo ""
    echo "| 源镜像 | 目标镜像 | 结果 | 平台 | 耗时 |"
    echo "| --- | --- | :---: | --- | --- |"
    for i in "${!R_SRC[@]}"; do
      local icon="✅"
      [[ "${R_STATUS[$i]}" == "success" ]] || icon="❌"
      echo "| \`${R_SRC[$i]}\` | \`${R_DEST[$i]}\` | ${icon} | ${R_PLATFORM[$i]:-—} | ${R_SECONDS[$i]}s |"
    done
  } > "$md"

  local json="${REPORT_DIR}/${REPORT_NAME}.json"
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "dest_registry": "%s",\n' "${DEST_EXACT:-$DEST_REGISTRY}"
    printf '  "strip_attestation": %s,\n' "$STRIP_ATTESTATION"
    printf '  "total": %s,\n' "$total"
    printf '  "success": %s,\n' "$ok"
    printf '  "failed": %s,\n' "$fail"
    printf '  "images": [\n'
    for i in "${!R_SRC[@]}"; do
      printf '    {"source": "%s", "dest": "%s", "status": "%s", "platforms": "%s", "seconds": %s}' \
        "${R_SRC[$i]}" "${R_DEST[$i]}" "${R_STATUS[$i]}" "${R_PLATFORM[$i]:-}" "${R_SECONDS[$i]}"
      [[ "$i" -lt $((${#R_SRC[@]} - 1)) ]] && printf ','
      printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
  } > "$json"

  log_info "报告已写入：${md}"
  log_info "报告已写入：${json}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if [[ -z "$DEST_REGISTRY" && -z "$DEST_EXACT" ]]; then
    log_error "缺少必填参数：--dest 或 --dest-exact"
    echo "" >&2
    usage >&2
    exit 1
  fi

  DEST_REGISTRY="${DEST_REGISTRY#docker://}"
  DEST_REGISTRY="${DEST_REGISTRY%/}"
  DEST_EXACT="${DEST_EXACT#docker://}"

  ensure_skopeo
  ensure_jq
  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    ensure_regctl
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "dry-run 模式：只打印命令，不会推送任何镜像"
  fi

  collect_images

  if [[ -n "$DEST_EXACT" && ${#SOURCE_IMAGES[@]} -gt 1 ]]; then
    die "--dest-exact 只能搭配单个源镜像使用（当前提供了 ${#SOURCE_IMAGES[@]} 个）；批量同步请改用 --dest 前缀模式"
  fi

  if [[ -n "$PLATFORMS" && "$STRIP_ATTESTATION" != "true" ]]; then
    log_warn "--platforms 仅在 --strip-attestation 模式下生效，本次将忽略（skopeo 用 --all 同步全部平台）"
  fi

  local total=${#SOURCE_IMAGES[@]}
  log_info "待同步镜像 ${total} 个 → ${DEST_EXACT:-$DEST_REGISTRY}"

  local idx=0
  for raw_src in "${SOURCE_IMAGES[@]}"; do
    idx=$((idx + 1))
    local src dest_repo dest platforms start end elapsed status note=""

    src="$(normalize_ref "$raw_src")"

    if ! validate_ref "$src"; then
      # 格式明显不对的输入直接记为失败，不浪费一次网络请求
      R_SRC+=("$src"); R_DEST+=("—"); R_STATUS+=("failed")
      R_PLATFORM+=("—"); R_SECONDS+=("0"); R_NOTE+=("镜像引用格式错误：$(validate_ref "$src" || true)")
      log_error "[${idx}/${total}] 跳过非法镜像引用：${src}"
      continue
    fi

    if [[ -n "$DEST_EXACT" ]]; then
      dest="$DEST_EXACT"
    else
      dest_repo="$(dest_repo_for "$src")"
      dest="${DEST_REGISTRY}/${dest_repo}"
    fi

    # 决定平台列表：显式指定优先，否则尝试自动探测，最后回退默认值
    platforms="$PLATFORMS"
    if [[ "$STRIP_ATTESTATION" == "true" && -z "$platforms" ]]; then
      platforms="$(detect_platforms "$src" || true)"
      if [[ -n "$platforms" ]]; then
        log_info "[${idx}/${total}] 自动探测到平台：${platforms}"
      else
        platforms="linux/amd64,linux/arm64"
        log_warn "[${idx}/${total}] 无法自动探测平台，回退默认值：${platforms}"
      fi
    elif [[ "$STRIP_ATTESTATION" != "true" ]]; then
      platforms="全部（--all）"
    fi

    group_start "[${idx}/${total}] ${src}"
    log_info "目标：${dest}"
    log_info "平台：${platforms}"

    start="$(date +%s)"
    if sync_one "$src" "$dest" "$platforms"; then
      status="success"
      log_ok "[${idx}/${total}] 同步成功"
    else
      status="failed"
      note="同步失败，详见上方日志"
      log_error "[${idx}/${total}] 同步失败"
      gh_error "镜像同步失败：${src}"
    fi
    end="$(date +%s)"
    elapsed=$((end - start))

    R_SRC+=("$src"); R_DEST+=("$dest"); R_STATUS+=("$status")
    R_PLATFORM+=("$platforms"); R_SECONDS+=("$elapsed"); R_NOTE+=("$note")
    group_end
  done

  emit_summary
}

main "$@"
