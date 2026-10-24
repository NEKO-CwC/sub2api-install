# sub2api-install

Sub2API 的「接入工具」引导站，以及它分发的两个安装脚本。

线上地址：**https://install.ncuos.com**

## 这是什么

用户在自己的电脑上把 Claude Code / Codex CLI / OpenCode 接到 Sub2API 时，通常要手改配置文件、填 base URL、填 Key、确认协议类型。这个站点把这件事变成「复制一条命令，粘贴到终端」。

WorkBuddy 和 DSH（DeepSeek Harness）这类桌面客户端没有配置文件可写，页面会给手动图文步骤：在客户端里添加自定义模型 / 提供商，填接口地址、Key、模型名。

页面负责教怎么打开终端、怎么拿 Key、怎么确认成功；脚本负责真正写配置。

```
site/
  index.html      静态引导页（无后端，无构建步骤）
  install.sh      macOS / Linux 安装脚本
  install.ps1     Windows PowerShell 安装脚本
  shots/          页面里的截图（可选，缺图时显示占位）
deploy/
  nginx.conf      容器内的 nginx 配置
  workloads.yaml  Deployment + Service + HTTPRoute
  apply.sh        打包 ConfigMap 并部署
```

## 设计上的几个决定

**Key 不经过浏览器。** 页面生成的命令里没有任何密钥。脚本运行后在终端里用 `read -s` / `Read-Host -AsSecureString` 读取，Key 只存在于进程内存和最终写入的配置文件里。上传到 API 时通过 `curl --config -` 从 stdin 传 header，不会出现在 `ps` 的命令行里。

**只改目标工具自己的配置文件，不动 shell profile。** 这样不会污染用户的全局环境，也不影响其它工具。每次写入前都会留一份 `.bak.sub2api-<时间戳>` 备份，`--restore` 一键回滚。

**写入前先校验 Key。** 用 `GET /v1/models` 验证（不消耗 token），顺手拿到该 Key 可见的模型列表，自动挑一个合适的默认模型。再调 `GET /v1/sub2api/billing` 显示当前计费倍率。

**JSON 配置是深度合并，不是覆盖。** Claude Code 的 `settings.json` 和 OpenCode 的 `opencode.json` 里可能已经有用户自己的 `env`、`provider` 等字段，脚本只往里加自己的那几个键。Codex 的 TOML 则保留全部原有内容，只替换顶层 `model` / `model_provider`，并重建 `[model_providers.sub2api]` 这一段。

## 脚本用法

### macOS / Linux

```bash
curl -fsSL https://install.ncuos.com/install.sh | bash -s -- --client claude-code
```

```
--client <claude-code|codex|opencode>   要配置的客户端（必填）
--base-url <url>                        Sub2API 地址，默认 https://sub2api.ncuos.com
--api-key <key>                         直接提供 Key（会留在 shell 历史里，不推荐）
--model <name>                          指定模型（默认自动选择）
--install-cli                           顺便 npm install -g 对应 CLI
--smoke                                 配置后发一条最小请求验证端到端可用
--dry-run                               只打印改动，不写文件
--restore                               从最近一次备份恢复
```

### Windows

```powershell
& ([scriptblock]::Create((irm https://install.ncuos.com/install.ps1))) -Client claude-code
```

```
-Client <claude-code|codex|opencode>     要配置的客户端（不给会交互式询问）
-BaseUrl <url>
-ApiKey <key>
-Model <name>
-InstallCli
-Smoke
-DryRun
-Restore
```

> PowerShell 的 `irm | iex` 会把参数丢掉，所以这里用 `[scriptblock]::Create(...)` 再调用，这样后面的 `-Client` 才能生效。

## 脚本会写哪些文件

| 工具 | 文件 | 写入内容 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `env` 下的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` |
| Codex CLI | `~/.codex/config.toml` | 顶层 `model_provider = "sub2api"`、`model`，以及 `[model_providers.sub2api]`（`wire_api = "responses"`、`supports_websockets = false`、`experimental_bearer_token`） |
| OpenCode | `~/.config/opencode/opencode.json` | `provider.sub2api`（`@ai-sdk/openai-compatible`、`baseURL`、`apiKey`、`models`） |

Windows 下对应 `%USERPROFILE%\.claude\settings.json`、`%USERPROFILE%\.codex\config.toml`、`%USERPROFILE%\.config\opencode\opencode.json`。

注意 Codex 的 `base_url` 要带 `/v1`，Claude Code 的 `ANTHROPIC_BASE_URL` 不带 `/v1`，OpenCode 的 `baseURL` 带 `/v1`。这是三个客户端各自的约定，脚本已经处理好。

## 部署

```bash
./deploy/apply.sh --dry-run   # 先看会创建什么
./deploy/apply.sh             # 实际部署
```

脚本会把 `site/` 打包成 ConfigMap，连同 Deployment / Service / HTTPRoute 一起 apply，然后等待 rollout 完成并打印 HTTPRoute 状态。

部署目标是 `sub2api` namespace：

- `install-site` Deployment：单副本 nginx，只读根文件系统，非 root，drop 掉全部 capability
- `install-site` Service：ClusterIP，80 → 8080
- `install-site-public` HTTPRoute：`install.ncuos.com` → `istio-system/public` 的 `https-ncuos-wildcard` listener

证书复用网关上的 `*.ncuos.com` 通配符证书，不需要单独申请。

默认读取 `~/.kube/sub2api-rancher.json`，可以用 `KUBECONFIG_PATH` 环境变量覆盖。

## 更新站点内容

改了 `site/` 里的文件后重跑 `./deploy/apply.sh` 即可。ConfigMap 内容变化会触发 Pod 滚动更新。

## 截图

页面里有 16 个截图位，用 `data-shot` 标记：

| 文件名 | 内容 |
|---|---|
| `windows-open-terminal.png` | Win+X 菜单里「终端」的位置 |
| `mac-open-terminal.png` | 聚焦搜索里输入「终端」的画面 |
| `linux-open-terminal.png` | Linux 终端窗口的提示符 |
| `keys-create.png` | 「创建密钥」按钮 |
| `keys-create-setting.png` | 创建密钥弹窗：名字、分组 |
| `copy-key.png` | 列表里复制 Key 的图标 |
| `terminal-paste-key.png` | 脚本提示「请粘贴 Sub2API Key」的画面 |
| `workbuddy-open.png` | WorkBuddy 主界面 |
| `workbuddy-model-menu.png` | 模型菜单底部的「配置自定义模型」 |
| `workbuddy-add-model.png` | 「添加模型」窗口 |
| `workbuddy-saved.png` | 保存后的模型配置 |
| `dsh-open-settings.png` | DSH 左下角「设置」入口 |
| `dsh-model-provider.png` | 模型页「+ 添加模型提供商」 |
| `dsh-custom-api.png` | 自定义模型 API 的填写项 |
| `dsh-select-model.png` | 模型菜单里选中自定义模型 |
| `usage-verify.png` | 用量明细里的调用记录 |

把图片按上面的文件名放进 `site/shots/`，重跑 `./deploy/apply.sh` 就会同步到集群。页面加载时检查图片是否存在，存在就替换、不存在就保留占位样式，所以可以分批加。

截图不走 ConfigMap：十几张图内联进去会超过 API Server 1MiB 的单对象上限。`apply.sh` 会在 rollout 完成后把 `site/shots/*.png` 同步到 `install-site-shots` PVC 上。
