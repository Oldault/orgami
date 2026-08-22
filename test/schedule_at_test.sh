#!/usr/bin/env bash
# The daily digest's hour is written into the company config, which every
# machine in the company reads, and rendered straight into `OnCalendar=`. So a
# time that cannot exist is not a typo the user gets told about — it is a timer
# that silently never fires, agreed on by every laptop. `24:00`, `25:30` and
# `29:59` all matched the old `[0-2][0-9]` guard.
#
# What this pins: which times `orgami schedule --at` and `orgami init
# --daily-at` accept, that a refused time reaches neither the config nor the
# unit, that a single-digit hour is normalised before it reaches either, and
# that a config already holding an impossible hour falls back instead of
# rendering it.
#
# Runs against a stub `systemctl` and a stub `gh` under a temp HOME and a temp
# ORGAMI_HOME — no timer is enabled, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "schedule --at: $*" >&2; exit 1; }

# --- the fixture organization --------------------------------------------------

export ORGAMI_HOME="$fixture/home"
export ORGAMI_COMPANY=acme
export HOME="$fixture/fakehome"
home="$ORGAMI_HOME/acme"
unit="$HOME/.config/systemd/user/orgami-daily@.timer"
mkdir -p "$home" "$fixture/bin" "$HOME"

config() { # config <daily_at-or-empty>
  if [[ -n ${1-} ]]; then
    jq -n --arg at "$1" '{org: "acme", daily: false, daily_at: $at}'
  else
    jq -n '{org: "acme", daily: false}'
  fi >"$home/config.json"
}

# --- the stubs ------------------------------------------------------------------
# `schedule_kind` picks systemd when `systemctl --user show-environment` works,
# so the stub both chooses the branch under test and keeps a real `systemctl`
# from enabling anything on the machine running this.

cat >"$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
exit 0
STUB
cat >"$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[[ $1 == api ]] && echo '{"login":"acme"}'
exit 0
STUB
chmod +x "$fixture/bin/systemctl" "$fixture/bin/gh"
PATH="$fixture/bin:$PATH"
export SYSTEMCTL_LOG="$fixture/systemctl.log" GH_LOG="$fixture/gh.log"
: >"$SYSTEMCTL_LOG"
: >"$GH_LOG"

# Proof the stub is the systemctl that runs — every assertion below about units
# and enabling is worth nothing otherwise.
[[ $(command -v systemctl) == "$fixture/bin/systemctl" ]] ||
  fail "the stub is not the systemctl on PATH — refusing to run: $(command -v systemctl)"

# --- the harness ----------------------------------------------------------------
# Through a fresh `bash -c` the way `bin/orgami` does: `OUT=$(...) || RC=$?`
# puts the call inside a `||` list, and bash suspends `set -e` underneath one,
# so a sourced function would sail past failures the dispatcher would stop on.

run() { # run <flags...> — sets ERR/RC, and leaves the rendered unit on disk
  rm -f "$unit"
  RC=0
  ORGAMI_BIN="$ROOT/bin/orgami" bash -c '
      set -euo pipefail
      ROOT=$1; shift
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/schedule.sh"
      cmd_schedule "$@"
    ' orgami "$ROOT" "$@" >/dev/null 2>"$fixture/err" || RC=$?
  ERR=$(cat "$fixture/err")
}

at_in_config() { jq -r '.daily_at // "unset"' "$home/config.json"; }
at_in_unit() { sed -n 's/^OnCalendar=Mon\.\.Fri //p' "$unit"; }

# --- an impossible hour is refused, and reaches nothing ------------------------
# `[0-2][0-9]` reads as 24 hours and matches 29. Each of these was accepted,
# written to the shared config, and rendered into a unit systemd cannot parse.

for bad in 24:00 25:30 29:59 30:00 99:99 08:60 8:0 "" "8" "eight" "08:00 " "1:2"; do
  config "07:30"
  run --at "$bad"
  [[ $RC == 1 ]] || fail "'$bad' is not a time of day and must be refused, got $RC"
  grep -q "24-hour clock" <<<"$ERR" ||
    fail "the refusal of '$bad' should say what a time looks like, got '$ERR'"
  grep -q -- "$bad" <<<"$ERR" || [[ -z $bad ]] ||
    fail "the refusal should quote back what was typed, got '$ERR'"
  [[ $(at_in_config) == "07:30" ]] ||
    fail "'$bad' must not reach the shared config, it now holds $(at_in_config)"
  [[ ! -f $unit ]] || fail "'$bad' must not reach a unit file, it rendered $(at_in_unit)"
done

# --- `--at` with no value is orgami's error, not bash's -------------------------
# `--at) want_at=$2` as the last argument reads an unset $2 under the `set -u`
# in bin/orgami: a raw "unbound variable" with no mention of orgami or of the
# flag, and `shift 2` failing straight after it.

