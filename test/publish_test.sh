#!/usr/bin/env bash
# `orgami publish` holds the only `git push` in the tool, and `cmd_weekly` calls
# it with `--yes` from the systemd timer — so it runs unattended, and what
# matters is what it refuses. No docs repo, a dry run, a declined confirmation,
# an unknown flag and a docs repo that already matches all have to stop before
# the push, and `--yes` has to be the only thing that reaches it.
#
# Runs against a stub `git` that records every invocation and refuses to push
# unless the case under test has said a push is expected. No network, no
# repository, no push.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "publish: $*" >&2; exit 1; }

# --- the fixture organization --------------------------------------------------

ORGAMI_HOME="$fixture/home"
export ORGAMI_COMPANY=acme
home="$ORGAMI_HOME/acme"
mkdir -p "$home/reports" "$home/map" "$fixture/bin"

config() { # config <docs_repo-or-empty>
  if [[ -n ${1-} ]]; then
    jq -n --arg r "$1" '{org: "acme", docs_repo: $r, docs_path: "orgami"}'
  else
    jq -n '{org: "acme"}'
  fi >"$home/config.json"
}

cat >"$home/reports/2026-W20.md" <<'REPORT'
# acme — 2026-W20

Four pull requests merged, two of them by people.

## Summary

Nothing shipped that anyone has to act on.

## Action required

- someone has to rotate the deploy key
REPORT

# --- the stub -------------------------------------------------------------------
# Records every invocation to $GIT_LOG and answers the handful of questions
# publish asks. A push is a hard failure unless STUB_ALLOW_PUSH says the case
# under test expects one, so a refusal path that ever reaches the push fails
# loudly here rather than being asserted away afterwards.

cat >"$fixture/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"

args=("$@")
[[ ${args[0]-} == -C ]] && args=("${args[@]:2}")
[[ ${args[0]-} == --no-pager ]] && args=("${args[@]:1}")

case ${args[0]-} in
  clone)
    # The last argument is the destination. A .git directory is all publish
    # looks at afterwards.
    mkdir -p "${args[$((${#args[@]} - 1))]}/.git"
    ;;
  rev-parse)
    case "$*" in
      *--abbrev-ref*) echo "origin/main" ;;
      *--verify*) exit 0 ;;
    esac
    ;;
  symbolic-ref) echo main ;;
  status) [[ ${STUB_DIRTY:-1} == 1 ]] && echo " M orgami/reports/README.md" ;;
  diff) echo " orgami/reports/README.md | 2 +-" ;;
  push)
    if [[ ${STUB_ALLOW_PUSH:-0} != 1 ]]; then
      echo "STUB GIT REFUSED A PUSH: publish reached 'git $*' on a path that must never push" >&2
      exit 1
    fi
    ;;
esac
exit 0
STUB
chmod +x "$fixture/bin/git"
PATH="$fixture/bin:$PATH"
export GIT_LOG="$fixture/git.log"
: >"$GIT_LOG"

# --- proof the stub is the git that runs ----------------------------------------
# Everything below asserts on a log the stub writes and on pushes the stub
# refuses, so both claims are worth nothing until they are shown to be true.

[[ $(command -v git) == "$fixture/bin/git" ]] ||
  fail "the stub is not the git on PATH — refusing to run: $(command -v git)"
git push origin HEAD 2>"$fixture/err" && fail "the stub must refuse a push by default"
grep -q 'STUB GIT REFUSED A PUSH' "$fixture/err" ||
  fail "a refused push must say so loudly, got '$(cat "$fixture/err")'"
grep -qx 'push origin HEAD' "$GIT_LOG" || fail "the stub must record every invocation"

# --- the harness ------------------------------------------------------------------
# Run through a fresh `bash -c` the way `bin/orgami` does, rather than calling
# the function in this shell: `OUT=$(...) || RC=$?` puts the call inside a
# `||` list, and bash suspends `set -e` for everything underneath one — so a
# sourced `cmd_publish` would sail past a failing git that the real dispatcher
# would stop on.

defaults() { STUB_DIRTY=1; STUB_ALLOW_PUSH=0; ANSWER=""; }
defaults
export ORGAMI_HOME STUB_DIRTY STUB_ALLOW_PUSH

