#!/usr/bin/env bash
#
# lint.sh —— 本地统一校验入口
#
# 一条命令跑完 CI 里**本地能跑**的那些静态检查：actionlint、yamllint、shellcheck、
# bash -n、zizmor（工作流安全扫描）。提交 PR 之前跑一次，
# 可以把「推上去 → CI 红 → 改了再推」这个来回省掉。
#
# 用法：
#   ./scripts/lint.sh             # 跑全部检查
#   ./scripts/lint.sh --fix-hint  # 失败时额外给出修复建议
#
# 覆盖范围（别把它当成 CI 的替代品）：
#   - 覆盖：actionlint、yamllint、shellcheck、bash -n、zizmor
#   - **不覆盖：提交信息规范**。CI 的 commit-messages job 校验 PR 里的提交与
#     **PR 标题**，而标题在 PR 建立之前根本不存在——本地任何入口都验不了它。
#     本地全绿不等于 commit-messages 会绿，PR 标题仍需自己按规范写
#   - zizmor 用 docker 跑，镜像版本从 .github/workflows/ci.yml 抽出（与 CI 同源）；
#     本机没有 docker 时退化为本机 zizmor，版本未必与 CI 对齐
#
# smoke-test / integration-test 两个 job 不是静态检查，且依赖网络与容器，
# 不在这里复现。
#
# 缺失的工具会被跳过并提示安装方式，不会让整个检查中断；跳过项一律显式列出，
# 不会被算作通过。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

cd "$PROJECT_ROOT"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

PASSED=0
FAILED=0
SKIPPED=0
declare -a FAILED_NAMES=()
# 跑了、但**不是 CI 同源**的项。它们的「通过」与 CI 的通过可信度不同，而三计数
# 分不出来（都计在 PASSED 里）——所以单独记下来，在结尾一并列出。
# 判据是「这一项的结论与 CI 用的是不是同一套工具/规则」，不是「它有没有跑成」。
declare -a NONSYNC_NOTES=()

# 执行一项检查。$1 是显示名，其余是命令。
run_check() {
  local name="$1"; shift
  printf '\n%s▶ %s%s\n' "$C_BOLD" "$name" "$C_RESET"
  printf '  %s$ %s%s\n' "$C_BLUE" "$*" "$C_RESET"

  if "$@"; then
    printf '  %s✓ 通过%s\n' "$C_GREEN" "$C_RESET"
    PASSED=$((PASSED + 1))
  else
    printf '  %s✗ 失败%s\n' "$C_RED" "$C_RESET"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
  fi
}

# 跳过一项检查并说明原因，而不是让整个脚本崩掉。
# $1 显示名，$2 跳过原因（工具没装 / 本环境下无从比较），$3 可选的安装方式。
skip_check() {
  local name="$1" reason="$2" hint="${3:-}"
  printf '\n%s▶ %s%s\n' "$C_BOLD" "$name" "$C_RESET"
  printf '  %s⚠ 已跳过：%s%s\n' "$C_YELLOW" "$reason" "$C_RESET"
  if [[ -n "$hint" ]]; then
    printf '  %s  安装方式：%s%s\n' "$C_YELLOW" "$hint" "$C_RESET"
  fi
  SKIPPED=$((SKIPPED + 1))
}

# 记一次失败。用于「工具在、但这一项根本没法跑成」的情形——它和「工具不在」
# 是两回事，跳过会把问题藏起来（照项目原则：无法判定要单独成类，不能冒充正常）。
fail_check() {
  local name="$1" reason="$2" hint="${3:-}"
  printf '\n%s▶ %s%s\n' "$C_BOLD" "$name" "$C_RESET"
  printf '  %s✗ 失败：%s%s\n' "$C_RED" "$reason" "$C_RESET"
  if [[ -n "$hint" ]]; then
    printf '  %s  %s%s\n' "$C_RED" "$hint" "$C_RESET"
  fi
  FAILED=$((FAILED + 1))
  FAILED_NAMES+=("$name")
}

# 跟在某项检查后面交代它的边界（不影响计数）
note() {
  printf '  %sⓘ %s%s\n' "$C_BLUE" "$1" "$C_RESET"
}

printf '%s' "$C_BOLD"
cat <<'BANNER'
╭──────────────────────────────────────────────╮
│  action-sync-images · 本地静态检查           │
╰──────────────────────────────────────────────╯
BANNER
printf '%s' "$C_RESET"

