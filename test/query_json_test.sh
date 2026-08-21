#!/usr/bin/env bash
# `orgami query --json` is what anything built on top of the map reads: a
# dashboard, a CI screen that fails when a repo gains an edge, another agent's
# tool. So the object has to have a fixed shape, and every edge has to arrive
# with the two things that make it checkable — the evidence it came from, and
# whether it was extracted from a file or inferred by matching. An edge that
# loses its confidence on the way out is the failure the emit_edge comment in
# lib/scan.sh is about, so it is asserted in both directions.
#
# And the flag may not disturb the text: without it the pane is what it was.
#
# Runs against a hand-written graph.json under a temp ORGAMI_HOME — no scan, no
# checkouts, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/acme/map"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"

# One node with an edge in each direction. `deploys-to` is tagged extracted and
# carries a signal; `calls` is tagged nothing at all, which is how scan writes
# the edges it resolved by matching rather than read off a line.
cat >"$home/acme/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-08-18T00:00:00Z",
 "nodes": [
   {"id": "repo:billing-api", "kind": "repo", "name": "billing-api",
    "meta": {"language": "Go"}},
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {}},
   {"id": "host:api.example.com", "kind": "host", "name": "api.example.com"}],
 "edges": [
   {"from": "repo:billing-api", "to": "host:api.example.com", "kind": "deploys-to",
    "evidence": "config/deploy.yml:12", "confidence": "extracted", "signal": "deploy"},
   {"from": "repo:web", "to": "repo:billing-api", "kind": "calls",
    "evidence": "src/api.ts:31"}]}
JSON

orgami() { ORGAMI_HOME="$home" ./bin/orgami "$@"; }

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

out=$(orgami query billing-api --json)

echo "$out" | jq -e . >/dev/null 2>&1 &&
  echo "ok   the output parses as JSON" ||
  { echo "FAIL the output is not JSON" >&2; exit 1; }

check "the node is resolved from its bare name" "$(jq -r .id <<<"$out")" "repo:billing-api"
check "kind is carried" "$(jq -r .kind <<<"$out")" "repo"
check "name is carried" "$(jq -r .name <<<"$out")" "billing-api"
check "meta is carried" "$(jq -r .meta.language <<<"$out")" "Go"
check "a node the scan wrote without meta still gets an object" \
  "$(orgami query api.example.com --json | jq -r '.meta | type')" "object"

check "the outgoing edge is under .edges.out" \
  "$(jq -r '.edges.out | length' <<<"$out")" "1"
check "and points at the node it reaches" \
  "$(jq -r '.edges.out[0].to' <<<"$out")" "host:api.example.com"
check "the incoming edge is under .edges.in" \
  "$(jq -r '.edges.in | length' <<<"$out")" "1"
check "and names the node that reaches it" \
  "$(jq -r '.edges.in[0].from' <<<"$out")" "repo:web"

check "an outgoing edge keeps its evidence" \
  "$(jq -r '.edges.out[0].evidence' <<<"$out")" "config/deploy.yml:12"
check "an incoming edge keeps its evidence" \
  "$(jq -r '.edges.in[0].evidence' <<<"$out")" "src/api.ts:31"
check "a signal survives where the scan recorded one" \
  "$(jq -r '.edges.out[0].signal' <<<"$out")" "deploy"
check "and is absent where it did not" \
  "$(jq -r '.edges.in[0] | has("signal")' <<<"$out")" "false"

# The distinction the whole map rests on: a tagged edge keeps its tag, an
# untagged one reads as what it is rather than as null.
check "a tagged edge keeps its confidence" \
  "$(jq -r '.edges.out[0].confidence' <<<"$out")" "extracted"
check "an untagged calls edge reads as inferred" \
  "$(jq -r '.edges.in[0].confidence' <<<"$out")" "inferred"
check "every edge carries one" \
  "$(jq '[.edges.out[], .edges.in[]] | map(select(.confidence == null)) | length' <<<"$out")" "0"

# The same traversal seen from the other end: what is .in here is .out there.
check "the edge reads the same way from the other node" \
  "$(orgami query web --json | jq -r '.edges.out[0].confidence')" "inferred"

# Without the flag, the pane. The flag adds an output, it does not change one.
text=$(orgami query billing-api)
echo "$text" | jq -e . >/dev/null 2>&1 &&
  { echo "FAIL the text output turned into JSON" >&2; fail=1; } ||
  echo "ok   without the flag the output is still the text pane"

# An unknown node fails the same way with the flag as without it, with the
# message that says what to do next.
err=$(orgami query nothing-here --json 2>&1 >/dev/null) && status=0 || status=$?
check "an unknown node still exits 1" "$status" "1"
check "with the message that says where to look" \
  "$err" "orgami: nothing called 'nothing-here' in the map — orgami view to browse"

err=$(orgami query billing-api --jsonn 2>&1 >/dev/null) && status=0 || status=$?
check "an unknown flag is refused rather than read as a node name" "$status" "1"
check "and says what the command takes" \
  "$err" "orgami: unknown flag '--jsonn' — usage: orgami query <repo|host|tool|service|vendor> [--json]"

exit "$fail"
