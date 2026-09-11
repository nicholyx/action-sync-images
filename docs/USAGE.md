# 使用指南

本文覆盖从零开始把镜像同步跑起来的全部步骤，以及各种常见配置场景。

如果你更想先理解原理，请先看 [ARCHITECTURE.md](ARCHITECTURE.md)。

---

## 目录

- [第一步：准备凭证](#第一步准备凭证)
- [第二步：同步第一个镜像](#第二步同步第一个镜像)
- [三种同步方式](#三种同步方式)
- [输入参数详解](#输入参数详解)
- [常见配置场景](#常见配置场景)
- [验证同步结果](#验证同步结果)
- [在本地使用](#在本地使用)
- [取消同步 / 删除镜像](#取消同步--删除镜像)

---

## 第一步：准备凭证

同步需要往你的镜像仓库推送，因此必须先配置凭证。**凭证只放在 GitHub Secrets 里，绝不写进代码。**

进入仓库的 `Settings` → `Secrets and variables` → `Actions`。

### 同步到阿里云 ACR

需要两个 Secret：

| 名称 | 值 |
| --- | --- |
| `DOCKER_USERNAME` | 阿里云容器镜像服务的账号（通常是阿里云账号全名） |
| `DOCKER_PASSWORD` | 该账号的**镜像仓库固定密码**，不是阿里云登录密码 |

> 💡 固定密码在阿里云控制台：容器镜像服务 → 访问凭证 → 设置固定密码。这个密码与你的阿里云账号登录密码是两回事。

### 同步到自建 Harbor

需要三个 Secret：

| 名称 | 值 |
| --- | --- |
| `HARBOR_REGISTRY` | Harbor 地址，**不含协议前缀**，例如 `harbor.example.com` |
| `HARBOR_USERNAME` | Harbor 用户名 |
| `HARBOR_PASSWORD` | Harbor 密码或机器人账号 Token |

> 💡 建议在 Harbor 里创建一个**机器人账号**，只授予目标项目的推送权限，而不是用管理员账号。这样万一凭证泄露，影响面可控。

### 可选：配置同步结果通知

同步往往是无人值守的——定时跑，或者随手点一下就走开了。**失败了没人知道**，等集群拉不到镜像才发现，中间可能已经隔了好几天。

配置一个 webhook 就能补上这个盲区。在仓库 Secrets 中新增：

| 名称 | 值 |
| --- | --- |
| `NOTIFY_WEBHOOK` | 机器人 webhook 地址（钉钉 / 飞书 / Slack 均可） |

配置之后，每次同步结束都会推送一条摘要，失败时还会列出失败的镜像名和运行链接。

**各平台 webhook 获取方式**：

| 平台 | 获取路径 |
| --- | --- |
| 钉钉 | 群设置 → 智能群助手 → 添加机器人 → 自定义 → 复制 Webhook 地址 |
| 飞书 | 群设置 → 群机器人 → 添加机器人 → 自定义机器人 → 复制 Webhook 地址 |
| Slack | Apps → Incoming Webhooks → Add to Slack → 复制 Webhook URL |

服务商类型会根据地址**自动识别**，通常不需要额外配置。

**几点说明**：

- **不配置就完全静默**，不会产生任何通知行为
- webhook 地址本身就是凭证（知道地址就能往群里发消息），所以它必须放在 Secrets 里，日志中也不会输出
- **通知失败不会影响同步结果**——webhook 挂了、网络不通，都只是告警，不会让一次成功的同步变成红色运行
- 不想被成功通知打扰，可以在本地/脚本里用 `--notify-on failure` 只在失败时通知（工作流目前固定为始终通知）

### 可选：更换目标仓库

默认目标仓库是 `registry.cn-shenzhen.aliyuncs.com/nicholyx`。想换成别的，不必改代码：

`Settings` → `Secrets and variables` → `Actions` → **Variables** 标签页 → `New repository variable`：

| 名称 | 值示例 |
| --- | --- |
| `ALIYUNCS_REGISTRY` | `registry.cn-hangzhou.aliyuncs.com/your-namespace` |

设置后工作流会自动使用它；不设置则使用内置默认值。登录地址会从该变量的第一段自动推导，所以换区域（比如从深圳换到杭州）也只需要改这一个地方。

---

## 第二步：同步第一个镜像

1. 打开仓库的 **Actions** 标签页
2. 左侧选择 `Sync-Images-to-AliYuncs`
3. 点击右上角 **Run workflow**
4. 在 `images_src` 里填入源镜像，例如：

   ```text
   registry.k8s.io/pause:3.9
   ```

5. 其余保持默认，点击绿色的 **Run workflow**

大约 30 秒后，进入这次运行，你会看到：

- 顶部 **Summary** 区域有一张同步结果表格
- 页面上有 `sync-report-aliyuncs` 产物可下载
- 运行名显示为 `你的用户名 - Sync registry.k8s.io/pause:3.9 to AliYuncs.`

同步后的镜像地址是：

```text
registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

拉取验证：

```bash
docker pull registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

---

## 三种同步方式

### 方式一：同步单个镜像

最简单，适合临时需要某个镜像的场景。

在 `Sync-Images-to-AliYuncs` 的 `images_src` 里填一个镜像。

### 方式二：一次同步多个镜像

`images_src` 支持批量输入。**换行、逗号、分号**都可以作分隔符，也可以混用：

```text
registry.k8s.io/kube-apiserver:v1.31.0
registry.k8s.io/kube-controller-manager:v1.31.0
registry.k8s.io/kube-scheduler:v1.31.0
```

或者写成一行：

```text
registry.k8s.io/pause:3.9, nginx:1.27, redis:7.4
```

特点：

- 重复的镜像会自动去重（保持书写顺序）
- **单个镜像失败不会中断其余镜像**，全部处理完后汇总报告
- 只要有任意一个失败，整个工作流就以失败结束（这样你不会漏看）

### 方式三：按清单文件批量同步

适合「维护一套固定镜像集合」的场景——比如某个 Kubernetes 版本的组件、某套中间件栈。

1. 编辑仓库根目录的 `images.lock.txt`，写入需要的镜像（每行一个，`#` 开头为注释）
2. 触发 `Sync-Batch` 工作流

工作流会读取该文件并批量同步。也可以用 `lockfile` 输入指定其它路径，便于维护多份清单。

> 💡 这个工作流默认**只支持手动触发**。配置里预留了 `schedule` 定时任务，取消注释后可实现「每天自动跟上上游更新」。开启前请确认你接受持续消耗 Actions 额度与镜像仓库存储。

---

## 输入参数详解

### Sync-Images-to-AliYuncs

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | 源镜像。可填多个，用换行/逗号/分号分隔。不需要 `docker://` 前缀 |
| `strip_attestation` | | `false` | 剔除 attestation manifest。源镜像带 provenance/SBOM 时勾选（见下方说明） |
| `platforms` | | 自动探测 | 保留哪些平台，如 `linux/amd64,linux/arm64`。**仅在勾选上一项时生效** |
| `concurrency` | | `4` | 并发同步的镜像数量。填 `1` 即回到串行 |
| `skip_existing` | | `true` | 跳过目标仓库中已存在且完全相同的镜像 |
| `dry_run` | | `false` | 只打印将要执行的命令，不实际推送。用于确认目标地址是否正确 |

**关于 `strip_attestation`：** 什么时候该勾？简单判断法是——如果同步时报了包含 `unknown manifest class` 的错误，就勾上重试。常见需要勾选的有 `ghcr.io/netbirdio/*` 这类用 BuildKit 构建且开启了 provenance 的项目。原理见 [ARCHITECTURE.md](ARCHITECTURE.md#深入理解-attestation-问题)。

**关于 `platforms`：** 留空时会自动读取源镜像的平台列表。只有当自动探测失败（比如源是单平台镜像）时才需要手动指定。如果源镜像只有 `linux/amd64` 而你按默认的 `linux/amd64,linux/arm64` 去同步，会失败——这时候改成只填 `linux/amd64` 即可。

### Sync-Images-to-Harbor

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | 源镜像，支持批量的规则同上 |
| `images_dest` | ✅ | — | 目标路径，会拼在 `HARBOR_REGISTRY` 之后，例如 `library/nginx:1.27` |
| `concurrency` | | `4` | 并发同步的镜像数量 |
| `skip_existing` | | `true` | 跳过已存在的相同镜像 |
| `dry_run` | | `false` | 同上 |

> ⚠️ Harbor 路径是**精确匹配**，不会做「把 `/` 换成 `_`」的压平处理。请确保 Harbor 中已经存在对应的项目（如 `library`），否则会推送失败。

### Sync-Batch

| 参数 | 必填 | 默认 | 说明 |
| --- | :---: | --- | --- |
| `lockfile` | ✅ | `images.lock.txt` | 清单文件路径 |
| `dest_registry` | | 见说明 | 目标仓库前缀。留空则依次取 `ALIYUNCS_REGISTRY` 变量、内置默认值 |
| `concurrency` | | `6` | 并发同步的镜像数量 |
| `skip_existing` | | `true` | 跳过已存在的相同镜像 |
| `dry_run` | | `false` | 同上 |

---

## 常见配置场景

### 场景一：同步多架构镜像（amd64 + arm64）

默认走 `skopeo copy --all`，**所有平台会自动完整保留**，你不需要做任何配置。

同步完成后，用 `docker buildx imagetools inspect` 可以确认：

```bash
docker buildx imagetools inspect registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

输出里应该能看到 `linux/amd64` 和 `linux/arm64` 两个平台。

### 场景二：同步带 attestation 的镜像

以 `ghcr.io/netbirdio/netbird:0.28.0` 为例：

```text
images_src:        ghcr.io/netbirdio/netbird:0.28.0
strip_attestation: ✅ 勾选
platforms:         （留空，自动探测）
```

### 场景三：源镜像只有单平台

```text
images_src:        some.registry/only-amd64-image:1.0
strip_attestation: ✅ 勾选
platforms:         linux/amd64
```

### 场景四：换一个阿里云命名空间

不用改代码，设置仓库变量即可：

```text
ALIYUNCS_REGISTRY = registry.cn-hangzhou.aliyuncs.com/your-company
```

### 场景五：同步到 Docker Hub

`sync.sh` 本身不限定目标仓库，只要把 `--dest` 指向 Docker Hub 即可。

最省事的做法是新增一个工作流（可以复制 `sync-images-aliyuncs.yml` 改造），把目标地址换成 `docker.io/你的用户名`，并配置对应的 Secrets。

> ⚠️ Docker Hub 免费账号有拉取速率限制，且**公共仓库的镜像对所有人可见**。同步前请确认镜像内容适合公开。

### 场景六：用 `dry_run` 先确认目标地址

不确定镜像名会被转成什么样？先勾上 `dry_run` 跑一次，日志里会打印出完整命令：

```text
[dry-run] skopeo copy --all --retry-times 3 \
  docker://registry.k8s.io/coredns/coredns:v1.11.1 \
  docker://registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
```

确认无误后取消勾选，再正式跑一次。

### 场景七：让批量同步跑得更快

同步镜像的时间几乎全花在网络等待上，所以**并发**和**跳过**是最有效的两个手段。

**并发** —— `concurrency` 控制同时进行几个镜像的同步，默认 4（批量工作流是 6），建议范围 4~8。
实测 4 个各需 1 秒的镜像：串行耗时 4 秒，并发后 1 秒。

> ⚠️ 不建议设得过高。上游仓库可能对并发连接限流，结果反而更慢，极端情况下还会触发风控。

**增量跳过** —— `skip_existing` 默认开启。同步前会比对源与目标的 manifest，
完全相同时直接跳过。定期同步的场景下绝大部分镜像都会被跳过，一次运行通常几秒就结束。

> 比对过程中任何一步失败都会判定为「需要同步」——宁可多推一次，也不会错误地跳过。
> 另外注意：`strip_attestation` 模式会重建索引，目标的 digest 必然与源不同，
> 比较 digest 没有意义，因此该模式下不做跳过。

**超时** —— 单个镜像默认 600 秒。某个镜像特别大、或者上游偶尔抽风时，
超时能让它快速失败并继续处理其余镜像，而不是卡住整个任务。
工作流没有暴露这个参数，需要时可在本地用 `--timeout` 指定。

---

## 验证同步结果

### 在 Actions 里看

每次运行结束后，**Summary** 页面会渲染出一张表格：

| 源镜像 | 目标镜像 | 结果 | 平台 | 耗时 |
| --- | --- | :---: | --- | --- |
| `registry.k8s.io/pause:3.9` | `registry.cn-shenzhen.aliyuncs.com/...` | ✅ | 全部（--all） | 12s |

失败的会显示 ❌，并可在日志里找到具体错误。

### 在本地拉取验证

```bash
# 阿里云需要先登录
docker login registry.cn-shenzhen.aliyuncs.com

docker pull registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

### 确认架构完整性

```bash
docker buildx imagetools inspect <目标镜像地址>
```

如果发现目标只有单一架构而源是多架构，说明同步时丢了平台——正常情况下不应该发生，请参考[排错手册](TROUBLESHOOTING.md)。

### 在集群里直接使用

同步过来的镜像可以直接替换原有引用。以 kubeadm 为例：

```bash
kubeadm init \
  --image-repository=registry.cn-shenzhen.aliyuncs.com/nicholyx \
  ...
```

注意这种用法要求目标仓库里的镜像路径与上游一致。本项目的扁平化命名（`registry.k8s.io_pause:3.9`）与之不兼容，需要改用 `--dest-exact` 模式同步，或使用 Harbor 工作流保留原始路径结构。

---

## 在本地使用

不依赖 GitHub Actions，本地也能跑同一套逻辑（需要 `skopeo`，剔除 attestation 时还需要 `regctl`）：

```bash
# macOS
brew install skopeo regclient

# 预览，不实际推送
./scripts/sync.sh \
  --src registry.k8s.io/pause:3.9 \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --dry-run

# 真正同步（需要先 docker login）
./scripts/sync.sh \
  --src registry.k8s.io/pause:3.9 \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx

# 批量
./scripts/sync.sh --file images.lock.txt --dest registry.cn-shenzhen.aliyuncs.com/nicholyx

# 剔除 attestation
./scripts/sync.sh \
  --src ghcr.io/netbirdio/netbird:0.28.0 \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --strip-attestation
```

完整参数见 `./scripts/sync.sh --help`。

---

## 取消同步 / 删除镜像

本项目**只负责推送，不提供删除功能**——删除是破坏性操作，不适合做成一个点错就执行的按钮。

需要删除时，请到对应仓库的控制台操作：

- **阿里云 ACR**：容器镜像服务 → 镜像仓库 → 选择仓库 → 版本 → 删除
- **Harbor**：项目 → 仓库 → 制品 → 删除

> 💡 如果只是想停止同步某个镜像，从 `images.lock.txt` 中删掉或注释掉对应行即可，已同步的镜像不受影响。
