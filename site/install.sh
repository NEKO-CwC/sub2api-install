#!/usr/bin/env bash
# Sub2API 客户端接入脚本（macOS / Linux）
#
#   bash install.sh --client claude-code|codex|opencode [选项]
#
# 设计原则:
#   - API Key 只在本机终端输入，不经过浏览器、不写入日志、不出现在进程参数里
#   - 修改任何配置文件前先备份，随时可以 --restore 回滚
#   - 只改目标工具自己的配置文件，不动 shell profile

set -euo pipefail

DEFAULT_BASE_URL="https://sub2api.ncuos.com"

CLIENT=""
BASE_URL=""
MODEL=""
API_KEY=""
DRY_RUN=0
RESTORE=0
INSTALL_CLI=0
SMOKE=0

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_TEAL=$'\033[38;5;37m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_DIM=""; C_TEAL=""; C_RED=""; C_GREEN=""; C_YELLOW=""
fi

info() { printf '%s\n' "${C_TEAL}::${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }
dim()  { printf '%s\n' "${C_DIM}$*${C_RESET}"; }

usage() {
  cat <<'EOF'
Sub2API 客户端接入脚本

用法:
  bash install.sh --client <claude-code|codex|opencode> [选项]

选项:
  --client <name>     要配置的客户端 (必填)
  --base-url <url>    Sub2API 地址，默认 https://sub2api.ncuos.com
  --api-key <key>     直接提供 Key（会留在 shell 历史里，不推荐）
  --model <name>      指定模型（默认自动从 /v1/models 选择）
  --install-cli       顺便用 npm 安装/升级对应 CLI
  --smoke             配置完成后发一条最小请求验证端到端可用
  --dry-run           只显示将要做的改动，不写文件
  --restore           从最近一次备份恢复该客户端的配置
  -h, --help          显示本帮助

示例:
  bash install.sh --client claude-code
  bash install.sh --client codex --install-cli
  bash install.sh --client opencode --restore
EOF
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --client)      CLIENT="${2:-}"; shift 2 ;;
    --base-url)    BASE_URL="${2:-}"; shift 2 ;;
    --api-key)     API_KEY="${2:-}"; shift 2 ;;
    --model)       MODEL="${2:-}"; shift 2 ;;
    --install-cli) INSTALL_CLI=1; shift ;;
    --smoke)       SMOKE=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --restore)     RESTORE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -n "$CLIENT" ] || { usage; die "缺少 --client"; }

case "$CLIENT" in
  claude-code|claude) CLIENT="claude-code" ;;
  codex)              CLIENT="codex" ;;
  opencode)           CLIENT="opencode" ;;
  *) die "不支持的客户端: ${CLIENT}（可选 claude-code / codex / opencode）" ;;
esac

BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
BASE_URL="${BASE_URL%/}"

# ---------- 平台 ----------
case "$(uname -s)" in
  Darwin) OS_NAME="macOS" ;;
  Linux)  OS_NAME="Linux" ;;
  *)      die "本脚本只支持 macOS 和 Linux；Windows 请用 install.ps1" ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  warn "当前是 root。配置会写入 root 的家目录，通常不是你想要的。"
fi

# ---------- 工具函数 ----------
timestamp() { date +%Y%m%d-%H%M%S; }

read_secret() {
  local prompt="$1" value=""
  if [ -r /dev/tty ]; then
    printf '%s' "$prompt" > /dev/tty
    IFS= read -rs value < /dev/tty || true
    printf '\n' > /dev/tty
  else
    printf '%s' "$prompt" >&2
    IFS= read -rs value || true
    printf '\n' >&2
  fi
  printf '%s' "$value"
}

# Key 通过 curl --config - 从 stdin 传入，不出现在 argv / ps 里
api_get() {
  local url="$1"
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' "$API_KEY" \
    | curl -fsS --config - --max-time 25 "$url" 2>/dev/null
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local dest="${f}.bak.sub2api-$(timestamp)"
  cp -p "$f" "$dest"
  printf '%s' "$dest"
}

claude_dir="$HOME/.claude"
claude_settings="$claude_dir/settings.json"

codex_dir="${CODEX_HOME:-$HOME/.codex}"
codex_config="$codex_dir/config.toml"

opencode_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
opencode_config="$opencode_dir/opencode.json"

