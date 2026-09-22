# 设计：让 regctl 路径的 TLS 与源凭证生效

## 1. 问题定位（代码事实）

`sync_via_regctl`（`scripts/sync.sh`）构造的命令只有三样东西：

```bash
run_with_timeout regctl index create "$dest" \
  --ref "$src" \
  "${platform_args[@]}"
```

对照 `sync_via_skopeo`：

```bash
cmd=(skopeo copy --all --retry-times "$MAX_RETRIES")
if [[ "$TLS_VERIFY" == "false" ]]; then          # ← regctl 路径缺失
  cmd+=(--src-tls-verify=false --dest-tls-verify=false)
fi
if [[ -n "$SRC_AUTHFILE" ]]; then                # ← regctl 路径缺失
  cmd+=(--src-authfile "$SRC_AUTHFILE")
fi
```

`SRC_AUTHFILE` 的全部使用点（`sync.sh:677/829/925/981/2214`）**没有一个**落在
`sync_via_regctl` 的范围内。

## 2. regctl 能力调研（2026-09-22 本地实测，v0.11.6，与脚本 `REGCTL_VERSION` 一致）

用两个探针 registry（一个纯 HTTP、一个返回 `401 WWW-Authenticate: Basic`）
逐项验证，结论如下。

| 结论 | 验证方式 | 结果 |
| --- | --- | --- |
| `--host` 是**逐命令叠加**的 host 覆盖，不写回配置文件 | `regctl registry config --host ...` 后读文件 | 文件不变；官方文档亦说明 `--host` 注入的值不进 `registry config` |
| `--host reg=H,tls=disabled` 让 regctl 改用**明文 HTTP** | 无 `--host` 报 `server gave HTTP response to HTTPS client`；加上后请求到达 HTTP 探针 | 有效 |
| `--host reg=H,user=U,pass=P` 凭证确实生效 | 401 探针第二次收到 `Authorization: Basic YWxpY2U6czNjcmV0` | 有效（但本设计不采用，见 §4） |
| `DOCKER_CONFIG=<dir>` 被 regclient 尊重 | 临时目录放 `config.json`，401 探针收到 Basic 头 | 有效 |
| `REGCTL_CONFIG` 是**替代**语义，不是合并 | 指向另一份配置后，原 `~/.regctl/config.json` 里的 host 全部消失 | 是替代——**这是陷阱**，见 §4 |
| `REGCTL_CONFIG` 与 `DOCKER_CONFIG` 可并存，Docker 凭证通道仍生效 | 两者同时设置，401 探针仍收到 Basic 头 | 有效 |
| TLS 被覆盖时 regctl 会主动告警 | `level=WARN msg="Changing TLS settings for registry orig=enabled new=disabled"` | 可见性天然具备 |
| 无凭证时的报错文本 | — | `no credentials available: unauthorized` |

配置文件的权威格式（由 `regctl registry set` 生成）：

```json
{"hosts": {"a.example": {"tls": "disabled", "hostname": "a.example", "reqConcurrent": 3}}}
```

`tls` 取值只有三个：`enabled` / `insecure` / `disabled`。

## 3. 最终设计

### 3.1 TLS：走 `--host` 叠加，不用配置文件

```bash
local -a cmd=(regctl)

if [[ "$TLS_VERIFY" == "false" ]]; then
  cmd+=(--host "reg=$(registry_host_of "$src"),tls=disabled")
  local dest_host; dest_host="$(registry_host_of "$dest")"
  # 同 host 不重复注入：regclient 对同一 reg 给两次会不会取后者未验证，
  # 而重复本身没有意义
  if [[ "$dest_host" != "$(registry_host_of "$src")" ]]; then
    cmd+=(--host "reg=${dest_host},tls=disabled")
  fi
fi

cmd+=(index create "$dest" --ref "$src")
cmd+=("${platform_args[@]}")
```

**为什么选 `--host` 而不是 `REGCTL_CONFIG` 临时文件**：`--host` 是**叠加**，
使用者在 `~/.regctl/config.json` 里配的自签 `cacert`、其它 host 的凭证全部保留；
而 `REGCTL_CONFIG` 是**替代**（上表实测），一旦设置，使用者原有的全部 registry 配置
都会失效——为一个参数引入那样的副作用不成比例。

