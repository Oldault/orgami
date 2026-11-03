#!/usr/bin/env bash
# Two ways `orgami doc` could publish something nobody wrote into the map:
#
#   1. A committed symlink in a checkout. `AGENTS.md -> ~/.config/gh/hosts.yml`
#      read as the repo's agent instructions would copy the scanning user's
#      token into CONVENTIONS.md, which publish pushes. A link that leaves its
#      checkout — directly, through a chain, or through a linked directory — is
#      never read; one that stays inside (CLAUDE.md -> AGENTS.md) still is. The
#      scan removes the bad links, and doc refuses them on its own as well, for
#      a cache written before that.
#   2. A company or org name used as a sed program. ASK-CLAUDE.md takes both
#      literally, `|`, `&` and `\` included.
#
# Fixture checkouts under a temp ORGAMI_HOME. No clone, no network, no model.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Read by doc_conventions, which sources lib/profile.sh through it.
# shellcheck disable=SC2034
ROOT=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() { [[ $2 == "$3" ]] || { echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; }; }

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh
# shellcheck source=../lib/profile.sh
source lib/profile.sh
# shellcheck source=../lib/doc.sh
source lib/doc.sh

secret="SECRET-TOKEN-$$"
mkdir -p "$tmp/outside"
echo "oauth_token: $secret" >"$tmp/secret.yml"
printf '# Architecture\n%s\n' "$secret" >"$tmp/outside/ARCHITECTURE.md"
printf '{"dependencies": {"next": "1", "x": "%s"}}\n' "$secret" >"$tmp/outside/package.json"

COMPANY=acme ORG=acme DIR="$tmp/acme"
src="$DIR/cache/src"
mkdir -p "$src/evil" "$src/good" "$src/.github" "$DIR/map"

# evil: every way out of the checkout.
ln -s "$tmp/secret.yml" "$src/evil/AGENTS.md"
ln -s AGENTS.md "$src/evil/CLAUDE.md"
ln -s ../../../../secret.yml "$src/evil/CONTRIBUTING.md"
ln -s "$tmp/outside" "$src/evil/docs"
ln -s "$tmp/outside/package.json" "$src/evil/package.json"
ln -s "$tmp/nowhere" "$src/evil/.cursorrules"
mkdir -p "$src/evil/.git"
echo '[remote "origin"]' >"$src/evil/.git/config"
ln -s .git/config "$src/evil/ARCHITECTURE.md"
ln -s "$tmp/secret.yml" "$src/.github/AGENTS.md"

# good: a real file, and a link that stays inside.
printf '# Good\nRun make test.\n' >"$src/good/AGENTS.md"
ln -s AGENTS.md "$src/good/CLAUDE.md"

# --- doc on a cache the scan never cleaned -----------------------------------

jq -n '[{name: "evil", agent_docs: ["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "docs/ARCHITECTURE.md"]},
        {name: "good", agent_docs: ["AGENTS.md", "CLAUDE.md"]}]' >"$DIR/map/repos.json"
doc_conventions 2>/dev/null
conv="$DIR/map/CONVENTIONS.md"
if grep -q "$secret" "$conv"; then echo "FAIL CONVENTIONS.md quotes a file outside the checkout" >&2; fail=1; fi
grep -q 'Run make test.' "$conv" || { echo "FAIL the real AGENTS.md is missing" >&2; fail=1; }
grep -q '`good/CLAUDE.md`' "$conv" || { echo "FAIL a link inside the checkout was refused" >&2; fail=1; }
if grep -q 'evil/' "$conv"; then echo "FAIL an escaping link got a section" >&2; fail=1; fi

# --- the helpers, one case each ----------------------------------------------

clone_file "$src/good" "$src/good/CLAUDE.md" || { echo "FAIL inside link refused" >&2; fail=1; }
for f in AGENTS.md CLAUDE.md CONTRIBUTING.md docs/ARCHITECTURE.md package.json .cursorrules ARCHITECTURE.md; do
  if clone_file "$src/evil" "$src/evil/$f"; then echo "FAIL clone_file allowed evil/$f" >&2; fail=1; fi
done

# --- what the scan does to the checkout --------------------------------------

check "profile_docs before the scan cleans up" "$(profile_docs "$src/evil" | jq -c .)" '[]'
scan_defuse_links "$src/evil"
scan_defuse_links "$src/good"
check "every escaping link is gone" "$(find "$src/evil" -path "$src/evil/.git" -prune -o -type l -print | wc -l | tr -d ' ')" 0
[[ -L $src/good/CLAUDE.md ]] || { echo "FAIL the inside link was removed" >&2; fail=1; }
[[ -e $tmp/secret.yml && -f $tmp/outside/package.json ]] ||
  { echo "FAIL removing a link touched its target" >&2; fail=1; }
check "a linked package.json is not read" "$(profile_framework "$src/evil" | jq -c .)" '[]'
check "profile_docs keeps the inside link" "$(profile_docs "$src/good" | jq -c .)" '["AGENTS.md","CLAUDE.md"]'

# --- ASK-CLAUDE.md takes the names literally ---------------------------------

echo '{"org": "acme"}' >"$DIR/config.json"
# shellcheck disable=SC2034 # read by doc_ask_claude
COMPANY='Ac|me & \1 co' ORG=acme
doc_ask_claude 2>/dev/null
ask="$DIR/map/ASK-CLAUDE.md"
grep -qF '"Ac|me & \1 co engineering"' "$ask" || { echo "FAIL the company name was not kept literally" >&2; fail=1; }
grep -qF 'organisation `acme`' "$ask" || { echo "FAIL the org was not substituted" >&2; fail=1; }
if grep -q '__COMPANY__\|__ORG__' "$ask"; then echo "FAIL a placeholder is left" >&2; fail=1; fi

exit $fail
