#!/usr/bin/env bash
# `orgami mcp --config <client>` prints the snippet that client actually reads.
# Zed reads "context_servers"; VS Code reads a top-level "servers" with a
# transport type; neither looks at "mcpServers". And when the Claude Code plugin
# is installed it already declares the server, so the claude-code answer must not
# tell anyone to register a second one. Offline; a throwaway HOME.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/agents.sh
source lib/agents.sh

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

export HOME=$home
unset CLAUDE_PLUGIN_ROOT CLAUDE_CONFIG_DIR

z=$(cmd_mcp_config zed)
check "zed uses context_servers" "$(jq -r 'keys[0]' <<<"$z")" "context_servers"
check "zed names the server" "$(jq -r '.context_servers.orgami.args[0]' <<<"$z")" "mcp"
v=$(cmd_mcp_config vscode)
check "vscode uses servers" "$(jq -r 'keys[0]' <<<"$v")" "servers"
check "vscode says stdio" "$(jq -r '.servers.orgami.type' <<<"$v")" "stdio"
check "cursor keeps mcpServers" "$(cmd_mcp_config cursor | jq -r 'keys[0]')" "mcpServers"

out=$(cmd_mcp_config claude-code)
case $out in "claude mcp add orgami -- "*) echo "ok   without the plugin, the command is printed" ;;
  *) echo "FAIL claude-code printed '$out'" >&2; fail=1 ;; esac

mkdir -p "$home/.claude/plugins"
echo '{"version": 2, "plugins": {"orgami@orgami": [{"scope": "user"}]}}' >"$home/.claude/plugins/installed_plugins.json"
out=$(cmd_mcp_config claude-code)
case $out in
  "#"*"plugin:orgami:orgami"*) echo "ok   with the plugin, it says the server is already there" ;;
  *) echo "FAIL claude-code printed '$out'" >&2; fail=1 ;;
esac
case $out in *"mcp add"*) echo "FAIL still prints the add command" >&2; fail=1 ;; esac

# The generated block is committed to a repository: no path from this machine.
cat >"$home/brief" <<'STUB'
#!/usr/bin/env bash
echo "web — a storefront"
echo "full page: orgami context · org: orgami context --org · why: /home/someone/.orgami/acme/map/DECISIONS.md"
STUB
chmod +x "$home/brief"
export ORGAMI_BIN=$home/brief
blk=$(agents_block web)
case $blk in *"/home/someone"*) echo "FAIL the block embeds a local path" >&2; fail=1 ;;
  *) echo "ok   the block carries no absolute local path" ;; esac

exit "$fail"
