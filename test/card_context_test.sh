#!/usr/bin/env bash
# What a tester reads on a repo card, in ARCHITECTURE.md and from
# `orgami context` / `orgami brief`, pinned against a hand-written company:
#
#   1. "Deployed with" is tool: edges only. A vendor is named, by its name, in
#      a section of its own, and a company that is both (aws) is said once.
#      A README link is a reference, not something the repo reaches.
#   2. A capped list says it is capped: "2 of 9 shown", "3 of 70".
#   3. A second name for the same instruction file is named, not repeated.
#   4. `orgami doc` writes the same card `orgami card` prints, .github too.
#   5. `context --org` is a flag; outside the map, context says so in a line;
#      a typo fails; nothing points at a file that is not there, and nothing
#      printed for an AGENTS.md names a path on this machine.
#
# No scan, no network, no model: a temp ORGAMI_HOME and stub-free fixtures.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bin=$PWD/bin/orgami

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
export ORGAMI_HOME="$home/orgami" ORGAMI_AUTOUPDATE=0 HOME="$home"
export XDG_STATE_HOME="$home/state" XDG_CONFIG_HOME="$home/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset ORGAMI_COMPANY
mkdir -p "$HOME"

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

dir="$ORGAMI_HOME/acme"
mkdir -p "$dir/map" "$dir/cache/prs" "$dir/cache/src/web" "$dir/reports"
echo '{"default": "acme"}' >"$ORGAMI_HOME/config.json"
echo '{"org": "acme-inc"}' >"$dir/config.json"

cat >"$dir/map/graph.json" <<'JSON'
{"generated": "2026-11-01T00:00:00Z",
 "nodes": [
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {"language": "TypeScript", "url": "https://github.com/acme-inc/web"}},
   {"id": "repo:docs", "kind": "repo", "name": "docs", "meta": {"language": "Markdown"}},
   {"id": "repo:.github", "kind": "repo", "name": ".github", "meta": {}},
   {"id": "tool:aws", "kind": "tool", "name": "aws", "meta": {}},
   {"id": "tool:github-actions", "kind": "tool", "name": "github-actions", "meta": {}},
   {"id": "vendor:aws", "kind": "vendor", "name": "AWS", "meta": {}},
   {"id": "vendor:stripe", "kind": "vendor", "name": "Stripe", "meta": {}},
   {"id": "host:api.stripe.example", "kind": "host", "name": "api.stripe.example", "meta": {}}],
 "edges": [
   {"from": "repo:web", "to": "tool:aws", "kind": "uses", "evidence": ".github/workflows/deploy.yml:12", "confidence": "extracted"},
   {"from": "repo:web", "to": "tool:github-actions", "kind": "uses", "evidence": ".github/workflows/deploy.yml:1", "confidence": "extracted"},
   {"from": "repo:web", "to": "vendor:aws", "kind": "uses", "evidence": ".github/workflows/deploy.yml:12", "confidence": "extracted"},
   {"from": "repo:web", "to": "vendor:stripe", "kind": "uses", "evidence": ".env.example:3", "confidence": "extracted"},
   {"from": "repo:web", "to": "host:api.stripe.example", "kind": "reaches", "evidence": ".env.example:4", "confidence": "extracted"},
   {"from": "repo:docs", "to": "repo:web", "kind": "references", "evidence": "README.md:9", "confidence": "extracted"},
   {"from": "repo:docs", "to": "vendor:stripe", "kind": "uses", "evidence": "README.md:20", "confidence": "extracted"}]}
JSON

cat >"$dir/map/repos.json" <<'JSON'
[{"name": "web", "meta": {"language": "TypeScript", "url": "https://github.com/acme-inc/web", "default_branch": "main"},
  "frameworks": ["Next.js"],
  "commands": {"scripts": {"test": "vitest run", "test (api)": "pnpm --filter api test"}, "procfile": [],
               "evidence": {"test": "package.json:7", "test (api)": "api/package.json:5"}},
  "serves": [], "routes": ["GET /a", "GET /b"], "routes_total": 9,
  "env": ["A", "B", "C"], "env_total": 70,
  "agent_docs": ["AGENTS.md"], "agent_doc_aliases": {"CLAUDE.md": "AGENTS.md"},
  "workspaces": [{"dir": "api", "name": "api", "frameworks": ["Hono"]}]},
 {"name": "docs", "meta": {}, "frameworks": [], "commands": {"scripts": {}, "procfile": []},
  "serves": [], "routes": [], "env": [], "agent_docs": []},
 {"name": ".github", "meta": {}, "frameworks": [], "commands": {"scripts": {}, "procfile": []},
  "serves": [], "routes": [], "env": [], "agent_docs": []}]
