# 项目起源与原始教程

本文归档了这个项目的起源，以及最初版本的使用教程。

内容主要来自项目初期的 README，**保留原始表述与作者署名**。其中的示例对应的是早期的实践方式（同步到 Docker Hub），与当前代码的实际行为已有差异——**当前用法请以 [README](../README.md) 和 [USAGE.md](USAGE.md) 为准**。

---

## 来源

最早的 `action-sync-images` 项目由 **WeiyiGeek** 创建：

- 项目地址：<https://github.com/WeiyiGeek/action-sync-images>
- 相关文章：[如何使用 Skopeo 做一个优雅的镜像搬运工](https://mp.weixin.qq.com/s/_r9WLMAIbOFEzj7-OWPWDw)
- 相关文章：[如何使用 Aliyun 容器镜像服务对海外 gcr、quay 仓库镜像进行镜像拉取构建?](https://mp.weixin.qq.com/s/oQ82YWYRnSIUp-RXLdNS8A)

本仓库最早是它的一个 fork，自 2024 年起由 nicholyx 独立维护，同步工作流的实现、CI 工具链与全部文档均已重写。原始的教程性内容保留在下方，供了解项目脉络之用。

---

## 前言

> 描述：使用 Github-Action 或者 Aliyun 镜像服务同步镜像到个人 DockerHub 或者私有镜像仓库中

---

## 一、使用 Github Action 优雅地同步国外镜像到个人 DockerHub

> 描述：由于国内上网环境的原因，在部署某些云原生应用时，通常会遇到镜像无法直接拉取，例如 `k8s.io`、`gcr.io`、`quay.io` 等国外仓库中的镜像。最开始的做法是使用他人同步到 Docker Hub 仓库中的此版本镜像，或者是采用国外的 VPS 虚拟主机使用 `docker pull` / `docker tag` / `docker push` 命令的方式复制到 Docker Hub 仓库。但对于作者来说这两种都不是最优解，因为有可能他人没有同步到你所需要的版本，或者说你根本就没有 VPS，此时应该怎么办呢。

虽然前面作者写了一篇【如何使用 Aliyun 容器镜像服务对海外 gcr、quay 仓库镜像进行镜像拉取构建?】的文章，但是作者仍然觉得不够优雅，并且不能批量地同步。此处作者在使用 Github-Action 构建项目时，突发奇想为何不用 Github Action + Skopeo 工具来同步镜像呢，说做就做，遂有了此篇文章。

### 操作流程

**Step 1.** 登录 GitHub，点击右上角 `+`，然后创建一个名为 `action-sync-images` 的仓库。

![weiyigeek.top-创建Github仓库图](https://img.weiyigeek.top/2023/5/20230727092416.png)

**Step 2.** 首先点击仓库里的 `Settings` 菜单，选择安全选项卡，点击 Action，然后将会进入到 `Actions secrets and variables`，此时为了账号密码，我们需要提前设置我们 Docker Hub 登录的账号密码到项目的 secrets 中（PS: fork 了此项目的朋友可以自行将对应 Docker Hub 设置为自己的账号密码）。

![weiyigeek.top-创建action使用的secrets图](https://img.weiyigeek.top/2023/5/20230727094133.png)

**Step 3.** 然后点击仓库里的 Action 菜单，再选择一个 simple workflow，将会为我们创建一个新的工作流文件，或者在项目根目录自行创建一个 `.github/workflows/sync-images-dockerHub-example.yaml` 目录文件。

![weiyigeek.top-快速创建 simple workflows 图](https://img.weiyigeek.top/2023/5/20230727092651.png)

**Step 4.** 此处我们拉取 kubernetes 最新的 V1.27.4 版本，使用 kubeadm 搭建集群，此时我们要在 Github Action 中使用 skopeo 工具将 `registry.k8s.io` 仓库中的镜像同步到 docker.io，执行下述 shell 命令，我们提前获取所需镜像并拼接拷贝命令，若需拷贝到自己的 hub 仓库请执行自行修改 `DOCKER_HUBUSERURL`，此处我 dockerhub 用户名是 `weiyigeek`。

```bash
K8SVERSION=1.27.4
DOCKER_HUBUSERURL=docker.io/weiyigeek
kubeadm config images list --kubernetes-version=${K8SVERSION} 2>/dev/null > K8sv1.27.4.txt
for i in `cat K8sv1.27.4.txt`;do
  echo skopeo copy --all docker://${i} docker://${DOCKER_HUBUSERURL}/${i##*/}
done

# 执行结果:
skopeo copy --all docker://registry.k8s.io/kube-apiserver:v1.27.4 docker://docker.io/weiyigeek/kube-apiserver:v1.27.4
skopeo copy --all docker://registry.k8s.io/kube-controller-manager:v1.27.4 docker://docker.io/weiyigeek/kube-controller-manager:v1.27.4
skopeo copy --all docker://registry.k8s.io/kube-scheduler:v1.27.4 docker://docker.io/weiyigeek/kube-scheduler:v1.27.4
skopeo copy --all docker://registry.k8s.io/kube-proxy:v1.27.4 docker://docker.io/weiyigeek/kube-proxy:v1.27.4
skopeo copy --all docker://registry.k8s.io/pause:3.9 docker://docker.io/weiyigeek/pause:3.9
skopeo copy --all docker://registry.k8s.io/etcd:3.5.7-0 docker://docker.io/weiyigeek/etcd:3.5.7-0
skopeo copy --all docker://registry.k8s.io/coredns/coredns:v1.10.1 docker://docker.io/weiyigeek/coredns:v1.10.1
```

**Step 5.** 将上述执行结果放置在 `Use Skopeo Tools Sync Image to Docker Hub` 子步骤下，然后将下述工作流的脚本复制粘贴到 `sync-images-dockerHub-example.yaml` 文件中，然后点击 `commit changes` 进行提交即可。

```yaml
# 工作流名称
name: Sync-Images-to-DockerHub-Example
# 工作流运行时显示名称
run-name: ${{ github.actor }} is Sync Images to DockerHub.
# 怎样触发工作流
on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

  # Allows you to run this workflow manually from the Actions tab
  workflow_dispatch:

# 工作流程任务（通常含有一个或多个步骤）
jobs:
  syncimages:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout Repos
      uses: actions/checkout@v3

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v2.9.1

    - name: Login to Docker Hub
      uses: docker/login-action@v2.2.0
      with:
        username: ${{ secrets.DOCKER_USERNAME }}
        password: ${{ secrets.DOCKER_PASSWORD }}
        logout: false

    # 使用shell命令批量同步所需的镜像到dockerHub中
    - name: Use Skopeo Tools Sync Image to Docker Hub
      run: |
        #!/usr/bin/env bash
        skopeo copy --all docker://registry.k8s.io/kube-apiserver:v1.27.4 docker://docker.io/weiyigeek/kube-apiserver:v1.27.4
        skopeo copy --all docker://registry.k8s.io/kube-controller-manager:v1.27.4 docker://docker.io/weiyigeek/kube-controller-manager:v1.27.4
        skopeo copy --all docker://registry.k8s.io/kube-scheduler:v1.27.4 docker://docker.io/weiyigeek/kube-scheduler:v1.27.4
        skopeo copy --all docker://registry.k8s.io/kube-proxy:v1.27.4 docker://docker.io/weiyigeek/kube-proxy:v1.27.4
        skopeo copy --all docker://registry.k8s.io/pause:3.9 docker://docker.io/weiyigeek/pause:3.9
        skopeo copy --all docker://registry.k8s.io/etcd:3.5.7-0 docker://docker.io/weiyigeek/etcd:3.5.7-0
        skopeo copy --all docker://registry.k8s.io/coredns/coredns:v1.10.1 docker://docker.io/weiyigeek/coredns:v1.10.1
```

![weiyigeek.top-sync-images-dockerHub-example图](https://img.weiyigeek.top/2023/5/20230727103541.png)

**Step 6.** commit 提交后将会触发工作流执行，此时我们回到仓库的 action 页面，点击如下图所示的，查看此工作流执行情况，是否有同步失败的情况。

![weiyigeek.top-查看工作流执行情况图](https://img.weiyigeek.top/2023/5/20230727103839.png)

**Step 7.** 最后登录我的 Docker Hub (<https://hub.docker.com/r/weiyigeek/>) 验证是否已经同步过来，可以从下图看到已经同步过来了。此后我们便可以使用 `docker pull` 命令或者是 `ctr image pull` 命令拉取镜像即可。

![weiyigeek.top-验证镜像同步图](https://img.weiyigeek.top/2023/5/20230727105454.png)

> 温馨提示：默认 `Docker Hub` 我们创建的账号都是免费计划，虽然没有空间的大小限制，但是有下载次数以及下载速度的限制，所以有条件的尽量自行使用内部私有镜像仓库。

至此，使用 Github Action + Skopeo 工具优雅地同步镜像到 dockerHub 中完毕。

---

## 二、使用 Aliyun 容器镜像服务拉取同步

如何使用 Aliyun 容器镜像服务对海外 gcr、quay 仓库镜像进行镜像拉取构建？

参考文章：<https://mp.weixin.qq.com/s/oQ82YWYRnSIUp-RXLdNS8A>

```bash
k8s.gcr.io/sig-storage/nfs-subdir-external-provisioner  > registry.cn-hangzhou.aliyuncs.com/weiyigeek/nfs-subdir-external-provisioner:v4.0.2

gcr.io/kaniko-project/executor:latest ->  registry.cn-hangzhou.aliyuncs.com/weiyigeek/kaniko-executor:latest
```

早期仓库中还包含两个配合该流程使用的 Dockerfile：

- `gcr.io/kaniko-project/executor/Dockerfile`
- `k8s.gcr.io/sig-storage/nfs-subdir-external-provisioner/Dockerfile`

它们用于在阿里云的镜像构建服务中「套壳」拉取海外镜像，随着同步工作流的成熟已不再需要，现已从仓库移除。如需查阅，可在 Git 历史中找到。

---

## 与原项目的差异

本仓库当前已与上述教程有明显不同：

| 方面 | 原始做法 | 当前做法 |
| --- | --- | --- |
| 触发方式 | `push` / `pull_request` 自动触发 | 仅 `workflow_dispatch` 手动触发（安全考虑） |
| 目标仓库 | Docker Hub | 阿里云 ACR / 自建 Harbor |
| 目标镜像名 | 取源镜像最后一段（`${i##*/}`） | 整条路径压平（`/` → `_`），避免不同来源互相覆盖 |
| 镜像列表 | 硬编码在 `run:` 中 | 工作流输入 / 清单文件 |
| 多架构 | 已有 `--all` | 保留，并新增 attestation 剔除路径 |
| 工具 | 仅 skopeo | skopeo + regctl 双路径 |
| 逻辑位置 | 全部写在 workflow 里 | 抽取到 `scripts/sync.sh`，本地可复用 |

关于当前设计背后的取舍，见 [ARCHITECTURE.md](ARCHITECTURE.md)。
