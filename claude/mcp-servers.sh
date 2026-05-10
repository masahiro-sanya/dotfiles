#!/bin/bash
# Restore Claude Code MCP servers (user scope) on a fresh machine.
# Idempotent: re-running skips servers that are already registered.
#
# Required: `claude` CLI on PATH.
# Optional follow-up:
#   - notion : initial OAuth in browser on first connect
#   - google-dev-knowledge : depends on ~/.claude/hooks/dev-knowledge-headers.sh
#   - terraform : requires Docker Desktop running
#
# Plugin-provided MCP (Slack / palmu-api-doc / Google Drive) are NOT handled
# here — install them via `/plugin` after `claude` first launch.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $1"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

if ! command -v claude &>/dev/null; then
  echo "claude CLI not found on PATH. Install it first." >&2
  exit 1
fi

# Existing servers (user scope) — used to skip re-add.
EXISTING="$(claude mcp list 2>/dev/null | awk -F: '/^[a-z]/ {print $1}' || true)"

add_stdio() {
  local name="$1"; shift
  if echo "$EXISTING" | grep -qx "$name"; then
    skip "$name (already registered)"
    return
  fi
  claude mcp add --scope user "$name" -- "$@"
  info "$name"
}

add_http() {
  local name="$1" url="$2"
  if echo "$EXISTING" | grep -qx "$name"; then
    skip "$name (already registered)"
    return
  fi
  claude mcp add --scope user --transport http "$name" "$url"
  info "$name"
}

# --- stdio servers ---
add_stdio serena uvx --from \
  "git+https://github.com/oraios/serena@368486299d5fa9a65a984daf24d0209ca1b49feb" \
  serena start-mcp-server
add_stdio drawio    npx -y @drawio/mcp@1.1.8
add_stdio context7  npx -y @upstash/context7-mcp@2.1.6
add_stdio gcloud    npx -y @google-cloud/gcloud-mcp@0.5.3
add_stdio terraform docker run -i --rm hashicorp/terraform-mcp-server

# --- http servers ---
add_http notion               https://mcp.notion.com/mcp
add_http google-dev-knowledge https://developerknowledge.googleapis.com/mcp

cat <<'EOF'

MCP servers registered. Manual follow-up:
  1. notion: open Claude Code, the first connect triggers browser OAuth
  2. google-dev-knowledge: ensure ~/.claude/hooks/dev-knowledge-headers.sh exists & is executable
  3. terraform: start Docker Desktop before use
  4. plugin MCP (Slack / palmu-api-doc / Google Drive): install via /plugin
EOF
