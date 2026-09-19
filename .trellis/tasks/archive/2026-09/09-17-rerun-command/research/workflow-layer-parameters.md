# Research: 工作流层的调用方式与参数（重跑命令需要复现的那一份）

- **Query**: 哪些 step 负责写 Summary？工作流传给 `sync.sh` 的参数是哪些？调用方式是本地 CLI 还是 Actions 专用入口？两者参数是否一致？
- **Scope**: internal（`.github/workflows/sync-images-*.yml`、`check-registry.yml`）
- **Date**: 2026-09-17

## Findings

### 11. Summary 责任方与各工作流传参（已确认）

**Summary 没有任何专门 step**——由 `sync.sh` 自身写（见 `check-modes-and-step-summary.md` 第 4 节）。工作流只负责：checkout → registry 登录 → 跑脚本 → `if: always()` 上传 `reports/` 为 Artifact。

#### `sync-images-aliyuncs.yml`

- 参数组装：`.github/workflows/sync-images-aliyuncs.yml:109-136`
  ```
  args=(--src "$IMAGES_SRC" --dest "$DEST_REGISTRY" --report-dir ./reports)
  + 条件追加：--strip-attestation / --platforms / --concurrency /
              --skip-existing / --verify / --dry-run /
              --notify-webhook + --history-artifact sync-report-aliyuncs /
              --notify-after-failures（仅当 != "1"）
  ```
- 调用：`.github/workflows/sync-images-aliyuncs.yml:139` `./scripts/sync.sh "${args[@]}"`
- 会把调用打进日志：`:138` `echo "执行：./scripts/sync.sh ${args[*]}"`（凭证已刻意走 env 避开了这一行，见 `:96-103`）
- Artifact 名：`sync-report-aliyuncs`（`:146`），`path: reports/`，`retention-days: 30`

#### `sync-images-batch.yml`

- 参数组装：`.github/workflows/sync-images-batch.yml:133-160`
  ```
  args=(--file "$LOCKFILE" --dest "$DEST_REGISTRY" --report-dir ./reports)
  + 条件追加：--concurrency / --skip-existing / --verify / --dry-run /
              --filter / --exclude /
              --notify-webhook + --history-artifact sync-report-batch /
              --notify-after-failures（仅当 != "1"）
  ```
- 调用：`.github/workflows/sync-images-batch.yml:162`（**没有** `echo 执行：...` 那行）
- Artifact 名：`sync-report-batch`（`:168`）
- 跑前校验清单存在与非空：`:116-131`

#### `sync-images-harbor.yml`

- 参数组装：`.github/workflows/sync-images-harbor.yml:101` `args=(--src "$IMAGES_SRC" --dest-exact "$dest" --report-dir ./reports)`
- 调用：`:125`；日志：`:124`
- **唯一使用 `--dest-exact` 的同步工作流**（目标地址在工作流里就拼好，注释 `:98`）

#### `check-registry.yml`（唯一的检查工作流）

- 参数按 `inputs.mode` 三分支组装：`.github/workflows/check-registry.yml:129-147`
  | mode | args |
  |---|---|
  | `audit` | `--file "$LOCKFILE" --dest "$DEST_REGISTRY" --audit` |
  | `updates` | `--file "$LOCKFILE" --check-updates`（`--updates-limit` 仅当 != "5"） |
  | `lock` | `--audit-lock "$LOCK_FILE"` |
- `--filter` / `--exclude` 追加在 `:151-158`，**lock 模式刻意跳过**（传了会被脚本告警）
- `--report-dir ./reports`：`:162`（无条件）
- 通知：`:164-168`（`--notify-webhook` + `--notify-on "$NOTIFY_ON"`）
- 调用：`:173`；注释 `:170-172` 说明「退出码 2 就是要让步骤失败」
- Artifact 名：`check-report`（`:179`）

**各工作流的目标地址默认值（重跑复现的关键）**——均形如：
```yaml
DEST_REGISTRY: ${{ inputs.dest_registry || vars.ALIYUNCS_REGISTRY || 'registry.cn-shenzhen.aliyuncs.com/nicholyx' }}
```
见 `.github/workflows/sync-images-batch.yml:72`、`.github/workflows/check-registry.yml:68`（aliyuncs / harbor 走各自的 env，见 `sync-images-aliyuncs.yml` 的 env 段与 `sync-images-harbor.yml:71`）。

### 12. 调用方式与参数一致性（已确认）

- **全部是本地 CLI**：四个工作流都直接 `./scripts/sync.sh "${args[@]}"`，**不存在 Actions 专用入口**（无 `action.yml`、无 `sync.sh` 内的 `GITHUB_ACTIONS` 分支）。
- 参数**完全一致**：工作流只是把 `inputs` / `secrets` 经 `env` 中转后再拼成 bash 数组（注释 `sync-images-aliyuncs.yml:108` 说明这是为了避免表达式注入）。CLI 能用的参数与工作流能传的是同一套。
- 工作流的两类「省略」会造成复现歧义：
  1. **默认值省略**：`--notify-after-failures` 为 `1` 时不传（`sync-images-aliyuncs.yml:134`、`sync-images-batch.yml:158`）、`--updates-limit` 为 `5` 时不传（`check-registry.yml:135`）。
  2. **凭证只走 env**：`SYNC_SRC_USERNAME` / `SYNC_SRC_PASSWORD` / `SYNC_SRC_CREDENTIALS`（`sync-images-batch.yml:106-111`、`check-registry.yml:75-77`），**永远不出现在 argv**，因此报告/日志里也不会有。
- `sync.sh` 在 `main()` 里把 env 作为命令行参数的兜底（`scripts/sync.sh:3270-3293`），命令行优先。
- 唯一「注入式」差异在测试里：`ci.yml` 用 `GITHUB_STEP_SUMMARY="$summary" ./scripts/sync.sh ...` 把 Summary 导向临时文件做断言（`.github/workflows/ci.yml:146`、`:202`）——这证明 Summary 由脚本写、且可被外部重定向。

## Caveats / Not Found

- 工作流的 `echo "执行：./scripts/sync.sh ${args[*]}"`（aliyuncs `:138`、harbor `:124`）是**日志里唯一接近「可复制命令」的东西**，但它：① 只在两个工作流里有；② 因凭证走 env，复制出来也跑不通私有源；③ 不含 `--report-dir` 之外的环境信息（`DEST_REGISTRY` 已是展开后的值，这一点反而有用）。
- batch 工作流不打印调用（`sync-images-batch.yml:162`），**推测**是有意为之但未在注释中说明。
- `vars.ALIYUNCS_REGISTRY` 是仓库级变量，本地不可见——复现工作流的确切目标地址需要另外知道这个变量的值。**未查到**仓库变量当前取值（不在代码库内）。
