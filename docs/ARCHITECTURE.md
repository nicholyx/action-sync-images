# 架构与原理

本文说明这个项目**为什么这么设计**，以及一次镜像同步从点击按钮到完成，中间究竟发生了什么。

如果你只想用起来，看 [README](../README.md) 就够了；如果你要改代码，或者想知道某个设计为什么是这样，本文是必读的。

---

## 目录

- [这个项目解决什么问题](#这个项目解决什么问题)
- [整体架构](#整体架构)
- [一次同步的完整流程](#一次同步的完整流程)
- [两条同步路径](#两条同步路径)
- [深入理解 attestation 问题](#深入理解-attestation-问题)
- [目标镜像名是怎么来的](#目标镜像名是怎么来的)
- [代码结构](#代码结构)
- [关键设计决策](#关键设计决策)
- [安全模型](#安全模型)

---

## 这个项目解决什么问题

国内集群拉取国外镜像仓库（`registry.k8s.io`、`gcr.io`、`quay.io`、`ghcr.io`）时会遇到网络不可达。

常见的三种绕法，各有各的麻烦：

| 做法 | 问题 |
| --- | --- |
| 用别人同步好的镜像 | 版本掌握在别人手里，你要的版本可能没有；也不知道对方同步的是不是原版 |
| 自己买台海外 VPS 做中转 | 要花钱、要维护，还得手动 `pull` / `tag` / `push` |
| 用阿里云的镜像服务做拉取 | 单次操作、不方便批量，也不便于纳入版本管理 |

本项目走的是第四条路：**把 GitHub Actions 当作一台免费的、临时的中转机**。

运行器在海外，能直接访问所有上游仓库；我们把镜像从一个 registry 搬运到另一个 registry，全程不需要你拥有任何服务器，也不依赖第三方是否同步过。

---

## 整体架构

```text
┌──────────────────────────────────────────────────────────────────┐
│ 触发方式                                                          │
│   ├─ workflow_dispatch   手动触发（主路径，按需同步单个/多个镜像）  │
│   └─ schedule            定时批量（读取清单文件，默认关闭）         │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ .github/workflows/sync-images-*.yml                              │
│                                                                  │
│ 职责边界（刻意保持得很薄）：                                        │
│   • 登录目标仓库（读取 Secrets）                                   │
│   • 把 workflow_dispatch 的输入经 env 中转后组装成命令行参数         │
│   • 调用 scripts/sync.sh                                          │
│   • 上传同步报告为 Artifact                                        │
│                                                                  │
│ 这里**不含任何同步逻辑**。                                         │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│ scripts/sync.sh  ← 全项目唯一的同步逻辑实现                         │
│                                                                  │
│   1. 解析输入：拆分批量镜像、去重、校验引用格式                       │
│   2. 选择路径：skopeo 还是 regctl                                  │
│   3. 执行同步：必要时自动探测平台、失败重试                          │
│   4. 产出报告：控制台表格 / GitHub Step Summary / JSON+Markdown     │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
                 ┌─────────────┴─────────────┐
                 ▼                           ▼
      ┌────────────────────┐      ┌────────────────────────┐
      │  skopeo copy --all │      │  regctl index create   │
      │                    │      │                        │
      │  默认路径           │      │  剔除 attestation 路径  │
      │  原样搬运整个索引    │      │  只保留指定平台的子镜像  │
      └────────────────────┘      └────────────────────────┘
```

**为什么要把逻辑抽到 `scripts/sync.sh`？**

因为本地和 CI 需要同一套行为。如果工作流里写一份、本地脚本再写一份，两边迟早会漂移——某天你会发现「CI 里能跑通的参数，本地跑就是不行」。把逻辑收敛到一处，本地能用 `--dry-run` 快速验证，CI 只是换了个执行环境而已。

代价是工作流需要 `actions/checkout` 把脚本拉下来。这个代价是值得的。

---

## 一次同步的完整流程

以「把 `registry.k8s.io/coredns/coredns:v1.11.1` 同步到阿里云」为例。

### 1. 触发

在 Actions 页面选择 `Sync-Images-to-AliYuncs`，点击 Run workflow，填写：

```text
images_src:        registry.k8s.io/coredns/coredns:v1.11.1
strip_attestation: false
platforms:         （留空）
dry_run:           false
```

### 2. 登录目标仓库

工作流执行：

```bash
registry_host="${DEST_REGISTRY%%/*}"     # → registry.cn-shenzhen.aliyuncs.com
printf '%s' "$REGISTRY_PASSWORD" | docker login "$registry_host" --username "$REGISTRY_USERNAME" --password-stdin
```

登录成功后，凭证被写进 `~/.docker/config.json`。

**这一步是后面所有工具能推送的前提**：`skopeo` 和 `regctl` 都会自动读取这个文件里的认证信息，因此不需要再单独为它们配置凭证。有人会问「为什么用 `docker login` 而不是 skopeo 自带的 `--dest-creds`」——因为这样能保证登录地址和推送地址永远来自同一个变量，改仓库时不会漏掉任何一处。

### 3. 组装参数并调用同步脚本

```bash
args=(--src "$IMAGES_SRC" --dest "$DEST_REGISTRY" --report-dir ./reports)
if [[ "$STRIP_ATTESTATION" == "true" ]]; then args+=(--strip-attestation); fi
if [[ -n "$PLATFORMS" ]];        then args+=(--platforms "$PLATFORMS"); fi
./scripts/sync.sh "${args[@]}"
```

注意所有 `${{ inputs.* }}` 都先经 `env:` 落到环境变量，再在脚本里引用。**绝不能**直接写 `${{ inputs.images_src }}` 到 `run:` 里——那等于把用户输入直接拼进 Shell 脚本，是教科书级的表达式注入。

### 4. sync.sh 内部做了什么

```text
解析参数
   │
   ├─ 校验：--dest 和 --dest-exact 至少给一个
   ├─ 规范化：去掉可能误带的 docker:// 前缀和结尾斜杠
   │
   ├─ 检查依赖：skopeo 必须存在；jq 可选；strip 模式下才需要 regctl
   │
   ├─ 收集镜像列表
   │     ├─ 把逗号 / 分号 / 换行分隔的输入拆成一行一个
   │     ├─ 从 --file 指定的清单文件里读（剥掉注释与空白）
   │     └─ awk 去重，保持原有顺序
   │
   └─ 逐个处理：
         ├─ 校验引用格式（拦住 URL、缺 tag 这类明显错误）
         ├─ 计算目标地址
         ├─ 决定平台列表
         ├─ 执行同步（用 ::group:: 折叠输出）
         └─ 记录结果

产出：
   ├─ 控制台表格（stderr）
   ├─ $GITHUB_STEP_SUMMARY（Actions 页面直接渲染成表格）
   └─ reports/sync-report.{md,json}
```

### 5. 结果呈现

三层输出，对应三种使用场景：

| 输出 | 给谁看 | 在哪看 |
| --- | --- | --- |
| 控制台表格 | 盯着日志排错的人 | Actions 日志 |
| Step Summary | 只想确认「成了没」的人 | Actions 运行页面顶部 |
| Markdown / JSON 报告 | 需要存档或二次处理的人 | Artifact 下载 |

退出码有明确语义，便于被其他工具调用：

| 退出码 | 含义 |
| --- | --- |
| `0` | 全部成功 |
| `1` | 参数或环境错误（缺依赖、参数非法）——根本没开始同步 |
| `2` | 至少一个镜像同步失败——其他镜像仍然会继续尝试 |

---

## 两条同步路径

### 默认：`skopeo copy --all`

```bash
skopeo copy --all \
  --retry-times 3 \
  docker://registry.k8s.io/coredns/coredns:v1.11.1 \
  docker://registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
```

`--all` 是关键：**没有它，只会同步运行器所在的 amd64 单平台**。加了它，源镜像如果是 multi-arch 索引，所有平台的子镜像和索引结构会被完整保留。

这是绝大多数情况下的正确选择，不依赖额外工具，速度也最快。

### 特殊：`regctl index create`

```bash
regctl index create <目标> \
  --ref <源镜像> \
  --platform linux/amd64 \
  --platform linux/arm64
```

这个路径只做一件事：**重建一个不含 attestation 的索引**。

它会把源索引里指定平台的子镜像逐个复制到目标仓库，然后重新组装一个新的 manifest 索引。因为只复制了列出来的平台，`platform` 为 `unknown` 的 attestation manifest 自然就不会被包含进去。

### 怎么选

| 情况 | 用哪条 |
| --- | --- |
| 普通镜像 | 默认（skopeo）即可 |
| 同步时报 `unknown manifest class` 之类的错 | 改用 regctl，勾选「剔除 attestation」 |
| 源镜像来自 `netbirdio` 这类开启了 provenance 的项目 | 直接用 regctl |

---

## 深入理解 attestation 问题

这是本项目最容易被误解的地方，值得单独讲清楚。

### 什么是 attestation

较新的构建工具（BuildKit 等）在推镜像时，除了各平台的镜像本身，还会额外推两种「附件」：

- **provenance**：这个镜像**是怎么构建出来的**（用了哪个 Dockerfile、哪些构建参数）
- **SBOM**：镜像里**包含哪些软件包**

它们以符合 OCI 1.1 规范的 manifest 形式存在，`platform` 字段被标记为 `unknown`，用来和真正的平台镜像区分开。

### 为什么会同步失败

这些附件在 OCI 1.1 里允许「空 blob」（即 `config` 大小为 0 的条目）。

阿里云 ACR 的校验逻辑还不支持这种形式，遇到时会直接拒绝，报错信息大致是：

```text
unknown manifest class for ...
```

而这个错误发生在推送整个索引的过程中，**会导致整个镜像同步失败**——哪怕你真正想要的那两个平台镜像完全正常。

### 为什么不能简单地「过滤掉」

因为 attestation manifest 是嵌在源索引里一起被引用的。你用 `skopeo copy --all` 时，它会忠实地把整个索引连同附件一起搬过去，没有「只搬一部分」的选项（skopeo 的 `--all` 是全有或全无）。

所以只能换一条路：**不搬运原索引，而是自己重新组装一个**。这正是 `regctl index create` 做的事——它按你给的平台列表逐个复制，然后新建索引。

### 代价

重建索引意味着你要**明确知道源镜像有哪些平台**。如果源镜像只有 `linux/amd64`，而你按默认的 `linux/amd64,linux/arm64` 去重建，regctl 找不到 arm64 的子镜像，就会失败。

针对这个问题，`sync.sh` 做了自动探测：

```text
如果用户显式指定了 --platforms → 用用户指定的
否则                             → 用 skopeo inspect --raw 读取源索引，解析出平台列表
                                   → 探测失败才回退到 linux/amd64,linux/arm64
```

探测逻辑依赖 `jq`，并且只对真正的 multi-arch 索引有效（单平台镜像的 manifest 里没有 `manifests` 字段，解析结果为空，会走回退分支）。

---

## 目标镜像名是怎么来的

这是使用中最容易困惑的部分。项目提供两种模式。

### 前缀模式（`--dest`，默认）

最终目标 = **前缀** + `/` + **源镜像路径中的 `/` 全部替换为 `_`**

```text
前缀：  registry.cn-shenzhen.aliyuncs.com/nicholyx
源镜像：registry.k8s.io/coredns/coredns:v1.11.1
        └──────┬──────┘ └──┬──┘ └──┬──┘
               │            │      └─ 保留原样
               └────────────┴────────┐
                                     ▼
目标：  registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
```

**为什么要做这种「压平」？** 因为阿里云容器镜像服务的个人版不支持多级仓库路径。你没法创建 `nicholyx/registry.k8s.io/coredns/coredns` 这样的仓库，但可以创建 `nicholyx/registry.k8s.io_coredns_coredns`。

把 registry 域名也保留在名字里，是为了避免不同来源的同名镜像互相覆盖——`registry.k8s.io/pause` 和 `docker.io/pause` 会被区分成两个仓库。

### 精确模式（`--dest-exact`）

目标地址由你完全指定，脚本不做任何拼接：

```text
--dest-exact harbor.example.com/library/nginx:1.27
源镜像         nginx:1.27
                │
                ▼
目标           harbor.example.com/library/nginx:1.27
```

适合自建 Harbor 这类支持多级路径的仓库。**注意这个模式只能搭配单个源镜像**——因为一个目标地址无法同时对应多个源镜像，脚本会明确报错而不是做出含糊的行为。

---

## 代码结构

```text
.
├── .github/
│   ├── workflows/
│   │   ├── sync-images-aliyuncs.yml   同步到阿里云（主力，含 attestation 处理）
│   │   ├── sync-images-harbor.yml     同步到自建 Harbor
│   │   ├── sync-images-batch.yml      按清单文件批量同步
│   │   ├── ci.yml                     CI：静态检查 + 冒烟测试 + 提交信息校验
│   │   ├── labeler.yml                PR 按改动路径自动打标签
│   │   ├── stale.yml                  长期无响应的 Issue/PR 自动标记与关闭
│   │   ├── welcome.yml                首次贡献者欢迎语
│   │   ├── release.yml                打 tag 后自动创建 Release
│   │   └── learn-github-actions.yaml  GitHub Actions 入门示例（与本项目功能无关）
│   ├── ISSUE_TEMPLATE/                三种 Issue 表单
│   ├── PULL_REQUEST_TEMPLATE.md       PR 模板
│   ├── CODEOWNERS                     指定 review 责任人
│   ├── dependabot.yml                 Actions 版本自动更新
│   └── labeler.yml                    打标签规则
│
├── scripts/
│   ├── sync.sh                        ★ 同步引擎，全项目唯一的逻辑实现
│   ├── lint.sh                        本地统一校验入口（等同 CI 的静态检查）
│   └── check-commit-msg.sh            约定式提交信息校验
│
├── docs/
│   ├── ARCHITECTURE.md                本文
│   ├── USAGE.md                       详细使用指南
│   ├── TROUBLESHOOTING.md             排错手册
│   ├── MAINTAINER_GUIDE.md            维护者手册
│   └── BACKGROUND.md                  项目起源与原始教程归档
│
├── images.lock.txt                    批量同步用的镜像清单（可选）
├── README.md                          项目门面
├── CONTRIBUTING.md                    贡献指南
├── SECURITY.md                        安全策略与威胁模型
├── CODE_OF_CONDUCT.md                 行为准则
├── CHANGELOG.md                       更新日志
└── LICENSE
```

---

## 关键设计决策

以下是几个「当初为什么这么选」的记录。改代码前建议先读一遍。

### 为什么把同步逻辑放在脚本里，而不是直接写在 workflow 的 `run:` 中

**因为需要本地可验证。**

写在 `run:` 里的 Shell，只有推上去跑一次才知道对不对。抽成脚本后，可以用 `--dry-run` 在本地确认命令拼接是否正确，也可以在 CI 里做冒烟测试（`ci.yml` 的 `smoke-test` 任务就是干这个的）。

### 为什么默认不做 attestation 剔除

**因为 `skopeo copy --all` 更快、更可靠，且能完整保留索引结构。**

把剔除做成默认行为会带来两个问题：一是每次同步都要先探测平台、再逐个复制，慢得多；二是会改变镜像的索引结构，对使用者来说是个意外。让需要的人显式勾选，是更诚实的设计。

### 为什么目标仓库地址做成变量而不是写死

**因为「改一处、漏一处」是这类项目最典型的故障。**

最初地址散落在三个地方（两处 `echo`、一处实际推送）。一旦只改了日志里的输出而漏掉真正推送的那处，就会出现「日志显示同步到了 A 仓库，实际推到了 B 仓库」——这是最难排查的一类问题。现在收敛成单个 `DEST_REGISTRY`，日志和实际行为必然一致。

### 为什么 `regctl` 版本要固定

**因为可复现性。**

原先用的是 `releases/latest/download`，意味着同一条工作流今天跑和明天跑可能用的是不同版本的工具。一旦新版本改了行为，你会看到一个「什么都没改但突然失败了」的工作流。现在固定为明确版本，升级是显式的、可追溯的（Dependabot 会提 PR）。

### 为什么 `--dest-exact` 不允许多镜像

**因为含糊的行为比报错更糟。**

如果要支持「多个源映射到多个精确目标」，就需要引入映射文件或成对参数，复杂度陡增。而如果只是简单地把它们全推到同一个地址，就会互相覆盖——用户看到的会是「同步成功了，但镜像不对」。让脚本明确报错并提示改用前缀模式，是更好的选择。

---

## 安全模型

本仓库最核心的风险是：**工作流里存放着真实可用的镜像仓库推送凭证。**

完整的威胁模型、已采取的防护措施、以及「怀疑凭证泄露时怎么办」，都写在 [SECURITY.md](../SECURITY.md) 中，请务必阅读。

这里只强调两条与改代码直接相关的铁律：

1. **不要给工作流添加自动触发**（`push`、`pull_request`、`issue_comment` 等），除非你能保证该路径下不可能执行到未受信任的输入。当前所有同步工作流都只有 `workflow_dispatch`，这是有意为之。
2. **不要把 `${{ }}` 表达式直接写进 `run:`**。必须先落到 `env:`，再用带引号的变量引用。CI 中的 `actionlint` 会拦截一部分这类问题，但它不是万能的。
