#!/usr/bin/env bash
# map/ARCHITECTURE.md and the per-repo cards are the pages a person actually
# opens, so what they may say is pinned here the way test/html_render_test.sh
# pins the same thing for map/graph.html — the two views of one graph must not
# drift apart.
#
# Three things:
#
#   1. Every edge on the page keeps its evidence and its confidence, and an
#      edge nobody declared is visibly marked as inferred rather than sitting
#      beside an extracted one as though a `file:line` could be opened for it.
#   2. "How the repositories reference each other" names a pair only when the
#      graph has that edge.
#   3. A section with nothing in it is gone, heading and all, per AGENTS.md.
#
# Runs against hand-written fixtures under a temp ORGAMI_HOME — no scan, no
# checkouts, no organization, no token, no network, no model.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fix=test/fixtures/doc
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

# Renders one fixture graph into a company of its own and echoes the directory.
#
# A fourth argument copies a weekly recap into `reports/`, which `orgami doc`
# reads to write INCIDENTS.md. The bare company below is rendered without one on
# purpose: a company whose first week produced no recap — and, equally, a quiet
# week whose recap omits the sections prompts/recap.md tells the model to omit —
# is the case that used to abort the whole command half way through.
render() {
  local name=$1 graph=$2 profiles=$3 recap=${4-}
  local dir="$home/$name"
  mkdir -p "$dir/map" "$dir/reports"
  echo "{\"default\": \"$name\"}" >"$home/config.json"
  echo '{"org": "acme"}' >"$dir/config.json"
  cp "$fix/$graph" "$dir/map/graph.json"
  cp "$fix/$profiles" "$dir/map/repos.json"
  [[ -n $recap ]] && cp "$fix/$recap" "$dir/reports/2026-W33.md"
  ORGAMI_HOME="$home" ORGAMI_COMPANY="$name" ./bin/orgami doc >/dev/null 2>"$dir/err" ||
    { echo "FAIL orgami doc failed on the $name fixture:" >&2; cat "$dir/err" >&2; exit 1; }
  echo "$dir"
}

# --- a graph with something in every section ---------------------------------

full=$(render full graph.json repos.json report.md)
page="$full/map/ARCHITECTURE.md"
[[ -f $page ]] || { echo "FAIL nothing rendered" >&2; exit 1; }

# The counts at the top are the split the rest of the page depends on: four
# edges read off a committed line, and two nobody declared — the untagged
# `calls` edge and the `changes-with` pair, which is the one kind of edge that
# enters the graph with no file behind it at all.
check "extracted edges are counted as extracted" \
  "$(grep -c '\*\*4 extracted\*\*' "$page")" "1"
check "and the edges nobody declared are counted apart" \
  "$(grep -c '\*\*2 inferred\*\*' "$page")" "1"

refs=$(sed -n '/^## How the repositories reference each other/,/^## /p' "$page")

# The whole point of the section: a solid arrow may only be drawn for an edge
# that cites a file, and a dotted one for an edge that cannot.
check "an extracted reference is drawn solid" \
  "$(grep -c '^  web\[web\] --> billing\[billing\]$' <<<"$refs")" "1"
check "an edge nobody declared is drawn dotted" \
  "$(grep -c '^  billing\[billing\] -\.-> web\[web\]$' <<<"$refs")" "1"

check "an extracted edge carries the file:line it came from" \
  "$(grep -c '^- `web` → `billing` — `package.json:14`$' <<<"$refs")" "1"
check "and is not labelled inferred" \
  "$(grep -c '^- `web` → `billing`.*inferred' <<<"$refs")" "0"
check "an untagged edge carries its evidence too" \
  "$(grep -c '^- `billing` → `web` — `internal/client.go:88`' <<<"$refs")" "1"
check "and says out loud that nothing declared it" \
  "$(grep -c '^- `billing` → `web`.*\*(inferred — matched, not declared)\*$' <<<"$refs")" "1"

# `changes-with` is the edge with no file behind it — two repos that landed
# changes together, counted out of merged pull requests. It is counted as
# inferred above, and it may not show up here, where every line offers the
# reader something to open.
check "a changes-with pair is not listed as a reference" \
  "$(grep -c 'toolbox' <<<"$refs")" "0"

