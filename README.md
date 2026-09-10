<div align="center">

# action-sync-images

**借用 GitHub Actions 当免费的海外中转机，把拉不动的镜像搬回国内仓库。**

不需要 VPS，不需要服务器，不依赖别人同步好的镜像。

[![CI](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml/badge.svg)](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![GitHub stars](https://img.shields.io/github/stars/nicholyx/action-sync-images?style=social)](https://github.com/nicholyx/action-sync-images/stargazers)

[快速开始](#快速开始) · [使用文档](docs/USAGE.md) · [工作原理](docs/ARCHITECTURE.md) · [排错手册](docs/TROUBLESHOOTING.md) · [贡献指南](CONTRIBUTING.md)

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
- **失败不中断** —— 批量同步时单个镜像失败不影响其余镜像，最后统一汇总
- **结果一目了然** —— 运行结束直接生成结果表格，无需翻日志
- **可在本地复现** —— 同一套逻辑封装成 `scripts/sync.sh`，本地也能跑，支持 `--dry-run`
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
| `dry_run` | | `false` | 只打印命令不推送，用来确认目标地址 |

### Sync-Images-to-Harbor

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | 源镜像，支持批量 |
| `images_dest` | ✅ | — | 目标路径，拼在 `HARBOR_REGISTRY` 之后，如 `library/nginx:1.27` |
| `dry_run` | | `false` | 同上 |

### Sync-Batch

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `lockfile` | ✅ | `images.lock.txt` | 清单文件路径 |
| `dest_registry` | | 见说明 | 目标仓库前缀，留空则用 `ALIYUNCS_REGISTRY` 变量或内置默认值 |
| `dry_run` | | `false` | 同上 |

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

不确定会变成什么样？**勾上 `dry_run` 跑一次**，日志里会打印完整的命令。

自建 Harbor 支持多级路径，用的是精确模式（不做压平）：

```text
源：nginx:1.27  →  目标：harbor.example.com/library/nginx:1.27
```

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
<summary><b>在本地跑，不用 GitHub Actions</b></summary>

```bash
brew install skopeo regclient   # macOS

# 先预览
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
│   ├── ci.yml                     CI：静态检查 + 冒烟测试
│   ├── labeler.yml                PR 自动打标签
│   ├── stale.yml                  Issue/PR 过期管理
│   ├── welcome.yml                欢迎首次贡献者
│   └── release.yml                自动发布
├── scripts/
│   ├── sync.sh                    ★ 同步引擎（全项目唯一的逻辑实现）
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

### 计划中

- [ ] 支持为源镜像配置独立凭证（同步私有仓库镜像）
- [ ] 同步结果的历史记录与趋势
- [ ] 支持一次性推送到多个目标仓库
- [ ] 可配置的超时与并发度

有想法？欢迎[提 Issue](https://github.com/nicholyx/action-sync-images/issues/new/choose) 讨论。

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

<div align="center">
<sub>如果这个项目帮你省下了一台 VPS 的钱，欢迎点个 ⭐</sub>
</div>