**`--tls-verify false` → `tls=disabled`（明文 HTTP）的取舍**（必须写进文档）：

- skopeo 的 `--tls-verify=false` 含义是「用 HTTPS 但不校验证书」，且
  `containers/image` 在遇到 HTTP 仓库时会**回退**，所以它对「自签 HTTPS」与
  「明文 HTTP」两种场景都有效
- regctl 的 `tls` 是**单值**，两个场景无法兼顾：`disabled` 只覆盖明文 HTTP，
  `insecure` 只覆盖自签 HTTPS
- 选 `disabled` 的理由：regctl 自己的错误提示就是 `Try updating your registry with
  "regctl registry set --tls disabled <registry>"`，即这是 regclient 对「连不上」
  的官方答案；且 `--tls-verify false` 最常见的动机是内网明文仓库
- **代价**：自签 HTTPS 场景在 regctl 路径下不适用。缓解有两条——
  (a) 该组合生效时打印一条 `log_info`，说明本次用的是明文 HTTP，自签证书请在
  `~/.regctl/config.json` 里配 `cacert`；
  (b) `docs/TROUBLESHOOTING.md` 记录该差异与绕法

**待实现时实测的一点**：`registry_host_of` 对 Docker Hub 返回 `docker.io`，
需确认 regclient 是否认这个名字（regclient 内部把 `docker.io` 映射到
`registry-1.docker.io`）。**若不认，后果是这条 `--host` 被忽略——与修复前行为相同，
不构成回归**；但应在集成测试里确认，别把「没生效」当成「生效了」。

### 3.2 源凭证：临时 `DOCKER_CONFIG` 目录，叠加使用者的 docker 配置

`DOCKER_CONFIG` 同样是**替代**语义：指向一个只含源凭证的目录，
使用者在 `~/.docker/config.json` 里的**目标仓库**登录信息就会消失——而目标仓库的
凭证在 CI 与本地都来自 `docker login`，于是「修好了源、弄坏了目标」。这是静默回归，
必须避免。

所以临时目录里的 `config.json` 是**使用者配置与源凭证的合并**：

```bash
# 使用者的 docker 配置位置（尊重既有的 DOCKER_CONFIG）
base_docker="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

if [[ -f "$base_docker" ]] && jq -e . "$base_docker" >/dev/null 2>&1; then
  # jq 的 * 对对象是**递归**合并，auths 会逐条并集，正是所需
  jq -s '.[0] * .[1]' "$base_docker" "$SRC_AUTHFILE" > "${REGCTL_CRED_DIR}/config.json" \
    || die "合并 regctl 凭证配置失败"
else
  # 使用者没有 docker 配置（或它不是合法 JSON）时从空开始
  jq -e . "$SRC_AUTHFILE" > "${REGCTL_CRED_DIR}/config.json" || die "生成 regctl 凭证配置失败"
fi
```

传递方式用 `env`，避免 `VAR=x func` 的隐式作用域，也避免 export 污染同进程的
后续逻辑：

```bash
run_with_timeout env DOCKER_CONFIG="$REGCTL_CRED_DIR" "${cmd[@]}"
```

**为什么不用 `--host` 传 `user`/`pass`**：项目已把「凭证不经过命令行」写成明文原则
（`sync.sh` 源凭证段注释：命令行对 `ps aux` 可见，且 `--dry-run` 会原样打印命令）。
若把密码塞进 `--host`，dry-run 就只能在「如实打印」与「打码」之间二选一——
前者泄漏、后者违反 dry-run 铁律。走文件两个问题同时消失。

**准备时机**：凭证在启动时即固定，不该每次同步都重建。新增全局
`REGCTL_CRED_DIR=""`，由新函数 `prepare_regctl_cred_dir()` 一次性准备，
在 `SRC_AUTHFILE` 就绪之后调用；函数内部先判断
`[[ "$STRIP_ATTESTATION" == "true" && -n "$SRC_AUTHFILE" ]]`，不满足就直接 `return 0`
（不创建任何东西）。

- 目录 `mktemp -d`，`chmod 700`；`config.json` `chmod 600`
- 纳入既有 `cleanup()`：`[[ -n "${REGCTL_CRED_DIR:-}" ]] && rm -rf "$REGCTL_CRED_DIR"`
- 保证 `cleanup()` 覆盖 `SIGINT`（AC5）

