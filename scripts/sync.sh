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
DEST_EXACT=""
declare -a DEST_REGISTRIES=()
PLATFORMS=""
STRIP_ATTESTATION="false"
MAX_RETRIES="3"
RETRY_DELAY=""
# 记录使用者是否显式指定过这两个参数。regctl 路径对它们无能为力，
# 而「默认值没生效」不值得打扰使用者，「显式指定的值没生效」必须说清楚。
RETRIES_EXPLICIT="false"
RETRY_DELAY_EXPLICIT="false"
DRY_RUN="false"
REPORT_DIR=""
REPORT_NAME="sync-report"
REGCTL_VERSION="v0.11.6"
CONCURRENCY="1"
TIMEOUT="600"
SKIP_EXISTING="false"
TLS_VERIFY="true"
NOTIFY_WEBHOOK=""
NOTIFY_TYPE="auto"
NOTIFY_ON="always"
WRITE_LOCK=""
declare -a SOURCE_IMAGES=()
declare -a SOURCE_FILES=()

# 镜像筛选。二者都是 ERE 正则，作用于源镜像的完整引用。
FILTER_REGEX=""
EXCLUDE_REGEX=""

# 与 SOURCE_IMAGES 按下标对齐：第 i 项非空表示该镜像被排除，内容为排除原因。
# 用「标记」而不是「从数组里删掉」是为了保住下标——下标同时决定了结果文件的
# 序号，删元素会让序号错位，结果表的顺序也就跟输入对不上了。
declare -a EXCLUDE_REASONS=()

# 被筛掉的镜像数量，由 apply_filters 填写，用于日志中的数量提示
FILTERED_OUT_COUNT="0"

# 单个镜像的结果写进这个目录下的独立文件。
# 之所以用文件而不是全局数组，是因为并发模式下每个任务是独立的子进程，
# 子进程对数组的修改不会传回父进程。
WORK_DIR=""

# 结果数组，由 load_results 从 WORK_DIR 读入
declare -a R_SRC=()
declare -a R_DEST=()
declare -a R_STATUS=()
declare -a R_PLATFORM=()
declare -a R_SECONDS=()
declare -a R_NOTE=()
declare -a R_SRC_DIGEST=()
declare -a R_DEST_DIGEST=()

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
log_skip()  { printf '%s[跳过]%s %s\n' "$C_DIM"               "$*" "$C_RESET" >&2; }

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
  -d, --dest <前缀>        目标仓库前缀。最终目标为「前缀 + 源镜像路径（压平）」，
                           例如 registry.cn-shenzhen.aliyuncs.com/nicholyx
                           **可重复指定以同时推送到多个目标**
      --dest-exact <地址>  精确指定完整目标地址，不再自动拼接源镜像名。
                           只能搭配单个源镜像、且不能与 --dest 混用，
                           例如 harbor.example.com/library/nginx:1.27

镜像来源（至少提供一项，可同时使用）：
  -s, --src <镜像>         源镜像，可重复指定；也支持逗号 / 分号 / 换行分隔的多个镜像
  -f, --file <路径>        从文件读取镜像列表，每行一个，# 开头为注释，空行忽略

筛选（作用于源镜像的完整引用，ERE 正则）：
      --filter <正则>      只同步匹配的镜像，例如 '^registry\.k8s\.io/'
      --exclude <正则>     跳过匹配的镜像，例如 '/pause:'
                           两者可同时使用：先 filter，后 exclude。
                           被排除的镜像仍会出现在结果表中并标注原因

可用性：
  -p, --platforms <列表>   逗号分隔的平台列表。仅在 --strip-attestation 下生效；
                           不指定时会自动探测源镜像的平台
      --strip-attestation  剔除 attestation manifest，改用 regctl 重建索引
                           （源镜像带 provenance/SBOM 时使用，如 netbirdio）
      --skip-existing      目标仓库已有完全相同的镜像时直接跳过，不重复推送。
                           默认的 skopeo 路径支持此优化；--strip-attestation
                           会重建索引，目标 digest 必然不同，因此不做跳过
      --tls-verify <bool>  是否校验 registry 的 TLS 证书，默认 true。
                           自建 HTTP 仓库（如本地 registry:2）填 false

性能与可靠性：
  -c, --concurrency <N>    并发同步的镜像数量，默认 1（串行）。
                           批量同步几十个镜像时调大能显著缩短总耗时，
                           建议值 4~8，过高可能触发上游限流
  -t, --timeout <秒>       单个镜像的超时时间，默认 600 秒（10 分钟）
  -r, --retries <次数>     单个镜像的失败重试次数，默认 3。
                           **仅对默认的 skopeo 路径生效**：--strip-attestation
                           走的是 regctl，而 regclient 自带重试策略（默认 5 次），
                           此时本参数会被忽略并给出告警
      --retry-delay <时长> 两次重试之间的固定间隔，例如 10s / 1m。默认不指定，
                           此时 skopeo 按失败次数指数退避——多数场景下这就够好，
                           只有窗口式限流的自建仓库才需要固定间隔。
                           同样仅对 skopeo 路径生效

输出与通知：
      --dry-run            只打印将要执行的命令，不实际推送
      --report-dir <目录>  把同步报告写入该目录（同时生成 .md 与 .json）
      --write-lock <路径>  把镜像与 digest 写成锁文件，可用于精确复现
      --regctl-version <v> 指定 regctl 版本，默认 v0.11.6

      --notify-webhook <url>  同步结束后把结果推送到这个 webhook。
                              不指定则完全不发送任何通知。
      --notify-type <类型>    钉钉 dingtalk / 飞书 feishu / Slack slack /
                              通用 generic，默认 auto（按 URL 自动识别）
      --notify-on <时机>      always（默认，总是通知）或 failure（仅失败时通知）

  -h, --help               显示本帮助

退出码：
  0  全部镜像同步成功（含被跳过的）
  1  参数或环境错误（缺少依赖、参数非法）
  2  至少一个镜像同步失败（其余镜像仍会继续尝试）

