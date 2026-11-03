#!/usr/bin/env bash
# `orgami note` refuses to write when the checkout it is run from belongs to
# another organization, because the repo it would infer is the wrong one. Its
# message says to pass --repo if that was meant, so --repo has to get past it:
# an agent working inside a client checkout names the repo outright.
#
# Under a temp HOME and ORGAMI_HOME, in a local git checkout. No network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "note_wrong_org: $*" >&2; exit 1; }

export HOME="$tmp/home" ORGAMI_HOME="$tmp/orgami" ORGAMI_COMPANY=acme
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$ORGAMI_HOME/acme/notes" "$ORGAMI_HOME/acme/map" "$tmp/checkout"
echo '{"default":"acme"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme","company":"acme"}' >"$ORGAMI_HOME/acme/config.json"
echo '[{"name":"api"}]' >"$ORGAMI_HOME/acme/map/repos.json"
git -C "$tmp/checkout" init --quiet
git -C "$tmp/checkout" remote add origin git@github.com:other/client.git

cd "$tmp/checkout"
if err=$("$root/bin/orgami" note "the queue drains slowly" 2>&1); then
  fail "a note from another org's checkout, with no --repo, was written"
fi
grep -q "belongs to 'other'" <<<"$err" || fail "the wrong org should be named, got '$err'"

err=$("$root/bin/orgami" note --repo api "the queue drains slowly" 2>&1) ||
  fail "--repo did not get past the checkout's org: $err"
grep -rqs 'repo: api' "$ORGAMI_HOME/acme/notes" || fail "the note was not filed under api: $err"
