# GitHub Actions 与供应链基线

改 `.github/workflows/**` 之前读这里。基线一旦建立就不许在后续改动中回退——
zizmor 在 CI 里盯着，但它不是万能的。

## Pre-Development Checklist

1. 本页全部条目
2. 修改工具的选择（见下「YAML 编辑规则」）

## 供应链基线（对标 OSSF Scorecard）

- **`uses:` 一律 pin 到 commit SHA**，注释保留版本号（`actions/checkout@<40位SHA> # v7`）。
  tag 可移动而 SHA 不可。查 SHA：`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`
- **所有 checkout 加 `persist-credentials: false`**——GITHUB_TOKEN 不残留在 runner 上
- **每个工作流显式声明最小 `permissions`**，绝不放任仓库默认（宽）权限
- **zizmor 基线 0 findings**。豁免集中在 `.github/zizmor.yml`，**每条豁免必须写明可验证的安全依据**（如 pull_request_target 但不 checkout PR 代码）
- Dependabot 每周更新 Actions，带 7 天 cooldown（新版本有 bug 时冷却期让它先暴露）

## 红线（任何时候不得违反，来自 docs/MAINTAINER_GUIDE.md）

- **不给同步/检查工作流加自动触发器**（`schedule` 等）——同步与「什么时候访问上游」都必须显式触发；需要定时的使用者 fork 后自行加
- **`${{ }}` 表达式不直接写进 `run:`**——一律经 `env:` 中转（表达式注入）。参考 `check-registry.yml` 的写法
- 不在日志中输出 Secret；webhook URL 视同凭证
- 不弱化 `pull_request_target` 的安全性：任何 checkout PR 代码的场景禁止使用它

## YAML 编辑规则（按修改对象选工具）

- **无结构的简单替换**（如把 `@v7` 换成 `@<sha>`）→ 脚本批量安全
- **涉及缩进/块结构的插入**（如给 step 加 `with:`）→ **逐个手工做**。批量脚本曾连续三次算错 `with:` 与 `uses:` 的层级关系弄坏 YAML
- **heredoc 内容必须跟着 block scalar 的缩进走**——`run: |` 里的 heredoc 结束符也要缩进，否则 YAML 解析坏掉
- 每次改完工作流：跑 `./scripts/lint.sh`——**zizmor 已在其中**（docker + `ci.yml` 里 pin 的
  那个版本，版本从 `ci.yml` 抽，不另写一份；基线 0 findings，豁免集中在 `.github/zizmor.yml`）。
  单独跑同一件事才是：
  `docker run --rm -v "$PWD":/repo:ro ghcr.io/zizmorcore/zizmor:<与 ci.yml 一致的版本> /repo --no-online-audits`

## CI 结构（ci.yml）

- 检查项：actionlint / yamllint / shellcheck / zizmor / **lint.sh 自测** / 冒烟 / **真实同步集成测试** / 提交信息校验
- **ci-summary 汇总 job**：`needs: [全部]` + `if: always()`——分支保护只盯「CI 总览」这一个 check，增删检查项不用改保护规则
- **新增检查项时要改三处，不是一处**：`needs`、汇总步骤里的 `names` 数组、`results` 数组。三者靠**下标对齐**，只改 `needs` 时那一项**不进判据**——它失败了本 job 仍绿，而界面上只表现为汇总表少一行（2026-09-24 加 lint-selftest 时真实踩到，且当时以为「加了 needs 就完事」）。汇总步骤里已加一条**长度一致性自断言**兜住这个坑；`names` 里的名字**含空格必须加引号**，否则会被拆成两个元素、后面全部错位
- **集成测试用本地 `registry:2` 容器真推送**：dry-run 覆盖不到真实路径，v1.1.0 的三个缺陷全部发生在那里。新功能必须在这里补真实路径断言
- 断言写法：**不要 grep 状态词本身**——汇总行里状态词永远在（如「缺失 0」），等于断言恒真。匹配带图标的正文行（`✗ 缺失`）或断言具体数值
- 「故意要失败的命令」必须包在 `set +e` / `set -e` 之间，否则 errexit 会在断言前中断步骤
- 跨步骤复用文件用 `/tmp` 固定路径——每个 `run:` 是独立 shell，变量不延续
- **加自断言前先确认那个 job 有没有 checkout**。`ci-summary` 就**没有**——它只读 `needs.*.result`，跑在自己的空工作目录里。2026-09-24 真实踩到：给它加了「读 `ci.yml` 数 `needs` 项数」的自断言，CI 上直接报
  `grep: .github/workflows/ci.yml: No such file or directory` → `needs（0 项）与 names（8 项）数量不一致`，
  把一个全绿的 PR 拖红。**没有 checkout 的 job，断言只能基于环境变量与 `needs.*`**

## Quality Check

- [ ] `./scripts/lint.sh` 全绿
- [ ] 新增 `uses:` pin 到 SHA；checkout 带 `persist-credentials: false`
- [ ] zizmor 0 findings
- [ ] 新的 CI 断言先在本地复现过
