# 给新 DSH 的接入提示词（AGENT-PROMPT）

把下面 `---` 之间的内容整段发给新机器上的 DSH 即可。

---

我要把宝塔（BT）MCP 服务接入本机 DSH，请按下面步骤执行。

**背景事实（已实测，别重新试错）**

1. 服务端 `mcp_info.json` 里有两个地址：`local_host` = `https://<INTERNAL_IP>:8765/<serverName>/mcp`，
   `public_host` = `https://<PUBLIC_IP>:8765/<serverName>/mcp`。其中 **public_host 不可达**
   （Connection refused），要走 `local_host`。
2. 服务端证书是自签的（根 CA：`CN=堡塔`），**证书 SAN 只含 `<PUBLIC_IP>` 和 `<ALT_IP>`**，
   **不含 `<INTERNAL_IP>`**。而且 **Node 禁止把 IP 当 SNI**（会抛
   `ERR_INVALID_ARG_VALUE: Setting the TLS ServerName to an IP address is not permitted`）。
   → 所以官方 `dsh-mcp-client` **直连必然 hostname mismatch**，这不是证书没装好。
3. **不要**用 `NODE_TLS_REJECT_UNAUTHORIZED=0`：它是**进程级**的，会让整个 DSH 进程
   （包括 LLM API 请求）失去证书校验，影响面远超这一个 MCP。
4. **不要**让 DSH 或系统信任库去信任宝塔证书 —— 用本地 stdio 桥把 TLS 决策收进子进程。
5. 本机若设了 HTTP 代理（如 `127.0.0.1:7897`），访问 `.local` 域名会握手失败
   （`SSL_ERROR_SYSCALL`），需要 `curl --noproxy '*'`。

**做法**

DSH 本体自带官方 MCP 客户端 `@deepseek-ai/dsh-mcp-client`（工具名映射
`mcp__<serverName>__<tool>`），不需要额外装。用一个 stdio 桥连它：

1. 把桥脚本放到本地，例如 `~/dsh-baota-mcp-bridge/src/baota-mcp-bridge.mjs`。
   桥做三件事：以 stdio 对外提供 MCP 协议；内部用自定义 fetch 连 `local_host`；
   从 `mcp_info.json` 自行读取 `api_token`（**令牌不要进命令行参数，避免 `ps` 泄漏**）。
   可用环境变量：`BAOTA_MCP_URL` / `BAOTA_MCP_TOKEN` / `BAOTA_MCP_INFO` /
   `BAOTA_TLS_INSECURE`（`1`=跳过校验，默认；`0`=校验证书链仅放宽主机名）/
   `BAOTA_DSH_MODULES`（指向 DSH 的 node_modules，用于解析它自带的 MCP SDK）/
   `BAOTA_BRIDGE_LOG=1`（日志走 stderr）。
2. 先把 `mcp_info.json` 放到桥能读到的地方（默认 `<repo>/../baota-mcp-package/skill/references/mcp_info.json`，
   建议用 `BAOTA_MCP_INFO` 显式指定）。**该文件含令牌，不要提交到 git。**
3. 在 profile 的 `cordis.patch.yml`（`$DSH_HOME/profiles/<profile>/cordis.patch.yml`）
   末尾追加一条 `insert`：
   `id: mcp-client`，`name: '@deepseek-ai/dsh-mcp-client'`，
   `config.serverName: baota`，`config.transport: stdio`，
   `config.command` 用 `node` 的**绝对路径**，
   `config.args` 用桥脚本的**绝对路径**，
   `config.env` 给 `BAOTA_DSH_MODULES` / `BAOTA_TLS_INSECURE` / `BAOTA_MCP_INFO`，
   再设 `toolCallTimeoutMs: 120000`。
   **写之前先备份**该文件。
4. **web 面板会热重载 `cordis.patch.yml`，不需要重启 DSH。**

**验证（必做，别只看配置）**

- 直接调用 `mcp__baota__SiteList`，应返回站点列表；
- 再调 `mcp__baota__SystemInfo`，应返回 CPU/内存/磁盘/负载；
- 共应有 **39 个工具**（Read/Glob/Grep/LS、SiteList/SiteGetConfig/SiteLogs/SiteTraffic/
  TrafficAnalysis/SiteCertList/WebFetch、DatabaseList/MysqlQuery、ServerIP/ServiceStatus/BashStatus、
  Container*/ComposeList/ImageList/VolumeList/NetworkList、SystemInfo/SoftwareList、
  Firewall*/Java|Node|Python|Go|Proxy|Html ProjectInfo、SSHInfo/SSHIntrusion/SecurityCheck、
  GetCrontab/GetChannel）。

**若失败**

- 工具不出现 → 看 mcp-panel（若有）的 `/mcp` 连接状态；
- `无法加载 MCP SDK` → `BAOTA_DSH_MODULES` 指错了，应指向 DSH 安装目录下的 `node_modules`；
- `缺少访问令牌` → `BAOTA_MCP_INFO` 路径不对或该 json 无 `api_token`；
- 桥崩溃 → `BAOTA_BRIDGE_LOG=1` 手动跑一次桥看 stderr，手动测试用：
  `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | BAOTA_TLS_INSECURE=1 BAOTA_BRIDGE_LOG=1 node <桥路径>`

**汇报时**：MCP url、serverName、工具数量、验证结果。**不要回显 api_token。**

---
