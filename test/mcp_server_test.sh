#!/usr/bin/env bash
# lib/mcp.py is started by the Claude Code plugin in every session, with or
# without a company configured, so it has to answer the handshake and list its
# tools on a bare machine, turn every failure into an isError result rather than
# a dead server, and survive a line that is not JSON-RPC at all. The plugin also
# has to point at it. Runs against a temp HOME and a copy of the fixture
# company — no org, no token, no network, no model.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

command -v python3 >/dev/null || { echo "mcp: python3 not installed — skipped"; exit 0; }

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "mcp: $*" >&2; exit 1; }

# One exchange: the lines on stdin, the replies on stdout, keyed by id.
exchange() {
  printf '%s\n' "$@" | env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$fixture/home" \
    ${ORGAMI_HOME:+ORGAMI_HOME="$ORGAMI_HOME"} python3 lib/mcp.py
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'
READY='{"jsonrpc":"2.0","method":"notifications/initialized"}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# --- a bare machine: no ~/.orgami at all ---------------------------------------
mkdir -p "$fixture/home"
unset ORGAMI_HOME
out=$(exchange "$INIT" "$READY" "$LIST" \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"orgami_context","arguments":{}}}' \
  'not json' \
  '[{"jsonrpc":"2.0","id":9,"method":"ping"}]' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"orgami_search","arguments":"wrong"}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool"}}' \
  '{"jsonrpc":"2.0","id":6,"method":"ping"}') || fail "the server exited non-zero on a bare machine"

reply() { jq -c --argjson i "$1" 'select(.id == $i)' <<<"$out"; }

[[ $(reply 1 | jq -r .result.serverInfo.name) == orgami ]] || fail "initialize did not answer: $(reply 1)"
v=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' lib/mcp.py)
[[ $(reply 1 | jq -r .result.serverInfo.version) == "$v" ]] || fail "initialize reports the wrong version"
n=$(reply 2 | jq '.result.tools | length')
[[ $n -gt 0 ]] || fail "tools/list listed nothing"
reply 2 | jq -e '.result.tools | all(.name and .description and .inputSchema.type == "object")' >/dev/null ||
  fail "a tool is missing its name, description or object inputSchema"

for i in 3 4; do
  reply "$i" | jq -e '.result.isError == true' >/dev/null || fail "call $i with no company was not an isError result: $(reply "$i")"
  reply "$i" | jq -e '.result.content[0].text | test("orgami init")' >/dev/null ||
    fail "call $i with no company does not say how to get one: $(reply "$i")"
done
reply 5 | jq -e '.result.isError == true and (.result.content[0].text | test("Unknown tool"))' >/dev/null ||
  fail "an unknown tool did not come back as isError"
[[ $(jq -c 'select(.id == null) | .error.code' <<<"$out" | tr '\n' ' ') == "-32700 -32600 " ]] ||
  fail "a garbage line and a batch should be -32700 and -32600: $(jq -c 'select(.id == null)' <<<"$out")"
reply 6 | jq -e '.result == {}' >/dev/null || fail "ping after the bad lines was not answered — the server died"
# The notification has no id, so it has no reply.
[[ $(grep -c . <<<"$out") == 8 ]] || fail "expected 8 replies, got $(grep -c . <<<"$out")"

# --- with the fixture company -------------------------------------------------
export ORGAMI_HOME="$fixture/orgami"
mkdir -p "$ORGAMI_HOME"
cp -R test/fixtures/company "$ORGAMI_HOME/acme"
echo '{"default": "acme"}' >"$ORGAMI_HOME/config.json"
term=$(jq -r '[.nodes[] | select(.kind == "repo")][0].name' "$ORGAMI_HOME/acme/map/graph.json")
out=$(exchange "$INIT" "$READY" \
  "$(jq -cn --arg q "$term" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:"orgami_search",arguments:{query:$q}}}')") ||
  fail "the server exited non-zero with a company"
reply 7 | jq -e '(.result.isError // false) == false and (.result.content[0].text | test("map/"))' >/dev/null ||
  fail "orgami_search found nothing for '$term' in the fixture map: $(reply 7)"

# --- the plugin declares the server, at a file that exists ---------------------
args=$(jq -r '.mcpServers.orgami.args[0] // empty' .claude-plugin/plugin.json)
[[ -n $args ]] || fail "plugin.json declares no orgami MCP server"
[[ -f ${args/\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT} ]] || fail "plugin.json launches $args, which is not in the tree"

echo "mcp: $n tools listed with no company, every failure an isError, the plugin points at it"
