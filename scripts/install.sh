#!/usr/bin/env bash
# dsh-baota-mcp-bridge 安装脚本
#
# 只做三件事：① 自检依赖 ② 定位/生成 mcp_info.json ③（加 --apply 时）把
# mcp-client 条目追加进 profile 的 cordis.patch.yml。默认 dry-run，不动任何文件。
#
# 用法：
#   ./scripts/install.sh                  # 仅自检 + 打印将要写入的配置
#   ./scripts/install.sh --apply          # 真正写入（先备份）
#   ./scripts/install.sh --revert         # 删除本脚本写入的段落
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$HERE/src/baota-mcp-bridge.mjs"
CRT="$HERE/src/baota_root_ca.crt"
INFO_DEFAULT="$HERE/../baota-mcp-package/skill/references/mcp_info.json"

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
PROFILE="${DSH_PROFILE:-web}"
PATCH="$DSH_HOME_DIR/profiles/$PROFILE/cordis.patch.yml"
MARK_BEGIN="# ── dsh-baota-mcp-bridge BEGIN ──"
MARK_END="# ── dsh-baota-mcp-bridge END ──"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

# ── 1. 依赖自检 ───────────────────────────────────────────────────────
echo "== 1. 依赖自检 =="
NODE_BIN="$(command -v node || true)"
if [ -n "$NODE_BIN" ]; then ok "node: $NODE_BIN ($(node -v))"; else bad "未找到 node"; exit 1; fi

# DSH 安装位置：用于解析它自带的 MCP SDK
DSH_MODULES="${BAOTA_DSH_MODULES:-}"
if [ -z "$DSH_MODULES" ]; then
  for cand in \
    "$(npm root -g 2>/dev/null)/@deepseek-ai/dsh/node_modules" \
    "$HOME/.local/share/nvm/versions/node/$(node -v 2>/dev/null | tr -d v)/lib/node_modules/@deepseek-ai/dsh/node_modules" \
    /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules \
    /opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules ; do
    [ -d "$cand/@modelcontextprotocol/sdk" ] && { DSH_MODULES="$cand"; break; }
  done
fi
if [ -n "$DSH_MODULES" ] && [ -d "$DSH_MODULES/@modelcontextprotocol/sdk" ]; then
  ok "MCP SDK: $DSH_MODULES"
else
  bad "未找到 @modelcontextprotocol/sdk —— 设置 BAOTA_DSH_MODULES 指向 DSH 的 node_modules"
  exit 1
fi

[ -f "$BRIDGE" ] && ok "桥: $BRIDGE" || { bad "缺少 $BRIDGE"; exit 1; }
[ -f "$CRT" ] && ok "CA 证书: $CRT" || warn "缺少 ${CRT}（仅 BAOTA_TLS_INSECURE=0 模式需要）"

# ── 2. 凭证 ───────────────────────────────────────────────────────────
echo
echo "== 2. 凭证（mcp_info.json）=="
INFO="${BAOTA_MCP_INFO:-$INFO_DEFAULT}"
# 规范化：去掉路径里的 ..，免得写进配置后难读
if [ -f "$INFO" ]; then
  INFO="$(cd "$(dirname "$INFO")" && pwd)/$(basename "$INFO")"
fi
if [ -f "$INFO" ]; then
  if node -e "const d=require('$INFO');process.exit(d.api_token?0:1)" 2>/dev/null; then
    ok "已找到并含 api_token: $INFO"
    # 复制到仓库内，使仓库自包含（不必依赖外部路径）
    if [ "$INFO" != "$HERE/src/mcp_info.json" ]; then
      if cp "$INFO" "$HERE/src/mcp_info.json" 2>/dev/null; then
        ok "已复制到 $HERE/src/mcp_info.json（仓库自包含；该文件已被 .gitignore 排除）"
      else
        warn "复制到仓库内失败，将直接引用原路径"
      fi
    fi
  else
    bad "$INFO 存在但没有 api_token"
  fi
else
  warn "未找到 $INFO"
  info "请把服务方下发的 mcp_info.json 放到该路径，或设 BAOTA_MCP_INFO 指向它。"
  info "（该文件含令牌，切勿提交到 git —— 已在 .gitignore 中排除）"
fi

# 从 mcp_info.json 现场提取证书链（仓库不分发 CA 证书）
if [ -f "$INFO" ] && [ ! -f "$CRT" ]; then
  if node -e "
