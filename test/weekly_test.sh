#!/usr/bin/env bash
# `orgami weekly` is the systemd timer's whole job, so nobody is watching when a
# step fails. One step dying must not take the rest with it: a recap that could
# not be written is no reason to leave the map a week stale or skip the publish.
# A quiet week is not a failure at all. Anything that did fail is named at the
# end and the run exits non-zero, so the timer shows as failed.
#
# Every step is a stub function that records its name, so nothing is pulled,
# scanned, written by a model or pushed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "weekly: $*" >&2; exit 1; }

export ORGAMI_HOME="$fixture/home" ORGAMI_COMPANY=acme
mkdir -p "$ORGAMI_HOME/acme/map" "$fixture/root/lib"
jq -n '{org: "acme", docs_repo: "git@github.com:acme/engineering.git"}' >"$ORGAMI_HOME/acme/config.json"

# cmd_weekly sources $ROOT/lib/update.sh for cmd_update; this one records the
# flags it was handed instead of updating anything.
cat >"$fixture/root/lib/update.sh" <<'STUB'
# shellcheck shell=bash
cmd_update() { echo "update $*" >>"$STEPS"; }
STUB

# Each stub records itself; STUB_FAIL names one that dies the way the real one
# would, STUB_ERREXIT one that hits a failing command halfway through.
cat >"$fixture/stubs.sh" <<'STUB'
# shellcheck shell=bash
step() {
  echo "$1" >>"$STEPS"
  [[ ${STUB_FAIL:-} != "$1" ]] || die "${STUB_MSG:-$1 broke}"
  if [[ ${STUB_ERREXIT:-} == "$1" ]]; then
    false
    echo "$1 ran past its own failure" >>"$STEPS"
  fi
}
cmd_pull() { step pull; }
cmd_report() { step report; }
cmd_scan() { step scan; }
cmd_coupling() { step coupling; }
cmd_doc() { step doc; }
cmd_sync() { step sync; }
cmd_publish() { step "publish $*"; }
STUB

export STEPS="$fixture/steps"

run() { # run — sets ERR, RC and DONE (the steps that ran, one per line)
  : >"$STEPS"
  RC=0
  bash -c '
      set -euo pipefail
      source lib/common.sh
      source lib/publish.sh
      source "$1"
      ROOT=$2
      cmd_weekly
    ' weekly "$fixture/stubs.sh" "$fixture/root" >/dev/null 2>"$fixture/err" || RC=$?
  ERR=$(cat "$fixture/err")
  DONE=$(cat "$STEPS")
  unset STUB_FAIL STUB_MSG STUB_ERREXIT
}

ran() { grep -qx -- "$1" <<<"$DONE"; }

# --- a week where everything works ---------------------------------------------

run
[[ $RC == 0 ]] || fail "a clean week should exit 0, got $RC: $ERR"
for s in pull report scan coupling doc sync "publish --yes"; do
  ran "$s" || fail "a clean week should run $s, ran: $DONE"
done
# The timer is not somebody typing `orgami update`, so the opt-out applies.
ran "update --quiet --auto" || fail "weekly must update with --auto, ran: $DONE"

# --- a quiet week is not a failure -----------------------------------------------

export STUB_FAIL=report STUB_MSG="no merged PRs in 2026-W20"
run
[[ $RC == 0 ]] || fail "a week with no merged PRs should exit 0, got $RC: $ERR"
grep -q 'quiet week' <<<"$ERR" || fail "a quiet week should be said, got '$ERR'"
for s in scan doc "publish --yes"; do
  ran "$s" || fail "a quiet week must still run $s, ran: $DONE"
done

# --- no claude: no recap, and everything else still runs --------------------------

export STUB_FAIL=report STUB_MSG="claude is not on PATH (the report narrative is written by Claude Code in headless mode)"
run
[[ $RC == 1 ]] || fail "a failed recap should fail the run, got $RC"
grep -q 'claude is not on PATH' <<<"$ERR" || fail "the report's own message should be shown, got '$ERR'"
grep -q 'orgami: weekly: report failed' <<<"$ERR" || fail "the failure should be named at the end, got '$ERR'"
for s in scan coupling doc sync "publish --yes"; do
  ran "$s" || fail "a failed recap must not stop $s, ran: $DONE"
done

# --- a step that dies ends only itself ----------------------------------------------

export STUB_FAIL=scan
run
[[ $RC == 1 ]] || fail "a failed scan should fail the run, got $RC"
grep -q 'weekly: scan failed' <<<"$ERR" || fail "the failed step should be named, got '$ERR'"
for s in coupling doc "publish --yes"; do
  ran "$s" || fail "a failed scan must not stop $s, ran: $DONE"
done

# --- and set -e still holds inside a step ---------------------------------------------
# Under `||` or `if`, bash suspends errexit for everything beneath, so a step
# guarded that way runs past its own failing commands. weekly must not.

export STUB_ERREXIT=doc
run
[[ $RC == 1 ]] || fail "a step failing halfway should fail the run, got $RC"
grep -q 'doc ran past its own failure' <<<"$DONE" &&
  fail "a step must stop at its first failing command, ran: $DONE"
ran "publish --yes" || fail "a failed doc must not stop publish, ran: $DONE"

# --- the first step failing still leaves the rest -----------------------------

export STUB_FAIL=pull
run
[[ $RC == 1 ]] || fail "a failed pull should fail the run, got $RC"
grep -q 'weekly: pull failed' <<<"$ERR" || fail "pull should be named, got '$ERR'"
ran "publish --yes" || fail "a failed pull must not stop publish, ran: $DONE"

echo "weekly: carries on past a failed step, names it, and treats a quiet week as no recap"
