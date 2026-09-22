<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

---

## 项目特定说明（本仓库维护者补充，不在 Trellis 受管块内）

- **文档语言**：本仓库文档以中文为主（README / docs/ / spec / journal 均如此），英文版 README 只是入口
- **动 `scripts/sync.sh` 前必读**：`.trellis/spec/engine/`（bash 3.2 硬规则 + 四种模式语义矩阵）；
  改工作流前必读 `.trellis/spec/workflows/`（供应链基线与红线）
- **GitHub 侧闭环**（Issue / PR / 里程碑 / 发布）的流程规范在 `.trellis/spec/maintenance/index.md`，
  Roadmap 的单一事实来源是 Issue #4
- **本地检查**：`./scripts/lint.sh` 一键跑完 CI 的静态检查
  （actionlint / yamllint / shellcheck / bash -n / zizmor），任何提交前先跑。
  它**不验提交信息规范**——CI 校的是 PR 标题，本地无从验证
