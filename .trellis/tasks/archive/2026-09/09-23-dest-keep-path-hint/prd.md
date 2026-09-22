# fix: 缺目标参数的指路文案漏了 --dest-keep-path

对应 Issue：nicholyx/action-sync-images#129

## Goal

`--dest-keep-path` 是与 `--dest` 并列的第三种目标模式，但**缺目标参数时**的报错文案只提了另外两种：

```bash
$ ./scripts/sync.sh --src nginx:1.27
[错误] 缺少必填参数：--dest 或 --dest-exact
```

**同一份文件里另外两条同类文案都是对的**（`3790` 与 `3865` 都写了 `--dest / --dest-keep-path`），
只有这一处漏了。`docs/ARCHITECTURE.md:133` 的流程图照抄了这条错文案。

## Requirements

### R1 文案补全且与既有写法一致

补成 `--dest` / `--dest-keep-path` / `--dest-exact` 三者的并列，措辞对齐同文件 3790 那条的既有风格
（那里写的是「`--dest` / `--dest-keep-path`」）。

### R2 文档同步

`docs/ARCHITECTURE.md` 里照抄该文案的地方一并修正。

### R3 加断言钉住它

这条文案目前**没有任何测试覆盖**——所以它才能长期少一项而不被发现。
加一条断言，让「三种模式都要被提到」这件事可被机械检查。

断言要能抓住「漏一个」，而不是只检查「文案非空」那种恒真形式。

## Acceptance Criteria

- [ ] **AC1** `./scripts/sync.sh --src nginx:1.27` 的报错里同时出现 `--dest`、`--dest-keep-path`、`--dest-exact`
- [ ] **AC2** 断言在 CI 里，且**做变异验证**：从文案里删掉 `--dest-keep-path` 后断言会红
- [ ] **AC3** `docs/ARCHITECTURE.md` 中照抄该文案处已同步（全仓 `grep` 不再有「--dest 或 --dest-exact」这种两选一写法）
- [ ] **AC4** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿
- [ ] **AC5** 相关既有断言仍全绿（尤其 `--dest-exact` 的互斥告警，它的文案是正确的那批）

## Constraints

- 只改文案与文档，**不改校验逻辑**（三种模式本来就都被接受，缺的是「说出来」）
- 兼容 bash 3.2

## Out of Scope

- `docs/ARCHITECTURE.md:279`「项目提供两种模式」那句（命名模型章节把 `--dest-keep-path` 整个漏了）
  ——那是**同一族的另一处**，但涉及重写一小节，与本任务的「一行文案」不同量级。见下方 Notes

## Notes

- 本任务是「用户最需要指路的那一刻给错方向」的修复：目标是要**保留路径**的 Harbor 类仓库、
  又忘了带前缀参数的人，会被引向 `--dest`（压平，正是他不想要的）或 `--dest-exact`（只接受单个源镜像）
- 命名模型章节的遗漏（`ARCHITECTURE.md:279`）已在同一次调研中发现，量级不同，留给单独的任务处理