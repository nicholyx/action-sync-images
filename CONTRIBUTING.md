# 贡献指南

感谢你愿意为 `action-sync-images` 投入时间！无论是报 bug、补文档还是提代码，都是对这个项目的帮助。

本文档面向所有想参与的人，**不需要你是 GitHub Actions 专家**。如果你在任何一个环节卡住了，直接在 Issue 里问，这本身就是一种贡献。

---

## 目录

- [行为准则](#行为准则)
- [我能贡献什么](#我能贡献什么)
- [报告问题](#报告问题)
- [提交代码](#提交代码)
- [提交信息规范](#提交信息规范)
- [分支与合并策略](#分支与合并策略)
- [开发环境准备](#开发环境准备)
- [本地验证工作流](#本地验证工作流)
- [代码风格要求](#代码风格要求)
- [Review 流程](#review-流程)
- [发布流程](#发布流程)

---

## 行为准则

参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。请在所有互动中保持专业与友善。

## 我能贡献什么

你不必会写代码也能帮上忙：

| 类型 | 举例 |
| --- | --- |
| 🐛 报 Bug | 某个镜像同步失败、多架构镜像丢平台、attestation 报错 |
| 📖 补文档 | 你踩过的坑，写进 [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) 就是他人的灯塔 |
| 💡 提需求 | 希望支持新的镜像仓库、新的同步策略 |
| 🧪 反馈使用体验 | 你说「这个参数看不懂」，就是文档需要改的信号 |
| 🔧 提代码 | 修 bug、加功能、补 CI |
| ⭐ 点 Star / 分享 | 让更多被镜像拉取困扰的人找到这里 |

## 报告问题

提 Issue 前请先做两件事：

1. 搜索[已有 Issue](https://github.com/nicholyx/action-sync-images/issues)，避免重复
2. 如果是**同步失败**，先查 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

我们提供了三种 Issue 模板，请按场景选择：

- **Bug 报告** —— 同步失败、报错、行为不符合预期
- **功能请求** —— 希望新增的能力
- **文档问题** —— 文档写错了、看不懂、缺内容

> ⚠️ **安全漏洞请勿提公开 Issue**，请走 [SECURITY.md](SECURITY.md) 中的私有渠道。

### 一个好 Bug 报告长什么样

```text
标题：同步 registry.k8s.io/coredns/coredns:v1.11.1 时报 unknown manifest class

环境：GitHub Actions（ubuntu-latest）
输入：images_src = registry.k8s.io/coredns/coredns:v1.11.1
       strip_attestation = false

期望：同步成功
实际：工作流在 skopeo 步骤失败，报错如下
      <完整的错误日志>

复现：Run workflow 里用上面的输入必现
补充：勾选 strip_attestation 后可以成功，怀疑与 attestation 有关
```

关键是把 **输入**、**完整报错**、**复现方式** 三样给全。日志请贴文本而不是截图，方便检索。

## 提交代码

### 整体流程

```text
Fork（若你无写权限）
   ↓
基于 main 创建分支  →  git switch -c fix/xxx
   ↓
改动 + 本地自测
   ↓
提交（遵循约定式提交）
   ↓
推送并开 PR（PR 模板会自动出现，请认真填）
   ↓
CI 自动检查（不通过会在 PR 上标红，可在本地提前跑同样的检查）
   ↓
维护者 review，可能请你改
   ↓
合并 🎉
```

### PR 的基本要求

- **一个 PR 只做一件事**。修 bug 和改文档请分开提，review 会快很多
- 描述里写清楚 **为什么**，而不只是 **改了什么**（diff 已经说明了后者）
- 如果是 UI / 输出相关改动，附上改动前后的对比
- 关联相关 Issue，例如 `Closes #12`
- 保持 PR 可被 review 的规模，超过 400 行 diff 建议拆分

## 提交信息规范

本项目遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/v1.0.0/)，
CI 会校验提交信息格式。**好消息是：用错格式 CI 会告诉你哪里错了。**

### 格式

```text
<类型>(<范围>): <简短描述>

[可选的正文，说明为什么这么改]

[可选的脚注，例如 BREAKING CHANGE 或 Closes #12]
```

### 允许的类型

| 类型 | 用途 |
| --- | --- |
| `feat` | 新功能 |
| `fix` | 修复 Bug |
| `docs` | 只改文档 |
| `ci` | 只改 CI / 工作流 |
| `chore` | 构建流程、依赖、杂项 |
| `refactor` | 重构（不改变外部行为） |
| `perf` | 性能优化 |
| `test` | 增删测试 |
| `style` | 格式调整（不影响逻辑） |
| `revert` | 回滚 |

### 示例

```bash
# ✅ 好
feat(aliyuncs): 支持一次同步多个镜像
fix(harbor): 补上 --all 避免丢失 arm64 平台
docs(readme): 补充 ALIYUNCS_REGISTRY 的配置说明
ci: 引入 actionlint 静态检查工作流

# ❌ 会被 CI 拦下
update                 # 缺少类型
修复bug                # 缺少类型与括号
feat:支持多镜像        # 冒号后需要空格
Feat(aliyuncs): xxx    # 类型必须小写
```

### 范围（scope）建议

用于说明改动落在哪个模块，常用的有 `aliyuncs`、`harbor`、`ci`、`docs`、`scripts`。

## 分支与合并策略

- `main` 是**唯一长期分支**，始终处于可发布状态
- 所有改动通过 PR 进入 `main`，**不接受直接向 `main` 推送**
- 功能分支从 `main` 拉出，合并后即删除
- 本项目使用 squash merge 保持 `main` 历史线性整洁

分支命名建议（不强制，但便于识别）：

| 前缀 | 用途 |
| --- | --- |
| `feat/` | 新功能 |
| `fix/` | 修 bug |
| `docs/` | 文档 |
| `ci/` | 工作流 |
| `chore/` | 杂项 |

## 开发环境准备

本项目**没有编译过程，也不需要安装依赖**——它本质是一组 YAML 工作流加几个 Shell 脚本。

你需要的是：

```bash
# 必需
git --version          # 任意较新版本
bash --version         # 4.0+（macOS 自带的是 3.2，跑校验脚本建议装 bash 5）

# 可选但强烈推荐（提交前本地自查，避免 CI 返工）
brew install actionlint shellcheck yamllint    # macOS
# 或
go install github.com/rhysd/actionlint/cmd/actionlint@latest
```

克隆并设置：

```bash
git clone https://github.com/nicholyx/action-sync-images.git
cd action-sync-images
```

## 本地验证工作流

### 一键自查（推荐）

仓库提供了统一入口，跑一次覆盖 CI 里的**静态检查**（`smoke-test` / `integration-test`
要起容器、连网络，不是静态检查；提交信息规范不在其中，原因见下面的提示）：

```bash
./scripts/lint.sh
```

它会依次执行 `actionlint`、`yamllint`、`shellcheck`、`bash -n` 与 `zizmor`
（工作流安全扫描：用 docker 跑 `ci.yml` 里 pin 的同一个镜像，版本从那里取，不另写一份）。
任何一项失败都会以非零码退出，并告诉你具体是哪个文件哪一行。**提交前跑一次，
能省掉一轮 CI 返工**——提交信息那一项除外，见下。

> ⚠️ **它验不了提交信息规范。** CI 的 `commit-messages` job 校验的是 PR 里的提交
> 与 **PR 标题**，而标题在 PR 建立之前根本不存在——本地任何入口都验不了它。
> 所以「本地全绿」不等于 `commit-messages` 会绿，PR 标题请照下面的规范自己写。

### 只想跑单项

```bash
actionlint                                    # 校验工作流语法与常见陷阱
yamllint -c .yamllint .github/workflows/      # 校验 YAML 风格
shellcheck scripts/*.sh                       # 校验 Shell 脚本
```

### 想真正跑一遍同步逻辑

工作流依赖 `skopeo` / `regctl` 与真实仓库凭证，本地完整复现需要：

```bash
brew install skopeo regclient      # macOS
```

然后可以直接用仓库提供的本地脚本做一次真实的同步（**会真的推送镜像**）：

```bash
./scripts/sync.sh --src registry.k8s.io/pause:3.9 \
                  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx
```

加 `--dry-run` 可以只打印将要执行的命令而不推送。

### 关于 `act`

理论上可以用 [`act`](https://github.com/nektos/act) 在本地模拟 Actions 执行，
但本项目的工作流强依赖 GitHub 的 Secrets 机制与镜像仓库网络访问，实际收益有限，
**不推荐**为此折腾。

## 代码风格要求

### 通用

- 一律使用 **LF** 换行、**UTF-8** 编码、文件末尾留空行（已由 [.editorconfig](.editorconfig) 约束）
- YAML 使用 **2 空格**缩进，**不要用 Tab**
- 中英文混排时，中英文之间加一个空格；标点用中文全角

### 工作流（`.github/workflows/*.yml`）

- 每个 step 必须有 `name`，且说清楚**做了什么**，而不是「运行脚本」
- Shell 脚本块统一以 `#!/usr/bin/env bash` + `set -euo pipefail` 开头
- **所有来自 `inputs` 的值必须先经 `env:` 中转再引用**，禁止直接写
  `${{ inputs.xxx }}` 到 `run:` 里——这是表达式注入的经典入口
- 变量引用一律加双引号，例如 `"${src}"` 而非 `${src}`
- 新增或修改 step 时，同步更新 README 中的参数表

### Shell（`scripts/*.sh`）

- 通过 `shellcheck` 且不添加大段 `# shellcheck disable`
- 需要禁用某条规则时，必须在该行上方写明原因
- 涉及路径或用户输入的地方必须加引号

### 文档（`*.md`）

- 命令、路径、代码标识符使用行内代码格式
- 大段命令使用带语言标注的代码块
- 中文文档请确保标点正确（不要用半角逗号代替中文顿号/逗号）

## Review 流程

### 提交 PR 之后

1. **CI 自动跑**（约 1 分钟内）——`actionlint`、`yamllint`、`shellcheck`、提交信息校验
2. **自动打标签** —— 根据改动文件自动标记（如 `ci`、`documentation`）
3. **维护者 review** —— 通常几天内；如果一周没动静，欢迎在 PR 里 @ 维护者催一下
4. **合并** —— 维护者会使用 squash merge

### 作为作者，你可以期待

- 具体的、可执行的 review 意见，而不是「这里不好」
- 如果方案有更优解，我们会说明原因，而不是直接改掉你的代码
- 如果 PR 长期无人处理，那一定是维护者疏忽，请务必催促

### 作为 reviewer，我们遵循

- 对**代码**严格，对**人**友善
- 区分「必须改」与「建议」——前者会明确说清楚
- 首次贡献者会得到更详细的引导

### 什么样的 PR 会被拒绝

- 与项目定位无关（本项目专注镜像同步，不做镜像构建、不做仓库管理平台）
- 引入重量级运行时依赖（如需要部署服务端）
- 在工作流中硬编码凭证或仓库地址
- 只改格式、制造大量无意义 diff

## 发布流程

由维护者执行：

```bash
# 1. 更新 CHANGELOG.md，把 Unreleased 的内容归入新版本
# 2. 打 tag 并推送
git tag -a v1.1.0 -m "release: v1.1.0"
git push origin v1.1.0
# 3. GitHub Actions 会自动创建 Release 并附带 CHANGELOG 摘要
```

版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)：破坏性改动升 major，
新增功能升 minor，修 bug 升 patch。

---

再次感谢你的参与。哪怕只是修正了一个错别字，这个项目都会因为你而更好一点。💛
