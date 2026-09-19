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
# 与 DEST_REGISTRIES 按下标对齐：每个目标用哪套命名规则（flat / keep）。
#
# 压平规则的存在理由很具体——阿里云 ACR 个人版不支持多级仓库路径；而自建
# Harbor 支持多级路径，且保留原路径更符合直觉（一眼能看出上游是谁）。
# 「阿里云给国内集群 + Harbor 做内部归档」这个最典型的多目标场景同时需要两者，
# 因此规则必须挂在**每个目标**上，而不是全局一份。
declare -a DEST_MODES=()
# 当前镜像的全部目标地址，由 resolve_dest_refs 填写（同步与审计共用）
declare -a DEST_REFS=()

# split_image_ref 的传出变量。三个值用命令替换传不回来（那是子 shell），
# 而调用方通常只关心其中一两个
REF_REPO=""
REF_TAG=""
REF_DIGEST=""
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
# 同步后逐平台校验目标与源的内容一致性。默认关闭：
# 校验要为每个镜像多做两次 inspect，大清单下开销明显；
# 且「同步成功」对多数使用者已经够用，需要精确性的场景再打开。
VERIFY="false"
# 清单审计（--audit）：只读地检查清单里每个镜像在目标仓库中的状态，不推送任何东西。
# 它回答的问题在过去只有真的跑一次同步才能回答——而同步是会真推送的。
# 「检查」与「搬运」本就该分开：只想看一眼仓库状态时，不该被迫先搬一趟。
AUDIT="false"
# 上游版本检查（--check-updates）：报告上游有、清单却未收录的 tag。
# 同样是只读的——「检查」与「搬运」分开，这里连目标仓库都不需要。
CHECK_UPDATES="false"
# 每个源仓库最多展示几条未收录的 tag（取版本序最大的若干条）。
# 上游仓库动辄几百个 tag，全列出来等于没有输出。
UPDATES_LIMIT="5"
# 锁文件时效性校验（--audit-lock <文件>）：检查锁文件里每个「镜像@digest」
# 的上游是否还是锁定的那份。--write-lock 只完成了「能复现」这半件事——
# 上游完全可能重新构建并覆盖同名 tag，此时锁文件没有任何变化（它记录的
# 是历史事实），但下一次增量同步会把新内容静默搬过去。缺的环节就是
# 定期问一句「上游的 tag 还是我锁的那份吗」。
AUDIT_LOCK_FILE=""
NOTIFY_WEBHOOK=""
NOTIFY_TYPE="auto"
NOTIFY_ON="always"
# 同一个镜像连续失败多少次才通知。默认 1：每次失败都通知（与历史行为一致）。
# 调大是为了对抗通知疲劳——上游抖动占了失败原因的一大部分，每次都响的话
# 群里的通知很快就没有人看了，真正需要关注的问题反而被淹没。
NOTIFY_AFTER_FAILURES="1"
# 与 --retries 同理：默认值在检查模式下不适用不值得打扰，显式传入必须说出来
NOTIFY_AFTER_FAILURES_EXPLICIT="false"
# 计算连续失败次数时要下载的历史报告 Artifact 名称（阈值 > 1 时才用到）
HISTORY_ARTIFACT="sync-report-aliyuncs"
WRITE_LOCK=""
declare -a SOURCE_IMAGES=()
declare -a SOURCE_FILES=()

# 源仓库凭证。
#
# 源与目标通常是两套**独立**的凭证：目标是自己的仓库，源是别人的系统。
# 把目标仓库的凭证发往源仓库，等于把「往我仓库推送」的权限交给一个你并不信任的
# 第三方，因此这里刻意不提供「复用一个 --username」的捷径。
#
# 凭证只写进临时认证文件，绝不进命令行——命令行参数对同机其他进程可见（ps），
# 而 --dry-run 还会把命令原样打印出来。
SRC_USERNAME=""
SRC_PASSWORD=""
SRC_REGISTRY=""
# 按源仓库映射凭证的文件路径（--src-credentials），每行「host 用户名 密码」。
# 与单一凭证的关系是互斥而非叠加：混用时的语义只有猜，宁可报错。
SRC_CREDENTIALS_FILE=""
# 由 setup_src_auth 生成的临时认证文件（600 权限），脚本退出时删除
SRC_AUTHFILE=""
# 解析出的凭证条目（TSV，内含明文凭证），同样退出即删。
# 放在独立变量而不是 WORK_DIR 下：setup_src_auth 的调用点早于 WORK_DIR 的创建
SRC_CRED_ENTRIES=""
# 环境变量 SYNC_SRC_CREDENTIALS（文件内容）落盘产生的临时文件路径。
# cleanup 只删这个，绝不动使用者通过 --src-credentials 指定的自有文件
SRC_CREDENTIALS_TMPFILE=""
# 多目标中转：prepare_oci_staging 的传出变量（不能用命令替换传——
# 那是子 shell，赋值传不回父进程，set -u 下读会炸）
OCI_STAGING_DIR=""
PULL_ELAPSED=0

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

# 重跑指引：同步失败之后，告诉使用者「重跑什么、怎么重跑」。
# 由 collect_rerun_items 一次算出，Step Summary / 报告 md / 报告 json 三处
# 共用同一份结果——三处各自再算一遍的话，口径漂移会让它们互相矛盾。
declare -a RERUN_IMAGES=()
RERUN_FILTER=""
RERUN_NOT_RERUNNABLE=0

# 审计结果数组，由 load_audit_results 从 WORK_DIR 读入。
# 刻意与同步结果分开：审计的状态值域（最新 / 落后 / 缺失 / 无法判定）
# 与同步（成功 / 跳过 / 失败）不是一回事，混在一套数组里会让报告、
# 通知与锁文件都变得含糊——「缺失」被通知渲染成「失败」就是误导。
declare -a A_SRC=()
declare -a A_DEST=()
declare -a A_STATE=()
declare -a A_NOTE=()

# 锁文件校验的结果数组：先由 parse_lockfile 填入解析结果（标注行与未锁定行
# 直接带上状态），校验完成的条目由 load_lock_results 用结果文件覆盖。
# 与审计的 A_* 分开：状态值域不同（一致/漂移/无法判定 vs 最新/落后/缺失），
# 混用会让报告与通知的语义变含糊。
declare -a L_REF=()
declare -a L_STATE=()
declare -a L_NOTE=()

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

目标地址（必填其一；--check-updates 只查上游，不需要填）：
  -d, --dest <前缀>        目标仓库前缀。最终目标为「前缀 + 源镜像路径（压平）」，
                           例如 registry.cn-shenzhen.aliyuncs.com/nicholyx
                           **可重复指定以同时推送到多个目标**
      --dest-keep-path <前缀>
                           同上，但**保留源镜像的路径结构**，不做压平。
                           用于支持多级路径的 registry（如自建 Harbor）：
                           registry.k8s.io/pause:3.9 会落到
                           <前缀>/registry.k8s.io/pause:3.9
                           源 registry 带端口时（localhost:5000/foo），端口
                           那一段仍会压成下划线——仓库路径不允许冒号
                           可与 --dest 混用，让每个目标各用合适的规则——
                           阿里云个人版不支持多级路径（用 --dest），
                           Harbor 支持（用 --dest-keep-path）
      --dest-exact <地址>  精确指定完整目标地址，不再自动拼接源镜像名。
                           只能搭配单个源镜像、且不能与 --dest /
                           --dest-keep-path 混用，
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
      --verify             同步后逐平台比对源与目标的子 manifest digest，
                           不一致时该镜像判定为失败。要为每个镜像多做两次
                           inspect，大清单下会明显变慢，默认关闭。
                           Windows 平台被排除在比对之外（其 manifest 在传输中
                           必然重新生成）；拿不到 digest 时只告警不判失败

      --audit              只读检查清单里每个镜像在目标仓库中的状态，**不推送
                           任何东西**。回答「我的仓库跟上清单了吗」，适合在
                           动手同步之前先看一眼，或接进 CI 做定期体检。
                           四种状态：最新 / 落后 / 缺失 / 无法判定。
                           与 --strip-attestation 互斥：后者会重建索引，
                           目标的平台摘要必然与源不同，审计只会给出一排
                           假的「落后」；与 --dry-run / --write-lock
                           同用时这些参数不生效（会告警）
                           --notify-webhook 在检查模式下同样有效，只是
                           --notify-on failure 的含义变成「有需要关注的项」
                           与 --check-updates 互斥（检查对象不同，请分开跑）

      --check-updates      只读检查上游有哪些 tag 不在清单里，回答「上游是不是
                           该升级了」。只报告，**不修改清单**——升到哪个版本
                           涉及兼容性判断，是人的决定。
                           不对 tag 做语义化比较，也不过滤预发布：上游命名未必
                           规整（1.27-alpine / v1.32.0-rc.1），语义化比较会给出
                           **错误**结论；这里只用版本序粗排并原样展示
                           不需要目标地址；退出码 2 表示「有仓库存在未收录的
                           tag，或有仓库没查成」
      --updates-limit <N>  每个仓库最多列出几条未收录的 tag，默认 5。
                           无论列出几条，总数都会给出

      --audit-lock <文件>  只读校验 --write-lock 生成的锁文件：锁文件里每个
                           「镜像@digest」的上游，现在还是不是锁定的那份。
                           --write-lock 只完成了「能复现」这半件事——上游重新
                           构建并覆盖同名 tag 时，锁文件不会有任何变化，而
                           下一次增量同步会把新内容静默搬过去。
                           三种状态：一致 / 漂移 / 无法判定；上游 tag 已删除
                           算漂移（明确发生的变更，不是「查不到」）。
                           锁文件中不带 digest 的行与「# [失败]」等标注行
                           会出现在报告里并标注类别，但不参与成败判定。
                           不需要目标地址；退出码 2 表示「有漂移或没查成」

源仓库凭证（同步私有镜像时使用）：
      --src-username <名>  源仓库的用户名，需与 --src-password 同时提供
      --src-password <密>  源仓库的密码或 Token
      --src-registry <地址>
                           凭证对应的源仓库地址。不指定时会自动从源镜像推导，
                           并把结果列在日志里；如果清单里混有公开仓库，
                           建议显式指定，避免凭证被发往并不需要的仓库

      --src-credentials <文件>
                           按源仓库映射凭证：每行「host 用户名 密码或Token」，
                           # 开头为注释。清单里混有多个私有源（公司 Harbor +
                           私有 GHCR）时使用；未匹配到凭证的 host 走匿名。
                           与 --src-username 互斥，混用直接报错。
                           文件权限建议 600；格式错误的行会指明行号

      以上各项也可用环境变量传入：SYNC_SRC_USERNAME / SYNC_SRC_PASSWORD /
      SYNC_SRC_REGISTRY / SYNC_SRC_CREDENTIALS（最后一个的值是**文件内容**
      而非路径，方便 CI 里从 Secret 直接注入）。CI 等自动化场景**应当**用
      环境变量——命令行参数对同机其他进程可见，也容易被调用方的日志语句
      原样打印出去。无论走哪条路，凭证都不会出现在本脚本的日志里
      （写入临时的 600 权限文件）

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
      --dry-run            输出同步计划与将要执行的命令，不实际推送。
                           计划不预测跳过结果，也不虚构未显式指定的平台
      --report-dir <目录>  把报告写入该目录（同时生成 .md 与 .json）。
                           同步与三种检查（--audit / --check-updates /
                           --audit-lock）均支持，文件名可区分
      --write-lock <路径>  把镜像与 digest 写成锁文件，可用于精确复现
      --regctl-version <v> 指定 regctl 版本，默认 v0.11.6

      --notify-webhook <url>  同步结束后把结果推送到这个 webhook。
                              不指定则完全不发送任何通知。
      --notify-type <类型>    钉钉 dingtalk / 飞书 feishu / Slack slack /
                              通用 generic，默认 auto（按 URL 自动识别）
      --notify-on <时机>      always（默认，总是通知）或 failure（仅在有事时通知）。
                           在 --audit / --check-updates 下，failure 表示
                           「有落后 / 缺失 / 无法判定，或有仓库没查成」
      --notify-after-failures <N>
                              同一个镜像连续失败多少次才通知，默认 1（每次失败都通知）。
                              调大可对抗通知疲劳：上游抖动的失败重跑就好，每次都响
                              的通知很快没人看了。需要能下载历史报告（gh CLI），
                              拿不到历史时按「连续失败 1 次」处理。
                              **仅同步模式适用**：检查没有「连续失败」的概念，
                              在 --audit / --check-updates 下显式传入会告警
      --history-artifact <名> 历史报告的 Artifact 名称，默认 sync-report-aliyuncs。
                              仅在 --notify-after-failures 大于 1 时使用

  -h, --help               显示本帮助

退出码：
  0  全部镜像同步成功（含被跳过的）
  1  参数或环境错误（缺少依赖、参数非法）
  2  至少一个镜像同步失败（其余镜像仍会继续尝试）

--audit 模式下的退出码：
  0  全部最新，且全部可判定
  1  参数或环境错误
  2  审计未得出「全部最新」——存在落后、缺失，或有无法判定的项。
     具体是哪一类看报告正文。把「没查完」也归入 2，是为了让 CI 门禁
     不会在检查本身没做完的情况下报绿

--audit-lock 模式下的退出码：
  0  全部与锁定的一致（未锁定 digest 的条目不参与判定）
  1  参数或环境错误
  2  有漂移（含上游已删除的 tag），或有无法判定的项

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

  # 只看状态不动手：清单里的镜像，目标仓库现在缺哪些、哪些落后了
  ./scripts/sync.sh --file images.lock.txt -d registry.cn-shenzhen.aliyuncs.com/nicholyx --audit

  # 校验锁文件的时效性：上游的 tag 还是我锁定的那份 digest 吗
  ./scripts/sync.sh --audit-lock sync-2026-09.lock

  # 一次推两个目标，各用各的命名规则：阿里云压平，自建 Harbor 保留路径
  ./scripts/sync.sh --file images.lock.txt \
      -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
      --dest-keep-path harbor.example.com/mirror
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
        DEST_REGISTRIES+=("$2"); DEST_MODES+=("flat"); shift 2 ;;
      --dest-keep-path)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        DEST_REGISTRIES+=("$2"); DEST_MODES+=("keep"); shift 2 ;;
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
      --verify)
        VERIFY="true"; shift ;;
      --audit)
        AUDIT="true"; shift ;;
      --check-updates)
        CHECK_UPDATES="true"; shift ;;
      --updates-limit)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        UPDATES_LIMIT="$2"; shift 2 ;;
      --audit-lock)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        AUDIT_LOCK_FILE="$2"; shift 2 ;;
      --tls-verify)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        TLS_VERIFY="$2"; shift 2 ;;
      --src-username)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SRC_USERNAME="$2"; shift 2 ;;
      --src-password)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SRC_PASSWORD="$2"; shift 2 ;;
      --src-registry)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SRC_REGISTRY="${2#docker://}"; SRC_REGISTRY="${SRC_REGISTRY%/}"
        shift 2 ;;
      --src-credentials)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        SRC_CREDENTIALS_FILE="$2"; shift 2 ;;
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
      --notify-after-failures)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        NOTIFY_AFTER_FAILURES="$2"; NOTIFY_AFTER_FAILURES_EXPLICIT="true"; shift 2 ;;
      --history-artifact)
        [[ -n "${2:-}" ]] || die "$1 需要一个参数"
        HISTORY_ARTIFACT="$2"; shift 2 ;;
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
# 拆解镜像引用为「仓库」「tag」「digest」，写入上面的三个全局变量。
#
# 规则：**只有最后一个 / 之后的冒号才是 tag 分隔符**——registry 地址里的冒号
# （localhost:5000/foo）不是。digest 一律先剥离。
split_image_ref() {
  local ref="$1"

  REF_REPO=""
  REF_TAG=""
  REF_DIGEST=""

  if [[ "$ref" == *"@"* ]]; then
    REF_DIGEST="${ref#*@}"
    ref="${ref%%@*}"
  fi

  local last_segment="${ref##*/}"
  if [[ "$last_segment" == *:* ]]; then
    REF_TAG="${last_segment#*:}"
    REF_REPO="${ref%:*}"
  else
    REF_REPO="$ref"
  fi
}

