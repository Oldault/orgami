#!/usr/bin/env bash
# What `orgami scan` says and does around the edges of an organization, before
# and after the repositories are read:
#
#   - exclude drops the repos whose name matches a pattern, and only those; a
#     pattern that is not a regex is named instead of excluding everything
#   - --jobs and --depth take positive whole numbers, or die saying so
#   - nothing left to scan says how many repos were forks, archived, excluded
#     or outside include, and an empty listing says so
#   - a token GitHub rejects is named as the token, not as the org in config
#   - a clone that fails says why, in git's own last line
#   - one scan per company at a time: a second one is refused while the first
#     runs, and the lock of one that died is taken over
#
# A stub `gh` earlier on PATH serves the repo list and clones from local
# repositories in a temp directory. No network, no token, nothing pushed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
holder=""
cleanup() {
  [[ -z $holder ]] || kill "$holder" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
home="$tmp/home" stub="$tmp/stub" bin="$tmp/bin"
mkdir -p "$home/acme" "$stub/src" "$bin"
echo '{"default": "acme"}' >"$home/config.json"
cfg="$home/acme/config.json"
setcfg() { jq -n --argjson e "$1" --argjson i "${2:-[]}" '{org: "acme", exclude: $e, include: $i}' >"$cfg"; }
setcfg '[]'

fail=0
check() { [[ $2 == "$3" ]] || { echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; }; }
has() { grep -qF -- "$2" "$tmp/err" || { echo "FAIL $1: no '$2' in: $(cat "$tmp/err")" >&2; fail=1; }; }

repo() {
  local d="$stub/src/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  printf '%s\n' "$1" >"$d/README.md"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
}
for r in api web web-sandbox infra; do repo "$r"; done

# list <name:flags...> — the org's repo list; flags are f (fork) and a (archived).
list() {
  (($#)) || { echo '[]' >"$stub/repos.json"; return 0; }
  printf '%s\n' "$@" | jq -R '{name: (split(":")[0]), flags: (split(":")[1] // "")}' |
    jq -s '[.[] | {name, description: null, language: null,
      archived: (.flags | test("a")), private: false, fork: (.flags | test("f")),
      pushed_at: "2026-01-01T00:00:00Z", default_branch: "main", topics: [],
      html_url: ("https://github.com/acme/" + .name), size: 1, open_issues_count: 0}]' >"$stub/repos.json"
}
list api web web-sandbox infra

cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
# Stub gh: the repo list, the account type, and clones from $STUB/src.
set -euo pipefail
case "$1 ${2-}" in
  "api orgs/"*)
    [[ -f $STUB/badtoken ]] && { echo '{"message": "Bad credentials"}'; echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1; }
    [[ -f $STUB/missing ]] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    while [[ $# -gt 0 && $1 != --jq ]]; do shift; done
    jq -c "$2" "$STUB/repos.json"
    ;;
  "api users/"*)
    [[ -f $STUB/badtoken ]] && { echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1; }
    echo Organization
    ;;
  "repo clone")
    name=${3#*/}
    if grep -qxF "$name" "$STUB/fail" 2>/dev/null; then
      echo "fatal: unable to access 'https://github.com/acme/$name/': The requested URL returned error: 403" >&2
      echo "failed to run git: exit status 128" >&2
      exit 1
    fi
    [[ -f $STUB/slow ]] && { : >"$STUB/started"; sleep 31.3; }
    git clone -q "$STUB/src/$name" "$4"
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$bin/gh"
: >"$stub/fail"

scan() {
  rc=0
  PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0 \
    "$root/bin/orgami" scan "$@" >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
}
g="$home/acme/map/graph.json"
repos() { jq -r '[.nodes[] | select(.kind == "repo") | .name] | sort | join(",")' "$g"; }
lock="$home/acme/cache/.scan.lock"

# --- exclude ----------------------------------------------------------------

setcfg '["zzzz"]'
scan
check "a pattern matching nothing excludes nothing (rc)" "$rc" 0
check "a pattern matching nothing excludes nothing" "$(repos)" "api,infra,web,web-sandbox"

setcfg '["-sandbox$", "^infra"]'
scan
check "exclude drops what matches (rc)" "$rc" 0
check "exclude drops what matches, and only that" "$(repos)" "api,web"
has "the log counts what exclude dropped" "2 matched by exclude"

setcfg '["*-infra"]'
scan
check "a glob for a pattern exits 1" "$rc" 1
has "a glob for a pattern is named" 'exclude pattern "*-infra"'
setcfg '["["]'
scan
check "an unclosed bracket exits 1" "$rc" 1
has "an unclosed bracket is named" 'exclude pattern "["'

# --- --jobs and --depth -----------------------------------------------------

setcfg '[]'
for j in abc -1 0 1.5; do
  scan --jobs "$j"
  check "--jobs $j exits 1" "$rc" 1
  has "--jobs $j is refused by name" "--jobs wants a positive whole number"
done
scan --depth x
check "--depth x exits 1" "$rc" 1
has "--depth x is refused by name" "--depth wants a positive whole number"

# --- nothing left to scan ---------------------------------------------------

cp "$g" "$tmp/before.json"
list api:f web:a
scan
check "an org of a fork and an archived repo exits 1" "$rc" 1
has "the fork and the archived repo are counted" "gh lists 2, and skipped 1 fork, 1 archived (forks and archived repos are never mapped)"
grep -q 'include and exclude' "$tmp/err" && { echo "FAIL config blamed for a fork: $(cat "$tmp/err")" >&2; fail=1; }

list api web web-sandbox
setcfg '["^(api|web)$"]' '["api", "web"]'
scan
check "include and exclude leaving nothing exits 1" "$rc" 1
has "include and exclude are counted" "skipped 2 matched by exclude, 1 not in include"
has "include and exclude point at the config" "include and exclude are in $cfg"

list
setcfg '[]'
scan
check "an empty listing exits 1" "$rc" 1
has "an empty listing says so" "gh lists no repositories in acme"
cmp -s "$g" "$tmp/before.json" || { echo "FAIL a scan with nothing to read changed the map" >&2; fail=1; }

# --- the token, not the org -------------------------------------------------

list api web web-sandbox infra
touch "$stub/badtoken"
rc=0
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0 GH_TOKEN=ghp_bad \
  "$root/bin/orgami" scan >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
check "a rejected GH_TOKEN exits 1" "$rc" 1
has "a rejected GH_TOKEN is named" "GitHub rejected the token in GH_TOKEN"
grep -q 'config.json' "$tmp/err" && { echo "FAIL a rejected token blamed config.json: $(cat "$tmp/err")" >&2; fail=1; }
rc=0
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0 GH_TOKEN="" GITHUB_TOKEN="" \
  "$root/bin/orgami" scan >"$tmp/out" 2>"$tmp/err" </dev/null || rc=$?
has "a rejected stored login is sent to gh auth login" "GitHub rejected gh's stored token — run: gh auth login"
rm "$stub/badtoken"

touch "$stub/missing"
scan
has "a 404 points at the org in config" "GitHub has no organization 'acme' this token can see — check the org in $cfg"
rm "$stub/missing"

# --- a failed clone says why ------------------------------------------------

rm -rf "$home/acme/cache/src/infra"
echo infra >"$stub/fail"
scan
check "one failed clone still exits 0" "$rc" 0
has "a failed clone gives git's reason" "could not clone: infra (fatal: unable to access 'https://github.com/acme/infra/': The requested URL returned error: 403)"
grep -q 'failed to run git' "$tmp/err" && { echo "FAIL gh's own trailer was given as the cause" >&2; fail=1; }
: >"$stub/fail"
[[ ! -e $lock ]] || { echo "FAIL a finished scan left its lock" >&2; fail=1; }

# git's first error line, not the "and the repository exists." it ends with.
mv "$stub/src/api" "$stub/api.away"
scan
has "a failed fetch gives git's reason" "could not fetch, mapped from the last checkout: api (fatal: '$stub/src/api' does not appear to be a git repository)"
mv "$stub/api.away" "$stub/src/api"

# --- one scan at a time -----------------------------------------------------

# A live holder: a process whose command line says orgami, as a scan's does.
bash -c 'sleep 30; :' orgami-scan-holder &
holder=$!
mkdir -p "$lock"
echo "$holder" >"$lock/pid"
scan
check "a second scan while one runs exits 1" "$rc" 1
has "a second scan says why" "another scan of acme is running (pid $holder)"
[[ -d $lock ]] || { echo "FAIL a refused scan removed the running scan's lock" >&2; fail=1; }
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# The holder is gone: its lock is taken over and the scan runs.
scan
check "a dead holder's lock is taken over (rc)" "$rc" 0
has "taking over is said" "taking over the lock of a scan that is no longer running (pid $holder)"
[[ ! -e $lock ]] || { echo "FAIL the scan that took over left the lock" >&2; fail=1; }
holder=""

# Two real scans: the second is refused while the first is cloning, and the
# first one's lock goes with it when it is stopped.
rm -rf "$home/acme/cache/src"/*
touch "$stub/slow"
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0 \
  "$root/bin/orgami" scan --jobs 2 >/dev/null 2>"$tmp/err1" </dev/null &
pid=$!
for _ in $(seq 100); do [[ -f $stub/started ]] && break; sleep 0.1; done
[[ -f $stub/started ]] || { echo "FAIL the slow clone never started" >&2; fail=1; }
rm -f "$stub/slow"
scan
check "a scan beside a running one exits 1" "$rc" 1
has "a scan beside a running one is refused" "another scan of acme is running (pid $pid)"
kill -TERM "$pid"
wait "$pid" 2>/dev/null || true
sleep 0.3
pkill -f 'sleep 31.3' 2>/dev/null || true
[[ ! -e $lock ]] || { echo "FAIL a stopped scan left its lock" >&2; fail=1; }

exit $fail
