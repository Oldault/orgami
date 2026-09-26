#!/usr/bin/env bash
# The decisions `orgami report` mines from a week's pull requests are model
# prose about to become the team's record, so they wait for a person the way a
# note drafted from a session does: in map/decisions/draft/, until `orgami
# drafts` keeps or drops each bullet. What this pins:
#   - report_decisions writes the draft, not the fragment, unless
#     notes_autopublish is on — the one setting that already sends model-written
#     text out unread;
#   - `orgami drafts` walks a draft bullet by bullet: kept ones land in the
#     week's fragment, dropped ones vanish, skipped ones stay in the draft, and
#     an emptied draft is removed;
#   - the assembler that writes DECISIONS.md never reads the draft folder.
#
# A stub `claude` answers the prompt and a stub `gum` pops answers off a queue.
# No organization, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "decisions_draft: $*" >&2; exit 1; }

export ORGAMI_HOME="$fixture/home"
export ORGAMI_COMPANY=acme
home="$ORGAMI_HOME/acme"
mkdir -p "$home/map" "$fixture/bin"
echo '{"default":"acme"}' >"$ORGAMI_HOME/config.json"
jq -n '{org: "acme"}' >"$home/config.json"
jq -n '{generated: "2026-08-18T06:00:00Z", nodes: [{id: "repo:api", kind: "repo", name: "api"}], edges: []}' >"$home/map/graph.json"

# The model: two durable decisions, in the shape prompts/decisions.md asks for.
cat >"$fixture/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
- **Retries moved into the worker** — the API timed out at 30 s under load. (acme/api#412)
- **Dropped Cypress for Playwright** — no reason recorded. (acme/web#98)
OUT
STUB
# gum: `choose` pops the next answer off the queue; `style` prints its text.
cat >"$fixture/bin/gum" <<'STUB'
#!/usr/bin/env bash
case $1 in
  choose) IFS= read -r a <"$GUM_QUEUE" || exit 1
          sed -i '1d' "$GUM_QUEUE"; echo "$a" ;;
  style)  shift; while [[ ${1:-} == --* ]]; do shift; done; echo "$*" ;;
  *) : ;;
esac
STUB
chmod +x "$fixture/bin/claude" "$fixture/bin/gum"
export PATH="$fixture/bin:$PATH"
export GUM_QUEUE="$fixture/queue"

# --- report_decisions holds the week ------------------------------------------------

digest=$(mktemp); echo '[]' >"$digest"
run_report() {
  (
    source "$ROOT/lib/common.sh"
    load_company
    source "$ROOT/lib/report.sh"
    report_decisions 2026-W34 "$digest" stub
  )
}
run_report 2>"$fixture/err"
[[ -f $home/map/decisions/draft/2026-W34.md ]] ||
  fail "the week's decisions should wait in map/decisions/draft/, got: $(ls -R "$home/map/decisions")"
[[ ! -f $home/map/decisions/2026-W34.md ]] ||
  fail "with drafts held, the fragment itself must not be written"
grep -q "2 decision(s) drafted for 2026-W34" "$fixture/err" ||
  fail "the log should say how many wait and name the command, got '$(cat "$fixture/err")'"
[[ $(grep -c '^- ' "$home/map/decisions/draft/2026-W34.md") == 2 ]] ||
  fail "both bullets should be in the draft"

# --- the assembler never reads the draft folder ------------------------------------

(
  source "$ROOT/lib/common.sh"
  load_company
  source "$ROOT/lib/doc.sh"
  printf '## 2026-W33\n\n- an older, kept decision (acme/api#1)\n' >"$home/map/decisions/2026-W33.md"
  doc_decisions 2>/dev/null
)
grep -q 'older, kept decision' "$home/map/DECISIONS.md" ||
  fail "a kept fragment should be assembled"
! grep -q 'Retries moved' "$home/map/DECISIONS.md" ||
  fail "a draft bullet reached DECISIONS.md without anyone keeping it"

# --- orgami drafts: keep one, drop one ---------------------------------------------

[[ $(./bin/orgami drafts --count) == 2 ]] ||
  fail "drafts --count should count the two decision bullets, got $(./bin/orgami drafts --count)"

printf 'keep it\nthrow it away\n' >"$GUM_QUEUE"
out=$(./bin/orgami drafts 2>&1) || fail "orgami drafts exited $?: $out"
grep -q '1 decision(s) kept, 1 discarded' <<<"$out" ||
  fail "the summary should count one kept and one dropped, got: $out"
[[ -f $home/map/decisions/2026-W34.md ]] ||
  fail "the kept bullet should have created the week's fragment"
grep -q '^## 2026-W34$' "$home/map/decisions/2026-W34.md" ||
  fail "the fragment should open with the week heading"
grep -q 'Retries moved' "$home/map/decisions/2026-W34.md" ||
  fail "the kept bullet is missing from the fragment"
! grep -q 'Cypress' "$home/map/decisions/2026-W34.md" ||
  fail "the dropped bullet reached the fragment"
[[ ! -f $home/map/decisions/draft/2026-W34.md ]] ||
  fail "an emptied draft should be removed"
[[ $(./bin/orgami drafts --count) == 0 ]] ||
  fail "nothing should be waiting after the review"

# --- skipped bullets stay, in a rewritten draft ------------------------------------

run_report 2>/dev/null
printf 'leave it for later\nkeep it\n' >"$GUM_QUEUE"
./bin/orgami drafts >/dev/null 2>&1 || fail "second review exited $?"
[[ -f $home/map/decisions/draft/2026-W34.md ]] ||
  fail "a skipped bullet should keep the draft alive"
[[ $(grep -c '^- ' "$home/map/decisions/draft/2026-W34.md") == 1 ]] ||
  fail "only the skipped bullet should remain in the draft"
grep -q 'Retries moved' "$home/map/decisions/draft/2026-W34.md" ||
  fail "the wrong bullet was left in the draft"
[[ $(grep -c 'Cypress' "$home/map/decisions/2026-W34.md") == 1 ]] ||
  fail "the kept bullet should be appended to the existing fragment once"

# --- notes_autopublish sends decisions straight through ----------------------------

rm -rf "$home/map/decisions"
jq -n '{org: "acme", notes_autopublish: true}' >"$home/config.json"
run_report 2>"$fixture/err"
[[ -f $home/map/decisions/2026-W34.md && ! -d $home/map/decisions/draft ]] ||
  fail "with notes_autopublish the fragment should be written directly"
grep -q 'decisions recorded for 2026-W34' "$fixture/err" ||
  fail "the direct path should log as before"

echo "decisions_draft: held unless autopublish, kept bullets land, dropped vanish, skipped stay, drafts never assembled"
