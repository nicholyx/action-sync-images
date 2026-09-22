# 执行计划：regctl 路径的 TLS 与源凭证

前置：`design.md` 的结论均已实证。执行时**不要重新推演方案**，按下面的顺序做；
每一步都给了验证方式。

## 步骤

### 0. 复现红（必须先做，否则后面无法区分「修好了」与「断言恒真」）

1. 起一个明文 HTTP registry（`registry:2`，映射到 `localhost:5000`）
2. 推一个多平台镜像进去做源
3. **清掉** `~/.regctl/config.json`（确保没有手工配置在替脚本干活）
4. 跑：

   ```bash
   ./scripts/sync.sh --src <http 源> --dest localhost:5000/dest-regctl \
     --strip-attestation --platforms linux/amd64 --tls-verify false --concurrency 1
   ```

5. **期望失败**，报错为 `server gave HTTP response to HTTPS client`
6. 把这段输出**原样贴进 PR 正文**——它是本修复的对照证据

**门**：没有复现到红，就不要往下走。先确认环境是不是哪里替脚本兜住了。

### 1. 新增 host 提取的复用点

`registry_host_of()`（`scripts/sync.sh:689`）已经能输出 `docker.io` / `host[:port]`，
直接用，不要新写一个。确认它对带端口与不带端口的引用都正确。

**门**：手工验证 `registry_host_of localhost:5000/foo:1` → `localhost:5000`。

### 2. 改造 `sync_via_regctl`

按 `design.md` §3.1 用数组先拼 `cmd=(regctl)`，再追加 `--host`，最后接
`index create`。要点：

- 全局 flag `--host` 放在子命令**之前**（实测有效；cobra 的 persistent flag
  位置虽灵活，但保持一种写法）
- 同 host 不重复注入（比对 `registry_host_of "$src"` 与 `"$dest"`）
- 用 `if` 而不是 `A && B`（SC2015 + `set -e`）
- dry-run 分支同步更新，复述真实参数（`design.md` §3.4）
- 打印一条说明：本次 regctl 走的是**明文 HTTP**，自签证书请用
  `~/.regctl/config.json`（`design.md` §3.1 的缓解措施 a）

**门**：重跑步骤 0 的命令，应当**成功**。

### 3. 新增 `prepare_regctl_cred_dir()`

- 全局 `REGCTL_CRED_DIR=""` 声明在其它全局量附近
- 函数内部先判断 `[[ "$STRIP_ATTESTATION" == "true" && -n "$SRC_AUTHFILE" ]]`，
  不满足立即 `return 0`
- 目录 `mktemp -d` + `chmod 700`；`config.json` `chmod 600`
- 合并逻辑照 `design.md` §3.2；`jq -s '.[0] * .[1]'` 是**递归**合并，
  实现时用一个假的使用者配置验证 `auths` 里的条目是**并集**而不是被替换
- 在 `SRC_AUTHFILE` 就绪之后调用一次（找 `setup_src_auth` 的调用点）

**门**：建一个假的 `~/.docker/config.json`（含另一个 host 的 auths 项），
跑一次带源凭证的 `--strip-attestation`，确认临时目录里的 `config.json`
**同时**含两项。

### 4. 接上 `env` 传递与清理

- `run_with_timeout env DOCKER_CONFIG="$REGCTL_CRED_DIR" "${cmd[@]}"`
  （`REGCTL_CRED_DIR` 为空时不要加 `env` 前缀，保持原行为）
- `cleanup()` 加一行删除 `REGCTL_CRED_DIR`

**门**：跑完一次后 `ls` 该临时目录，确认已删除；`Ctrl-C` 中断一次，同样确认。

### 5. CI 步骤改造（`integration-test` job）

1. **删掉**手工写 `~/.regctl/config.json` 的那段（它正是本缺陷的证据）
2. 该步骤改传 `--tls-verify false`
3. 保留 #121 的两条断言（平台集正好是 `linux/amd64`；目标摘要不同于源）
4. **新增私有源用例**：`registry:2` + htpasswd 起需要 Basic 认证的仓库，
   源从它读；断言「带凭证成功」与「不带凭证失败（401）」**两条**
5. 若新增步骤与既有步骤共用 registry 容器，注意端口与清理

**门**：本地能跑通的等价命令，逐条写进 CI；不要写没在本地跑过的断言。

### 6. 文档同步

- `docs/USAGE.md`：`--strip-attestation` 与 `--tls-verify` 的交互（含 `disabled`
  与 `insecure` 的差异、自签证书的绕法）
- `docs/TROUBLESHOOTING.md`：保留报错原文（`server gave HTTP response to HTTPS client`、
  `no credentials available: unauthorized`），写明什么情况下不该用这个方案
- `docs/ARCHITECTURE.md`：为什么 TLS 走 `--host` 而凭证走临时 `DOCKER_CONFIG`；
  为什么 `REGCTL_CONFIG` 被否掉（替代语义）
- `CHANGELOG.md`：`[Unreleased]` → `### 修复`，写清「此前错在哪、有什么后果」
  ——**插入前断言锚点在 `[Unreleased]` 与下一个 `## [` 之间**
  （`maintenance/index.md` 记过这个坑）

### 7. 全量回归

```bash
bash -n scripts/sync.sh
shellcheck scripts/sync.sh        # 注意本地新版与 CI 旧版报错不一致
./scripts/sync.sh --help >/dev/null
```

外加 `smoke-test` 与 `integration-test` 两个 job 全绿。

## 审查门（交给 trellis-check）

按 `prd.md` 的 AC1–AC9 逐条核，其中三条是**必须做变异验证**的：

- **AC2**：只测「带凭证成功」是不够的——源可能恰好匿名可读，断言会恒真。
  必须同时验「不带凭证失败」
- **AC7**：把合并逻辑临时改成「直接复制 `$SRC_AUTHFILE`」，确认 AC7 的断言**会失败**；
  不会失败就说明断言是恒真的，等于没写
- **AC4**：用固定字符串做诱饵（如 `pass=DECOY_PASSWORD`），跑起来后在 `ps` 输出里
  grep 它，确认**搜不到**

另外三条容易被漏掉：

- AC3 要比对 `~/.regctl/config.json` 与 `~/.docker/config.json` 的**前后哈希**，
  不是「看起来没变」
- AC5 的中断用例要真的发 `SIGINT`，不是让它正常退出
- AC6 要确认 dry-run 里**没有**凭证的值

## 回滚点

- **步骤 2 完成**后可独立回滚：只动 `sync_via_regctl`，删掉 `--host` 分支即回到原状
- **步骤 3–4 完成**后回滚要连 `cleanup()` 那行一起删，否则 `cleanup` 引用不存在的
  变量（`set -u` 下会炸）
- **步骤 5 的 CI 改动**与代码改动在同一 PR，回滚一并
- 整个改动无持久状态、无数据迁移，`git revert` 单个 squash 提交即可

## 容易踩的坑（本项目已有教训，见 `.trellis/spec/engine/bash-rules.md`）

- 空数组 + `set -u` 在 bash 3.2 抛 unbound variable——`cmd` 恒非空，安全；
  但新写的任何数组遍历都要先判长度
- `printf '%s'` 不输出结尾换行，配 `while IFS= read -r` 会丢最后一段
- 管道接 `tail`/`head` 后 `if` 判断的是尾部命令的退出码——判成败用
  `if out="$(cmd 2>&1)"`
- 第三方工具（`jq`）的退出码不得冒成脚本的退出码
- 进程替换 `< <(...)` 不传退出码
