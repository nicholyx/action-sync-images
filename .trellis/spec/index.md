# Spec 导航

本目录是 action-sync-images 的编码规范，供 AI 会话在动手前注入。
所有规则都来自真实代码与真实踩坑，每条都给出处。

## 这个项目是什么

一句话：**借用 GitHub Actions 当免费的海外中转机，把拉不动的容器镜像搬回国内仓库。**

- 全部同步逻辑在 `scripts/sync.sh`（约 3000 行 bash），工作流只负责登录与组装参数
- 三种只读检查：`--audit`（目标 vs 清单）、`--check-updates`（上游 vs 清单）、`--audit-lock`（锁文件时效）
- 文档以**中文**为主（`README.md` / `docs/`），英文版 README 是入口不是全文

## 按任务类型选择要读的 spec

| 你要动什么 | 先读 |
| --- | --- |
| `scripts/sync.sh`（任何改动） | [engine/index.md](engine/index.md) —— **必读**，含 bash 硬规则 |
| `.github/workflows/**` | [workflows/index.md](workflows/index.md) —— 供应链基线与红线 |
| 发版 / PR / CHANGELOG / Issue | [maintenance/index.md](maintenance/index.md) |
| 设计新功能（判断「该不该做」） | [guides/index.md](guides/index.md) —— 设计原则 |

## Pre-Development Checklist（任何任务动手前）

1. 读上表对应的 spec 入口
2. `./scripts/lint.sh` 必须先跑一遍确认基线是绿的
3. GitHub 侧上下文（issue、里程碑、看板）见 [maintenance/index.md](maintenance/index.md)

## Quality Check（任何任务收尾前）

- [ ] `./scripts/lint.sh` 全绿（actionlint + yamllint + shellcheck + bash -n）
- [ ] 改了行为 → `docs/`（USAGE / TROUBLESHOOTING / ARCHITECTURE）与两个 README 同步更新
- [ ] 用户可感知的改动 → 记入 `CHANGELOG.md` 的 `[Unreleased]`（分类固定，见 maintenance）
- [ ] 全仓无 U+FFFD 乱码（扫描命令见 engine/index.md 的 Quality Check）
- [ ] CI 全绿才合并；合并方式与红线见 maintenance/index.md