# ---------- 恢复 ----------
restore_latest() {
  local dir="$1" base="$2" label="$3" latest
  latest="$(ls -1t "$dir/$base".bak.sub2api-* 2>/dev/null | head -n1 || true)"
  [ -n "$latest" ] || die "没有找到 $label 的备份（$dir/$base.bak.sub2api-*）"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] 将用 $latest 覆盖 $dir/$base"
    return 0
  fi
  cp -p "$latest" "$dir/$base"
  ok "已恢复 $label: $dir/$base"
  dim "  来源: $latest"
}

if [ "$RESTORE" -eq 1 ]; then
  case "$CLIENT" in
    claude-code) restore_latest "$claude_dir" "settings.json" "Claude Code" ;;
    codex)       restore_latest "$codex_dir" "config.toml" "Codex CLI" ;;
    opencode)    restore_latest "$opencode_dir" "opencode.json" "OpenCode" ;;
  esac
  exit 0
fi

# ---------- 可选安装 CLI ----------
install_cli() {
  local pkg="$1"
  if ! command -v npm >/dev/null 2>&1; then
    warn "没有找到 npm，跳过 CLI 安装。"
    dim "  安装 Node.js: https://nodejs.org/  或  brew install node"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] npm install -g $pkg"
    return 0
  fi
  info "安装 $pkg ..."
  npm install -g "$pkg" >/dev/null 2>&1 || die "npm install -g $pkg 失败"
  ok "已安装 $pkg"
}

# ---------- Key 校验 ----------
validate_key() {
  local out body code
  out="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"\n' "$API_KEY" \
    | curl -sS --config - --max-time 25 -w '\n%{http_code}' "$BASE_URL/v1/models" 2>&1 || true)"
  code="$(printf '%s' "$out" | tail -n1)"
  body="$(printf '%s' "$out" | sed '$d')"

  case "$code" in
    200) ;;
    401|403) die "Key 无效或没有权限（HTTP ${code}）。请到 $BASE_URL/keys 重新复制。" ;;
    000)    die "无法连接 ${BASE_URL}。请检查网络或地址是否正确。" ;;
    *)      die "Key 校验失败（HTTP ${code}）：$(printf '%s' "$body" | head -c 300)" ;;
  esac

  case "$body" in
    *'"error"'*) die "Key 校验失败：$(printf '%s' "$body" | head -c 300)" ;;
  esac
  printf '%s' "$body"
}

extract_models() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | awk '!seen[$0]++'
}

pick_model() {
  local models="$1" prefer="$2" picked=""
  if [ -n "$prefer" ]; then
    picked="$(printf '%s\n' "$models" | grep -i "$prefer" | head -n1 || true)"
  fi
  [ -n "$picked" ] || picked="$(printf '%s\n' "$models" | head -n1 || true)"
  printf '%s' "$picked"
}

show_billing() {
  local body rate
  body="$(api_get "$BASE_URL/v1/sub2api/billing" || true)"
  [ -n "$body" ] || return 0
  rate="$(printf '%s' "$body" | sed -n 's/.*"effective_rate_multiplier"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p')"
  [ -n "$rate" ] && dim "  当前计费倍率: ${rate}x"
  return 0
}

smoke_test() {
  local model="${MODEL:-}"
  [ -n "$model" ] || { warn "没有可用模型，跳过测试请求"; return 0; }

  local path payload
  if [ "$CLIENT" = "claude-code" ]; then
    path="/v1/messages"
    payload="{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly SUB2API_OK.\"}]}"
  else
    path="/v1/chat/completions"
    payload="{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly SUB2API_OK.\"}]}"
  fi

  info "发送测试请求 ($path) ..."
  local body
  body="$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$API_KEY" \
    | curl -sS --config - --max-time 60 -X POST -d "$payload" "$BASE_URL$path" 2>&1 || true)"

  if [ -z "$body" ]; then
    warn "测试请求没有返回内容。配置已写入，可稍后在用量页确认。"
  elif printf '%s' "$body" | grep -q '"error"'; then
    warn "测试请求返回错误（配置已写入）："
    printf '%s\n' "$body" | head -c 400; printf '\n'
  else
    ok "测试请求成功。到「用量明细」可以看到这次调用。"
  fi
}