# ---------------------------------------------------------------------------
# 1. actionlint —— 工作流语法与常见陷阱
#    它同时会调用 shellcheck 检查 run: 里的 Shell 片段
#
#    **显式传工作流文件列表，不裸跑。** 裸跑时 actionlint 要靠 .git 定位项目根，
#    而在不含 .git 的目录（典型场景：GitHub 的 source tarball 解压出来）里会直接
#    报「no project was found in any parent directories of …」——使用者什么都没改，
#    第一项就红。显式给文件则不必依赖 git，两种目录下都真跑。
#
#    目标集**不能**复用 YAML_TARGETS：那个收的是 .github 下全部 yml/yaml
#    （yamllint 需要那些），而 dependabot.yml / labeler.yml / ISSUE_TEMPLATE/*.yml
#    都不是工作流，喂给 actionlint 会报「"jobs" section is missing in workflow」。
#    这里说的 labeler.yml 是 .github/ 下那个；.github/workflows/labeler.yml 是工作流，要收。
#    这里只收 .github/workflows/ 下的——两个目标集不同，别合并。
#
#    目标文件集与规则集都同 CI 的 `./actionlint -color` 一致（CI 那边不传文件，
#    靠项目根自动发现同一批文件——实测含子目录也一致）：
#    本地过要真的等于 CI 过，所以不再屏蔽任何规则——此前被屏蔽的 SC2086
#    正是「本地不报、CI 报」的来源（#133）。
# ---------------------------------------------------------------------------
WORKFLOW_TARGETS=()
while IFS= read -r f; do
  WORKFLOW_TARGETS+=("$f")
done < <(find .github/workflows -name '*.yml' -o -name '*.yaml' 2>/dev/null | sort)

