# 设计：让「默认目标是作者的」这件事在使用前就可见

## 边界

| 文件 | 改动 |
| --- | --- |
| `README.md` | 快速开始加一个步骤 |
| `docs/USAGE.md` | 「可选：更换目标仓库」改为必填口径 |
| `docs/TROUBLESHOOTING.md` | `denied` 的排查步骤补上这个根因 |
| `.github/workflows/sync-images-aliyuncs.yml` | 登录步骤前加一条前置提示 |
| `.github/workflows/sync-images-batch.yml` | 同上（两者共用同一个默认值） |
| `.github/workflows/check-registry.yml` | 同上，但**只在 `audit` 模式**（它的登录步骤本就 `if: inputs.mode == 'audit'`） |

**不改**默认值、不改 Harbor 工作流（它已是必填 + 明确报错，是本次要**对齐**的范本）、不改 `sync.sh`（脚本层管不到工作流的变量默认值）。

## 落点一：工作流的前置提示

### 位置

两个工作流的「登录目标仓库」步骤内、`docker login` **之前**——那里已经解析出了 `DEST_REGISTRY`，且是最早能判断的时机（早于任何网络动作）。

### 判断条件

```bash
        # 默认目标是作者示例用的命名空间。使用者 fork 后如果不设 ALIYUNCS_REGISTRY，
        # 就会往那里推——阿里云的命名空间是**账号内唯一**而非全局唯一，所以如果他
        # 恰好建了同名的能成功（推到自己账号下），否则就是 denied。两种情况下他都
        # 不知道自己在用谁的默认值，所以这里提示一句。
        #
        # 用仓库 owner 判断而不是猜字符串：作者自己的仓库不打扰。
        # 不阻断：默认值可能是使用者的合法选择（见上）。
        if [[ "$DEST_REGISTRY" == "$DEFAULT_DEST" && "$REPO_OWNER" != "nicholyx" ]]; then
          echo "::warning::目标仓库是内置的示例默认值（${DEFAULT_DEST}，项目作者的命名空间）。要同步到你自己的仓库，请在 Settings → Secrets and variables → Actions → Variables 里设置 ALIYUNCS_REGISTRY；若你确实在用这个命名空间，可忽略本条。"
        fi
```

### 两个变量走 `env:`

沿用项目在 `env:` 里落值的既有做法（`sync-images-aliyuncs.yml:60` 的注释明确写过：所有 `${{ }}` 都先经 `env:` 落到环境变量再在脚本里引用，绝不直接写进 `run:`——那等于把输入拼进 Shell）：

```yaml
      REPO_OWNER: ${{ github.repository_owner }}
      DEFAULT_DEST: 'registry.cn-shenzhen.aliyuncs.com/nicholyx'
```

`DEFAULT_DEST` 写成字面量常量而不是从 `DEST_REGISTRY` 反推：判据是「**目标是否等于内置默认值**」，与「值里恰好含 nicholyx」是两回事（后者会误伤自己设了 `registry.cn-hangzhou.aliyuncs.com/nicholyx` 的使用者）。

### 为什么不写成报错退出

阿里云的命名空间是**账号内唯一**的——使用者在自己账号下建一个同名的 `nicholyx` 命名空间，推送会成功。默认值因此**可能是合法选择**，报错会误伤。PRD 的「影响」一节记了这个判断的来由。

## 落点二：README 的快速开始

现在三步是「配置凭证 → 触发同步 → 拉取验证」。目标仓库必须夹在**第一步与第二步之间**——凭证配好了、但还没同步，正是该知道「会推到哪里」的时候：

```markdown
### 2. 设置目标仓库

默认值是 `registry.cn-shenzhen.aliyuncs.com/nicholyx`——**这是项目作者示例用的命名空间**，你要同步到自己的仓库就把它换掉：

`Settings` → `Secrets and variables` → `Actions` → **Variables** 标签页 → `New repository variable`：

| 名称 | 值示例 |
| --- | --- |
| `ALIYUNCS_REGISTRY` | `registry.cn-shenzhen.aliyuncs.com/your-namespace` |

> 不设置也能跑，但会推到作者的命名空间——除非你的阿里云账号下恰好建了同名的 `nicholyx` 命名空间，否则会 `denied` 失败。
```

（后续步骤顺延编号。）

写「不设置也能跑，但…」而不是「必须设置」：如实，且与 PRD 的影响分析一致。

## 落点三：USAGE 的口径

`:108` 的「### **可选**：更换目标仓库」改为「### 目标仓库（`ALIYUNCS_REGISTRY`）」，正文第一句点明默认值是谁的：

```markdown
默认值是 `registry.cn-shenzhen.aliyuncs.com/nicholyx`——**项目作者示例用的命名空间**。同步到你自己的仓库需要覆盖它，不必改代码：
```

把它们从「可选」挪到必读的位置，同时保留原有的「换区域只需改这一个地方」说明（那条依旧成立）。

## 落点四：TROUBLESHOOTING 的 `denied`

`:171` 的排查步骤只有三条，「目标命名空间不存在/无权限」被合并成第一条并举例 `nicholyx`。改为**把「默认值是作者的」提到最前面**——它是这条错误最常见、也最难自己想到的成因：

```markdown
1. **确认目标仓库是你的**

   工作流默认推到 `registry.cn-shenzhen.aliyuncs.com/nicholyx`——**项目作者的命名空间**。没设 `ALIYUNCS_REGISTRY` 就会往那里推：除非你的账号下恰好有同名的 `nicholyx` 命名空间，否则会被拒。设置方式见[使用文档](USAGE.md#目标仓库aliyuncs_registry)。

   如果你**确实**想用某个命名空间，确认它在你的账号下已创建（阿里云：控制台创建命名空间；Harbor：创建项目）。
```

**「（如 `nicholyx`）」这个举例要去掉**：它让人以为该去创建一个叫 `nicholyx` 的命名空间——那确实可能碰巧能用，但把根因（默认值是别人的）藏起来了。

## 兼容性

| 影响面 | 说明 |
| --- | --- |
| 同步行为与退出码 | **零变化**：新增的是 `echo "::warning::"`，不阻断 |
| 作者自己的仓库 | 提示不出现（`REPO_OWNER == nicholyx`） |
| 其他 fork | 只多一行 Actions 警告，不影响结果 |
| 既有工作流断言 | 新增的是 `env:` 两个变量与一段 `if`；`actionlint` / `yamllint` 必须过 |
| `sync.sh` | 不涉及——它接收 `--dest`，不知道也不该知道工作流的默认值是谁的 |

## 验证方式

工作流里的 shell 片段**抽出来本地跑**（沿用本项目对 CI 脚本「原文抽出执行」的既有做法），两个变量各取一组：

| `DEST_REGISTRY` | `REPO_OWNER` | 期望 |
| --- | --- | --- |
| 默认值 | `nicholyx` | 无输出（作者自己） |
| 默认值 | `someone-else` | 一条 `::warning::` |
| 自定义值 | `someone-else` | 无输出（已设置变量） |
| 含 `nicholyx` 但非默认值（如改到杭州区域） | `someone-else` | 无输出（不误伤） |

第四条是判据精确性的检查点：用 `==` 比较而非 `*nicholyx*` 匹配。

另跑：`actionlint`、`yamllint -c .yamllint .github/`、`./scripts/lint.sh`。
