#!/usr/bin/env bash
# `changes-with` is the one edge in the map that enters without a file:line
# behind it. Every other edge is extracted — a literal string sat in a committed
# file and the evidence is the line you can open. This one is counted out of
# merged pull requests, so what keeps it honest is not the evidence string but
# the `confidence: "inferred"` tag beside it: drop that field and a correlation
# becomes indistinguishable from a declared dependency everywhere downstream.
# That is what this pins first.
#
# It also pins what decides the edge exists at all — the more-than-once gate,
# the more-than-one-author gate, because one lead merging into two client
# projects every week is not coupling, and the bot exclusion, because a
# dependency bump across ten repositories is not either — and that merging into
# `map/graph.json` rebuilds its changes-with edges and leaves the rest alone.
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

# A third week, so each arm of the gate has a pair two people made: dev-four
# merges billing-api and web on one day, and api and worker move together on
# two days of one week, once by dev-five and once by dev-six. jobs and scheduler
# stay dev-three's alone.
pr() { printf '{"repository": {"name": "%s"}, "author": {"login": "%s"}, "mergedAt": "%s"}' "$@"; }
printf '{"week": "2026-W22", "prs": [%s, %s, %s, %s, %s, %s]}\n' \
  "$(pr billing-api dev-four 2026-05-25T10:00:00Z)" "$(pr web dev-four 2026-05-25T11:00:00Z)" \
  "$(pr api dev-five 2026-05-26T10:00:00Z)" "$(pr worker dev-five 2026-05-26T11:00:00Z)" \
  "$(pr api dev-six 2026-05-27T10:00:00Z)" "$(pr worker dev-six 2026-05-27T11:00:00Z)" \
  >"$home/acme/cache/prs/2026-W22.json"

# A graph that already has edges in it. `coupling` merges; it does not own
# this file, only its changes-with edges, and the stale one here goes. worker
# is not in the map, so api + worker, stable as it is, has no edge to become.
cat >"$home/acme/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-05-20T00:00:00Z",
 "nodes": [
   {"id": "repo:billing-api", "kind": "repo", "name": "billing-api", "meta": {}},
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {}},
   {"id": "repo:jobs", "kind": "repo", "name": "jobs", "meta": {}},
   {"id": "repo:scheduler", "kind": "repo", "name": "scheduler", "meta": {}},
   {"id": "repo:api", "kind": "repo", "name": "api", "meta": {}}],
 "edges": [
   {"from": "repo:web", "to": "repo:billing-api", "kind": "calls",
    "evidence": "src/api.ts:31", "confidence": "extracted"},
   {"from": "repo:jobs", "to": "repo:web", "kind": "changes-with",
    "evidence": "2 weeks / 0 days, dev-one, dev-two", "confidence": "inferred"}]}
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
            | .evidence' "$graph")" "3 weeks / 2 days, dev-four, dev-one"

# --- the gate ----------------------------------------------------------------

# Both arms of `weeks > 1 or days > 1`, each with two authors. billing-api and
# web moved together in three different weeks; api and worker on two different
# days of one week, which coupling.json marks stable.
check "a pair seen in several weeks reaches the graph" \
  "$(jq '[.edges[] | select(.kind == "changes-with"
          and .from == "repo:billing-api" and .to == "repo:web")] | length' "$graph")" "1"
check "a pair seen on two days of one week is stable" \
  "$(jq -c '.pairs[] | select(.a == "api" and .b == "worker") | [.weeks, .days, .stable]' "$pairs")" \
  "[1,2,true]"
check "but a pair naming a repo the map does not hold is no edge" \
  "$(jq '[.edges[] | select(.kind == "changes-with" and .to == "repo:worker")] | length' "$graph")" "0"

# One person on two days, or in two weeks, is that person's calendar.
check "a pair only one author made is counted, and not stable" \
  "$(jq -c '.pairs[] | select(.a == "jobs" and .b == "scheduler") | [.days, .authors, .stable]' "$pairs")" \
  '[2,["dev-three"],false]'
check "and it produces no edge" \
  "$(jq '[.edges[] | select(.kind == "changes-with" and .from == "repo:jobs")] | length' "$graph")" "0"

# Two repositories landing changes on the same day once is noise. It is counted
# — it is in coupling.json, where the count is the point — but it is not an edge.
check "the one-week pair is counted" \
  "$(jq '[.pairs[] | select(.a == "docs" and .b == "marketing")
          | select(.weeks == 1 and .days == 1)] | length' "$pairs")" "1"
check "nor does the one-week pair" \
  "$(jq '[.edges[] | select(.kind == "changes-with")
          | select(.from == "repo:docs" or .to == "repo:marketing")] | length' "$graph")" "0"

# The stale jobs + web edge was in the graph before the run; nothing in the
# pairs supports it now, so it is gone rather than kept forever.
check "so the graph holds exactly the one stable pair it has both repos of" \
  "$(jq -c '[.edges[] | select(.kind == "changes-with") | [.from, .to]]' "$graph")" \
  '[["repo:billing-api","repo:web"]]'

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
check "and the nodes are left alone" "$(jq '.nodes | length' "$graph")" "5"

# Running it twice adds the same edges again; `unique` is what stops the graph
# growing a duplicate every week the timer fires.
before=$(jq '.edges | length' "$graph")
ORGAMI_HOME="$home" ./bin/orgami coupling >/dev/null
check "a second run adds nothing" "$(jq '.edges | length' "$graph")" "$before"

exit "$fail"
