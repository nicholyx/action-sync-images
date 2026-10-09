# 执行清单

## 改动点（按依赖序）

1. `scripts/sync.sh` · `check_updates_all()`
   - [x] 汇总判定加 `upd_empty`：三计数全 0 才打「均已覆盖」；汇总句追加「N 个上游返回空 tag 列表」档
   - [x] Step Summary（2913-2923）与报告 md（2925-2934）的汇总句同步
   - [x] json summary 补 `"empty": ${upd_empty}`（2932）
   - [x] 通知 summary 句与 attention 计数加 `upd_empty`（2936-2939）
   - [x] 退出码判定加 `|| upd_empty -gt 0`（2943）
   - [x] 改写 2757-2759、2817-2819 两处旧拍板注释（新口径：进退出码 2、不并 failed 计数、档位单列）
2. `.trellis/spec/engine/modes.md`
   - [x] 语义矩阵 check-updates 列退出码 2 描述补「上游空 tag 列表」；退出码小节（406 附近）同步
3. `.github/workflows/ci.yml` · smoke-test
   - [x] 新增独立步骤「验证空 tag 列表的汇总与退出码口径」：专用 stub（bin-mixed）按 ref 分流
     `*empty*` → 空 Tags / `*fail*` → 连不上 / 其余 → v1 v2 v3——不动主 stub（与 ⑦⑨ 各自建 stub 的惯例一致，
     主 stub「什么仓库都答 7 个 tag」的约定被其它用例依赖）；场景 C 回归钉住真覆盖仍是 0 +「均已覆盖」
   - [x] 新场景 A：单一空 tag 仓库 + 其余覆盖 → 断言退出码 2、汇总行含「1 个上游返回空 tag 列表」、无「均已覆盖」句
   - [x] 新场景 B：空 tag + 查询失败混合 → 两档分列计数不合并
   - [x] 回归：既有 check-updates 断言不动且保持绿（全覆盖场景若有，钉住退出码 0）
4. 文档
   - [x] `docs/USAGE.md` --check-updates 退出码口径
   - [x] `CHANGELOG.md`：行为变化（空 tag 场景 0 → 2），放 Unreleased 或新版本段
   - [x] README 参数速查核对（无退出码表述，无需改）

## 断言写法约束（踩过的坑）

- `|| { 诊断; fail; }` 是哑弹：诊断命令失败会吞掉 fail——用 `|| fail "..."`，诊断放 fail 前的独立语句
- `$var` 不紧贴全角字符（bash 3.2 unbound variable 假红）
- 断言匹配带数值的行（如「1 个上游返回空 tag 列表」），不匹配纯措辞——措辞在别的路径也会出现，只匹配措辞等于恒真

## 验证命令

```bash
./scripts/lint.sh                    # 提交前全绿
# CI 断言本地复现：直接抽 smoke-test 的步骤脚本跑（注意 zsh vs bash，先 echo $BASH_VERSION）
```

## 收尾

- PR 标题：`fix: 「上游返回空 tag 列表」不再冒充「均已覆盖」，退出码如实返回 2`（lint.sh 不验，自己把关）
- PR 合并后：#172 评论两处落点并关闭；Roadmap #4 已完成区补条目