const fs=require('fs');const d=require('$INFO');
if(d.tls_cert&&d.tls_cert.includes('BEGIN CERTIFICATE')){
  fs.writeFileSync('$CRT', d.tls_cert.endsWith('\\n')?d.tls_cert:d.tls_cert+'\\n');
  process.exit(0)}process.exit(1)" 2>/dev/null; then
    ok "已从 mcp_info.json 提取证书链 → src/baota_root_ca.crt"
  else
    warn "mcp_info.json 里没有 tls_cert，跳过（仅 BAOTA_TLS_INSECURE=0 需要）"
  fi
fi

# ── 3. 桥自检 ─────────────────────────────────────────────────────────
echo
echo "== 3. 桥自检（真实连接一次）=="
if [ -f "$INFO" ]; then
  out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"install-check","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | BAOTA_DSH_MODULES="$DSH_MODULES" BAOTA_MCP_INFO="$INFO" BAOTA_TLS_INSECURE="${BAOTA_TLS_INSECURE:-1}" \
      "$NODE_BIN" "$BRIDGE" 2>/dev/null)
  n=$(printf '%s' "$out" | node -e "
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
  for(const l of s.split('\n')){ if(!l.trim())continue; let d; try{d=JSON.parse(l)}catch{continue}
    if(d.id===2) console.log((d.result?.tools||[]).length) }
})" 2>/dev/null)
  if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
    ok "连接成功，发现 $n 个工具"
  else
    bad "桥未能取到工具列表 —— 用 BAOTA_BRIDGE_LOG=1 手动跑一次看 stderr"
  fi
else
  info "跳过（无 mcp_info.json）"
fi

# ── 4. 目标配置 ───────────────────────────────────────────────────────
echo
echo "== 4. 目标配置 =="
echo "  profile patch: $PATCH"
if [ -f "$PATCH" ]; then ok "已存在"; else warn "不存在（DSH 可能尚未创建该 profile）"; fi
if [ -f "$PATCH" ] && grep -qF "$MARK_BEGIN" "$PATCH"; then
  warn "本条目已存在 —— 重复 --apply 不会重复写入"
fi

BLOCK="$MARK_BEGIN
- insert:
    - id: mcp-client
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: baota
        transport: stdio
        command: $NODE_BIN
        args:
          - $BRIDGE
        env:
          BAOTA_DSH_MODULES: $DSH_MODULES
          BAOTA_TLS_INSECURE: '${BAOTA_TLS_INSECURE:-1}'
          BAOTA_MCP_INFO: $INFO
        toolCallTimeoutMs: 120000
$MARK_END"

echo
echo "  将要写入的内容："
printf '%s\n' "$BLOCK" | sed 's/^/    /'

# ── 5. 写入 ───────────────────────────────────────────────────────────
# 备份失败必须中止：绝不能在无备份的情况下改配置
backup() {
  local dest="$PATCH.bak-$(date +%Y%m%d-%H%M%S)"
  if ! cp "$PATCH" "$dest" 2>/dev/null; then
    bad "备份失败（权限？），已中止，未修改任何文件"
    exit 1
  fi
  printf '    备份: %s\n' "$dest"
}

case "${1:-}" in
  --apply)
    [ -f "$PATCH" ] || { bad "$PATCH 不存在，无法写入"; exit 1; }
    if grep -qF "$MARK_BEGIN" "$PATCH"; then
      echo; warn "已存在，跳过写入（如需更新请先 --revert）"; exit 0
    fi
    backup
    if ! printf '\n%s\n' "$BLOCK" >> "$PATCH" 2>/dev/null; then
      bad "写入失败（权限？）——可用刚才的备份还原"
      exit 1
    fi
    echo; ok "已写入 $PATCH"
    echo "  web 面板会热重载，无需重启 DSH。"
    ;;
  --revert)
    [ -f "$PATCH" ] || { bad "$PATCH 不存在"; exit 1; }
    grep -qF "$MARK_BEGIN" "$PATCH" || { warn "未找到标记段，无需回退"; exit 0; }
    backup
    # 连同本条目上方的中文说明注释一起删掉（支持新旧两种写法）
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0==b {skip=1}
      !skip {
        if ($0 ~ /^# ── 宝塔 MCP 接入/) { pending=1; next }
        if (pending && $0 ~ /^#/) next
        pending=0
        print
      }
      $0==e {skip=0}' "$PATCH" > "$PATCH.tmp"
    if [ ! -s "$PATCH.tmp" ]; then
      rm -f "$PATCH.tmp"; bad "回退结果为空，已中止（可用备份还原）"; exit 1
    fi
    mv "$PATCH.tmp" "$PATCH" || { bad "回退失败（可用备份还原）"; exit 1; }
    echo; ok "已移除标记段"
    ;;
  *)
    echo; info "以上为 dry-run。确认无误后跑： $0 --apply"
    ;;
esac
