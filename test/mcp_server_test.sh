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
  printf '%s\n' "$@" | env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$fixture/home" ORGAMI_AUTOUPDATE=0 \
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
# Hits are nodes, notes and pages, not the lines of graph.json that happen to
# hold the word: the repo comes back as its node, with an edge's evidence.
reply 7 | jq -e --arg id "repo:$term" '.result.structuredContent
  | (.nodes | any(.id == $id)) and (.pages | type == "array") and (.notes | type == "array")
    and ([.pages[].file] | all(endswith(".md")))' >/dev/null ||
  fail "orgami_search did not return structured node, note and page hits: $(reply 7 | jq -c .result.structuredContent)"
reply 7 | jq -e '.result.content[0].text | test("\"id\":|map/graph\\.json:") | not' >/dev/null ||
  fail "orgami_search still prints raw JSON lines: $(reply 7 | jq -r '.result.content[0].text' | head -5)"

# A client with no checkout (Claude Desktop, an editor on another folder) still
# needs the organization overview, and `orgami context` alone no longer gives it
# outside a mapped repo, so the tool has to be able to ask for --org.
out=$(exchange "$INIT" "$READY" \
  '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"orgami_context","arguments":{"org":true}}}' \
  "$(jq -cn --arg r "$term" '{jsonrpc:"2.0",id:20,method:"tools/call",params:{name:"orgami_context",arguments:{org:true,repo:$r}}}')") ||
  fail "the server exited non-zero on orgami_context"
reply 19 | jq -e '(.result.isError // false) == false and (.result.content[0].text | startswith("# acme — acme-inc"))' >/dev/null ||
  fail "orgami_context with org:true did not return the organization overview: $(reply 19)"
reply 20 | jq -e '.result.isError == true and (.result.content[0].text | test("^Refused"))' >/dev/null ||
  fail "orgami_context with org and repo together was not refused: $(reply 20)"

# --- empty states are answers, not errors --------------------------------------
# A company with a map and nothing else: no notes, no decisions page, no
# conventions page, no symbol index, no drafts. Every one of those is a state the
# tool reports, the same way orgami_live and orgami_dns always have. A bad
# argument is still an error.
mkdir -p "$fixture/bare"
cp -R test/fixtures/company "$fixture/bare/acme"
rm -rf "$fixture/bare/acme/notes" "$fixture/bare/acme/map/decisions" "$fixture/bare/acme/map/playbooks" \
  "$fixture/bare/acme/map/DECISIONS.md" "$fixture/bare/acme/map/CONVENTIONS.md" "$fixture/bare/acme/map/depth.json"
echo '{"default": "acme"}' >"$fixture/bare/config.json"
call() { jq -cn --arg n "$1" --argjson a "$2" --argjson i "$3" '{jsonrpc:"2.0",id:$i,method:"tools/call",params:{name:$n,arguments:$a}}'; }
out=$(ORGAMI_HOME="$fixture/bare" exchange "$INIT" "$READY" \
  "$(call orgami_notes '{}' 10)" "$(call orgami_decisions '{}' 11)" "$(call orgami_conventions '{}' 12)" \
  "$(call orgami_symbol '{"name":"x"}' 13)" "$(call orgami_playbook '{}' 14)" "$(call orgami_drafts '{}' 15)" \
  "$(call orgami_search '{"query":"zz-nothing-matches-zz"}' 16)" "$(call orgami_search '{"query":"  "}' 17)" \
  "$(call orgami_drafts '{"action":"keep"}' 18)") || fail "the server exited non-zero on an empty company"
for i in 10 11 12 13 14 15 16; do
  reply "$i" | jq -e '(.result.isError // false) == false and (.result.content[0].text | length) > 0' >/dev/null ||
    fail "empty state $i came back as an error: $(reply "$i")"
done
reply 11 | jq -e '.result.content[0].text | test("orgami report") and test("orgami doc")' >/dev/null ||
  fail "orgami_decisions does not say which commands write DECISIONS.md: $(reply 11)"
reply 16 | jq -e '.result.structuredContent.found == {"nodes":0,"notes":0,"pages":0}' >/dev/null ||
  fail "an empty search does not say it found nothing, structurally: $(reply 16)"
for i in 17 18; do
  reply "$i" | jq -e '.result.isError == true and (.result.content[0].text | test("^Refused"))' >/dev/null ||
    fail "a call missing its argument ($i) was not refused: $(reply "$i")"
done

# --- the plugin declares the server, at a file that exists ---------------------
args=$(jq -r '.mcpServers.orgami.args[0] // empty' .claude-plugin/plugin.json)
[[ -n $args ]] || fail "plugin.json declares no orgami MCP server"
[[ -f ${args/\$\{CLAUDE_PLUGIN_ROOT\}/$ROOT} ]] || fail "plugin.json launches $args, which is not in the tree"

echo "mcp: $n tools listed with no company, every failure an isError, the plugin points at it"
