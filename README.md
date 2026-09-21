# dsh-baota-mcp-bridge

把**宝塔（BT）MCP 服务**接入 [DSH (DeepSeek Harness)](https://github.com/deepseek-ai) ——
用一个零依赖的本地 stdio 桥，把 TLS 决策收进子进程，**DSH 进程与系统信任库都不需要信任宝塔证书**。

已验证：`FastMCP 1.28.1`，**39 个工具**（网站/SSL、数据库与 SQL、Docker、防火墙、
系统与服务、各语言项目、SSH 与安全巡检、计划任务）。

## 为什么需要这个桥

宝塔服务端是自签证书，且 **证书 SAN 通常不含你实际使用的内网地址**：

| 事实 | 后果 |
|---|---|
| 证书 SAN 只有公网 IP（如 `<PUBLIC_IP>`），而可达地址是内网 IP（如 `<INTERNAL_IP>`） | 官方 MCP client 直连必然 `hostname/IP mismatch` |
| **Node 禁止把 IP 当 SNI** | `servername: '<PUBLIC_IP>'` 这种绕过法直接抛 `ERR_INVALID_ARG_VALUE` |
| `dsh-mcp-client` 没有 TLS 配置入口 | 无法在配置里指定 `ca` / `checkServerIdentity` |
| 唯一现成开关是 `NODE_TLS_REJECT_UNAUTHORIZED=0` | **进程级** —— 会让整个 DSH（含 LLM API 请求）失去证书校验 |

桥把 TLS 决策隔离在一个小进程里，于是「只对这一个 MCP 放宽」成为可能。

## 架构

```
DSH 宿主进程
  └─ @deepseek-ai/dsh-mcp-client（DSH 本体自带，无需安装）
       └─ stdio（JSON-RPC）
            └─ src/baota-mcp-bridge.mjs      ← TLS 决策在这里，仅此进程
                 └─ streamable-http (HTTPS)
                      └─ 宝塔 MCP 服务
```

工具以 `mcp__baota__<工具名>` 出现在模型工具集中。

## 安装

```bash
git clone <this-repo> ~/dsh-baota-mcp-bridge
cd ~/dsh-baota-mcp-bridge

# 1) 把服务方下发的 mcp_info.json 放到桥能读到的位置
export BAOTA_MCP_INFO=/path/to/mcp_info.json

# 2) 自检（dry-run，不写任何文件）
./scripts/install.sh

# 3) 确认无误后写入 profile patch
./scripts/install.sh --apply
```

`install.sh` 会自检 node、DSH 自带的 MCP SDK、凭证文件，并**真实连接一次**确认能取到工具列表，
然后才写入配置（写入前自动备份）。web 面板会热重载 `cordis.patch.yml`，**无需重启 DSH**。

回退：

```bash
./scripts/install.sh --revert
```

## 手动配置（等价）

在 `$DSH_HOME/profiles/<profile>/cordis.patch.yml` 末尾追加：

```yaml
- insert:
    - id: mcp-client
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: baota
        transport: stdio
        command: /absolute/path/to/node
        args:
          - /absolute/path/to/dsh-baota-mcp-bridge/src/baota-mcp-bridge.mjs
        env:
          BAOTA_DSH_MODULES: /absolute/path/to/dsh/node_modules
          BAOTA_TLS_INSECURE: '1'
          BAOTA_MCP_INFO: /absolute/path/to/mcp_info.json
        toolCallTimeoutMs: 120000
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `BAOTA_MCP_URL` | 读 `mcp_info.json` 的 `local_host` | 目标端点 |
| `BAOTA_MCP_TOKEN` | 读 `mcp_info.json` 的 `api_token` | Bearer 令牌；**建议留空走文件，避免 `ps` 泄漏** |
| `BAOTA_MCP_INFO` | `<repo>/../baota-mcp-package/skill/references/mcp_info.json` | 凭证文件路径 |
| `BAOTA_MCP_CA` | `<repo>/src/baota_root_ca.crt` | CA 证书（仅 `INSECURE=0` 时用）。**不随仓库分发**，由 `install.sh` 从你的 `mcp_info.json` 现场提取 |
| `BAOTA_TLS_INSECURE` | `1` | `1`=跳过全部校验；`0`=校验证书链、仅放宽主机名 |
| `BAOTA_DSH_MODULES` | 自动探测 | DSH 的 `node_modules`，用于解析其自带的 MCP SDK |
| `BAOTA_BRIDGE_LOG` | 关 | `1` 打开 stderr 日志 |

**关于 `BAOTA_TLS_INSECURE`**：默认 `1`（完全跳过校验）。这**不等于**降低整个系统的安全性 ——
放宽范围仅限这个桥进程连的那一个内网端点，DSH 自身与你所有其他 HTTPS 流量不受影响。
若你想要更强的保证，设 `0`：桥会校验宝塔证书链，只放宽主机名一项。

## 手动调试桥

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
 | BAOTA_TLS_INSECURE=1 BAOTA_BRIDGE_LOG=1 node src/baota-mcp-bridge.mjs
```

## 给 AI Agent 用的接入提示词

见 [`AGENT-PROMPT.md`](AGENT-PROMPT.md) —— 把那段整段发给新机器上的 DSH，它就能自己装好
（含全部踩坑结论，不用重复试错）。

## 安全

- `mcp_info.json` **含明文令牌**，已在 `.gitignore` 中排除，**切勿提交**。
- 令牌只从文件读取，**不进命令行参数**（`ps` 不可见）、**不写进 `cordis.patch.yml`**。
- 桥不从网络下载任何东西，除 DSH 自带的 `@modelcontextprotocol/sdk` 外**零依赖**。
- 仓库**不分发 CA 证书** —— 私发证书公开分发没有任何好处；改由 `install.sh` 从你本地的
  `mcp_info.json` 现场提取（`src/baota_root_ca.crt`，已在 `.gitignore` 中）。

## License

BSD-3-Clause
