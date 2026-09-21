# 执行计划：让默认目标仓库在使用前可见

## 前置

```bash
git switch main && git pull
git switch -c fix/default-dest-clarity
./scripts/lint.sh          # 基线必须全绿
```

设计里四个落点都已定稿（含判断条件与文案），照做即可。

## 步骤

### 1. 工作流加前置提示（两个文件）

`sync-images-aliyuncs.yml` 与 `sync-images-batch.yml`：

- `env:` 加两个变量（`REPO_OWNER`、`DEFAULT_DEST`），沿用项目「所有 `${{ }}` 先落 `env:`」的既有做法
- 「登录目标仓库」步骤内、`docker login` **之前**加判断（`design.md` 落点一有完整片段）

**两个要点**：

- 判据是 `[[ "$DEST_REGISTRY" == "$DEFAULT_DEST" ]]`，**不是** `*nicholyx*` 匹配——后者会误伤把区域换到杭州但保留同名命名空间的使用者
- 用 `echo "::warning::"`，**不用 `exit 1`**：默认值可能是使用者的合法选择

### 2. README 快速开始加一步

在「配置凭证」与「触发同步」之间插入「设置目标仓库」，后续步骤顺延编号（`design.md` 落点二有文案）。

**顺延编号时注意**：README 里可能有别处引用「第 2 步」这类措辞，一并核对。

### 3. USAGE 改口径

`:108` 的「### 可选：更换目标仓库」改为「### 目标仓库（`ALIYUNCS_REGISTRY`）」，第一句点明默认值是谁的，并把它从「可选」的位置挪到必读区。

### 4. TROUBLESHOOTING 改排查步骤

`denied` 的排查第一条改为「确认目标仓库是你的」（`design.md` 落点四有文案），**去掉「（如 `nicholyx`）」这个会误导的举例**。

### 5. 验证

**工作流的 shell 片段抽出来本地跑**（两个变量各取一组，四种组合见 `design.md` 的验证表）：

```bash
# 抽 if 片段，用四种组合跑
DEST_REGISTRY="registry.cn-shenzhen.aliyuncs.com/nicholyx" REPO_OWNER="someone-else" bash /tmp/frag.sh
# 期望：一条 ::warning::
DEST_REGISTRY="registry.cn-shenzhen.aliyuncs.com/nicholyx" REPO_OWNER="nicholyx" bash /tmp/frag.sh
# 期望：无输出
DEST_REGISTRY="registry.cn-hangzhou.aliyuncs.com/nicholyx" REPO_OWNER="someone-else" bash /tmp/frag.sh
# 期望：无输出（判据精确）
```

**第四种组合是判据精确性的检查点**，不能只看「默认值」那两种。

### 6. 收尾

- `actionlint`、`yamllint -c .yamllint .github/`、`./scripts/lint.sh`
- 全仓 U+FFFD 与控制字符扫描
- CHANGELOG `[Unreleased]` → `### 文档`（或 `### 变更`，与项目既有分类一致）

## 审查门

- [ ] 两个工作流都有前置提示（Aliyuncs 与 Batch）
- [ ] 提示用 `::warning::`，**不**改变退出码与同步行为
- [ ] 判据是精确比较，四种组合都验过（含「含 nicholyx 但非默认值」不误伤）
- [ ] 两个变量走 `env:`，没有 `${{ }}` 直接出现在 `run:` 里
- [ ] README 的快速开始能在同步**之前**告诉使用者要设变量；后续步骤编号已顺延
- [ ] USAGE 不再把它说成「可选」
- [ ] TROUBLESHOOTING 的 `denied` 排查里能查到这条根因，且没有「（如 `nicholyx`）」这种误导举例
- [ ] 三处文档口径一致（都说清默认值是谁的、都给出设置方式）
- [ ] `actionlint` / `yamllint` / `lint.sh` 全绿
- [ ] 全仓无 U+FFFD 与控制字符

## 回滚

五个文件互相独立。若只有工作流提示出问题（例如 actionlint 对 `::warning::` 的写法有意见），可单独回退它而保留文档修正——**文档那三处是本次的主要交付**，提示是锦上添花。