# 第二参数是命名规则：
#   flat（默认）压平——/ 和 : 都换成 _，适配不支持多级仓库路径的 registry
#   keep        保留——原样保留源镜像的路径结构，供支持多级路径的 registry 使用
dest_repo_for() {
  local name="" tag="" short=""
  local mode="${2:-flat}"

  split_image_ref "$1"
  name="$REF_REPO"
  if [[ -n "$REF_TAG" ]]; then
    tag=":${REF_TAG}"
  fi

  # 冒号一律替换掉：仓库路径里不允许出现冒号（registry 的语法约束），
  # 而它只可能来自带端口的源 registry（localhost:5000/foo）。
  # 这是两种模式的共同前提，不是压平规则的一部分。
  name="${name//:/_}"

  # 压平：把 / 也换成 _（适配不支持多级仓库路径的 registry）。
  # keep 模式保留 /，因此层级结构还在，只是端口那一段变成了下划线。
  if [[ "$mode" != "keep" ]]; then
    name="${name//\//_}"
  fi

  # 源只给了 digest 没给 tag（形如 nginx@sha256:…）时，
  # 用 digest 前缀生成一个可读的 tag，避免目标没有 tag
  if [[ -z "$tag" && -n "$REF_DIGEST" ]]; then
    short="${REF_DIGEST#sha256:}"
    tag=":${short:0:12}"
  fi

  printf '%s%s' "$name" "$tag"
}

# 解析某个源镜像对应的全部目标地址，写入全局数组 DEST_REFS。
#
# 用全局变量传出而不是命令替换：命令替换是子 shell，数组赋值传不回父进程
# （与 OCI_STAGING_DIR 同一类问题，项目里已经踩过一次）。
resolve_dest_refs() {
  local src="$1"
  local i d mode

  DEST_REFS=()

  if [[ -n "$DEST_EXACT" ]]; then
    DEST_REFS=("$DEST_EXACT")
    return 0
  fi

  # 逐目标取各自的命名规则。两个数组按下标对齐，由 parse_args 同步追加保证。
  for i in "${!DEST_REGISTRIES[@]}"; do
    d="${DEST_REGISTRIES[$i]}"
    mode="${DEST_MODES[$i]:-flat}"
    DEST_REFS+=("${d}/$(dest_repo_for "$src" "$mode")")
  done
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
  # 私有源的探测同样需要凭证。漏掉这里会重演「跳过判定静默失效」那类问题：
  # inspect 拿到 401，跳过判定一律判为「需要同步」，增量能力形同虚设。
  if [[ -n "$SRC_AUTHFILE" ]]; then
    cmd+=(--authfile "$SRC_AUTHFILE")
  fi
  cmd+=("docker://${ref}")
  "${cmd[@]}"
}