示例：
  # 同步单个镜像
  ./scripts/sync.sh -s registry.k8s.io/pause:3.9 -d registry.cn-shenzhen.aliyuncs.com/nicholyx

  # 批量同步，先看命令对不对
  ./scripts/sync.sh --src "nginx:1.27,redis:7.4" -d harbor.example.com/library --dry-run

  # 批量并发同步，并跳过已经同步过的镜像
  ./scripts/sync.sh --file images.lock.txt -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
      --concurrency 6 --skip-existing

  # 剔除 attestation，只保留 amd64 与 arm64
  ./scripts/sync.sh -s ghcr.io/netbirdio/netbird:0.28.0 -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
      --strip-attestation --platforms linux/amd64,linux/arm64

  # 从完整清单里只同步 kube-* 组件，并临时跳过已知有问题的 apiserver
  ./scripts/sync.sh --file images.lock.txt -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
      --filter 'kube-' --exclude 'kube-apiserver'
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
        SOURCE_IMAGES+=("$2"); shift 2 ;;
      -f|--file|--source-file)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SOURCE_FILES+=("$2"); shift 2 ;;
      --filter)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        FILTER_REGEX="$2"; shift 2 ;;
      --exclude)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        EXCLUDE_REGEX="$2"; shift 2 ;;
      -d|--dest|--dest-registry)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        DEST_REGISTRIES+=("$2"); shift 2 ;;
      --dest-exact)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        DEST_EXACT="$2"; shift 2 ;;
      -p|--platforms)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        PLATFORMS="$2"; shift 2 ;;
      --strip-attestation)
        STRIP_ATTESTATION="true"; shift ;;
      --skip-existing)
        SKIP_EXISTING="true"; shift ;;
      --tls-verify)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        TLS_VERIFY="$2"; shift 2 ;;
      -c|--concurrency)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        CONCURRENCY="$2"; shift 2 ;;
      -t|--timeout)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        TIMEOUT="$2"; shift 2 ;;
      -r|--retries)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        MAX_RETRIES="$2"; RETRIES_EXPLICIT="true"; shift 2 ;;
      --retry-delay)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        RETRY_DELAY="$2"; RETRY_DELAY_EXPLICIT="true"; shift 2 ;;
      --write-lock)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        WRITE_LOCK="$2"; shift 2 ;;
      --notify-webhook)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        NOTIFY_WEBHOOK="$2"; shift 2 ;;
      --notify-type)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        NOTIFY_TYPE="$2"; shift 2 ;;
      --notify-on)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        NOTIFY_ON="$2"; shift 2 ;;
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

# 校验数值型参数，避免把 --concurrency abc 这种输入带到后面才炸
validate_numeric() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "${name} 必须是非负整数，当前为「${value}」"
  fi
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
#
# 阿里云个人版仓库不支持多级路径，因此把路径分隔符压平。
#
# 有两处容易忽略的细节：
#
# 1. **剥掉 digest**：目标需要的是可寻址的名字而非不可变引用，
#    带着 @sha256:… 拼出来的目标地址是非法的，推送必然失败。
#    这个问题在使用锁文件（源引用天然带 digest）时会立刻暴露。
#
# 2. **端口后的冒号也要处理**：仓库名允许的字符集是
#    [a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*，**不含冒号**。而 registry 地址
#    可以带端口（如 localhost:5000），若只替换 / 就会生成
#    `localhost:5000_source_hello` 这种非法仓库名。
#    因此必须先分离出 tag——只有落在**最后一个 / 之后**的冒号才是 tag
#    分隔符——对名称部分同时替换 / 和 :，最后再拼回 tag。
dest_repo_for() {
  local ref="$1" digest="" name="" tag="" short=""

  # 剥掉 digest
  if [[ "$ref" == *"@"* ]]; then
    digest="${ref#*@}"
    ref="${ref%%@*}"
  fi

  # 分离 tag：只有最后一个 / 之后的冒号才是 tag 分隔符
  local last_segment="${ref##*/}"
  if [[ "$last_segment" == *:* ]]; then
    tag=":${last_segment#*:}"
    name="${ref%:*}"
  else
    name="$ref"
  fi

  # 压平：/ 和 : 都换成 _（仓库名不允许冒号，也不支持多级路径）
  name="${name//\//_}"
  name="${name//:/_}"

  # 源只给了 digest 没给 tag（形如 nginx@sha256:…）时，
  # 用 digest 前缀生成一个可读的 tag，避免目标没有 tag
  if [[ -z "$tag" && -n "$digest" ]]; then
    short="${digest#sha256:}"
    tag=":${short:0:12}"
  fi

  printf '%s%s' "$name" "$tag"
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

# 统一的 skopeo inspect --raw 调用。
#
# 之所以要包一层：**TLS 设置必须与 copy 保持一致**。曾经 --tls-verify false
# 只传给了 skopeo copy，而跳过判定等处的 inspect 仍在用默认的 TLS 校验，
# 于是对 HTTP registry 的探测全部失败，「目标是否已是最新」永远判为否，
# 增量跳过形同虚设。
#
# 这个问题是 CI 的真实同步集成测试抓出来的——dry-run 不执行跳过判定，
# 本地 mock 又绕开了真实 TLS，两者都覆盖不到。
skopeo_inspect_raw() {
  local ref="$1"
  local -a cmd=(skopeo inspect --raw)
  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--tls-verify=false)
  fi
  cmd+=("docker://${ref}")
  "${cmd[@]}"
}

