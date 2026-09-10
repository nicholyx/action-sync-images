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
| `platform ... not found` | [平台不匹配](#错误platform-not-found) |
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

继续往下看[错误：platform not found](#错误platform-not-found)。

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

### 原因

登录目标仓库失败。可能是凭证错误、凭证过期，或者 Secret 名字写错了。

### 排查步骤

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

---

## 错误：`denied: requested access to the resource is denied`

### 原因

认证通过了，但**没有权限往目标仓库推送**。

### 排查步骤

1. **确认目标命名空间/项目存在**

   - 阿里云：需要先在控制台创建命名空间（如 `nicholyx`）
   - Harbor：需要先创建项目（如 `library`）

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

   如果要同步的是私有仓库镜像，需要额外配置源仓库的凭证。本项目目前**不支持为源仓库配置独立凭证**——如果你有这个需求，欢迎提 Issue 讨论。

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
