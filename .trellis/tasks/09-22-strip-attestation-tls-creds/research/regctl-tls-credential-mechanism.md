# regctl 的 TLS 与凭证机制：原始实验记录

日期：2026-09-22 · regctl v0.11.6（darwin-arm64，与 `scripts/sync.sh` 的
`REGCTL_VERSION` 一致）· 用途：Issue #120 / 本任务 `design.md` §2 的原始依据

## 环境准备

```bash
arch="$(uname -m)"   # arm64
curl -fsSL "https://github.com/regclient/regclient/releases/download/v0.11.6/regctl-darwin-${arch}" \
  -o /tmp/regctl-bin
chmod +x /tmp/regctl-bin
/tmp/regctl-bin version   # VCSTag: v0.11.6
```

把 `HOME` 指向空目录，确保读不到任何真实配置：

```bash
export HOME=/tmp/fakehome-noregctl
```

## 探针 1：HTTP registry（验证 TLS 切换）

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        rec = {"path": self.path, "auth": self.headers.get("Authorization")}
        with open("/tmp/regctl-probe.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(200); self.send_header("Content-Type","application/json")
        body = b'{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 5199), H).serve_forever()
```

### A. 不传 `--host` —— 复现了 #120

```
$ regctl manifest get 127.0.0.1:5199/library/alpine:latest
failed to get manifest 127.0.0.1:5199/library/alpine:latest: Get
"https://127.0.0.1:5199/v2/library/alpine/manifests/latest":
http: server gave HTTP response to HTTPS client
Try updating your registry with "regctl registry set --tls disabled <registry>"
```

### B. 传 `--host reg=...,tls=disabled` —— 切到明文 HTTP

```
$ regctl --host 'reg=127.0.0.1:5199,tls=disabled' manifest get 127.0.0.1:5199/library/alpine:latest
unsupported media type: "application/json"
```

报错内容变成了探针返回体的媒体类型问题，**说明请求已经走通**。探针记录：

```json
{"path": "/v2/library/alpine/manifests/latest", "auth": null}
```

（后两条来自 C；B 与 C 各产生一条，`auth` 均为 `null`——原因见下）

### C. 再加 `user`/`pass`，探针仍报 `auth: null`

**这不是凭证失效**：探针返回 200，客户端没有机会进入
「401 → 用凭证换 token/重试」的流程。用探针 2 才能验证，见下。

## 探针 2：401 + Basic（验证凭证）

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
    def handle_one(self):
        rec = {"path": self.path, "auth": self.headers.get("Authorization")}
        with open("/tmp/regctl-probe2.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="test"')
        self.send_header("Content-Length", "0"); self.end_headers()
    do_GET = handle_one
    do_HEAD = handle_one
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 5198), H).serve_forever()
```

### D. 无凭证

```
$ regctl --host 'reg=127.0.0.1:5198,tls=disabled' manifest get 127.0.0.1:5198/library/alpine:latest
failed to get manifest ...: no credentials available: unauthorized
```

这正是 Issue #120 里 `--strip-attestation` + 私有源会撞上的错误文本。

### E. `--host` 带 `user`/`pass` —— 凭证生效

```
$ regctl --host 'reg=127.0.0.1:5198,tls=disabled,user=alice,pass=s3cret' manifest get ...
failed to get manifest ...: unauthorized
```

探针记录：

```json
{"path": "/v2/library/alpine/manifests/latest", "auth": null}
{"path": "/v2/library/alpine/manifests/latest", "auth": "Basic YWxpY2U6czNjcmV0"}
```

`YWxpY2U6czNjcmV0` 解码即 `alice:s3cret`。**凭证确实发出**，
但本设计不采用（密码进命令行，见 `design.md` §4）。

### F. `DOCKER_CONFIG` 指向含凭证的临时目录

```bash
mkdir -p /tmp/dockercfg
cat > /tmp/dockercfg/config.json <<'JSON'
{"auths":{"127.0.0.1:5198":{"auth":"YWxpY2U6czNjcmV0"}}}
JSON

DOCKER_CONFIG=/tmp/dockercfg regctl --host 'reg=127.0.0.1:5198,tls=disabled' \
  manifest get 127.0.0.1:5198/library/alpine:latest
```

输出里出现（顺带证明了 TLS 覆盖有可见告警）：

```
level=WARN msg="Changing TLS settings for registry" orig=enabled new=disabled host=127.0.0.1:5198
failed to get manifest ...: unauthorized
```

探针记录：

```json
{"path": "/v2/library/alpine/manifests/latest", "auth": null}
{"path": "/v2/library/alpine/manifests/latest", "auth": "Basic YWxpY2U6czNjcmV0"}
```

**`DOCKER_CONFIG` 被尊重。**

## 配置文件语义（`REGCTL_CONFIG`）

由 `registry set` 生成的权威格式：

```
$ regctl registry set --tls disabled a.example
$ cat ~/.regctl/config.json
{
  "hosts": {
    "a.example": {
      "tls": "disabled",
      "hostname": "a.example",
      "reqConcurrent": 3
    }
  }
}
```

### G. `REGCTL_CONFIG` 是**替代**而非合并

```
$ echo '{"hosts":{"b.example":{"hostname":"b.example","tls":"insecure"}}}' > /tmp/other-config.json
$ regctl registry config
{"hosts":{"a.example":{"tls":"disabled","hostname":"a.example","reqConcurrent":3}}}

$ REGCTL_CONFIG=/tmp/other-config.json regctl registry config
{"hosts":{"b.example":{"tls":"insecure","hostname":"b.example"}}}
```

`a.example` 整个消失——**设置 `REGCTL_CONFIG` 会让使用者的全局配置全部失效**。
这是 `design.md` §4 否掉该方案的依据。

`regctl registry --help` 的原文：

> By default, the configuration is loaded from `$HOME/.regctl/config.json`.
> This location can be overridden with the `REGCTL_CONFIG` environment variable.
> Note that these commands do not include logins imported from Docker or values
> injected with `--host`.

最后一句两点信息：`--host` 注入的值**不进配置文件**（叠加而非写入）；
regctl **会**从 Docker 导入登录。

### H. `REGCTL_CONFIG` 与 `DOCKER_CONFIG` 可并存

```bash
cat > /tmp/rc-tls-only.json <<'JSON'
{"hosts":{"127.0.0.1:5198":{"hostname":"127.0.0.1:5198","tls":"disabled"}}}
JSON

REGCTL_CONFIG=/tmp/rc-tls-only.json DOCKER_CONFIG=/tmp/dockercfg \
  regctl manifest get 127.0.0.1:5198/library/alpine:latest
```

探针仍记录到 `"auth": "Basic YWxpY2U6czNjcmV0"`——Docker 凭证通道未被
`REGCTL_CONFIG` 切断。（此结论本设计未直接使用，但它说明两条通道互相独立，
是 §3.1 选择 `--host` 的旁证。）

## `tls` 的取值集合

`regctl registry set` 的选项说明：

```
--tls string    TLS (enabled, insecure, disabled)
```

只有三个值，是**单值**——这正是 `--tls-verify false` 无法被完整映射的原因
（`disabled` 覆盖明文 HTTP，`insecure` 覆盖自签 HTTPS，二者不可兼得）。
详见 `design.md` §3.1 的取舍。

## 复现本记录

按上文的探针脚本起服务，按 A–H 的顺序执行即可。注意 macOS 无 `timeout` 命令；
`regctl` 在连接失败时自行快速返回。所有实验都在 `HOME` 指向空目录的前提下进行。
