<div align="center">

# action-sync-images

**Borrow GitHub Actions as a free overseas relay to move unreachable container images into a registry you can pull from.**

No VPS, no server, and no dependency on someone else's mirror.

[![CI](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml/badge.svg)](https://github.com/nicholyx/action-sync-images/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nicholyx/action-sync-images)](https://github.com/nicholyx/action-sync-images/releases)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/badge?org=nicholyx&repo=action-sync-images)](https://github.com/ossf/scorecard)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![GitHub stars](https://img.shields.io/github/stars/nicholyx/action-sync-images?style=social)](https://github.com/nicholyx/action-sync-images/stargazers)

[Quick Start](#quick-start) · [How It Works](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Contributing](CONTRIBUTING.md)

[中文文档](README.md) | **English**

> 📖 **Note on language**: The full documentation (`docs/`) is written in Chinese, where most of
> this project's users are. This English README covers everything you need to get started;
> for deeper details, the Chinese docs are still worth a read (browser translation works fine).

</div>

---

## What is this

Pulling images from `registry.k8s.io`, `gcr.io`, `quay.io`, or `ghcr.io` from inside mainland China often fails at the network layer.

The three common workarounds each have their own pain: using someone else's mirror puts your versions in their hands; renting an overseas VPS as a relay costs money and needs maintenance; cloud-vendor image tools are one-shot, awkward for batch jobs, and don't fit version control.

This project takes a fourth path: **use GitHub Actions as a free, ephemeral relay**.

The runner sits overseas with direct access to all upstream registries. You click a button, and it copies images from one registry to another. You never own a server.

```text
  registry.k8s.io/coredns/coredns:v1.11.1
                  │
                  │  GitHub Actions (overseas runner)
                  │  skopeo / regctl copy
                  ▼
  registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_coredns_coredns:v1.11.1
                  │
                  ▼
            your cluster in China
```

---

## Features

- **Zero infrastructure** — no VPS, no server. Just a GitHub account
- **Multi-arch preserved** — amd64 / arm64 travel together, not just the runner's platform
- **Attestation handling** — a dedicated path for registries that reject OCI 1.1 empty blobs (`unknown manifest class`)
- **Batch sync** — multiple images per run, or a manifest file for a fixed image set
- **On-demand filtering** — pick images from the manifest with regexes instead of editing the manifest itself
- **Multi-destination** — one run pushes to several registries (e.g. Aliyun for clusters in China, Harbor for internal archive), each choosing its own naming rule (flattened or path-preserving)
- **Concurrency + incremental** — batch sync runs concurrently and skips images the destination already has. On scheduled re-runs, everything is usually skipped in seconds
- **Fail-safe batching** — one failed image doesn't abort the rest; everything is summarized at the end
- **Timeout & retries** — per-image timeouts keep one huge image from stalling the whole batch
- **Self-hosted registries** — TLS verification can be turned off for internal HTTP registries
- **Result notifications** — push sync *and* audit results to DingTalk / Lark / Slack so unattended runs aren't a blind spot
- **Auditable** — source and destination digests are recorded; lockfiles reproduce exactly what was synced
- **Status check** — `--audit` reports how far your registry has drifted from the manifest (current / stale / missing / unknown), pushing nothing
- **Release check** — `--check-updates` compares upstream tags against the manifest and reports versions you haven't pinned yet
- **Check from the web UI** — the `Check-Registry` workflow runs either check with one click, no tooling required; results land in the run's Summary and can be pushed as notifications
- **Trends** — `scripts/history.sh` aggregates past reports to answer "which image keeps failing"
- **Local reproduction** — the same logic ships as `scripts/sync.sh` with `--dry-run`
- **Configurable destination** — change namespace or region without touching code
- **Full static checks** — actionlint + yamllint + shellcheck + commit conventions via `./scripts/lint.sh`

---

## Quick Start

### 1. Configure credentials

Go to `Settings` → `Secrets and variables` → `Actions` and add your Aliyun Container Registry credentials:

| Secret | Value |
| --- | --- |
| `DOCKER_USERNAME` | Your Aliyun account |
| `DOCKER_PASSWORD` | The **registry fixed password** (not your Aliyun login password) |

> Using a self-hosted Harbor instead? Configure `HARBOR_REGISTRY` / `HARBOR_USERNAME` / `HARBOR_PASSWORD`. See the [usage guide](docs/USAGE.md) for details.

### 2. Trigger a sync

Open **Actions** → pick `Sync-Images-to-AliYuncs` → **Run workflow** → enter a source image:

```text
registry.k8s.io/pause:3.9
```

### 3. Pull and verify

```bash
docker pull registry.cn-shenzhen.aliyuncs.com/nicholyx/registry.k8s.io_pause:3.9
```

That's it — you don't write a single line of code.

---

## Three ways to sync

### ① A single image

Enter one image in `images_src`. Best for a one-off need.

### ② Multiple images at once

`images_src` accepts **newlines, commas, and semicolons** (mixable):

```text
registry.k8s.io/kube-apiserver:v1.31.0
registry.k8s.io/kube-controller-manager:v1.31.0
registry.k8s.io/kube-scheduler:v1.31.0
```

Or in one line: `nginx:1.27, redis:7.4, registry.k8s.io/pause:3.9`

Duplicates are de-duplicated; **one failed image doesn't stop the others**, and you get a summary table at the end.

### ③ Batch sync from a manifest

For maintaining a fixed image set — e.g. all components of a Kubernetes version.

Edit [`images.lock.txt`](images.lock.txt) at the repo root, then trigger the `Sync-Batch` workflow.

> 💡 Tip: the output of `kubeadm config images list --kubernetes-version=v1.31.0` can be pasted straight in.

---

## Parameter reference

### Sync-Images-to-AliYuncs (primary workflow)

| Input | Required | Default | Description |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | Source image(s). No `docker://` prefix needed |
| `strip_attestation` | | `false` | Strip attestation manifests. Check this when you see `unknown manifest class` |
| `platforms` | | auto-detect | Platforms to keep, e.g. `linux/amd64,linux/arm64`. Only applies when the previous option is checked |
| `concurrency` | | `4` | How many images to sync in parallel |
| `skip_existing` | | `true` | Skip images the destination already has |
| `dry_run` | | `false` | Print commands without pushing, to preview destination names |

### Sync-Images-to-Harbor

| Input | Required | Default | Description |
| --- | :---: | --- | --- |
| `images_src` | ✅ | — | Source image(s) |
| `images_dest` | ✅ | — | Destination path appended after `HARBOR_REGISTRY`, e.g. `library/nginx:1.27` |
| `concurrency` | | `4` | Parallel image count |
| `skip_existing` | | `true` | Skip identical existing images |
| `dry_run` | | `false` | Same as above |

### Sync-Batch

| Input | Required | Default | Description |
| --- | :---: | --- | --- |
| `lockfile` | ✅ | `images.lock.txt` | Manifest file path |
| `dest_registry` | | see below | Destination prefix. Empty falls back to the `ALIYUNCS_REGISTRY` variable, then the built-in default |
| `concurrency` | | `6` | Parallel image count |
| `skip_existing` | | `true` | Skip identical existing images |
| `dry_run` | | `false` | Same as above |
| `filter` | | empty | Only sync images matching this regex, e.g. `kube-` |
| `exclude` | | empty | Skip images matching this regex, e.g. `apiserver` |

> 📖 For every parameter in depth — edge cases, examples, scenarios — see the [usage guide](docs/USAGE.md).

---

## How destination names are derived

This confuses everyone on first use — **take a look before your first sync**.

The default "flattening" rule exists because **Aliyun Container Registry's personal edition does not support nested repository paths**:

```text
Source: registry.k8s.io/coredns/coredns:v1.11.1
        └──────┬──────┘ └──┬──┘ └──┬──┘
               └───────────┴───────┴──→ every / replaced with _
                              ▼
Dest:   <your prefix>/registry.k8s.io_coredns_coredns:v1.11.1
```

Keeping the registry domain in the name prevents collisions between same-named images from different sources — `registry.k8s.io/pause` and `docker.io/pause` land in different repositories.

Not sure what a name becomes? **Run with `dry_run` once** and read the printed commands.

Self-hosted Harbor supports nested paths and uses exact mode (no flattening):

```text
Source: nginx:1.27  →  Dest: harbor.example.com/library/nginx:1.27
```

**Want different rules per destination?** `--dest-keep-path` takes the same prefix-plus-path form as `--dest` but keeps the source path intact. Mix and match:

```bash
./scripts/sync.sh --file images.lock.txt \
  -d <aliyun-prefix> \
  --dest-keep-path harbor.example.com/mirror
```

```text
<aliyun-prefix>/registry.k8s.io_pause:3.9              ← flattened (Aliyun personal edition has no nested paths)
harbor.example.com/mirror/registry.k8s.io/pause:3.9    ← path preserved (Harbor supports it)
```

See [USAGE.md § scenario 14](docs/USAGE.md#场景十四一次推往两类仓库各用各的命名规则) (Chinese).

---

## Common scenarios

<details>
<summary><b>Syncing images with attestations (<code>unknown manifest class</code>)</b></summary>

Check `strip_attestation` and leave `platforms` empty (auto-detected):

```text
images_src:        ghcr.io/netbirdio/netbird:0.28.0
strip_attestation: ✅
```

Typical triggers are `ghcr.io/netbirdio/*` and anything built with BuildKit provenance enabled. See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the underlying mechanism.

</details>

<details>
<summary><b>Single-platform source images (<code>platform not found</code>)</b></summary>

Check `strip_attestation` and specify the platform explicitly:

```text
images_src:        some.registry/only-amd64:1.0
strip_attestation: ✅
platforms:         linux/amd64
```

List the source's platforms first:

```bash
skopeo inspect --raw docker://<source image> | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"'
```

</details>

<details>
<summary><b>Syncing only part of a manifest</b></summary>

The manifest is the complete record of desired state, but a single run often covers only part of it. Use `filter` / `exclude` instead of editing the manifest:

```text
lockfile:  images.lock.txt
filter:    kube-          # only kube-* components
exclude:   apiserver      # but skip apiserver
```

Both accept regexes (ERE) and can be combined (filter first, then exclude).

**Excluded images still appear in the result table** with the rule that excluded them — if the manifest lists 20 images but the table shows 19, you'd otherwise assume the 20th synced. Visible exclusion is the only trustworthy exclusion.

Locally:

```bash
./scripts/sync.sh --file images.lock.txt --dest <dest> \
  --filter 'kube-' --exclude 'apiserver'
```

</details>

<details>
<summary><b>Changing the Aliyun namespace / region</b></summary>

No code changes. `Settings` → `Secrets and variables` → `Actions` → **Variables**, add:

```text
ALIYUNCS_REGISTRY = registry.cn-hangzhou.aliyuncs.com/your-namespace
```

The login host is derived from the first segment, so switching regions is a one-variable change.

</details>

<details>
<summary><b>Syncing to Docker Hub</b></summary>

`sync.sh` doesn't care about the destination. Copy a workflow file, change the destination to `docker.io/<your-username>`, and configure the credentials.

> ⚠️ Docker Hub rate-limits free pulls, and public repositories are **visible to everyone**.

</details>

<details>
<summary><b>Is a certain image failing repeatedly?</b></summary>

Each run's report is a separate artifact — one report never shows trends. `scripts/history.sh` aggregates them:

```bash
# Summarize the last 20 runs
./scripts/history.sh

# History of one image
./scripts/history.sh --image registry.k8s.io/pause:3.9

# The 5 most failing images
./scripts/history.sh --top-failures 5

# The 5 slowest images on average
./scripts/history.sh --slowest 5
```

Output is Markdown, ready to paste into an issue:

```text
20 runs total, covering `2026-08-22T…` ~ `2026-09-11T…`
96 image-syncs: 88 success ｜ 5 skipped ｜ 3 failed
```

It **reuses the report artifacts you already have — no new storage** — so it never leaves a growing commit trail behind. Requires the `gh` CLI and `jq`; supports offline use via `--dir`.

</details>

<details>
<summary><b>Checking how far your registry has drifted (<code>--audit</code>)</b></summary>

The manifest is the desired state, but "is my registry actually caught up?" used to require running a real sync — and a real sync pushes. `--audit` only reads:

```bash
./scripts/sync.sh --file images.lock.txt -d <your-registry-prefix> --audit
```

```text
 ✓ current   registry.k8s.io/pause:3.9
 ✗ missing   registry.k8s.io/etcd:3.5.15-0
 ⚠ stale     registry.k8s.io/coredns/coredns:v1.11.1
 ? unknown   quay.io/coreos/flannel:v0.25.5
   source unreachable: dial tcp: lookup quay.io: no such host
```

**`unknown` is a category of its own.** "Couldn't check" and "doesn't match" are different things — showing a network hiccup as `stale` sends you chasing a problem that doesn't exist. When the *source* is unreachable the result is `unknown` too, never `missing`.

Exit code `2` means "not everything is current" (including "couldn't finish checking"), so it drops straight into a CI health check — auditing is read-only and does not violate the "syncs must be explicitly triggered" rule.

Drop `--audit` and re-run the same command to fix what it found; `--skip-existing` skips whatever is already current. Full details in [USAGE.md § scenario 12](docs/USAGE.md#场景十二审计清单与目标仓库的差距) (Chinese).

</details>

<details>
<summary><b>Is there a newer upstream release? (<code>--check-updates</code>)</b></summary>

The manifest pins a set of images (say, one Kubernetes version). When upstream ships a new release, nothing tells you. `--check-updates` pulls the upstream tag list and diffs it against the manifest:

```bash
./scripts/sync.sh --file images.lock.txt --check-updates
```

```text
registry.k8s.io/kube-apiserver
  in manifest: v1.31.0
  340 tags upstream, 12 not in the manifest; highest by version order (5):
    v1.32.3 v1.32.2 v1.32.1 v1.31.4 v1.31.3
```

**It reports, it never edits the manifest** — which version to move to is a compatibility judgement, and that call is yours. It also does **no semver reasoning and no prerelease filtering**: upstream tag naming is often irregular (`latest`, `1.27-alpine`, `v1.32.0-rc.1`), and semver comparison would return *wrong* answers. So seeing `latest` or a tag older than your manifest is normal — this is **not an upgrade recommendation**.

Only the 5 highest-by-version tags are listed by default (`--updates-limit`), but the total count is always reported. No destination needed; multiple tags from one repository are fetched once. See [USAGE.md § scenario 13](docs/USAGE.md#场景十三发现上游的新版本) (Chinese).

</details>

<details>
<summary><b>Running locally without GitHub Actions</b></summary>

```bash
brew install skopeo regclient   # macOS

# Preview
./scripts/sync.sh --src registry.k8s.io/pause:3.9 --dest registry.cn-shenzhen.aliyuncs.com/nicholyx --dry-run

# Real sync (docker login first)
./scripts/sync.sh --src registry.k8s.io/pause:3.9 --dest registry.cn-shenzhen.aliyuncs.com/nicholyx
```

`./scripts/sync.sh --help` lists every option.

</details>

---

## Project layout

```text
.
├── .github/workflows/
│   ├── sync-images-aliyuncs.yml   sync to Aliyun (primary)
│   ├── sync-images-harbor.yml     sync to self-hosted Harbor
│   ├── sync-images-batch.yml      batch sync from a manifest
│   ├── check-registry.yml         read-only registry check (audit / upstream)
│   ├── ci.yml                     CI: static checks + smoke tests
│   ├── scorecard.yml              OSSF Scorecard supply-chain scoring
│   ├── labeler.yml                auto-label PRs by changed paths
│   ├── stale.yml                  stale issue/PR management
│   ├── welcome.yml                greet first-time contributors
│   └── release.yml                automated releases
├── scripts/
│   ├── sync.sh                    ★ the sync engine (single source of logic)
│   ├── history.sh                 aggregate past reports into trends
│   ├── lint.sh                    one-shot local check entry point
│   └── check-commit-msg.sh        commit message conventions
├── docs/                          full docs, see index below
├── images.lock.txt                batch sync manifest
└── ...                            governance files (LICENSE / CONTRIBUTING / SECURITY, etc.)
```

**One design note:** all sync logic lives in `scripts/sync.sh`; workflows only log in, assemble arguments, and call the script. Local runs and CI execute the same code — no "works in CI, fails locally" drift.

---

## Documentation index

The docs below are written in Chinese.

| Doc | Contents | Audience |
| --- | --- | --- |
| [USAGE.md](docs/USAGE.md) | Full usage guide: config, parameters, scenarios, verification | everyone |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Error lookup table and step-by-step diagnosis | when things break |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works: architecture, flow, design trade-offs | code readers |
| [MAINTAINER_GUIDE.md](docs/MAINTAINER_GUIDE.md) | Maintainer handbook: routine, releases, incidents | maintainers |
| [BACKGROUND.md](docs/BACKGROUND.md) | Project origin and original tutorial archive | the curious |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute: bugs, PRs, commit conventions | contributors |
| [SECURITY.md](SECURITY.md) | Security policy and threat model | security-minded folks |
| [CHANGELOG.md](CHANGELOG.md) | Release history | everyone |

---

## Roadmap

See the [roadmap issue #4](https://github.com/nicholyx/action-sync-images/issues/4) — the single source of truth for contributors. Each item links to a dedicated issue with background, entry points, and acceptance criteria.

Recent highlights:

- ✅ v1.2: multi-destination sync, real end-to-end CI integration tests
- ✅ v1.3: private source credentials, regex filtering, sync history trends
- ✅ v1.4: per-platform integrity verification (`--verify`), duration rankings, failure-threshold alerting
- ✅ v1.5: single-pull multi-destination, per-registry credential mapping
- ✅ v1.6: manifest audit, upstream release detection, per-destination naming rules

Ideas welcome — [open an issue](https://github.com/nicholyx/action-sync-images/issues/new/choose).

---

## Contributing

Any contribution helps — bug reports, docs, code, or even just "this paragraph is confusing".

Read [CONTRIBUTING.md](CONTRIBUTING.md) first for commit conventions, code style, and the PR flow.

The easiest one: **run `./scripts/lint.sh` before pushing** — it saves you a CI round.

First-time contributors get an automatic welcome message on their PR.

---

## Acknowledgements

This project started as a derivative of [WeiyiGeek/action-sync-images](https://github.com/WeiyiGeek/action-sync-images). Thanks to the original author for the initial idea and tutorial — see [BACKGROUND.md](docs/BACKGROUND.md).

Thanks also to [skopeo](https://github.com/containers/skopeo) and [regclient](https://github.com/regclient/regclient) — at its core, this project orchestrates these two excellent tools.

---

## License

[MIT](LICENSE)

This project started as a derivative of [WeiyiGeek/action-sync-images](https://github.com/WeiyiGeek/action-sync-images) (see Acknowledgements above). That upstream repository carries **no license**, so the MIT license here covers **the original work of this repository's author**; the original tutorial content has been archived to [docs/BACKGROUND.md](docs/BACKGROUND.md) with attribution preserved. If you need to use the upstream's original content in a more explicit way, please contact the original author for permission.

<div align="center">
<sub>If this project saved you the cost of a VPS, consider giving it a ⭐</sub>
</div>
