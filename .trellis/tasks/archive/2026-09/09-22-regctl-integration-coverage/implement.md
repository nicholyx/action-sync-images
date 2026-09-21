# 执行计划：让 regctl 路径的真实推送进 CI

## 前置

```bash
git switch main && git pull
git switch -c test/regctl-integration-coverage
./scripts/lint.sh          # 基线必须全绿
```

断言逻辑已用假 JSON 实测过（见 `design.md` 的「断言逻辑已实测」），照抄即可。

## 步骤

### 1. 在 `integration-test` job 加一个步骤

位置：**紧接**「首次同步（真实推送）」之后——复用同一个源镜像 `localhost:5000/source/hello:latest`，推到**新的目标前缀** `localhost:5000/dest-regctl`，与既有用例的产物并列对照。

完整片段见 `design.md` 落点一。

**三个容易写错的点**：

1. **目标名走压平规则**：`--dest localhost:5000/dest-regctl` + 源 `localhost:5000/source/hello:latest` → `localhost:5000/dest-regctl/localhost_5000_source_hello:latest`（与既有用例同构，只是前缀变了）
2. **不预装 regctl**：脚本的 `ensure_regctl` 自己会下载。别在 job 里加安装步骤——那会绕开被测代码
3. **断言二不能省**：只断言「推送成功」是不够的，skopeo 路径同样会成功。**产物与源摘要不同**才是「真的重建了索引」的证据

### 2. 本地能验的部分

```bash
# 断言逻辑：用假 JSON 跑（design 里那张表的三种输入）
# 参数与路径选择：dry-run 应显示 regctl 路径
./scripts/sync.sh --src localhost:5000/source/hello:latest --dest localhost:5000/dest-regctl \
  --strip-attestation --platforms linux/amd64 --dry-run 2>&1 | grep '执行路径'
# 期望：执行路径：regctl index create
```

**本地验不了真实推送**（没有 `registry:2`）——那部分只能等 CI。

### 3. 反证（在 CI 上做一次）

把新用例的 `--strip-attestation --platforms linux/amd64` 临时去掉、推一次，确认**断言二失败**。这是「断言不是恒真」的证明。验完还原。

**如果可以**，把这个反证也在本地用假 JSON 跑一遍（design 的表里已经有这一行）。

### 4. 收尾

- `actionlint`、`yamllint -c .yamllint .github/`、`./scripts/lint.sh`
- CHANGELOG：加 `### 修复` 或 `### 变更`（补测试覆盖通常归入后者；与本仓库既有分类保持一致）
- 全仓 U+FFFD 与控制字符扫描

## 审查门

- [ ] 新步骤在 `integration-test` job 内，位置紧随「首次同步」
- [ ] 目标前缀是**新的**（`dest-regctl`），不与既有用例冲突
- [ ] **没有**加 regctl 安装步骤（脚本自理）
- [ ] 两条断言都在，且平台断言是「**恰好等于**」而非「包含」
- [ ] 反证做过（去掉 `--strip-attestation` → 断言二失败）
- [ ] 不新增 secret、不改 job 的其他步骤
- [ ] `actionlint` / `yamllint` / `lint.sh` 全绿
- [ ] CHANGELOG 已加条目
- [ ] 全仓无 U+FFFD 与控制字符

## 回滚

单一步骤，`git revert` 即可。不影响任何生产代码。
