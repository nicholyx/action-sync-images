# 跨文件常量断言的 awk 按步骤边界复位

对应 Issue：nicholyx/action-sync-images#141

## Goal

`ci.yml` 里那条「`history.sh` 的常量 ↔ `check-registry.yml` 的字面量」断言，
从工作流一侧取 artifact 名用的是这个 awk：

```awk
/uses: actions\/upload-artifact/ { want = 1; next }
want && /^[[:space:]]*name:/ {
  s = $0; sub(/^[[:space:]]*name:[[:space:]]*/, "", s); print s; want = 0
}
```

**`want` 不按步骤边界复位**：一旦某个上传步骤**省略了 `name:`**，旗标会一直悬着，
直到撞上后面**任意一行** `name:`——可能是完全无关的步骤里的属性行。

## 已实测的后果（含最坏情形）

| 构造 | 旧 awk | 新 awk |
| --- | --- | --- |
| upload 步骤无 `name:`，后面某步骤有 `name: 误抓的` | ❌ 误抓 `误抓的` | ✅ 不抓 |
| 同上，但那行**恰好是 `check-registry` 的真实值** | ❌ 误抓 → **与真值相同 → 静默通过** | ✅ 不抓 |

第二行是**最坏情形**：断言不但失效，还恰好「通过」了——**恒真的断言比没有断言更糟**。

## 今天的可达性

**不可达**：`check-registry.yml` 目前只有一个 `upload-artifact` 且带 `name:`。
所以这是潜在问题，不是现行缺陷（检查阶段标为 P4 并如实报告，没有顺手修）。
本任务就是把它修掉，因为**修法已明确且成本极低**。

## Requirements

### R1 按步骤边界复位

在每个 YAML 列表项开始时把 `want` 清零：

```awk
/^[[:space:]]*-[[:space:]]/ { want = 0 }
```

**顺序**：这条要放在 `uses:` 那条**之前**——`- uses: actions/upload-artifact@…` 这种写法
既匹配列表项、也匹配 `uses:`，先清零再置位才是对的。

### R2 不得改变现有结果

在真实的 `check-registry.yml` 上，新旧 awk 必须**输出相同**（实测都是 `check-report`）。
这条要用差分证明，不能只看「跑通了」。

### R3 加断言防回归

现在这条 awk 的逻辑**没有独立断言**——它只在「恰好取对」时被间接验证。
要加一条能抓住「误抓」的断言，构造上面表格里的**第一种情形**（属性行不是真值，便于断言）。

**注意**：断言要能区分「抓对了」与「抓到别的东西」，不能只断「输出非空」。

## Acceptance Criteria

- [ ] **AC1** `want` 在列表项边界复位；`- uses:` 的写法仍能正确置位（实测确认）
- [ ] **AC2** 真实 `check-registry.yml` 上新旧 awk 输出**逐字节相同**（差分实测）
- [ ] **AC3** 断言覆盖「误抓」情形；**变异验证**：把复位那行去掉后断言必须变红
- [ ] **AC4** 断言能区分「抓到真值」与「抓到别的」——**不是**只断非空
- [ ] **AC5** `bash -n`、`shellcheck`、`./scripts/lint.sh` 全绿；CI 两个 job 全绿

## Constraints

- 只改这一个 awk 与它的断言，不碰同一处的其它逻辑（`check_mode_const`、顶层 `name` 的取法）
- 兼容 bash 3.2（awk 用的是 POSIX 语法）
- 不新增步骤

## Out of Scope

- 同批发现的另两条（`expect` 只钉前缀、mock 注释理由）——有意不改，已登记在 #141 的正文里

## Notes

- 判据是「**断言取到的值，确实是它声称取的那个字段**」——这与「恒真断言」同族：
  取到别的东西而不自知，比取不到更危险