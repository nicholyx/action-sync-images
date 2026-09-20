# 设计：让 dry-run 不再留下没做过的事的痕迹

## 边界

| 文件 | 改动 |
| --- | --- |
| `scripts/sync.sh` | `process_one()` 两处守卫（耗时、目标 digest）；`emit_summary()` 一处统一告警 + 两处守卫（锁文件、通知） |
| `.github/workflows/ci.yml` | 新增断言；改一条既有断言（它拿 dry-run 当夹具测通知） |
| `CHANGELOG.md` | `[Unreleased]` → `### 变更`（这是行为变更，不是纯修复） |

不动 `write_lockfile()` / `send_notification()` 内部——它们在非 dry-run 下的行为完全不变，守卫只加在调用点。

## 统一判据

一句话贯穿四个落点：

> **dry-run 没有真的搬过任何东西，所以任何描述「搬了什么、花了多久、搬完了」的输出都必须是空或零。**

这不是「dry-run 要不要更保守」的取舍，而是判据换位：原来测的是「这段代码跑了多久 / 这个函数有没有被调用」，应该测的是「**有没有真的搬过**」。

## 复现手段：把竞态变成确定性

耗时那条**平时跑不出来**（打印一行只要微秒，只有在负载高的 runner 上才会跨过 1 秒边界）——这正是它表现为「偶发 flaky」的原因。**只靠重跑撞运气验证不了它。**

用 mock `date` 强制跨秒，把它变成确定性复现：

```bash
mkdir -p /tmp/mockdate
cat > /tmp/mockdate/date <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  n=$(cat /tmp/mockdate/counter 2>/dev/null || echo 100)
  n=$((n + 1)); echo "$n" > /tmp/mockdate/counter; printf '%s\n' "$n"
else
  exec /bin/date "$@"
fi
EOF
chmod +x /tmp/mockdate/date
rm -f /tmp/mockdate/counter
PATH="/tmp/mockdate:$PATH" ./scripts/sync.sh \
  --src 'nginx:1.27,redis:7.2,alpine:3.20' --dest r.example.com/x \
  --dry-run --report-dir /tmp/dryrep3
```

实测（2026-09-20）：三个镜像的 `seconds` 全为 `1`，md 里出现「最慢的同步记录」排行——**一次什么都没搬的 dry-run 报出了耗时排行**。三个镜像是必要的：`duration_ranking_rows` 要求 `${#rows[@]} -ge 3` 才输出。

**这个 mock 是断言的基础**：没有它，「dry-run 的 seconds 恒为 0」在 CI 上几乎总是绿的（因为打印够快），断言就成了摆设。

## 落点一与四：`process_one()` 内的两处守卫

耗时（在 `endif` 之后、`pull_elapsed` 累加之前）：

```bash
    end="$(date +%s)"
    elapsed=$((end - start))
    # dry-run 没有真的搬过任何东西，耗时如实为 0。判据是「有没有真的搬过」，
    # 不是「这段代码跑了多久」——干跑只打印一行命令，但在负载高的 runner 上
    # 仍可能跨过 1 秒边界。那个 1s 会进报告、进耗时排行，并让「耗时全为 0 时
    # 排行应隐去」的断言偶发误报（2026-09-19 在 #103 的 PR 上带崩过整个
    # smoke-test job，重跑即绿）。
    if [[ "$DRY_RUN" == "true" ]]; then
      elapsed=0
    fi
```

`pull_elapsed` 不必单独处理：它的来源 `prepare_oci_staging` 已被 `"$DRY_RUN" != "true"` 挡住，dry-run 下恒为 0。

目标 digest：

```bash
    if [[ "$status" == "success" ]]; then
      src_digest="$(compute_digest "$src" || true)"
      # dry-run 不查目标 digest：那个 tag 上若已有镜像（上一次真实同步留下的），
      # 查到的会是它，写进报告的「目标 Digest」列会被读成本次同步的产物。
      # source_digest 不受影响——它是源镜像自身的属性，与本次是否推送无关。
      if [[ "$DRY_RUN" != "true" ]]; then
        dest_digest="$(compute_digest "$dest" || true)"
      fi
```

## 落点二与三：`emit_summary()` 里一处告警 + 两处守卫

两个落点在同一个函数里相邻（锁文件在前、通知在后）。合并成**一条告警**，与 `--audit-lock` 的既有风格一致（一次列出全部不生效的参数）：

