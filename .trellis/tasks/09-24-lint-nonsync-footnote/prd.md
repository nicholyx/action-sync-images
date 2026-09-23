# ci: lint.sh 把「非 CI 同源」在结尾显式列出

## Goal

zizmor 退回本机二进制时，其结论与 CI 同源结论可信度不同却计入同一类。在结尾汇总处补一条脚注列出非 CI 同源的项——不动三计数、不改结构、不新增参数

## Requirements

- TBD

## Acceptance Criteria

- [ ] TBD

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
