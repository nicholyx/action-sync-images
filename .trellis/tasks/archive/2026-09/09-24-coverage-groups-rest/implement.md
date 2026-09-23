# implement：#137 的其余覆盖组

## 顺序（由简到繁，每组独立可验证，各是一次「红→绿」的完整循环）

### 第 1 步：D 组 —— 三条失效参数告警（最简单，先做）

- [ ] `--platforms`（**skopeo 路径**）：`--platforms linux/amd64` **不带** `--strip-attestation`
      → 断告警文案含 `--platforms` 与「本次将忽略」
- [ ] 同一处配**负面**断言：带 `--strip-attestation` 时**不出现**该告警
- [ ] `--skip-existing`（**regctl 路径**）：带 `--strip-attestation --skip-existing` → 断告警
- [ ] `--tls-verify false`（**regctl 路径**）：带 `--strip-attestation --tls-verify false`
      → 断文案含 cacert 的指引
- [ ] 落点：既有「验证只读模式的不生效参数告警」或「验证 regctl 路径的平台列表解析」附近；
      **逐条确认该步骤当前的调用参数**，别把两条方向相反的门禁塞进同一个调用
- [ ] 先跑一次**改前**的现状（这些告警已存在，所以是「确认断言能表达它」，不是「红→绿」）——
      改为用**变异**证明断言有牙：删掉对应 `log_warn` 看是否变红

### 第 2 步：A 组 —— `--updates-limit`（stub skopeo）

- [ ] 写 stub `skopeo`：`list-tags` 时吐 `{"Name":"<repo>","Tags":[...]}`（7 个 tag），
      其他子命令按需返回；`chmod +x`，`PATH` 前置
- [ ] 清单里只写其中 1 个 tag → 缺失 6 个
- [ ] `--updates-limit 3`：断**总数** `共 6 个` **且** 恰好列出 3 个
- [ ] 正对照：不传 limit（默认 5）→ 总数仍是 6、列出 5 个
- [ ] 变异验证：把 `missing` 事先 `head -n "$limit"` → 断言必须红

### 第 3 步：B + C 组 —— 三种检查的报告落盘与 summary

- [ ] 扩既有「验证检查模式的报告落盘」，覆盖三种模式的 6 个文件
- [ ] 断 `check` 字段等于模式名（`check-updates` / `lock-audit`，不是 `audit`）
- [ ] 断 json 顶层形状与 `.summary` 的**具体数值**（不是「存在」）
- [ ] 变异：把 `check_name` 写成固定值 `audit` → 断言必须红

### 第 4 步：F 组 —— feishu / slack 的端到端

- [ ] 照 #159 的端到端手法（本地 HTTP server + `--notify-type <平台>`）
- [ ] feishu：假 webhook 回 `{"code":0,"msg":"success"}` → 断「平台已确认送达」；
      并断**请求体**的包装是 `msg_type` 形态
- [ ] slack：假 webhook 回 `invalid_payload` → 断「拒收」；请求体是 `{"text":…}`
- [ ] 端口用新的、未被占用的（该 job 已占 8894–8899，注意别撞）
- [ ] 变异：把 payload 的 `msg_type` 改成 `msgtype`（dingtalk 的形态）→ 断言必须红

### 第 5 步：E 组 —— 同步模式 `--notify-on failure` 的门禁（integration-test）

- [ ] (a) 真实全绿 + `--notify-on failure` → 断**无** payload（用假 webhook 计数：
      没收到 POST 就是没发）
- [ ] (b) 同步失败 + `--notify-on failure` → 断**有** payload；**不能加 `--dry-run`**
- [ ] 变异：把 `send_notification` 里的 `-eq 0` 改成 `-ne 0`（或把两处判据互换）
      → 两条断言必须红
- [ ] 同时确认检查模式那条（`attention`）仍绿——两处判据不同，别互相覆盖

## 验证命令

```bash
bash -n scripts/sync.sh
./scripts/lint.sh                     # 每步之后都跑
# 抽出的步骤本地跑；集成测试需要容器与 5000 端口（本机 5000 被 AirPlay 占 → 用容器 shim）
python3 /tmp/extract_step.py "<步骤名>" > /tmp/step.sh && bash /tmp/step.sh
```

## 回滚点

每个组是一次独立的 `ci.yml` 插入，失败即用 `cp` 备份还原 ——
**不要用 `git checkout <文件>`**（会丢同文件其他未提交改动）。

## 复核门

- [ ] 每组都有「变异 → 红」的证据，且变异**精确到单点**
- [ ] 所有断言是**正向**（断等于 X），不是「不等于 Y」
- [ ] 成对的断言（有/无 payload、正面/负面告警）必须**同时**存在
- [ ] 每条断言都能回答：「哪个单点变异会让它红？」
- [ ] `./scripts/lint.sh` 8 · 0 · 0