### 3.3 日志诚实

修复后 `write_src_authfile` 里那句「源仓库凭证已装载」不再误导——凭证确实会送到
regctl。但要注意**顺序**：该信息在 `prepare_regctl_cred_dir()` 之前打印也可以，
因为它描述的是「凭证已准备好」，而合并只是把它换成 regctl 能读的形态。

### 3.4 dry-run

`sync_via_regctl` 的 dry-run 分支要复述**真正会执行的参数**（项目铁律）：

- `--host reg=H,tls=disabled` 照常打印（无敏感信息）
- `DOCKER_CONFIG=<dir>` 打印**路径**，不打印内容（无敏感信息）
- 凭证的值（用户名/密码）不得出现在 dry-run 输出里

### 3.5 CI 覆盖

现有「regctl 路径（`--strip-attestation`）的真实推送」步骤**手工写入了
`~/.regctl/config.json`** 把 host 标成 `tls: disabled`——那一步的存在本身就是本缺陷的
证据（#121 的记录）。修复后应当：

1. **删掉手工写配置**，改传 `--tls-verify false`
2. 断言该步骤在**没有** `~/.regctl/config.json` 的前提下成功
3. 新增私有源用例：起一个需要 Basic 认证的 registry（`registry:2` + htpasswd 是标准做法），
   源从它读；断言「带凭证成功、不带 401」
4. 保留 #121 已有的两条断言（平台集正好是 `linux/amd64`；目标摘要不同于源）

## 4. 被否掉的方案

| 方案 | 否决理由 |
| --- | --- |
| `--host reg=H,user=U,pass=P` 传凭证 | 违反 R3：密码进命令行，`ps aux` 可见且 dry-run 必须打码（进而违反 dry-run 铁律） |
| `REGCTL_CONFIG` 指向临时配置（只含源凭证与 TLS） | 替代语义：使用者 `~/.regctl/config.json` 里的其它配置全部失效。要用它就必须自行合并用户配置，而那还不如直接用 `--host` 叠加来得干净 |
| 写使用者全局 `~/.regctl/config.json` | 直接违反 R2，且并发运行会互相覆盖 |
| 改用 `skopeo` 传 `--src-authfile` 等的等价物 | regctl 的 `index create` 是重建索引的**唯一**手段，换工具就丢了 `--strip-attestation` 的全部意义 |

## 5. 兼容性与风险

- **bash 3.2**：`cmd` 数组恒非空，不触发空数组 + `set -u` 的 unbound variable；
  条件用 `if` 而非 `A && B`（SC2015 与 `set -e` 交互）
- **函数抽取执行**（CI 用 `sed` 抽函数单测）：`sync_via_regctl` 新增的依赖必须自包含
  ——`registry_host_of` 已是独立函数；`TLS_VERIFY` / `SRC_AUTHFILE` / `REGCTL_CRED_DIR`
  是运行级全局，若 CI 要抽取 `sync_via_regctl` 单测，需要像既有抽取那样自行声明
- **不传参数时零变化**：`TLS_VERIFY` 默认 `true`、`SRC_AUTHFILE` 默认空，
  两个新增分支都不会进入，普通用户的命令逐字节不变
- **回滚**：改动集中在 `sync_via_regctl` + 一个新函数 + `cleanup()` 一行，
  `git revert` 单个提交即可，无数据迁移、无持久状态

## 6. 验证策略

先复现红，再验绿——每条断言都要有「修复前失败」的对照，否则无法区分
「修复生效」与「断言恒真」：

- **AC1 红**：修复前，HTTP 仓库 + `--strip-attestation --tls-verify false`
  → `server gave HTTP response to HTTPS client`（已实测复现）
- **AC1 绿**：修复后同命令成功
- **AC2**：私有源带凭证成功 / 不带 401——两条都要测，只测「成功」无法排除
  「源恰好匿名可读」导致的恒真
- **AC7 变异验证**：故意让合并退化为「直接用 `$SRC_AUTHFILE`」，
  确认 AC7 的断言**会失败**——否则该断言是恒真的，等于没写
