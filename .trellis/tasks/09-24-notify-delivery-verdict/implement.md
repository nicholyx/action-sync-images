# implement：通知送达判定

## 执行清单

### 第 1 步：新增 `notify_delivery_verdict`（`scripts/sync.sh`）

放在 `notify_send_text` 之前（它要被后者调用）。要点：

- [ ] `VERDICT` 走 stdout（单行单词），详情走全局 `NOTIFY_VERDICT_DETAIL`——
      bash 3.2 没有 `declare -A`，多值传出用**全局变量**是仓库既有模式
- [ ] 函数**自包含**：只依赖 `jq` 与传入的 body 文件，不引用运行级全局变量
      （CI 会把它整段抽到独立上下文里跑）
- [ ] 非 2xx 分支要**在最前面**判：这时候不该去解析 body
- [ ] JSON 用 `jq -r '.errcode // empty'`，**必须接住 jq 的退出码**——
      `jq` 解析失败退出 5，让它冒到顶就把一个不在脚本退出码体系里的数字暴露给用户
- [ ] body 截断：detail 里带上响应体时取首行并限长（如 200 字符）
- [ ] 变量后紧跟中文时一律加花括号 `"${v}中文"`（bash 3.2 会把全角首字节并进变量名）

### 第 2 步：改 `notify_send_text`

- [ ] `-o /dev/null` → `-o "$body_file"`（`mktemp` 建、显式 `rm -f` 收尾）
- [ ] `case "$verdict"` 四分支（见 design.md §3.2），文案照抄
- [ ] **仍然 `return 0`**——末尾不要写 `return $?`
- [ ] 保持不打印 webhook URL

### 第 3 步：抽取式单测（`ci.yml` 的 smoke-test job）

- [ ] 照既有「提取函数 + mock」的手法（`sed -n "/^${fn}()/,/^}/p"`）抽出
      `notify_delivery_verdict`
- [ ] 喂 design.md §4 矩阵的行（原计划 14 行，检查阶段补到 16 行——见该矩阵），逐行断结论与 detail
- [ ] **每行都要positive 断言**：断「结论等于 X」而不是「结论不等于 Y」
      （负向判据几乎总是恒真）
- [ ] 至少一条**正对照**：`errcode:0` 必须判 `confirmed`——
      没有它，一个「永远返回 rejected」的实现也能全绿

### 第 4 步：端到端断言（同一个 job，照 `hook-note.py` 的手法）

- [ ] 起一个本地 HTTP server，用**没被占用的端口**（该 job 已用 8898）
- [ ] 用例 (a)：200 + `{"errcode":0,"errmsg":"ok"}` + `--notify-type dingtalk`
      → stderr 含「平台已确认送达」
- [ ] 用例 (b)：200 + `{"errcode":310000,"errmsg":"keywords not in content"}`
      + `--notify-type dingtalk` → stderr 含「拒收」且含 `errcode=310000`，
      **并且**不含「平台已确认送达」（成对出现才有牙）
- [ ] 用例 (c)：200 + 非 JSON（如 `<html>`)→ stderr 含「无法判定」
- [ ] 一个一个 server 分开起、`trap` 收尾；每个用例之间不要复用同一个端口上的
      响应内容——**改 server 行为就重启 server**
- [ ] 复现顺序：**先证明改前是绿的/错的**（用例 b 在改前会看到「结果已推送到」），
      再改，再看红→绿

### 第 5 步：回归

- [ ] 既有「验证失败原因真的随通知发得出去」（generic）仍绿
- [ ] `./scripts/lint.sh` 全绿（**这一步不能跳**——上一个任务就是忘了跑它，
      让 SC2016 漏进了 PR）
- [ ] `bash -n scripts/sync.sh`
- [ ] 在 **bash 5**（CI 的解释器）与**本地 bash 3.2**（macOS）两边都过一遍

## 验证命令

```bash
bash -n scripts/sync.sh
./scripts/lint.sh
# 抽取式单测：本地跑
bash /tmp/verify-notify-verdict.sh
# 端到端：本地起 server（脚本见 ci.yml 新步骤），断言 grep 文案
```

## 回滚点

- 第 1、2 步各是一个原子改动，任一失败可 `cp` 备份还原——
  **不要用 `git checkout <文件>`**（会丢掉同文件的其他未提交改动）

## 复核门

- [ ] design.md §4 矩阵各行的结论与 detail 全部有断言（实际 26 条 check）
- [ ] 端到端 (a)(b)(c) 三例都有「先见旧行为、后见新行为」的证据
- [ ] `rejected` 两副面孔（非 2xx / 2xx+平台报错）文案不同
- [ ] generic 200 空体仍 `accepted`（PRD 边界）