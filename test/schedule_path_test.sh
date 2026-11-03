#!/usr/bin/env bash
# A scheduler starts orgami with its own PATH, not the login shell's. systemd's
# user manager and cron both leave out ~/.local/bin, which is where orgami links
# itself and where the official installer puts claude, so a timer that does not
# set PATH fails on `need claude` every week. Each of the four ways orgami is
# scheduled — the weekly unit, the rendered daily unit, the launchd plist and
# the cron line — has to carry it.
#
# Renders into a temp directory and stubs the scheduler choice; nothing is
# enabled, loaded or installed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "schedule path: $*" >&2; exit 1; }

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/schedule.sh
source lib/schedule.sh

want='%h/.local/bin:/usr/local/bin:/usr/bin:/bin'

grep -qxF "Environment=PATH=$want" systemd/orgami-weekly@.service ||
  fail "the weekly unit should set PATH=$want"

schedule_daily_unit "$fixture" 08:00
grep -qxF "Environment=PATH=$want" "$fixture/orgami-daily@.service" ||
  fail "the daily unit should set PATH=$want, got: $(grep PATH "$fixture/orgami-daily@.service" || echo nothing)"

plist=$(schedule_plist acme dev.orgami.weekly.acme /x/orgami weekly)
grep -qF "<key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:" <<<"$plist" ||
  fail "the plist PATH should start with ~/.local/bin and /opt/homebrew/bin"

# The cron branch prints a line to paste. It is reached by making the stub
# scheduler answer cron, whatever this machine has.
export ORGAMI_HOME="$fixture/home" ORGAMI_COMPANY=acme
mkdir -p "$ORGAMI_HOME/acme"
jq -n '{org: "acme"}' >"$ORGAMI_HOME/acme/config.json"
schedule_kind() { echo cron; }
for kind in --weekly --daily; do
  out=$(ORGAMI_BIN=/x/orgami cmd_schedule "$kind")
  line=$(grep -E '^  [0-9]' <<<"$out") || fail "no cron line for $kind, got: $out"
  grep -qF "PATH=$HOME/.local/bin:" <<<"$line" ||
    fail "the $kind cron line should set PATH with ~/.local/bin, got: $line"
  grep -qF "ORGAMI_COMPANY=acme" <<<"$line" || fail "the $kind cron line lost the company, got: $line"
done