# ---------- JSON 深度合并 ----------
json_merge() {
  local file="$1" patch="$2"
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs=require("fs");
      const file=process.argv[1], patchText=process.argv[2];
      let cur={};
      try{ const t=fs.readFileSync(file,"utf8"); if(t.trim()) cur=JSON.parse(t); }catch(e){ cur={}; }
      if(!cur || typeof cur!=="object" || Array.isArray(cur)) cur={};
      const patch=JSON.parse(patchText);
      const merge=(a,b)=>{ for(const k of Object.keys(b)){
        const v=b[k];
        if(v && typeof v==="object" && !Array.isArray(v) && a[k] && typeof a[k]==="object" && !Array.isArray(a[k])) merge(a[k],v);
        else a[k]=v;
      } return a; };
      merge(cur,patch);
      fs.writeFileSync(file, JSON.stringify(cur,null,2)+"\n");
    ' "$file" "$patch"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$patch" <<'PY'
import json, sys
path, patch = sys.argv[1], json.loads(sys.argv[2])
try:
    cur = json.load(open(path))
    if not isinstance(cur, dict):
        cur = {}
except Exception:
    cur = {}
def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict):
            merge(a[k], v)
        else:
            a[k] = v
merge(cur, patch)
with open(path, "w") as f:
    f.write(json.dumps(cur, indent=2, ensure_ascii=False) + "\n")
PY
  elif command -v jq >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    if [ -s "$file" ]; then
      jq -s '.[0] * .[1]' "$file" <(printf '%s' "$patch") > "$tmp"
    else
      printf '%s' "$patch" | jq '.' > "$tmp"
    fi
    mv "$tmp" "$file"
  else
    die "需要 node、python3 或 jq 之一来合并 JSON 配置"
  fi
}

# ---------- Codex TOML 改写 ----------
# 保留原有内容，替换顶层 model / model_provider，重建 [model_providers.sub2api]
toml_write_codex() {
  local file="$1" model="$2" base="$3"
  local tmp; tmp="$(mktemp)"

  awk -v model="$model" -v base="$base/v1" '
    BEGIN { header=1; mp=0; md=0; skip=0 }
    {
      if (header && $0 ~ /^[ \t]*\[/) {
        if (!mp) { print "model_provider = \"sub2api\""; mp=1 }
        if (!md) { print "model = \"" model "\""; md=1 }
        print ""; header=0
      }
      if (header) {
        if ($0 ~ /^[ \t]*model_provider[ \t]*=/) { print "model_provider = \"sub2api\""; mp=1; next }
        if ($0 ~ /^[ \t]*model[ \t]*=/)          { print "model = \"" model "\""; md=1; next }
      }
      if ($0 ~ /^\[model_providers\.sub2api\][ \t]*$/) { skip=1; next }
      if (skip && $0 ~ /^\[/) { skip=0 }
      if (skip) next
      print
    }
    END {
      if (!mp) print "model_provider = \"sub2api\""
      if (!md) print "model = \"" model "\""
      print ""
      print "# Added by Sub2API installer. Remove this table to undo."
      print "[model_providers.sub2api]"
      print "name = \"Sub2API\""
      print "base_url = \"" base "\""
      print "wire_api = \"responses\""
      print "requires_openai_auth = false"
      print "supports_websockets = false"
      print "experimental_bearer_token = \"__SUB2API_KEY__\""
    }
  ' "$file" > "$tmp"

  # Key 按 TOML basic string 规则转义（\ 和 "），再用 awk 字面量插入，
  # 避免 sed 替换串对 &、\、| 的特殊处理。
  local toml_esc
  toml_esc="$(printf '%s' "$API_KEY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  SUB2API_KEY_RAW="$toml_esc" awk '
    {
      n = split($0, parts, "__SUB2API_KEY__")
      if (n > 1) {
        line = parts[1]
        for (i = 2; i <= n; i++) line = line ENVIRON["SUB2API_KEY_RAW"] parts[i]
        print line
      } else {
        print
      }
    }
  ' "$tmp" > "$tmp.2"
  mv "$tmp.2" "$tmp"

  mv "$tmp" "$file"
}

# ---------- 主流程 ----------
[ -n "$API_KEY" ] || API_KEY="$(read_secret "请粘贴 Sub2API Key（输入不会显示）: ")"
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"
[ -n "$API_KEY" ] || die "Key 不能为空"

case "$API_KEY" in
  sk-*) ;;
  *) warn "Key 不以 sk- 开头，仍继续尝试。" ;;
