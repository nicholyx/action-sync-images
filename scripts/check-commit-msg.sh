#!/usr/bin/env bash
#
# check-commit-msg.sh —— 约定式提交信息校验
#
# 用于 CI 与本地 git hook。项目所有提交必须遵循 Conventional Commits：
#   <类型>(<范围>): <描述>
#
# 用法：
#   ./scripts/check-commit-msg.sh --message "feat(aliyuncs): 支持批量同步"
#   ./scripts/check-commit-msg.sh --file .git/COMMIT_EDITMSG
#   ./scripts/check-commit-msg.sh --range origin/main..HEAD
#   ./scripts/check-commit-msg.sh --last                # 只查最近一次提交
#
# 退出码：0 全部合规，1 存在不合规的提交信息

set -euo pipefail

# 允许的类型，与 CONTRIBUTING.md 中的表格保持一致
readonly ALLOWED_TYPES='feat|fix|docs|ci|chore|refactor|perf|test|style|revert|build'

# <类型>[(<范围>)][!]: <描述>
# 范围限定为小写字母、数字、点、下划线、斜杠、连字符
readonly PATTERN="^(${ALLOWED_TYPES})(\([a-z0-9._/-]+\))?!?: .+"

MODE=""
VALUE=""

usage() {
  cat <<EOF
check-commit-msg.sh —— 校验提交信息是否符合约定式提交规范

用法：
  --message <文本>     校验一段提交信息
  --file <路径>        校验文件内容（配合 git 的 commit-msg hook）
  --range <区间>       校验一个提交区间，例如 origin/main..HEAD
  --last               校验最近一次提交
  -h, --help           显示帮助

合规示例：
  feat(aliyuncs): 支持一次同步多个镜像
  fix(harbor): 补上 --all 避免丢失 arm64 平台
  docs: 补充 ALIYUNCS_REGISTRY 的配置说明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) MODE="message"; VALUE="${2:?--message 需要参数}"; shift 2 ;;
    --file)    MODE="file";    VALUE="${2:?--file 需要参数}";    shift 2 ;;
    --range)   MODE="range";   VALUE="${2:?--range 需要参数}";   shift 2 ;;
    --last)    MODE="range";   VALUE="HEAD~1..HEAD";             shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  usage >&2
  exit 1
fi

# 这些提交信息无需遵循规范，直接放行：
#   - merge：由 git 自动生成的合并提交
#   - revert：git revert 生成的固定格式
#   - fixup!/squash!：交互式 rebase 的中间产物
#   - 以 # 开头：git 的注释行
should_skip() {
  local subject="$1"
  [[ -z "$subject" ]] && return 0
  [[ "$subject" == Merge\ * ]] && return 0
  [[ "$subject" == Revert\ * ]] && return 0
  [[ "$subject" == fixup!* ]] && return 0
  [[ "$subject" == squash!* ]] && return 0
  [[ "$subject" == \#* ]] && return 0
  return 1
}

FAILED_COUNT=0
CHECKED_COUNT=0

check_one() {
  local subject="$1"

  if should_skip "$subject"; then
    printf '  \033[2m跳过（无需校验）\033[0m %s\n' "$subject"
    return 0
  fi

  CHECKED_COUNT=$((CHECKED_COUNT + 1))

  if [[ "$subject" =~ $PATTERN ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$subject"
    return 0
  fi

  FAILED_COUNT=$((FAILED_COUNT + 1))
  printf '  \033[31m✗\033[0m %s\n' "$subject"

  # 给出针对性的原因，而不是甩一句「格式错误」。
  # 判断顺序很重要：先定位类型部分的问题，再定位冒号与描述的问题，
  # 否则「Feat: xxx」会被误报成「类型缺失」。
  local lower
  lower="$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')"

  if [[ ! "$subject" =~ ^(${ALLOWED_TYPES})(\(|!|:) ]]; then
    if [[ "$lower" =~ ^(${ALLOWED_TYPES})(\(|!|:) ]]; then
      printf '      \033[33m→ 类型必须小写，应写作「%s」。\033[0m\n' "${lower%%[(!:]*}"
    elif [[ "$subject" =~ ^([A-Za-z]+) ]]; then
      printf '      \033[33m→ 类型「%s」不在允许列表内。\033[0m\n' "${BASH_REMATCH[1]}"
      printf '        允许的类型：feat fix docs ci chore refactor perf test style revert build\n'
    else
      printf '      \033[33m→ 缺少类型前缀。\033[0m\n'
      printf '        允许的类型：feat fix docs ci chore refactor perf test style revert build\n'
    fi
  elif [[ "$subject" != *": "* ]]; then
    printf '      \033[33m→ 冒号后面需要有一个空格，应写作「…: 描述」。\033[0m\n'
  else
    printf '      \033[33m→ 格式应为：<类型>(<范围>): <描述>\033[0m\n'
  fi
  return 1
}

printf '\n\033[1m校验提交信息\033[0m\n'

case "$MODE" in
  message)
    check_one "$VALUE" || true
    ;;
  file)
    [[ -f "$VALUE" ]] || { echo "文件不存在：$VALUE" >&2; exit 1; }
    # 只取第一行（标题行），忽略注释
    subject="$(head -n 1 "$VALUE" | sed 's/[[:space:]]*$//')"
    check_one "$subject" || true
    ;;
  range)
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "当前目录不是 git 仓库" >&2
      exit 1
    fi
    while IFS= read -r subject; do
      check_one "$subject" || true
    done < <(git log --format='%s' "$VALUE" 2>/dev/null)
    ;;
esac

printf '\n'
if [[ "$FAILED_COUNT" -gt 0 ]]; then
  printf '\033[31m%d 条不合规\033[0m（共检查 %d 条）\n\n' "$FAILED_COUNT" "$CHECKED_COUNT"
  cat <<'EOF'
示例：
  feat(aliyuncs): 支持一次同步多个镜像
  fix(harbor): 补上 --all 避免丢失 arm64 平台
  docs: 补充 ALIYUNCS_REGISTRY 的配置说明
  ci: 引入 actionlint 静态检查工作流

详见 CONTRIBUTING.md 的「提交信息规范」一节。
EOF
  exit 1
fi

printf '\033[32m全部合规\033[0m（共检查 %d 条）\n' "$CHECKED_COUNT"