```bash
  # dry-run 没有实际同步任何镜像，锁文件与通知都失去了对象：锁文件记录的是
  # 「这次推上去的是哪一份」，通知通报的是「这次搬得怎么样」。两者的告警
  # 合并成一条、一次列全——与 --audit-lock 的处理方式一致。
  if [[ "$DRY_RUN" == "true" ]]; then
    local -a dry_noop=()
    if [[ -n "$WRITE_LOCK" ]]; then dry_noop+=("--write-lock"); fi
    if [[ -n "$NOTIFY_WEBHOOK" ]]; then dry_noop+=("--notify-webhook"); fi
    if [[ ${#dry_noop[@]} -gt 0 ]]; then
      log_warn "--dry-run 没有实际同步任何镜像，以下参数本次不生效：${dry_noop[*]}（要生成锁文件或发送通知，请去掉 --dry-run）"
    fi
  fi

  # ---- 锁文件 ----
  if [[ -n "$WRITE_LOCK" && "$DRY_RUN" != "true" ]]; then
    write_lockfile "$WRITE_LOCK"
  fi

  # ---- 结果通知 ----
  if [[ "$DRY_RUN" != "true" ]]; then
    send_notification "$total" "$ok" "$skipped" "$fail" "$excluded"
  fi
```

**只在参数真被传入时告警**（`-n "$WRITE_LOCK"` / `-n "$NOTIFY_WEBHOOK"`）——「默认值不生效不打扰，显式传入必须说」，与参数校验层的既有口径一致。

**不加 `local` 之外的提前 return**：`emit_summary` 末尾还有返回值语义，守卫只包裹两个调用。

## 测试影响：一条既有断言必须改

CI 里 #102 阶段加的通知断言**拿 dry-run 当夹具**（无 registry 也能造出失败记录）：

```bash
./scripts/sync.sh --src 'nginx' --dest registry.example.com/smoke \
  --dry-run --notify-webhook http://127.0.0.1:8898/hook --notify-type generic
```

它断言的是「失败详情带出原因」，**不是**「dry-run 应该发通知」——dry-run 在这里只是「不联网就能失败」的手段。本任务让 dry-run 不发通知后，这条必须去掉 `--dry-run`。

**替代方案已验证可行**（2026-09-20）：

```bash
# smoke-test job 已装 skopeo；非法引用在 validate_ref 阶段直接失败，不联网
PATH=<mock skopeo> ./scripts/sync.sh --src 'https://bad.example.com/x:1' \
  --dest r.example.com/x --report-dir /tmp/altrep2 \
  --notify-webhook http://127.0.0.1:8903/ --notify-type generic
# >>> 通知已发出（退出码 2 = 有失败，既有语义），正文含「### 失败详情」
```

用带协议前缀的引用（`https://…`）而不是 `nginx`：两者都会被 `validate_ref` 拒绝，但前者更明确地表达「这一条必定失败」。

## 兼容性

| 影响面 | 说明 |
| --- | --- |
| 非 dry-run 的真实同步 | **零变化**：耗时照常计时、锁文件照常写、通知照常发、目标 digest 照常查（R6） |
| dry-run 报告的 schema | 字段与类型不变，只是 `seconds` 恒 0、`dest_digest` 为空。消费方（`history.sh`）不区分 dry-run，见下 |
| `history.sh` 的聚合 | 它会读取所有报告（含 dry-run 产出的）。`seconds` 由「偶发 1」变成「恒 0」只会让 `--slowest` 更准；`dest_digest` 为空本就允许（`short_digest` 对空值输出 `—`） |
| 退出码 | 不变 |
| 既有 dry-run 断言 | 需检查有没有断言「dry-run 写了锁文件」或「dry-run 发了通知」的——已知仅通知那条（见上）；锁文件未见断言 |
| bash 3.2 | 无新语法；`local -a` + 长度判断包裹展开的写法沿用既有模式 |

## 回滚

四个守卫互相独立，可分别 revert。若只有耗时那条出问题（例如某处依赖 dry-run 的 `seconds` 非 0——目前无此依赖），可单独回退它而保留其余三条。

## 验证方式（先红后绿）

| 落点 | 红（改动前） | 绿（改动后） |
| --- | --- | --- |
| 耗时 | mock `date` 下 `seconds=1`，md 出排行（已实测） | `seconds` 恒 0，md 无排行 |
| 锁文件 | `--dry-run --write-lock` 产出文件（已实测） | 不产出，且有告警 |
| 通知 | `--dry-run --notify-webhook` 真的发出请求（已实测） | 零请求（本地假 webhook 收不到），且有告警 |
| 目标 digest | **已实测**：mock skopeo 下 dry-run 报告写入了 `dest=sha256:e83c8747…`，而目标是空的——真实环境下这个值来自上一次同步留在该 tag 上的镜像 | `dest_digest` 为空，`source_digest` 不变 |

**非 dry-run 回归**：同一组输入去掉 `--dry-run` 跑一次，四者行为与改动前逐字一致。

CI 断言放在 `smoke-test` job（dry-run 部分不需要 registry；通知那条改用非法引用，也不需要）。
