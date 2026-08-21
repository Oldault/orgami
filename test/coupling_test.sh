#!/usr/bin/env bash
# `changes-with` is the one edge in the map that enters without a file:line
# behind it. Every other edge is extracted — a literal string sat in a committed
# file and the evidence is the line you can open. This one is counted out of
# merged pull requests, so what keeps it honest is not the evidence string but
# the `confidence: "inferred"` tag beside it: drop that field and a correlation
# becomes indistinguishable from a declared dependency everywhere downstream.
# That is what this pins first.
#
# It also pins the two things that decide the edge exists at all — the
# more-than-once gate, and the bot exclusion, because a dependency bump across
# ten repositories is not coupling — and that merging into `map/graph.json`
# adds to the graph rather than replacing it.
#
# Runs against a hand-written pull request cache under a temp ORGAMI_HOME. No
# organization, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/acme/map" "$home/acme/cache/prs"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"

# Two weeks of merged pull requests, hand-written so each pair is there for a
# reason: dev-one couples billing-api and web across both weeks, dev-three
# couples jobs and scheduler on two separate days of one week, dev-two touched
# docs and marketing together exactly once, and the two bots touch pairs of
# repositories every week they run.
cp test/fixtures/coupling/2026-W20.json test/fixtures/coupling/2026-W21.json \
  "$home/acme/cache/prs/"

# A graph that already has an edge in it. `coupling` merges; it does not own
# this file.
cat >"$home/acme/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-05-20T00:00:00Z",
 "nodes": [
   {"id": "repo:billing-api", "kind": "repo", "name": "billing-api", "meta": {}},
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {}}],
 "edges": [
   {"from": "repo:web", "to": "repo:billing-api", "kind": "calls",
    "evidence": "src/api.ts:31", "confidence": "extracted"}]}
JSON

ORGAMI_HOME="$home" ./bin/orgami coupling >/dev/null

graph="$home/acme/map/graph.json"
pairs="$home/acme/map/coupling.json"

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

# --- the tag that makes the edge readable ------------------------------------

# The one that matters most. Not `extracted`, not absent: a `changes-with` edge
# without its confidence is a claim about a dependency nobody can check.
check "every changes-with edge is tagged inferred" \
  "$(jq '[.edges[] | select(.kind == "changes-with")
         | select(.confidence != "inferred")] | length' "$graph")" "0"
check "and none of them claims to be extracted" \
  "$(jq '[.edges[] | select(.kind == "changes-with" and .confidence == "extracted")]
         | length' "$graph")" "0"

# The evidence is the count it came from, said as prose. There is no file to
# open, so it must not look like there is one.
check "the evidence is the correlation, not a citation" \
  "$(jq -r '.edges[] | select(.kind == "changes-with" and .from == "repo:billing-api")
            | .evidence' "$graph")" "2 weeks / 1 days, dev-one"

# --- the gate ----------------------------------------------------------------

# Both arms of `weeks > 1 or days > 1`. billing-api and web moved together in
# two different weeks; jobs and scheduler on two different days of one week.
check "a pair seen in two weeks reaches the graph" \
  "$(jq '[.edges[] | select(.kind == "changes-with"
          and .from == "repo:billing-api" and .to == "repo:web")] | length' "$graph")" "1"
check "so does a pair seen on two days of one week" \
  "$(jq '[.edges[] | select(.kind == "changes-with"
          and .from == "repo:jobs" and .to == "repo:scheduler")] | length' "$graph")" "1"

# Two repositories landing changes on the same day once is noise. It is counted
# — it is in coupling.json, where the count is the point — but it is not an edge.
check "the one-week pair is counted" \
  "$(jq '[.pairs[] | select(.a == "docs" and .b == "marketing")
          | select(.weeks == 1 and .days == 1)] | length' "$pairs")" "1"
check "and it produces no edge" \
  "$(jq '[.edges[] | select(.kind == "changes-with")
          | select(.from == "repo:docs" or .to == "repo:marketing")] | length' "$graph")" "0"

check "so the gate let through exactly the two stable pairs" \
  "$(jq '[.edges[] | select(.kind == "changes-with")] | length' "$graph")" "2"

# --- the bots ----------------------------------------------------------------

# Asserted through lib/bots.jq rather than against a list written here, so this
# stays true if the definition of a bot changes. `coupling` reads the same file.
check "no bot reaches the pair list at all" \
  "$(jq -L lib 'include "bots";
      [.pairs[].authors[] | select(is_bot)] | length' "$pairs")" "0"
check "and the pairs a bot alone would have made are absent" \
  "$(jq '[.pairs[] | select((.a == "billing-api" and .b == "docs")
          or (.a == "jobs" and .b == "web"))] | length' "$pairs")" "0"

# --- what was already in the graph -------------------------------------------

check "the edge that was there before is still there" \
  "$(jq '[.edges[] | select(.kind == "calls" and .evidence == "src/api.ts:31")]
         | length' "$graph")" "1"
check "with its own confidence untouched" \
  "$(jq -r '.edges[] | select(.kind == "calls") | .confidence' "$graph")" "extracted"
check "and the nodes are left alone" "$(jq '.nodes | length' "$graph")" "2"

# Running it twice adds the same edges again; `unique` is what stops the graph
# growing a duplicate every week the timer fires.
before=$(jq '.edges | length' "$graph")
ORGAMI_HOME="$home" ./bin/orgami coupling >/dev/null
check "a second run adds nothing" "$(jq '.edges | length' "$graph")" "$before"

exit "$fail"