# 探测源镜像包含哪些平台。
# 仅当源是 manifest list / OCI index 时才有意义；单平台镜像返回空。
# 依赖 skopeo 与 jq。
detect_platforms() {
  local ref="$1" raw
  raw="$(skopeo_inspect_raw "$ref" 2>/dev/null)" || return 1
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
# 超时包装
#
# GNU coreutils 提供 timeout，macOS 需要装 coreutils 才有对应的 gtimeout。
# 两者都没有时降级为不限制超时，并给出一次提示——这比直接报错更友好，
# 毕竟超时只是保护措施，不是功能本身。
# ---------------------------------------------------------------------------
declare -a TIMEOUT_CMD=()

setup_timeout() {
  if [[ "$TIMEOUT" == "0" ]]; then
    TIMEOUT_CMD=()
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout "$TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout "$TIMEOUT")
  else
    TIMEOUT_CMD=()
    log_warn "未找到 timeout 命令，单镜像超时保护已禁用（macOS 可 brew install coreutils）"
  fi
}

run_with_timeout() {
  if [[ ${#TIMEOUT_CMD[@]} -gt 0 ]]; then
    "${TIMEOUT_CMD[@]}" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# 同步实现
# ---------------------------------------------------------------------------

# 常规路径：skopeo 原样搬运，--all 保证 multi-arch 索引完整保留
sync_via_skopeo() {
  local src="$1" dest="$2"
  # 用数组拼参数而不是条件分支重复整条命令：
  # 这样也不会踩到「空数组在 set -u 下展开出错」的坑
  local -a cmd=(skopeo copy --all --retry-times "$MAX_RETRIES")

  # 不指定 --retry-delay 时，skopeo 的等待时间随失败次数指数增长。
  # 显式指定则固定间隔——这是为窗口式限流的仓库准备的，不是默认选项。
  if [[ -n "$RETRY_DELAY" ]]; then
    cmd+=(--retry-delay "$RETRY_DELAY")
  fi

  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--src-tls-verify=false --dest-tls-verify=false)
  fi

  cmd+=("docker://${src}" "docker://${dest}")

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dim "  [dry-run] ${cmd[*]}"
    return 0
  fi

  run_with_timeout "${cmd[@]}"
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
  #
  # **结尾的换行不能省。** read 在读到「没有换行符收尾的最后一段」时会返回
  # 非零（表示遇到 EOF 而非完整行），while 便不再执行循环体。少这个换行会导致：
  #   - 单个平台：一段都读不到，platform_args 为空，直接判定为解析失败
  #   - 多个平台：最后一段被静默丢弃（表现为 arm64 没同步，但毫无报错）
  # 注意 sources 一侧同样没有结尾换行——detect_platforms 用 paste -sd, - 生成，
  # 所以这里必须自己补上，不能指望输入。
  while IFS= read -r p; do
    p="${p// /}"
    if [[ -n "$p" ]]; then
      platform_args+=(--platform "$p")
    fi
  done < <(printf '%s\n' "$platforms" | tr ',' '\n')

  [[ ${#platform_args[@]} -gt 0 ]] || die "平台列表解析结果为空：${platforms}"

  if [[ "$DRY_RUN" == "true" ]]; then
    # 这里打印 platform_args 本身，而不是把 ${platforms} 的逗号换成 --platform。
    # 两者看起来一样，但来源不同：后者是「按输入的想当然」，前者才是真正会执行的参数。
    # 上面那个丢平台的缺陷之所以长期没被发现，正是因为 dry-run 一直在按输入复述，
    # 而不是复述实际参数——dry-run 一旦与实际行为脱节，就失去了它全部的意义。
    log_dim "  [dry-run] regctl index create ${dest} --ref ${src} ${platform_args[*]}"
    return 0
  fi

  run_with_timeout regctl index create "$dest" \
    --ref "$src" \
    "${platform_args[@]}"
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

# 提取镜像的「平台 → 子 manifest digest」映射。
#
# 为什么不直接比较顶层 manifest 的完整 JSON：不同 registry 对 mediaType、
# annotations 与字段顺序的处理并不一致——例如源是 OCI index、目标被规范化成
# Docker manifest list，两边内容完全一致却会被判为不同，导致跳过永远不生效。
# 逐个比较各平台子 manifest 的 digest，才真正对应「镜像内容是否一致」。
#
# 单平台镜像没有 manifests 字段，返回空，由调用方决定退化策略。
#
# Windows 平台被排除在外。实测发现它的 digest 在搬运前后必然不同
# （源 registry.k8s.io/pause:3.9 的两个 windows/amd64 条目是 4e2a…/4fe1…，
# 推送到阿里云后变成 26b1…/fb04…，其余 5 个 Linux 平台则完全一致）——
# 说明 manifest 在传输过程中被重新生成了。把它纳入比较只会让跳过永远
# 不生效，而本项目面向的是国内 Linux 容器环境，用不到 Windows 镜像。
platform_digest_map() {
  skopeo_inspect_raw "$1" 2>/dev/null \
    | jq -r '
        .manifests[]?
        | select(.platform.architecture != null and .platform.architecture != "unknown")
        | select(.platform.os != "windows")
        | "\(.platform.os)/\(.platform.architecture) \(.digest)"
      ' 2>/dev/null \
    | sort
}

# 判断目标仓库是否已有与源一致的镜像。
#
# 任何一步失败都返回「不一致」——宁可多同步一次，也不要错误地跳过。
is_up_to_date() {
  local src="$1" dest="$2"
  local src_map dest_map src_norm dest_norm

  # 这里刻意不判断 platform_digest_map 的退出码。
  # set -o pipefail 下，只要管道中任一环节返回非零，整个管道就是失败的——
  # 而 skopeo 完全可能在输出了正确内容之后仍返回非零（例如对个别平台打印警告）。
  # 实测正是这一点让跳过从未生效：摘要明明一字不差，却因为退出码被判为「不一致」。
  # 真正有意义的是**有没有拿到内容**，所以只看输出。
  src_map="$(platform_digest_map "$src" || true)"
  dest_map="$(platform_digest_map "$dest" || true)"

  if [[ "${SYNC_DEBUG:-}" == "1" ]]; then
    log_dim "  [debug] 源平台摘要: ${src_map:-<无>}"
    log_dim "  [debug] 目标平台摘要: ${dest_map:-<无>}"
  fi

  # multi-arch：逐平台比对子 manifest 的 digest
  if [[ -n "$src_map" ]]; then
    if [[ -n "$dest_map" && "$src_map" == "$dest_map" ]]; then
      return 0
    fi
    return 1
  fi

  # 单平台镜像没有 manifests 字段，退化为比较规范化后的 manifest JSON。
  # 同样只看内容而不看退出码，理由见上。
  src_norm="$(skopeo_inspect_raw "$src" 2>/dev/null | jq -S -c . 2>/dev/null || true)"
  [[ -n "$src_norm" ]] || return 1

  dest_norm="$(skopeo_inspect_raw "$dest" 2>/dev/null | jq -S -c . 2>/dev/null || true)"
  [[ -n "$dest_norm" ]] || return 1

  [[ "$src_norm" == "$dest_norm" ]]
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

# 校验正则是否合法。
#
# grep 的退出码语义正好可用：0 匹配、1 不匹配、2 出错。所以「喂空输入」
# 就能把语法错误与「没有匹配」区分开——1 是正常结果，只有 2 才说明正则写错了。
# 这个判断放在任何同步动作之前，避免跑到一半才发现参数有问题。
validate_regex() {
  local name="$1" re="$2"
  [[ -n "$re" ]] || return 0

  local code=0
  printf '' | grep -Eq -- "$re" 2>/dev/null || code=$?

  if [[ "$code" -eq 2 ]]; then
    die "${name} 不是合法的正则表达式：「${re}」"
  fi
}

# 按 --filter / --exclude 标记要排除的镜像。
#
# 注意这里**只做标记，不删除元素**。下标同时决定结果文件的序号，删掉元素会让
# 序号整体前移，被排除项之后的镜像序号全错，结果表的顺序也就与输入对不上了。
apply_filters() {
  [[ -n "$FILTER_REGEX" || -n "$EXCLUDE_REGEX" ]] || return 0

  local i src
  local excluded=0

  for i in "${!SOURCE_IMAGES[@]}"; do
    src="${SOURCE_IMAGES[$i]}"

    if [[ -n "$FILTER_REGEX" ]] && ! printf '%s\n' "$src" | grep -Eq -- "$FILTER_REGEX"; then
      EXCLUDE_REASONS[i]="未匹配 --filter「${FILTER_REGEX}」"
      excluded=$((excluded + 1))
      continue
    fi

    if [[ -n "$EXCLUDE_REGEX" ]] && printf '%s\n' "$src" | grep -Eq -- "$EXCLUDE_REGEX"; then
      EXCLUDE_REASONS[i]="匹配 --exclude「${EXCLUDE_REGEX}」"
      excluded=$((excluded + 1))
      continue
    fi
  done

  local total=${#SOURCE_IMAGES[@]}
  if [[ "$excluded" -gt 0 ]]; then
    log_info "筛选：${total} 个镜像中排除 ${excluded} 个，实际同步 $((total - excluded)) 个"
  fi

  # 全被筛掉时明确失败。静默地「什么都不同步然后报成功」是最糟的结果——
  # 使用者会以为同步完成了，直到集群拉不到镜像才发现。
  if [[ "$excluded" -eq "$total" ]]; then
    die "全部 ${total} 个镜像都被筛掉了，没有可同步的镜像。请放宽 --filter / --exclude"
  fi

  FILTERED_OUT_COUNT="$excluded"
}

# ---------------------------------------------------------------------------
# 单个镜像的处理（可能在子进程中运行）
# ---------------------------------------------------------------------------

# 计算镜像的内容摘要（digest）。
#
# digest 是不可变的——同一个 tag 今天是 sha256:aaa，明天可能变成 sha256:bbb
# （上游重新构建了）。不记录它，就丢失了「这次同步的到底是哪一份镜像」。
#
# 这里对 --raw 拿到的原始 manifest 字节做 sha256，与 OCI 的 digest 定义一致。
# 拿不到就返回空，由调用方决定是否显示为「未知」——**不应因此让同步失败**。
compute_digest() {
  local ref="$1" raw
  raw="$(skopeo_inspect_raw "$ref" 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  printf 'sha256:%s' "$(printf '%s' "$raw" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
}

# 短摘要，用于在表格里展示。完整的值留在报告文件中。
short_digest() {
  local d="$1"
  [[ -n "$d" ]] || { printf '—'; return 0; }
  printf '%s' "${d:0:19}…"
}

# 结果文件的分隔符。
#
# 这里**不能用制表符**：bash 把 IFS 中的空白字符（空格、tab、换行）视为
# 「可合并的空白」，相邻的两个 tab 会被当作一个分隔符。而 note 为空时正好
# 会产生连续的 tab，导致其后所有字段整体左移——实测表现为目标 digest
# 被读成空值。改用 ASCII 的 Unit Separator（0x1f）这种非空白字符，
# bash 才会严格按字符切分，空字段得以保留。
readonly FIELD_SEP=$'\x1f'

write_result() {
  local file="$1" src="$2" dest="$3" status="$4" platform="$5" seconds="$6" note="$7"
  local src_digest="$8" dest_digest="$9"
  # note 里若混入分隔符会破坏字段结构，统一换成空格
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$src" "$FIELD_SEP" "$dest" "$FIELD_SEP" "$status" "$FIELD_SEP" \
    "$platform" "$FIELD_SEP" "$seconds" "$FIELD_SEP" "${note//$FIELD_SEP/ }" "$FIELD_SEP" \
    "$src_digest" "$FIELD_SEP" "$dest_digest" > "$file"
}

# 解析本镜像要使用的平台列表
resolve_platforms() {
  local src="$1" platforms=""

  if [[ "$STRIP_ATTESTATION" != "true" ]]; then
    printf '%s' "全部（--all）"
    return 0
  fi

  platforms="$PLATFORMS"
  if [[ -z "$platforms" ]]; then
    platforms="$(detect_platforms "$src" || true)"
    if [[ -n "$platforms" ]]; then
      log_info "自动探测到平台：${platforms}"
    else
      platforms="linux/amd64,linux/arm64"
      log_warn "无法自动探测平台，回退默认值：${platforms}"
    fi
  fi
  printf '%s' "$platforms"
}

# 结果文件的路径。按「镜像序号-目标序号」命名，零填充保证字典序正确。
result_file_for() {
  printf '%s/result-%04d-%02d' "$WORK_DIR" "$1" "$2"
}

process_one() {
  local idx="$1" raw_src="$2"
  local total="$3"
  local src dest dest_repo platforms
  local src_digest="" dest_digest=""
  local -a dests=()

  src="$(normalize_ref "$raw_src")"

  # 格式明显不对的输入直接记为失败，不浪费一次网络请求
  if ! validate_ref "$src"; then
    local reason
    reason="$(validate_ref "$src" 2>&1 || true)"
    log_error "[${idx}/${total}] 跳过非法镜像引用：${src} —— ${reason}"
    gh_error "镜像引用格式错误：${src}（${reason}）"
    write_result "$(result_file_for "$idx" 1)" "$src" "—" "failed" "—" "0" \
      "镜像引用格式错误：${reason}" "" ""
    return 0
  fi

  # 构造目标列表。支持多目标：每个镜像会对列表中的每个目标各同步一次。
  dest_repo="$(dest_repo_for "$src")"
  if [[ -n "$DEST_EXACT" ]]; then
    dests=("$DEST_EXACT")
  else
    local d
    for d in "${DEST_REGISTRIES[@]}"; do
      dests+=("${d}/${dest_repo}")
    done
  fi

  group_start "[${idx}/${total}] ${src}"

  # 平台取决于源镜像、与目标无关，因此只解析一次
  platforms="$(resolve_platforms "$src")"

  local di=0
  local dest_total=${#dests[@]}
  for dest in "${dests[@]}"; do
    di=$((di + 1))

    local start end elapsed status note=""
    local result_file
    result_file="$(result_file_for "$idx" "$di")"

    if [[ "$dest_total" -gt 1 ]]; then
      log_info "目标 [${di}/${dest_total}]：${dest}"
    else
      log_info "目标：${dest}"
    fi
    log_info "平台：${platforms}"

    # 增量跳过：目标已经有完全相同的镜像时不必再推一次。
    # **每个目标独立判定**——某个目标已是最新，不代表其他目标也是。
    # strip-attestation 模式会重建索引、目标 digest 必然与源不同，因此不做跳过。
    if [[ "$SKIP_EXISTING" == "true" && "$STRIP_ATTESTATION" != "true" && "$DRY_RUN" != "true" ]]; then
      if is_up_to_date "$src" "$dest"; then
        log_skip "  目标已是最新，跳过"
        src_digest="$(compute_digest "$src" || true)"
        write_result "$result_file" "$src" "$dest" "skipped" "全部（--all）" "0" \
          "目标已存在相同镜像" "$src_digest" "$src_digest"
        continue
      fi
    fi

    start="$(date +%s)"
    if sync_one "$src" "$dest" "$platforms"; then
      status="success"
      log_ok "  同步成功"
    else
      status="failed"
      note="同步失败，详见上方日志"
      log_error "  同步失败"
      gh_error "镜像同步失败：${src} → ${dest}"
    fi
    end="$(date +%s)"
    elapsed=$((end - start))

    # 记录 digest 作为「这次同步的到底是哪一份镜像」的凭据。
    # 取不到就留空，只影响审计信息的完整度，不影响同步本身的成败。
    if [[ "$status" == "success" ]]; then
      src_digest="$(compute_digest "$src" || true)"
      dest_digest="$(compute_digest "$dest" || true)"
      if [[ -n "$src_digest" ]]; then
        log_info "  源 digest：${src_digest}"
      fi
      if [[ -n "$src_digest" && -n "$dest_digest" && "$src_digest" != "$dest_digest" ]]; then
        # 顶层 digest 不同不一定是问题（例如 registry 会重新包装 manifest），
        # 但值得记一笔，便于日后排查
        log_dim "  注：目标 digest 与源不同（${dest_digest}），通常由 registry 重新包装 manifest 导致"
      fi
    fi

    write_result "$result_file" "$src" "$dest" "$status" "$platforms" "$elapsed" "$note" \
      "$src_digest" "$dest_digest"
  done

  group_end
  return 0
}

# 调度所有镜像。
# 并发通过后台进程实现，槽位靠 jobs -pr 统计当前运行中的作业数来控制——
# 不用 wait -n（bash 4.3+）是为了兼容 macOS 自带的 bash 3.2。
dispatch_all() {
  local idx=0
  local total=${#SOURCE_IMAGES[@]}
  local raw_src reason

  for raw_src in "${SOURCE_IMAGES[@]}"; do
    idx=$((idx + 1))

    # 被筛掉的镜像不进子进程：既不值得为它起一个进程，也不需要网络请求。
    # 序号照常占位，所以结果表的顺序与输入完全一致。
    reason="${EXCLUDE_REASONS[$((idx - 1))]:-}"
    if [[ -n "$reason" ]]; then
      write_result "$(result_file_for "$idx" 1)" "$raw_src" "—" "excluded" "—" "0" "$reason" "" ""
      continue
    fi

    if [[ "$CONCURRENCY" -gt 1 ]]; then
      while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CONCURRENCY" ]]; do
        sleep 0.3
      done
      process_one "$idx" "$raw_src" "$total" &
    else
      process_one "$idx" "$raw_src" "$total"
    fi
  done

  if [[ "$CONCURRENCY" -gt 1 ]]; then
    # wait 返回最后一个作业的退出码；process_one 内部已把失败转成结果记录，
    # 这里不让它影响脚本自身
    wait || true
  fi
}

# ---------------------------------------------------------------------------
# 结果汇总与报告
# ---------------------------------------------------------------------------
load_results() {
  local f src dest status platform seconds note src_digest dest_digest
  local -a files=()

  # glob 排序后是字典序，因此文件名用零填充保证 1、2、…、10 的顺序正确
  for f in "${WORK_DIR}"/result-*; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done

  [[ ${#files[@]} -gt 0 ]] || return 0

  for f in "${files[@]}"; do
    src=""; dest=""; status=""; platform=""; seconds="0"; note=""
    src_digest=""; dest_digest=""
    IFS="$FIELD_SEP" read -r src dest status platform seconds note src_digest dest_digest < "$f" || true
    R_SRC+=("${src:-}")
    R_DEST+=("${dest:-}")
    R_STATUS+=("${status:-unknown}")
    R_PLATFORM+=("${platform:-}")
    R_SECONDS+=("${seconds:-0}")
    R_NOTE+=("${note:-}")
    R_SRC_DIGEST+=("${src_digest:-}")
    R_DEST_DIGEST+=("${dest_digest:-}")
  done
}

# 把本次同步的镜像与 digest 写成锁文件。
#
# 用途是「精确复现」：tag 是可以被上游覆盖的，digest 不会。
# 把 digest 锁定下来之后，无论上游怎么重新构建，都能拉回完全相同的那一份镜像。
# 写出的格式与 --file 读取的格式兼容，可直接回喂给脚本。
write_lockfile() {
  local path="$1" i
  local dir
  dir="$(dirname "$path")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || { log_warn "锁文件目录不存在且创建失败：${dir}"; return 0; }
  fi

  {
    echo "# 由 scripts/sync.sh 生成于 $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "#"
    echo "# 每行是「镜像@digest」。digest 指向不可变的内容，"
    echo "# 即便上游重新构建了同名 tag，这里锁定的仍是当时那一份。"
    echo "# 可直接用 --file 读取本文件实现精确复现："
    echo "#   ./scripts/sync.sh --file ${path} --dest <目标仓库>"
    echo ""
    for i in "${!R_SRC[@]}"; do
      # 跳过失败的条目：没有可靠的 digest 可锁
      if [[ "${R_STATUS[$i]}" == "failed" ]]; then
        echo "# [失败] ${R_SRC[$i]}"
        continue
      fi
      # 被筛掉的是有意不锁的，与「锁失败」区分开，避免误读为出了问题
      if [[ "${R_STATUS[$i]}" == "excluded" ]]; then
        echo "# [已排除] ${R_SRC[$i]}"
        continue
      fi
      if [[ -z "${R_SRC_DIGEST[$i]}" ]]; then
        echo "# [无 digest] ${R_SRC[$i]}"
        continue
      fi
      # 源引用本身可能已经带 digest，先剥掉再重新拼接，避免出现两个 @
      echo "${R_SRC[$i]%%@*}@${R_SRC_DIGEST[$i]}"
    done
  } > "$path"

  log_info "锁文件已写入：${path}"
  return 0
}

# ---------------------------------------------------------------------------
# 结果通知
#
# 同步是无人值守的：定时跑、或者随手点一下就走开。这带来一个很实际的盲区——
# 失败了没人知道，往往要等到集群拉不到镜像才发现，中间可能已经隔了好几天。
#
# 这里有一条硬约束：**通知失败绝不能影响同步结果**。webhook 挂了、网络不通、
# 平台改了格式，都只是附加能力的失败，不该让一次成功的同步变成红色运行。
# ---------------------------------------------------------------------------

# 按 webhook 地址识别服务商
detect_notify_type() {
  local url="$1"
  case "$url" in
    *oapi.dingtalk.com*)         printf 'dingtalk' ;;
    *feishu.cn*|*larksuite.com*) printf 'feishu' ;;
    *hooks.slack.com*)           printf 'slack' ;;
    *)                           printf 'generic' ;;
  esac
}

# 组装通知正文。各平台的差异只在最外层包装，正文共用同一份。
build_notify_text() {
  local total="$1" ok="$2" skipped="$3" fail="$4" excluded="${5:-0}"
  local i text=""

  text="## 镜像同步完成"$'\n\n'
  text+="共 **${total}** 个镜像 ｜ 成功 ${ok} ｜ 跳过 ${skipped} ｜ 失败 ${fail}"$'\n'

  if [[ "$excluded" -gt 0 ]]; then
    text+="另有 ${excluded} 个镜像被筛选条件排除，未参与本次同步。"$'\n'
  fi

  if [[ "$fail" -gt 0 ]]; then
    text+=$'\n'"### 失败详情"$'\n\n'
    for i in "${!R_SRC[@]}"; do
      if [[ "${R_STATUS[$i]}" == "failed" ]]; then
        text+="- ${R_SRC[$i]}"$'\n'
      fi
    done
  fi

  # 在 Actions 中运行时附上运行链接，便于收到通知后一键跳转排查
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    local base="${GITHUB_SERVER_URL:-https://github.com}"
    text+=$'\n'"[查看运行详情](${base}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID})"$'\n'
  fi

  printf '%s' "$text"
}

send_notification() {
  local total="$1" ok="$2" skipped="$3" fail="$4" excluded="${5:-0}"

  [[ -n "$NOTIFY_WEBHOOK" ]] || return 0

  if [[ "$NOTIFY_ON" == "failure" && "$fail" -eq 0 ]]; then
    log_info "本次没有失败，按 --notify-on failure 的配置跳过通知"
    return 0
  fi

  local type="$NOTIFY_TYPE"
  if [[ "$type" == "auto" ]]; then
    type="$(detect_notify_type "$NOTIFY_WEBHOOK")"
  fi

  local text payload
  text="$(build_notify_text "$total" "$ok" "$skipped" "$fail" "$excluded")"

  # 交给 jq 构造 JSON，转义由它负责，避免镜像名中的特殊字符破坏结构
  case "$type" in
    dingtalk)
      payload="$(jq -n --arg t "$text" '{msgtype:"markdown",markdown:{title:"镜像同步完成",text:$t}}')" ;;
    feishu)
      payload="$(jq -n --arg t "$text" '{msg_type:"text",content:{text:$t}}')" ;;
    slack|generic)
      payload="$(jq -n --arg t "$text" '{text:$t}')" ;;
    *)
      log_warn "未知的通知类型：${type}（可选：dingtalk / feishu / slack / generic）"
      return 0 ;;
  esac

  # webhook 地址本身就是凭证——知道地址就能往群里发消息，
  # 因此日志里只记录类型与结果，绝不输出 URL。
  # 注意不要写成 `... || printf '000'`：curl 的 -w '%{http_code}' 在连接失败时
  # 本身就会输出 000，再补一个会拼成 000000 这种看不懂的东西。
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --max-time 15 \
    -d "$payload" "$NOTIFY_WEBHOOK" 2>/dev/null)" || true
  http_code="${http_code:-000}"

  if [[ "$http_code" =~ ^2 ]]; then
    log_info "同步结果已推送到 ${type}"
  else
    log_warn "通知发送失败（HTTP ${http_code}），同步结果不受影响"
    gh_warning "同步结果通知发送失败：HTTP ${http_code}"
  fi

  return 0
}

emit_summary() {
  local ok=0 fail=0 skipped=0 excluded=0 i
  for i in "${!R_STATUS[@]}"; do
    case "${R_STATUS[$i]}" in
      success)  ok=$((ok + 1)) ;;
      skipped)  skipped=$((skipped + 1)) ;;
      excluded) excluded=$((excluded + 1)) ;;
      *)        fail=$((fail + 1)) ;;
    esac
  done

  # total 只统计真正尝试同步的镜像。把被筛掉的算进来会让「共 N 个镜像」
  # 包含根本没打算同步的那些，与实际发生的事情对不上。
  local total=$((ok + skipped + fail))

  local headline="同步完成：共 ${total} 个镜像，成功 ${ok} 个，跳过 ${skipped} 个，失败 ${fail} 个"
  if [[ "$excluded" -gt 0 ]]; then
    headline+="，另有 ${excluded} 个被筛选排除"
  fi
  log_info "$headline"

  # ---- 控制台表格 ----
  printf '\n' >&2
  printf '%s\n' "────────────────────────────────────────────────────────" >&2
  for i in "${!R_SRC[@]}"; do
    local mark="${C_GREEN}✓${C_RESET}"
    case "${R_STATUS[$i]}" in
      success)  mark="${C_GREEN}✓${C_RESET}" ;;
      skipped)  mark="${C_DIM}⤼${C_RESET}" ;;
      excluded) mark="${C_DIM}⊘${C_RESET}" ;;
      *)        mark="${C_RED}✗${C_RESET}" ;;
    esac
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
      echo "| 源镜像 | 目标镜像 | 结果 | 平台 | Digest | 耗时 |"
      echo "| --- | --- | :---: | --- | --- | --- |"
      for i in "${!R_SRC[@]}"; do
        local icon="✅"
        case "${R_STATUS[$i]}" in
          skipped)  icon="⤼ 已存在" ;;
          excluded) icon="⊘ 已排除" ;;
          success)  icon="✅" ;;
          *)        icon="❌" ;;
        esac
        echo "| \`${R_SRC[$i]}\` | \`${R_DEST[$i]}\` | ${icon} | ${R_PLATFORM[$i]:-—} | \`$(short_digest "${R_SRC_DIGEST[$i]:-}")\` | ${R_SECONDS[$i]}s |"
      done
      echo ""
      echo "**合计**：${total} 个镜像 · 成功 ${ok} · 跳过 ${skipped} · 失败 ${fail}"
      if [[ "$excluded" -gt 0 ]]; then
        echo ""
        echo "> 另有 ${excluded} 个镜像被 \`--filter\` / \`--exclude\` 排除，未参与本次同步。"
      fi
      echo ""
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "> ⚠️ 本次为 dry-run，未实际推送任何镜像。"
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  # ---- 报告文件 ----
  if [[ -n "$REPORT_DIR" ]]; then
    write_report "$total" "$ok" "$skipped" "$fail" "$excluded"
  fi

  # ---- 锁文件 ----
  if [[ -n "$WRITE_LOCK" ]]; then
    write_lockfile "$WRITE_LOCK"
  fi

  # ---- 结果通知 ----
  send_notification "$total" "$ok" "$skipped" "$fail" "$excluded"

  [[ "$fail" -eq 0 ]] || return 2
  return 0
}

