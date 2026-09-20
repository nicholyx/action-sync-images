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
- [失败了怎么重跑](#失败了怎么重跑)
- [查看历史趋势](#查看历史趋势)
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
- 不想被成功通知打扰，可以在本地/脚本里用 `--notify-on failure` 只在失败时通知

**降低通知噪音**：默认每次失败都会通知，而失败原因里相当一部分是上游抖动——重跑一次就好。天天响的通知很快就没有人看了，真正的问题反而被淹没。

三个同步工作流都提供了 `notify_after_failures` 输入：**同一个镜像连续失败 N 次才通知**，中间成功过一次就重新计数，单个镜像独立统计。

| 设置 | 效果 |
| --- | --- |
| `1`（默认） | 每次失败都通知 |
| `3` | 同一镜像连续失败 3 次才通知，通知里会注明「连续第 3 次失败」 |

实现说明，供排查时参考：连续次数从**历史运行的报告 Artifact** 中推算（默认取本工作流的 `sync-report-*`），不是保存在仓库里的状态。因此：

- 触发通知的运行会多几秒用于下载历史报告
- 历史报告拿不到时（Artifact 过期、首次运行）一律按「连续失败 1 次」处理——**宁可不通知，也不基于猜测误报**
- 历史窗口受 Artifact 保留期限制（默认 30 天），足够判断「是不是一直在失败」

**体检结果同样能推送。** `--audit` 与 `--check-updates` 是只读的，但它们的结论同样无人值守——定期跑一次，只有出问题时才需要有人知道。

```bash
./scripts/sync.sh --file images.lock.txt -d <目标仓库> --audit \
  --notify-webhook "$NOTIFY_WEBHOOK" --notify-on failure
```

在检查模式下，`--notify-on failure` 的含义是「有需要关注的项」——存在落后 / 缺失 / 无法判定，或有仓库没查成；**全绿时不会打扰**。通知里只列需要处理的条目（最多 20 条，完整结果看运行页面），不会把整张表推过去把重点淹没。

> `--notify-after-failures` 只在同步模式下有意义——检查没有「连续失败」这个概念，在检查模式下显式传入会告警。

### 可选：更换目标仓库

默认目标仓库是 `registry.cn-shenzhen.aliyuncs.com/nicholyx`。想换成别的，不必改代码：

`Settings` → `Secrets and variables` → `Actions` → **Variables** 标签页 → `New repository variable`：

| 名称 | 值示例 |
| --- | --- |
| `ALIYUNCS_REGISTRY` | `registry.cn-hangzhou.aliyuncs.com/your-namespace` |

设置后工作流会自动使用它；不设置则使用内置默认值。登录地址会从该变量的第一段自动推导，所以换区域（比如从深圳换到杭州）也只需要改这一个地方。

### 可选：同步私有仓库的镜像

上面几条讲的都是**同步到**哪里，这一条讲的是**从哪里同步**。

公司内部 Harbor、私有 GHCR 包这类需要认证的源，匿名拉取会在第一步就 401。两种配置方式：

**方式一：单一凭证**（源仓库只有一家时最简单）

| Secret | 值 |
| --- | --- |
| `SRC_REGISTRY_USERNAME` | 源仓库的用户名 |
| `SRC_REGISTRY_PASSWORD` | 源仓库的密码或 Token |

**方式二：按仓库映射**（清单混有多个私有源时）

配置一个 Secret `SRC_CREDENTIALS`，内容为多行文本：

```text
harbor.internal.example.com  alice   token-a
ghcr.io                      bob     ghp_xxx
```

每行三个字段：**host 用户名 密码**，`#` 开头为注释。同步时按源镜像的 registry host 匹配凭证，**没匹配到的走匿名**——公开镜像不受影响，也不必为每个私有源拆分运行。

> ⚠️ 两种方式**互斥**：同时配置会直接报错。前者把一套凭证发给所有（或指定的那个）源仓库，后者按仓库各配各的——混用的语义只能靠猜，脚本一律拒绝。

配置后三个同步工作流都会自动带上它们，无需改动任何工作流文件。

> ⚠️ **源与目标的凭证是分开的两套。** 目标是你的仓库，源是别人的系统——把目标仓库的凭证发往源仓库，等于把「往我仓库推送」的权限交给一个你并不信任的第三方。所以这里刻意没有「复用已有凭证」的选项，哪怕实践中两者偶尔相同。

凭证会被发往哪些仓库？日志里会列出来（本地单一凭证模式）：

```text
[信息] 源仓库凭证已装载（1 个仓库）：harbor.internal.example.com
```

本地单一凭证模式下，如果清单里**混有公开镜像**（比如同时有 `docker.io` 和内部 Harbor），凭证会被发往所有源仓库，其中并不需要凭证的那些反而可能因为凭证不匹配而失败。两个解法：

```bash
# 解法一：固定到一个仓库（--src-registry）
SYNC_SRC_USERNAME=alice SYNC_SRC_PASSWORD='…' SYNC_SRC_REGISTRY=harbor.internal.example.com \
  ./scripts/sync.sh --file images.lock.txt --dest <目标仓库>

# 解法二：按仓库映射（--src-credentials，或环境变量值为文件内容）
SYNC_SRC_CREDENTIALS="$(cat src-credentials.txt)" \
  ./scripts/sync.sh --file images.lock.txt --dest <目标仓库>
```

映射方式下这个问题天然不存在：没匹配到的 host 根本不会收到凭证。

> 💡 凭证**不会出现在命令行或日志里**。脚本把它写进一个 600 权限的临时文件，用 `--src-authfile` 交给 skopeo——命令行参数对同机其他进程可见（`ps aux`），也容易被调用方的日志语句原样打印出去。该文件在脚本退出时删除。

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
| `dry_run` | | `false` | 先输出同步计划，再打印命令；不实际推送。用于确认筛选结果与目标地址 |

> 每次同步都会自动记录源与目标的 digest（详见[关于 digest](#关于-digest)），无需额外配置。

### 同时推送到多个目标

`--dest` 可以重复指定——同一个镜像经常需要落在多个地方（阿里云给国内集群、Harbor 做内部归档）：

```bash
./scripts/sync.sh \
  --src registry.k8s.io/pause:3.9 \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --dest harbor.example.com/mirror
```

几点需要注意：

- **每个目标独立判定**：A 目标成功、B 目标失败时，报告里能直接看出是哪个目标的问题，而不是笼统的「同步失败」
- **增量跳过按目标独立执行**：某个目标已是最新，不代表其他目标也是
- **任一目标失败则整体失败**（退出码 `2`）
- **源只拉取一次**：多个目标都需要推送时，源镜像先拉到本地 OCI 目录中转，再逐目标推送——对大镜像能省下成倍的拉取时间，也降低被上游限流的概率。单目标不走中转；`--strip-attestation` 模式要重建索引，也不走中转。中转准备的任何环节失败（如临时空间不足）都会自动退化为逐目标拉取并告警，不影响结果

> ⚠️ `--dest-exact` 与 `--dest` **不能混用**：前者指定完整目标地址、后者是待拼接的前缀，混在一起会让目标变得含糊。脚本会直接拒绝这种组合，而不是猜你的意图。

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
| `filter` | | 空 | 只同步匹配该正则的镜像（ERE）。详见[场景九](#场景九只同步清单里的一部分镜像) |
| `exclude` | | 空 | 跳过匹配该正则的镜像（ERE） |

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

### 场景六：用 `dry_run` 先确认同步计划

不确定筛选结果、目标名或执行路径？先勾上 `dry_run` 跑一次。默认同步模式会先输出同步计划预览，再打印完整命令：

```text
[信息] 同步计划预览（dry-run）
[信息] 源镜像 1 个 · 目标 1 个 · 预计命令 1 条
[信息] 执行路径：skopeo copy --all · 平台策略：全部（--all）
[信息] 计划映射：
  [1] registry.k8s.io/coredns/coredns:v1.11.1 → registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1

[dry-run] skopeo copy --all --retry-times 3 \
  docker://registry.k8s.io/coredns/coredns:v1.11.1 \
  docker://registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
```

在 Actions 里运行时，计划也会写入 **Summary** 的 `Dry-run 同步计划` 表格，方便确认所有源 → 目标映射。

计划预览刻意只回答「这次会执行哪些搬运命令」：

- 映射来自同一套目标解析逻辑，而不是重新拼接一份输入
- `--skip-existing` 是否能跳过需要查询目标仓库，计划**不预测**跳过结果
- `--strip-attestation` 未显式指定平台时，计划只说明「实际执行时自动探测」，不会虚构平台列表
- 非法引用不会生成映射，并会在计划里标出实际执行会失败
- `--audit` / `--check-updates` / `--audit-lock` 的 `--dry-run` 仍按只读检查的既有语义忽略，不渲染同步计划

同时，**同步模式下**`--dry-run` 没有真的搬过任何东西，因此**任何描述「搬了什么、花了多久、搬完了」的输出都为空或零**：报告里的耗时恒为 0（耗时排行也随之隐去）、`dest_digest` 留空（`source_digest` 照常记录，它描述的是源镜像本身）。`--write-lock` 与 `--notify-webhook` 因为没有对象而不生效——前者记录的是「这次推上去的是哪一份」，后者通报的是「这次搬得怎么样」——显式传入时会有一条告警说明。要生成锁文件或发送通知，去掉 `--dry-run` 再跑一次。

确认无误后取消勾选，再正式跑一次。

### 场景七：锁定一份镜像，用于精确复现

tag 是**可以变**的——上游重新构建一次，同一个 `v1.2.3` 背后可能就是完全不同的镜像。
digest 不会。

每次同步都会在报告中记录源与目标的 digest。如果需要把「当时那一份」固定下来，
用 `--write-lock` 生成锁文件：

```bash
./scripts/sync.sh \
  --src registry.k8s.io/pause:3.9 \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --write-lock images.lock.resolved.txt
```

生成的内容形如：

```
registry.k8s.io/pause:3.9@sha256:dff9de1091914871…
```

这个文件可以**直接回喂给脚本**，实现精确复现：

```bash
./scripts/sync.sh --file images.lock.resolved.txt --dest <目标仓库>
```

此时源用的是 `镜像@digest`，无论上游怎么改名重建，拉到的都是同一份内容。

> 💡 把锁文件提交到仓库，就等于给「这份环境当时用的是哪些镜像」留了一份可查证的记录。

### 关于 digest

| 概念 | 是否可变 | 用途 |
| --- | --- | --- |
| tag（`v1.2.3`） | ✅ 可被覆盖 | 日常使用 |
| digest（`sha256:…`） | ❌ 不可变 | 审计、复现、校验 |

同步报告中的 digest 有两个用途：

- **审计**：出问题时能查清「三天前同步的那份 `latest` 到底是哪个」
- **验证**：比对源与目标的 digest 是否一致

> ⚠️ 需要说明的是，**目标 digest 与源不一致不一定是故障**。部分 registry
> （如阿里云 ACR 对 Windows 平台）会重新包装 manifest，导致顶层 digest 变化，
> 而实际的镜像内容是一致的。脚本遇到这种情况会在日志中提示，不会判定为失败。

拿不到 digest 时（例如网络问题）不会影响同步本身，只会在报告中留空。

### 场景八：让批量同步跑得更快

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

### 场景九：只同步清单里的一部分镜像

清单文件是「期望状态的完整记录」，但**某一次同步**往往只想覆盖其中一部分：
这次只补同步 `kube-*` 组件、临时跳过某个已知有问题的镜像、只同步某个 registry 下的东西。

与其反复编辑清单文件（改完还得记得改回来，而且很容易忘），不如把筛选条件写在命令上：

```bash
# 只同步 kube-* 组件
./scripts/sync.sh --file images.lock.txt --dest <目标仓库> \
  --filter 'kube-'

# 从清单里临时排掉 apiserver
./scripts/sync.sh --file images.lock.txt --dest <目标仓库> \
  --exclude 'apiserver'

# 组合使用：先 filter 后 exclude
./scripts/sync.sh --file images.lock.txt --dest <目标仓库> \
  --filter '^registry\.k8s\.io/' --exclude 'apiserver'
```

两者都接受 **ERE 正则**，匹配的是源镜像的**完整引用**（`registry.io/ns/name:tag`）。

**被排除的镜像仍会出现在结果表和报告中**，标为 `⊘ 已排除` 并注明是哪条规则把它排掉的：

```text
 ✓ registry.k8s.io/kube-scheduler:v1.31.0
 ⊘ registry.k8s.io/kube-apiserver:v1.31.0
   匹配 --exclude「apiserver」
```

这一点是刻意的：清单里列了 20 个镜像、结果表只出现 19 行，使用者会以为第 20 个同步了。
**看得见的排除才是排除，看不见的排除是隐患。**

> ⚠️ 正则写错会立即以退出码 `1` 报错，不会跑到一半才发现。
> 如果筛选条件把**全部**镜像都排掉了，同样按参数错误处理——静默地「什么都没同步然后报成功」
> 是最糟的结果。

> 💡 排除不等于失败。筛选是有意为之的操作，因此不会影响退出码：
> 只要剩下的镜像都同步成功，退出码就是 `0`。

---

### 场景十：调整重试行为

**先说结论：多数情况下你不需要管它，两条路径本来就在做指数退避。**

| 路径 | 重试由谁负责 | `--retries` 是否生效 |
| --- | --- | --- |
| 默认（skopeo） | skopeo 的 `--retry-times` | ✅ 生效 |
| `--strip-attestation`（regctl） | regclient 内部策略 | ❌ 不生效，**会告警** |

#### 为什么 regctl 路径不吃 `--retries`

`regctl` 底层的 regclient 有一套比我们更完善的重试策略：

- 默认重试 5 次，指数退避，上限 30 秒
- HTTP **429 与 5xx** 触发退避
- **尊重 `Retry-After` 响应头**——registry 说等多久就等多久

最后一条尤其重要：它比脚本自己猜一条退避曲线准得多。而脚本层只能看到退出码，分不清「被限流」和「镜像不存在」——对后者重试纯属浪费时间。

因此我们没有在脚本里重新实现退避。代价是 `--retries` 在 regctl 路径下无效，这个限制会**明确告警**而不是被静默忽略：

```text
[警告] --retries 10 在 regctl 路径下不生效：regclient 有自己的重试策略（默认 5 次），本次将忽略
```

#### 什么时候才需要 `--retry-delay`

skopeo 在不指定 `--retry-delay` 时，等待时间随失败次数**指数增长**——这对绝大多数 registry 都是最优解。

例外是**窗口式限流**的自建仓库：它们的额度按固定时间窗重置，指数退避的短间隔会一直撞在窗口边界上，反而是固定的长间隔更稳。这时可以指定：

```bash
./scripts/sync.sh --src <镜像> --dest <目标仓库> \
  --retries 5 --retry-delay 30s
```

值的写法是时长：`10s`、`1m`、`2m30s`。

> ⚠️ 不要一遇到失败就加大重试次数。如果失败原因是「镜像不存在」「没有权限」，重试再多次也不会成功，只会让一次注定失败的同步拖得更久。先看日志里的具体错误。

---

### 场景十一：校验同步结果的完整性

**先说结论：`skopeo copy` 返回 0，不代表每个平台都完整推上去了。** 传输中断、目标 registry 重新包装、限流导致的静默截断，都可能只影响部分平台——而命令的退出码看不出这些。

`--verify` 在同步成功后逐平台比对源与目标的子 manifest digest：

```bash
./scripts/sync.sh --src <镜像> --dest <目标仓库> --verify
```

- 全部一致 → 日志给出「校验通过」
- 有差异 → 该镜像判定为**失败**，并明确列出哪个平台缺失（退出码 `2`）
- 拿不到 digest（网络问题）→ 只告警，**不判定失败**——校验不该比同步本身更容易失败

**默认关闭**，原因有两个：

- 校验要为每个镜像多做两次 `inspect`，几十个镜像的清单会明显变慢
- 「同步成功」对多数场景已经够用；需要精确性（比如镜像要进生产）时再打开

比对规则与增量跳过共用同一套逻辑：按**各平台的子 manifest digest** 比对（顶层 digest 会因 registry 重新包装而变化），Windows 平台被排除在外（其 manifest 在传输中必然重新生成）。

三个同步工作流都开放了 `verify` 输入。

---

### 场景十二：审计清单与目标仓库的差距

定期同步有个绕不开的麻烦：清单记录着期望状态，但**「仓库现在到底跟上没有」只有真的跑一次同步才知道**——而同步是会真推送的。只想看一眼状态时，不该被迫先搬一趟。

`--audit` 只读地检查清单里每个镜像在目标仓库中的状态，**不推送任何东西**：

```bash
./scripts/sync.sh --file images.lock.txt \
  --dest registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --audit
```

输出形如：

```text
 ✓ 最新  registry.k8s.io/pause:3.9
   → registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
 ✗ 缺失  registry.k8s.io/etcd:3.5.15-0
   → registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_etcd:3.5.15-0
   目标仓库中不存在
 ⚠ 落后  registry.k8s.io/coredns/coredns:v1.11.1
   → registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
   目标与源的平台摘要不一致
 ? 无法判定  quay.io/coreos/flannel:v0.25.5
   → registry.cn-shenzhen.aliyuncs.com/nicholyx/quay.io_coreos_flannel:v0.25.5
   源镜像无法访问：dial tcp: lookup quay.io: no such host

审计完成：最新 1 ｜ 落后 1 ｜ 缺失 1 ｜ 无法判定 1
```

四种状态必须分清楚：

| 状态 | 含义 | 该怎么办 |
| --- | --- | --- |
| ✅ 最新 | 目标存在，且与源的平台摘要一致 | 不用管 |
| ⚠️ 落后 | 目标存在，但内容与源不同 | 重新同步 |
| ❌ 缺失 | 目标仓库里没有这个镜像 | 同步过去 |
| ❓ 无法判定 | 源或目标查不到（网络、凭证、私有仓库） | 先解决访问问题再看 |

**「无法判定」单独占一类，不并进「落后」。** 查询失败和内容不一致是两回事：把网络抖动显示成「落后」，会让人去排查一个并不存在的问题——错误的信息比没有信息更糟，因为它会被当成结论。同理，源自身取不到时报的是「无法判定」，而不是目标「缺失」。

审计的退出码：

| 码 | 含义 |
| --- | --- |
| `0` | 全部最新，且全部可判定 |
| `1` | 参数或环境错误 |
| `2` | 审计未得出「全部最新」——存在落后、缺失，或有无法判定的项 |

**「没查完」也返回 `2`**，是为了让 CI 门禁不至于在检查本身都没做完时就报绿。究竟属于哪一种，报告正文里分得很清楚。

审计是只读的，接进定时任务也不违反「同步必须显式触发」这条红线：

```yaml
- name: 镜像仓库体检
  run: |
    ./scripts/sync.sh --file images.lock.txt --dest "$DEST" --audit
```

几条需要注意的限制：

- **不能与 `--strip-attestation` 同时使用**。剔除 attestation 会重建索引，目标的平台摘要必然与源不同，审计只会给出一排**假的「落后」**。这个组合会直接报错，而不是默默给出错误结论。
- `--dry-run` / `--write-lock` / `--verify` / `--skip-existing` 在审计模式下没有作用，显式传入时会告警。
- 加 `--report-dir` 可把报告落盘（`.md` + `.json`，JSON 顶层带 `generated_at` 与汇总计数），体检工作流已自动上传为 Artifact。
- 可与 `--filter` / `--exclude` 组合；被排除的镜像**仍会出现在报告里**并标注原因——报告里少一项，看的人会默认它是好的。
- 看完报告要动手时，去掉 `--audit` 重跑同一条命令即可：已经最新的会被 `--skip-existing` 自动跳过。

---

### 场景十三：发现上游的新版本

清单锁的是某个 k8s 版本的整套组件。上游发新版本时（v1.31 → v1.32），**没有任何机制会通知你**——得自己盯上游发布、自己查有哪些新 tag、再手工更新清单。这是定期同步流程里唯一还需要人肉盯着的环节。

`--check-updates` 把上游的 tag 列表拉下来与清单对比：

```bash
./scripts/sync.sh --file images.lock.txt --check-updates
```

```text
registry.k8s.io/kube-apiserver
  清单中：v1.31.0
  上游共 340 个 tag，其中 12 个不在清单中，版本序最大的 5 个：
    v1.32.3 v1.32.2 v1.32.1 v1.31.4 v1.31.3

quay.io/coreos/flannel
  清单中：v0.25.5
  无法查询上游 tag 列表：unauthorized: authentication required

检查完成：2 个源仓库，1 个有未收录的 tag（共 12 个），1 个查询失败
```

三条需要说清楚的设计边界：

**只报告，不修改清单。** 升到哪个版本涉及兼容性判断（API 变更、周边组件配套），是人的决定。工具只负责让信息可见。清单要改，请手工编辑 `images.lock.txt`。

**不做语义化版本判断，也不过滤预发布。** 上游 tag 命名未必规整——`1.27-alpine`、`latest`、`v1.32.0-rc.1` 都可能出现，语义化比较会给出**错误**结论（把 rc 当成比正式版更新）。这里只用版本序粗排、原样展示。因此列表里出现 `latest`、出现比清单里**更旧**的 tag 都是正常的：它只说明「上游有这个 tag 而清单没有」，**不是升级建议**。

**输出收敛，但总数始终给出。** 一个仓库动辄几百个 tag，全列出来等于没有输出。默认只列版本序最大的 5 条（`--updates-limit` 可调）——但总数一定会报，只显示前几条而不说总数会让人低估差距。

其他几点：

- **不需要目标地址**：`--check-updates` 只查上游，不必传 `--dest`
- **同一个源仓库的多个 tag 只查一次上游**（清单里十几个 k8s 组件大多来自同一个仓库）
- 私有上游复用 `--src-username` / `--src-credentials` 的凭证装载路径
- 单个仓库查不成不影响其他仓库，会单独报出来
- 退出码：`0` 清单已覆盖；`2` 有未收录的 tag**或**有仓库没查成；`1` 参数错误
- 与 `--audit` 互斥——检查对象不同（上游 vs 目标仓库），报告也是两套，请分两次运行
- 加 `--report-dir` 可把报告落盘（`.md` + `.json`），JSON 里每个仓库一条记录，含未收录的 tag 列表

---

### 场景十四：一次推往两类仓库，各用各的命名规则

`--dest` 使用「压平」规则（`/` → `_`），因为**阿里云 ACR 个人版不支持多级仓库路径**。但自建 Harbor 支持多级路径，而且保留原路径更符合直觉——一眼能看出上游是谁。

于是「阿里云给国内集群 + Harbor 做内部归档」这个最典型的多目标场景，两边要的名字其实不一样：

| 目标 | 期望的镜像名 |
| --- | --- |
| 阿里云 ACR | `<前缀>/registry.k8s.io_pause:3.9` |
| 自建 Harbor | `<前缀>/registry.k8s.io/pause:3.9` |

`--dest-keep-path` 就是为后者准备的——语义与 `--dest` 完全相同（前缀 + 源镜像路径），只是**保留路径结构**：

```bash
./scripts/sync.sh --file images.lock.txt \
  -d registry.cn-shenzhen.aliyuncs.com/nicholyx \
  --dest-keep-path harbor.example.com/mirror
```

```text
registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9   ← 压平（--dest）
harbor.example.com/mirror/registry.k8s.io/pause:3.9                    ← 保留路径（--dest-keep-path）
```

两者可以任意混用、顺序无关，每个目标的命名**互相独立**（某个目标推送失败不影响另一个）。不确定会变成什么样，照例先跑一次 `--dry-run`。

**一个边界**：仓库路径里不允许出现冒号，所以源 registry 带端口时（`localhost:5000/foo`），端口那一段会被压成下划线，结果是 `<前缀>/localhost_5000/foo`。层级结构仍然保留，只是这一段没法原样带入。

另外，`--dest-keep-path` 与 `--dest-exact` 不能同时使用：前者是待拼接的前缀，后者是完整地址，混用时目标会变得含糊，因此直接报错而不是默默忽略其中一个。

### 场景十五：在 Actions 页面做体检（不用装 CLI）

场景十二与十三用的是本地命令行。但更多时候，你只是想在网页上点一下——**体检工作流就是为这个准备的**：不用装任何工具，也不用克隆仓库。

打开 **Actions** → 左侧选 `Check-Registry` → **Run workflow**：

| 输入 | 说明 |
| --- | --- |
| `mode` | `audit`：清单与目标仓库的差距；`updates`：上游与清单的差距；`lock`：锁文件时效校验（上游还是锁定的那份 digest 吗） |
| `lockfile` | 清单文件路径，默认 `images.lock.txt`（`audit` / `updates` 用） |
| `lock_file` | 锁文件路径，默认 `images.lock.resolved.txt`（**仅 `lock` 需要**，即 `--write-lock` 的产物） |
| `dest_registry` | 目标仓库前缀，**仅 `audit` 需要**；留空则用 `ALIYUNCS_REGISTRY` 变量或内置默认值 |
| `updates_limit` | `updates` 模式下每个仓库最多列出几条未收录的 tag，默认 5 |
| `filter` / `exclude` | 只看清单里的一部分镜像（`lock` 模式不适用——校验以锁文件为准，没有筛的概念） |
| `notify_on` | `failure`（默认，仅在有落后 / 缺失 / 无法判定时推送）或 `always` |

结果渲染在运行页面的 **Summary** 里（与同步报告同样的表格）。配了 `NOTIFY_WEBHOOK` 的话，结果也会推送到群里——这样定期体检就不需要有人天天去页面看。

**关于红绿灯**：体检发现差异时，这次运行**是红的**——绿 = 一切正常，红 = 需要看看。这不是「检查失败」，而是「检查有结论」；究竟是有差异还是没查成，Summary 里分得很清楚。

**体检不会自动跑**。工作流只有手动触发。需要定时的使用者可以 fork 后自行加一行 `schedule`——「什么时候去访问一批上游仓库」应该是你自己的决定，不是项目替你做的。

> `mode=updates` 与 `mode=lock` 时不需要 `dest_registry`；工作流不会把它传给脚本（传了也只会得到一句「不生效」的告警）。`mode=lock` 同样不传 `filter` / `exclude`——锁文件校验没有筛选的概念。

### 场景十六：校验锁文件的时效性（上游还是我锁的那份吗）

`--write-lock` 把同步时的 digest 锁下来，承诺「无论上游怎么重新构建，都能拉回完全相同的那一份」。但这个承诺有个前提：**锁文件只记录历史，它不会告诉你上游已经变了**。

上游完全可能重新构建并覆盖同名 tag（构建不可复现、维护者手滑、供应链事故）。此时锁文件没有任何变化——它记录的历史事实依然「正确」——但下一次增量同步会发现源变了，**把新内容静默搬进你的仓库**。等你从集群行为异常中发现，往往已经隔了很久。

`--audit-lock` 补上缺的环节：定期问一句「上游的 tag 还是我锁的那份吗」：

```bash
./scripts/sync.sh --audit-lock sync-2026-09.lock
```

```text
 ✓ 一致  registry.k8s.io/pause:3.9@sha256:013b4552…
 ⚠ 漂移  docker.io/library/nginx:1.27@sha256:dddd0000…
   上游已变更：锁定 sha256:dddd0000…，当前 sha256:ffff0000…
 ⚠ 漂移  registry.k8s.io/gone:v1.0@sha256:bbbb0000…
   上游已删除该 tag（锁定 sha256:bbbb0000…）
 ? 无法判定  quay.io/coreos/flannel:v0.25.5@sha256:cccc0000…
   上游无法访问：unauthorized: authentication required

锁文件校验完成：一致 1 ｜ 漂移 2 ｜ 无法判定 1
```

比对口径与 `--write-lock` 完全同源（顶层 manifest digest），「一致」意味着的正是「当时锁的就是这份」。

**「上游 tag 已删除」算漂移，不算无法判定**：tag 消失是明确发生的变更（registry 明确回答了「不存在」），与「网络原因查不到」性质不同——后者才进「无法判定」。

不需要目标地址；退出码与审计同一约定（`0` 全部一致 / `2` 有漂移或没查成）。配了 webhook 时，`--notify-on failure` 表示「有漂移或无法判定」时才打扰。

**发现漂移之后**：锁文件的价值正在于此——把镜像引用里的 tag 换成 `@digest`，拉到的就是当时那份精确的旧版本；是否接受上游的新内容，是你要做的决定。

几点说明：

- 锁文件里**不带 digest 的行**（手写的普通引用）会出现在报告里并标为「未锁定」，不参与判定——没有基准，校验从何谈起
- `# [失败]` / `# [已排除]` / `# [无 digest]` 标注行（上次同步未锁上的条目）同样出现在报告里并标明类别，不会被悄悄吞掉
- `--src` / `--file` 不能与 `--audit-lock` 同用：校验清单以锁文件为准，混进来只会让语义变含糊
- 锁文件校验已接进体检工作流（`Check-Registry` 的 `mode=lock`），不用装 CLI 在 Actions 页面就能跑；建议每次同步前跑一次
- 加 `--report-dir` 可把报告落盘（`.md` + `.json`），与其他检查报告同名约定

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

## 失败了怎么重跑

一个镜像失败往往只是暂时的——上游抖动、被限流、网络瞬断。这类失败重跑一次多半就好了，麻烦的是**把失败的那些挑出来**：清单里几十个镜像，总不能一个个对照着抄。

运行结束后，**Summary 页面会自动给出重跑指引**，直接复制粘贴即可。

**Aliyuncs / Harbor 工作流**给出的是镜像列表，粘进下一次运行的 `images_src` 输入：

```
nginx:1.27
redis:7.2
```

**Sync-Batch** 给出的是锚定正则，粘进 `filter` 输入：

```
^(docker://)?(nginx:1\.27|redis:7\.2)$
```

这条正则以 `^…$` 锚定整串、并转义了 `.` `+` 之类的元字符，所以**不会**把 `nginx:1.27-alpine` 这类同前缀的 tag 一起匹配进来。

> 「镜像引用格式错误」这类失败重跑多少次都是一样的结果，因此不会列进清单。指引会用一句「另有 N 个……未列入」交代清楚，不会让它们悄悄消失。

全绿时不会出现这一节；`dry_run` 预览时也不会——预览没有真正推送过，谈不上重跑。

同样的信息也落进报告（Artifact 里的 `.md` 与 `.json`）。`json` 的 `rerun` 字段供脚本消费：

```bash
jq -r '.rerun.images[]' sync-report.json     # 失败项清单
jq -r '.rerun.filter'   sync-report.json     # 锚定正则
jq    '.rerun.not_rerunnable' sync-report.json   # 重跑也无解的项数
```

每个镜像的失败原因在 `images[].note`——报告 `.md` 与 Actions 页面 Step Summary 的「说明」列是同一份内容：

```bash
jq -r '.images[] | select(.status=="failed") | "\(.source)：\(.note)"' sync-report.json
```

`note` 字段始终存在：成功项为空串，跳过项与排除项写的是各自的原因（如「目标已存在相同镜像」「匹配 --exclude「redis」」）。

---

## 查看历史趋势

单次报告只说明「这一次」。想知道某个镜像是否**反复**失败、哪个镜像最不稳定，用 `scripts/history.sh` 把历次报告摊在一起看：

```bash
# 汇总最近 20 次运行
./scripts/history.sh

# 某个镜像的历史
./scripts/history.sh --image registry.k8s.io/pause:3.9

# 失败最多的 5 个镜像
./scripts/history.sh --top-failures 5

# 平均最慢的 5 个镜像——同步速度被谁拖慢了
./scripts/history.sh --slowest 5
```

输出是 Markdown，可以直接粘进 Issue：

```text
共 **20** 次运行，覆盖 `2026-08-22T…` ~ `2026-09-11T…`
累计同步 **96** 个镜像次：成功 88 ｜ 跳过 5 ｜ 失败 3

| 镜像 | 成功 | 跳过 | 失败 | 最近一次 |
| --- | :---: | :---: | :---: | :---: |
| `ghcr.io/foo/bar:1.2` | 14 | 3 | 3 | ❌ |
```

数据来自每次运行上传的报告 Artifact——**不需要任何额外配置，也不会往仓库里写任何东西**。因此历史窗口就等于 Artifact 的保留期（默认 30 天，见工作流里的 `retention-days`）。

这个取舍是刻意的：为了看趋势而往仓库里持续提交历史文件，代价是永远增长且无法清理的提交记录。而趋势本身并不需要永久保存。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--dir <目录>` | 用本地已有的报告目录，不访问 GitHub（离线可用） |
| `--limit <N>` | 下载最近 N 次运行，默认 20 |
| `--image <镜像>` | 只看某个镜像 |
| `--top-failures <N>` | 只看失败最多的 N 个，默认 10 |
| `--slowest <N>` | 只看平均耗时最慢的 N 个，同时给出波动范围 |

单次运行里也有一份耗时排行：报告与 Step Summary 末尾的「最慢的同步记录」，按耗时降序列出前 5 条。有效记录不足 3 条、或全部耗时为 0（dry-run）时会自动省略——空有形式而没有信息量的榜单只是噪音。

> 💡 波动范围往往比平均值更有参考价值：单次超时会把平均值拉得很高，看范围就能分辨「一直慢」还是「偶尔慢」。「偶尔慢」通常是上游抖动，不值得优化；「一直慢」才是真正的瓶颈。

> 💡 需要 `gh` CLI 与 `jq`。
>
> ⚠️ 历史中**存在**失败记录时，脚本以退出码 `2` 结束——便于把它接进别的检查，比如「过去 20 次里出现过失败就告警」。注意这说的是历史，不是本次运行的结果。

### 检查报告的趋势（`--check`）

同步趋势之外，`--check` 把**检查报告**（v1.8.0 起 `--audit` / `--audit-lock` 支持 `--report-dir` 落盘；体检工作流上传为 `check-report` Artifact）也摊在一起：

```bash
# 哪个镜像一直落后 / 一直缺失（审计趋势）
./scripts/history.sh --check audit

# 哪个锁条目一直在漂移（锁文件时效趋势）
./scripts/history.sh --check lock-audit

# 用本地报告目录（混放同步报告也没关系，按报告内的 check 字段识别）
./scripts/history.sh --check audit --dir ./reports
```

输出与同步趋势同款：

```text
共 **3** 次审计，覆盖 `2026-09-01T…` ~ `2026-09-10T…`
累计 **21** 条记录：最新 4 ｜ 落后 4 ｜ 缺失 6 ｜ 无法判定 1 ｜ 被排除 6

| 源镜像 | 目标 | 最新 | 落后 | 缺失 | 无法判定 | 最近一次 |
| --- | --- | :---: | :---: | :---: | :---: | :---: |
| `quay.io/flux/source-controller` | `r.example.com/flux:1.0` | 0 | 0 | 3 | 0 | ✗ |
| `docker.io/library/nginx:1.27` | `r.example.com/nginx:1.27` | 1 | 2 | 0 | 0 | ⚠️ |
```

两个口径上的要点：

- **分组键是「源镜像 + 目标」**：审计的状态绑定目标仓库——同一个源在 A 目标最新、在 B 目标落后，合并计数就丢了信息
- **「无法判定」不触发退出码 2**：趋势窗口里的无法判定多为网络抖动或匿名访问，查不成不等于落后 / 漂移；它们在表格中独立可见，退出码 `2` 只由确定异常（落后 / 缺失 / 漂移）的历史触发

`check-updates` 不支持趋势：未收录 tag 的增减没有趋势价值（收不收本来就要人判断），显式传入会得到参数错误。被 `--filter` / `--exclude` 排除的组合与锁文件里未锁定 digest 的条目不进趋势表，但会在表后的统计行中说明数量。

### 在 Actions 页面看趋势（不用装 CLI）

`History-Trend` 工作流把趋势搬到了网页上：**Actions** → 左侧选 `History-Trend` → **Run workflow**，选 `mode`（`audit` / `lock-audit` / `sync`）即可。结果渲染在运行页面的 Summary，同时落盘为 Artifact（`trend-report`，含 `.md` 与机器可读的 `.json`），供归档或给别的系统消费。

与体检工作流同一套红绿灯：**绿 = 窗口内没有需要处理的记录，红 = 有**（audit 是落后 / 缺失，lock-audit 是漂移，sync 是失败）——红不是「查询失败」，是「查询有结论」。

> `history.sh --report-dir <目录>` 在本地也能产出同款 `.md` + `.json`，与工作流是同一份格式约定。

**趋势查询不会自动跑**。工作流只有手动触发。

---

## 在本地使用

不依赖 GitHub Actions，本地也能跑同一套逻辑（需要 `skopeo`，剔除 attestation 时还需要 `regctl`）：

```bash
# macOS
brew install skopeo regclient

# 预览同步计划和实际命令，不实际推送
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

# 私有源。凭证走环境变量比走命令行更稳妥——命令行参数对同机其他进程可见
SYNC_SRC_USERNAME=alice SYNC_SRC_PASSWORD='…' \
  ./scripts/sync.sh \
    --src harbor.internal.example.com/library/nginx:1.27 \
    --dest registry.cn-shenzhen.aliyuncs.com/nicholyx
```

### 同步到自建的 HTTP registry

自建 registry（例如本地起的 `registry:2` 容器）通常走 HTTP 而非 HTTPS，需要显式关闭 TLS 校验：

```bash
# 本地起一个 registry 试试
docker run -d -p 5000:5000 --name registry registry:2

./scripts/sync.sh \
  --src docker.io/library/nginx:1.27 \
  --dest localhost:5000/mirror \
  --tls-verify false
```

> ⚠️ **只在可信网络中对自建仓库使用 `--tls-verify false`。** 对公网仓库关闭证书校验会让中间人攻击成为可能。

另外注意：目标仓库名由源镜像推导，其中**端口号里的冒号也会被替换掉**（仓库名不允许含冒号），所以上面的例子会同步到 `localhost:5000/mirror/docker.io_library_nginx:1.27`。

完整参数见 `./scripts/sync.sh --help`。

---

## 取消同步 / 删除镜像

本项目**只负责推送，不提供删除功能**——删除是破坏性操作，不适合做成一个点错就执行的按钮。

需要删除时，请到对应仓库的控制台操作：

- **阿里云 ACR**：容器镜像服务 → 镜像仓库 → 选择仓库 → 版本 → 删除
- **Harbor**：项目 → 仓库 → 制品 → 删除

> 💡 如果只是想停止同步某个镜像，从 `images.lock.txt` 中删掉或注释掉对应行即可，已同步的镜像不受影响。
