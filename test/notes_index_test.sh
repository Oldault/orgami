#!/usr/bin/env bash
# Every command that reads notes reads them through notes_index: notes, stale,
# notes --repo, the repo card, context, the runbooks and the playbooks. It used
# to build its JSON with printf, escaping only a quote, a backslash and a
# newline, so one tab in one note broke all of them for everyone it synced to.
# The note's repo is checked against the map, because a note filed under a typo
# never reaches the real repo's card and nothing tells its author. And `stale`
# and `notes` treat bad input and no notes the way the rest of the tool does.
#
# End-to-end through bin/orgami against a disposable ORGAMI_HOME. A stub `gh`
# that always fails stands in for the network. No docs repo, no model.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
orgami=$PWD/bin/orgami

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "notes_index: $*" >&2; exit 1; }

mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" ORGAMI_AUTOUPDATE=0 ORGAMI_COMPANY=acme
export ORGAMI_HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
mkdir -p "$ORGAMI_HOME/acme/map"
echo '{"default":"acme","author":"t"}' >"$ORGAMI_HOME/config.json"
jq -n '{org: "acme"}' >"$ORGAMI_HOME/acme/config.json"
jq -n '[{name: "shop-app"}, {name: "gatus"}, {name: "billing-api"}]' >"$ORGAMI_HOME/acme/map/repos.json"
notes="$ORGAMI_HOME/acme/notes"

run() { "$orgami" "$@" </dev/null; }

# --- no notes is a state, not a failure ----------------------------------------

out=$(run notes 2>&1) || fail "notes with no notes exited $?: $out"
[[ $out == "no notes yet"* ]] || fail "notes with no notes should say so: $out"
out=$(run stale 2>&1) || fail "stale with no notes exited $?: $out"

# --- stale wants a number --------------------------------------------------------

out=$(run stale abc 2>&1) && fail "stale abc succeeded: $out"
[[ $out == "orgami: days is a whole number"* ]] || fail "stale abc leaked something other than orgami's message: $out"
grep -q 'invalid date' <<<"$out" && fail "stale abc leaked date(1)'s error: $out"

# --- the repo a note names is one the map holds -----------------------------------

out=$(run note --repo zzz-typo 'filed under a typo' 2>&1) && fail "a note on a repo the map lacks was accepted"
grep -q "'zzz-typo' is not a repository in the acme map" <<<"$out" || fail "the refusal does not name the repo: $out"
grep -q 'leave --repo out' <<<"$out" || fail "the refusal gives no next step: $out"
out=$(run note --repo shopapp 'filed under a near miss' 2>&1) && fail "a near-miss repo name was accepted"
grep -q 'did you mean: shop-app' <<<"$out" || fail "the refusal does not offer the close name: $out"
[[ -z $(find "$notes" -name '*.md' 2>/dev/null) ]] || fail "a refused note was written anyway"

# GitHub names are case-insensitive, so a different case is the same repo,
# filed under the map's spelling.
f=$(run note --repo Shop-App 'case does not matter' 2>/dev/null) || fail "a case variant of a mapped repo was refused"
grep -qx 'repo: shop-app' "$f" || fail "the note should carry the map's spelling: $(grep '^repo:' "$f")"

# --- characters printf never escaped ----------------------------------------------

run note --repo shop-app "$(printf 'columns\tare\ttab separated')" >/dev/null 2>&1 || fail "a note with tabs was refused"
run note --repo gatus "$(printf 'a "quoted" \\ back\rslash \001 and a bell')" >/dev/null 2>&1 ||
  fail "a note with quotes, a backslash, a CR and a control character was refused"
# Hand-written: no trailing newline, a blank line in the frontmatter, a tab in a
# frontmatter value. A file arriving from a teammate is not shaped by orgami note.
printf -- '---\nid: hand\nauthor: them\n\ndate: 2026-01-02T00:00:00Z\nrepo: gatus\ntags: [gotcha,\tops]\n---\n\nwritten by hand, no newline at the end' \
  >"$notes/hand.md"

out=$(run notes 2>&1) || fail "notes exited $? with a tab in a note: $out"
for want in 'tab separated' 'quoted' 'written by hand' 'case does not matter'; do
  grep -q "$want" <<<"$out" || fail "notes lost the note containing '$want': $out"
