#!/usr/bin/env bash
# Every value-taking flag is parsed as `--flag) x=$2; shift 2`, and bin/orgami
# runs under `set -euo pipefail`. Typed as the final argument, such a flag used
# to read an unset $2 and abort with bash's own "unbound variable" — a message
# that names neither orgami nor the flag, with the `shift 2` failing right
# behind it. `need_arg` in lib/common.sh is the guard.
#
# What this pins, twice over:
#   - behaviour: every value-taking flag, run bare through its real parser,
#     dies as orgami's error naming the flag — never as bash's.
#   - the pattern: no parse arm reads $2 without need_arg in front of it, so a
#     new flag cannot reintroduce the failure without tripping this test.
#
# Runs against stub `gh`, `claude` and `systemctl` under a temp HOME and a temp
# ORGAMI_HOME — no org, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "flag args: $*" >&2; exit 1; }

# --- every $2 read is guarded ----------------------------------------------------
# The arm is one line (`--flag) need_arg "$1" $#; x=$2; shift 2 ;;`) or the
# guard sits on its own line directly under the flag, as in `schedule --at`.

unguarded=$(awk '
  FNR == 1 { p1 = ""; p2 = "" }
  /\$2/ && /shift 2/ {
    if ($0 !~ /need_arg/ && p1 !~ /need_arg/ && p2 !~ /need_arg/)
      printf "%s:%d: %s\n", FILENAME, FNR, $0
  }
  { p2 = p1; p1 = $0 }
' lib/*.sh)
[[ -z $unguarded ]] ||
  fail "these arms read \$2 with no need_arg guard in reach:
$unguarded"

# --- the fixture organization ----------------------------------------------------

export ORGAMI_HOME="$fixture/home"
export ORGAMI_COMPANY=acme
export HOME="$fixture/fakehome"
home="$ORGAMI_HOME/acme"
mkdir -p "$home/map" "$fixture/bin" "$HOME"
jq -n '{org: "acme", daily: false}' >"$home/config.json"
echo '[]' >"$home/map/repos.json" # `live` refuses to start without a map

# Stubs for the `need <tool>` preflights that run before flag parsing. None may
# ever be reached past the parser — a trailing value-flag dies inside the loop.
for tool in gh claude systemctl; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/bin/$tool"
  chmod +x "$fixture/bin/$tool"
done
PATH="$fixture/bin:$PATH"

# --- the harness ------------------------------------------------------------------
# Through a fresh `bash -c` the way `bin/orgami` runs: `RUN=... || RC=$?` puts
# the call inside a `||` list, and bash suspends `set -e` underneath one, so a
# sourced function would sail past failures the dispatcher would stop on.

run() { # run <libfile> <cmd_fn> [args...] — flag under test goes last
  local lib=$1
  shift
  RC=0
  ORGAMI_BIN="$ROOT/bin/orgami" bash -c '
      set -euo pipefail
      ROOT=$1; shift
      lib=$1; shift
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/$lib"
      "$@"
    ' orgami "$ROOT" "$lib" "$@" >/dev/null 2>"$fixture/err" || RC=$?
  ERR=$(cat "$fixture/err")
}

# --- a bare value-flag is orgami's error, never bash's -----------------------------
# One row per value-taking arm in lib/: `<libfile> <cmd_fn> [leading args] <flag>`.

cases=(
  "advise.sh cmd_advise --stale-days"
  "advise.sh cmd_advise --reject"
  "agents.sh cmd_agents --repo"
  "agents.sh cmd_agents --workspace"
  "daily.sh cmd_daily --date"
  "daily.sh cmd_daily --model"
  "depth.sh cmd_depth --only"
  "depth.sh cmd_depth --jobs"
  "depth.sh cmd_depth -j"
  "depth.sh cmd_depth --python"
  "depth.sh cmd_depth --symbol"
  "dns.sh cmd_dns --domain"
  "dns.sh cmd_dns -d"
  "dns.sh cmd_dns --max-domains"
  "doc.sh cmd_doc --model"
  "init.sh cmd_init fresh --org"
  "init.sh cmd_init fresh --docs-repo"
  "init.sh cmd_init fresh --docs-path"
  "init.sh cmd_init fresh --daily-at"
  "live.sh cmd_live --provider"
  "live.sh cmd_live -p"
  "notes.sh cmd_note --repo"
  "notes.sh cmd_note --tag"
  "notes.sh cmd_note --topic"
  "notes.sh cmd_note --supersede"
  "notes.sh cmd_notes --repo"
  "notes.sh cmd_notes --tag"
  "notes.sh cmd_prune --id"
  "notes.sh cmd_sync --max-age"
  "notes.sh cmd_join fresh --repo"
  "notes.sh cmd_join fresh --path"
  "playbook.sh cmd_playbook --topic"
  "pull.sh cmd_pull --last"
  "pull.sh cmd_pull --since"
  "pull.sh cmd_pull --until"
  "report.sh cmd_report --week"
  "report.sh cmd_report --model"
  "report.sh cmd_latest --week"
  "scan.sh cmd_scan --only"
  "scan.sh cmd_scan --depth"
  "scan.sh cmd_scan --jobs"
  "schedule.sh cmd_schedule --at"
)

for case_line in "${cases[@]}"; do
  read -ra argv <<<"$case_line"
  flag=${argv[-1]}
  run "${argv[@]}"
  [[ $RC == 1 ]] ||
    fail "'${argv[1]} $flag' with nothing after it must be refused with 1, got $RC: $ERR"
  grep -q 'unbound variable' <<<"$ERR" &&
    fail "'${argv[1]} $flag' must die as orgami's error, not bash's: '$ERR'"
  grep -q '^orgami: ' <<<"$ERR" ||
    fail "'${argv[1]} $flag' should die through die(), got '$ERR'"
  grep -qF -- "$flag" <<<"$ERR" ||
    fail "the refusal of '${argv[1]} $flag' should name the flag, got '$ERR'"
done

# --- the same flag with a value still parses --------------------------------------
# The guard must reject a missing value, not the flag: a value after it has to
# travel exactly as far as it did before. `pull --since` dies later, on its own
# date check — proof the parser accepted the value and moved on.

run pull.sh cmd_pull --since not-a-date --until
[[ $RC == 1 ]] || fail "a trailing --until must still be refused mid-line, got $RC"
grep -qF -- "--until" <<<"$ERR" ||
  fail "the mid-line refusal should name --until, got '$ERR'"

run pull.sh cmd_pull --last 0 --since 2026-01-05 --until
[[ $RC == 1 ]] || fail "--until at the end of a valid line must be refused, got $RC"
grep -q 'unbound variable' <<<"$ERR" &&
  fail "a trailing flag after valid ones must still be orgami's error: '$ERR'"

echo "flag args: a bare value-flag dies as orgami's error, and every arm is guarded"
