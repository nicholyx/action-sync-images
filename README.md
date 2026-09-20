<div align="center">

# action-sync-images

**借用 GitHub Actions 当免费的海外中转机，把拉不动的镜像搬回国内仓库。**

不需要 VPS，不需要服务器，不依赖别人同步好的镜像。

[![CI](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml/badge.svg)](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nicholyx/action-sync-images)](https://github.com/nicholyx/action-sync-images/releases)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/badge?org=nicholyx&repo=action-sync-images)](https://github.com/ossf/scorecard)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![GitHub stars](https://img.shields.io/github/stars/nicholyx/action-sync-images?style=social)](https://github.com/nicholyx/action-sync-images/stargazers)

[快速开始](#快速开始) · [使用文档](docs/USAGE.md) · [工作原理](docs/ARCHITECTURE.md) · [排错手册](docs/TROUBLESHOOTING.md) · [贡献指南](CONTRIBUTING.md)

**中文** | [English](README.en.md)

</div>

---

## 这是什么

国内集群要拉 `registry.k8s.io`、`gcr.io`、`quay.io`、`ghcr.io` 上的镜像，往往会卡在网络这一关。

常见的三种绕法各有各的麻烦：用别人同步好的镜像，版本捏在别人手里；买台海外 VPS 做中转，要花钱还要维护；用云厂商的镜像服务，单次操作、不便批量、也进不了版本管理。

这个项目走第四条路：**把 GitHub Actions 当作一台免费的临时中转机**。

运行器在海外，能直接访问所有上游仓库。你只要点一下按钮，它就把镜像从一个 registry 搬到另一个 registry。全程不需要你拥有任何服务器。

```text
  registry.k8s.io/coredns/coredns:v1.11.1
                  │
                  │  GitHub Actions（海外运行器）
                  │  skopeo / regctl 搬运
                  ▼
  registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
                  │
                  ▼
            你的国内集群
```

---

## 特性

- **零基础设施** —— 不需要 VPS、不需要服务器，只需要一个 GitHub 账号
- **完整保留多架构** —— amd64 / arm64 一起搬，不会只同步当前平台
- **处理 attestation** —— 专门的路径解决阿里云 ACR 拒绝 OCI 1.1 空 blob 的问题（`unknown manifest class`）
- **批量同步** —— 一次填多个镜像，或用清单文件维护一整套镜像集合
- **按需筛选** —— 用正则从清单里挑出这次要同步的镜像，不必为了临时筛选去改清单文件
- **多目标同步** —— 一次运行推送到多个仓库（比如阿里云给国内集群、Harbor 做内部归档），且每个目标可各自选择压平或保留路径
- **并发 + 增量** —— 批量同步支持并发执行，并自动跳过目标已有的相同镜像。
  定期同步的场景下，重复运行通常几秒就跑完
- **失败不中断** —— 批量同步时单个镜像失败不影响其余镜像，最后统一汇总
- **超时与重试可控** —— 单个镜像可设超时，避免一个大镜像卡住整个批量任务
- **支持自建 registry** —— 可关闭 TLS 校验，同步自建的 HTTP 仓库
- **结果通知** —— 可推送同步与体检结果到钉钉 / 飞书 / Slack，无人值守时也能第一时间知道成败
- **可审计** —— 记录源与目标的 digest，并可生成锁文件用于精确复现
- **状态可查** —— `--audit` 只读检查清单与目标仓库的差距（最新 / 落后 / 缺失 / 无法判定），不推送任何东西
- **上游新版可查** —— `--check-updates` 对比上游 tag 与清单，报告有哪些版本还没收录
- **锁文件可校验** —— `--audit-lock` 定期确认上游的 tag 还是你锁定的那份 digest，上游悄悄覆盖 tag 时第一时间知道
- **网页上就能体检** —— `Check-Registry` 工作流一键跑上面两项检查，不用装任何工具，结果进运行页面的 Summary 并可推送通知
- **结果一目了然** —— 运行结束直接生成结果表格，无需翻日志
- **失败后知道怎么办** —— 同步失败时，运行页面直接给出**可粘贴的重跑清单**（`Sync-Batch` 给锚定正则），复制一次就能只重跑失败的那些，不必自己从表格里一个个抄
- **可看趋势** —— `scripts/history.sh` 汇总历次报告，回答「哪个镜像总在失败」「哪个镜像一直落后 / 一直在漂移」
- **可在本地复现** —— 同一套逻辑封装成 `scripts/sync.sh`，本地也能跑；`--dry-run` 会先输出源 → 目标同步计划，再打印实际命令
- **目标仓库可配置** —— 换命名空间或区域不需要改代码
- **静态检查齐全** —— actionlint + yamllint + shellcheck + 提交信息规范，`./scripts/lint.sh` 一键跑完

---

## 快速开始

### 1. 配置凭证

进入仓库 `Settings` → `Secrets and variables` → `Actions`，添加阿里云容器镜像服务的凭证：

| Secret | 值 |
| --- | --- |
| `DOCKER_USERNAME` | 阿里云账号 |
| `DOCKER_PASSWORD` | 镜像仓库的**固定密码**（不是阿里云登录密码） |

> 用 Harbor 的话改配 `HARBOR_REGISTRY` / `HARBOR_USERNAME` / `HARBOR_PASSWORD`，详见 [使用文档](docs/USAGE.md#第一步准备凭证)。

### 2. 触发同步

打开 **Actions** → 左侧选 `Sync-Images-to-AliYuncs` → **Run workflow** → 填入源镜像：

```text
registry.k8s.io/pause:3.9
```

### 3. 拉取验证

```bash
docker pull registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

就这样。整个流程不需要你写一行代码。

---

## 三种同步方式

### ① 单个镜像

在 `Sync-Images-to-AliYuncs` 的 `images_src` 里填一个镜像，适合临时需要。

### ② 一次多个镜像

`images_src` 支持**换行、逗号、分号**分隔，可以混用：

```text
registry.k8s.io/kube-apiserver:v1.31.0
registry.k8s.io/kube-controller-manager:v1.31.0
registry.k8s.io/kube-scheduler:v1.31.0
```

或写成一行：`nginx:1.27, redis:7.4, registry.k8s.io/pause:3.9`

重复的会自动去重；**某个镜像失败不会影响其它镜像**，结束后给你一张汇总表。

### ③ 按清单批量同步

适合维护「某个 k8s 版本的整套组件」这类固定集合。

编辑仓库根目录的 [`images.lock.txt`](images.lock.txt)，然后触发 `Sync-Batch` 工作流即可。

> 💡 清单生成小技巧：`kubeadm config images list --kubernetes-version=v1.31.0` 的输出可以直接粘进去。

---

## 参数速查

### Sync-Images-to-AliYuncs（主力工作流）

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | 源镜像，可多个。不需要 `docker://` 前缀 |
| `strip_attestation` | | `false` | 剔除 attestation manifest。报 `unknown manifest class` 时勾它 |
| `platforms` | | 自动探测 | 保留的平台，如 `linux/amd64,linux/arm64`。仅在上项勾选时生效 |
| `concurrency` | | `4` | 并发同步的镜像数量，批量时提速明显 |
| `skip_existing` | | `true` | 跳过目标仓库中已存在且完全相同的镜像 |
| `dry_run` | | `false` | 先输出同步计划，再打印命令；不实际推送。用于确认筛选结果与目标地址 |

### Sync-Images-to-Harbor

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | 源镜像，支持批量 |
| `images_dest` | ✅ | — | 目标路径，拼在 `HARBOR_REGISTRY` 之后，如 `library/nginx:1.27` |
| `concurrency` | | `4` | 并发同步的镜像数量 |
| `skip_existing` | | `true` | 跳过已存在的相同镜像 |
| `dry_run` | | `false` | 同上 |

### Sync-Batch

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `lockfile` | ✅ | `images.lock.txt` | 清单文件路径 |
| `dest_registry` | | 见说明 | 目标仓库前缀，留空则用 `ALIYUNCS_REGISTRY` 变量或内置默认值 |
| `concurrency` | | `6` | 并发同步的镜像数量 |
| `skip_existing` | | `true` | 跳过已存在的相同镜像 |
| `dry_run` | | `false` | 同上 |
| `filter` | | 空 | 只同步匹配该正则的镜像，如 `kube-` |
| `exclude` | | 空 | 跳过匹配该正则的镜像，如 `apiserver` |

> 📖 每个参数的深入说明、边界情况与示例，见 [使用文档](docs/USAGE.md#输入参数详解)。

---

## 目标镜像名是怎么变的

这是使用中最容易困惑的一点，**建议动手前先看一眼**。

默认采用「压平」规则，因为**阿里云容器镜像服务的个人版不支持多级仓库路径**：

```text
源镜像：registry.k8s.io/coredns/coredns:v1.11.1
        └──────┬──────┘ └──┬──┘ └──┬──┘
               └───────────┴───────┴──→ / 全部替换为 _
                              ▼
目标：  <你的仓库前缀>/registry.k8s.io_coredns_coredns:v1.11.1
```

保留 registry 域名是为了避免不同来源的同名镜像互相覆盖——`registry.k8s.io/pause` 和 `docker.io/pause` 会落到两个不同的仓库。

不确定会变成什么样？**勾上 `dry_run` 跑一次**，日志里会先输出同步计划，再打印完整命令。

自建 Harbor 支持多级路径，用的是精确模式（不做压平）：

```text
源：nginx:1.27  →  目标：harbor.example.com/library/nginx:1.27
```

**多个目标想各用各的规则？** 用 `--dest-keep-path`——语义与 `--dest` 相同（前缀 + 源镜像路径），只是不压平。两者可以混用：

```bash
./scripts/sync.sh --file images.lock.txt \
  -d <阿里云前缀> \
  --dest-keep-path harbor.example.com/mirror
```

```text
<阿里云前缀>/registry.k8s.io_pause:3.9                  ← 压平（阿里云个人版不支持多级路径）
harbor.example.com/mirror/registry.k8s.io/pause:3.9     ← 保留路径（Harbor 支持）
```

详见[场景十四](docs/USAGE.md#场景十四一次推往两类仓库各用各的命名规则)。

---

## 常见场景

<details>
<summary><b>同步带 attestation 的镜像（报 <code>unknown manifest class</code>）</b></summary>

勾选 `strip_attestation`，`platforms` 留空（会自动探测）：

```text
images_src:        ghcr.io/netbirdio/netbird:0.28.0
strip_attestation: ✅
```

常见触发者是 `ghcr.io/netbirdio/*`，以及任何用 BuildKit 开启了 provenance 的项目。原理见 [ARCHITECTURE.md](docs/ARCHITECTURE.md#深入理解-attestation-问题)。

</details>

<details>
<summary><b>源镜像只有单平台（报 <code>platform not found</code>）</b></summary>

勾选 `strip_attestation`，并显式指定平台：

```text
images_src:        some.registry/only-amd64:1.0
strip_attestation: ✅
platforms:         linux/amd64
```

先确认源镜像有哪些平台：

```bash
skopeo inspect --raw docker://<源镜像> | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"'
```

</details>

<details>
<summary><b>只同步清单里的一部分镜像</b></summary>

清单是「期望状态的完整记录」，但某一次同步往往只想覆盖其中一部分。用 `filter` / `exclude` 挑，不必为了临时筛选去改动清单文件：

```text
lockfile:  images.lock.txt
filter:    kube-          # 只同步 kube-* 组件
exclude:   apiserver      # 但把 apiserver 排掉
```

两者都接受正则（ERE），可组合使用（先 filter 后 exclude）。

**被排除的镜像仍会出现在结果表中**，并标注是哪条规则把它排掉的——清单里列了 20 个而结果表只有 19 行，会让人误以为第 20 个已经同步了。看得见的排除才是排除。

本地用法：

```bash
./scripts/sync.sh --file images.lock.txt --dest <目标仓库> \
  --filter 'kube-' --exclude 'apiserver'
```

</details>

<details>
<summary><b>换一个阿里云命名空间 / 区域</b></summary>

不用改代码。`Settings` → `Secrets and variables` → `Actions` → **Variables**，新增：

```text
ALIYUNCS_REGISTRY = registry.cn-hangzhou.aliyuncs.com/your-namespace
```

登录地址会自动从它的第一段推导，所以换区域也只需改这一处。

</details>

<details>
<summary><b>同步到 Docker Hub</b></summary>

`sync.sh` 不限定目标仓库。复制一份工作流，把目标地址改成 `docker.io/你的用户名`，配上对应 Secrets 即可。

> ⚠️ Docker Hub 免费账号有拉取速率限制，且公共仓库的镜像**对所有人可见**。

</details>

<details>
<summary><b>某个镜像是不是一直在失败？</b></summary>

每次运行的报告都是独立的 Artifact，单看一份看不出趋势。`scripts/history.sh` 把历次报告摊在一起：

```bash
# 汇总最近 20 次运行
./scripts/history.sh

# 某个镜像的历史
./scripts/history.sh --image registry.k8s.io/pause:3.9

# 失败最多的 5 个镜像
./scripts/history.sh --top-failures 5

# 哪个镜像一直落后 / 一直缺失（检查报告趋势）
./scripts/history.sh --check audit

# 哪个锁条目一直在漂移
./scripts/history.sh --check lock-audit
```

输出是 Markdown 表格，可以直接贴进 Issue：

```text
共 **20** 次运行，覆盖 `2026-08-22T…` ~ `2026-09-11T…`
累计同步 **96** 个镜像次：成功 88 ｜ 跳过 5 ｜ 失败 3

| 镜像 | 成功 | 跳过 | 失败 | 最近一次 |
| --- | :---: | :---: | :---: | :---: |
| `ghcr.io/foo/bar:1.2` | 14 | 3 | 3 | ❌ |
```

它**复用已有的报告 Artifact，不引入任何新的存储**——因此不会给仓库留下持续增长的提交历史。历史的价值在于趋势，而趋势不需要永久保存。

> 💡 需要 `gh` CLI 与 `jq`。默认从 GitHub 下载报告，也可以用 `--dir` 指向本地目录离线使用。装不了 CLI？`History-Trend` 工作流在 Actions 页面就能跑趋势，结果进 Summary 并落盘 Artifact。

</details>

<details>
<summary><b>先看看仓库跟上清单没有（<code>--audit</code>）</b></summary>

清单是期望状态，但「仓库现在到底跟上没有」此前只有真的跑一次同步才知道——而同步是会真推送的。`--audit` 只读地检查，**不推送任何东西**：

```bash
./scripts/sync.sh --file images.lock.txt -d <目标仓库> --audit
```

```text
 ✓ 最新  registry.k8s.io/pause:3.9
 ✗ 缺失  registry.k8s.io/etcd:3.5.15-0
 ⚠ 落后  registry.k8s.io/coredns/coredns:v1.11.1
 ? 无法判定  quay.io/coreos/flannel:v0.25.5
   源镜像无法访问：dial tcp: lookup quay.io: no such host

审计完成：最新 1 ｜ 落后 1 ｜ 缺失 1 ｜ 无法判定 1
```

**「无法判定」单独占一类**：查不到和内容不一致是两回事，把网络抖动显示成「落后」会让人去排查一个并不存在的问题。源自身取不到时报的也是「无法判定」，不是目标「缺失」。

退出码 `2` 表示「未得出全部最新」（含「没查完」），可以直接接进 CI 做定期体检——审计是只读的，不违反「同步必须显式触发」这条红线。

看完全去掉 `--audit` 重跑同一条命令即可补齐，已是最新的会被 `--skip-existing` 自动跳过。详见[场景十二](docs/USAGE.md#场景十二审计清单与目标仓库的差距)。

</details>

<details>
<summary><b>上游是不是该升级了（<code>--check-updates</code>）</b></summary>

清单锁的是某个 k8s 版本的整套组件，上游发新版本时没有任何机制会通知你。`--check-updates` 拉取上游 tag 列表与清单对比：

```bash
./scripts/sync.sh --file images.lock.txt --check-updates
```

```text
registry.k8s.io/kube-apiserver
  清单中：v1.31.0
  上游共 340 个 tag，其中 12 个不在清单中，版本序最大的 5 个：
    v1.32.3 v1.32.2 v1.32.1 v1.31.4 v1.31.3
```

**只报告，不修改清单**——升到哪个版本涉及兼容性判断，是人的决定。**也不做语义化版本判断、不过滤预发布**：上游命名未必规整（`latest`、`1.27-alpine`、`v1.32.0-rc.1`），语义化比较会给出错误结论。所以列表里出现 `latest` 或比清单更旧的 tag 都正常，它**不是升级建议**。

默认只列版本序最大的 5 条（`--updates-limit` 可调），但总数一定会报。不需要目标地址；同一个源仓库的多个 tag 只查一次上游。详见[场景十三](docs/USAGE.md#场景十三发现上游的新版本)。

</details>

<details>
<summary><b>在本地跑，不用 GitHub Actions</b></summary>

```bash
brew install skopeo regclient   # macOS

# 先预览：同步计划 + 实际命令
./scripts/sync.sh --src registry.k8s.io/pause:3.9 --dest registry.cn-shenzhen.aliyuncs.com/nicholyx --dry-run

# 确认后正式同步（需先 docker login）
./scripts/sync.sh --src registry.k8s.io/pause:3.9 --dest registry.cn-shenzhen.aliyuncs.com/nicholyx
```

`./scripts/sync.sh --help` 查看全部参数。

</details>

---

## 项目结构

```text
.
├── .github/workflows/
│   ├── sync-images-aliyuncs.yml   同步到阿里云（主力）
│   ├── sync-images-harbor.yml     同步到自建 Harbor
│   ├── sync-images-batch.yml      按清单文件批量同步
│   ├── check-registry.yml         镜像仓库体检（只读检查，不推送）
│   ├── ci.yml                     CI：静态检查 + 冒烟测试
│   ├── scorecard.yml              OSSF Scorecard 供应链评分
│   ├── labeler.yml                PR 自动打标签
│   ├── stale.yml                  Issue/PR 过期管理
│   ├── welcome.yml                欢迎首次贡献者
│   └── release.yml                自动发布
├── scripts/
│   ├── sync.sh                    ★ 同步引擎（全项目唯一的逻辑实现）
│   ├── history.sh                 汇总历次同步报告，看趋势
│   ├── lint.sh                    本地统一校验入口
│   └── check-commit-msg.sh        提交信息规范校验
├── docs/                          完整文档，见下方索引
├── images.lock.txt                批量同步清单
└── ...                            治理文件（LICENSE / CONTRIBUTING / SECURITY 等）
```

**一个设计要点：** 所有同步逻辑都在 `scripts/sync.sh` 里，工作流只负责登录、组装参数、调用脚本。这样本地和 CI 跑的是同一套代码，不会出现「CI 能跑本地不行」的漂移。

---

## 文档索引

| 文档 | 内容 | 适合谁 |
| --- | --- | --- |
| [USAGE.md](docs/USAGE.md) | 完整使用指南：配置、参数、场景、验证 | 所有使用者 |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 排错手册：错误速查表与逐项排查 | 遇到问题时 |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 原理剖析：架构、流程、设计取舍 | 想读懂代码的人 |
| [MAINTAINER_GUIDE.md](docs/MAINTAINER_GUIDE.md) | 维护者手册：日常、发布、应急 | 维护者 |
| [BACKGROUND.md](docs/BACKGROUND.md) | 项目起源与原始教程归档 | 想了解来龙去脉 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 如何贡献：报 bug、提 PR、提交规范 | 想参与的人 |
| [SECURITY.md](SECURITY.md) | 安全策略与威胁模型 | 关注安全的人 |
| [CHANGELOG.md](CHANGELOG.md) | 更新日志 | 所有人 |

---

## 路线图

### 已完成

- [x] 同步到阿里云 ACR / 自建 Harbor
- [x] 多架构镜像支持（保留完整索引）
- [x] attestation 剔除路径
- [x] 批量同步与清单文件
- [x] 本地 CLI 与 `--dry-run`
- [x] 完整的 CI 与自动化
- [x] 可配置的超时、并发与重试
- [x] 增量跳过（`--skip-existing`）
- [x] 同步结果通知（钉钉 / 飞书 / Slack）
- [x] digest 记录与锁文件（`--write-lock`）
- [x] 一次推送到多个目标仓库
- [x] 按正则筛选镜像（`--filter` / `--exclude`）
- [x] 自建 registry 的 TLS 开关（`--tls-verify`）
- [x] 私有源凭证与按仓库映射（`--src-username` / `--src-credentials`）
- [x] 同步历史趋势（`scripts/history.sh`）
- [x] 完整性校验（`--verify`）与连续失败告警阈值
- [x] 多目标同步只拉取源镜像一次
- [x] 供应链加固（Actions pin 到 SHA、zizmor、OSSF Scorecard）
- [x] 清单审计（`--audit`）与上游新版本发现（`--check-updates`）
- [x] 每个目标各用各的命名规则（`--dest-keep-path`）

- [x] 检查结果的通知与「仓库体检」工作流（`Check-Registry`）
- [x] 锁文件时效性校验（`--audit-lock`）与检查报告落盘
- [x] 检查报告的趋势聚合（`history.sh --check`：一直落后 / 一直缺失 / 一直在漂移）
- [x] 趋势结果落盘与 Actions 页面查看（`history.sh --report-dir` 与 History-Trend 工作流）
- [x] 失败后的可操作化：可粘贴的重跑指引，与失败原因进报告、Step Summary 与通知
- [x] 报告可信度收尾：json 报告改由 `jq` 构造（引号不再产出坏数据）、取运行列表的失败不再冒充「没有运行记录」、坏掉的历史报告可见地跳过（不再整体崩掉或静默丢弃）
- [x] dry-run 的诚实性：干跑没搬过任何东西，因此不产出耗时、锁文件、通知与目标 digest（后两者不生效时会告警）

### 计划中

完整清单见 [路线图 Issue #4](https://github.com/nicholyx/action-sync-images/issues/4)——那里是面向贡献者的工作清单，每项都对应一个独立 Issue，包含背景、入手位置与验收标准。

> 有想法？欢迎[提 Issue](https://github.com/nicholyx/action-sync-images/issues/new/choose) 讨论——高质量的提议最好带上真实的使用场景。

---

## 贡献

欢迎任何形式的参与——报 bug、补文档、提代码，甚至只是反馈「这段话说得看不懂」都是帮助。

动手前请读一下 [CONTRIBUTING.md](CONTRIBUTING.md)，里面写清了提交信息规范、代码风格和 PR 流程。

最简单的一条：**提交前跑一次 `./scripts/lint.sh`**，它能让你少推一轮 CI。

首次贡献者会在 PR 下收到一份自动欢迎与上手提示。

---

## 致谢

本项目的雏形衍生自 [WeiyiGeek/action-sync-images](https://github.com/WeiyiGeek/action-sync-images)，感谢原作者提供了最初的思路与教程，相关文章见 [BACKGROUND.md](docs/BACKGROUND.md)。

同时感谢 [skopeo](https://github.com/containers/skopeo) 与 [regclient](https://github.com/regclient/regclient) —— 这个项目本质上是在编排这两个优秀的工具。

---

## 许可证

[MIT](LICENSE)

本项目最早衍生自 [WeiyiGeek/action-sync-images](https://github.com/WeiyiGeek/action-sync-images)（详见上方致谢）。该上游仓库未附带许可证，因此 **MIT 许可证覆盖的是本仓库中由本项目作者原创的部分**；原始的教程性内容已归档至 [docs/BACKGROUND.md](docs/BACKGROUND.md) 并保留原作者署名。如需以更明确的方式使用上游的原始内容，请自行联系原作者取得授权。

<div align="center">
<sub>如果这个项目帮你省下了一台 VPS 的钱，欢迎点个 ⭐</sub>
</div>
