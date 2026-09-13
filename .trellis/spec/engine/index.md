# 同步引擎（scripts/sync.sh）

全项目唯一的逻辑实现，约 3000 行 bash。**改它之前必读本目录全部文件。**

## Pre-Development Checklist

1. [bash 硬规则](bash-rules.md) —— 兼容 macOS bash 3.2 的全部禁忌，**每条都真实踩过**
2. [模式矩阵](modes.md) —— 同步 / 审计 / 上游检查 / 锁文件校验四种模式的语义、退出码、互斥关系
3. 设计取舍的「为什么」在 `docs/ARCHITECTURE.md` 的「关键设计决策」一节——改设计前先确认不是把记录过的决定改回去

## 本层的既有模式（动手前先对号入座）

- **所有模式的命令实现都走同一套封装**：`skopeo_inspect_raw` / `skopeo_list_tags` / `compute_digest`。新检查不要绕开它们自己拼 skopeo 命令——凭证装载（`--src-authfile`）与 TLS 开关都在封装里，绕开就是静默失效的种子
- **并发**：子进程 + 带序号的结果文件（`result_file_for` / `audit_result_file_for` / `lock_result_file_for`），槽位控制用 `jobs -pr` 计数（不用 `wait -n`，bash 3.2 没有）
- **多值传出**：用全局变量（`OCI_STAGING_DIR` / `DEST_REFS` / `REF_REPO` 等），**不用命令替换**——那是子 shell，赋值传不回父进程
- **新参数**：解析在 `parse_args`，显式指定但不生效的必须进对应模式的「不生效」告警列表（默认值不生效不打扰）

## Quality Check

- [ ] `./scripts/lint.sh` 全绿
- [ ] 新增行为在本地用 mock skopeo 验证过（本仓库没有 skopeo 时，用 PATH 前置的 mock 二进制）
- [ ] **真实路径**的行为进了 CI 集成测试（`.github/workflows/ci.yml` 的「真实同步集成测试」job，用本地 `registry:2`）——dry-run 覆盖不到真实推送，v1.1.0 的三个缺陷全部发生在那里
- [ ] 每条 CI 断言先在本地复现（包括 CI 脚本的提取执行）
- [ ] 全仓 U+FFFD 扫描：

```bash
python3 -c "
import pathlib
bad=[str(p) for p in pathlib.Path('.').rglob('*') if p.is_file() and '.git' not in p.parts
     and chr(0xfffd) in p.read_text(encoding='utf-8', errors='ignore')]
print(bad if bad else 'OK')
"
```
