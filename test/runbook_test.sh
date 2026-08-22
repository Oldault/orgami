#!/usr/bin/env bash
# A runbook is the document an agent reads immediately before acting on a
# repository, and it makes a claim about itself in its own body: "Nothing here
# was written by a model." That claim is falsifiable, so it is tested here — a
# stub `claude`, `gh`, `curl` and `wget` sit first on PATH and record any call,
# and the render has to produce the whole document without touching one.
#
# The rest is what a reader has to be able to trust: a quoted note carries the
# author and date that lead back to the note, a tag lands under the heading it
# is supposed to, a heading never appears with nothing under it, and — the part
# that separates a runbook admitting a gap from one that reads as complete — the
# three sentences the generator prints when it cannot know are exact.
#
# Runs against a hand-written ORGAMI_HOME in a temp directory. No organization,
# no token, no network, no model, and nothing written outside the temp
# directory.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the libraries, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh
# shellcheck source=../lib/runbook.sh
source lib/runbook.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
# ORGAMI_HOME points into the fixture too: nothing here may write to a real one.
ORGAMI_HOME="$fixture/home"
# shellcheck disable=SC2034  # COMPANY is read by the library, not by this test
COMPANY=acme
# shellcheck disable=SC2034  # ORG is read by the library, not by this test
ORG=acme
mkdir -p "$DIR/notes" "$DIR/map/decisions" "$DIR/reports" "$DIR/cache/prs" \
  "$ORGAMI_HOME" "$fixture/bin"

fail() { echo "runbook: $*" >&2; exit 1; }

# --- nothing here was written by a model -------------------------------------
#
# The header of lib/runbook.sh says no model writes any of this, and the render
# prints the same claim into its own output. A stub that records the call and
# fails is the only way to hold either one to it.
for cmd in claude gh curl wget; do
  cat >"$fixture/bin/$cmd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$cmd \$*" >>"$fixture/reached"
exit 1
EOF
  chmod +x "$fixture/bin/$cmd"
done
PATH="$fixture/bin:$PATH"

# --- the fixture organization -------------------------------------------------
#
# Three repositories, each one a branch of the generator: `bare` declares
# nothing at all, `gated` has CI that never deploys, and `web` has everything —
# so the sections that exist only when there is something to say are all
# reachable in one render.
cat >"$DIR/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-08-18T00:00:00Z",
 "nodes": [
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {}},
   {"id": "repo:billing", "kind": "repo", "name": "billing", "meta": {}},
   {"id": "repo:bare", "kind": "repo", "name": "bare", "meta": {}},
   {"id": "repo:gated", "kind": "repo", "name": "gated", "meta": {}},
   {"id": "host:shop.acme.com", "kind": "host", "name": "shop.acme.com", "meta": {}},
   {"id": "service:postgres", "kind": "service", "name": "postgres", "meta": {}}],
 "edges": [
   {"from": "repo:web", "to": "host:shop.acme.com", "kind": "deploys-to",
    "evidence": "fly.toml", "confidence": "extracted"},
   {"from": "repo:web", "to": "service:postgres", "kind": "depends-on",
    "evidence": "docker-compose.yml", "confidence": "extracted"},
   {"from": "repo:web", "to": "repo:billing", "kind": "calls",
    "evidence": "src/pay.ts:31", "confidence": "extracted"}]}
JSON

