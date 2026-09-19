# 实施计划：重跑指引

## 0. 开工前的 GitHub 侧配套（维护闭环要求）

- [ ] 建里程碑 `v1.15.0`（主题：失败后的可操作化）
- [ ] 建 Issue：重跑指引（背景 → 期望/验收标准 → 入手位置 → 难度），挂 `v1.15.0`，打 `enhancement`
- [ ] Issue 入 Projects 看板（`gh project item-add 1 --owner @me --url <issue-url>`）
- [ ] 另建两个 Issue 记录本任务**不做**但已发现的缺口（诚实留档，不夹带）：
  - 同步报告缺失失败原因（`note` 只在终端打印，三种检查模式都有）
  - `write_report` 的 json 是裸 `printf` 拼接，镜像名含 `"` / `\` 会产出非法 JSON
- [ ] 更新 Roadmap（Issue #4）：新条目进「计划中」

## 1. 代码（全部在 `scripts/sync.sh`）

按依赖顺序，每步可独立验证：

- [ ] **1.1 `ere_escape()`** —— ERE 元字符转义，覆盖 `\ ^ $ . [ ] | ( ) * + ? { }`。
      先用独立脚本验证，再落进 `sync.sh`。
- [ ] **1.2 `rerun_style()`** —— 读 `GITHUB_WORKFLOW_REF` 判形态（`sync-images-batch.yml` → `filter`，其余 → `list`）。
- [ ] **1.3 `collect_rerun_items()`** —— 唯一聚合点。遍历 `R_*`，产出全局变量
      `RERUN_IMAGES` / `RERUN_FILTER` / `RERUN_NOT_RERUNNABLE`。
      注意：**多值传出用全局变量，不用命令替换**。
- [ ] **1.4 `render_rerun_section()`** —— 渲染 markdown 片段到 stdout；无失败项或 dry-run 时输出空。
      片段串里用 `validate_regex` 自检拼出的正则，不过则降级为只给清单。
- [ ] **1.5 接入 `emit_summary()`** —— Step Summary 的「合计」之后插入该片段。
      ⚠️ 位置：在「最慢的同步记录」之前（行动项优先于性能排行）。
- [ ] **1.6 接入 `write_report()` 的 md** —— 复用同一片段函数，**不复制渲染逻辑**。
- [ ] **1.7 接入 `write_report()` 的 json** —— 在 `"exclude"` 之后、`"images"` 之前插入 `"rerun"` 字段；
      `filter` 值里的 `\` 转义为 `\\`。

## 2. 验证

- [ ] `./scripts/lint.sh` 全绿（actionlint + yamllint + shellcheck + bash -n）
- [ ] **单测断言**（按项目惯例，CI 步骤内联提取生产函数执行）：
  - `ere_escape 'nginx:1.27'` → `nginx:1\.27`
  - 锚定正则**不匹配** `nginx:1.27-alpine`，**匹配** `nginx:1.27` 与 `docker://nginx:1.27`
  - 含 `+` / `{}` / `|` 的 tag 转义后仍能正确匹配
- [ ] **渲染断言**（四种输入）：有失败 → 出现；全绿 → 不出现；有不可重跑项 → 计数行出现；dry-run → 不出现
- [ ] **Summary 集成断言**：`GITHUB_STEP_SUMMARY="$tmp" ./scripts/sync.sh ...` 后断言片段（照 `.github/workflows/ci.yml:146`、`:202` 的既有手法）
  - ⚠️ 断言匹配**带图标的正文行或具体数值**，不要匹配状态词本身（本项目在这条上真实翻过车）
- [ ] 新断言**先在本地复现**（含 `bash -e` 语义）再提交
- [ ] 全仓 U+FFFD 扫描

## 3. 文档

- [ ] `docs/USAGE.md` —— 新增一节讲重跑指引（含「为什么 Batch 给的是正则」）
- [ ] `docs/ARCHITECTURE.md` —— 「关键设计决策」补一条：为什么重跑指引用锚定正则而不是给 Batch 加输入
- [ ] `README.md` —— 特性列表补一条
- [ ] `CHANGELOG.md` —— `[Unreleased]` 的 `### 新增` 下加条目
      ⚠️ **插入前断言锚点行号 > `[Unreleased]` 行号且 < 下一个 `## [` 行号**（v1.8.0 时条目连续插进已发布段落，靠 diff tag 才发现）

## 4. 风险文件与回滚点

- **风险文件**：`scripts/sync.sh` 是全项目唯一逻辑实现（约 3000 行）。动手前必读 `.trellis/spec/engine/` 全部文件。
- **回滚点**：单文件改动、无状态迁移 → 任一步出问题 `git checkout scripts/sync.sh` 即恢复。
- 提交拆成两个：① 代码 + CI 断言 ② 文档。便于单独回滚文档。

## 5. `task.py start` 前的检查清单

- [ ] `prd.md` / `design.md` / `implement.md` 三件齐全且已过 PRD 收敛
- [ ] `implement.jsonl` / `check.jsonl` 各至少一条真实的 spec / research 条目（不能是空的或 `_example` 占位）
- [ ] 用户已就最终规划总结**明确批准**（初次请求与建任务时的同意都不算）
- [ ] GitHub Issue 已建、里程碑已挂、看板已同步
