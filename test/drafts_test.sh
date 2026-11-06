#!/usr/bin/env bash
# `orgami drafts` asks about each draft in a terminal, and an agent or a timer
# has none. Interactive is a layer, so every answer the prompt takes is a flag
# too. What this pins:
#   - --help prints usage with no terminal;
#   - --list and --list --json show every note and decision draft with an id;
#   - --keep and --drop act on one id, for notes and decisions alike, and a
#     decision's id still names it after the bullets around it are gone;
#   - an id that names nothing, or tries to name a path, changes nothing;
#   - a kept note is screened again, and one that fails stays a draft;
#   - inside a checkout, the drafts are that checkout's company's.
#
# Against a temp ORGAMI_HOME, stdin from /dev/null. No organization, no token,
# no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "drafts: $*" >&2; exit 1; }

export HOME="$tmp/home" ORGAMI_HOME="$tmp/orgami" ORGAMI_AUTOUPDATE=0
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset ORGAMI_COMPANY
home="$ORGAMI_HOME/acme"
mkdir -p "$HOME" "$home/notes/draft" "$home/map/decisions/draft"
echo '{"default":"acme","author":"tester"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme"}' >"$home/config.json"
echo '[{"name":"api"}]' >"$home/map/repos.json"

o() { ./bin/orgami "$@" </dev/null; }

note=20261103-173955-tester-the-queue-drains-slowly
printf -- '---\nid: %s\nauthor: tester\ndate: 2026-11-03T17:39:55Z\nrepo: api\ntags: [gotcha]\nauto: true\n---\n\nThe queue drains slowly under load.\n' \
  "$note" >"$home/notes/draft/$note.md"
cat >"$home/map/decisions/draft/2026-W44.md" <<'MD'
## 2026-W44

- **Retries moved into the worker** — the API timed out under load. (acme/api#412)
- **Dropped Cypress for Playwright** — no reason recorded. (acme/web#98)
  a wrapped second line
MD

# --- --help and the refusal, with no terminal ---------------------------------------

out=$(o drafts --help) || fail "drafts --help exited $? with no terminal"
grep -q -- '--keep <id>' <<<"$out" || fail "--help should name --keep, got: $out"
out=$(o drafts 2>&1) && fail "the interactive review should refuse with no terminal"
grep -q 'orgami drafts --list' <<<"$out" || fail "the refusal should name --list, got: $out"

# --- --list ---------------------------------------------------------------------------

json=$(o drafts --list --json) || fail "drafts --list --json exited $?"
[[ $(jq length <<<"$json") == 3 ]] || fail "one note and two decisions should be listed, got: $json"
[[ $(jq -r '.[0] | "\(.kind) \(.id) \(.repo) \(.tags | join(","))"' <<<"$json") == "note $note api gotcha" ]] ||
  fail "the note entry is wrong: $(jq -c '.[0]' <<<"$json")"
[[ $(jq -r '.[0].text' <<<"$json") == "The queue drains slowly under load." ]] ||
  fail "the note text should be its body, got: $(jq -r '.[0].text' <<<"$json")"
retries=$(jq -r '.[] | select(.kind == "decision" and (.text | test("Retries"))) | .id' <<<"$json")
cypress=$(jq -r '.[] | select(.kind == "decision" and (.text | test("Cypress"))) | .id' <<<"$json")
[[ $retries == 2026-W44.* && $cypress == 2026-W44.* && $retries != "$cypress" ]] ||
  fail "each decision needs an id of its own, got '$retries' and '$cypress'"
jq -e '.[] | select(.id == "'"$cypress"'") | .text | test("wrapped second line")' <<<"$json" >/dev/null ||
  fail "a wrapped bullet should keep its continuation line"

text=$(o drafts --list) || fail "drafts --list exited $?"
grep -qx "$note" <<<"$text" || fail "--list should print the note id on its own line, got: $text"
grep -qx "$retries" <<<"$text" || fail "--list should print each decision id, got: $text"

# --- --keep and --drop ----------------------------------------------------------------

o drafts --drop "$cypress" >/dev/null || fail "--drop of a decision exited $?"
! grep -q Cypress "$home/map/decisions/draft/2026-W44.md" || fail "the dropped decision is still in the draft"
# The id was taken before the other bullet went; it must still name its bullet.
o drafts --keep "$retries" >/dev/null || fail "--keep of a decision exited $? after its neighbour was dropped"
grep -q 'Retries moved' "$home/map/decisions/2026-W44.md" || fail "the kept decision did not reach the week's fragment"
grep -q '^## 2026-W44$' "$home/map/decisions/2026-W44.md" || fail "the fragment should open with its week"
[[ ! -f $home/map/decisions/draft/2026-W44.md ]] || fail "an emptied decisions draft should be removed"

o drafts --keep "$note" >/dev/null || fail "--keep of a note exited $?"
[[ -f $home/notes/$note.md && ! -f $home/notes/draft/$note.md ]] || fail "the kept note should move into notes/"
[[ $(o drafts --count) == 0 ]] || fail "nothing should be waiting, got $(o drafts --count)"
[[ $(o drafts --list) == "nothing waiting" ]] || fail "an empty --list should say so"
[[ $(o drafts --list --json) == "[]" ]] || fail "an empty --list --json should be []"

# --- ids that name nothing ----------------------------------------------------------

out=$(o drafts --drop no-such-draft 2>&1) && fail "--drop of an unknown id should fail"
grep -q "no draft 'no-such-draft'" <<<"$out" || fail "an unknown id should be named, got: $out"
o drafts --drop ../../config >/dev/null 2>&1 && fail "a path given as an id should name nothing"
[[ -f $ORGAMI_HOME/config.json && -f $home/config.json ]] || fail "a path given as an id removed a file"

# --- a kept note is screened again --------------------------------------------------

key="sk-ant-api03-$(printf 'AbCdEfGh1JkLmNoPqRsT%.0s' 1 2)"
printf -- '---\nid: leaky\nauthor: tester\n---\n\nthe key is %s\n' "$key" >"$home/notes/draft/leaky.md"
o drafts --keep leaky >/dev/null 2>&1 && fail "a draft carrying a key was kept"
[[ -f $home/notes/draft/leaky.md && ! -f $home/notes/leaky.md ]] || fail "a refused keep should leave the draft where it was"
o drafts --drop leaky >/dev/null || fail "--drop of the refused draft exited $?"

# --- the checkout's company ---------------------------------------------------------

mkdir -p "$ORGAMI_HOME/beta/notes/draft" "$tmp/checkout"
echo '{"org":"beta-org"}' >"$ORGAMI_HOME/beta/config.json"
printf -- '---\nid: b1\nauthor: tester\n---\n\na beta draft\n' >"$ORGAMI_HOME/beta/notes/draft/b1.md"
git -C "$tmp/checkout" init --quiet
git -C "$tmp/checkout" remote add origin git@github.com:beta-org/web.git
[[ $(cd "$tmp/checkout" && "$root/bin/orgami" drafts --count </dev/null) == 1 ]] ||
  fail "inside a beta checkout, beta's one draft should be counted"
[[ $(o drafts --count) == 0 ]] || fail "outside it, the default company's count should stand"

echo "drafts: --help and --list work headless, --keep and --drop act by id, unknown ids change nothing, keeps are screened"
