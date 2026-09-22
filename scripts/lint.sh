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
# ---------------------------------------------------------------------------
if command -v actionlint >/dev/null 2>&1; then
  run_check "actionlint（工作流静态检查）" actionlint -color -ignore 'SC2086'
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
  run_check "$ZIZMOR_NAME" zizmor . --no-online-audits
  # 这条结论的价值全在「与 CI 同源」上，而这条路径恰恰不同源——所以把两边的版本
  # 都摆出来，让读的人自己判断，而不是只说一句「可能有出入」就过去。
  note "本机没有 docker，退而用本机 zizmor（$(zizmor --version 2>/dev/null | head -n 1)）；"
  note "CI 在 ci.yml 里 pin 的是 ${ZIZMOR_IMAGE:-未取到}；两者不一致时，本项的通过不等于 CI 的通过。"
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
