#!/usr/bin/env bash
# `orgami prune --superseded` on a notes directory where no note supersedes
# another used to die with a bare exit 1 and not one line of output: `grep`
# exits 1 when it matches nothing, and bin/orgami runs under `set -euo
# pipefail`. Nothing to prune is the ordinary state — the state a person is in
# when they run a cleanup command just to check — so the command has to say so
# and leave with 0. And when a note does carry `supersedes:`, the dead note
# still has to move to the archive, which is the half a careless guard could
# break.
#
# End-to-end through bin/orgami against a disposable ORGAMI_HOME. No
# organization, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/acme/notes"
echo '{"default":"acme"}' >"$home/config.json"
echo '{"org":"acme"}' >"$home/acme/config.json"

fail() { echo "notes_prune: $*" >&2; exit 1; }

# --- nothing to prune ----------------------------------------------------------

printf -- '---\nauthor: test\ndate: 2026-08-20\n---\na plain note nothing supersedes\n' \
  >"$home/acme/notes/n1.md"

out=$(ORGAMI_HOME=$home ./bin/orgami prune --superseded 2>"$home/err") ||
  fail "with nothing to prune the command exited $? instead of 0"
grep -q '0 archived' <<<"$out" ||
  fail "stdout should still report the count, got '$out'"
grep -q 'nothing to prune' "$home/err" ||
  fail "the user has to be told there was nothing to prune, got '$(cat "$home/err")'"
[[ -f $home/acme/notes/n1.md ]] ||
  fail "a note nothing supersedes was moved"

# --- one superseded note -------------------------------------------------------

printf -- '---\nauthor: test\ndate: 2026-08-21\nsupersedes: n1\n---\nthe note that replaces n1\n' \
  >"$home/acme/notes/n2.md"

out=$(ORGAMI_HOME=$home ./bin/orgami prune --superseded 2>/dev/null) ||
  fail "with one superseded note the command exited $?"
grep -q 'archived n1' <<<"$out" ||
  fail "the superseded note should be named as archived, got '$out'"
[[ -f $home/acme/notes/archive/n1.md && ! -f $home/acme/notes/n1.md ]] ||
  fail "n1 should have moved to notes/archive"
[[ -f $home/acme/notes/n2.md ]] ||
  fail "the superseding note itself was pruned"

echo "notes_prune: nothing to prune says so and exits 0, a superseded note still moves"