write_report() {
  local total="$1" ok="$2" skipped="$3" fail="$4" excluded="$5" i
  mkdir -p "$REPORT_DIR"

  local result_line="共 ${total} 个镜像，成功 ${ok} 个，跳过 ${skipped} 个，失败 ${fail} 个"
  if [[ "$excluded" -gt 0 ]]; then
    result_line+="；另有 ${excluded} 个被筛选排除"
  fi

  local md="${REPORT_DIR}/${REPORT_NAME}.md"
  {
    echo "# 镜像同步报告"
    echo ""
    echo "- 生成时间：$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "- 目标地址：${DEST_EXACT:-${DEST_REGISTRIES[*]}}"
    echo "- 同步模式：$([[ "$STRIP_ATTESTATION" == "true" ]] && echo 'regctl（剔除 attestation）' || echo 'skopeo（保留全部平台）')"
    if [[ -n "$FILTER_REGEX" || -n "$EXCLUDE_REGEX" ]]; then
      echo "- 筛选条件：$([[ -n "$FILTER_REGEX" ]] && echo "--filter「${FILTER_REGEX}」")$([[ -n "$FILTER_REGEX" && -n "$EXCLUDE_REGEX" ]] && echo " ")$([[ -n "$EXCLUDE_REGEX" ]] && echo "--exclude「${EXCLUDE_REGEX}」")"
    fi
    echo "- 结果：${result_line}"
    echo ""
    echo "| 源镜像 | 目标镜像 | 结果 | 平台 | 源 Digest | 目标 Digest | 耗时 |"
    echo "| --- | --- | :---: | --- | --- | --- | --- |"
    for i in "${!R_SRC[@]}"; do
      local icon="✅"
      case "${R_STATUS[$i]}" in
        skipped)  icon="⤼" ;;
        excluded) icon="⊘" ;;
        success)  icon="✅" ;;
        *)        icon="❌" ;;
      esac
      echo "| \`${R_SRC[$i]}\` | \`${R_DEST[$i]}\` | ${icon} | ${R_PLATFORM[$i]:-—} | \`${R_SRC_DIGEST[$i]:-—}\` | \`${R_DEST_DIGEST[$i]:-—}\` | ${R_SECONDS[$i]}s |"
    done
  } > "$md"

  local json="${REPORT_DIR}/${REPORT_NAME}.json"
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '  "dest_registry": "%s",\n' "${DEST_EXACT:-${DEST_REGISTRIES[*]}}"
    printf '  "strip_attestation": %s,\n' "$STRIP_ATTESTATION"
    printf '  "total": %s,\n' "$total"
    printf '  "success": %s,\n' "$ok"
    printf '  "skipped": %s,\n' "$skipped"
    printf '  "failed": %s,\n' "$fail"
    printf '  "excluded": %s,\n' "$excluded"
    printf '  "filter": "%s",\n' "$FILTER_REGEX"
    printf '  "exclude": "%s",\n' "$EXCLUDE_REGEX"
    printf '  "images": [\n'
    for i in "${!R_SRC[@]}"; do
      printf '    {"source": "%s", "dest": "%s", "status": "%s", "platforms": "%s", "source_digest": "%s", "dest_digest": "%s", "seconds": %s}' \
        "${R_SRC[$i]}" "${R_DEST[$i]}" "${R_STATUS[$i]}" "${R_PLATFORM[$i]:-}" \
        "${R_SRC_DIGEST[$i]:-}" "${R_DEST_DIGEST[$i]:-}" "${R_SECONDS[$i]}"
      if [[ "$i" -lt $((${#R_SRC[@]} - 1)) ]]; then
        printf ','
      fi
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

  if [[ ${#DEST_REGISTRIES[@]} -eq 0 && -z "$DEST_EXACT" ]]; then
    log_error "缺少必填参数：--dest 或 --dest-exact"
    echo "" >&2
    usage >&2
    exit 1
  fi

  # 两者语义不同：--dest 是前缀（会被拼接），--dest-exact 是完整地址（不拼接）。
  # 混用时目标地址会变得含糊，宁可明确报错。
  if [[ -n "$DEST_EXACT" && ${#DEST_REGISTRIES[@]} -gt 0 ]]; then
    die "--dest-exact 与 --dest 不能同时使用：前者指定完整目标地址，后者是待拼接的前缀"
  fi

  validate_numeric "--concurrency" "$CONCURRENCY"
  validate_numeric "--timeout" "$TIMEOUT"
  validate_numeric "--retries" "$MAX_RETRIES"

  # 正则先校验再跑。写错的正则应该立刻被拒绝，而不是等收集完镜像才发现
  validate_regex "--filter" "$FILTER_REGEX"
  validate_regex "--exclude" "$EXCLUDE_REGEX"

  [[ "$CONCURRENCY" -ge 1 ]] || die "--concurrency 至少为 1"

  case "$NOTIFY_ON" in
    always|failure) ;;
    *) die "--notify-on 只能是 always 或 failure，当前为「${NOTIFY_ON}」" ;;
  esac

  case "$TLS_VERIFY" in
    true|false) ;;
    *) die "--tls-verify 只能是 true 或 false，当前为「${TLS_VERIFY}」" ;;
  esac

  # 规范化每个目标：去掉可能误带的 docker:// 前缀与结尾斜杠。
  # 用重建数组代替按下标原地修改——后者要写下标，容易触发静态检查告警，
  # 可读性也差一些。
  if [[ ${#DEST_REGISTRIES[@]} -gt 0 ]]; then
    local -a normalized=()
    local item
    for item in "${DEST_REGISTRIES[@]}"; do
      item="${item#docker://}"
      item="${item%/}"
      normalized+=("$item")
    done
    DEST_REGISTRIES=("${normalized[@]}")
  fi
  DEST_EXACT="${DEST_EXACT#docker://}"

  ensure_skopeo
  ensure_jq
  setup_timeout
  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    ensure_regctl
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "dry-run 模式：只打印命令，不会推送任何镜像"
  fi

  collect_images
  # 筛选放在 collect_images 之后、其余校验之前：
  # --dest-exact 要求「只有一个源镜像」，而筛选后的数量才是有意义的数量
  apply_filters

  # 这里看的是「筛选之后」的数量：--dest-exact 的约束来自多个镜像会撞到
  # 同一个目标地址，而筛掉之后只剩一个就不会撞
  local active_count
  active_count=$((${#SOURCE_IMAGES[@]} - FILTERED_OUT_COUNT))

  if [[ -n "$DEST_EXACT" && "$active_count" -gt 1 ]]; then
    die "--dest-exact 只能搭配单个源镜像使用（当前提供了 ${active_count} 个）；批量同步请改用 --dest 前缀模式"
  fi

  if [[ -n "$PLATFORMS" && "$STRIP_ATTESTATION" != "true" ]]; then
    log_warn "--platforms 仅在 --strip-attestation 模式下生效，本次将忽略（skopeo 用 --all 同步全部平台）"
  fi

  if [[ "$SKIP_EXISTING" == "true" && "$STRIP_ATTESTATION" == "true" ]]; then
    log_warn "--skip-existing 在 --strip-attestation 模式下不可用（索引会被重建，digest 必然不同），本次将忽略"
  fi

  # regctl 路径用的是 regclient 自己的重试策略，脚本层面的这两个参数到不了它那里。
  # 默认值被忽略不值得打扰，但使用者**显式传入**却没生效必须说出来——
  # 「参数被接受却不起作用」比直接报错更危险：它让人对系统行为产生错误认知。
  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    if [[ "$RETRIES_EXPLICIT" == "true" ]]; then
      log_warn "--retries ${MAX_RETRIES} 在 regctl 路径下不生效：regclient 有自己的重试策略（默认 5 次），本次将忽略"
    fi
    if [[ "$RETRY_DELAY_EXPLICIT" == "true" ]]; then
      log_warn "--retry-delay ${RETRY_DELAY} 仅对 skopeo 生效，regctl 路径将忽略（regclient 会遵循 registry 返回的 Retry-After）"
    fi
  fi

  # 报「实际要同步」的数量，而不是清单里的总数——筛选之后这两个值常常不同
  local total="$active_count"
  if [[ -n "$DEST_EXACT" ]]; then
    log_info "待同步镜像 ${total} 个 → ${DEST_EXACT}"
  else
    log_info "待同步镜像 ${total} 个 → ${DEST_REGISTRIES[*]}"
    if [[ ${#DEST_REGISTRIES[@]} -gt 1 ]]; then
      log_info "共 ${#DEST_REGISTRIES[@]} 个目标，每个镜像都会推送到全部目标"
    fi
  fi
  if [[ "$CONCURRENCY" -gt 1 ]]; then
    log_info "并发度：${CONCURRENCY}"
  fi

  WORK_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064  # 此处就是要在此刻展开 WORK_DIR 的值
  trap "rm -rf '${WORK_DIR}'" EXIT

  local start end
  start="$(date +%s)"
  dispatch_all
  end="$(date +%s)"
  log_info "总耗时：$((end - start)) 秒"

  load_results
  emit_summary
}

main "$@"
