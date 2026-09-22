# 排错手册

同步失败的绝大多数原因都在这份文档里。**遇到问题请先查这里**，比开 Issue 快得多。

如果这里没有覆盖你的情况，请[提 Issue](https://github.com/nicholyx/action-sync-images/issues/new/choose) —— 补进这份文档本身就是一种贡献。

---

## 快速定位

在 Actions 运行页面的日志里搜索关键词：

| 日志中的关键词 | 跳到 |
| --- | --- |
| `unknown manifest class` | [attestation 问题](#错误unknown-manifest-class) |
| `no matching manifest` | [多架构丢失](#错误no-matching-manifest-for-linuxarm64) |
| `unauthorized` / `authentication required` | [认证失败](#错误unauthorized-authentication-required) |
| `denied` / `forbidden` | [权限不足](#错误denied-requested-access-to-the-resource-is-denied) |
| `manifest unknown` / `not found` | [镜像不存在](#错误manifest-unknown) |
| `platform ... not found` | [平台不匹配](#错误platform--not-found) |
| `toomanyrequests` / `pull rate limit` | [Docker Hub 限流](#错误toomanyrequests-you-have-reached-your-pull-rate-limit) |
| `context deadline exceeded` / `timeout` | [网络问题](#错误context-deadline-exceeded--timeout) |
| `skopeo: command not found` | [缺少依赖](#错误skopeo-command-not-found) |

---

## 错误：`unknown manifest class`

### 完整报错长这样

```text
time="..." level=fatal msg="copying image: ... unknown manifest class for ..."
```

或者：

```text
Error: creating an index: ... unknown manifest class
```

### 原因

源镜像带有 attestation manifest（provenance 或 SBOM），而阿里云 ACR 尚不支持 OCI 1.1 规范中的「空 blob」形式，因此在推送整个索引时拒绝接收。

### 解决

**在触发工作流时勾选 `strip_attestation`，重新运行。**

工作流会改用 `regctl` 重建一个不含 attestation 的索引。

### 典型触发者

- `ghcr.io/netbirdio/*`（该项目的构建流程默认开启 provenance）
- 任何使用 `docker buildx build --provenance=true` 构建并推送的镜像
- 使用 BuildKit 且开启了 SBOM 生成的镜像

### 如果勾选后仍然失败

继续往下看[错误：platform not found](#错误platform--not-found)。

---

## 错误：`no matching manifest for linux/arm64`

### 原因

目标仓库里只有 amd64 的镜像，没有 arm64。这通常意味着同步时没有保留多架构索引。

### 解决

**本项目正常情况下不会出现这个问题**（默认使用 `skopeo copy --all`），如果你遇到了，请检查：

1. 是不是在**旧版本**的代码上同步的？项目早期版本确实缺少 `--all`，升级到最新版即可。
2. 是不是手动改了工作流，去掉了 `--all`？
3. 是不是走的 `strip_attestation` 路径，而 `platforms` 里漏填了平台？

如果是第三种，把 `platforms` 填成 `linux/amd64,linux/arm64`（或干脆留空让脚本自动探测）。

### 验证是否已修复

```bash
docker buildx imagetools inspect <目标镜像地址>
```

输出中应当同时包含 `linux/amd64` 与 `linux/arm64`。

---

## 错误：`unauthorized: authentication required`

### 先分清是哪一端报的

这个报错有**两个完全不同的来源**，处理方式也完全不同。先看日志里有没有 `目标：…` 那一行：

| 报错位置 | 来源 | 跳转到 |
| --- | --- | --- |
| 已出现 `目标：…`，在推送时报错 | 目标仓库 | [目标仓库](#目标仓库) |
| 刚打印 `[1/N] 镜像名` 就报错，没有 `目标：` | **源仓库** | [源仓库](#源仓库私有镜像) |

分不清的话，往下按目标仓库查一遍通常也能看出端倪——目标仓库的凭证问题更常见。

### 目标仓库

可能是凭证错误、凭证过期，或者 Secret 名字写错了。

**排查步骤**

1. **确认 Secret 存在且名字正确**

   到 `Settings` → `Secrets and variables` → `Actions`，检查：

   - 阿里云场景需要 `DOCKER_USERNAME` 和 `DOCKER_PASSWORD`
   - Harbor 场景需要 `HARBOR_REGISTRY`、`HARBOR_USERNAME`、`HARBOR_PASSWORD`

   > ⚠️ Secret 名字**大小写敏感**，`docker_username` 和 `DOCKER_USERNAME` 是两个不同的东西。

2. **确认密码类型正确（阿里云最常见的坑）**

   阿里云容器镜像服务需要的是**镜像仓库的固定密码**，不是阿里云账号的登录密码。

   获取路径：阿里云控制台 → 容器镜像服务 → 访问凭证 → 设置固定密码。

3. **确认仓库地址与登录地址匹配**

   如果改过 `ALIYUNCS_REGISTRY` 变量，确认它的第一段（registry host）是你真正要推的仓库。脚本会用它的第一段去登录。

4. **在本地验证凭证是否有效**

   ```bash
   docker login registry.cn-shenzhen.aliyuncs.com -u <用户名>
   # 粘贴密码后执行
   docker pull registry.cn-shenzhen.aliyuncs.com/nicholyx/nginx:latest
   ```

   本地能成功说明凭证没问题，问题在 GitHub 侧的配置。

### 源仓库（私有镜像）

如果源镜像来自公司内部 Harbor、私有 GHCR 包这类需要认证的仓库，匿名拉取就是这个报错。

**解决**：配置一对源仓库凭证。注意它们与目标仓库的凭证是**分开的两套**：

| Secret | 值 |
| --- | --- |
| `SRC_REGISTRY_USERNAME` | 源仓库用户名 |
| `SRC_REGISTRY_PASSWORD` | 源仓库密码或 Token |

本地则用环境变量（比命令行参数稳妥，见下）：

```bash
SYNC_SRC_USERNAME=alice SYNC_SRC_PASSWORD='…' \
  ./scripts/sync.sh --src harbor.internal.example.com/library/nginx:1.27 --dest <目标>
```

配置生效后，日志里会出现一行确认：

```text
[信息] 源仓库凭证已装载（1 个）：harbor.internal.example.com
```

如果这一行没出现，说明凭证根本没传进来——检查 Secret 名字，或者本地环境变量是否真的导出了。

> ⚠️ **不要把目标仓库的凭证拿去当源仓库的凭证。** 目标是你的仓库，源是别人的系统；把「往我仓库推送」的权限交给第三方，是拿自己的仓库冒险。所以脚本刻意没有提供「复用」的捷径。

> 💡 凭证**不会进日志**。脚本把它写进 600 权限的临时文件，用 `--src-authfile` 交给 skopeo；CI 里则走环境变量而非命令行参数——命令行参数对同机进程可见（`ps aux`），也容易被日志语句原样打印出去。

> ⚠️ **用了 `--strip-attestation` 时另有一种传递方式。** 那条路径的底层是 `regctl`，它不认 `--src-authfile`，凭证改经临时的 `DOCKER_CONFIG` 目录传递——内容是你的 `~/.docker/config.json` 与本次源凭证的**合并**（目录 0700、文件 0600，退出时清理，你的原文件不会被改动）。
>
> **这一点在 2026-09-23 之前是坏的**（[#120](https://github.com/nicholyx/action-sync-images/issues/120)）：凭证根本没有传给 regctl，私有源 + `--strip-attestation` 必然以 `no credentials available: unauthorized` 失败，**而上面那行「已装载」照样会打印**——也就是说，看到它并不证明凭证送到了该去的地方。仍在撞这个报错的话，先确认脚本版本。

> ⚠️ **自签 HTTPS 证书的仓库在 `--strip-attestation` 下不适用 `--tls-verify false`。** regctl 的 TLS 是按仓库的单值（`disabled` = 明文 HTTP，`insecure` = 自签证书），一个值照顾不了两种场景，脚本选了前者。这种情况请改在 `~/.regctl/config.json` 里为该仓库配 `cacert`。详见 `USAGE.md` 的「与 `--strip-attestation` 的一处差异」。

---

## 错误：`denied: requested access to the resource is denied`

### 原因

认证通过了，但**没有权限往目标仓库推送**。

### 排查步骤

1. **确认目标仓库是你的**

   工作流默认推到 `registry.cn-shenzhen.aliyuncs.com/nicholyx`——**项目作者的命名空间**。没设 `ALIYUNCS_REGISTRY` 就会往那里推：除非你的阿里云账号下恰好有同名的 `nicholyx` 命名空间（命名空间是**账号内唯一**，不是全局唯一），否则会被拒。设置方式见[使用文档](USAGE.md#目标仓库aliyuncs_registry)。

   如果你**确实**想用某个命名空间，确认它在你的账号下已创建（阿里云：控制台创建命名空间；Harbor：创建项目）。

2. **确认账号有推送权限**

   Harbor 的机器人账号容易被配成只读，检查它的权限是否包含 `push`。

3. **确认目标路径结构符合仓库限制**

   阿里云**个人版不支持多级仓库路径**。如果你用 `--dest-exact` 指定了 `.../a/b/c:tag` 这样的多级路径，可能被拒绝。个人版请使用默认的前缀模式（自动压平为 `a_b_c`）。

   企业版支持多级路径，可正常使用 `--dest-exact`。

---

## 错误：`manifest unknown`

### 原因

源镜像不存在。可能是 tag 写错了、镜像已被上游删除，或者仓库地址拼错。

### 排查步骤

1. **确认 tag 拼写**

   特别注意版本号里常见的混淆：`v1.27.4` 和 `1.27.4` 是不同的 tag。

2. **确认镜像确实存在**

   ```bash
   skopeo inspect docker://registry.k8s.io/coredns/coredns:v1.11.1
   ```

   或者用浏览器打开对应的仓库页面查 tag 列表。

3. **确认私有镜像已认证**

   如果要同步的是私有仓库镜像，需要额外配置源仓库的凭证。两种方式都支持：
   单值凭证（`--src-username` / `--src-password`，或环境变量），以及清单混有
   多个私有源时的**按仓库映射**（`--src-credentials`）。完整说明见
   [USAGE.md 的「同步私有仓库的镜像」](USAGE.md#可选同步私有仓库的镜像)。

---

## 错误：`platform ... not found`

### 完整报错长这样

```text
Error: creating an index: platform linux/arm64 not found in ...
```

### 原因

用的是 `strip_attestation` 路径，但源镜像里**不存在**你指定的某个平台。最常见的是源镜像只有 `linux/amd64`，而 `platforms` 填了 `linux/amd64,linux/arm64`。

### 解决

**把 `platforms` 改为源镜像实际具有的平台。**

先确认源镜像有哪些平台：

```bash
skopeo inspect --raw docker://<源镜像> | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"'
```

输出示例：

```text
linux/amd64
linux/arm64
unknown/unknown      ← 这就是 attestation，不要写进 platforms
```

然后把 `platforms` 填成实际存在的那些，例如只填 `linux/amd64`。

> 💡 如果输出为空或者报错，说明源本身是单平台镜像，直接填 `linux/amd64`（或它实际的那个架构）。
>
> 💡 **不要**把 `unknown/unknown` 填进 `platforms`——那正是我们要剔除的东西。

---

## 错误：`toomanyrequests: You have reached your pull rate limit`

### 完整报错长这样

```text
toomanyrequests: You have reached your pull rate limit.
You may increase the limit by authenticating and upgrading:
https://www.docker.com/increase-rate-limit
```

### 原因

Docker Hub 对**匿名拉取**有速率限制（按 IP 计），而 GitHub Actions 的 runner 用的是共享 IP，很容易撞上。

关键是要意识到：**这跟你的仓库没有关系**，是上游 Docker Hub 在限你。所以查目标仓库的配置、改 Secret，都不会有任何效果。

### 解决

**方案一：配置 Docker Hub 凭证。** 登录后的额度按账号算，比匿名高一个数量级。

用源仓库凭证即可（`SRC_REGISTRY_USERNAME` / `SRC_REGISTRY_PASSWORD`）：

```text
SRC_REGISTRY_USERNAME = 你的 Docker Hub 用户名
SRC_REGISTRY_PASSWORD = Access Token，**不是**登录密码
```

> 💡 Token 在 Docker Hub → Account Settings → Security → New Access Token 创建。用 Token 而不是密码，因为它可以随时吊销、权限可控，泄露了也不会连带账号本身。

**方案二：换一个上游。** 很多镜像有官方镜像站或国内同步源，从那里拉根本不经过 Docker Hub。通常比配凭证更省事，也更稳定。

**不要靠加大 `--retries` 解决。** 限流是窗口式的，短时间内重试只会继续撞在同一个窗口边界上。真要重试，配合 `--retry-delay` 拉长间隔才有效果——见[使用指南](USAGE.md#场景十调整重试行为)。

### 怎么确认是这个问题

报错里只要出现 `toomanyrequests` 或 `pull rate limit`，就是它，不必再往下查。

---

## 错误：`context deadline exceeded` / `timeout`

### 原因

网络问题。可能是上游仓库暂时不可达，或者镜像层太大导致传输超时。

### 解决

1. **直接重跑一次**

   上游仓库偶发抽风是最常见的情况，重跑通常就好了。

2. **检查上游仓库状态**

   `registry.k8s.io`、`gcr.io` 等偶尔会有区域性故障。

3. **拆分成多次同步**

   如果要同步的镜像很多且体积都很大，一次跑可能超时。分批触发即可——工作流本身支持一次填多个镜像，但网络不好时分开跑更稳。

---

## 错误：`skopeo: command not found`

### 原因

运行器环境缺少 `skopeo`。

### 说明

GitHub 官方的 `ubuntu-latest` 运行器**预装了 skopeo**，正常情况下不会出现这个问题。

如果出现了，可能是：

- 你用的是自建的 self-hosted runner，且没装 skopeo
- GitHub 更新了运行器镜像，移除了 skopeo（这种变动会在 Actions 的运行日志里体现）

### 解决

在对应工作流的步骤前加一个安装步骤：

```yaml
      - name: 安装 skopeo
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq skopeo
```

如果确认是 GitHub 更改了运行器镜像导致的，欢迎提 Issue 让我们同步修复。

---

## 错误：`regctl 下载失败（已重试一次）`

### 现象

```text
[警告] regctl 下载失败，重试一次（多为网络抖动）...
[错误] regctl 下载失败（已重试一次）：https://github.com/regclient/regclient/releases/download/v0.11.6/regctl-linux-amd64。多为网络原因，稍后重跑即可
```

### 原因

用 `--strip-attestation` 时需要 `regctl`，脚本会从 GitHub release 下载到 `$HOME/.regclient/bin`。

**这条下载已经重试过一轮**（间隔 5 秒）。两次都失败，说明多半不是一次瞬时抖动：跑在封锁 GitHub releases 的网络里、代理需要额外配置、或者 GitHub 自身故障。

### 解决

1. **先原样重跑一次**。抖动窗口有时比 5 秒长，CI 上尤其如此
2. **手动放一份**。脚本只在 `command -v regctl` **不命中**时才下载，所以把二进制放进 `PATH` 里的任意位置就能完全跳过这条路径：

   ```bash
   # 版本要与脚本固定的那个一致，见 scripts/sync.sh 的 REGCTL_VERSION
   version="v0.11.6"
   os="$(uname -s | tr '[:upper:]' '[:lower:]')"
   arch="$(uname -m)"
   case "$arch" in                       # 注意：uname 给的是 x86_64/aarch64，
     x86_64|amd64)  arch="amd64" ;;      # 而 release 上的文件名用的是 amd64/arm64
     aarch64|arm64) arch="arm64" ;;
   esac

   mkdir -p "$HOME/.regclient/bin"
   curl -fsSL "https://github.com/regclient/regclient/releases/download/${version}/regctl-${os}-${arch}" \
     -o "$HOME/.regclient/bin/regctl"
   chmod 755 "$HOME/.regclient/bin/regctl"
   export PATH="$HOME/.regclient/bin:$PATH"   # 关键的一行，理由见下
   ```

   `$HOME/.regclient/bin` 默认**不在**使用者的 `PATH` 里——脚本下载完只是在自己进程内临时前置它。所以**光把文件放进那个目录不算数**：新起的 shell 里 `command -v regctl` 仍然不命中，脚本会再走一次下载路径（实测确认：只放文件、不加 `PATH` 时，`curl` 仍被调用了两次并以「已重试一次」失败）。CI 里对应的是把目录写进 `$GITHUB_PATH`——下载与 `chmod` 同上（注意把 `uname -m` 映射成 `amd64`/`arm64`），这一行才是关键：

   ```yaml
   - name: 准备 regctl
     run: |
       # …下载到 "$HOME/.regclient/bin/regctl" 并 chmod 755，同上…
       echo "$HOME/.regclient/bin" >> "$GITHUB_PATH"
   ```
3. **确认能连到 GitHub**：拿报错里那个 URL 在浏览器或 `curl -I` 里试一次，能区分「网络策略」与「脚本问题」

> ⚠️ **别把它当成「网络不好」一笔带过。** 这条报错此前是**一次失败就放弃**的（[#122](https://github.com/nicholyx/action-sync-images/issues/122)），看到它意味着两轮都没成——值得花一分钟看一眼 URL 是否可达。

---

## 错误：`Permission denied` / `Resource not accessible by integration`

### 原因

工作流的 `GITHUB_TOKEN` 权限不足。这通常发生在自动化工作流（labeler、stale、welcome）上，而不是同步工作流。

### 排查步骤

1. **确认工作流里声明了 `permissions`**

   每个需要写操作的工作流都应有显式声明，例如：

   ```yaml
   permissions:
     contents: read
     pull-requests: write
   ```

2. **确认仓库的默认 Token 权限设置**

   到 `Settings` → `Actions` → `General` → `Workflow permissions`，确认没有把权限限制得过死。

3. **注意 fork 场景的限制**

   来自 fork 的 PR，在 `pull_request` 事件下拿到的 `GITHUB_TOKEN` 是**只读**的。这就是本项目的 `labeler.yml` 和 `welcome.yml` 使用 `pull_request_target` 的原因（它们不 checkout PR 代码，因此是安全的）。

---

## 自建 registry：密码填对了却始终 `unauthorized`

### 现象

自建 registry 启用了 htpasswd 认证。用同样的用户名密码 `docker login` 能成功，
但脚本同步时始终 401，日志里看不出任何线索——就是一个普通的认证失败。

### 原因

**密码文件的哈希算法不对。**

Docker Registry 的 htpasswd 实现**只认 bcrypt**（哈希以 `$2y$` 或 `$2a$` 开头）。
而 Apache 的 `htpasswd` 不加参数时默认生成 MD5（`$apr1$`），`openssl passwd` 更是只能生成 `$apr1$`。

用这些方式生成的密码文件，registry 加载时不报错、启动也完全正常，
但**任何一次登录都会失败**——而且失败得毫无线索。

### 解决

生成时显式指定 bcrypt：

```bash
htpasswd -Bbn <用户名> '<密码>' > /path/to/htpasswd
```

关键是 `-B` 这个参数。生成完检查一下：

```bash
head -1 /path/to/htpasswd
```

- 看到 `$2y$…` 或 `$2a$…` → 正确
- 看到 `$apr1$…` → 用错了工具或漏了 `-B`，registry 不会认

机器上没有 `htpasswd` 的话：

```bash
apt-get install -y apache2-utils   # Debian / Ubuntu
brew install httpd                 # macOS（htpasswd 随 httpd 一起提供）
```

### 为什么要专门记这一条

因为它**不报错**。registry 启动正常、`docker login` 本地可能也是用别的凭据成功的，
只有同步路径上才表现为 401。很容易被误判成「Secret 配错了」，然后在一个根本
不是问题的地方反复排查。

> 💡 这个坑是在给本项目写集成测试时踩到的：CI 里本来打算用 `openssl passwd -apr1`
> 生成密码文件（省得装 apache2-utils），结果 registry 每一次认证都失败。

---

## 同步「成功」但镜像不对

### 现象

工作流绿灯，但拉下来的镜像不是预期的那个，或者拉不到。

### 排查清单

1. **确认目标地址**

   在 Summary 表格或日志里查看实际的目标地址。默认模式下，源镜像路径中的 `/` 会被替换成 `_`：

   ```text
   registry.k8s.io/coredns/coredns:v1.11.1
     ↓
   <你的仓库>/registry.k8s.io_coredns_coredns:v1.11.1
   ```

   这个规则不是每个人都能一眼猜到，**用 `dry_run` 先跑一次**是最稳妥的做法。

2. **确认拉取时的 tag**

   镜像名不同，tag 是一样的（`v1.11.1`）。

3. **确认本地 docker 已登录**

   阿里云的私有仓库需要先 `docker login` 才能拉取。

---

## 通用调试手段

### 用 dry_run 先看命令

不确定会发生什么时，勾选 `dry_run` 触发一次。它会把将要执行的完整命令打印出来但不执行——零风险，且能回答「目标地址到底会是什么」这个高频疑问。

### 本地复现

自动化环境出问题时，在本地跑同样的命令是最快的定位方式：

```bash
git clone https://github.com/nicholyx/action-sync-images.git
cd action-sync-images

# 用与 CI 完全相同的逻辑跑一遍
./scripts/sync.sh \
  --src <出问题的镜像> \
  --dest <你的目标仓库> \
  --dry-run
```

如果本地能跑通而 CI 不行，那问题多半在凭证或环境上，而不是同步逻辑本身。

### 看完整的运行日志

Actions 的运行页面里，点开失败的步骤，展开被折叠的 `::group::` 块，可以看到每个镜像的详细处理过程。

### 先跑一遍静态检查

改动过工作流之后，先在本地跑：

```bash
./scripts/lint.sh
```

`actionlint` 能发现很多「看起来没问题但运行时会炸」的写法（比如用错上下文、输入参数名写错）。

---

## 还是没解决？

请在 [提 Issue](https://github.com/nicholyx/action-sync-images/issues/new/choose) 时附上：

1. 出问题的源镜像完整地址
2. 触发时填写的参数
3. **完整的报错文本**（不是截图）
4. 失败运行的链接

有这四样，绝大多数问题都能很快定位。
