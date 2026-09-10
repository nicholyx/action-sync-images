#!/usr/bin/env bash
#
# lint.sh —— 本地统一校验入口
#
# 一条命令跑完 CI 中执行的全部静态检查。提交 PR 之前跑一次，
# 可以把「推上去 → CI 红 → 改了再推」这个来回省掉。
#
# 用法：
#   ./scripts/lint.sh             # 跑全部检查
#   ./scripts/lint.sh --fix-hint  # 失败时额外给出修复建议
#
# 缺失的工具会被跳过并提示安装方式，不会让整个检查中断。

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

# 工具不存在时给出安装指引并跳过，而不是让整个脚本崩掉
skip_check() {
  local name="$1" hint="$2"
  printf '\n%s▶ %s%s\n' "$C_BOLD" "$name" "$C_RESET"
  printf '  %s⚠ 已跳过：未安装对应工具%s\n' "$C_YELLOW" "$C_RESET"
  printf '  %s  安装方式：%s%s\n' "$C_YELLOW" "$hint" "$C_RESET"
  SKIPPED=$((SKIPPED + 1))
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
  skip_check "actionlint（工作流静态检查）" \
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
  skip_check "yamllint（YAML 风格）" "brew install yamllint  或  pipx install yamllint"
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
  skip_check "shellcheck（Shell 脚本）" "brew install shellcheck"
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

printf '\n%s✓ 全部检查通过，可以放心提交。%s\n' "$C_GREEN" "$C_RESET"
