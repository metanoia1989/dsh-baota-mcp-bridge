#!/usr/bin/env node
/**
 * 宝塔 MCP stdio ⇄ streamable-http 桥（官方 SDK 版）
 *
 * 为什么需要它：宝塔服证书 SAN 只有 <PUBLIC_IP> / <ALT_IP>，
 * 而可达地址是 <INTERNAL_IP>；Node 又禁止把 IP 当 SNI。官方 MCP client 直连
 * 必然 hostname mismatch，而它没有 TLS 配置入口 —— 唯一的开关
 * NODE_TLS_REJECT_UNAUTHORIZED=0 是进程级的，会连带废掉整个 DSH 进程的证书校验。
 *
 * 于是把 TLS 决策收进这个子进程：它自己实现 fetch，TLS 参数只在这里生效。
 * DSH 进程、系统信任库都不需要信任宝塔证书。
 *
 *   BAOTA_TLS_INSECURE=1（默认）—— 完全跳过证书校验，仅本进程生效
 *   BAOTA_TLS_INSECURE=0         —— 校验证书链（CA 用宝塔根证书），仅放宽主机名
 *
 * 其他环境变量：
 *   BAOTA_MCP_URL    目标 url（缺省读 mcp_info.json 的 local_host）
 *   BAOTA_MCP_TOKEN  Bearer 令牌（缺省读 mcp_info.json；不走命令行，避免 ps 泄漏）
 *   BAOTA_MCP_CA     CA 证书路径（校验模式用）
 *   BAOTA_MCP_INFO   mcp_info.json 路径
 *   BAOTA_DSH_MODULES DSH node_modules 路径（用于解析 MCP SDK）
 *   BAOTA_BRIDGE_LOG '1' 打开 stderr 日志
 *
 * 协议流：stdin/stdout 走 JSON-RPC，日志一律走 stderr。
 */

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import https from 'node:https';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEBUG = process.env.BAOTA_BRIDGE_LOG === '1';
const log = (...a) => { if (DEBUG) console.error('[baota-bridge]', ...a); };
const fail = (msg) => { console.error('[baota-bridge] FATAL:', msg); process.exit(1); };

// ── 解析 DSH 自带的 MCP SDK（不新增依赖） ─────────────────────────────
const DSH_MODULES = process.env.BAOTA_DSH_MODULES
  || '/path/to/dsh/node_modules';
const sdk = (sub) => pathToFileURL(join(DSH_MODULES, '@modelcontextprotocol/sdk/dist/esm', sub)).href;

let Client, StdioServerTransport, StreamableHTTPClientTransport, types;
try {
  ({ Client } = await import(sdk('client/index.js')));
  ({ StdioServerTransport } = await import(sdk('server/stdio.js')));
  ({ StreamableHTTPClientTransport } = await import(sdk('client/streamableHttp.js')));
  types = await import(sdk('types.js'));
} catch (e) {
  fail(`无法加载 MCP SDK（${DSH_MODULES}）：${e.message}`);
}

// ── 配置 ──────────────────────────────────────────────────────────────
function loadInfo() {
  // 显式指定优先；否则依次试几个常见位置
  const candidates = process.env.BAOTA_MCP_INFO
    ? [process.env.BAOTA_MCP_INFO]
    : [
        resolve(HERE, 'mcp_info.json'),
        resolve(HERE, '../mcp_info.json'),
        resolve(HERE, '../../mcp_info.json'),
        resolve(process.cwd(), 'mcp_info.json'),
        resolve(process.env.HOME || '.', '.dsh/baota-mcp/mcp_info.json'),
        resolve(HERE, '../../baota-mcp-package/skill/references/mcp_info.json'),
      ];
  for (const p of candidates) {
    try {
      const data = JSON.parse(readFileSync(p, 'utf8'));
      if (process.env.BAOTA_MCP_INFO) log('凭证文件:', p);
      return { data, path: p };
    } catch { /* 试下一个 */ }
  }
  console.error('[baota-bridge] 未找到可用的 mcp_info.json，试过：');
  for (const p of candidates) console.error('   ', p);
  console.error('  → 用 BAOTA_MCP_INFO 显式指定其路径');
  return { data: {}, path: null };
}
const { data: info } = loadInfo();
const rawUrl = process.env.BAOTA_MCP_URL || info.local_host || info.url || info.public_host;
const token = process.env.BAOTA_MCP_TOKEN || info.api_token;
if (!rawUrl) fail('缺少目标 url');
if (!token) fail('缺少访问令牌');

const insecure = process.env.BAOTA_TLS_INSECURE !== '0'; // 默认跳过
const caPath = process.env.BAOTA_MCP_CA
  || [resolve(HERE, 'baota_root_ca.crt'), resolve(HERE, '../src/baota_root_ca.crt'),
      resolve(HERE, '../baota-mcp-package/skill/references/baota_root_ca.crt')]
       .find((p) => { try { readFileSync(p); return true } catch { return false } })
  || resolve(HERE, 'baota_root_ca.crt');

