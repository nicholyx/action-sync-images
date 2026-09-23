# design：通知送达判定

## 1. Scope / Trigger

跨层契约变更：通知路径对外部平台的**回执解释**从「HTTP 码」改成「按平台解析响应体」。
外部契约（各平台回执格式）与内部契约（判定结论 → 日志级别）都要写清楚，故用完整模板。

## 2. Signatures

```bash
# 新增：把「HTTP 码 + 响应体」翻译成判定结论
#   $1 type       平台类型（dingtalk / feishu / slack / generic）
#   $2 http_code  curl -w '%{http_code}' 的输出（连接失败时是 000）
#   $3 body_file  响应体落盘文件（可能为空文件）
# 输出（stdout，单行单词）：
#   confirmed | accepted | rejected | undetermined
# 副作用：把人类可读的详情写入全局 NOTIFY_VERDICT_DETAIL（可能为空串）
notify_delivery_verdict() { ... }

# 变更：notify_send_text 内部
#   改前  curl -o /dev/null -w '%{http_code}'
#   改后  curl -o "$body_file" -w '%{http_code}'   # 响应体落盘后交给上面的判定
# 对外契约不变：永远返回 0
notify_send_text() { ... }
```

## 3. Contracts

### 3.1 各平台的响应体契约（外部，逐个确认过）

| type | 成功 | 失败信号 | 形态 |
|---|---|---|---|
| `dingtalk` | `{"errcode":0,"errmsg":"ok"}` | `errcode != 0`（310000 通用：sign not match / keywords not in content / ip 不在白名单；300001 token 不存在） | JSON |
| `feishu` | `{"code":0,"msg":"success","data":{}}` | `code != 0`（如 11232 限流） | JSON |
| `slack` | HTTP 200 + 纯文本 `ok` | 纯文本错误码：`invalid_payload` / `no_text` / `no_service` / `no_channel` / `action_prohibited` / `channel_is_archived` | **纯文本，不是 JSON** |
| `generic` | 无统一契约 | 无法判定 | 任意（常见 200 空体） |

Slack 的失败信号是**一枚短 token**，不是「任何非 ok 的文本」：200 但不是 token 形态的响应体
（典型是透明代理返回的 HTML 错误页）归 `undetermined`——把它报成「平台拒收」会把排查方向
带偏到机器人配置上。判据是形态（无空白、无 `<`、长度 ≤ 64），不是一张码表：Slack 新增
错误码时照样落在 `rejected`。

飞书的 `StatusCode` / `StatusMessage` 是官方标注的**冗余字段（兼容存量历史逻辑，不建议使用）**
——只在 `code` 缺失时作为回退读取，不作为首选。

### 3.2 判定结论 → 日志（内部契约）

| 结论 | 触发 | 日志 |
|---|---|---|
| `confirmed` | 平台已确认接收 | `log_info`：`结果已推送到 <type>（平台已确认送达）` |
| `accepted` | `generic` 且 HTTP 2xx（该类型无统一回执） | `log_info`：`结果已推送到 <type>（该类型无统一回执，送达状态无法判定）` |
| `rejected` | 非 2xx，或 2xx 但平台明确报错 | `log_warn` + `gh_warning`：带出原因 |
| `undetermined` | 2xx 但响应体不是该平台的预期结构 | `log_warn` + `gh_warning`：明说「无法判定」 |

**`rejected` 的文案分两副面孔**（同一结论、不同事实）：

- 非 2xx → `通知发送失败（HTTP <code>）…`
- 2xx + 平台报错 → `通知被 <type> 拒收（HTTP 200，errcode=… errmsg=…）…`

因为「代理返回 502」与「平台明确拒收」是两件事，合并成一句话会误导排查方向。

### 3.3 不变的部分

- 日志**绝不输出 webhook URL**（URL 视同凭证）
- `notify_send_text` 永远 `return 0`；通知失败只告警，不改变同步退出码
- 「发不发」的门禁（`--notify-on` / `--notify-after-failures`）一行不改

## 4. Validation & Error Matrix

