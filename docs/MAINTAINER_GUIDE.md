# 维护者手册

这份文档写给项目的维护者——也就是你自己。

它回答两个问题：**这个项目平时需要做什么**，以及**出事了怎么办**。

---

## 目录

- [项目定位与边界](#项目定位与边界)
- [仓库配置清单](#仓库配置清单)
- [自动化设施一览](#自动化设施一览)
- [日常维护](#日常维护)
- [处理 Issue](#处理-issue)
- [审查 PR](#审查-pr)
- [发布新版本](#发布新版本)
- [应急处理](#应急处理)
- [项目红线](#项目红线)

---

## 项目定位与边界

明确项目**做什么**和**不做什么**，是拒绝无关需求时最有力的依据。

### 做

- 把容器镜像从一个 registry 搬运到另一个 registry
- 处理搬运过程中的实际问题（多架构、attestation、认证）
- 让搬运过程可追溯、可复现、可在本地验证

### 不做

| 不做的事 | 原因 |
| --- | --- |
| 构建镜像 | 那是 Dockerfile 和 CI 的事，本项目只搬运现成的 |
| 删除镜像 | 破坏性操作，不适合做成按钮 |
| 镜像内容扫描 / 签名验证 | 需要引入大量依赖，且不是本项目要解决的问题 |
| 成为一个需要部署的服务端 | 会彻底改变项目的使用门槛 |
| 支持任意 registry 的任意认证方式 | 按需支持，不为假设的需求做设计 |

如果有人提的需求落在「不做」里，可以礼貌地引用这一段，并说明欢迎 fork 自行改造。

---

## 仓库配置清单

以下配置**不在代码里**，只在 GitHub 仓库设置中，换机器或重建仓库时需要重新配置。

### Secrets（`Settings` → `Secrets and variables` → `Actions`）

| 名称 | 用途 | 必须 |
| --- | --- | :---: |
| `DOCKER_USERNAME` | 阿里云容器镜像服务账号 | 用阿里云时 |
| `DOCKER_PASSWORD` | 阿里云镜像仓库**固定密码** | 用阿里云时 |
| `HARBOR_REGISTRY` | Harbor 地址（不含协议） | 用 Harbor 时 |
| `HARBOR_USERNAME` | Harbor 用户名 | 用 Harbor 时 |
| `HARBOR_PASSWORD` | Harbor 密码或机器人 Token | 用 Harbor 时 |

### Variables

| 名称 | 用途 | 默认值 |
| --- | --- | --- |
| `ALIYUNCS_REGISTRY` | 覆盖阿里云目标仓库前缀 | `registry.cn-shenzhen.aliyuncs.com/nicholyx` |

### 仓库功能开关

以下是当前的配置状态，可作为重建仓库或排查配置问题时的对照：

| 功能 | 当前状态 | 说明 |
| --- | :---: | --- |
| Issues | ✅ 已启用 | 反馈主入口，配合 `.github/ISSUE_TEMPLATE/` 的表单使用 |
| Discussions | ✅ 已启用 | 承接使用提问，避免 Issue 列表被问答淹没 |
| Wiki | ❌ **已关闭** | 见下 —— 文档正文在 `docs/`，留着空 Wiki 只会让访客点进一个空页面 |
| Projects | ✅ 已启用 | 单人维护时收益有限，可随时关闭 |
| Secret scanning | ✅ 已启用 | 持续扫描仓库中的凭证泄露 |
| Push protection | ✅ 已启用 | 推送含凭证的内容时直接拦截 |
| Dependabot 告警 | ✅ 已启用 | 依赖存在已知漏洞时告警 |
| Dependabot 安全更新 | ✅ 已启用 | 有补丁版本时自动提 PR |
| **Private vulnerability reporting** | ✅ **已启用** | `SECURITY.md` 与 `ISSUE_TEMPLATE/config.yml` 都指向 `security/advisories/new`。**不开的话那个入口是不存在的**，文档里的安全报告渠道就是死的 |
| 合并后自动删分支 | ✅ 已启用 | 见下 |
| 允许自动合并（auto-merge） | ✅ 已启用 | 见下 |
| Topics | ✅ 已配置 | `docker` / `kubernetes` / `skopeo` 等 10 个主题标签 |
| 分支保护 | ✅ 已配置 | 见上一节 |

#### 关于「合并后自动删分支」与「允许自动合并」

这两项在 2026-09-24 之前都是关闭的，各自造成了一处本可避免的摩擦：

- **合并后自动删分支（`delete_branch_on_merge`）**：此前必须每次手动带上
  `gh pr merge --delete-branch`，忘了就留下一个已合并分支。**开这个设置不等于可以不带**
  —— 手动带上是幂等的，养成习惯仍有益处；但设置开着，忘带也不会留下垃圾。
- **允许自动合并（`allow_auto_merge`）**：此前 `gh pr merge --auto` 会报
  `Auto merge is not allowed`，本文档还因此把它当作「已知故障」记了绕过办法
  （改成等检查跑完再手动合并）。**开这个设置之后那个「故障」就不存在了** ——
  它本来就不是故障，是一个没打开的开关。

> 教训：**把「某个开关没开」记成「已知故障」，会让后来者去找根本不存在的 bug。**
> 遇到反复出现的操作摩擦时，先问一句「这是行为问题，还是配置问题」。

#### 为什么不启用 Wiki

Wiki 是**独立的 git 仓库**，改代码时很容易忘记同步；而 `docs/` 里的文档会随 PR
一起被 review（CODEOWNERS 也覆盖了该目录），不会出现文档与代码脱节。

此前 Wiki 处于「已启用但从未初始化」的状态：仓库页面上留着一个
「Create the first page」的入口，点进去是空页面 —— **对访客来说这比没有 Wiki 更糟**。
现已关闭。真要重新启用时：GitHub 要求**先在网页端创建首个页面**才会初始化它的
git 仓库（这一步没有 API），之后再 `git clone https://github.com/nicholyx/action-sync-images.wiki.git`。

#### 初始化 Wiki

GitHub 要求**先在网页端创建首个页面**，才会初始化 Wiki 的 git 仓库——这一步没有对应的 API，无法自动化：

1. 打开 <https://github.com/nicholyx/action-sync-images/wiki>
2. 点击 **Create the first page**
3. 标题填 `Home`，内容写一句「文档正文在仓库的 `docs/` 目录」并用链接指过去
4. 保存之后，就可以用命令行维护了：

   ```bash
   git clone https://github.com/nicholyx/action-sync-images.wiki.git
   ```

> 💡 **为什么不把文档正文放进 Wiki？**
> Wiki 是一个独立的 git 仓库，改代码时很容易忘记同步；而 `docs/` 里的文档会随 PR 一起被 review（CODEOWNERS 也覆盖了该目录），不会出现文档与代码脱节的情况。Wiki 更适合作为入口页。

> ⚠️ **如果本仓库仍是 fork**，Issues 默认是禁用的，且部分设置受限。需要先执行「Leave fork network」（见下文）。

### 分支保护

`Settings` → `Branches` → `Add branch protection rule`，分支名填 `main`：

- ✅ Require a pull request before merging
- ✅ Require status checks to pass → 选择 **CI 总览**（`ci-summary`）
  - 这个汇总检查覆盖了 actionlint、yamllint、shellcheck、zizmor、lint.sh 自测、冒烟测试、集成测试、提交信息规范
  - 只需要勾这一个，新增检查项时不用回来改设置
- ✅ Require conversation resolution before merging
- ⬜ Require approvals —— **单人维护时不要开**，否则你自己没法合并自己的 PR
- ✅ Do not allow bypassing the above settings（可选，严格些）

### Labels

需要存在以下标签，自动化工作流会引用它们：

| 标签 | 颜色建议 | 用途 |
| --- | --- | --- |
| `bug` | `#d73a4a` | 默认自带 |
| `documentation` | `#0075ca` | 默认自带 |
| `enhancement` | `#a2eeef` | 默认自带 |
| `good first issue` | `#7057ff` | 默认自带 |
| `help wanted` | `#008672` | 默认自带 |
| `question` | `#d876e3` | 默认自带 |
| `duplicate` | `#cfd3d7` | 默认自带 |
| `invalid` | `#e4e669` | 默认自带 |
| `wontfix` | `#ffffff` | 默认自带 |
| `ci` | `#0e8a16` | 工作流/CI 改动 |
| `dependencies` | `#0366d6` | 依赖更新（Dependabot 用） |
| `automation` | `#5319e7` | 脚本改动 |
| `governance` | `#b60205` | 治理文件改动 |
| `sync-aliyuncs` | `#1d76db` | 阿里云同步相关 |
| `sync-harbor` | `#006b75` | Harbor 同步相关 |
| `stale` | `#795548` | 过期标记（stale bot 用） |

创建命令（在仓库根目录执行）：

```bash
gh label create ci           --color 0e8a16 --description "CI / 工作流改动"
gh label create dependencies --color 0366d6 --description "依赖更新"
gh label create automation   --color 5319e7 --description "自动化脚本改动"
gh label create governance   --color b60205 --description "治理文件改动"
gh label create sync-aliyuncs --color 1d76db --description "阿里云同步相关"
gh label create sync-harbor   --color 006b75 --description "Harbor 同步相关"
gh label create stale         --color 795548 --description "长期无响应"
```

---

## 自动化设施一览

项目里有五套自动化，了解各自的触发条件，出问题时才知道去哪里找。

| 工作流 | 触发条件 | 它做什么 |
| --- | --- | --- |
| `ci.yml` | push 到 main、PR、手动 | 静态检查 + 冒烟测试 + 提交信息校验，结果汇总为「CI 总览」 |
| `labeler.yml` | PR 打开/更新 | 按改动文件路径自动打标签 |
| `welcome.yml` | 首次开 Issue/PR | 自动发表欢迎语与上手提示 |
| `stale.yml` | 每天定时 + 手动 | 60 天无响应的条目标记 stale，再 14 天自动关闭 |
| `release.yml` | 推送 `v*.*.*` tag | 从 CHANGELOG 提取说明并创建 Release |
| `dependabot.yml` | 每周一 | 为工作流里引用的 Actions 提更新 PR |

### 如果自动化行为不符合预期

- **打标签不对** → 改 `.github/labeler.yml` 的路径规则
- **stale 误伤** → 改 `.github/workflows/stale.yml`，把标签加进 `exempt-issue-labels`
- **CI 卡住不让合并** → 检查是不是真的有问题；确认无误时可以临时在分支保护里放宽，但请尽快改回来
- **Dependabot 噪音太大** → 调整 `.github/dependabot.yml` 的 `open-pull-requests-limit` 或 `schedule.interval`

### 维护流程已沉淀为 Skill

项目的维护知识沉淀为两个项目级 skill（`.claude/skills/`），随仓库分发，克隆即生效：

| Skill | 适用场景 | 内容 |
| --- | --- | --- |
| `oss-bootstrap` | **新项目**从零落实开源规范 | 六个阶段：CI 与提交规范 → 治理文件 → 仓库自动化 → 文档体系 → 仓库设置（分支保护/看板/里程碑）→ 首个发布；附搭建期的踩坑记录 |
| `maintain-loop` | **本项目**的日常迭代闭环 | 盘点 → 规划 → 实现 → CI 与合并 → 发布 → 继续规划，附运行期的硬规则（全部来自真实 Issue） |

两者的关系：前者「从 0 到 1 搭基建」，后者「基建就位后按流程跑」。本仓库自身就是
`oss-bootstrap` 的参考实现——skill 里引用的每个文件都能在仓库里找到成品。

在装了 Claude Code 的环境里，让 AI「新建开源项目 / 给项目补 CI 与规范」会走 `oss-bootstrap`；
说「继续迭代 / 按维护流程走 / 发布新版本」会走 `maintain-loop`。人工维护者也可以把它们当
**流程速查表**来读——本手册其余部分讲「每件事的细节」，skill 讲「整件事的顺序」。

修改维护流程时**两边都要改**：先改本手册（细节的事实来源），再同步对应 skill（流程的执行入口）。

---

## 日常维护

### 每周（约 10 分钟）

- [ ] 扫一眼 **Issues**，给新 Issue 加标签、回复或标记 `good first issue`
- [ ] 扫一眼 **Pull Requests**，跑一下 CI 的 review
- [ ] 处理 Dependabot 的更新 PR（通常点一下合并即可，CI 会告诉你有没有问题）

### 每月（约 30 分钟）

- [ ] 检查 Actions 用量，避免账单意外
- [ ] 翻一下 Actions 的历史运行，看有没有反复失败的同步
- [ ] 检查阿里云 / Harbor 的凭证是否即将过期
- [ ] 看看 `CHANGELOG.md` 的 `Unreleased` 段落是否积累了不少内容，考虑发一个版本

### 每季度

- [ ] 复审 `SECURITY.md` 的威胁模型是否还成立
- [ ] 检查工作流里引用的 Action 版本，考虑升大版本
- [ ] 回顾一下「不做什么」清单，确认项目没有偏离定位

---

## 处理 Issue

### 收到新 Issue

1. **先判断类型**：Bug / 功能请求 / 文档问题 / 使用提问
2. **使用提问** → 引导到 Discussions，并礼貌关闭（不要粗暴关，附上讨论链接）
3. **Bug** → 确认能否复现，加 `bug` 标签
4. **功能请求** → 对照[项目边界](#项目定位与边界)，能做的加 `enhancement`，明确不做的说明原因后关闭
5. **适合新手** → 加 `good first issue`，并在正文补充「从哪个文件入手」的提示

### 回复的几个原则

- **先说结论**：能修 / 不能修 / 需要更多信息
- **给替代方案**：不能按他说的做，就告诉他可以怎么做
- **不要秒回后消失**：如果要说「我看看」，就说清楚大概什么时候看
- **明确拒绝**：做不到就直说，含糊其辞比拒绝更消耗人

---

## 审查 PR

### 审查清单

按这个顺序看：

1. **CI 是否通过** —— 没通过的话先看为什么，别急着看代码
2. **改动是否符合项目定位** —— 见[项目边界](#项目定位与边界)
3. **描述里的「为什么」** —— 只说「改了什么」的 PR 要追问动机
4. **有没有触碰[红线](#项目红线)** —— 尤其是工作流的触发方式和表达式注入
5. **有没有同步更新文档** —— 改了输入参数却没改 README 参数表，要打回
6. **有没有更新 CHANGELOG** —— 用户可见的行为变化必须有记录

### 给反馈的方式

- **区分「必须改」和「建议」**，前者要明确说清楚原因
- **指出问题时给出方向**，而不只是「这里不好」
- **首次贡献者多给一些上下文**，他们不熟悉这个项目的历史
- **肯定做得好的地方** —— 这不是客套，而是让贡献者知道什么是对的

### 合并

使用 **squash merge**，保持 `main` 历史线性。

合并前确认 squash 后的提交信息仍符合约定式提交规范（默认会取 PR 标题，而 PR 标题已经被 CI 校验过了）。

合并后删除分支。

---

## 发布新版本

### 什么时候发

- 有新的用户可见功能
- 有重要的 Bug 修复
- 积累了一批小改动

不需要为每个提交发版。

### 怎么发

```bash
# 1. 确认工作区干净且与远端同步
git switch main
git pull

# 2. 编辑 CHANGELOG.md
#    把 [Unreleased] 段落的内容归入新版本号，并保留一个空的 [Unreleased]
#    例如把 "## [Unreleased]" 改成 "## [1.1.0] - 2026-09-11"

# 3. 提交
git add CHANGELOG.md
git commit -m "chore(release): 发布 v1.1.0"
git push

# 4. 打 tag 并推送（这一步会触发自动发布）
git tag -a v1.1.0 -m "release: v1.1.0"
git push origin v1.1.0
```

推送 tag 后，`release.yml` 会自动创建 Release，说明文字从 `CHANGELOG.md` 对应的版本段落提取。

也可以直接用命令行发布：

```bash
gh release create v1.1.0 --title v1.1.0 --notes-file <(sed -n '/## \[1.1.0\]/,/## \[/p' CHANGELOG.md | head -n -1)
```

### 版本号规则

遵循[语义化版本](https://semver.org/lang/zh-CN/)：

| 改动类型 | 版本变化 | 例子 |
| --- | --- | --- |
| 破坏性变更 | major | 移除某个输入参数 |
| 新增功能 | minor | 支持批量同步 |
| Bug 修复 | patch | 修复多架构丢失 |

> 💡 对使用者而言，本项目的「破坏性变更」主要指：输入参数被删改、目标镜像命名规则变化、默认行为变化。

---

## 应急处理

### 怀疑凭证泄露

**这是本项目的最高优先级事件。**

1. **立即轮换密码**
   - 阿里云：控制台 → 容器镜像服务 → 访问凭证 → 重置固定密码
   - Harbor：重置对应用户/机器人账号的密码
2. **更新仓库 Secrets**（`Settings` → `Secrets and variables` → `Actions`）
3. **排查影响范围**
   - 检查镜像仓库的推送日志，看有没有非你发起的推送
   - 检查 Actions 运行历史，看有没有非你触发的 `workflow_dispatch`
   - 检查是否有可疑的 PR 改动了 `.github/workflows/`
4. **排查泄露途径**
   - 是否在日志、截图、Issue 里贴出过凭证
   - 是否有工作流把凭证输出到了日志（搜 `echo` Secrets 的写法）
5. **记录**：在 `SECURITY.md` 或私下记录事件经过，避免重蹈覆辙

### CI 突然全红

1. 先看是不是 `ci-summary` 汇总失败但各子任务通过 —— 那是汇总逻辑的问题
2. 看 actionlint / yamllint / shellcheck 各自报什么
3. 如果本地 `./scripts/lint.sh` 是绿的而 CI 是红的，**按分歧源逐项排查**，不要先猜版本：
   - **调用参数与目标集是否一致**。`lint.sh` 的 actionlint 自 2026-09-23 起显式传
     `.github/workflows/` 下的文件，与 CI 的 `./actionlint -color` 规则集、目标文件集一致
     （CI 不传文件，靠项目根自动发现同一批文件）。
     在它之前本地多一个 `-ignore 'SC2086'`——那才是「本地不报、CI 报」的真实来源，
     照旧版这句去比版本会一无所获（两边都是 1.7.12）
   - **工具版本**。actionlint 在 CI 里固定在 `ci.yml` 的 `env.ACTIONLINT_VERSION`，本地可能更新；
     **yamllint 与 shellcheck 两边都不 pin**；zizmor 在本地没有 docker 时会退回本机二进制，
     而 CI 用 pin 的镜像——只有它会把两边的版本打出来（退回本机二进制的那条路径上）。
     其余几项 `lint.sh` 不打版本，要比对得自己跑
     `actionlint --version` / `yamllint --version` / `shellcheck --version`
4. 如果所有 PR 都红，可能是 GitHub 改了运行器镜像，检查运行日志里的环境信息

### 同步工作流突然失败

1. **先看是不是配额问题** —— 阿里云 ACR 个人版有仓库数量和流量限制
2. **看是不是上游镜像变了** —— 上游可能重新构建了镜像导致 digest 变化
3. **看是不是 GitHub 运行器环境变了** —— 比如 skopeo 被移除，参考[排错手册](TROUBLESHOOTING.md#错误skopeo-command-not-found)
4. **临时绕过** —— 如果急需某个镜像，可以在本地用 `scripts/sync.sh` 直接同步，不必等 CI 修好

### 仓库仍是 fork，想脱离

在当前 GitHub 限制下，「Leave fork network」**只能通过网页界面完成**，没有对应的 API：

1. 打开仓库 `Settings`
2. 拉到底部的 **Danger Zone**
3. 点击 **Leave fork network**
4. 按提示确认

操作后：

- 仓库成为完全独立的仓库
- 可以正常启用 Issues、Discussions
- 所有仓库设置不再受限
- **失去与上游的 fork 关联**，无法再直接向上游提 PR（这是不可逆的）

> 💡 如果暂时不想脱离，也可以先试着在 `Settings` → `General` → `Features` 里直接勾选 Issues。fork 的 Issues 默认关闭，但部分情况下可以直接开启。

---

## 项目红线

以下几条是**改代码时不能碰**的，除非你完全清楚后果：

### 1. 不要给同步工作流添加自动触发器

当前所有 `sync-images-*.yml` 都只有 `workflow_dispatch`。这是**有意的安全设计**。

一旦加上 `push`、`pull_request`、`issue_comment` 这类自动触发，任何能影响这些事件的人（比如提 PR 的人）就可能诱导工作流执行任意命令，而工作流持有你的镜像仓库凭证。

### 2. 不要把 `${{ }}` 直接写进 `run:`

```yaml
# ❌ 危险：用户输入直接拼进 Shell
run: echo "${{ inputs.images_src }}"

# ✅ 正确：先落到 env，再用带引号的变量引用
env:
  IMAGES_SRC: ${{ inputs.images_src }}
run: echo "$IMAGES_SRC"
```

CI 里的 actionlint 会拦一部分，但它不是万能的，**审查 PR 时要人工确认**。

### 3. 不要在日志里输出 Secret

```yaml
# ❌ 绝对不要
run: echo "密码是 ${{ secrets.DOCKER_PASSWORD }}"
```

GitHub 会对已知的 Secret 做脱敏，但**不要依赖这个机制** —— 经过编码、截断、拼接后的值不会被识别。

### 4. 不要降低 `pull_request_target` 的安全性

`labeler.yml` 和 `welcome.yml` 用了 `pull_request_target`，代价是它们运行在**有写权限的上下文**中。

当前它们安全的前提是：**不 checkout PR 代码、不执行 PR 内容**。

如果有人往这两个工作流里加 `actions/checkout` 并把 `ref` 指向 PR 分支，就等于把仓库写权限交给任何提 PR 的人。**这种改动必须拒绝。**

### 5. 不要把凭证、内网地址写进代码

仓库是公开的。任何硬编码的地址都会被索引，任何硬编码的凭证都会立刻泄露。

---

## 附：常用命令速查

```bash
# 本地跑完整检查（提交前必做）
./scripts/lint.sh

# 校验一段提交信息
./scripts/check-commit-msg.sh --message "feat(aliyuncs): xxx"

# 本地试跑同步（不推送）
./scripts/sync.sh --src <镜像> --dest <目标> --dry-run

# 查看最近的 Actions 运行
gh run list -L 10

# 查看某次运行的日志
gh run view <run-id> --log

# 重新运行失败的 job
gh run rerun <run-id> --failed

# 列出待处理的 PR
gh pr list

# 合并 PR（squash）
gh pr merge <number> --squash --delete-branch
```
