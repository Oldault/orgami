#!/usr/bin/env bash
# `linkify_prs` is what stands between a model writing prose and a docs
# repository getting a live GitHub link pushed into it. The guarantee AGENTS.md
# makes for it is not "the URL is assembled by code" — that much a bare regex
# over `org/repo#123` also gives you, and it is worthless: the model writes the
# shape, the regex turns the shape into a link, and `acme/totally-invented#99999`
# arrives in the weekly recap as something a reader can click. The guarantee is
# that the *reference* had to exist first, and the only offline record of what
# exists is map/graph.json.
#
# So what is pinned here is mostly what does NOT become a link: a repository the
# scan never saw, another organization's repository, and a repository name whose
# dot has been allowed to act as a wildcard. And that an unrecognised reference
# survives as plain text rather than being dropped — unlinked text makes no
# promise, but deleting it would hide that the model said it.
#
# Pure functions over stdin. No organization, no token, no network, no model.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

graph="$fixture/graph.json"

# Four repositories the scan saw, and a host — only `kind: "repo"` names may
# become a link. `web` and `web-ui` share a prefix on purpose, and
# `docs.example` carries the dot the pattern has to escape.
cat >"$graph" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-08-18T00:00:00Z",
 "nodes": [
   {"id": "repo:billing-api", "kind": "repo", "name": "billing-api"},
   {"id": "repo:web", "kind": "repo", "name": "web"},
   {"id": "repo:web-ui", "kind": "repo", "name": "web-ui"},
   {"id": "repo:docs.example", "kind": "repo", "name": "docs.example"},
   {"id": "host:api.example.com", "kind": "host", "name": "api.example.com"}],
 "edges": []}
JSON

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1" >&2
    echo "     expected: $3" >&2
    echo "     got:      $2" >&2
    fail=1
  fi
}

# linkify <text> — the function as the report and the playbook call it.
linkify() { linkify_prs acme "$graph" <<<"$1"; }

# --- what the map has seen becomes a link ------------------------------------

check "a bare org/repo reference to a repo in the graph becomes a link" \
  "$(linkify 'Shipped acme/billing-api#12 on Tuesday.')" \
  'Shipped [acme/billing-api#12](https://github.com/acme/billing-api/pull/12) on Tuesday.'

check "and the backticked form of it" \
  "$(linkify 'Shipped `acme/web#7` on Tuesday.')" \
  'Shipped [acme/web#7](https://github.com/acme/web/pull/7) on Tuesday.'

check "the short repo#N form the daily digest uses becomes a link" \
  "$(linkify 'Shipped billing-api#12 on Tuesday.')" \
  'Shipped [billing-api#12](https://github.com/acme/billing-api/pull/12) on Tuesday.'

check "and the backticked short form" \
  "$(linkify 'Shipped `web#7` on Tuesday.')" \
  'Shipped [web#7](https://github.com/acme/web/pull/7) on Tuesday.'

check "a reference at the start of a line is not missed" \
  "$(linkify 'billing-api#3 landed first.')" \
  '[billing-api#3](https://github.com/acme/billing-api/pull/3) landed first.'

check "a reference opening a parenthesis is not missed" \
  "$(linkify 'Reviewed (acme/web#9) twice.')" \
  'Reviewed ([acme/web#9](https://github.com/acme/web/pull/9)) twice.'

check "a longer repository name wins over the prefix it shares" \
  "$(linkify 'Shipped web-ui#4.')" \
  'Shipped [web-ui#4](https://github.com/acme/web-ui/pull/4).'

check "several references on one line are all linked" \
  "$(linkify 'web#1 then billing-api#2.')" \
  '[web#1](https://github.com/acme/web/pull/1) then [billing-api#2](https://github.com/acme/billing-api/pull/2).'

