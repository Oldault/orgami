#!/usr/bin/env bash
# `orgami review --auto --merge` squash-merges a whole pull request on a model's
# word, so it may only merge what it actually read: a branch from the docs repo
# itself, touching nothing but notes, fetched at the commit gh says it is at.
# A fork, a branch that would not fetch, or a pull request that also changes a
# workflow is left for a person. A pull request gh reports as deletions only is
# merged without a model. And the verdict ids the model sends back become paths
# that are moved and deleted, so an id that is not one of the pull request's own
# note files touches nothing.
#
# Stub `gh`, `git` and `claude`. No network, no repository, no push.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture/acme"
mkdir -p "$DIR/notes" "$fixture/bin" "$fixture/work"
echo '{"org":"acme","docs_repo":"git@github.com:acme/orgami-reports.git","docs_path":"orgami"}' \
  >"$DIR/config.json"

# gh answers `pr view` from $PR_JSON and the REST file list from $FILES_JSON, in
# the shapes real gh returns, and logs every call; git fetches unless
# told not to and shows note text for any path; claude replies with $VERDICTS.
cat >"$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case "$1 $2" in
  "pr view") cat "$PR_JSON" ;;
  "api --paginate") cat "$FILES_JSON" ;;
  "pr merge" | "pr comment" | "pr close") exit 0 ;;
  *) exit 1 ;;
esac
STUB
cat >"$fixture/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ $1 == -C ]] && shift 2
echo "git $*" >>"$CALLS"
case $1 in
  fetch) [[ ${FETCH:-ok} == ok ]] ;;
  rev-parse) echo "${FETCHED_OID:-abc123}" ;;
  show) printf -- '---\nid: %s\nauthor: t\n---\n\na note\n' "$(basename "${2#*:}" .md)" ;;
  *) exit 0 ;;
esac
STUB
cat >"$fixture/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ $* == *--help* ]] && exit 0
cat >/dev/null
cat "$VERDICTS"
STUB
chmod +x "$fixture/bin/"*
PATH="$fixture/bin:$PATH"
export CALLS="$fixture/calls.log" PR_JSON="$fixture/pr.json" FILES_JSON="$fixture/files.json"
export VERDICTS="$fixture/verdicts.json"

fail() { echo "notes_review_auto: $*" >&2; exit 1; }

# pr <isCrossRepository> <REST files json> [changedFiles]. `pr view` carries no
# file list at all here, so nothing can pass by reading the capped one.
pr() {
  jq -n --argjson cross "$1" --argjson files "$2" --arg count "${3:-}" '
    {headRefName: "orgami-notes/t", headRefOid: "abc123", isCrossRepository: $cross,
     changedFiles: (if $count == "" then ($files | length) else ($count | tonumber) end)}' >"$PR_JSON"
  printf '%s\n' "$2" >"$FILES_JSON"
}
deleted='[{"filename":"orgami/notes/old.md","status":"removed","additions":0,"deletions":5}]'

run() {
  : >"$CALLS"
  OUT=$(review_auto "$fixture/work" 7 1 2>"$fixture/err") || fail "review_auto exited $? ($(cat "$fixture/err"))"
  ERR=$(cat "$fixture/err")
}
merged() { grep -q '^pr merge' "$CALLS"; }

# --- a fork ---------------------------------------------------------------------

pr true "$deleted"
run
merged && fail "a pull request from a fork was merged"
grep -q 'fork' <<<"$ERR" || fail "a fork should be named as the reason, got '$ERR'"

# --- a branch that would not fetch ---------------------------------------------

pr false '[{"filename":"orgami/notes/new.md","status":"added","additions":5,"deletions":0}]'
FETCH=fail run
merged && fail "a pull request whose branch would not fetch was merged"
grep -q 'could not fetch' <<<"$ERR" || fail "the failed fetch should be said, got '$ERR'"
grep -q '^git show' "$CALLS" && fail "nothing should be read from a branch that did not fetch"

# --- fetched, but not at the commit gh reported ---------------------------------

pr false "$deleted"
FETCHED_OID=def456 run
merged && fail "a branch that moved after it was read was merged"

# --- a pull request that changes more than notes --------------------------------