cat >"$DIR/map/repos.json" <<'JSON'
[{"name": "bare",
  "meta": {"language": "Ruby", "private": false},
  "frameworks": [], "commands": {"scripts": {}}, "env": [],
  "workflows": [], "routes": [], "serves": [], "agent_docs": []},
 {"name": "gated",
  "meta": {"language": "Go", "private": true},
  "frameworks": [], "commands": {"scripts": {}}, "env": [],
  "workflows": [
    {"name": "CI", "file": ".github/workflows/ci.yml", "on": ["pull_request"], "deploys": false},
    {"name": "nightly", "file": ".github/workflows/nightly.yml", "on": ["schedule"], "deploys": false}],
  "routes": [], "serves": [], "agent_docs": []},
 {"name": "web",
  "meta": {"language": "TypeScript", "private": false, "description": "the storefront",
           "url": "https://github.com/acme/web", "default_branch": "main"},
  "frameworks": ["Next.js"],
  "commands": {"runtime": "node 22", "package_manager": "pnpm",
               "scripts": {"dev": "next dev", "test": "vitest", "build": "next build",
                           "lint": "eslint .", "seed": "node scripts/seed.js"},
               "procfile": ["web"]},
  "env": ["DATABASE_URL", "SENTRY_DSN", "STRIPE_KEY"],
  "workflows": [
    {"name": "CI", "file": ".github/workflows/ci.yml", "on": ["pull_request"], "deploys": false},
    {"name": "deploy", "file": ".github/workflows/deploy.yml", "on": ["push"],
     "deploys": true, "environment": "production"}],
  "routes": ["/healthz", "/checkout"], "serves": ["shop.acme.com"],
  "agent_docs": ["AGENTS.md"]}]
JSON

# One note per runbook tag, so the whole tag-to-heading table is exercised —
# plus a tag nobody defined, and a note on another repository.
note() { # note <id> <date> <repo> <tags> <body>
  cat >"$DIR/notes/$1.md" <<EOF
---
id: $1
author: tester
date: $2
repo: $3
tags: [$4]
---

$5
EOF
}

note 20260810-090000-a 2026-08-10T09:00:00Z web setup \
  "Copy .env.example first; the app crashes on a missing DATABASE_URL rather than reporting it."
note 20260811-090001-b 2026-08-11T09:00:00Z web deploy \
  "Deploys drain connections for 30 seconds, so two in a row will queue."
note 20260812-090002-c 2026-08-12T09:00:00Z web rollback \
  "Roll back with the previous image tag; reverting the branch rebuilds and takes twenty minutes."
note 20260813-090003-d 2026-08-13T09:00:00Z web incident \
  "Sessions vanished when Redis evicted under memory pressure."
note 20260814-090004-e 2026-08-14T09:00:00Z web alert \
  "Checkout latency pages at p95; check the payment provider status page before the app."
note 20260815-090005-f 2026-08-15T09:00:00Z web gotcha \
  "The build cache lies after a lockfile bump."
note 20260816-090006-g 2026-08-16T09:00:00Z web oncall \
  "Page the platform rota, not the app team."
note 20260817-090007-h 2026-08-17T09:00:00Z web quokka \
  "A tag nobody defined, which must not become a heading."
note 20260818-090008-i 2026-08-18T09:00:00Z billing gotcha \
  "Another repository's trap, which must not reach this runbook."

cat >"$DIR/map/decisions/2026-W33.md" <<'MD'
# Decisions

- Checkout stays server-rendered — acme/web#41
- Billing owns the ledger schema — acme/billing#12
MD

cat >"$DIR/reports/2026-W33.md" <<'MD'
# 2026-W33

## What got fixed

- Sessions dropped under memory pressure — acme/web#123
- A rounding error in invoices — acme/billing#77

## Action required

- Rotate the Stripe key before September — acme/web#124

## Something else
MD

cat >"$DIR/cache/prs/2026-W33.json" <<'JSON'
{"prs": [
  {"number": 123, "author": {"login": "tester"}, "repository": {"name": "web"}},
  {"number": 124, "author": {"login": "tester"}, "repository": {"name": "web"}},
  {"number": 77, "author": {"login": "other"}, "repository": {"name": "billing"}}
]}
JSON

# --- the renders --------------------------------------------------------------

web=$(runbook_render web)
bare=$(runbook_render bare)
gated=$(runbook_render gated)

[[ -f $fixture/reached ]] &&
  fail "the render called $(head -1 "$fixture/reached") — a runbook is derived, not written"

# Nothing outside the temp directory. `notes_author` writes a config the moment
# it is asked for an author, and a runbook must never be the thing that asks.
[[ -z $(find "$ORGAMI_HOME" -mindepth 1 2>/dev/null) ]] ||
  fail "the render wrote into ORGAMI_HOME"

