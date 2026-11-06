#!/usr/bin/env bash
# Colour is for a terminal. `orgami query host` once wrote the kind's 256-colour
# escape to a pipe, and ignored NO_COLOR, because style_kind_color returned its
# escape whether or not the palette was on. Repo nodes were fine only because
# they take their colours from S_*, which style_init blanks.
#
# Runs against a hand-written graph under a temp ORGAMI_HOME; no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/acme/map"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"
cat >"$home/acme/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-08-18T00:00:00Z",
 "nodes": [
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {}},
   {"id": "service:postgres", "kind": "service", "name": "postgres"},
   {"id": "host:api.example.com", "kind": "host", "name": "api.example.com"}],
 "edges": [
   {"from": "repo:web", "to": "service:postgres", "kind": "depends-on",
    "evidence": "docker-compose.yml:4", "confidence": "extracted"},
   {"from": "repo:web", "to": "host:api.example.com", "kind": "deploys-to",
    "evidence": "fly.toml:1", "confidence": "extracted"}]}
JSON

fail=0
esc=$'\033'
check() { # check <label> <text that must hold no escape>
  if [[ $2 == *"$esc"* ]]; then echo "FAIL $1: wrote an escape code" >&2; fail=1; else echo "ok   $1"; fi
}

for node in postgres api.example.com web; do
  out=$(ORGAMI_AUTOUPDATE=0 ORGAMI_HOME="$home" ./bin/orgami query "$node" </dev/null)
  check "query $node into a pipe is plain" "$out"
  out=$(NO_COLOR=1 ORGAMI_COLOR=1 ORGAMI_AUTOUPDATE=0 ORGAMI_HOME="$home" ./bin/orgami query "$node" </dev/null)
  check "query $node with NO_COLOR is plain even when colour is forced" "$out"
done

# Forced colour (the fzf preview pane) still works.
out=$(ORGAMI_COLOR=1 ORGAMI_AUTOUPDATE=0 ORGAMI_HOME="$home" ./bin/orgami query postgres </dev/null)
if [[ $out == *"${esc}[38;5;140m"* ]]; then echo "ok   ORGAMI_COLOR=1 still colours the service kind"; else
  echo "FAIL ORGAMI_COLOR=1 lost the colour" >&2; fail=1
fi

exit "$fail"