pr false '[{"filename":"orgami/notes/old.md","status":"removed","additions":0,"deletions":5},
           {"filename":".github/workflows/ci.yml","status":"modified","additions":3,"deletions":0}]'
run
merged && fail "a pull request that also changes a workflow was merged"
grep -q 'more than notes' <<<"$ERR" || fail "the non-note file should be the reason, got '$ERR'"

# --- a workflow renamed into notes/ ----------------------------------------------

pr false '[{"filename":"orgami/notes/x.md","status":"renamed","additions":0,"deletions":0,
            "previous_filename":".github/CODEOWNERS"}]'
run
merged && fail "a rename out of .github/ into notes/ was merged"
grep -q 'more than notes (.github/CODEOWNERS)' <<<"$ERR" || fail "the old path should be the reason, got '$ERR'"

# --- more files than the list shows ----------------------------------------------

pr false "$deleted" 101
run
merged && fail "a pull request with files missing from the list was merged"
grep -q 'could not list every file' <<<"$ERR" || fail "the short list should be the reason, got '$ERR'"

# --- a deletion gh does not call a deletion -------------------------------------

pr false '[{"filename":"orgami/notes/old.md","status":"modified","additions":0,"deletions":5}]'
echo '{"verdicts":[],"summary":""}' >"$VERDICTS"
run
merged && fail "a modified note with no verdict was merged as a removal"

# --- a genuine removal, from the docs repo itself ------------------------------

pr false "$deleted"
run
merged || fail "a deletion-only pull request from the same repo was not merged ($ERR)"
grep -q -- '--match-head-commit abc123' "$CALLS" ||
  fail "the merge should be pinned to the commit that was read, got '$(grep '^pr merge' "$CALLS")'"
grep -q 'removals only' <<<"$OUT" || fail "the merge should say it was removals only, got '$OUT'"

# --- verdict ids the pull request does not hold ---------------------------------

echo 'a file the reviewer must not reach' >"$fixture/acme/victim.md"
echo 'kept' >"$DIR/notes/other.md"
pr false '[{"filename":"orgami/notes/20260820-101010-t-new.md","status":"added","additions":5,"deletions":0}]'
cat >"$VERDICTS" <<'JSON'
{"verdicts": [
  {"id": "../victim", "verdict": "reject", "reason": "x"},
  {"id": "other", "verdict": "reject", "reason": "x"},
  {"id": "20260820-101010-t-new", "verdict": "approve", "reason": "fine"}],
 "summary": "s"}
JSON
cmd_sync() { echo "cmd_sync $*" >>"$CALLS"; }
run
[[ -f $fixture/acme/victim.md ]] || fail "a verdict id with ../ deleted a file outside notes/"
[[ -f $DIR/notes/other.md ]] || fail "a verdict for a note not in the pull request held it back"
grep -q "ignoring a verdict for '../victim'" <<<"$ERR" || fail "the bad id should be logged, got '$ERR'"
grep -q "ignoring a verdict for 'other'" <<<"$ERR" || fail "the foreign id should be logged, got '$ERR'"
merged || fail "the one note in the pull request was approved, so it should merge ($ERR)"

# --- a note in the pull request that got no verdict -----------------------------

echo '{"verdicts":[{"id":"../victim","verdict":"approve","reason":"x"}],"summary":""}' >"$VERDICTS"
run
merged && fail "a pull request whose note got no verdict was merged"
grep -q 'no verdict for' <<<"$ERR" || fail "the unreviewed note should be named, got '$ERR'"

# --- a new note and an archived one on the same branch ---------------------------

pr false '[{"filename":"orgami/notes/20260820-101010-t-new.md","status":"added","additions":5,"deletions":0},
           {"filename":"orgami/notes/old.md","status":"removed","additions":0,"deletions":5}]'
echo '{"verdicts":[{"id":"20260820-101010-t-new","verdict":"approve","reason":"fine"}],"summary":""}' >"$VERDICTS"
run
grep -q 'old.md' <(grep '^git show' "$CALLS") && fail "a removed note was read from the branch"
merged || fail "an approved note alongside a removal should merge ($ERR)"

echo "notes_review_auto: forks, unfetched or moved branches, non-note files and stray verdict ids never merge"