| http_code | body | type | 结论 | detail |
|---|---|---|---|---|
| 000 | （空） | 任意 | `rejected` | `HTTP 000`（连接失败/超时） |
| 500 | 任意 | 任意 | `rejected` | `HTTP 500`（+ 响应体首行，截断） |
| 200 | `{"errcode":0,...}` | dingtalk | `confirmed` | — |
| 200 | `{"errcode":310000,"errmsg":"keywords not in content"}` | dingtalk | `rejected` | `errcode=310000 errmsg=keywords not in content` |
| 200 | `{"code":0,...}` | feishu | `confirmed` | — |
| 200 | `{"StatusCode":0,"StatusMessage":"success"}` | feishu | `confirmed` | 回退字段 |
| 200 | `{"code":11232,"msg":"rate limit"}` | feishu | `rejected` | `code=11232 msg=rate limit` |
| 200 | `<html>…</html>`（非 JSON） | dingtalk/feishu | `undetermined` | `响应体不是 JSON` |
| 200 | `{"foo":"bar"}`（无 errcode/code 字段） | dingtalk/feishu | `undetermined` | `响应体里没有 errcode 字段` |
| 200 | `ok` | slack | `confirmed` | — |
| 200 | `invalid_payload` | slack | `rejected` | `invalid_payload` |
| 200 | （空） | slack | `undetermined` | `响应体为空` |
| 200 | `<html>…</html>`（不是回执 token） | slack | `undetermined` | `响应体不是 Slack 的预期回执（<html>…</html>）` |
| 200 | `null`（合法 JSON，不是对象） | dingtalk | `undetermined` | `响应体里没有 errcode 字段`（判「能不能解析」用 `jq .`，不能用 `jq -e .`——后者在 `null`/`false` 上返回非零） |
| 200 | （空） | generic | `accepted` | `该类型无统一回执`（**必须继续算成功**） |
| 200 | 任意 | generic | `accepted` | 同上——不猜 generic 的成败 |

## 5. Good / Base / Bad Cases

- **Good**：自建 webhook 返回 200 空体 → `accepted`，`log_info`，运行仍绿（边界要求）
- **Base**：钉钉正常接收 → `{\"errcode\":0}` → `confirmed`
- **Bad（这就是本 issue）**：钉钉因「关键词不匹配」拒收 → 200 + `errcode:310000` →
  改前：`结果已推送到 dingtalk`（假的成功）；改后：`通知被 dingtalk 拒收（HTTP 200，
  errcode=310000 errmsg=keywords not in content）` + 一条 `::warning::`

## 6. Tests Required

| 落点 | 断言点 |
|---|---|
| 抽取式单测（不需要网络） | 把 `notify_delivery_verdict` 整段抽出来，喂上面矩阵的 16 行，逐行断结论与 detail |
| 端到端（本地 HTTP server，照 `hook-note.py` 的手法） | (a) 200 + `errcode:0` → stderr 有「平台已确认送达」；(b) 200 + `errcode:310000` → stderr 有「拒收」且带 `errcode=310000`，**且没有**成功行（正对照 + 负对照成对，单写负向判据是恒真的）。(c) 200 + 非 JSON → 「无法判定」；(d) generic + 200 空体 → 仍算成功；(e) 502 + 响应体 → 「通知发送失败」；(f) 502 + 空体 → **文案与改前一字不差**（既有检索不失效） |
| 契约回归（AC5） | 抽出 `notify_send_text` 后**裸调用**（不写成 `cmd \|\| fail`——那会让 errexit 对函数内部失效，只看得到「返回值是 0」一个形态），在「平台拒收」「连不上」「`mktemp` 建不出临时文件」三种形态下都必须既不中断也不返回非零 |
| 回归 | 既有「验证失败原因真的随通知发得出去」用 generic，必须仍绿 |

**端口**：新起 server 用 ci.yml 里没被占用的端口（该 job 已有 8896–8899，新步骤用 8895；「连不上」那一支用 8894），且 `trap` 收尾。

## 7. Wrong vs Correct

### Wrong

