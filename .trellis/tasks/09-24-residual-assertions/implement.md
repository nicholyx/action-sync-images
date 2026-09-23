# implement：收拢 #166 的零散残余断言

只改 `.github/workflows/ci.yml`。**`scripts/sync.sh` 必须一行不改**（收尾时 `git diff` 核对）。

## 第 1 步：A —— `--updates-limit` 的「全部列出如下」分支

- [ ] 复用第 158 号任务留下的 stub 夹具（`/tmp/stub-skopeo`，stub 的 `list-tags` 固定返回
      `v1 v2 v3 v4 v5 v6 v10`）——或就近新建，注意**不要**与既有步骤的固定路径冲突
- [ ] 夹具让**缺失数 ≤ limit**：上游 7 个 tag、清单里放 5 个 → 缺失 2 个，`--updates-limit 5`
- [ ] 断文案含「全部列出如下」，**且**列出的恰好是那 2 个
- [ ] 对照：清单里只放 1 个（缺失 6 个）时必须是「版本序最大的 5 个」——两次运行相互为对照
- [ ] 变异：把 `scripts/sync.sh:2528` 的 `-le` 改成 `-ge` → 断言必须红（改完 `cp` 还原）

## 第 2 步：B —— `--tls-verify false` 的 skopeo 路径负面对照

- [ ] 落点就近放在既有那条正面断言的**同一个步骤**里（`ci.yml:2741-2748` 附近），
      紧邻着写，免得将来只改一处
- [ ] 跑一次**不带** `--strip-attestation` 的 `--tls-verify false`，断
      **不出现** `regctl 路径下 --tls-verify false 映射为明文 HTTP`
- [ ] **同一次运行**里断该参数确实生效（dry-run 的执行命令里带 `--tls-verify=false`）——
      没有它，「路径走对了」与「压根没跑」不可分
- [ ] 变异：把 `sync.sh` 里那条 `log_warn` 的 `regctl_path_active == true` 门禁去掉
      → 负面断言必须红

## 第 3 步：C —— stub 多仓库的分组去重

- [ ] 夹具：同一仓库两个 tag（`mock-a.local/app:v1` + `:v2`）+ 另一个仓库一个 tag
- [ ] 断检查报告里第一个仓库**只出现一次**，且「清单中」列出**两个** tag
- [ ] 断第二个仓库独立成一组（防止「全都合成一组」也能过）
- [ ] 变异：把去重/分组逻辑改成不去重 → 断言必须红

## 第 4 步：D —— 用断言钉住两条保守边界

- [ ] 在 #159 留下的抽取式单测（`notify_delivery_verdict`）里加两行矩阵：
      ① `200` + `ok `（尾随空白）→ `undetermined`（**同时**断不是 `confirmed`、
      不是 `rejected`——两者都要断）
      ② `200` + `{"code":0}\n{"code":310000}`（JSON Lines）→ `rejected`
- [ ] 每行注释写清**为什么这个方向可接受**（保守、绝不假成功），否则下一个人会当成 bug 去改
- [ ] 变异：把 slack 的比较改成去空白后 `== ok` → ① 必须红

## 验证命令

```bash
bash -n scripts/sync.sh
./scripts/lint.sh
# 抽出的步骤本地跑（注意：本机没装 skopeo 时用 PATH 前置 stub）
python3 /tmp/extract_step.py "<步骤名>" > /tmp/s.sh && bash /tmp/s.sh
git diff --stat scripts/sync.sh   # 必须为空
```

## 回滚点

每步一次独立的 `ci.yml` 插入；变异用 `cp` 备份还原，**不用 `git checkout <文件>`**。

## 复核门

- [ ] 四条都有「单点变异 → 红」的证据
- [ ] 两处负向判据（A 的对照、B 的负面）都与正面成对
- [ ] `./scripts/lint.sh` 8 · 0 · 0
- [ ] `scripts/sync.sh` 与 HEAD 逐字节一致