# A link that has just been written must not be walked over a second time: the
# repository name inside `[acme/web#1](…)` is preceded by a `/`, which is what
# keeps the short-form patterns off it.
check "a link is written once, not rewritten by the short-form pass" \
  "$(linkify 'acme/web#1')" \
  '[acme/web#1](https://github.com/acme/web/pull/1)'

# --- what the map has NOT seen stays as the model wrote it -------------------

# The bug this test exists for. A pure-shape regex answers this with a live link
# to an organization nobody has ever scanned.
check "an invented repository in the org stays plain text" \
  "$(linkify 'The team shipped acme/totally-invented#99999 last week.')" \
  'The team shipped acme/totally-invented#99999 last week.'

check "and its backticked form too" \
  "$(linkify 'Also `acme/totally-invented#99999`.')" \
  'Also `acme/totally-invented#99999`.'

check "an invented short reference stays plain text" \
  "$(linkify 'See totally-invented#5.')" \
  'See totally-invented#5.'

# The decision written down in lib/common.sh: an upstream pull request in
# somebody else's organization is a real thing a recap may mention, but nothing
# offline has seen it, so it is left as text rather than linked on shape alone.
check "another organization stays plain text" \
  "$(linkify 'Also `evil-org/malware#1`.')" \
  'Also `evil-org/malware#1`.'

check "even when the repository name is one this org has" \
  "$(linkify 'Upstream evil-org/billing-api#1 is unrelated.')" \
  'Upstream evil-org/billing-api#1 is unrelated.'

check "a host in the graph is not a repository" \
  "$(linkify 'Nothing at api.example.com#1 here.')" \
  'Nothing at api.example.com#1 here.'

# --- the dot in a repository name is a dot -----------------------------------

check "a repository name containing a dot is linked" \
  "$(linkify 'Shipped docs.example#8.')" \
  'Shipped [docs.example#8](https://github.com/acme/docs.example/pull/8).'

# If the dot were ever left unescaped this would become a link to a repository
# that does not exist — the wildcard failure the gsub in linkify_prs prevents.
check "and its dot does not act as a wildcard" \
  "$(linkify 'Shipped docsXexample#8.')" \
  'Shipped docsXexample#8.'

# --- text that says nothing about a pull request -----------------------------

prose='A paragraph with #12, a/b, issue 34 and https://github.com/acme/web/pull/2 in it.'
check "text with no reference passes through unchanged" \
  "$(linkify "$prose")" "$prose"

multi=$'## Heading\n\nA line.\n\n- a bullet\n'
check "and so does a multi-line body" "$(linkify "$multi")" "$(printf '%s' "$multi")"

# --- no graph to check against -----------------------------------------------

# Before the first scan there is no map. The function may not crash and may not
# link on shape alone either — it hands the text back as it arrived.
check "with no graph file the text passes through" \
  "$(linkify_prs acme "$fixture/absent.json" <<<'acme/web#1 and web#2')" \
  'acme/web#1 and web#2'

echo '{"nodes": [{"id": "host:h", "kind": "host", "name": "h"}], "edges": []}' \
  >"$fixture/norepos.json"
check "a graph holding no repositories passes through" \
  "$(linkify_prs acme "$fixture/norepos.json" <<<'acme/web#1 and web#2')" \
  'acme/web#1 and web#2'

echo 'not json at all' >"$fixture/broken.json"
check "an unreadable graph passes through rather than dying" \
  "$(linkify_prs acme "$fixture/broken.json" <<<'acme/web#1')" \
  'acme/web#1'

# --- the organization is taken from the config, not assumed ------------------

check "an org with a dot in it is matched literally" \
  "$(linkify_prs 'acme.io' "$graph" <<<'Shipped acme.io/web#5.')" \
  'Shipped [acme.io/web#5](https://github.com/acme.io/web/pull/5).'

check "and its dot is not a wildcard either" \
  "$(linkify_prs 'acme.io' "$graph" <<<'Shipped acmeXio/web#5.')" \
  'Shipped acmeXio/web#5.'

exit "$fail"