# --- 1. the provenance line ---------------------------------------------------

generated=$(jq -r '.generated | .[0:10]' "$DIR/map/graph.json")
want="<sub>Derived from the scan of $generated. Nothing here was written by a model.</sub>"
for doc in "$web" "$bare" "$gated"; do
  grep -qxF -- "$want" <<<"$doc" ||
    fail "the provenance line is missing or does not name the scan date: want '$want'"
done

# --- 2. every quoted note leads back to the note ------------------------------
#
# A quote a reader cannot trace is the thing this repository's evidence rule
# exists to prevent. The handle is the author and the note's own date, not the
# note id: the note is reproduced whole, so the quote is the record, and an id
# is what `playbook_notes` prints because a playbook's prose stands in for the
# note instead of repeating it. So this asserts the decision, not merely what
# the code happens to do — both halves of the attribution have to match the
# note the quote came from, read back through `notes_index`.
tags_json=$(printf '%s\n' "${RUNBOOK_TAGS[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
quoted=0
while IFS=$'\t' read -r author date body; do
  [[ -n $body ]] || continue
  quoted=$((quoted + 1))
  # `|| true` because a note that was not quoted at all is a failure with a
  # message, not a pipeline that dies under `pipefail` saying nothing.
  quote=$(grep -F -A1 -- "- $body" <<<"$web" || true)
  [[ -n $quote ]] || fail "a note tagged for a runbook section was not quoted: $body"
  attribution=$(tail -1 <<<"$quote")
  [[ $attribution == "  <sub>$author, ${date:0:10}</sub>" ]] ||
    fail "a quoted note lost its attribution: expected '  <sub>$author, ${date:0:10}</sub>', got '$attribution'"
done < <(notes_index | jq -r --argjson t "$tags_json" --arg r web '
  .[] | select(.repo == $r)
  | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | any(. as $x | $t | index($x)))
  | [.author, .date, (.body | gsub("^\\n+"; "") | gsub("\\n+$"; ""))] | @tsv')
[[ $quoted == 7 ]] || fail "expected 7 tagged notes to be quoted, walked $quoted"

grep -q "Another repository's trap" <<<"$web" &&
  fail "a note on another repository reached this runbook"

# --- 3. the tag-to-heading map holds ------------------------------------------

section() { # section <heading> <doc>
  awk -v h="## $1" '$0 == h { on = 1; next } /^## / { on = 0 } /^---$/ { on = 0 } on' <<<"$2"
}

check_tag() { # check_tag <tag> <heading> <phrase from the note>
  local got
  got=$(runbook_tag_heading "$1")
  [[ $got == "$2" ]] || fail "tag '$1' should head '$2', got '$got'"
  grep -q -- "$3" <<<"$(section "$2" "$web")" ||
    fail "the note tagged '$1' is not under '## $2'"
}

check_tag setup    "Getting it running"   "Copy .env.example first"
check_tag deploy   "Deploying it"         "drain connections for 30 seconds"
check_tag rollback "Rolling it back"      "previous image tag"
check_tag incident "When it broke before" "Redis evicted under memory pressure"
check_tag alert    "When an alert fires"  "check the payment provider status page"
check_tag gotcha   "Traps"                "build cache lies after a lockfile bump"
check_tag oncall   "Who to reach"         "Page the platform rota"

# A person who has rolled it back knows better than the workflow: their note
# replaces the derived paragraph rather than sitting beside it.
grep -q "Derived from the workflow, not from anyone having done it" <<<"$web" &&
  fail "a rollback note must replace the derived rollback, not join it"

# An unknown tag falls through to itself and stays a plain note. Inventing a
# section for it would put a heading on something nobody filed under one.
got=$(runbook_tag_heading quokka)
[[ $got == quokka ]] || fail "an unknown tag should head itself, got '$got'"
grep -q "A tag nobody defined" <<<"$web" &&
  fail "an unknown tag became a runbook section"

# --- 4. the three absence sentences -------------------------------------------
#
# These are the "say what the tool cannot know" rule, in the three places a
# reader would otherwise read silence as completeness. They are asserted
# verbatim: a rewording that hedges is the failure this guards against.
no_commands="No run or test command is declared in the repository."
no_ci="There is no CI in this repository at all. How it reaches production is not recorded here — if you know, record it with \`orgami note --tag deploy\`."
no_deploy="No workflow in this repository deploys. CI runs $(jq -r '[.[] | select(.name == "gated") | .workflows[].name] | join(", ")' "$DIR/map/repos.json"), but shipping happens somewhere this scan cannot see — record it with \`orgami note --tag deploy\`."

grep -qxF -- "$no_commands" <<<"$bare" ||
  fail "a repository declaring no scripts must say so: want '$no_commands'"
grep -qxF -- "$no_ci" <<<"$bare" ||
  fail "a repository with no CI must say so: want '$no_ci'"
grep -qxF -- "$no_deploy" <<<"$gated" ||
  fail "CI that never deploys must say so, and name the CI: want '$no_deploy'"

# The two are alternatives, not a pair: a repository with CI is never told it
# has none, and one with none is never told its CI does not deploy.
grep -qF -- "$no_ci" <<<"$gated" && fail "a repository with CI was told it has none"
grep -qF -- "No workflow in this repository deploys" <<<"$bare" &&
  fail "a repository with no CI was told its CI does not deploy"

# A repository that ships and answers nowhere is the third silence: it has no
# health endpoint to list, and the section says that instead of listing none.
grep -q "Whatever tells you it is up lives somewhere this scan cannot see" <<<"$web" &&
  fail "web serves /healthz, so it must be listed rather than declared missing"

# --- 5. no heading with nothing under it --------------------------------------
#
# `## Run it` and `## How it ships` are unconditional on purpose: they always
# say something, including when the answer is that nothing was found. Every
# other section exists only when it has content. The rule that covers both is
# that a heading is never printed with nothing beneath it.
empty_sections() {
  awk '
    /^## / { if (h != "" && c == 0) print h; h = $0; c = 0; next }
    /^---$/ { if (h != "" && c == 0) print h; h = ""; c = 0; next }
    NF { if (h != "") c = 1 }
    END { if (h != "" && c == 0) print h }'
}

for name in web bare gated; do
  empty=$(empty_sections <<<"${!name}")
  [[ -z $empty ]] || fail "$name has an empty section: $(tr '\n' ' ' <<<"$empty")"
done

# The two that are unconditional, on the repository that declares nothing.
for heading in "## Run it" "## How it ships"; do
  grep -qxF -- "$heading" <<<"$bare" ||
    fail "'$heading' must be printed even when the answer is that nothing was found"
done

# And the ones that are not: nothing in `bare` feeds them, so they are absent
# rather than present and empty.
for heading in "## Rolling it back" "## Where it lives" "## Is it alive" \
  "## What it drags with it" "## Do not" "## Seen before" "## Traps" "## House rules"; do
  grep -qxF -- "$heading" <<<"$bare" &&
    fail "'$heading' has nothing behind it in a bare repository and must not be printed"
done

# The same sections, on the repository that does feed them — otherwise the
# check above passes because they were never generated at all.
for heading in "## Rolling it back" "## Where it lives" "## Is it alive" \
  "## What it drags with it" "## Do not" "## Seen before" "## House rules"; do
  grep -qxF -- "$heading" <<<"$web" ||
    fail "'$heading' is fed by the fixture and must be printed"
done

# What those sections carry, since an empty-heading check alone would pass on a
# section that prints one wrong line.
grep -q 'Rotate the Stripe key before September — acme/web#124' <<<"$(section "Do not" "$web")" ||
  fail "an action-required line naming this repo belongs under 'Do not'"
grep -q 'Sessions dropped under memory pressure — acme/web#123' <<<"$(section "Seen before" "$web")" ||
  fail "a recorded failure naming this repo belongs under 'Seen before'"
grep -q 'A rounding error in invoices' <<<"$web" &&
  fail "another repository's recorded failure reached this runbook"

echo "runbook: quotes traceable, tags placed, absence stated, no empty headings, no model"
