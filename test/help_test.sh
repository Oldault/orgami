#!/usr/bin/env bash
# `<command> --help` answers on a machine with nothing set up, and after setup
# answers instead of parsing --help as a flag. A fresh user found `scan --help`
# saying "no company selected", then "unknown flag: --help", with --jobs and
# --depth only in `orgami help --all`. The answer is sliced out of that help, so
# every command it names is run here, bare and with a company configured.
# Temp ORGAMI_HOME and HOME, no gh, no claude, no network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "help: $*" >&2; exit 1; }

export HOME="$fixture/home" ORGAMI_HOME="$fixture/orgami" ORGAMI_AUTOUPDATE=0
unset ORGAMI_COMPANY
mkdir -p "$HOME"

cmds=$(./bin/orgami help --all | awk '/^  orgami [a-z]/ { print $2 }' | LC_ALL=C sort -u)
[[ $(wc -l <<<"$cmds") -gt 30 ]] || fail "help --all names too few commands: $cmds"

check() { # check <label> — every command answers --help and -h with its own help
  local c flag out err
  for c in $cmds; do
    for flag in --help -h; do
      out=$(./bin/orgami "$c" "$flag" </dev/null 2>"$fixture/err") ||
        fail "$c $flag exited non-zero $1: $(cat "$fixture/err")"
      err=$(cat "$fixture/err")
      [[ -z $err ]] || fail "$c $flag wrote to stderr $1: $err"
      [[ $out == *"orgami $c"* ]] || fail "$c $flag does not show its usage $1: $out"
    done
  done
}

check "with no company"

mkdir -p "$ORGAMI_HOME/acme"
echo '{"default":"acme"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme"}' >"$ORGAMI_HOME/acme/config.json"
check "with a company"

# The flags a user asked for are in the answer, and --help after another flag
# still answers rather than running the command.
out=$(./bin/orgami scan --jobs 4 --help </dev/null)
[[ $out == *--jobs* && $out == *--depth* ]] || fail "scan --help does not list --jobs and --depth: $out"
[[ ! -e $ORGAMI_HOME/acme/map/graph.json ]] || fail "scan --help ran a scan"
out=$(./bin/orgami read --help </dev/null)
[[ $out == *"orgami latest"* ]] || fail "read, latest's alias, does not show latest's help: $out"
out=$(./bin/orgami brief --help </dev/null)
[[ $out == *"orgami help --all"* ]] || fail "a command with no section of its own does not point at help --all: $out"
out=$(./bin/orgami nosuchcommand --help </dev/null 2>&1) && fail "an unknown command's --help exited 0"
[[ $out == *"unknown command: nosuchcommand"* ]] || fail "an unknown command's --help does not say so: $out"

echo "help: every command in help --all answers -h and --help, before setup and after"