# 从镜像引用中提取 registry 主机名。
#
# 规则与 OCI 的引用解析一致：只有第一段看起来像主机名时才当作 registry，
# 否则视为 Docker Hub。这里不能简单地取「第一个 / 之前的部分」——
# nginx:1.27 里的冒号是 tag 分隔符而不是端口，那样会把它误判成主机名。
registry_host_of() {
  local ref="$1" first
  ref="${ref#docker://}"
  ref="${ref%%@*}"

  # 不含 / 的引用必然来自 Docker Hub（如 nginx:1.27、library/nginx:1.27）
  if [[ "$ref" != */* ]]; then
    printf 'docker.io'
    return 0
  fi

  first="${ref%%/*}"
  if [[ "$first" == *.* || "$first" == *:* || "$first" == "localhost" ]]; then
    printf '%s' "$first"
  else
    printf 'docker.io'
  fi
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
# 三层降级：timeout → gtimeout → perl alarm。前两层都没有是 macOS 的常态
# （系统默认不带 coreutils），此时用系统自带的 perl 兜底——alarm 的 SIGALRM
# 会跨 exec 保留、默认动作终止进程，恰好就是 timeout 在这里的全部用法。
# 最后一层都没有时才降级为不限制超时，并给出一次提示——这比直接报错更友好，
# 毕竟超时只是保护措施，不是功能本身。但在 perl 也不存在的系统上，
# 使用者应当明确知道自己跑在无保护状态，而不是看到一句可以忽略的警告。
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
  elif command -v perl >/dev/null 2>&1; then
    TIMEOUT_CMD=(perl -e 'alarm shift; exec @ARGV' "$TIMEOUT")
  else
    TIMEOUT_CMD=()
    log_warn "找不到 timeout / gtimeout / perl，单镜像超时保护已禁用（macOS 可 brew install coreutils）"
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

  # 只传给源：目标是自己的仓库，凭证由 docker login 或 CI 的 Secrets 提供
  if [[ -n "$SRC_AUTHFILE" ]]; then
    cmd+=(--src-authfile "$SRC_AUTHFILE")
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

# 推送到单个目标。多目标中转模式下走本地 OCI 目录，否则按常规路径。
# 中转推送不需要 --src-authfile（本地文件无鉴权），但 --all 不能省——
# 它同样要保留多架构索引。
#
# 常规分支的末尾**不能写 return 0**：sync_one 的退出码是「同步是否成功」
# 的唯一依据，覆盖它会让失败的同步被记成成功（本 PR 的 CI 当场抓到过）。
sync_to_dest() {
  local src="$1" dest="$2" platforms="$3" oci_dir="$4"

  if [[ -z "$oci_dir" ]]; then
    sync_one "$src" "$dest" "$platforms"
    return $?
  fi

  local -a cmd=(skopeo copy --all)
  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--dest-tls-verify=false)
  fi
  cmd+=("oci:${oci_dir}:sync" "docker://${dest}")
  run_with_timeout "${cmd[@]}"
}

# 完整 inspect（非 --raw）。同样统一 TLS 与凭证设置——
# 大小估算用它，漏掉凭证会重演「跳过判定静默失效」。
skopeo_inspect() {
  local ref="$1"
  local -a cmd=(skopeo inspect)
  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--tls-verify=false)
  fi
  if [[ -n "$SRC_AUTHFILE" ]]; then
    cmd+=(--authfile "$SRC_AUTHFILE")
  fi
  cmd+=("docker://${ref}")
  "${cmd[@]}"
}

# 估算镜像的未压缩层数据总量（字节）。拿不到就返回空，调用方跳过空间检查——
# 检查是防止磁盘写满的预检，不该因为估不出大小就拒绝同步。
# LayersData 的字段大小写在 skopeo 版本间有过变化，候选都试一遍；
# 全都匹配不上时返回 0，同样跳过检查而不是拒绝同步。
estimate_image_bytes() {
  skopeo_inspect "$1" 2>/dev/null \
    | jq -r '[(.LayersData // .layersData // [])[] | (.size // .Size // 0)] | add // 0' 2>/dev/null \
    || true
}

# 多目标中转的准备阶段：把源镜像拉到本地 OCI 目录，一次拉取供全部目标使用。
#
# 成功时把目录路径写入全局 OCI_STAGING_DIR，拉取耗时写入全局 PULL_ELAPSED，
# 返回 0；失败时（磁盘不足 / 拉取失败）返回非零，调用方退化为逐目标拉推。
# **不能用命令替换「stdout 传值」**：那是子 shell，里面的赋值传不回父进程，
# set -u 下父进程读 PULL_ELAPSED 会直接 unbound variable。
# 失败路径全部走告警而不是 die——优化失败不该改变同步的结果语义。
prepare_oci_staging() {
  local src="$1"
  local tmpdir="${TMPDIR:-/tmp}"
  tmpdir="${tmpdir%/}"

  # 磁盘空间预检：估算层数据量 + 20% 余量 + 100MB 底数。
  # 并发模式下每个镜像都有各自的中转目录，需求按并发度放大——
  # 否则 6 个大镜像并发时预检全部通过，实际把磁盘一起写满。
  # runner 通常有 14GB 可用，但 ML 框架这类镜像能到 10GB 级，写满磁盘
  # 会让后续所有目标一起失败——那正是这个优化最不该发生的地方。
  local est
  est="$(estimate_image_bytes "$src")"
  if [[ -n "$est" && "$est" -gt 0 ]]; then
    local need=$(( est * 12 * CONCURRENCY / 10 + 104857600 ))
    local avail
    avail="$(df -Pk "$tmpdir" | awk 'NR==2 {print $4 * 1024}')"
    if [[ -n "$avail" && "$avail" -lt "$need" ]]; then
      log_warn "临时空间不足（并发 ${CONCURRENCY} 路需约 $((need / 1048576))MB，可用 $((avail / 1048576))MB），退化为逐目标拉取"
      return 1
    fi
  fi

  local oci_dir
  oci_dir="$(mktemp -d "${tmpdir}/sync-oci.XXXXXX")" || {
    log_warn "无法创建中转目录，退化为逐目标拉取"
    return 1
  }

  local -a cmd=(skopeo copy --all)
  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--src-tls-verify=false)
  fi
  if [[ -n "$SRC_AUTHFILE" ]]; then
    cmd+=(--src-authfile "$SRC_AUTHFILE")
  fi
  cmd+=("docker://${src}" "oci:${oci_dir}:sync")

  local start end
  start="$(date +%s)"
  if ! run_with_timeout "${cmd[@]}"; then
    rm -rf "$oci_dir"
    log_warn "源镜像拉取到本地中转失败，退化为逐目标拉取（原因见上方日志）"
    return 1
  fi
  end="$(date +%s)"
  PULL_ELAPSED=$((end - start))
  OCI_STAGING_DIR="$oci_dir"
  return 0
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

# 同步后的完整性校验：逐平台比对源与目标的子 manifest digest。
#
# 为什么需要它：`skopeo copy` 返回 0 只说明命令跑完了，不代表每个平台都完整
# 推上去了——传输中断、目标 registry 重新包装、限流导致的静默截断，都可能
# 只影响部分平台。而报告里记录的 digest 从来只是记录、没有比对。
#
# 退出码：
#   0  一致（或源与目标都是单平台且内容一致）
#   1  存在差异（差异详情已写到 stdout，调用方负责展示）
#   2  无法校验（拿不到 digest）——**不判定失败**，理由与 digest 记录一致：
#      网络抖动是常态，校验本身不该比同步更容易失败
#
# 与增量跳过共用 platform_digest_map，因此天然继承两个关键取舍：
# 按子 manifest 的 digest 比对（顶层 digest 会因 registry 重新包装而变化）、
# 排除 Windows 平台（其 manifest 在传输中必然重新生成）。
verify_integrity() {
  local src="$1" dest="$2"
  local src_map dest_map src_norm dest_norm

  src_map="$(platform_digest_map "$src" || true)"

  # 单平台镜像没有 manifests 列表，退化为比对规范化后的 manifest JSON，
  # 与 is_up_to_date 的单平台路径保持同一逻辑
  if [[ -z "$src_map" ]]; then
    src_norm="$(skopeo_inspect_raw "$src" 2>/dev/null | jq -S -c . 2>/dev/null || true)"
    if [[ -z "$src_norm" ]]; then
      return 2
    fi
    dest_norm="$(skopeo_inspect_raw "$dest" 2>/dev/null | jq -S -c . 2>/dev/null || true)"
    if [[ -z "$dest_norm" ]]; then
      return 2
    fi
    if [[ "$src_norm" == "$dest_norm" ]]; then
      return 0
    fi
    printf '单平台 manifest 内容不一致\n'
    return 1
  fi

  dest_map="$(platform_digest_map "$dest" || true)"
  if [[ -z "$dest_map" ]]; then
    return 2
  fi

  # 源有而目标没有 → 平台缺失；反之 → 目标多出意料之外的平台
  local missing extra
  missing="$(comm -23 <(printf '%s\n' "$src_map") <(printf '%s\n' "$dest_map"))"
  extra="$(comm -13 <(printf '%s\n' "$src_map") <(printf '%s\n' "$dest_map"))"

  if [[ -z "$missing" && -z "$extra" ]]; then
    return 0
  fi

  local p problems=""
  if [[ -n "$missing" ]]; then
    problems+="目标缺失的平台："
    while IFS= read -r p; do
      [[ -n "$p" ]] && problems+=$'\n'"  ${p%% *}（digest ${p#* }）"
    done <<<"$missing"
  fi
  if [[ -n "$extra" ]]; then
    problems+="${problems:+$'\n'}目标多出的平台："
    while IFS= read -r p; do
      [[ -n "$p" ]] && problems+=$'\n'"  ${p%% *}（digest ${p#* }）"
    done <<<"$extra"
  fi
  printf '%s' "$problems"
  return 1
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
    # 审计模式下说「实际同步 N 个」会让人以为发生了推送——措辞跟着模式走
    local action="同步"
    if [[ "$AUDIT" == "true" ]]; then
      action="审计"
    fi
    log_info "筛选：${total} 个镜像中排除 ${excluded} 个，实际${action} $((total - excluded)) 个"
  fi

  # 全被筛掉时明确失败。静默地「什么都不做然后报成功」是最糟的结果——
  # 使用者会以为同步完成了，直到集群拉不到镜像才发现。
  if [[ "$excluded" -eq "$total" ]]; then
    die "全部 ${total} 个镜像都被筛掉了，没有剩余可处理的镜像。请放宽 --filter / --exclude"
  fi

  FILTERED_OUT_COUNT="$excluded"
}

# ---------------------------------------------------------------------------
# 源仓库凭证
#
# 两个刻意的设计：
#
# 1. **凭证不经过命令行。** 命令行参数对同机其他进程可见（ps aux），
#    而 --dry-run 还会把命令原样打印出来。所以凭证只写进临时文件，
#    再用 --src-authfile 交给 skopeo。
# 2. **不与目标仓库复用凭证。** 源和目标是两套独立的东西：目标是你自己的仓库，
#    源是别人的系统。把目标仓库的凭证发往源仓库，等于把「往我仓库推送」的权限
#    交给一个你并不信任的第三方，哪怕实践中两者偶尔相同也不该默认如此。
# ---------------------------------------------------------------------------
# 解析凭证映射文件，输出 TSV（host<FS>user<FS>pass）到 stdout。
#
# 两个安全细节：
#   - 格式错误的行**只报行号与字段数，绝不回显行内容**——行里有密码，
#     而错误信息会进日志
#   - host 会做与 normalize_ref 一致的前缀清理，避免「同一个仓库两种写法
#     匹配不上」这种最难排查的静默失败
parse_src_credentials() {
  local file="$1"
  local lineno=0 line host user pass rest

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # 去首尾空白（内联三段式，避免为它引入子进程）
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "$line" == \#* ]] && continue

    # 按空白切分。字段数不对就拒绝——静默跳过是最糟的：凭证没配上的仓库
    # 会以 401 失败，而使用者根本不知道是文件写错还是权限不够。
    host="${line%%[[:space:]]*}"
    rest="${line#"$host"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    user="${rest%%[[:space:]]*}"
    rest="${rest#"$user"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    pass="${rest%%[[:space:]]*}"
    rest="${rest#"$pass"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    if [[ -z "$user" || -z "$pass" || -n "$rest" ]]; then
      die "凭证文件 ${file} 第 ${lineno} 行格式错误（应为 3 个字段：host 用户名 密码，空白分隔）。已停止同步——错误的凭证映射比没有更危险"
    fi

    host="${host#docker://}"
    host="${host%/}"
    printf '%s%s%s%s%s\n' "$host" "$FIELD_SEP" "$user" "$FIELD_SEP" "$pass"
  done < "$file"
}

# 把凭证条目（TSV：host<FS>user<FS>pass）写成 skopeo 用的 authfile。
write_src_authfile() {
  local entries_file="$1"

  # TMPDIR 常以 / 结尾，拼路径前先去掉，否则会生成 // 这种双斜杠路径
  local tmpdir="${TMPDIR:-/tmp}"
  tmpdir="${tmpdir%/}"

  SRC_AUTHFILE="$(mktemp "${tmpdir}/sync-src-auth.XXXXXX")" || die "无法创建临时认证文件"
  chmod 600 "$SRC_AUTHFILE"

  # auth.json 里的凭据是 base64 编码的「用户名:密码」，且不能带换行。
  # 交给 jq 拼 JSON：手工拼接的话，用户名里的引号或反斜杠会直接破坏文件结构
  if ! jq -R . "$entries_file" | jq -rs 'map(split("\u001f")) | map({(.[0]): {auth: ((.[1] + ":" + .[2]) | @base64)}}) | {auths: (add // {})}' \
      > "$SRC_AUTHFILE"; then
    die "生成源仓库认证文件失败"
  fi

  # 只报「配了哪些仓库」。用户名不打印，密码更不打印。
  local count
  count="$(wc -l < "$entries_file" | tr -d ' ')"
  log_info "源仓库凭证已装载（${count} 个仓库）：$(cut -d"$FIELD_SEP" -f1 "$entries_file" | sort -u | paste -sd' ' -)"
}

setup_src_auth() {
  [[ -n "$SRC_USERNAME" || -n "$SRC_PASSWORD" || -n "$SRC_REGISTRY" \
    || -n "$SRC_CREDENTIALS_FILE" ]] || return 0

  # 互斥而非叠加：混用时「文件里有 private.io、命令行又给了另一个用户名」
  # 的语义只能靠猜。宁可拒绝，让使用者把意图写清楚。
  if [[ -n "$SRC_CREDENTIALS_FILE" && ( -n "$SRC_USERNAME" || -n "$SRC_PASSWORD" || -n "$SRC_REGISTRY" ) ]]; then
    die "--src-credentials 与 --src-username / --src-password / --src-registry 互斥：前者按仓库映射多套凭证，后者是单套，混用的语义只能靠猜"
  fi

  # 凭证条目用独立的临时文件：本函数的调用点早于 WORK_DIR 的创建。
  # 文件内含明文凭证，cleanup() 负责删除。
  local tmpdir="${TMPDIR:-/tmp}"
  tmpdir="${tmpdir%/}"
  local entries
  entries="$(mktemp "${tmpdir}/sync-src-cred.XXXXXX")" || die "无法创建临时凭证文件"
  chmod 600 "$entries"
  SRC_CRED_ENTRIES="$entries"

  if [[ -n "$SRC_CREDENTIALS_FILE" ]]; then
    [[ -f "$SRC_CREDENTIALS_FILE" ]] || die "凭证文件不存在：${SRC_CREDENTIALS_FILE}"

    # 权限过宽只告警不拒绝：CI 里它是 Secret 注入的临时文件（600），
    # 本地则可能是使用者有意放宽的；真正的硬约束由解析和 authfile 的
    # 600 权限兜住。
    # 注意不能看 find 的退出码——它只表示「遍历成功」，与是否匹配无关
    # （这点和 grep 不同），必须看输出是否非空。
    if [[ -n "$(find "$SRC_CREDENTIALS_FILE" -perm -0044 2>/dev/null)" ]]; then
      log_warn "凭证文件 ${SRC_CREDENTIALS_FILE} 对同组/其他用户可读，建议 chmod 600"
    fi

    parse_src_credentials "$SRC_CREDENTIALS_FILE" >> "$entries"
    [[ -s "$entries" ]] || die "凭证文件 ${SRC_CREDENTIALS_FILE} 中没有任何有效条目（是否全为注释或空行？）"
    write_src_authfile "$entries"
    return 0
  fi

  # ---- 以下为单一凭证模式（v1.3.0 的行为，保持不变）----
  if [[ -n "$SRC_REGISTRY" && -z "$SRC_USERNAME" ]]; then
    die "--src-registry 需要与 --src-username / --src-password 一起使用"
  fi

  if [[ -z "$SRC_USERNAME" || -z "$SRC_PASSWORD" ]]; then
    die "--src-username 与 --src-password 必须同时提供（当前只给了一个）"
  fi

  local -a hosts=()
  local img
  if [[ -n "$SRC_REGISTRY" ]]; then
    hosts=("$SRC_REGISTRY")
  else
    for img in "${SOURCE_IMAGES[@]}"; do
      hosts+=("$(registry_host_of "$img")")
    done
  fi

  # 去重。用 sort 而不是关联数组，同样是为了兼容 macOS 自带的 bash 3.2。
  local -a uniq_hosts=()
  local h
  while IFS= read -r h; do
    if [[ -n "$h" ]]; then
      uniq_hosts+=("$h")
    fi
  done < <(printf '%s\n' "${hosts[@]}" | sort -u)

  local uh
  for uh in "${uniq_hosts[@]}"; do
    printf '%s%s%s%s%s\n' "$uh" "$FIELD_SEP" "$SRC_USERNAME" "$FIELD_SEP" "$SRC_PASSWORD" >> "$entries"
  done
  write_src_authfile "$entries"

  if [[ -z "$SRC_REGISTRY" && "${#uniq_hosts[@]}" -gt 1 ]]; then
    log_warn "凭证被应用到多个源仓库。若不希望如此，请用 --src-registry 指定其中之一，或改用 --src-credentials 按仓库映射"
  fi
}

# 退出时清理临时文件。
# 用函数而不是把命令内联进 trap，是为了让以后新增的清理项只改这一处，
# 不必再去核对 trap 那行字符串的展开时机。
cleanup() {
  [[ -n "${SRC_AUTHFILE:-}" ]] && rm -f "$SRC_AUTHFILE"
  [[ -n "${SRC_CRED_ENTRIES:-}" ]] && rm -f "$SRC_CRED_ENTRIES"
  [[ -n "${SRC_CREDENTIALS_TMPFILE:-}" ]] && rm -f "$SRC_CREDENTIALS_TMPFILE"
  [[ -n "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
  return 0
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

# 生成「最慢的同步记录」表格行（不含表头），输出到 stdout。
#
# 为什么是「记录」而不是「镜像」：多目标下同一个镜像会有多条记录，各自的耗时
# 是独立的；混在一起聚合反而看不清是哪个目标慢。排序的对象是记录，展示时
# 把目标也带上。
#
# 两个不输出的条件，都是为了避免噪音：
#   - 有效记录不足 3 条：两三个镜像肉眼就能看出快慢，排行只是干扰
#   - 全部为 0 秒（dry-run 的常态）：没有真实耗时数据，排出来的全是 0s
duration_ranking_rows() {
  local max="${1:-5}"
  local -a rows=()
  local i r nonzero=0

  for i in "${!R_SRC[@]}"; do
    # 跳过与排除的耗时恒为 0，参与排序只会污染榜单
    case "${R_STATUS[$i]}" in
      skipped|excluded) continue ;;
    esac
    rows+=("${R_SECONDS[$i]}${FIELD_SEP}${i}")
  done

  [[ ${#rows[@]} -ge 3 ]] || return 0

  for r in "${rows[@]}"; do
    [[ "${r%%"${FIELD_SEP}"*}" -gt 0 ]] && nonzero=$((nonzero + 1))
  done
  [[ "$nonzero" -gt 0 ]] || return 0

  # 借助 sort 排序而不是在 bash 里手写：数字降序恰好是它的强项，
  # 而且避免为了兼容 bash 3.2 而手写排序循环
  printf '%s\n' "${rows[@]}" \
    | sort -t"$FIELD_SEP" -k1,1rn \
    | head -n "$max" \
    | while IFS= read -r r; do
        local idx="${r##*"${FIELD_SEP}"}"
        printf "| %ss | \`%s\` → \`%s\` |\n" \
          "${R_SECONDS[$idx]}" "${R_SRC[$idx]}" "${R_DEST[$idx]}"
      done
}

# 渲染 dry-run 的同步计划预览。
#
# 这不是第二种 dry-run 实现：真实执行的参数仍由 sync_via_skopeo /
# sync_via_regctl 输出。这里只汇总它们即将覆盖的源 → 目标映射，并把
# 「跳过判定 / 自动探测平台」这类必须实际执行才能知道的信息留作提示，
# 不在计划里虚构结果。
print_dry_run_plan() {
  local active_count="$1"
  local raw_src normalized dest row
  local dest_count=0
  local command_count=0
  local execution_path
  local platform_strategy
  local -a plan_rows=()
  local -a plan_lines=()

  if [[ -n "$DEST_EXACT" ]]; then
    dest_count=1
  else
    dest_count=${#DEST_REGISTRIES[@]}
  fi

  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    execution_path="regctl index create"
    if [[ -n "$PLATFORMS" ]]; then
      # 与 sync_via_regctl 一致：先按逗号拆开、去空白，再重组展示。
      # 不能直接复述原始输入，否则空段和空格会让计划偏离实际参数。
      local platform
      local -a explicit_platforms=()
      while IFS= read -r platform; do
        platform="${platform// /}"
        if [[ -n "$platform" ]]; then
          explicit_platforms+=("$platform")
        fi
      done < <(printf '%s\n' "$PLATFORMS" | tr ',' '\n')
      if [[ ${#explicit_platforms[@]} -eq 0 ]]; then
        platform_strategy="实际执行会失败：平台列表解析结果为空"
      else
        platform_strategy="$(IFS=,; printf '%s' "${explicit_platforms[*]}")"
      fi
    else
      platform_strategy="实际执行时自动探测（失败回退 linux/amd64,linux/arm64）"
    fi
  else
    execution_path="skopeo copy --all"
    platform_strategy="全部（--all）"
  fi

  local idx=0
  local total=${#SOURCE_IMAGES[@]}
  for raw_src in "${SOURCE_IMAGES[@]}"; do
    idx=$((idx + 1))
    [[ -z "${EXCLUDE_REASONS[$((idx - 1))]:-}" ]] || continue

    normalized="$(normalize_ref "$raw_src")"
    if ! validate_ref "$normalized" >/dev/null 2>&1; then
      log_error "  [${idx}/${total}] ${normalized} —— 镜像引用无效，实际执行会失败"
      continue
    fi

    resolve_dest_refs "$normalized"
    for dest in "${DEST_REFS[@]}"; do
      command_count=$((command_count + 1))
      plan_lines+=("  [${command_count}] ${normalized} → ${dest}")
      # shellcheck disable=SC2016
      row="$(printf '| `%s` | `%s` | `%s` | %s |' \
        "$normalized" "$dest" "$execution_path" "$platform_strategy")"
      plan_rows+=("$row")
    done
  done

  log_info "同步计划预览（dry-run）"
  log_info "源镜像 ${active_count} 个 · 目标 ${dest_count} 个 · 预计命令 ${command_count} 条"
  log_info "执行路径：${execution_path} · 平台策略：${platform_strategy}"
  if [[ "$FILTERED_OUT_COUNT" -gt 0 ]]; then
    log_info "另有 ${FILTERED_OUT_COUNT} 个源镜像被筛选排除，不进入计划"
  fi
  if [[ "$SKIP_EXISTING" == "true" && "$STRIP_ATTESTATION" != "true" ]]; then
    log_info "skip-existing 只能在实际执行时判断，本计划不预测跳过结果"
  fi
  log_info "计划映射："
  if [[ ${#plan_rows[@]} -gt 0 ]]; then
    printf '%s\n' "${plan_lines[@]}" >&2
  fi
  log_info "预计命令合计：${command_count} 条"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## Dry-run 同步计划"
      echo ""
      echo "| 源镜像 | 目标镜像 | 执行路径 | 平台策略 |"
      echo "| --- | --- | --- | --- |"
      if [[ ${#plan_rows[@]} -gt 0 ]]; then
        printf '%s\n' "${plan_rows[@]}"
      fi
      echo ""
      echo "**预计命令**：${command_count} 条"
      if [[ "$FILTERED_OUT_COUNT" -gt 0 ]]; then
        echo ""
        echo "> 另有 ${FILTERED_OUT_COUNT} 个源镜像被 \`--filter\` / \`--exclude\` 排除。"
      fi
      if [[ "$SKIP_EXISTING" == "true" && "$STRIP_ATTESTATION" != "true" ]]; then
        echo ""
        echo "> \`--skip-existing\` 只能在实际执行时判断；本计划不预测跳过结果。"
      fi
      echo ""
      echo "> ⚠️ 本次为 dry-run，未推送任何镜像。"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

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
  local src dest platforms
  local src_digest="" dest_digest=""

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
  resolve_dest_refs "$src"
  local -a dests=("${DEST_REFS[@]}")

  group_start "[${idx}/${total}] ${src}"

  # 平台取决于源镜像、与目标无关，因此只解析一次
  platforms="$(resolve_platforms "$src")"

  # ---- 第一遍：逐目标做增量跳过判定，收集真正需要推送的目标 ----
  # **每个目标独立判定**——某个目标已是最新，不代表其他目标也是。
  # strip-attestation 模式会重建索引、目标 digest 必然与源不同，因此不做跳过。
  local di=0
  local dest_total=${#dests[@]}
  local -a pending=()
  local -a pending_di=()
  for dest in "${dests[@]}"; do
    di=$((di + 1))

    if [[ "$dest_total" -gt 1 ]]; then
      log_info "目标 [${di}/${dest_total}]：${dest}"
    else
      log_info "目标：${dest}"
    fi
    log_info "平台：${platforms}"

    if [[ "$SKIP_EXISTING" == "true" && "$STRIP_ATTESTATION" != "true" && "$DRY_RUN" != "true" ]]; then
      if is_up_to_date "$src" "$dest"; then
        log_skip "  目标已是最新，跳过"
        src_digest="$(compute_digest "$src" || true)"
        write_result "$(result_file_for "$idx" "$di")" "$src" "$dest" "skipped" "全部（--all）" "0" \
          "目标已存在相同镜像" "$src_digest" "$src_digest"
        continue
      fi
    fi
    pending+=("$dest")
    pending_di+=("$di")
  done

  # ---- 推送 ----
  # 多个目标待推送时走本地 OCI 中转：源只拉取一次，逐目标推送。
  # 中转是**纯优化**——准备阶段的任何失败（磁盘不足、拉取失败）都退化为
  # 逐目标拉推的旧行为，不改变任何一条结果记录的语义。
  # 单目标、dry-run 与 strip-attestation 模式不走中转：
  # 前两者没有收益，第三者要重建索引、regctl 不经过 oci transport。
  local pull_elapsed=0
  local oci_dir=""
  if [[ ${#pending[@]} -ge 2 && "$STRIP_ATTESTATION" != "true" && "$DRY_RUN" != "true" ]]; then
    log_info "${#pending[@]} 个目标待推送，尝试本地中转（源只拉取一次）"
    OCI_STAGING_DIR=""
    PULL_ELAPSED=0
    if prepare_oci_staging "$src"; then
      oci_dir="$OCI_STAGING_DIR"
      pull_elapsed="$PULL_ELAPSED"
      log_ok "源已拉取到本地中转（耗时 ${pull_elapsed}s），逐目标推送"
    fi
  fi

  local start end elapsed status note=""
  local result_file
  local p
  for p in "${!pending[@]}"; do
    dest="${pending[$p]}"
    di="${pending_di[$p]}"
    result_file="$(result_file_for "$idx" "$di")"

    start="$(date +%s)"
    if sync_to_dest "$src" "$dest" "$platforms" "$oci_dir"; then
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

    # 拉取耗时计入第一个待推送目标，并在备注里注明——
    # 总耗时几乎总是由它主导，藏进日志会让耗时排行看起来不合理
    if [[ "$p" -eq 0 && "$pull_elapsed" -gt 0 ]]; then
      elapsed=$((elapsed + pull_elapsed))
      note="含源镜像拉取 ${pull_elapsed}s"
    fi

    # 完整性校验：skopeo 返回 0 不代表每个平台都完整推上去了。
    # 校验放在 digest 记录之前——校验失败会直接改写 status，此时 digest
    # 的取值路径要跟最终状态一致。
    if [[ "$status" == "success" && "$VERIFY" == "true" ]]; then
      local diff_detail verify_rc=0
      diff_detail="$(verify_integrity "$src" "$dest")" || verify_rc=$?
      case "$verify_rc" in
        0)
          log_ok "  校验通过（逐平台一致）"
          ;;
        1)
          status="failed"
          note="完整性校验失败：${diff_detail//$'\n'/; }"
          log_error "  完整性校验失败"
          printf '%s\n' "$diff_detail" | sed 's/^/    /' >&2
          gh_error "完整性校验失败：${src} → ${dest}（${diff_detail//$'\n'/; }）"
          ;;
        2)
          # 拿不到 digest 多半是网络抖动，校验不该比同步本身更容易失败
          log_warn "  无法完成完整性校验（拿不到 digest），不影响结果"
          ;;
      esac
    fi

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

  # 中转目录里是完整镜像（可能数 GB），推送循环一结束就删，不等退出兜底
  [[ -n "$oci_dir" ]] && rm -rf "$oci_dir"

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
# 清单审计（--audit）
#
# 解决的问题很具体：定期同步的用法是「清单记录期望状态，隔一段时间跑一次」，
# 但「我的仓库现在跟上清单了吗」在过去只有真的跑一次同步才能回答——而同步
# 是会真推送的。「检查」与「搬运」本就该分开：只想看一眼仓库状态时，
# 不该被迫先搬一趟。
#
# 四种状态必须分开，尤其是最后一种：
#   最新 / 落后 / 缺失 / 无法判定
# 把「查不到」显示成「落后」，会让人去排查一个并不存在的问题（其实只是网络
# 抖了一下）。这与「参数被接受却不生效必须告警」是同一条原则——错误的信息
# 比没有信息更糟，因为它会被当成结论。
# ---------------------------------------------------------------------------

# 探测一个镜像引用的可达性。
#
# 输出 ok / missing，或 unreachable + 字段分隔符 + 原因。
#
# 判据刻意保守：**只有明确表示「不存在」的错误才算 missing，其余一律算
# unreachable**。反过来（拿不准的都当成缺失）会诱导使用者去同步一个可能
# 早已存在的镜像；「误报缺失」比「承认不知道」有害得多，因为前者会被当成结论。
probe_ref() {
  local ref="$1" err="" rc=0

  # stderr 交给命令替换、stdout 丢弃：出错原因全在 stderr 里。
  # 重定向顺序不能反——2>&1 必须在 >/dev/null 之前，否则 stderr 会被一起丢掉。
  set +e
  err="$(skopeo_inspect_raw "$ref" 2>&1 >/dev/null)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    printf 'ok'
    return 0
  fi

  # registry 表达「这个 manifest / 仓库不存在」的几种措辞。
  # 不在这份名单里的（unauthorized、超时、DNS 解析失败……）一律算无法判定。
  if printf '%s\n' "$err" | grep -qiE 'manifest unknown|name unknown|repository name not known|not found|no such manifest'; then
    printf 'missing'
    return 0
  fi

  # 只取第一行：报错里常跟着很长的 URL，而且多行内容塞进结果文件会破坏排版。
  # 这里刻意不按字节截断——那可能把一个多字节字符切一半，输出成乱码。
  printf 'unreachable%s%s' "$FIELD_SEP" \
    "$(printf '%s' "$err" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -n 1 || true)"
}

# 审计状态的图标与名称。三个地方要用（控制台、Step Summary、通知），
# 各写一份 case 早晚会漂移成一地不一致。
audit_state_mark() {
  case "$1" in
    current)  printf '%s✓%s' "$C_GREEN" "$C_RESET" ;;
    stale)    printf '%s⚠%s' "$C_YELLOW" "$C_RESET" ;;
    missing)  printf '%s✗%s' "$C_RED" "$C_RESET" ;;
    excluded) printf '%s⊘%s' "$C_DIM" "$C_RESET" ;;
    *)        printf '%s?%s' "$C_YELLOW" "$C_RESET" ;;
  esac
}

audit_state_label() {
  case "$1" in
    current)  printf '最新' ;;
    stale)    printf '落后' ;;
    missing)  printf '缺失' ;;
    excluded) printf '已排除' ;;
    *)        printf '无法判定' ;;
  esac
}

# Step Summary 里用 emoji 更醒目（终端那边是单色字符 + 颜色）
audit_state_emoji() {
  case "$1" in
    current)  printf '✅' ;;
    stale)    printf '⚠️' ;;
    missing)  printf '❌' ;;
    excluded) printf '⊘' ;;
    *)        printf '❓' ;;
  esac
}

audit_result_file_for() {
  printf '%s/audit-%04d-%02d' "$WORK_DIR" "$1" "$2"
}

write_audit_result() {
  local file="$1" src="$2" dest="$3" state="$4" note="$5"
  # note 里若混入分隔符会破坏字段结构，统一换成空格
  printf '%s%s%s%s%s%s%s\n' \
    "$src" "$FIELD_SEP" "$dest" "$FIELD_SEP" "$state" "$FIELD_SEP" "${note//$FIELD_SEP/ }" > "$file"
}

# 审计一个源镜像在全部目标上的状态。
#
# 多目标时**逐目标各出一行**，不合并成一个状态：一个目标已是最新、另一个缺失
# 是完全正常的（两个仓库各自的历史不同），合并只会把这层信息抹掉，
# 让人误以为「都好了」或者「都没好」。
audit_one() {
  local idx="$1" src="$2"
  local src_probe dest di=0 dest_total probed state note file

  group_start "[${idx}] ${src}"

  # 源不可达就没有「应该是什么」这一说，任何对比都失去意义：
  # 逐目标记一笔即可，不必再向目标发请求
  src_probe="$(probe_ref "$src")"
  resolve_dest_refs "$src"
  dest_total=${#DEST_REFS[@]}

  for dest in "${DEST_REFS[@]}"; do
    di=$((di + 1))
    file="$(audit_result_file_for "$idx" "$di")"

    if [[ "$src_probe" != "ok" ]]; then
      state="unknown"
      if [[ "$src_probe" == unreachable* ]]; then
        note="源镜像无法访问：${src_probe#*"$FIELD_SEP"}"
      else
        note="源仓库中不存在这个镜像"
      fi
      write_audit_result "$file" "$src" "$dest" "$state" "$note"
      continue
    fi

    probed="$(probe_ref "$dest")"
    case "$probed" in
      ok)
        if is_up_to_date "$src" "$dest"; then
          state="current"
          note=""
        else
          # 与 --verify 同一套比对口径：按各平台子 manifest 的 digest 比。
          # 顶层 digest 会因 registry 重新包装而变化，拿它比会误报一大堆
          state="stale"
          note="目标与源的平台摘要不一致"
        fi
        ;;
      missing)
        state="missing"
        note="目标仓库中不存在"
        ;;
      *)
        state="unknown"
        note="目标仓库无法访问：${probed#*"$FIELD_SEP"}"
        ;;
    esac

    write_audit_result "$file" "$src" "$dest" "$state" "$note"
  done

  group_end
  return 0
}

# 调度全部审计任务。
# 并发控制与 dispatch_all 同一套（jobs -pr 数槽位，兼容 bash 3.2 不用 wait -n）。
dispatch_audit() {
  local idx=0
  local total=${#SOURCE_IMAGES[@]}
  local raw_src reason

  for raw_src in "${SOURCE_IMAGES[@]}"; do
    idx=$((idx + 1))

    reason="${EXCLUDE_REASONS[$((idx - 1))]:-}"
    if [[ -n "$reason" ]]; then
      # 被筛掉的同样出现在报告里。审计场景下这一点更要紧：
      # 报告里少一项，看的人会默认它是好的
      write_audit_result "$(audit_result_file_for "$idx" 1)" "$raw_src" "—" "excluded" "$reason"
      continue
    fi

    if [[ "$CONCURRENCY" -gt 1 ]]; then
      while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CONCURRENCY" ]]; do
        sleep 0.3
      done
      audit_one "$idx" "$raw_src" &
    else
      audit_one "$idx" "$raw_src"
    fi
  done

  if [[ "$CONCURRENCY" -gt 1 ]]; then
    wait || true
  fi
}

load_audit_results() {
  local f src dest state note
  local -a files=()

  for f in "${WORK_DIR}"/audit-*; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done

  [[ ${#files[@]} -gt 0 ]] || return 0

  for f in "${files[@]}"; do
    src=""; dest=""; state=""; note=""
    IFS="$FIELD_SEP" read -r src dest state note < "$f" || true
    A_SRC+=("${src:-}")
    A_DEST+=("${dest:-}")
    A_STATE+=("${state:-unknown}")
    A_NOTE+=("${note:-}")
  done
}

emit_audit_summary() {
  local current=0 stale=0 missing=0 unknown=0 excluded=0 i

  for i in "${!A_STATE[@]}"; do
    case "${A_STATE[$i]}" in
      current)  current=$((current + 1)) ;;
      stale)    stale=$((stale + 1)) ;;
      missing)  missing=$((missing + 1)) ;;
      excluded) excluded=$((excluded + 1)) ;;
      *)        unknown=$((unknown + 1)) ;;
    esac
  done

  local checked=$((current + stale + missing + unknown))

  printf '\n' >&2
  printf '%s\n' "────────────────────────────────────────────────────────" >&2
  for i in "${!A_SRC[@]}"; do
    printf ' %s %s  %s\n' "$(audit_state_mark "${A_STATE[$i]}")" \
      "$(audit_state_label "${A_STATE[$i]}")" "${A_SRC[$i]}" >&2
    printf '   %s→ %s%s\n' "$C_DIM" "${A_DEST[$i]}" "$C_RESET" >&2
    if [[ -n "${A_NOTE[$i]}" ]]; then
      printf '   %s%s%s\n' "$C_YELLOW" "${A_NOTE[$i]}" "$C_RESET" >&2
    fi
  done
  printf '%s\n' "────────────────────────────────────────────────────────" >&2

  if [[ "$stale" -eq 0 && "$missing" -eq 0 && "$unknown" -eq 0 ]]; then
    log_ok "审计完成：${checked} 条全部最新"
  else
    log_info "审计完成：最新 ${current} ｜ 落后 ${stale} ｜ 缺失 ${missing} ｜ 无法判定 ${unknown}"
  fi
  if [[ "$excluded" -gt 0 ]]; then
    log_dim "另有 ${excluded} 条被 --filter / --exclude 排除，未参与审计"
  fi
  # 审计的终点是动作。把「下一步怎么做」直接写出来，省得看完报告还要想
  if [[ "$stale" -gt 0 || "$missing" -gt 0 ]]; then
    log_dim "去掉 --audit 重跑同一条命令即可补齐：已经最新的会被 --skip-existing 自动跳过"
  fi

  # md 与 Step Summary、报告文件三方同源：只在这里渲染一次
  local audit_md="## 镜像清单审计"$'\n\n'
  audit_md+="| 源镜像 | 目标镜像 | 状态 | 说明 |"$'\n'
  audit_md+="| --- | --- | :---: | --- |"$'\n'
  for i in "${!A_SRC[@]}"; do
    audit_md+="| \`${A_SRC[$i]}\` | \`${A_DEST[$i]}\` | $(audit_state_emoji "${A_STATE[$i]}") $(audit_state_label "${A_STATE[$i]}") | ${A_NOTE[$i]:-—} |"$'\n'
  done
  audit_md+=$'\n'"**合计**：最新 ${current} · 落后 ${stale} · 缺失 ${missing} · 无法判定 ${unknown}"$'\n'
  if [[ "$excluded" -gt 0 ]]; then
    audit_md+=$'\n'"> 另有 ${excluded} 条被 \`--filter\` / \`--exclude\` 排除，未参与审计。"$'\n'
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$audit_md" >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ -n "$REPORT_DIR" ]]; then
    local audit_records="${WORK_DIR}/records-audit.jsonl"
    : > "$audit_records"
    for i in "${!A_SRC[@]}"; do
      jq -n --arg src "${A_SRC[$i]}" --arg dest "${A_DEST[$i]}" \
        --arg state "${A_STATE[$i]}" --arg note "${A_NOTE[$i]}" \
        '{source:$src,dest:$dest,state:$state,note:$note}' >> "$audit_records"
    done
    write_check_report_files "audit" "镜像清单审计" "$audit_md" \
      "{\"current\":${current},\"stale\":${stale},\"missing\":${missing},\"unknown\":${unknown},\"excluded\":${excluded}}" \
      "$audit_records"
  fi

  # ---- 结果通知 ----
  # 只为「需要关注的项」列详情：全绿时一句话就够，把整张表推过去只会淹没重点。
  # 条数封顶——清单很长时通知不该变成一篇长文，完整表格在运行页面上。
  local detail="" listed=0 hidden=0
  for i in "${!A_SRC[@]}"; do
    case "${A_STATE[$i]}" in
      current|excluded) continue ;;
    esac
    if [[ "$listed" -ge 20 ]]; then
      hidden=$((hidden + 1))
      continue
    fi
    if [[ -n "${A_NOTE[$i]}" ]]; then
      detail+="- \`${A_SRC[$i]}\` **$(audit_state_label "${A_STATE[$i]}")**：${A_NOTE[$i]}"$'\n'
    else
      detail+="- \`${A_SRC[$i]}\` **$(audit_state_label "${A_STATE[$i]}")**"$'\n'
    fi
    listed=$((listed + 1))
  done
  if [[ "$hidden" -gt 0 ]]; then
    detail+="- …另有 ${hidden} 条未列出（完整结果见运行页面）"$'\n'
  fi

  send_check_notification "镜像清单体检" \
    "共检查 **${checked}** 条（镜像 × 目标）：最新 ${current} ｜ 落后 ${stale} ｜ 缺失 ${missing} ｜ 无法判定 ${unknown}" \
    "$detail" \
    "$((stale + missing + unknown))"

  # 「没查完」与「查出差异」都返回 2：让 CI 门禁不至于在检查本身都没做完时
  # 就报绿。究竟属于哪一种，报告正文里分得很清楚。
  if [[ "$stale" -gt 0 || "$missing" -gt 0 || "$unknown" -gt 0 ]]; then
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 上游版本检查（--check-updates）
#
# images.lock.txt 锁的是某个 k8s 版本的整套组件。上游发新版本时，没有任何机制
# 会通知你——得自己盯上游发布、自己查有哪些新 tag、再手工更新清单。这是定期
# 同步流程里唯一还需要人肉盯着的环节：搬运本身自动化了，校验、通知、趋势都有了，
# 唯独「该不该同步新版本」还靠人记得去查。
#
# 三条刻意的约束：
#
# 1. **只报告，绝不修改清单。** 升到哪个版本涉及兼容性判断，是人的决定。工具
#    只负责让信息可见，不替使用者做选择——与「同步必须显式触发」同源。
# 2. **输出必须收敛。** kube-apiserver 这类仓库有几百个 tag，全列出来等于没有
#    输出。取版本序最大的若干条，同时给出总数——只删不报总数会让人低估差距。
# 3. **不做语义化版本判断，也不过滤预发布。** 上游 tag 命名未必规整
#    （1.27-alpine、latest、v1.32.0-rc.1），语义化比较会给出**错误**结论
#    （把 rc 当成比正式版更新）。只用 sort -V 做「谁在后」的粗排序并原样展示：
#    哪个能上生产是使用者的判断，不是工具的。
# ---------------------------------------------------------------------------

skopeo_list_tags() {
  local repo="$1"
  local -a cmd=(skopeo list-tags)
  if [[ "$TLS_VERIFY" == "false" ]]; then
    cmd+=(--tls-verify=false)
  fi
  # 私有上游同样需要凭证，与 inspect 走同一条装载路径
  if [[ -n "$SRC_AUTHFILE" ]]; then
    cmd+=(--authfile "$SRC_AUTHFILE")
  fi
  cmd+=("docker://${repo}")
  "${cmd[@]}"
}

# 把清单按「源仓库」分组：同一个仓库的多个 tag 只查一次上游，
# 否则 k8s 那十几个组件会把同一个仓库查上十几遍。
#
# 结果写进两个按下标对齐的全局数组（bash 3.2 没有关联数组，
# 项目里统一用下标对齐的并行数组）。
declare -a UPD_REPOS=()
declare -a UPD_KNOWN_TAGS=()
group_repos_from_manifest() {
  local i repo tag idx found
  UPD_REPOS=()
  UPD_KNOWN_TAGS=()

  for i in "${!SOURCE_IMAGES[@]}"; do
    # 被筛掉的不查：与同步、审计一致，使用者有意排除的东西不该产生网络请求。
    # 汇总里会报出排除了多少个，不会悄悄少查。
    if [[ -n "${EXCLUDE_REASONS[$i]:-}" ]]; then
      continue
    fi

    split_image_ref "${SOURCE_IMAGES[$i]}"
    repo="$REF_REPO"
    tag="$REF_TAG"

    found=0
    for idx in "${!UPD_REPOS[@]}"; do
      if [[ "${UPD_REPOS[$idx]}" == "$repo" ]]; then
        found=1
        if [[ -n "$tag" ]]; then
          # 下标不带 $：数组下标是算术上下文，项目里的数组赋值统一这么写
          UPD_KNOWN_TAGS[idx]="${UPD_KNOWN_TAGS[idx]:-} ${tag}"
        fi
        break
      fi
    done

    if [[ "$found" -eq 0 ]]; then
      UPD_REPOS+=("$repo")
      UPD_KNOWN_TAGS+=("$tag")
    fi
  done
}

check_updates_all() {
  local limit="$UPDATES_LIMIT"
  local idx repo known_tags raw rc upstream_sorted known_sorted missing missing_count shown
  local checked=0 with_updates=0 failed=0 total_missing=0
  local summary_rows=""
  local notify_detail=""

  group_repos_from_manifest

  if [[ ${#UPD_REPOS[@]} -eq 0 ]]; then
    log_warn "没有可检查的镜像（全部被筛选排除）"
    return 0
  fi

  local upd_records="${WORK_DIR}/records-check-updates.jsonl"
  : > "$upd_records"

  log_info "检查 ${#UPD_REPOS[@]} 个源仓库的上游 tag 列表"

  for idx in "${!UPD_REPOS[@]}"; do
    repo="${UPD_REPOS[$idx]}"
    known_tags="${UPD_KNOWN_TAGS[$idx]:-}"
    checked=$((checked + 1))

    printf '\n' >&2
    printf '%s%s%s\n' "$C_BLUE" "$repo" "$C_RESET" >&2

    known_tags="$(printf '%s' "$known_tags" | tr -s ' ' | sed 's/^ //; s/ $//')"
    if [[ -n "$known_tags" ]]; then
      printf '  清单中：%s\n' "$known_tags" >&2
    else
      printf '  清单中：（只给了 digest，没有 tag）\n' >&2
    fi

    set +e
    raw="$(skopeo_list_tags "$repo" 2>&1)"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
      # 单个仓库查不成不该影响其他仓库：私有仓库、不支持列 tag 的 registry、
      # 网络抖动都会走到这里，逐个记下来继续
      failed=$((failed + 1))
      local reason
      reason="$(printf '%s' "$raw" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -n 1 || true)"
      printf '  %s无法查询上游 tag 列表%s：%s\n' "$C_YELLOW" "$C_RESET" "$reason" >&2
      summary_rows+="| \`${repo}\` | ${known_tags:-—} | — | 查询失败：${reason} |"$'\n'
      notify_detail+="- \`${repo}\` **查询失败**：${reason}"$'\n'
      jq -n --arg repo "$repo" --arg known "${known_tags}" \
        --arg state "error" --arg tags "" --arg note "查询失败：${reason}" \
        '{repo:$repo,in_manifest:$known,state:$state,latest_tags:$tags,note:$note}' >> "$upd_records"
      continue
    fi

    upstream_sorted="$(printf '%s' "$raw" | jq -r '.Tags[]?' 2>/dev/null | grep -v '^$' | sort -u || true)"
    if [[ -z "$upstream_sorted" ]]; then
      printf '  %s上游没有返回任何 tag%s\n' "$C_YELLOW" "$C_RESET" >&2
      summary_rows+="| \`${repo}\` | ${known_tags:-—} | — | 上游返回空列表 |"$'\n'
      jq -n --arg repo "$repo" --arg known "${known_tags}" \
        --arg state "empty" --arg tags "" --arg note "上游没有返回任何 tag" \
        '{repo:$repo,in_manifest:$known,state:$state,latest_tags:$tags,note:$note}' >> "$upd_records"
      continue
    fi

    known_sorted="$(printf '%s' "$known_tags" | tr ' ' '\n' | grep -v '^$' | sort -u || true)"
    missing="$(comm -13 <(printf '%s\n' "$known_sorted") <(printf '%s\n' "$upstream_sorted") || true)"
    missing="$(printf '%s' "$missing" | grep -v '^$' || true)"

    if [[ -z "$missing" ]]; then
      printf '  %s清单已覆盖上游现有 tag（上游共 %s 个）%s\n' \
        "$C_GREEN" "$(printf '%s\n' "$upstream_sorted" | grep -c .)" "$C_RESET" >&2
      summary_rows+="| \`${repo}\` | ${known_tags:-—} | 0 | ✅ 已覆盖 |"$'\n'
      jq -n --arg repo "$repo" --arg known "${known_tags}" \
        --arg state "covered" --arg tags "" --arg note "" \
        '{repo:$repo,in_manifest:$known,state:$state,latest_tags:$tags,note:$note}' >> "$upd_records"
      continue
    fi

    with_updates=$((with_updates + 1))
    missing_count="$(printf '%s\n' "$missing" | grep -c .)"
    total_missing=$((total_missing + missing_count))

    # 缺失数少于上限时就说「全部列出」——写「版本序最大的 5 个」却只列出 3 条，
    # 看的人会以为还有没显示出来的
    local tail_label="版本序最大的 ${limit} 个"
    if [[ "$missing_count" -le "$limit" ]]; then
      tail_label="全部列出如下"
    fi

    printf '  %s上游共 %s 个 tag，其中 %s 个不在清单中，%s：%s\n' \
      "$C_YELLOW" \
      "$(printf '%s\n' "$upstream_sorted" | grep -c .)" \
      "$missing_count" "$tail_label" "$C_RESET" >&2

    shown="$(printf '%s\n' "$missing" | sort -Vr | head -n "$limit" | tr '\n' ' ')"
    shown="${shown% }"
    printf '    %s\n' "$shown" >&2

    summary_rows+="| \`${repo}\` | ${known_tags:-—} | ${missing_count} | ${shown} |"$'\n'
    notify_detail+="- \`${repo}\` 有 **${missing_count}** 个未收录：${shown}"$'\n'
    jq -n --arg repo "$repo" --arg known "${known_tags}" \
      --arg state "updates" --arg tags "${shown}" --arg note "" \
      '{repo:$repo,in_manifest:$known,state:$state,latest_tags:$tags,note:$note}' >> "$upd_records"
  done

  printf '\n' >&2
  if [[ "$with_updates" -eq 0 && "$failed" -eq 0 ]]; then
    log_ok "检查完成：${checked} 个源仓库，清单均已覆盖上游现有 tag"
  else
    log_info "检查完成：${checked} 个源仓库，${with_updates} 个有未收录的 tag（共 ${total_missing} 个），${failed} 个查询失败"
  fi
  if [[ "$FILTERED_OUT_COUNT" -gt 0 ]]; then
    log_dim "另有 ${FILTERED_OUT_COUNT} 个镜像被 --filter / --exclude 排除，未参与检查"
  fi
  if [[ "$with_updates" -gt 0 ]]; then
    # 说清楚边界：这是报告，不是升级建议，更不会替你改文件
    log_dim "以上只是「上游有这些 tag」，不是「应该升级到哪个版本」；清单需要时请手工编辑"
  fi

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## 上游版本检查"
      echo ""
      echo "检查了 ${checked} 个源仓库：${with_updates} 个有未收录的 tag（共 ${total_missing} 个），${failed} 个查询失败。"
      echo ""
      echo "| 源仓库 | 清单中 | 未收录 | 版本序最大的 ${limit} 个 |"
      echo "| --- | --- | :---: | --- |"
      printf '%s' "$summary_rows"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ -n "$REPORT_DIR" ]]; then
    local upd_md="## 上游版本检查"$'\n\n'
    upd_md+="检查了 ${checked} 个源仓库：${with_updates} 个有未收录的 tag（共 ${total_missing} 个），${failed} 个查询失败。"$'\n\n'
    upd_md+="| 源仓库 | 清单中 | 未收录 | 版本序最大的 ${limit} 个 |"$'\n'
    upd_md+="| --- | --- | :---: | --- |"$'\n'
    upd_md+="${summary_rows}"
    write_check_report_files "check-updates" "上游版本检查" "$upd_md" \
      "{\"checked\":${checked},\"with_updates\":${with_updates},\"failed\":${failed},\"total_missing\":${total_missing}}" \
      "$upd_records"
  fi

  send_check_notification "上游版本检查" \
    "检查了 **${checked}** 个源仓库：${with_updates} 个有未收录的 tag（共 ${total_missing} 个），${failed} 个查询失败" \
    "$notify_detail" \
    "$((with_updates + failed))"

  # 与 --audit 同一套退出码约定：没查成与查出差异都返回 2，
  # 让 CI 门禁不至于在检查本身没做完时报绿
  if [[ "$with_updates" -gt 0 || "$failed" -gt 0 ]]; then
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 锁文件时效性校验（--audit-lock）
#
# --write-lock 的卖点是「digest 不会变，锁下来就能精确复现」。但这只完成了
# 半件事：上游重新构建并覆盖同名 tag 时，锁文件不会有任何变化（它记录的
# 是历史事实，依然「正确」），而下一次增量跳过发现源变了，会把新内容静默
# 搬进你的仓库。等你在集群行为异常时发现，已经隔了很久。
#
# 这里补上缺的环节：定期问一句「上游的 tag 还是我锁的那份吗」。
#
# 状态三分类，沿用审计家族的原则：漂移只在「明确不一致」时下结论，
# 查不到一律算无法判定。唯一的边界是「上游 tag 已删除」——tag 消失是
# 明确发生的变更（registry 明确回答了「不存在」），所以算漂移而不是
# 无法判定，并在备注里注明，与「网络原因查不到」区分开。
# ---------------------------------------------------------------------------

# 锁文件条目的状态图标与名称（报告、Step Summary、通知共用）
lock_state_mark() {
  case "$1" in
    match)   printf '%s✓%s' "$C_GREEN" "$C_RESET" ;;
    drift)   printf '%s⚠%s' "$C_YELLOW" "$C_RESET" ;;
    unknown) printf '%s?%s' "$C_YELLOW" "$C_RESET" ;;
    *)       printf '%s⊘%s' "$C_DIM" "$C_RESET" ;;
  esac
}

lock_state_label() {
  case "$1" in
    match)   printf '一致' ;;
    drift)   printf '漂移' ;;
    unknown) printf '无法判定' ;;
    nodigest) printf '未锁定' ;;
    *)       printf '标注' ;;
  esac
}

lock_state_emoji() {
  case "$1" in
    match)   printf '✅' ;;
    drift)   printf '⚠️' ;;
    unknown) printf '❓' ;;
    nodigest) printf '⊘' ;;
    *)       printf 'ℹ️' ;;
  esac
}

# 解析锁文件为待校验条目，填入 L_* 数组。
#
# 标注行（「# [失败] xxx」这类）不是噪音：它们记录着上次同步时哪些镜像
# 没锁上、为什么。审计报告里应当原样带出——悄悄吞掉的话，看报告的人
# 会以为锁文件里只有成功的条目。
parse_lockfile() {
  local path="$1" line trimmed
  L_REF=()
  L_STATE=()
  L_NOTE=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" ]]; then
      continue
    fi

    # 标注行：write_lockfile 写出的「# [类别] 镜像」。
    # 其余 # 开头的是普通注释（文件头说明等），跳过。
    if [[ "$trimmed" == "#"* ]]; then
      if [[ "$trimmed" =~ ^#\ \[(.+)\]\ (.+)$ ]]; then
        L_REF+=("${BASH_REMATCH[2]}")
        L_STATE+=("marker")
        L_NOTE+=("锁文件标注「${BASH_REMATCH[1]}」，不参与校验")
      fi
      continue
    fi

    # 普通条目，允许行内注释（与 --file 的读取规则一致）
    trimmed="${trimmed%%#*}"
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" ]]; then
      continue
    fi

    if [[ "$trimmed" != *"@"* ]]; then
      L_REF+=("$trimmed")
      L_STATE+=("nodigest")
      L_NOTE+=("未锁定 digest，无法校验时效性")
      continue
    fi

    L_REF+=("$trimmed")
    L_STATE+=("")
    L_NOTE+=("")
  done < "$path"

  if [[ ${#L_REF[@]} -eq 0 ]]; then
    die "锁文件里没有可校验的条目：${path}"
  fi
}

lock_result_file_for() {
  printf '%s/lock-%04d' "$WORK_DIR" "$1"
}

write_lock_result() {
  local file="$1" ref="$2" state="$3" note="$4"
  printf '%s%s%s%s%s\n' "$ref" "$FIELD_SEP" "$state" "$FIELD_SEP" "${note//$FIELD_SEP/ }" > "$file"
}

# 校验单个锁文件条目：上游当前 digest 是否仍与锁定的一致。
#
# 比对口径与 --write-lock 完全同源（都是 compute_digest 的顶层 manifest
# digest），因此「一致」意味着的正是「当时锁的就是这份」。
audit_lock_one() {
  local idx="$1" entry="$2"
  local ref="${entry%%@*}"
  local locked="${entry#*@}"
  local file cur probe

  file="$(lock_result_file_for "$idx")"

  set +e
  cur="$(compute_digest "$ref")"
  local cur_rc=$?
  set -e

  if [[ "$cur_rc" -eq 0 && -n "$cur" ]]; then
    if [[ "$cur" == "$locked" ]]; then
      write_lock_result "$file" "$entry" "match" ""
    else
      write_lock_result "$file" "$entry" "drift" "上游已变更：锁定 ${locked}，当前 ${cur}"
    fi
    return 0
  fi

  # digest 拿不到，区分「上游明确说不存在」与「查不到」：
  # 前者是明确发生的变更（漂移），后者才是无法判定
  probe="$(probe_ref "$ref")"
  if [[ "$probe" == "missing" ]]; then
    write_lock_result "$file" "$entry" "drift" "上游已删除该 tag（锁定 ${locked}）"
  elif [[ "$probe" == unreachable* ]]; then
    write_lock_result "$file" "$entry" "unknown" "上游无法访问：${probe#*"$FIELD_SEP"}"
  else
    write_lock_result "$file" "$entry" "unknown" "无法获取上游 digest（probe=${probe}）"
  fi
  return 0
}

# 调度全部锁文件条目。标注行与未锁定行不走子进程，直接落结果。
dispatch_audit_lock() {
  local i idx entry
  local total=${#L_REF[@]}

  for i in "${!L_REF[@]}"; do
    idx=$((i + 1))
    entry="${L_REF[$i]}"

    case "${L_STATE[$i]}" in
      marker|nodigest)
        write_lock_result "$(lock_result_file_for "$idx")" "$entry" \
          "${L_STATE[$i]}" "${L_NOTE[$i]}"
        continue ;;
    esac

    if [[ "$CONCURRENCY" -gt 1 ]]; then
      while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CONCURRENCY" ]]; do
        sleep 0.3
      done
      audit_lock_one "$idx" "$entry" &
    else
      audit_lock_one "$idx" "$entry"
    fi
  done

  if [[ "$CONCURRENCY" -gt 1 ]]; then
    wait || true
  fi
}

load_lock_results() {
  local f ref state note
  local -a files=()

  for f in "${WORK_DIR}"/lock-*; do
    [[ -e "$f" ]] || continue
    files+=("$f")
  done

  [[ ${#files[@]} -gt 0 ]] || return 0

  # 结果文件是全集（每个条目一个），按序覆盖解析时的初始值
  L_REF=()
  L_STATE=()
  L_NOTE=()
  for f in "${files[@]}"; do
    ref=""; state=""; note=""
    IFS="$FIELD_SEP" read -r ref state note < "$f" || true
    L_REF+=("${ref:-}")
    L_STATE+=("${state:-unknown}")
    L_NOTE+=("${note:-}")
  done
}

emit_lock_summary() {
  local match=0 drift=0 unknown=0 nodigest=0 marker=0 i

  for i in "${!L_STATE[@]}"; do
    case "${L_STATE[$i]}" in
      match)   match=$((match + 1)) ;;
      drift)   drift=$((drift + 1)) ;;
      unknown) unknown=$((unknown + 1)) ;;
      nodigest) nodigest=$((nodigest + 1)) ;;
      *)       marker=$((marker + 1)) ;;
    esac
  done

  printf '\n' >&2
  printf '%s\n' "────────────────────────────────────────────────────────" >&2
  for i in "${!L_REF[@]}"; do
    printf ' %s %s  %s\n' "$(lock_state_mark "${L_STATE[$i]}")" \
      "$(lock_state_label "${L_STATE[$i]}")" "${L_REF[$i]}" >&2
    if [[ -n "${L_NOTE[$i]}" ]]; then
      printf '   %s%s%s\n' "$C_YELLOW" "${L_NOTE[$i]}" "$C_RESET" >&2
    fi
  done
  printf '%s\n' "────────────────────────────────────────────────────────" >&2

  if [[ "$drift" -eq 0 && "$unknown" -eq 0 ]]; then
    log_ok "锁文件校验完成：${match} 条与锁定的一致"
  else
    log_info "锁文件校验完成：一致 ${match} ｜ 漂移 ${drift} ｜ 无法判定 ${unknown}"
  fi
  if [[ "$nodigest" -gt 0 ]]; then
    log_dim "另有 ${nodigest} 条未锁定 digest，无法校验（已列在报告里）"
  fi
  if [[ "$marker" -gt 0 ]]; then
    log_dim "另有 ${marker} 条锁文件标注（上次同步未锁上的条目）"
  fi
  if [[ "$drift" -gt 0 ]]; then
    log_dim "漂移的镜像可从锁文件回拉精确的旧版本：把引用中的 tag 换成 @digest 即可"
  fi

  local lock_md="## 锁文件时效性校验"$'\n\n'
  lock_md+="| 锁定条目 | 状态 | 说明 |"$'\n'
  lock_md+="| --- | :---: | --- |"$'\n'
  for i in "${!L_REF[@]}"; do
    lock_md+="| \`${L_REF[$i]}\` | $(lock_state_emoji "${L_STATE[$i]}") $(lock_state_label "${L_STATE[$i]}") | ${L_NOTE[$i]:-—} |"$'\n'
  done
  lock_md+=$'\n'"**合计**：一致 ${match} · 漂移 ${drift} · 无法判定 ${unknown} · 未锁定 ${nodigest} · 标注 ${marker}"$'\n'

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$lock_md" >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ -n "$REPORT_DIR" ]]; then
    local lock_records="${WORK_DIR}/records-lock-audit.jsonl"
    : > "$lock_records"
    for i in "${!L_REF[@]}"; do
      jq -n --arg ref "${L_REF[$i]}" --arg state "${L_STATE[$i]}" --arg note "${L_NOTE[$i]}" \
        '{entry:$ref,state:$state,note:$note}' >> "$lock_records"
    done
    write_check_report_files "lock-audit" "锁文件时效性校验" "$lock_md" \
      "{\"match\":${match},\"drift\":${drift},\"unknown\":${unknown},\"nodigest\":${nodigest},\"marker\":${marker}}" \
      "$lock_records"
  fi

  # 通知只带需要关注的条目，与 --audit 同一套克制规则
  local detail="" listed=0 hidden=0
  for i in "${!L_STATE[@]}"; do
    case "${L_STATE[$i]}" in
      drift|unknown) ;;
      *) continue ;;
    esac
    if [[ "$listed" -ge 20 ]]; then
      hidden=$((hidden + 1))
      continue
    fi
    detail+="- \`${L_REF[$i]}\` **$(lock_state_label "${L_STATE[$i]}")**：${L_NOTE[$i]}"$'\n'
    listed=$((listed + 1))
  done
  if [[ "$hidden" -gt 0 ]]; then
    detail+="- …另有 ${hidden} 条未列出（完整结果见运行页面）"$'\n'
  fi

  send_check_notification "锁文件时效性校验" \
    "共校验 **$((match + drift + unknown))** 条：一致 ${match} ｜ 漂移 ${drift} ｜ 无法判定 ${unknown}" \
    "$detail" \
    "$((drift + unknown))"

  if [[ "$drift" -gt 0 || "$unknown" -gt 0 ]]; then
    return 2
  fi
  return 0
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
# ---------------------------------------------------------------------------
# 连续失败计数
#
# 「同一个镜像连续失败 N 次才通知」需要跨运行的状态，而脚本每次运行都是独立的。
# 这里不复用 history.sh（它是独立的事后查询工具，不是同步流程的库），
# 而是把「下载报告 + 展开记录」这一小段在此重写——两处对同一数据格式的依赖
# 由报告 JSON 的 schema（write_report 产出）保证。
# ---------------------------------------------------------------------------

# 下载最近若干次运行的同步报告，展开为逐条记录，按时间升序写入 $1。
# 行格式：generated_at<FS>source<FS>status（ISO 时间的字典序即时间序）。
#
# 任何一环失败都返回非零——调用方按「拿不到历史」降级，不中断同步。
# 不是每次运行都在做同步（还有 CI、Release），所以单次下载失败是常态而非异常。
fetch_sync_history() {
  local out_file="$1"

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local tmpdir id f
  tmpdir="$(mktemp -d)" || return 1

  local -a run_ids=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && run_ids+=("$id")
  done < <(gh run list --limit 15 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)

  local got=0
  if [[ ${#run_ids[@]} -gt 0 ]]; then
    for id in "${run_ids[@]}"; do
      if gh run download "$id" -n "$HISTORY_ARTIFACT" -D "${tmpdir}/${id}" >/dev/null 2>&1; then
        got=$((got + 1))
      fi
    done
  fi

  if [[ "$got" -eq 0 ]]; then
    rm -rf "$tmpdir"
    return 1
  fi

  : > "$out_file"
  while IFS= read -r f; do
    jq -r 'select(.images != null) | .generated_at as $at
           | .images[] | [$at, .source, .status] | join("\u001f")' "$f" >> "$out_file" 2>/dev/null || true
  done < <(find "$tmpdir" -type f -name '*.json' 2>/dev/null)

  rm -rf "$tmpdir"
  sort -o "$out_file" "$out_file"
  [[ -s "$out_file" ]]
}

# 计算某镜像在历史中的连续失败次数（不含本次运行）。
# 从最新记录往回数，中间遇到任何非 failed 的记录（成功/跳过/排除）即清零——
# 「中间成功过一次就重新计数」正是这个功能的语义。
count_consecutive_failures() {
  local image="$1" history_file="$2"
  local count=0 line src status
  local -a lines=()

  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done < "$history_file"

  local i
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    line="${lines[$i]}"
    src="${line#*"${FIELD_SEP}"}"          # 跳过 generated_at
    src="${src%%"${FIELD_SEP}"*}"
    status="${line##*"${FIELD_SEP}"}"
    [[ "$src" == "$image" ]] || continue
    if [[ "$status" == "failed" ]]; then
      count=$((count + 1))
    else
      break
    fi
  done
  printf '%s' "$count"
}

# 决定本次要通知哪些失败镜像。输出到 stdout，每行「镜像<FS>连续失败次数」。
#
# 阈值为 1 时就是全部失败镜像（历史行为）；大于 1 时逐个数连续次数，
# 未达阈值的失败会被有意地沉默——这正是这个功能存在的意义：
# 上游抖动的失败重跑就好，每次都响的通知很快就没有人看了。
#
# 拿不到历史时全部按「连续 1 次」处理：宁可不通知，也不基于猜测误报。
gather_alert_images() {
  local hist_file="$1"
  local i img cnt

  for i in "${!R_SRC[@]}"; do
    [[ "${R_STATUS[$i]}" == "failed" ]] || continue
    img="${R_SRC[$i]}"
    if [[ -n "$hist_file" && -s "$hist_file" ]]; then
      cnt="$(count_consecutive_failures "$img" "$hist_file")"
      cnt=$((cnt + 1))
    else
      cnt=1
    fi
    if [[ "$cnt" -ge "$NOTIFY_AFTER_FAILURES" ]]; then
      printf '%s%s%s\n' "$img" "$FIELD_SEP" "$cnt"
    else
      log_info "${img} 连续失败 ${cnt} 次，未达阈值 ${NOTIFY_AFTER_FAILURES}，暂不通知"
    fi
  done
}

build_notify_text() {
  local total="$1" ok="$2" skipped="$3" fail="$4" excluded="${5:-0}" alert_detail="$6"
  local text=""

  text="## 镜像同步完成"$'\n\n'
  text+="共 **${total}** 个镜像 ｜ 成功 ${ok} ｜ 跳过 ${skipped} ｜ 失败 ${fail}"$'\n'

  if [[ "$excluded" -gt 0 ]]; then
    text+="另有 ${excluded} 个镜像被筛选条件排除，未参与本次同步。"$'\n'
  fi

  if [[ "$fail" -gt 0 ]]; then
    text+=$'\n'"### 失败详情"$'\n\n'
    text+="${alert_detail}"
  fi

  # 在 Actions 中运行时附上运行链接，便于收到通知后一键跳转排查
  append_run_link "$text"
}

# 把一段 Markdown 文本推送到 webhook。
#
# 同步、审计、上游检查三条路径共用它：类型识别、JSON 组装、HTTP 调用与降级
# 处理都只该有一份实现——分三份写，改一处忘两处是迟早的事。
#
# **永远返回 0**：通知是附加能力，发不出去只告警，绝不能让一次成功的运行变红。
notify_send_text() {
  local text="$1" title="$2"
  local type="$NOTIFY_TYPE"

  [[ -n "$NOTIFY_WEBHOOK" ]] || return 0

  if [[ "$type" == "auto" ]]; then
    type="$(detect_notify_type "$NOTIFY_WEBHOOK")"
  fi

  # 交给 jq 构造 JSON，转义由它负责，避免镜像名中的特殊字符破坏结构
  local payload
  case "$type" in
    dingtalk)
      payload="$(jq -n --arg t "$text" --arg s "$title" '{msgtype:"markdown",markdown:{title:$s,text:$t}}')" ;;
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
    log_info "结果已推送到 ${type}"
  else
    log_warn "通知发送失败（HTTP ${http_code}），结果不受影响"
    gh_warning "结果通知发送失败：HTTP ${http_code}"
  fi

  return 0
}

# 把 Actions 运行链接追加到通知正文末尾，便于收到通知后一键跳转排查
append_run_link() {
  local text="$1"
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    local base="${GITHUB_SERVER_URL:-https://github.com}"
    text+=$'\n'"[查看运行详情](${base}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID})"$'\n'
  fi
  printf '%s' "$text"
}

# 把检查模式的报告落盘（.md 与 .json 各一份）。
#
# md 与 Step Summary 同源——调用方把渲染好的同一段 markdown 传进来，
# 两处不会各自漂移；json 顶层带 generated_at 与汇总计数，供其他系统消费
# （history.sh 就是靠 generated_at 对齐时间的，检查报告沿用同一约定）。
# 记录文件是 JSON Lines（每行一个对象），由调用方用 jq -n --arg 逐条写出，
# 转义交给 jq，避免备注里的特殊字符破坏结构。
write_check_report_files() {
  local check_name="$1" title="$2" md_body="$3" summary_json="$4" records_file="$5"
  local generated
  generated="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$REPORT_DIR"

  {
    echo "# ${title}"
    echo ""
    echo "- 生成时间：${generated}"
    echo ""
    printf '%s\n' "$md_body"
  } > "${REPORT_DIR}/${check_name}-report.md"

  jq -n --arg at "$generated" --arg name "$check_name" \
    --slurpfile r "$records_file" \
    '{generated_at:$at, check:$name, summary:('"${summary_json}"'), records:$r}' \
    > "${REPORT_DIR}/${check_name}-report.json"

  log_info "检查报告已写入：${REPORT_DIR}/${check_name}-report.md 与 .json"
}


# 审计 / 上游检查完成后的通知。
#
# 与同步路径共用发送实现，但**「要不要发」的规则不同**：
# `--notify-on failure` 在检查模式下表示「有需要关注的项」——存在落后 / 缺失 /
# 无法判定，或有仓库没查成。检查没有「连续失败」的概念，因此
# `--notify-after-failures` 在这里不适用（显式传入时在参数校验阶段告警）。
send_check_notification() {
  local title="$1" summary="$2" detail="$3" attention="$4"

  [[ -n "$NOTIFY_WEBHOOK" ]] || return 0

  if [[ "$NOTIFY_ON" == "failure" && "$attention" -eq 0 ]]; then
    log_info "本次没有需要关注的项，按 --notify-on failure 的配置跳过通知"
    return 0
  fi

  local text="## ${title}"$'\n\n'"${summary}"$'\n'
  if [[ -n "$detail" ]]; then
    text+=$'\n'"${detail}"$'\n'
  fi
  text="$(append_run_link "$text")"

  notify_send_text "$text" "$title"
  return 0
}

send_notification() {
  local total="$1" ok="$2" skipped="$3" fail="$4" excluded="${5:-0}"

  [[ -n "$NOTIFY_WEBHOOK" ]] || return 0

  if [[ "$NOTIFY_ON" == "failure" && "$fail" -eq 0 ]]; then
    log_info "本次没有失败，按 --notify-on failure 的配置跳过通知"
    return 0
  fi

  # 决定本次要通知哪些失败镜像（详见 gather_alert_images）。
  local alert_detail="" line img cnt
  local -a alert_lines=()
  local hist_file="${WORK_DIR:-}/notify-history.tsv"

  if [[ "$fail" -gt 0 && "$NOTIFY_AFTER_FAILURES" -gt 1 ]]; then
    # 历史只在此时才需要——下载要花几秒，不该让每次成功的运行都付出这个代价
    if ! fetch_sync_history "$hist_file"; then
      log_warn "无法获取历史报告（--history-artifact「${HISTORY_ARTIFACT}」），无法判断连续失败次数，本次不发送失败通知"
      return 0
    fi
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    img="${line%%"${FIELD_SEP}"*}"
    cnt="${line##*"${FIELD_SEP}"}"
    if [[ "$cnt" -gt 1 ]]; then
      alert_lines+=("- ${img}（**连续第 ${cnt} 次失败**）")
    else
      alert_lines+=("- ${img}")
    fi
  done < <(gather_alert_images "$hist_file")

  if [[ "$fail" -gt 0 && ${#alert_lines[@]} -eq 0 ]]; then
    # 有失败但没有任何镜像达到通知阈值——沉默是刻意的
    log_info "所有失败均未达到连续 ${NOTIFY_AFTER_FAILURES} 次的阈值，本次不通知"
    return 0
  fi

  # 必须先判长度再遍历：set -u 下空数组的 "${arr[@]}" 在 bash 3.2（macOS 自带）
  # 会报 unbound variable。CI 的 bash 5 不报，所以这个缺陷只在本地暴露——
  # 触发条件是「同步全部成功 + 配置了 webhook + 在 macOS 上跑」，
  # 表现为同步明明成功了脚本却以非零退出。与 collect_images 里那条注释同源。
  if [[ ${#alert_lines[@]} -gt 0 ]]; then
    for line in "${alert_lines[@]}"; do
      alert_detail+="${line}"$'\n'
    done
  fi

  local text
  text="$(build_notify_text "$total" "$ok" "$skipped" "$fail" "$excluded" "$alert_detail")"

  notify_send_text "$text" "镜像同步完成"

  return 0
}

# ---------------------------------------------------------------------------
# 重跑指引
#
# v1.11 让失败如实报告，v1.14 让瞬时抖动自动挽回一轮。这一段补的是持续失败
# 之后的最后一跳：把「重跑」直接交到使用者手里——复制一段、粘一次即可，
# 不必自己从报告里抄镜像名、再去拼一条带筛选参数的运行。
# ---------------------------------------------------------------------------

# 转义 ERE 元字符，让镜像引用能安全地拼进 --filter 的正则。
#
# 必须转义：--filter 走的是 grep -E，`.` 之类会退化成通配，而镜像引用里点号
# 几乎必然出现。实测 BSD sed（macOS 自带）与 GNU sed（CI）行为一致。
ere_escape() {
  printf '%s' "$1" | sed 's/[][\^$.|*+?(){}]/\\&/g'
}

# 当前跑在哪个同步工作流里，决定重跑指引给哪种形态。
#
# 用 GITHUB_WORKFLOW_REF（含工作流文件名）而不是 GITHUB_WORKFLOW（页面上的
# 显示名）：后者随时可以改，前者跟着文件走。两个都拿不到（本地跑）时退化为
# list —— 镜像清单对任何入口都有参考价值，正则给错了则会把作用域指偏。
rerun_style() {
  case "${GITHUB_WORKFLOW_REF:-}" in
    *sync-images-batch.yml*) printf '%s' "filter" ;;
    *)                       printf '%s' "list" ;;
  esac
}

# 挑出「值得重跑」的失败项。三处消费方共用这一份结果。
#
# 判定是两条：状态为 failed，且失败原因不是「镜像引用格式错误」——后者重跑
# 多少次都还是同样的结果，列进清单只会让人白跑一趟。被排除的项不静默消失，
# 计数留在 RERUN_NOT_RERUNNABLE 里由渲染层交代（「排除的东西必须可见」）。
#
# 结果走全局变量：本文件对「命令替换是子 shell、赋值传不回父进程」有过多轮
# 教训，多值一律用全局变量传出。
collect_rerun_items() {
  RERUN_IMAGES=()
  RERUN_FILTER=""
  RERUN_NOT_RERUNNABLE=0

  # dry-run 没有真正推送过任何东西，谈不上「重跑失败项」。
  [[ "$DRY_RUN" == "true" ]] && return 0

  local i ref
  local -a seen=()
  for i in "${!R_STATUS[@]}"; do
    [[ "${R_STATUS[$i]}" == "failed" ]] || continue

    if [[ "${R_NOTE[$i]}" == 镜像引用格式错误* ]]; then
      RERUN_NOT_RERUNNABLE=$((RERUN_NOT_RERUNNABLE + 1))
      continue
    fi

    ref="${R_SRC[$i]}"
    [[ -n "$ref" ]] || continue

    # 保序去重：多目标时同一个源会出现多行，而重跑只要列一次。
    # bash 3.2 没有关联数组，失败项数量又小，线性查一遍足够。
    local dup=""
    if [[ ${#seen[@]} -gt 0 ]]; then
      local s
      for s in "${seen[@]}"; do
        if [[ "$s" == "$ref" ]]; then dup=1; break; fi
      done
    fi
    [[ -n "$dup" ]] && continue

    seen+=("$ref")
    RERUN_IMAGES+=("$ref")
  done

  # 拼锚定正则。锚点是必须的：--filter 是部分匹配（grep -E），不锚定的话
  # nginx:1.27 会连带把 nginx:1.27-alpine 一类也匹配进来。
  # 另外要容忍 docker:// 前缀——filter 匹配的是**规范化之前**的原始串，
  # 而清单里的 ref 取自规范化之后的结果，两者可能差一个前缀。
  if [[ ${#RERUN_IMAGES[@]} -gt 0 ]]; then
    local joined="" part
    for ref in "${RERUN_IMAGES[@]}"; do
      part="$(ere_escape "$ref")"
      [[ -n "$joined" ]] && joined+="|"
      joined+="$part"
    done
    RERUN_FILTER="^(docker://)?(${joined})$"
  fi

  return 0
}

# 渲染「重跑失败项」这一节（markdown，写到 stdout）。
#
# 没有失败项或 dry-run 时输出空，调用方据此决定要不要写出这一节——
# 全绿不打扰。参数是标题级别：Step Summary 的顶层小节用 ###，报告 md 用 ##。
render_rerun_section() {
  local level="${1:-###}"

  if [[ ${#RERUN_IMAGES[@]} -eq 0 ]]; then
    return 0
  fi

  local n=${#RERUN_IMAGES[@]}
  local style
  style="$(rerun_style)"

  # 只有 Batch 走正则形态，且正则必须通过语法自检——拼错了宁可不给正则，
  # 也不能给一条会把作用域指偏的。其余情况一律退回清单形态。
  #
  # 这里刻意不调 validate_regex：那个函数发现非法正则时会 die，而当前只是
  # 渲染阶段，正则不可用应当降级，不该让整个运行挂掉。
  local use_filter=""
  if [[ "$style" == "filter" ]] && [[ -n "$RERUN_FILTER" ]]; then
    local code=0
    printf '' | grep -Eq -- "$RERUN_FILTER" 2>/dev/null || code=$?
    if [[ "$code" -ne 2 ]]; then
      use_filter=1
    fi
  fi

  printf '\n%s 重跑失败项\n\n' "$level"

  # 代码块围栏的反引号写在双引号格式串里并转义——写在单引号里会触发
  # SC2016（静态检查把反引号当成不会展开的表达式）。
  if [[ -n "$use_filter" ]]; then
    printf "本次有 %s 个镜像失败。复制下面的正则，粘进本工作流的 \`filter\` 输入，重新运行即可只重跑它们：\n\n" "$n"
    printf "\`\`\`\n%s\n\`\`\`\n" "$RERUN_FILTER"
  else
    printf "本次有 %s 个镜像失败。复制下面的镜像列表，粘进本工作流的 \`images_src\` 输入，重新运行即可只重跑它们：\n\n" "$n"
    printf "\`\`\`\n"
    local ref
    for ref in "${RERUN_IMAGES[@]}"; do
      printf '%s\n' "$ref"
    done
    printf "\`\`\`\n"
  fi

  if [[ "$RERUN_NOT_RERUNNABLE" -gt 0 ]]; then
    printf '\n> 另有 %s 个因镜像引用格式错误，重跑不会成功，未列入。\n' "$RERUN_NOT_RERUNNABLE"
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

  # ---- 重跑指引的聚合 ----
  # 三个消费方（Step Summary、报告 md、报告 json）共用这一份结果，所以在这里
  # 算一次，而不是各算各的——口径不一致时，页面和报告会互相矛盾。
  collect_rerun_items

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

      # 重跑指引排在耗时排行之前：失败之后最要紧的是「怎么办」，
      # 它比「哪些慢」更该先被看到。
      local rerun_md
      rerun_md="$(render_rerun_section "###")"
      if [[ -n "$rerun_md" ]]; then
        echo "$rerun_md"
      fi

      # 耗时排行。一批镜像的总耗时几乎总是被其中一两个主导——
      # 找出它们是优化同步速度的第一步，逐个翻表格反而看不出来。
      local ranking
      ranking="$(duration_ranking_rows 5)"
      if [[ -n "$ranking" ]]; then
        echo ""
        echo "### 最慢的同步记录"
        echo ""
        echo "| 耗时 | 镜像 → 目标 |"
        echo "| ---: | --- |"
        echo "$ranking"
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

    # 与 Step Summary 共用同一段渲染，避免两处各写一遍后悄悄漂移。
    # 标题级别不同：这里是报告的顶层小节（##），Summary 里是 ###。
    local rerun_md
    rerun_md="$(render_rerun_section "##")"
    if [[ -n "$rerun_md" ]]; then
      echo "$rerun_md"
    fi

    local ranking
    ranking="$(duration_ranking_rows 5)"
    if [[ -n "$ranking" ]]; then
      echo ""
      echo "## 最慢的同步记录"
      echo ""
      echo "| 耗时 | 镜像 → 目标 |"
      echo "| ---: | --- |"
      echo "$ranking"
    fi
  } > "$md"

  # json 交给 jq 构造：镜像引用可能含引号、反斜杠或控制字符（FIELD_SEP 就是
  # U+001F），手工拼接要完整实现一遍 JSON 字符串转义才可能正确。字符串用
  # --arg、数字用 --argjson 传，保住类型不被降级成 string——history.sh 的
  # map(.total) | add 依赖 number。与 write_check_report_files 同一条路径。
  local json="${REPORT_DIR}/${REPORT_NAME}.json"
  # 中间文件用 mktemp 而不是 WORK_DIR：write_report 会被单测整段抽出到独立
  # 上下文执行（见 CI 的「验证重跑指引」），那里没有 WORK_DIR，set -u 下普通
  # 展开会当场 unbound variable。自身的临时文件不该依赖运行的临时目录生命周期。
  local records_file
  records_file="$(mktemp "${TMPDIR:-/tmp}/sync-report-images.XXXXXX")"
  : > "$records_file"
  for i in "${!R_SRC[@]}"; do
    jq -n --arg source "${R_SRC[$i]}" \
          --arg dest "${R_DEST[$i]}" \
          --arg status "${R_STATUS[$i]}" \
          --arg platforms "${R_PLATFORM[$i]:-}" \
          --arg source_digest "${R_SRC_DIGEST[$i]:-}" \
          --arg dest_digest "${R_DEST_DIGEST[$i]:-}" \
          --argjson seconds "${R_SECONDS[$i]:-0}" \
      '{source:$source, dest:$dest, status:$status, platforms:$platforms,
        source_digest:$source_digest, dest_digest:$dest_digest, seconds:$seconds}' \
      >> "$records_file"
  done

  # 重跑指引的机器可读形态。无失败项时三个字段都是零值，字段本身始终存在，
  # 消费方不必判空。
  #
  # 空数组必须走 else 分支单独写：bash 3.2 + set -u 下 "空数组[@]" 的展开会抛
  # unbound variable（CI 的 bash 5 不复现，只在 macOS 自带 bash 暴露）。
  local rerun_json
  if [[ ${#RERUN_IMAGES[@]} -gt 0 ]]; then
    # 用 $ARGS.positional 而不是 $ARGS：后者是整个 {positional, named} 对象，
    # 写错会把 images 变成对象而不是字符串数组。
    rerun_json="$(jq -n --arg filter "$RERUN_FILTER" \
      --argjson not_rerunnable "$RERUN_NOT_RERUNNABLE" \
      --args '{images:$ARGS.positional, filter:$filter, not_rerunnable:$not_rerunnable}' \
      "${RERUN_IMAGES[@]}")"
  else
    rerun_json="$(jq -n --arg filter "$RERUN_FILTER" \
      --argjson not_rerunnable "$RERUN_NOT_RERUNNABLE" \
      '{images:[], filter:$filter, not_rerunnable:$not_rerunnable}')"
  fi

  # --argjson 把上一步的 JSON 文本嵌回来，jq 原样保留其结构而不会二次转义成
  # 字符串；--slurpfile 对空文件产出 [] 而不是 null。
  jq -n --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg dest "${DEST_EXACT:-${DEST_REGISTRIES[*]}}" \
    --argjson strip "$STRIP_ATTESTATION" \
    --argjson total "$total" --argjson success "$ok" \
    --argjson skipped "$skipped" --argjson failed "$fail" \
    --argjson excluded "$excluded" \
    --arg filter "$FILTER_REGEX" --arg exclude "$EXCLUDE_REGEX" \
    --argjson rerun "$rerun_json" \
    --slurpfile images "$records_file" \
    '{generated_at:$at, dest_registry:$dest, strip_attestation:$strip,
      total:$total, success:$success, skipped:$skipped, failed:$failed,
      excluded:$excluded, filter:$filter, exclude:$exclude,
      rerun:$rerun, images:$images}' > "$json"

  rm -f "$records_file"

  log_info "报告已写入：${md}"
  log_info "报告已写入：${json}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  # 环境变量作为兜底，命令行参数优先。
  #
  # CI 里尤其要用环境变量：命令行参数既对同机其他进程可见（ps aux），
  # 也容易被调用方的日志语句原样打印出去——工作流里就有一句
  # 「执行：./scripts/sync.sh ${args[*]}」。凭证不该经过那条路。
  if [[ -z "$SRC_USERNAME" && -n "${SYNC_SRC_USERNAME:-}" ]]; then
    SRC_USERNAME="$SYNC_SRC_USERNAME"
  fi
  if [[ -z "$SRC_PASSWORD" && -n "${SYNC_SRC_PASSWORD:-}" ]]; then
    SRC_PASSWORD="$SYNC_SRC_PASSWORD"
  fi
  if [[ -z "$SRC_REGISTRY" && -n "${SYNC_SRC_REGISTRY:-}" ]]; then
    SRC_REGISTRY="${SYNC_SRC_REGISTRY#docker://}"
    SRC_REGISTRY="${SRC_REGISTRY%/}"
  fi
  # SYNC_SRC_CREDENTIALS 的值是**文件内容**而非路径：CI 里 Secret 是一整段文本，
  # 落成 600 权限的临时文件再走同一条解析路径，避免为 Secret 单独开一条分支。
  # 这个临时文件同样由 cleanup() 删除。
  if [[ -z "$SRC_CREDENTIALS_FILE" && -n "${SYNC_SRC_CREDENTIALS:-}" ]]; then
    local _tmpdir="${TMPDIR:-/tmp}"
    _tmpdir="${_tmpdir%/}"
    SRC_CREDENTIALS_FILE="$(mktemp "${_tmpdir}/sync-src-cred-env.XXXXXX")" \
      || die "无法创建临时凭证文件（来自 SYNC_SRC_CREDENTIALS）"
    chmod 600 "$SRC_CREDENTIALS_FILE"
    printf '%s\n' "$SYNC_SRC_CREDENTIALS" > "$SRC_CREDENTIALS_FILE"
    # 记录这是我们自己创建的临时文件——cleanup 只删它，绝不动使用者
    # 通过 --src-credentials 指定的自有文件
    SRC_CREDENTIALS_TMPFILE="$SRC_CREDENTIALS_FILE"
  fi

  # --check-updates / --audit-lock 不碰目标仓库，因此不需要目标地址
  if [[ ${#DEST_REGISTRIES[@]} -eq 0 && -z "$DEST_EXACT" && "$CHECK_UPDATES" != "true" && -z "$AUDIT_LOCK_FILE" ]]; then
    log_error "缺少必填参数：--dest 或 --dest-exact"
    echo "" >&2
    usage >&2
    exit 1
  fi

  # 两者语义不同：--dest / --dest-keep-path 是前缀（会被拼接），
  # --dest-exact 是完整地址（不拼接）。混用时目标地址会变得含糊，宁可明确报错。
  if [[ -n "$DEST_EXACT" && ${#DEST_REGISTRIES[@]} -gt 0 ]]; then
    die "--dest-exact 不能与 --dest / --dest-keep-path 同时使用：前者指定完整目标地址，后两者是待拼接的前缀"
  fi

  validate_numeric "--concurrency" "$CONCURRENCY"
  validate_numeric "--timeout" "$TIMEOUT"
  validate_numeric "--retries" "$MAX_RETRIES"
  validate_numeric "--updates-limit" "$UPDATES_LIMIT"

  [[ "$UPDATES_LIMIT" -ge 1 ]] || die "--updates-limit 至少为 1"

  # 正则先校验再跑。写错的正则应该立刻被拒绝，而不是等收集完镜像才发现
  validate_regex "--filter" "$FILTER_REGEX"
  validate_regex "--exclude" "$EXCLUDE_REGEX"

  [[ "$CONCURRENCY" -ge 1 ]] || die "--concurrency 至少为 1"

  case "$NOTIFY_ON" in
    always|failure) ;;
    *) die "--notify-on 只能是 always 或 failure，当前为「${NOTIFY_ON}」" ;;
  esac

  validate_numeric "--notify-after-failures" "$NOTIFY_AFTER_FAILURES"
  [[ "$NOTIFY_AFTER_FAILURES" -ge 1 ]] || die "--notify-after-failures 至少为 1（1 = 每次失败都通知）"

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

  # ---- 只读检查的参数约束 ----
  # 三个检查的对象不同（目标仓库 / 上游 tag 列表 / 锁文件时效），报告是三套，
  # 混着跑会互相淹没。都要的话跑三次就好——这类检查本来就该是随手能跑的命令。
  if [[ "$AUDIT" == "true" && "$CHECK_UPDATES" == "true" ]]; then
    die "--audit 与 --check-updates 不能同时使用：前者看目标仓库与清单的差距，后者看上游与清单的差距，请分两次运行"
  fi
  if [[ -n "$AUDIT_LOCK_FILE" && "$CHECK_UPDATES" == "true" ]]; then
    die "--audit-lock 与 --check-updates 不能同时使用：前者校验锁定的 digest 是否仍然有效，后者列举上游未收录的 tag，请分两次运行"
  fi
  if [[ -n "$AUDIT_LOCK_FILE" && "$AUDIT" == "true" ]]; then
    die "--audit-lock 与 --audit 不能同时使用：前者以锁文件为基准查上游，后者以源镜像为基准查目标仓库，请分两次运行"
  fi

  # --audit-lock 自带条目来源，不允许再混入 --src / --file，否则「校验哪些」
  # 变成两份清单的并集，语义只能靠猜
  if [[ -n "$AUDIT_LOCK_FILE" && ( ${#SOURCE_IMAGES[@]} -gt 0 || ${#SOURCE_FILES[@]} -gt 0 ) ]]; then
    die "--audit-lock 自带校验清单，不要再同时使用 --src / --file"
  fi

  if [[ "$CHECK_UPDATES" == "true" ]]; then
    local -a upd_ignored=()
    if [[ "$DRY_RUN" == "true" ]]; then upd_ignored+=("--dry-run"); fi
    if [[ -n "$WRITE_LOCK" ]]; then upd_ignored+=("--write-lock"); fi
    # --notify-webhook 在检查模式下是生效的（见 send_check_notification），
    # 但「连续失败次数」这个概念在检查里不存在，只有同步才有
    if [[ "$NOTIFY_AFTER_FAILURES_EXPLICIT" == "true" ]]; then
      upd_ignored+=("--notify-after-failures")
    fi
    if [[ "$VERIFY" == "true" ]]; then upd_ignored+=("--verify"); fi
    if [[ "$SKIP_EXISTING" == "true" ]]; then upd_ignored+=("--skip-existing"); fi
    if [[ "$STRIP_ATTESTATION" == "true" ]]; then upd_ignored+=("--strip-attestation"); fi
    if [[ ${#DEST_REGISTRIES[@]} -gt 0 ]]; then upd_ignored+=("目标地址（--dest / --dest-keep-path）"); fi
    if [[ -n "$DEST_EXACT" ]]; then upd_ignored+=("--dest-exact"); fi
    # 并发与超时是给搬运用的；列 tag 是一次轻量查询，串行足够
    if [[ "$CONCURRENCY" != "1" ]]; then upd_ignored+=("--concurrency"); fi
    if [[ "$TIMEOUT" != "600" ]]; then upd_ignored+=("--timeout"); fi
    if [[ ${#upd_ignored[@]} -gt 0 ]]; then
      log_warn "--check-updates 只查上游，以下参数本次不生效：${upd_ignored[*]}"
    fi
  fi

  # ---- 审计模式的参数约束 ----
  if [[ "$AUDIT" == "true" ]]; then
    # 剔除 attestation 会重建索引，目标的平台摘要必然与源不同。继续跑只会得到
    # 一排假的「落后」——比报错更糟：它会让人去排查一个并不存在的问题。
    if [[ "$STRIP_ATTESTATION" == "true" ]]; then
      die "--audit 与 --strip-attestation 不能同时使用：剔除 attestation 会重建索引，目标的平台摘要必然与源不同，审计只会给出一排假的「落后」"
    fi

    # 审计不推送、不写文件、不通知，这些参数到了这里没有作用。
    # 「参数被接受却不生效」比直接报错更危险——它让人对系统行为产生错误认知，
    # 所以显式传入了就必须说出来。
    local -a ignored=()
    if [[ "$DRY_RUN" == "true" ]]; then ignored+=("--dry-run"); fi
    if [[ -n "$WRITE_LOCK" ]]; then ignored+=("--write-lock"); fi
    # --notify-webhook 在审计模式下是生效的（见 send_check_notification）
    if [[ "$NOTIFY_AFTER_FAILURES_EXPLICIT" == "true" ]]; then
      ignored+=("--notify-after-failures")
    fi
    if [[ "$VERIFY" == "true" ]]; then ignored+=("--verify"); fi
    if [[ "$SKIP_EXISTING" == "true" ]]; then ignored+=("--skip-existing"); fi
    if [[ ${#ignored[@]} -gt 0 ]]; then
      log_warn "--audit 是只读检查，以下参数本次不生效：${ignored[*]}"
    fi
  fi

  # ---- 锁文件校验的参数约束 ----
  if [[ -n "$AUDIT_LOCK_FILE" ]]; then
    if [[ ! -f "$AUDIT_LOCK_FILE" ]]; then
      die "锁文件不存在：${AUDIT_LOCK_FILE}"
    fi

    local -a lock_ignored=()
    if [[ "$DRY_RUN" == "true" ]]; then lock_ignored+=("--dry-run"); fi
    if [[ -n "$WRITE_LOCK" ]]; then lock_ignored+=("--write-lock"); fi
    if [[ "$NOTIFY_AFTER_FAILURES_EXPLICIT" == "true" ]]; then lock_ignored+=("--notify-after-failures"); fi
    if [[ "$VERIFY" == "true" ]]; then lock_ignored+=("--verify"); fi
    if [[ "$SKIP_EXISTING" == "true" ]]; then lock_ignored+=("--skip-existing"); fi
    if [[ "$STRIP_ATTESTATION" == "true" ]]; then lock_ignored+=("--strip-attestation"); fi
    if [[ -n "$FILTER_REGEX" || -n "$EXCLUDE_REGEX" ]]; then lock_ignored+=("--filter / --exclude"); fi
    if [[ ${#DEST_REGISTRIES[@]} -gt 0 ]]; then lock_ignored+=("目标地址（--dest / --dest-keep-path）"); fi
    if [[ -n "$DEST_EXACT" ]]; then lock_ignored+=("--dest-exact"); fi
    if [[ ${#lock_ignored[@]} -gt 0 ]]; then
      log_warn "--audit-lock 只校验锁文件，以下参数本次不生效：${lock_ignored[*]}"
    fi
  fi

  ensure_skopeo
  ensure_jq
  setup_timeout
  if [[ "$STRIP_ATTESTATION" == "true" ]]; then
    ensure_regctl
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "dry-run 模式：输出同步计划与命令，不会推送任何镜像"
  fi

  if [[ -n "$AUDIT_LOCK_FILE" ]]; then
    # 锁文件校验自带条目来源。SOURCE_IMAGES 也从锁文件填充：
    # 私有上游的凭证要从里面推导 host，走的是同一条装载路径
    parse_lockfile "$AUDIT_LOCK_FILE"
    local li
    for li in "${!L_REF[@]}"; do
      SOURCE_IMAGES+=("${L_REF[$li]%%@*}")
    done
  else
    collect_images
    # 筛选放在 collect_images 之后、其余校验之前：
    # --dest-exact 要求「只有一个源镜像」，而筛选后的数量才是有意义的数量
    apply_filters
  fi
  # 凭证依赖最终的镜像列表（未指定 --src-registry 时要从里面推导 host），
  # 因此放在筛选之后——被筛掉的镜像不该影响凭证要发给谁
  setup_src_auth

  # 这里看的是「筛选之后」的数量：--dest-exact 的约束来自多个镜像会撞到
  # 同一个目标地址，而筛掉之后只剩一个就不会撞
  local active_count
  active_count=$((${#SOURCE_IMAGES[@]} - FILTERED_OUT_COUNT))

  if [[ -n "$DEST_EXACT" && "$active_count" -gt 1 && "$CHECK_UPDATES" != "true" && -z "$AUDIT_LOCK_FILE" ]]; then
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
  local action="同步"
  local verb="推送到"
  if [[ "$AUDIT" == "true" ]]; then
    action="审计"
    verb="检查"
  fi

  if [[ "$CHECK_UPDATES" == "true" ]]; then
    log_info "待检查镜像 ${total} 个（只查上游 tag，不需要目标地址）"
  elif [[ -n "$AUDIT_LOCK_FILE" ]]; then
    log_info "待校验锁文件条目 ${total} 个（${AUDIT_LOCK_FILE}）"
  elif [[ -n "$DEST_EXACT" ]]; then
    log_info "待${action}镜像 ${total} 个 → ${DEST_EXACT}"
  else
    log_info "待${action}镜像 ${total} 个 → ${DEST_REGISTRIES[*]}"
    if [[ ${#DEST_REGISTRIES[@]} -gt 1 ]]; then
      log_info "共 ${#DEST_REGISTRIES[@]} 个目标，每个镜像都会${verb}全部目标"
    fi
  fi
  if [[ "$CONCURRENCY" -gt 1 ]]; then
    log_info "并发度：${CONCURRENCY}"
  fi

  WORK_DIR="$(mktemp -d)"
  # 用函数而不是内联字符串：退出时要清理的不止 WORK_DIR（还有源仓库认证文件），
  # 写成函数后新增清理项只改 cleanup 一处，不必再核对这行的展开时机
  trap cleanup EXIT

  if [[ "$DRY_RUN" == "true" && "$AUDIT" != "true" && "$CHECK_UPDATES" != "true" && -z "$AUDIT_LOCK_FILE" ]]; then
    print_dry_run_plan "$active_count"
  fi

  local start end check_rc=0
  start="$(date +%s)"
  if [[ -n "$AUDIT_LOCK_FILE" ]]; then
    dispatch_audit_lock
  elif [[ "$AUDIT" == "true" ]]; then
    dispatch_audit
  elif [[ "$CHECK_UPDATES" == "true" ]]; then
    # 接住退出码再放行：set -e 下它会直接结束脚本，连总耗时都打不出来
    set +e
    check_updates_all
    check_rc=$?
    set -e
  else
    dispatch_all
  fi
  end="$(date +%s)"
  log_info "总耗时：$((end - start)) 秒"

  # 各模式的报告是分开的：状态值域不同，汇总方式与退出码也不同
  if [[ -n "$AUDIT_LOCK_FILE" ]]; then
    load_lock_results
    emit_lock_summary
    return $?
  fi
  if [[ "$AUDIT" == "true" ]]; then
    load_audit_results
    emit_audit_summary
    return $?
  fi
  if [[ "$CHECK_UPDATES" == "true" ]]; then
    # 结果已经直接输出，这里只需把退出码带出去
    return "$check_rc"
  fi

  load_results
  emit_summary
}

main "$@"