# And nothing else invents a pair either: the section lists exactly the two
# reference-shaped edges the graph holds.
check "the section lists only the edges the graph has" \
  "$(grep -c '^- `' <<<"$refs")" "2"

# The two sections that exist here so their absence below means something.
check "the deployment section is present when a tool is used" \
  "$(grep -c '^## Deployment$' "$page")" "1"
check "with the repo and the file that named the tool" \
  "$(grep -c '^- `web` — `fly.toml:1`$' "$page")" "1"
check "the hosts section is present when a host was extracted" \
  "$(grep -c '^## Hosts and endpoints$' "$page")" "1"
check "with the evidence column filled in" \
  "$(grep -c '^| `api.acme.com` | web | `fly.toml:9` |$' "$page")" "1"

# --- the per-repo cards ------------------------------------------------------

web="$full/map/repos/web.md"
check "a card names the frameworks the profile states" \
  "$(grep -c 'TypeScript · Next.js · public' "$web")" "1"
check "and each command as the profile states it" \
  "$(grep -c '^- `build` — `next build`$' "$web")" "1"
check "and the runtime it is run with" \
  "$(grep -c 'pnpm · node 22' "$web")" "1"
check "and the edge out of it keeps its evidence" \
  "$(grep -c '^- references \*\*billing\*\* — `package.json:14`$' "$web")" "1"
check "and an edge into it says it was inferred" \
  "$(grep -c '^- called by \*\*billing\*\* — `internal/client.go:88` \*(inferred)\*$' "$web")" "1"

# A profile with nothing in it must produce a page that claims nothing. Not a
# heading with an empty list under it, and not a framework borrowed from the
# repo next door.
box="$full/map/repos/toolbox.md"
[[ -f $box ]] || { echo "FAIL no card for a repo with an empty profile" >&2; exit 1; }
check "an empty profile gets no run section" "$(grep -c '^## Run it$' "$box")" "0"
check "no endpoints section" "$(grep -c '^## Endpoints$' "$box")" "0"
check "no configuration section" "$(grep -c '^## Configuration$' "$box")" "0"
check "and borrows nothing from the other repos" \
  "$(grep -cE 'Next\.js|Gin|next build' "$box")" "0"
# The one thing it does say is what the map cannot know, which is not the same
# as an empty section.
check "it says instead what the scan could not see" \
  "$(grep -c 'runtime wiring leaves no trace here' "$box")" "1"

# --- a graph with nothing to deploy and nowhere to reach ---------------------

bare=$(render bare bare-graph.json bare-repos.json)
page="$bare/map/ARCHITECTURE.md"

# AGENTS.md: a heading with nothing underneath is noise in every future diff.
check "no tool, no deployment heading" "$(grep -c '^## Deployment$' "$page")" "0"
check "no host, no hosts heading" "$(grep -c '^## Hosts and endpoints$' "$page")" "0"
check "and no leftover line about there being none" \
  "$(grep -c 'No hosts found' "$page")" "0"

# The sections that stay are the ones whose empty text says something the
# absence of a heading would not — that a thing may exist and this scan cannot
# see it. They are the opposite case, and they stay as they are.
check "backing services stays and says what it cannot know" \
  "$(grep -c 'They may still exist — provisioned by hand, or wired in at runtime.' "$page")" "1"
check "and the reference section stays with the pair it has" \
  "$(grep -c '^- `alpha` → `beta` — `go.mod:7`$' "$page")" "1"

# --- and the pages after the incidents one still get written -----------------
#
# The bare company has no recap at all, which is what every company looks like
# before its first Monday. `orgami doc` writes INCIDENTS.md out of `reports/`
# midway through its run, and a failure there took the rest of the command down
# with it — the render above would already have failed, and these say what the
# rest of the command was that never ran.
check "the incidents page is written with no recaps to read" \
  "$(test -f "$bare/map/INCIDENTS.md" && echo yes)" "yes"
check "with no fires section, since nothing has been recorded" \
  "$(grep -c '^## Where the fires start$' "$bare/map/INCIDENTS.md")" "0"
check "and the pages written after it are there too" \
  "$(test -f "$bare/map/ASK-CLAUDE.md" && echo yes)" "yes"

exit "$fail"
