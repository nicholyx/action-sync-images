# 设计：让 regctl 路径的真实推送进 CI

## 边界

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/ci.yml` | `integration-test` job 加**一个步骤** |

**不改** `sync.sh`（本任务只补覆盖）、不动 `smoke-test`、不预装 regctl（理由见落点二）。

## 落点一：用例长什么样

紧接既有的「首次同步（真实推送）」之后——**复用同一个源镜像**（`localhost:5000/source/hello:latest`），但推到**不同的目标前缀**，两条路径的产物因此可以并列对照：

```yaml
      - name: regctl 路径（--strip-attestation）的真实推送
        run: |
          #!/usr/bin/env bash
          set -euo pipefail

          # 这条路径此前只在 dry-run 与参数层面被测过。它与默认的 skopeo 路径
          # 是完全不同的实现（regctl index create 重建索引、逐平台复制），
          # 而项目自己记过：dry-run 覆盖不到真实推送，v1.1.0 的三个缺陷
          # 全部发生在那里。
          #
          # 源镜像不需要真的带 attestation——这条路径的语义是「重建一个只含
          # 指定平台的索引」，对普通镜像同样成立。
          output="$(./scripts/sync.sh \
            --src localhost:5000/source/hello:latest \
            --dest localhost:5000/dest-regctl \
            --strip-attestation --platforms linux/amd64 \
            --tls-verify false --concurrency 1 2>&1)"
          echo "$output"

          dest="localhost:5000/dest-regctl/localhost_5000_source_hello:latest"
          raw="$(skopeo inspect --raw --tls-verify=false "docker://${dest}")" || {
            echo "::error::regctl 路径的目标镜像不存在：${dest}"; exit 1; }

          # 断言一：产物是**索引**，且平台集合**恰好**是指定的那个。
          # 这是 regctl 路径区别于 skopeo 路径的核心语义——同一个多平台的
          # 源，skopeo 会原样搬运整个索引（多个平台），regctl 只保留列出的。
          platforms="$(jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"' <<<"$raw" | sort | tr '\n' ' ')"
          if [[ "$platforms" != "linux/amd64 " ]]; then
            echo "::error::regctl 路径的平台集合应为「linux/amd64」，实际为「${platforms}」"
            exit 1
          fi

          # 断言二：产物与源**必然不同**。重建索引意味着 digest 不会与源相同——
          # 若相同，说明它其实走的是原样搬运（skopeo）那条路。
          src_sum="$(skopeo inspect --raw --tls-verify=false docker://localhost:5000/source/hello:latest | openssl dgst -sha256 | awk '{print $NF}')"
          dest_sum="$(openssl dgst -sha256 <<<"$raw" | awk '{print $NF}')"
          if [[ "$src_sum" == "$dest_sum" ]]; then
            echo "::error::目标与源摘要相同——说明没有重建索引，走的不是 regctl 路径"
            exit 1
          fi

          echo "✓ regctl 路径真实推送成功：索引只含指定的平台"
```

### 为什么这两条断言能区分路径

`localhost:5000/source/hello:latest` 是从 `docker.io/library/hello-world:latest` 复制的，**本身是多平台索引**。于是同一个源在两条路径下的产物不同：

| 路径 | 目标产物 | 平台数 | 与源 digest |
| --- | --- | --- | --- |
| skopeo（既有用例 `dest/…`） | 原样搬运的索引 | 多个 | **相同** |
| **regctl（本用例 `dest-regctl/…`）** | 重建的索引 | **恰好 1 个** | **不同** |

断言二尤其重要：只断言「推送成功」是不够的——skopeo 路径同样会成功，而**两条路径的产物 digest 不同**才是 regctl 真的重建了索引的证据。

## 落点二：为什么不预装 regctl

`ensure_regctl()`（`scripts/sync.sh:738`）本身就含获取逻辑：

1. `command -v regctl` 存在 → 直接用
2. dry-run → 不下载，只告警
3. 否则 → 从 `https://github.com/regclient/regclient/releases/download/${REGCTL_VERSION}/regctl-${os}-${arch}` 下载到 `$HOME/.regclient/bin`，`chmod +x`，`export PATH`
4. 下载失败 → `die`

**所以 CI 里什么都不用装**：让用例走这条路，它既是使用者在 CI 之外会遇到的样子，也顺带覆盖了 `ensure_regctl` 本身（包括那个 `os`/`arch` 映射）。

预装反而绕开了被测代码——这与「用真实路径测真实行为」的初衷相悖。

**代价**：每次运行多一次下载（几秒）。这个 job 本来就要从 `docker.io` 拉 `hello-world` 当素材，所以不新增「依赖外网」这个前提。

## 兼容性

| 影响面 | 说明 |
| --- | --- |
| 该 job 的其他步骤 | 不受影响：新用例用**新的目标前缀**（`dest-regctl`），与既有的 `dest` 不冲突 |
| `sync.sh` | 零改动 |
| job 时长 | +一次 regctl 下载 + 一次小镜像同步（hello-world 极小） |
| secret | 不新增 |
| 失败时的可诊断性 | 下载失败时脚本自己 `die` 并打出下载 URL；平台不符时报出实际平台集合 |

## 反证（断言不是恒真的证明）

**不改代码**就能反证：把新用例的 `--strip-attestation --platforms linux/amd64` **去掉**，让它走默认的 skopeo 路径——此时产物与源 digest **相同**、平台集合是多个，**断言二必然失败**。这证明这两条断言确实在测「走的是不是 regctl 路径」，而不是「推送有没有成功」。

### 断言逻辑已实测（2026-09-22）

两条断言已抽出来用假 JSON 跑过（多平台索引 = skopeo 产物/源，单平台 = regctl 产物）：

| 输入 | 断言一（平台集合 == `linux/amd64`） | 断言二（与源摘要不同） |
| --- | --- | --- |
| 多平台索引 | **失败**（实际 `linux/386 linux/amd64 linux/arm64`） | — |
| 单平台 `linux/amd64` | **通过** | **通过**（与源的多平台摘要不同） |
| **反证**：多平台索引（即 skopeo 产物） | 失败 | **失败**（与源摘要相同）← 去掉 `--strip-attestation` 的情形 |

第三行是断言有效性的证据：它证明断言二能在「误走 skopeo 路径」时失败，而不是恒真。

真实推送只能在 CI 验证（本地没有 `registry:2`）。

## 验证方式

| 层次 | 怎么验 |
| --- | --- |
| 断言逻辑 | 抽出来用假 JSON 跑：多平台 → 失败；单平台 → 通过；与源相同 → 失败 |
| 参数与路径选择 | 本地 dry-run：`--strip-attestation --platforms linux/amd64` 的计划应显示 `执行路径：regctl index create`（既有 smoke-test 已覆盖这一层） |
| **真实推送** | **CI 的 integration-test job**（本地无 registry:2，只能在那里验） |
| 反证 | CI 上把 `--strip-attestation` 去掉跑一次，确认断言失败 |