esac

info "平台: $OS_NAME    客户端: $CLIENT    地址: $BASE_URL"

MODELS_JSON="$(validate_key)"
MODELS="$(extract_models "$MODELS_JSON")"
MODEL_COUNT="$(printf '%s\n' "$MODELS" | grep -c . || true)"
ok "Key 有效，可见 $MODEL_COUNT 个模型"

if [ "$MODEL_COUNT" -gt 0 ]; then
  printf '%s\n' "$MODELS" | head -n 6 | sed 's/^/    /'
  [ "$MODEL_COUNT" -gt 6 ] && dim "    ... 共 $MODEL_COUNT 个"
fi

if [ -z "$MODEL" ]; then
  case "$CLIENT" in
    claude-code) MODEL="$(pick_model "$MODELS" "claude")" ;;
    codex)       MODEL="$(pick_model "$MODELS" "gpt")" ;;
    opencode)    MODEL="$(pick_model "$MODELS" "")" ;;
  esac
fi
[ -n "$MODEL" ] && dim "  选用模型: $MODEL"

if [ "$INSTALL_CLI" -eq 1 ]; then
  case "$CLIENT" in
    claude-code) install_cli "@anthropic-ai/claude-code" ;;
    codex)       install_cli "@openai/codex" ;;
    opencode)    install_cli "opencode-ai" ;;
  esac
fi

case "$CLIENT" in
  claude-code)
    patch="{\"env\":{\"ANTHROPIC_BASE_URL\":\"$BASE_URL\",\"ANTHROPIC_AUTH_TOKEN\":\"$API_KEY\",\"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\":\"1\"}}"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将写入 $claude_settings"
      printf '%s\n' "$patch"
    else
      mkdir -p "$claude_dir"
      b="$(backup_file "$claude_settings")"; [ -n "$b" ] && dim "  已备份: $b"
      json_merge "$claude_settings" "$patch"
      chmod 600 "$claude_settings" 2>/dev/null || true
      ok "已写入 $claude_settings"
    fi
    ;;

  codex)
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将写入 $codex_config"
      dim "  model_provider = \"sub2api\""
      dim "  model = \"$MODEL\""
      dim "  [model_providers.sub2api] base_url = \"$BASE_URL/v1\""
    else
      mkdir -p "$codex_dir"
      [ -f "$codex_config" ] || : > "$codex_config"
      b="$(backup_file "$codex_config")"; [ -n "$b" ] && dim "  已备份: $b"
      toml_write_codex "$codex_config" "$MODEL" "$BASE_URL"
      chmod 600 "$codex_config" 2>/dev/null || true
      ok "已写入 $codex_config"
    fi
    ;;

  opencode)
    patch="{\"\$schema\":\"https://opencode.ai/config.json\",\"provider\":{\"sub2api\":{\"npm\":\"@ai-sdk/openai-compatible\",\"name\":\"Sub2API\",\"options\":{\"baseURL\":\"$BASE_URL/v1\",\"apiKey\":\"$API_KEY\"},\"models\":{\"$MODEL\":{\"name\":\"$MODEL\"}}}}}"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 将写入 $opencode_config"
      printf '%s\n' "$patch"
    else
      mkdir -p "$opencode_dir"
      b="$(backup_file "$opencode_config")"; [ -n "$b" ] && dim "  已备份: $b"
      json_merge "$opencode_config" "$patch"
      chmod 600 "$opencode_config" 2>/dev/null || true
      ok "已写入 $opencode_config"
    fi
    ;;
esac

show_billing

if [ "$SMOKE" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  smoke_test
fi

if [ "$DRY_RUN" -eq 0 ]; then
  echo
  ok "配置完成"
  case "$CLIENT" in
    claude-code) dim "  下一步: 新开一个终端，运行 claude" ;;
    codex)       dim "  下一步: 新开一个终端，运行 codex" ;;
    opencode)    dim "  下一步: 新开一个终端，运行 opencode" ;;
  esac
  dim "  回滚: bash install.sh --client $CLIENT --restore"
  dim "  用量: $BASE_URL/keys"
fi