JSON

printf '# Web\nRun pnpm test.\n' >"$dir/cache/src/web/AGENTS.md"
ln -s AGENTS.md "$dir/cache/src/web/CLAUDE.md"

# --- the repo card -----------------------------------------------------------

card=$("$bin" card web </dev/null)
check "deployed with lists tool: edges only" \
  "$(grep -c '^- deployed with aws, github-actions$' <<<"$card")" "1"
check "no raw vendor: id anywhere on the card" "$(grep -c 'vendor:' <<<"$card" || true)" "0"
check "a vendor gets its own section, by name, with its evidence" \
  "$(grep -c '^- Stripe — `.env.example:3`$' <<<"$card")" "1"
check "aws, a deploy tool and a vendor, is said once" "$(grep -ci 'aws' <<<"$card")" "1"
check "a host the repo reaches is listed as reached" \
  "$(grep -c '^- reaches `api.stripe.example`$' <<<"$card")" "1"
check "a capped endpoint list says how many there were" \
  "$(grep -c '<summary>2 of 9 shown</summary>' <<<"$card")" "1"
check "a capped environment list says how many there were" \
  "$(grep -c '<summary>3 of 70 environment variables</summary>' <<<"$card")" "1"
check "a linked instruction file is named on the one it points at" \
  "$(grep -c '^- \[`AGENTS.md`\](.*) (also `CLAUDE.md`)$' <<<"$card")" "1"
check "a command carries the line it was read from" \
  "$(grep -c '^- `test (api)` — `pnpm --filter api test` (`api/package.json:5`)$' <<<"$card")" "1"
check "a workspace package names its framework" \
  "$(grep -c '^- `api` · Hono$' <<<"$card")" "1"

# The terminal view's repo pane draws the same split (lib/tui.sh).
pane=$(ORGAMI_COMPANY=acme "$bin" _tui preview repo:web </dev/null)
check "tui: RUNS ON holds tools only, with no raw vendor: id" \
  "$(sed -n '/RUNS ON/,/^$/p' <<<"$pane" | grep -cE '^  (aws|github-actions) ') $(grep -c 'vendor:' <<<"$pane" || true)" "2 0"
check "tui: VENDORS names Stripe, and aws is said once" \
  "$(sed -n '/VENDORS/,/^$/p' <<<"$pane" | grep -c '^  Stripe ') $(grep -ciE '^  aws ' <<<"$pane")" "1 1"

docs=$("$bin" card docs </dev/null)
check "a vendor-only repo gets no Runs on section" "$(grep -c '^## Runs on$' <<<"$docs" || true)" "0"
check "and no deployed with line" "$(grep -c 'deployed with' <<<"$docs" || true)" "0"

# --- orgami doc: the same cards, the table, the conventions ------------------

cat >"$dir/cache/prs/2026-W44.json" <<'JSON'
{"prs": [{"number": 7, "title": "Add checkout", "author": {"login": "dana"}, "mergedAt": "2026-10-30T10:00:00Z", "repository": {"name": "web"}},
         {"number": 8, "title": "Fix\ttabbed title", "author": {"login": "lee"}, "mergedAt": "2026-10-31T10:00:00Z", "repository": {"name": "web"}}]}
JSON
"$bin" doc </dev/null >/dev/null 2>"$home/doc.err" || { cat "$home/doc.err" >&2; exit 1; }

for r in web docs .github; do
  check "orgami doc writes the card orgami card prints: $r" \
    "$(cmp -s <("$bin" card "$r" </dev/null) "$dir/map/repos/$r.md" && echo same)" "same"
done
check "the batched card keeps its recent work, newest first" \
  "$(grep -A3 '^## Recent merged work$' "$dir/map/repos/web.md" | sed -n 3p)" "- #8 Fix tabbed title — lee, 2026-10-31"

arch="$dir/map/ARCHITECTURE.md"
check "the table has a Vendors and a References column" \
  "$(grep -c '^| Repo | Language | Deployed with | Vendors | Depends on | Reaches | References |$' "$arch")" "1"
check "web: tools, vendors without the duplicate, the host it reaches" \
  "$(grep -c '^| \[web\](https://github.com/acme-inc/web) | TypeScript | aws, github-actions | Stripe | — | api.stripe.example | — |$' "$arch")" "1"
check "docs: a README link is a reference, not reach" \
  "$(grep -c '^| \[docs\]() | Markdown | — | Stripe | — | — | web |$' "$arch")" "1"