if command -v actionlint >/dev/null 2>&1; then
  if [[ ${#WORKFLOW_TARGETS[@]} -gt 0 ]]; then
    run_check "actionlint（工作流静态检查）" actionlint -color "${WORKFLOW_TARGETS[@]}"
  else
    # 列表为空意味着这一项根本没跑成。不能悄悄放过：它会和「检查通过」长得一样，
    # 而使用者以为 CI 里那一项已经在本地说过了（照同文件 zizmor 的既有处理）。
    fail_check "actionlint（工作流静态检查）" "没有找到任何工作流文件（.github/workflows/*.yml）" \
      "actionlint 拿不到文件就不会检查任何东西——这一项此时与跳过无异，但读者会以为它跑过了。"
  fi
else
  skip_check "actionlint（工作流静态检查）" "未安装对应工具" \
    "brew install actionlint  或  go install github.com/rhysd/actionlint/cmd/actionlint@latest"
fi

# ---------------------------------------------------------------------------
# 2. yamllint —— YAML 风格
# ---------------------------------------------------------------------------
YAML_TARGETS=()
while IFS= read -r f; do
  YAML_TARGETS+=("$f")
done < <(find .github -name '*.yml' -o -name '*.yaml' 2>/dev/null | sort)

if command -v yamllint >/dev/null 2>&1; then
  if [[ ${#YAML_TARGETS[@]} -gt 0 ]]; then
    run_check "yamllint（YAML 风格）" yamllint -c .yamllint "${YAML_TARGETS[@]}"
  fi
else
  skip_check "yamllint（YAML 风格）" "未安装对应工具" "brew install yamllint  或  pipx install yamllint"
fi

# ---------------------------------------------------------------------------
# 3. shellcheck —— Shell 脚本
# ---------------------------------------------------------------------------
SH_TARGETS=()
while IFS= read -r f; do
  SH_TARGETS+=("$f")
done < <(find scripts -name '*.sh' 2>/dev/null | sort)

if command -v shellcheck >/dev/null 2>&1; then
  if [[ ${#SH_TARGETS[@]} -gt 0 ]]; then
    run_check "shellcheck（Shell 脚本）" shellcheck -x "${SH_TARGETS[@]}"
  fi
else
  skip_check "shellcheck（Shell 脚本）" "未安装对应工具" "brew install shellcheck"
fi

# ---------------------------------------------------------------------------
# 4. bash 语法检查 —— 不依赖任何外部工具，永远会跑
# ---------------------------------------------------------------------------
if [[ ${#SH_TARGETS[@]} -gt 0 ]]; then
  for f in "${SH_TARGETS[@]}"; do
    run_check "bash -n（${f}）" bash -n "$f"
  done
fi

# ---------------------------------------------------------------------------
# 5. zizmor —— 工作流安全扫描（对应 CI 的 zizmor job）
#
#    镜像引用从 ci.yml 抽，不写第二份：写死会在 CI 升级时静默漂移，
#    而这一项的全部价值就是「本地过 = CI 过」。
#    没有 docker 时退化为本机 zizmor（版本未必与 CI 对齐，会提示）；
#    两者都没有才跳过。
# ---------------------------------------------------------------------------
ZIZMOR_NAME="zizmor（工作流安全扫描）"

# grep -o 找不到匹配时退出码是 1，set -e 下会让脚本当场退出，所以显式接住
ZIZMOR_REFS="$(grep -o 'ghcr\.io/zizmorcore/zizmor:[^[:space:]]*' .github/workflows/ci.yml 2>/dev/null)" || ZIZMOR_REFS=""
ZIZMOR_IMAGE="${ZIZMOR_REFS%%$'\n'*}"

if command -v docker >/dev/null 2>&1; then
  if [[ -z "$ZIZMOR_IMAGE" ]]; then
    fail_check "$ZIZMOR_NAME" "没能从 .github/workflows/ci.yml 里取到 zizmor 镜像版本" \
      "这一项靠「与 CI 同源」才有意义，取不到版本就不该随便挑一个来跑。"
  else
    # 与 CI 完全同一条命令，只是把容器里的 /repo 换成本地目录
    run_check "$ZIZMOR_NAME" docker run --rm -v "$PWD":/repo:ro \
      "$ZIZMOR_IMAGE" /repo --no-online-audits
  fi
elif command -v zizmor >/dev/null 2>&1; then
  local_zizmor_version="$(zizmor --version 2>/dev/null | head -n 1)"
  run_check "$ZIZMOR_NAME" zizmor . --no-online-audits
  # 这条结论的价值全在「与 CI 同源」上，而这条路径恰恰不同源——所以把两边的版本
  # 都摆出来，让读的人自己判断，而不是只说一句「可能有出入」就过去。
  note "本机没有 docker，退而用本机 zizmor（${local_zizmor_version}）；"
  note "CI 在 ci.yml 里 pin 的是 ${ZIZMOR_IMAGE:-未取到}；两者不一致时，本项的通过不等于 CI 的通过。"
  # 记进 NONSYNC_NOTES：上面两条 note 打在 zizmor 那一段，是否被读到取决于读者
  # 有没有翻到那里；而结尾才是人真正会看的地方（Issue #139）。
  NONSYNC_NOTES+=("zizmor（本机 ${local_zizmor_version}，CI pin ${ZIZMOR_IMAGE:-未取到}）")
else
  skip_check "$ZIZMOR_NAME" "未安装 docker，本机也没有 zizmor" \
    "安装 Docker（CI 就是用 docker 跑 zizmor，本项依赖它），或 brew install zizmor"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n%s──────────────────────────────────────────────%s\n' "$C_BOLD" "$C_RESET"
printf '通过 %s%d%s · 失败 %s%d%s · 跳过 %s%d%s\n' \
  "$C_GREEN" "$PASSED" "$C_RESET" \
  "$C_RED" "$FAILED" "$C_RESET" \
  "$C_YELLOW" "$SKIPPED" "$C_RESET"

# 非 CI 同源的项单独列一遍。它们被计在「通过」里——三计数分不出来，而两者的
# 可信度不同。上面的 note 打在各自那一段，是否被读到取决于读者有没有翻到那里；
# 这里是人真正会看的位置。**不改三计数**：那是结构改动，与本条要解决的问题不成比例。
if [[ ${#NONSYNC_NOTES[@]} -gt 0 ]]; then
  printf '\n%s本次有 %d 项不是 CI 同源，其「通过」不等于 CI 的通过：%s\n' \
    "$C_YELLOW" "${#NONSYNC_NOTES[@]}" "$C_RESET"
  for _n in "${NONSYNC_NOTES[@]}"; do
    printf '  • %s\n' "$_n"
  done
fi

if [[ "$FAILED" -gt 0 ]]; then
  printf '\n%s以下检查未通过：%s\n' "$C_RED" "$C_RESET"
  for n in "${FAILED_NAMES[@]}"; do
    printf '  • %s\n' "$n"
  done
  printf '\n%s提示：%s大部分问题根据报错信息即可直接定位。\n' "$C_YELLOW" "$C_RESET"
  printf '      YAML 缩进问题可参考 .editorconfig（统一 2 空格）。\n'
  exit 1
fi

printf '\n%s✓ 以上检查全部通过。%s\n' "$C_GREEN" "$C_RESET"
printf '%s  注意：提交信息规范不在其中——CI 的 commit-messages job 校验 PR 标题，%s\n' "$C_YELLOW" "$C_RESET"
printf '        而标题在 PR 建立之前不存在，本地无从验证。PR 标题请按规范写。\n'