done
out=$(run notes --repo shop-app 2>&1) || fail "notes --repo exited $?"
grep -q 'tab separated' <<<"$out" || fail "notes --repo lost the tab note: $out"
grep -q 'written by hand' <<<"$out" && fail "notes --repo shop-app showed a gatus note"
out=$(run stale 0 2>&1) || fail "stale exited $? with a tab in a note: $out"
grep -q '2026-01-02' <<<"$out" || fail "stale did not list the old hand-written note: $out"

# The parse itself, field by field, on every jq this tool supports.
# shellcheck disable=SC2034  # ROOT and DIR are read by the library
ROOT=$PWD DIR="$ORGAMI_HOME/acme"
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh
got=$(notes_parse "$notes/hand.md" | jq -c '{id, author, date, repo, tags, body}')
want='{"id":"hand","author":"them","date":"2026-01-02T00:00:00Z","repo":"gatus","tags":"[gotcha,\tops]","body":"\nwritten by hand, no newline at the end\n"}'
[[ $got == "$want" ]] || fail "notes_parse read the hand-written note as $got"
[[ $(notes_index | jq 'length') == 4 ]] || fail "notes_index should hold all four notes: $(notes_index | jq -c '[.[].id]')"

# --- notes --check flags a note on a repo the map does not hold ---------------------

out=$(run notes --check 2>&1) || fail "notes --check failed on notes that are all fine: $out"
printf -- '---\nid: stray\nauthor: them\ndate: 2026-01-03T00:00:00Z\nrepo: does-not-exist\n---\n\nstray\n' >"$notes/stray.md"
out=$(run notes --check 2>&1) && fail "notes --check passed a note on a repo the map does not hold"
grep -q "stray.md: repo 'does-not-exist' is not in the map" <<<"$out" || fail "notes --check did not name the note: $out"
grep -q 'orgami prune --id stray' <<<"$out" || fail "notes --check gives no next step: $out"

# --- the HTML page's notes go through the same parse --------------------------------

# shellcheck source=../lib/web.sh
source lib/web.sh
got=$(web_notes 2>&1 | jq -r 'length') || fail "web_notes broke on a tab or control character: $got"
[[ $got == 5 ]] || fail "web_notes should list all five notes, got $got"

# --- one parse for a loop over every repo ---------------------------------------------

NOTES_INDEX_CACHE=""
notes_index_hold "$tmp/held.json"
[[ $NOTES_INDEX_CACHE == "$tmp/held.json" ]] || fail "notes_index_hold did not point the cache at its file"
printf -- '---\nid: later\nauthor: them\ndate: 2026-01-04T00:00:00Z\nrepo: gatus\n---\n\nlater\n' >"$notes/later.md"
[[ $(notes_index | jq 'length') == 5 ]] || fail "a held index should not reparse"
NOTES_INDEX_CACHE=""
[[ $(notes_index | jq 'length') == 6 ]] || fail "with the cache cleared, notes_index should read the new note"
rm -f "$notes/later.md"

# --- an id is never empty-ended, and two in one second do not collide -----------------

# date answers the id's stamp with one fixed second, so both notes land in it.
realdate=$(command -v date)
mkdir -p "$tmp/clock"
cat >"$tmp/clock/date" <<EOF
#!/usr/bin/env bash
[[ \$* == "-u +%Y%m%d-%H%M%S" ]] && { echo 20260101-000000; exit 0; }
exec "$realdate" "\$@"
EOF
chmod +x "$tmp/clock/date"
a=$(PATH="$tmp/clock:$PATH" run note --repo gatus 'ここにメモ' 2>/dev/null) || fail "a note with no Latin letters was refused"
b=$(PATH="$tmp/clock:$PATH" run note --repo gatus 'ここにメモ' 2>/dev/null) || fail "the second note in the same second was refused"
[[ $(basename "$a") == 20260101-000000-t.md ]] || fail "a first line with no Latin letters should give no trailing dash: $(basename "$a")"
[[ $(basename "$b") == 20260101-000000-t-2.md ]] || fail "the second note in the same second should get -2: $(basename "$b")"
grep -qx 'id: 20260101-000000-t-2' "$b" || fail "the id in the front matter should match the file: $(grep '^id:' "$b")"
[[ $(grep -c 'ここにメモ' "$a" "$b" | grep -c ':1$') == 2 ]] || fail "the first note was overwritten by the second"

echo "notes_index: tabs and control characters parse, unknown repos refused and flagged, stale checks its number"
