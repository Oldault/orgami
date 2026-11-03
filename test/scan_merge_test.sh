#!/usr/bin/env bash
# What `orgami scan` does to a map that already exists, when the run is not a
# clean full scan:
#
#   - `--only <repo>` rereads that repo and merges it in; every other repo keeps
#     its nodes, its edges and its profile, and the map keeps its date
#   - `--only` with a name the org does not have dies, and the map is untouched
#   - a clone that fails keeps that repo as the last map had it
#   - when nothing at all could be read, the previous map stays and the exit
#     status says so
#   - a personal account gets a sentence, not gh's 404, and the repo list on
#     disk is never replaced by a failed listing
#
# A stub `gh` earlier on PATH serves the repo list and clones from local
# repositories in a temp directory. No network, no token, nothing pushed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home" stub="$tmp/stub" bin="$tmp/bin" scratch="$tmp/t"
mkdir -p "$home/acme" "$stub/src" "$bin" "$scratch"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"

fail=0
check() { [[ $2 == "$3" ]] || { echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; }; }

# The origin of each clone is a plain working repository, so a later commit in
# it is what the next fetch sees — no push anywhere.
repo() {
  local d="$stub/src/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  shift
  while (($#)); do
    mkdir -p "$(dirname "$d/$1")"
    printf '%s\n' "$2" >"$d/$1"
    shift 2
  done
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
}
repo alpha Dockerfile 'FROM scratch'
# A committed link out of the checkout: the scan removes it before reading.
echo "SECRET-$$" >"$tmp/secret"
ln -s "$tmp/secret" "$stub/src/alpha/AGENTS.md"
git -C "$stub/src/alpha" add -A
git -C "$stub/src/alpha" -c user.name=t -c user.email=t@t commit -qm link
repo beta README.md 'beta'
repo gamma fly.toml 'app = "gamma-app"'

jq -n '[("alpha", "beta", "gamma") | {name: ., description: null, language: "Go",
  archived: false, private: false, fork: false, pushed_at: "2026-01-01T00:00:00Z",
  default_branch: "main", topics: [], html_url: ("https://github.com/acme/" + .),
  size: 1, open_issues_count: 0}]' >"$stub/repos.json"

cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
# Stub gh: the repo list, the account type, and clones from $STUB/src.
set -euo pipefail
case "$1 ${2-}" in
  "api orgs/"*)
    [[ -f $STUB/personal ]] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    while [[ $# -gt 0 && $1 != --jq ]]; do shift; done
    jq -c "$2" "$STUB/repos.json"
    ;;
  "api users/"*)
    if [[ -f $STUB/personal ]]; then echo User; else echo Organization; fi
    ;;
  "repo clone")
    name=${3#*/}
    grep -qxF "$name" "$STUB/fail" 2>/dev/null && exit 1
    [[ -f $STUB/slow ]] && { : >"$STUB/started"; sleep 31.7; }
    git clone -q "$STUB/src/$name" "$4"
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$bin/gh"
: >"$stub/fail"

# TMPDIR is the test's own, so whatever a scan leaves behind is visible.
scan() {
  PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme TMPDIR="$scratch" \
    "$root/bin/orgami" scan --jobs 2 "$@" >"$tmp/out" 2>"$tmp/err"
}
leftovers() { find "$scratch" -mindepth 1 | wc -l | tr -d ' '; }
g="$home/acme/map/graph.json"
p="$home/acme/map/repos.json"
repos() { jq -r '[.nodes[] | select(.kind == "repo") | .name] | sort | join(",")' "$g"; }
edge() { jq -r --arg f "repo:$1" --arg t "$2" 'any(.edges[]; .from == $f and .to == $t)' "$g"; }

# --- a full scan -------------------------------------------------------------

scan || { echo "FAIL full scan:" >&2; cat "$tmp/err" >&2; exit 1; }
check "full scan maps every repo" "$(repos)" "alpha,beta,gamma"
check "a profile per repo" "$(jq -r 'map(.name) | join(",")' "$p")" "alpha,beta,gamma"
check "alpha uses docker" "$(edge alpha tool:docker)" true
check "a link out of the checkout is not an agent doc" \
  "$(jq -c '.[] | select(.name == "alpha") | .agent_docs' "$p")" '[]'
[[ ! -L $home/acme/cache/src/alpha/AGENTS.md ]] || { echo "FAIL the escaping link is still in the checkout" >&2; fail=1; }
jq '.generated = "2020-01-01T00:00:00Z"' "$g" >"$g.tmp" && mv "$g.tmp" "$g"

# --- --only rereads one repo and keeps the rest ------------------------------

printf 'FROM scratch\n' >"$stub/src/beta/Dockerfile"
git -C "$stub/src/beta" add -A
git -C "$stub/src/beta" -c user.name=t -c user.email=t@t commit -qm docker
scan --only beta || { echo "FAIL --only beta:" >&2; cat "$tmp/err" >&2; exit 1; }
check "--only keeps the other repos" "$(repos)" "alpha,beta,gamma"
check "--only picks up the repo's new edge" "$(edge beta tool:docker)" true
check "--only keeps another repo's edges" "$(edge alpha tool:docker)" true
check "--only keeps another repo's host" "$(edge gamma host:gamma-app.fly.dev)" true
check "--only keeps every profile" "$(jq -r 'map(.name) | join(",")' "$p")" "alpha,beta,gamma"
check "--only keeps the map's date" "$(jq -r .generated "$g")" "2020-01-01T00:00:00Z"
check "nothing doubled" "$(jq '[.nodes[].id] | length == (unique | length)' "$g")" true

# --- --only with a name the org does not have --------------------------------

cp "$g" "$tmp/before.json"
if scan --only betta; then echo "FAIL --only typo exited 0" >&2; fail=1; fi
grep -q "no active repo 'betta'" "$tmp/err" || { echo "FAIL --only typo message: $(cat "$tmp/err")" >&2; fail=1; }
cmp -s "$g" "$tmp/before.json" || { echo "FAIL --only typo changed the map" >&2; fail=1; }

# --- one clone fails: that repo keeps what the last map said -----------------

rm -rf "$home/acme/cache/src/gamma"
echo gamma >"$stub/fail"
scan || { echo "FAIL scan with one failed clone:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q 'could not clone: gamma' "$tmp/err" || { echo "FAIL failed clone not reported" >&2; fail=1; }
check "a failed clone keeps its repo" "$(repos)" "alpha,beta,gamma"
check "a failed clone keeps its edges" "$(edge gamma host:gamma-app.fly.dev)" true

# --- a fetch that fails: mapped from the checkout, and said ------------------

mv "$stub/src/alpha" "$stub/alpha.away"
scan || { echo "FAIL scan with one failed fetch:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q 'could not fetch, mapped from the last checkout: alpha' "$tmp/err" ||
  { echo "FAIL failed fetch not reported: $(cat "$tmp/err")" >&2; fail=1; }
check "a failed fetch still maps the repo" "$(edge alpha tool:docker)" true
mv "$stub/alpha.away" "$stub/src/alpha"
check "no temp left after a scan" "$(leftovers)" 0

# --- nothing can be read: the previous map stays -----------------------------

cp "$g" "$tmp/before.json"
rm -rf "$home/acme/cache/src"/*
printf 'alpha\nbeta\ngamma\n' >"$stub/fail"
if scan; then echo "FAIL a scan with every clone failing exited 0" >&2; fail=1; fi
grep -q 'unchanged' "$tmp/err" || { echo "FAIL all-failed message: $(cat "$tmp/err")" >&2; fail=1; }
cmp -s "$g" "$tmp/before.json" || { echo "FAIL an all-failed scan changed the map" >&2; fail=1; }

# --- a personal account ------------------------------------------------------

cp "$home/acme/cache/repos/list.json" "$tmp/list.before"
touch "$stub/personal"
if scan; then echo "FAIL a personal account exited 0" >&2; fail=1; fi
grep -q 'is a personal account' "$tmp/err" || { echo "FAIL personal account message: $(cat "$tmp/err")" >&2; fail=1; }
cmp -s "$home/acme/cache/repos/list.json" "$tmp/list.before" ||
  { echo "FAIL a failed listing replaced list.json" >&2; fail=1; }

rm -f "$stub/personal"
check "no temp left after failed scans" "$(leftovers)" 0

# --- stopped half way: no clone left running, no temp left -------------------

# A background job in a script ignores SIGINT, so the test sends TERM, which
# the scan treats the same way.
rm -rf "$home/acme/cache/src"/*
: >"$stub/fail"
touch "$stub/slow"
# Started directly, not through scan(): a function sent to the background is a
# subshell of its own, and TERM would stop that instead of the scan.
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme TMPDIR="$scratch" \
  "$root/bin/orgami" scan --jobs 2 >"$tmp/out" 2>"$tmp/err" &
pid=$!
for _ in $(seq 100); do [[ -f $stub/started ]] && break; sleep 0.1; done
[[ -f $stub/started ]] || { echo "FAIL the slow clone never started" >&2; fail=1; }
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
check "a stopped scan exits 130" "$rc" 130
sleep 0.3
if pgrep -f 'sleep 31.7' >/dev/null; then
  echo "FAIL a clone kept running after the scan stopped" >&2
  pkill -f 'sleep 31.7' || true
  fail=1
fi
check "no temp left after a stopped scan" "$(leftovers)" 0

exit $fail