```bash
local http_code
http_code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST ... -d "$payload" "$NOTIFY_WEBHOOK" 2>/dev/null)" || true
if [[ "$http_code" =~ ^2 ]]; then
  log_info "结果已推送到 ${type}"      # ← 对任何 HTTP 200 都成立，包括「对方明确拒绝了」
fi
```

### Correct

```bash
local body_file http_code
# 临时文件：建不出就退成 /dev/null（旧实现本来就用它）。**不能**让 mktemp 的失败
# 冒出去——set -e 会穿透函数，一次成功的同步会因为通知这个附属动作变红，
# 而「通知是附加能力」是既有契约。退成 /dev/null 后通知照发，判定只会看到空
# 响应体、如实报「无法判定」，不伪造成功。
if ! body_file="$(mktemp 2>/dev/null)"; then
  body_file="/dev/null"
fi
http_code="$(curl -sS -o "$body_file" -w '%{http_code}' -X POST ... -d "$payload" "$NOTIFY_WEBHOOK" 2>/dev/null)" || true
http_code="${http_code:-000}"

# 结论与详情由判定函数写进**全局变量**，调用方随后读它。
# 不要写成 verdict="$(notify_delivery_verdict ...)"：命令替换是子 shell，
# 函数对全局变量的赋值传不回父进程（bash-rules.md 记过这个坑）。函数仍把结论
# 打到 stdout，是为了能被整段抽出来独立验证——抽出来的单测读 stdout。
NOTIFY_VERDICT=""
NOTIFY_VERDICT_DETAIL=""
notify_delivery_verdict "$type" "$http_code" "$body_file" >/dev/null
# 临时文件由本函数自己建、自己删（bash 3.2 没有 `trap ... RETURN`）。
# /dev/null 不是本函数建的，别去 rm 它（那是设备节点）。
if [[ "$body_file" != "/dev/null" ]]; then
  rm -f "$body_file"
fi

case "$NOTIFY_VERDICT" in
  confirmed)    log_info "结果已推送到 ${type}（平台已确认送达）" ;;
  accepted)     log_info "结果已推送到 ${type}（该类型无统一回执，送达状态无法判定）" ;;
  rejected)
    # 非 2xx 与「2xx + 平台报错」是两件事，文案分开（见 §3.2）
    if [[ "$http_code" =~ ^2 ]]; then
      log_warn "通知被 ${type} 拒收（HTTP ${http_code}${NOTIFY_VERDICT_DETAIL:+，}${NOTIFY_VERDICT_DETAIL}），结果不受影响"
      gh_warning "结果通知被 ${type} 拒收：${NOTIFY_VERDICT_DETAIL}"
    else
      log_warn "通知发送失败（${NOTIFY_VERDICT_DETAIL}），结果不受影响"
      gh_warning "结果通知发送失败：${NOTIFY_VERDICT_DETAIL}"
    fi ;;
  undetermined|*) log_warn "通知发送结果无法判定（HTTP ${http_code}${NOTIFY_VERDICT_DETAIL:+，}${NOTIFY_VERDICT_DETAIL}），结果不受影响"
                  gh_warning "结果通知发送结果无法判定：${NOTIFY_VERDICT_DETAIL}" ;;
esac
```

**注意**：上面就是 `scripts/sync.sh` 的实际形态（本节的示例与实现一致，改动实现时
一并改这里）。要点三处——临时文件显式 `rm -f`（bash 3.2 没有 `trap ... RETURN`）、
结论走全局变量而非命令替换、非 2xx 的文案由 `NOTIFY_VERDICT_DETAIL` 拼出
（空体时与改前逐字相同：`通知发送失败（HTTP 502），结果不受影响`）。

## 8. 禁止的实现方式

- ❌ 一个通用的「响应体里找 code 字段」抽象——字段名、成功值、形态三者各平台都不同
- ❌ 解析失败时 `return 0`/默认成功——那正是本 issue，只是换了个地方
- ❌ 为 generic 猜成败（自建 webhook 没有可依据的契约）
- ❌ 让通知判定影响 `sync.sh` 的退出码（既有契约：通知是附加能力）
- ❌ 把响应体整段打进日志（可能很大、也可能含平台侧内容）——截断到首行/限长