conv="$dir/map/CONVENTIONS.md"
check "CONVENTIONS lists the linked file once, with its other name" \
  "$(grep -c '^### `web/AGENTS.md` — 2 lines (also `CLAUDE.md`)$' "$conv")" "1"
check "and gives the link no section of its own" "$(grep -c '^### `web/CLAUDE.md`' "$conv" || true)" "0"

# --- context and brief -------------------------------------------------------

overview=$("$bin" context --org </dev/null)
check "--org is a flag, not a repo name" "$(grep -c "is not a repo" <<<"$overview" || true)" "0"
check "and prints the organization" "$(head -1 <<<"$overview")" "# acme — acme-inc"
check "busy repos are listed when PRs are cached" \
  "$(grep -c '^## Biggest repos by recent work$' <<<"$overview")" "1"
check "an existing ARCHITECTURE.md is pointed at, home written as ~" \
  "$(grep -c '^- `~/orgami/acme/map/ARCHITECTURE.md` — the whole org' <<<"$overview")" "1"
check "a DECISIONS.md that does not exist is not pointed at" \
  "$(grep -c 'DECISIONS.md' <<<"$overview" || true)" "0"

rm -f "$dir/cache/prs/"*.json "$arch"
overview=$("$bin" context --org </dev/null)
check "no cached PRs, no busy-repos heading" \
  "$(grep -c 'Biggest repos' <<<"$overview" || true)" "0"
check "no ARCHITECTURE.md, no pointer to it" \
  "$(grep -c 'ARCHITECTURE.md' <<<"$overview" || true)" "0"

# A personal checkout under another owner: one line, not the client's org.
mine="$home/zavod"
mkdir -p "$mine"
git -C "$mine" init -q
git -C "$mine" remote add origin git@github.com:someone/zavod.git
out=$(cd "$mine" && "$bin" context </dev/null)
check "outside the map, context is one line" "$(grep -c . <<<"$out")" "1"
check "which says so and gives the next step" \
  "$(grep -c "^'zavod' is not a repo in the acme map (acme-inc)\. For the organization: orgami context --org\." <<<"$out")" "1"
check "and lists none of the org's repos" "$(grep -c 'web' <<<"$out" || true)" "0"

# A checkout of the org the map has not caught up with yet.
new="$home/newrepo"
mkdir -p "$new"
git -C "$new" init -q
git -C "$new" remote add origin https://github.com/acme-inc/newrepo.git
check "an org repo the map does not hold yet says to scan" \
  "$(cd "$new" && "$bin" context </dev/null)" "'newrepo' is in acme-inc but not in the map yet — run: orgami scan"

rc=0
"$bin" context wbe </dev/null >/dev/null 2>"$home/err" || rc=$?
check "a typo in a named repo fails" "$rc" "1"
check "and says how to see the org" \
  "$(grep -c "no repo called 'wbe' in the acme-inc map — orgami context --org" "$home/err")" "1"

page=$("$bin" context web </dev/null)
check "the repo page names no path on this machine" "$(grep -c "$ORGAMI_HOME" <<<"$page" || true)" "0"
check "and ends with the commands" \
  "$(tail -1 <<<"$page")" 'More: `orgami query <name>` for one node, `orgami context --org` for the whole org.'

brief=$("$bin" brief web </dev/null)
check "brief names no path on this machine" "$(grep -c "$ORGAMI_HOME\|$home" <<<"$brief" || true)" "0"
check "and no DECISIONS.md before there is one" "$(grep -c 'DECISIONS' <<<"$brief" || true)" "0"
mkdir -p "$dir/map/decisions"
printf '# W44\n' >"$dir/map/DECISIONS.md"
check "once there is one, brief names it, bare" \
  "$("$bin" brief web </dev/null | tail -1)" "full page: orgami context · org: orgami context --org · why: DECISIONS.md in the map"

# coupling.json keeps every pair it counted and marks the graph-worthy ones.
cat >"$dir/map/coupling.json" <<'JSON'
{"pairs": [{"a": "web", "b": "docs", "weeks": 3, "days": 2, "authors": ["dana", "lee"], "stable": true},
           {"a": "web", "b": ".github", "weeks": 1, "days": 1, "authors": ["dana"], "stable": false}]}
JSON
page=$("$bin" context web </dev/null)
check "a stable pair is listed as changing together" "$(grep -c '^- \*\*docs\*\* — same day 2×' <<<"$page")" "1"
check "a pair one person made is not" "$(grep -c '^- \*\*\.github\*\*' <<<"$page" || true)" "0"
check "nor on the org page" \
  "$("$bin" context --org </dev/null | grep -c '\.github' || true)" "0"

exit "$fail"
