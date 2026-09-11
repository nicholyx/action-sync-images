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

凭证会被发往哪个仓库？不指定时脚本从源镜像自动推导，并把结果列在日志里：

```text
[信息] 源仓库凭证已装载（1 个）：harbor.internal.example.com
```

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
| `dry_run` | | `false` | 只打印将要执行的命令，不实际推送。用于确认目标地址是否正确 |

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
- 源镜像会被拉取多次（每个目标一次）——这是当前实现的取舍，换取的是逻辑简单与失败可定位

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

### 场景六：用 `dry_run` 先确认目标地址

不确定镜像名会被转成什么样？先勾上 `dry_run` 跑一次，日志里会打印出完整命令：

```text
[dry-run] skopeo copy --all --retry-times 3 \
  docker://registry.k8s.io/coredns/coredns:v1.11.1 \
  docker://registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
```

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