config "07:30"
run --at
[[ $RC == 1 ]] || fail "--at with nothing after it must be refused, got $RC"
grep -q 'unbound variable' <<<"$ERR" &&
  fail "a missing value must be orgami's error, not bash's: '$ERR'"
grep -q 'orgami: --at wants a time' <<<"$ERR" ||
  fail "the refusal should name the flag and show a time, got '$ERR'"
[[ $(at_in_config) == "07:30" ]] || fail "nothing may be written when the flag has no value"

# --- the times that exist are accepted, and rendered as given -------------------

for good in 00:00 08:00 09:15 12:59 19:45 23:59; do
  config "07:30"
  run --at "$good"
  [[ $RC == 0 ]] || fail "'$good' is a time of day and must be accepted, got $RC: $ERR"
  [[ $(at_in_config) == "$good" ]] ||
    fail "'$good' should reach the config, which holds $(at_in_config)"
  [[ $(at_in_unit) == "$good" ]] ||
    fail "'$good' should reach OnCalendar=, which reads $(at_in_unit)"
done

# --- a single-digit hour is accepted and normalised before it is stored ---------
# `8:00` is what a person types. It is taken, and written as `08:00` so that the
# config, the unit, the plist and the cron line all see one shape rather than
# each relying on its own tolerance for a bare `8`.

config "07:30"
run --at 8:00
[[ $RC == 0 ]] || fail "'8:00' is what a person types and must be accepted, got $RC: $ERR"
[[ $(at_in_config) == "08:00" ]] ||
  fail "'8:00' should be stored as 08:00, the config holds $(at_in_config)"
[[ $(at_in_unit) == "08:00" ]] ||
  fail "'8:00' should render as 08:00, OnCalendar= reads $(at_in_unit)"

config "07:30"
run --at 0:05
[[ $RC == 0 ]] || fail "'0:05' must be accepted, got $RC: $ERR"
[[ $(at_in_config) == "00:05" ]] ||
  fail "'0:05' should be stored as 00:05, the config holds $(at_in_config)"

# --- a config already holding an impossible hour falls back ---------------------
# The old guard let 24:00 into configs that exist now, and the fallback used the
# same guard, so it passed it straight through. Rendering it is the failure this
# whole test is about, so the stored value is repaired rather than trusted.

config "24:00"
run --daily
[[ $RC == 0 ]] || fail "a bad stored time should fall back, not refuse, got $RC: $ERR"
[[ $(at_in_unit) == "08:00" ]] ||
  fail "a stored 24:00 must not be rendered, OnCalendar= reads $(at_in_unit)"
[[ $(at_in_config) == "08:00" ]] ||
  fail "a stored 24:00 should be repaired, the config holds $(at_in_config)"

# A config with no daily_at at all is the same path, and still has to work.
config ""
run --daily
[[ $RC == 0 ]] || fail "no stored time should fall back, got $RC: $ERR"
[[ $(at_in_unit) == "08:00" ]] || fail "the default is 08:00, OnCalendar= reads $(at_in_unit)"

# --- `orgami init --daily-at` writes the same field, so it has the same clock ---
# A fresh config is the other way an impossible hour gets in, and from there
# `schedule --daily` renders it on every machine that reads it.

init() { # init <company> <flags...> — sets ERR/RC
  RC=0
  ORGAMI_BIN="$ROOT/bin/orgami" bash -c '
      set -euo pipefail
      ROOT=$1; shift
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/init.sh"
      cmd_init "$@"
    ' orgami "$ROOT" "$@" >/dev/null 2>"$fixture/err" || RC=$?
  ERR=$(cat "$fixture/err")
}

for bad in 24:00 29:59 8:0 "eight"; do
  rm -rf "${ORGAMI_HOME:?}/fresh"
  init fresh --org acme --daily-at "$bad"
  [[ $RC == 1 ]] || fail "init --daily-at '$bad' must be refused, got $RC"
  grep -q "24-hour clock" <<<"$ERR" ||
    fail "init should refuse '$bad' the way schedule does, got '$ERR'"
  [[ ! -f $ORGAMI_HOME/fresh/config.json ]] ||
    fail "init --daily-at '$bad' must not create a config"
done

rm -rf "${ORGAMI_HOME:?}/fresh"
init fresh --org acme --daily-at
[[ $RC == 1 ]] || fail "init --daily-at with no value must be refused, got $RC"
grep -q 'unbound variable' <<<"$ERR" &&
  fail "a missing value must be orgami's error, not bash's: '$ERR'"

rm -rf "${ORGAMI_HOME:?}/fresh"
init fresh --org acme --daily-at 9:30
[[ $RC == 0 ]] || fail "init --daily-at 9:30 must be accepted, got $RC: $ERR"
[[ $(jq -r .daily_at "$ORGAMI_HOME/fresh/config.json") == "09:30" ]] ||
  fail "init should store 9:30 as 09:30, it wrote $(jq -r .daily_at "$ORGAMI_HOME/fresh/config.json")"

echo "schedule --at: impossible hours refused everywhere they are stored"