run() { # run <flags...> — answers the prompt with $ANSWER, sets OUT/ERR/RC/CALLS
  : >"$GIT_LOG"
  RC=0
  OUT=$(bash -c '
      set -euo pipefail
      ROOT=$PWD
      source lib/common.sh
      source lib/publish.sh
      cmd_publish "$@"
    ' orgami "$@" <<<"$ANSWER" 2>"$fixture/err") || RC=$?
  ERR=$(cat "$fixture/err")
  CALLS=$(cat "$GIT_LOG")
  # The stub shouts rather than failing quietly, so a push nobody expected is a
  # failure of this test wherever it happens, not something an assertion below
  # has to remember to look for.
  if [[ $STUB_ALLOW_PUSH != 1 ]] && grep -q 'STUB GIT REFUSED A PUSH' <<<"$ERR"; then
    fail "$ERR"
  fi
  defaults
}

pushed() { grep -qE '(^| )push ' <<<"$CALLS"; }
committed() { grep -qE '(^| )commit ' <<<"$CALLS"; }

# --- no docs repo: it never even clones ---------------------------------------

config ""
run
[[ $RC == 1 ]] || fail "a company with no docs_repo must be refused, got $RC"
grep -q 'no docs_repo in' <<<"$ERR" || fail "the refusal should say what to set, got '$ERR'"
[[ -z $CALLS ]] || fail "nothing may run git before the docs repo is known, got '$CALLS'"

# --- an unknown flag stops before the clone -----------------------------------

config "git@github.com:acme/engineering.git"
run --force
[[ $RC == 1 ]] || fail "an unknown flag must be refused, got $RC"
grep -q 'unknown flag: --force' <<<"$ERR" || fail "the refusal should name the flag, got '$ERR'"
[[ -z $CALLS ]] || fail "an unknown flag must be caught before any git runs, got '$CALLS'"

# --- a dry run stages, prints, resets and stops -------------------------------

run --dry-run
[[ $RC == 0 ]] || fail "a dry run is not a failure, got $RC: $ERR"
grep -q 'changes to publish in git@github.com:acme/engineering.git:orgami' <<<"$OUT" ||
  fail "a dry run should print what it would publish, got '$OUT'"
grep -q 'orgami/reports/README.md' <<<"$OUT" || fail "a dry run should print the staged diff, got '$OUT'"
grep -q 'reset --quiet' <<<"$CALLS" || fail "a dry run must unstage what it staged, got '$CALLS'"
committed && fail "a dry run must not commit"
pushed && fail "a dry run must not push"

# --- the confirmation, declined -----------------------------------------------

ANSWER=n
run
[[ $RC == 1 ]] || fail "a declined push must fail, got $RC"
grep -q 'orgami: aborted' <<<"$ERR" || fail "a declined push should say it aborted, got '$ERR'"
grep -q 'reset --quiet' <<<"$CALLS" || fail "a declined push must unstage what it staged, got '$CALLS'"
committed && fail "a declined push must not commit"
pushed && fail "a declined push must not push"
declined=$CALLS

# --- and declined by saying nothing at all ------------------------------------
# `[y/N]` means the default is no, so an empty answer has to refuse exactly as
# `n` does — this is the answer an unattended run gives.

ANSWER=""
run
[[ $RC == 1 ]] || fail "an empty answer must refuse, got $RC"
grep -q 'orgami: aborted' <<<"$ERR" || fail "an empty answer should abort, got '$ERR'"
committed && fail "an empty answer must not commit"
pushed && fail "an empty answer must not push"

# --- nothing an environment says can stand in for the flag ---------------------

ANSWER=n
export CI=1 ORGAMI_YES=1 YES=1 ORGAMI_NONINTERACTIVE=1
run
unset CI ORGAMI_YES YES ORGAMI_NONINTERACTIVE
[[ $RC == 1 ]] || fail "no environment variable may answer the prompt, got $RC"
pushed && fail "no environment variable may reach the push"

# --- a docs repo that already matches ------------------------------------------

STUB_DIRTY=0
run --yes
[[ $RC == 0 ]] || fail "nothing to publish is not a failure, got $RC: $ERR"
grep -q 'nothing to publish' <<<"$OUT" || fail "it should say why it did nothing, got '$OUT'"
committed && fail "an empty diff must not be committed"
pushed && fail "an empty diff must not be pushed"

# --- and what --yes is for ------------------------------------------------------

STUB_ALLOW_PUSH=1
run --yes
[[ $RC == 0 ]] || fail "--yes should publish, got $RC: $ERR"
grep -q 'commit --quiet -m docs(orgami): acme ' <<<"$CALLS" ||
  fail "--yes should commit the map, got '$CALLS'"
grep -q 'push --quiet origin HEAD' <<<"$CALLS" || fail "--yes should push, got '$CALLS'"
grep -q '^pushed: docs(orgami): acme ' <<<"$OUT" || fail "the push should be reported, got '$OUT'"
grep -q 'push to git@github' <<<"$OUT$ERR" && fail "--yes must not have prompted"

# --- the page leaves without the live reading, unless it may -------------------
# map/orgami.html inlines map/live.json, and live.json leaves the machine only
# when live_publish says so. So the published page is a fresh render with the
# reading read as missing, and a plain copy once the org has said it may go.
# The local page is never touched.

printf '%s\n' '{"generated":"2026-08-18T06:30:11Z","providers":["fly"],"deployments":[{"repo":"api","provider":"fly","name":"acme-api-secret-name","state":"running","urls":[]}],"unmatched":[]}' >"$home/map/live.json"
echo '<!doctype html><title>local page</title>acme-api-secret-name' >"$home/map/orgami.html"
published="$home/cache/docs/orgami/orgami.html"
STUB_ALLOW_PUSH=1
run --yes
[[ $RC == 0 ]] || fail "publishing with a page and a live reading should work, got $RC: $ERR"
[[ -f $published ]] || fail "the page must be published"
grep -q '<script id="data"' "$published" || fail "without live_publish the page must be rendered afresh, not copied"
grep -q 'acme-api-secret-name' "$published" && fail "without live_publish the published page must not carry the live reading"
grep -q '"missing":"orgami live' "$published" || fail "the published page should say the live reading was not read"
grep -q 'acme-api-secret-name' "$home/map/orgami.html" || fail "the local page must be left as it was"
grep -q '](orgami.html)' "$home/cache/docs/orgami/README.md" || fail "the front page should link the page"

jq '. + {live_publish: true}' "$home/config.json" >"$home/config.tmp" && mv "$home/config.tmp" "$home/config.json"
STUB_ALLOW_PUSH=1
run --yes
[[ $RC == 0 ]] || fail "publishing with live_publish should work, got $RC: $ERR"
grep -q 'acme-api-secret-name' "$published" || fail "with live_publish the page is copied as it is"
rm -f "$home/map/live.json" "$home/map/orgami.html"
config "git@github.com:acme/engineering.git"

# --- --yes reaches the push, and nothing else does -----------------------------
# The behaviour above pins that the flag works and that answering the prompt
# does not. What it cannot show is that no future edit sets `yes` from somewhere
# other than the flag, or hands `--yes` in from a caller nobody looked at.

[[ $(grep -c 'yes=1' lib/publish.sh) == 1 ]] ||
  fail "yes is set in more than one place — only the flag may set it"
grep -q -- '--yes|-y) yes=1' lib/publish.sh || fail "the one place yes is set is not the flag arm"

callers=$(grep -rn '^[^#]*cmd_publish' bin lib | grep -v 'cmd_publish() {')
[[ $(grep -c . <<<"$callers") == 2 ]] ||
  fail "publish has call sites nobody has looked at: $callers"
grep -q '^bin/orgami:[0-9]*: *cmd_publish "\$@"$' <<<"$callers" ||
  fail "the dispatcher should pass the user's flags through and nothing else: $callers"
[[ $(grep -c -- '--yes' <<<"$callers") == 1 ]] ||
  fail "more than one caller supplies --yes: $callers"
sed -n '/^cmd_weekly() {/,/^}/p' lib/publish.sh | grep -q 'cmd_publish --yes' ||
  fail "the one caller supplying --yes should be cmd_weekly"

# The declined-confirmation call log, so the reader can see for themselves that
# a refusal ends at the reset.
if [[ -n ${ORGAMI_TEST_SHOW_CALLS:-} ]]; then
  echo "--- git calls on the declined-confirmation path ---" >&2
  printf '%s\n' "$declined" >&2
fi

echo "publish: refuses without a docs repo, on a dry run, on a declined prompt and on an unknown flag"
