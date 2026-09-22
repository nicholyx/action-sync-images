# fix: check-commit-msg.sh 对无效区间静默放行

对应 Issue：nicholyx/action-sync-images#132

## Goal

`--range` 模式把 `git log` 的 stderr 丢弃（`check-commit-msg.sh:142`），于是**不区分「区间无效」与「区间内没有提交」**——两者都得到 0 条，都打印「**全部合规（共检查 0 条）**」并 exit 0。

```text
$ ./scripts/check-commit-msg.sh --range nonsense..HEAD   → 全部合规（共检查 0 条）  exit 0
$ ./scripts/check-commit-msg.sh --range abc123..def456   → 全部合规（共检查 0 条）  exit 0
```

而它 header 第 11 行推荐的本地用法正是 `--range origin/main..HEAD`——**刚 clone、没有 remote-tracking ref、或 detached HEAD 时就是这个形态**，会静默放行。

这与项目记过的「恒真的断言比没有断言更糟」是同一族：**0 条检查结果冒充「全部合规」**。

## 关键前提（已实测，方案就建立在它上面）

**两种情形的退出码完全区分得开**：

| 情形 | `git log --format='%s' <区间>` 的 rc | 输出 |
| --- | --- | --- |
| 区间**无效**（ref 不存在 / 不存在的 SHA） | **128** | `fatal: ambiguous argument '…': unknown revision or path not in the working tree.` |
| 区间**有效但为空**（如 `HEAD..HEAD`） | **0** | 空 |
| 区间有效非空 | 0 | 提交信息 |

所以**不需要**先去 `git rev-parse --verify` 逐个 ref——`git log` 的退出码本身就是判据。

## Requirements

### R1 接住 `git log` 的退出码

失败（rc ≠ 0）时**报错退出**，并把 git 的报错原文带出来（只取首行，与 `history.sh` 取 stderr 首行的既有做法一致）。**不要**继续打印「全部合规」。

### R2 「区间为空」要说得准确

rc = 0 但一条都没读到，此时**措辞不能是「全部合规」**——那会让人以为验过了。

**这里的取舍**（需要明确记录）：

- **exit 码保持 0**。理由：CI 里 `BASE..HEAD` 为空是**合法情形**（例如一个只有 merge 的 PR），把它判失败会制造假红
- 但输出要明确说明「区间里没有提交，没有可校验的内容」，让人知道**这次什么都没验**

替代方案（把空区间也判失败）被否掉：它会把一个合法情形变成红灯，而判据「有没有提交可验」与「提交信息合不合规」是两回事。

### R3 报错文案要能指路

区间无效的常见原因是 ref 不存在（`origin/main` 没 fetch、拼错、detached HEAD）。
文案里应带上**使用者给的那个区间字符串**，并在合适时提示检查 ref 是否存在——但不要猜具体原因，如实转述 git 的话。

### R4 不改退出码语义的其它部分

- 有不合规提交 → exit 1（不变）
- 全部合规且有提交 → exit 0（不变）
- `--message` / `--file` 模式不受影响

## Acceptance Criteria

- [ ] **AC1** `--range` 传无效区间（ref 不存在、不存在的 SHA）→ **exit 1**，且输出含 git 的报错信息，**不含**「全部合规」
- [ ] **AC2** `--range HEAD..HEAD`（有效但空）→ exit 0，但输出**不是**「全部合规」，
      而是明确说明「没有提交可校验」
- [ ] **AC3** 有效非空区间行为不变（合规 → 0，不合规 → 1）
- [ ] **AC4** **变异验证**：把接住退出码的那段改回 `2>/dev/null` 的原样，AC1 必须变红
- [ ] **AC5** 加断言进 CI（`ci.yml` 的 `commit-messages` job 或 smoke-test，择一，
      在 PR 里说明选择理由）
- [ ] **AC6** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 两个 job 全绿

## Constraints

- 兼容 bash 3.2
- 不改 `check_one` 的规则、不改 `--message` / `--file` 模式
- 不新增命令行参数

## Out of Scope

- **`--last` 的 `HEAD~1..HEAD` 在仓库首个提交上也会落到「区间无效」**——修完 R1 之后它会**报错而不是静默放行**，
  这正是期望行为（首个提交本就无从比较）。不再为它单独加逻辑
- `check_one` 对 merge 提交的放行规则
- #130 的 lint.sh 接入问题（`lint.sh` **不接入**本脚本的决定不变——本 issue 只修它自身的缺陷）

## Notes

- **本 issue 的修法是「让静默变成可见」，不是「让空区间失败」**——这两件事很容易混。
  判据是「**0 条检查结果不能冒充「全部合规」**」，而不是「0 条就是错」
- 发现经过：在 #130（`lint.sh` 承诺与实现不符）的方案评估中撞到——当时正考虑把本脚本接进
  `lint.sh`，一验证就发现它会假绿，于是 #130 决定不接入它。**修完本 issue 之后，
  「接不接」这个决定仍应重新评估一次**（见 #130 的 Out of Scope）