let ca;
if (!insecure) {
  try { ca = readFileSync(caPath, 'utf8'); }
  catch (e) { fail(`读取 CA 失败：${caPath} —— ${e.message}`); }
}

const u = new URL(rawUrl);
if (u.protocol !== 'https:') fail(`只支持 https，收到 ${u.protocol}`);
log(`target : ${rawUrl}`);
log(`tls    : ${insecure ? '跳过校验（仅本进程）' : '校验链 + 放宽主机名'}`);

// ── 自定义 fetch：把 TLS 决策限制在本进程 ─────────────────────────────
// 返回 WHATWG Response，供 StreamableHTTPClientTransport 使用。
const tlsFetch = (input, init = {}) => new Promise((resolve_, reject_) => {
  const url = new URL(typeof input === 'string' ? input : input.url ?? String(input));
  const body = init.body;
  const payload = body == null ? null
    : (typeof body === 'string' ? Buffer.from(body, 'utf8')
      : Buffer.isBuffer(body) ? body
        : Buffer.from(body));

  const headers = {};
  const src = init.headers || {};
  if (src && typeof src.forEach === 'function' && !Array.isArray(src)) src.forEach((v, k) => { headers[k] = v; });
  else if (Array.isArray(src)) for (const [k, v] of src) headers[k] = v;
  else Object.assign(headers, src);
  if (payload) headers['content-length'] = payload.length;

  const opts = {
    hostname: url.hostname,
    port: url.port || 443,
    path: url.pathname + url.search,
    method: init.method || 'GET',
    headers,
    rejectUnauthorized: !insecure,
  };
  if (!insecure) {
    opts.ca = ca;
    // 唯一放宽项：证书 SAN 不含实际主机名
    opts.checkServerIdentity = () => undefined;
  }

  const req = https.request(opts, (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => {
      const h = new Headers();
      for (const [k, v] of Object.entries(res.headers)) {
        if (Array.isArray(v)) for (const x of v) h.append(k, x);
        else if (v != null) h.set(k, v);
      }
      resolve_(new Response(Buffer.concat(chunks), { status: res.statusCode, headers: h }));
    });
  });
  req.on('error', reject_);
  if (init.signal) init.signal.addEventListener('abort', () => req.destroy(new Error('aborted')));
  if (payload) req.write(payload);
  req.end();
});

// ── 上游客户端 ────────────────────────────────────────────────────────
const upstream = new StreamableHTTPClientTransport(new URL(rawUrl), {
  fetch: tlsFetch,
  requestInit: { headers: { Authorization: `Bearer ${token}` } },
});

const upstreamClient = new Client(
  { name: 'baota-mcp-bridge', version: '1.0.0' },
  { capabilities: {} },
);

// ── 本地 stdio 服务端：把三个能力原样代理到上游 ───────────────────────
const { Server } = await import(sdk('server/index.js'));

const server = new Server(
  { name: 'baota-mcp-bridge', version: '1.0.0' },
  { capabilities: { tools: {}, resources: {}, prompts: {} } },
);

server.setRequestHandler(types.ListToolsRequestSchema, async (_req, extra) => {
  const r = await upstreamClient.listTools(undefined, { signal: extra?.signal });
  return { tools: r.tools, nextCursor: r.nextCursor };
});

server.setRequestHandler(types.CallToolRequestSchema, async (req, extra) => {
  const r = await upstreamClient.callTool(req.params, undefined, { signal: extra?.signal });
  return r;
});

server.setRequestHandler(types.ListResourcesRequestSchema, async (_req, extra) => {
  const r = await upstreamClient.listResources(undefined, { signal: extra?.signal });
  return { resources: r.resources, nextCursor: r.nextCursor };
});

server.setRequestHandler(types.ReadResourceRequestSchema, async (req, extra) => {
  return upstreamClient.readResource(req.params, { signal: extra?.signal });
});

server.setRequestHandler(types.ListPromptsRequestSchema, async (_req, extra) => {
  const r = await upstreamClient.listPrompts(undefined, { signal: extra?.signal });
  return { prompts: r.prompts, nextCursor: r.nextCursor };
});

server.setRequestHandler(types.GetPromptRequestSchema, async (req, extra) => {
  return upstreamClient.getPrompt(req.params, { signal: extra?.signal });
});

// ── 启动 ──────────────────────────────────────────────────────────────
await upstreamClient.connect(upstream);
log('上游已连接');

const caps = upstreamClient.getServerCapabilities();
log('上游能力:', JSON.stringify(caps));

const local = new StdioServerTransport();
await server.connect(local);
log('桥已就绪（stdio ⇄ streamable-http）');

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
process.on('uncaughtException', (e) => { console.error('[baota-bridge] uncaught:', e); });
