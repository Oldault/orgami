#!/usr/bin/env bash
# `orgami update` runs unattended — at session start and from the weekly timer —
# so the only thing that matters is what it refuses. A checkout with work in it,
# a checkout with commits of its own, a checkout tracking nothing, and the clone
# Claude Code owns: all four are left exactly as they were.
#
# Runs against real git repositories in a temp directory. No network, no remote,
# and nothing installed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/update.sh
source lib/update.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

export XDG_STATE_HOME="$fixture/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$fixture/gitconfig"
: >"$GIT_CONFIG_GLOBAL"

fail() { echo "update: $*" >&2; exit 1; }

q() { "$@" >/dev/null 2>&1; }

# An upstream with two commits, and a clone sitting on the first.
q git init --bare -b main "$fixture/origin.git"
q git clone "$fixture/origin.git" "$fixture/seed"
echo '{"version": "1.0.0"}' >"$fixture/seed/manifest.json"
q git -C "$fixture/seed" add -A
q git -C "$fixture/seed" commit -m "first"
q git -C "$fixture/seed" push -u origin main

q git clone "$fixture/origin.git" "$fixture/install"

echo '{"version": "1.0.1"}' >"$fixture/seed/manifest.json"
q git -C "$fixture/seed" commit -am "fix: the thing"
q git -C "$fixture/seed" push
q git -C "$fixture/install" fetch origin

# --- a clean install is fair game --------------------------------------------

if why=$(update_why_not "$fixture/install"); then
  fail "a clean tracking clone should be updatable, refused with: $why"
fi

# --- work in the tree is not ---------------------------------------------------

echo "local edit" >>"$fixture/install/manifest.json"
why=$(update_why_not "$fixture/install") ||
  fail "a checkout with uncommitted work must be refused"
grep -q 'uncommitted' <<<"$why" || fail "the refusal should say why, got '$why'"
q git -C "$fixture/install" checkout -- manifest.json

# --- and neither is a checkout with commits of its own -------------------------

before=$(git -C "$fixture/install" rev-parse HEAD)
echo '{"version": "1.0.0-mine"}' >"$fixture/install/manifest.json"
q git -C "$fixture/install" commit -am "mine"
mine=$(git -C "$fixture/install" rev-parse HEAD)
update_cli "$fixture/install" 1 && fail "a diverged checkout must not be updated"
[[ $(git -C "$fixture/install" rev-parse HEAD) == "$mine" ]] ||
  fail "a diverged checkout was moved"
q git -C "$fixture/install" reset --hard "$before"

# --- tracking nothing ----------------------------------------------------------

q git -C "$fixture/install" checkout -b orphan
why=$(update_why_not "$fixture/install") ||
  fail "a branch tracking no upstream must be refused"
grep -q 'upstream' <<<"$why" || fail "the refusal should say why, got '$why'"
q git -C "$fixture/install" checkout main

# --- the clone Claude Code owns ------------------------------------------------

update_is_plugin_dir "$HOME/.claude/plugins/marketplaces/orgami" ||
  fail "the plugin clone must be recognised as somebody else's"
update_is_plugin_dir "$fixture/install" &&
  fail "an ordinary install must not be mistaken for the plugin clone"
update_cli "$HOME/.claude/plugins/marketplaces/orgami" 1 &&
  fail "the plugin clone must never be pulled directly"

# --- what it does when it is allowed to ----------------------------------------

update_cli "$fixture/install" 1 || fail "a clean clone behind its upstream should update"
[[ $(git -C "$fixture/install" rev-parse HEAD) == \
   $(git -C "$fixture/install" rev-parse '@{u}') ]] ||
  fail "the clone did not fast-forward"

# What moved is left for the next session to say, once.
report=$(update_report)
grep -q '1.0.0 -> 1.0.1' <<<"$report" || fail "the version change should be reported, got '$report'"
grep -q 'fix: the thing' <<<"$report" || fail "what changed should be reported, got '$report'"
[[ -z $(update_report) ]] || fail "an update must be announced once, not every session"

# Nothing left to do, and it says nothing rather than inventing something.
update_cli "$fixture/install" 1 && fail "an up-to-date clone must report no change"

# --- every copy on the machine, not just the one running ------------------------

# A plugin hook runs the plugin's copy; the clone that owns the CLI on PATH is a
# different directory. Updating only the copy that happens to be executing
# leaves the other one behind forever.
mkdir -p "$fixture/path-install/bin" "$fixture/path-install/lib" "$fixture/fakebin"
: >"$fixture/path-install/bin/orgami"
chmod +x "$fixture/path-install/bin/orgami"
ln -sf "$fixture/path-install/bin/orgami" "$fixture/fakebin/orgami"

targets=$(PATH="$fixture/fakebin:$PATH" update_targets)
grep -qx "$ROOT" <<<"$targets" || fail "the running copy should be a target, got '$targets'"
grep -qx "$fixture/path-install" <<<"$targets" ||
  fail "the clone behind the CLI on PATH should be a target, got '$targets'"

# The same directory twice is one update, not two.
ln -sf "$ROOT/bin/orgami" "$fixture/fakebin/orgami"
targets=$(PATH="$fixture/fakebin:$PATH" update_targets)
[[ $(grep -c . <<<"$targets") == 1 ]] ||
  fail "one clone reached two ways is still one clone, got '$targets'"

# --- ahead of an upstream it already contains -----------------------------------
# --ff-only calls that "already up to date" and succeeds, so the success alone
# is not proof the clone moved: install.sh must not run and nothing may be
# announced.

q git -C "$fixture/install" reset --hard '@{u}'
echo '{"version": "1.0.1-mine"}' >"$fixture/install/manifest.json"
# shellcheck disable=SC2016  # expanded by the install.sh it writes, not here
echo 'touch "$(dirname "$0")/../installed"' >"$fixture/install/install.sh"
q git -C "$fixture/install" add -A
q git -C "$fixture/install" commit -m "mine, on top"
mine=$(git -C "$fixture/install" rev-parse HEAD)
why_not=$(update_why_not "$fixture/install") && fail "the ahead clone should pass the cheap checks, got: $why_not"
update_cli "$fixture/install" 1 && fail "a clone ahead of its upstream must not count as updated"
[[ $(git -C "$fixture/install" rev-parse HEAD) == "$mine" ]] || fail "a clone ahead was moved"
[[ -e $fixture/installed ]] && fail "install.sh must not run from a clone that did not fast-forward"
[[ -z $(update_report) ]] || fail "a clone that did not move must not be announced"

# --- the opt-out holds for every run nobody typed ----------------------------------
# A stub git and claude on PATH record every call. Opted out, an automatic run —
# the timer's --auto, the session hook's --if-stale, and the detached child
# either starts — must touch neither; a person's `orgami update` still updates.

mkdir -p "$fixture/stubbin" "$fixture/orgami-home"
cat >"$fixture/stubbin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >>"$STUB_LOG"
exit 1
STUB
cat >"$fixture/stubbin/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude $*" >>"$STUB_LOG"
exit 1
STUB
chmod +x "$fixture/stubbin/git" "$fixture/stubbin/claude"
export STUB_LOG="$fixture/stub.log"
# Recorded rather than run, so a detached child that should not exist is seen
# here and not raced.
detach() { echo "detach $*" >>"$STUB_LOG"; }

auto_run() { # auto_run <flags...> — sets CALLS to what the stubs saw
  : >"$STUB_LOG"
  rm -f "$XDG_STATE_HOME/orgami/update-checked"
  PATH="$fixture/stubbin:$PATH" ORGAMI_HOME="$fixture/orgami-home" \
    ORGAMI_BIN="$fixture/stubbin/git" cmd_update "$@" >/dev/null 2>&1 || true
  CALLS=$(cat "$STUB_LOG")
}

for optout in env config; do
  if [[ $optout == env ]]; then
    export ORGAMI_AUTOUPDATE=0
    rm -f "$fixture/orgami-home/config.json"
  else
    unset ORGAMI_AUTOUPDATE
    echo '{"auto_update": false}' >"$fixture/orgami-home/config.json"
  fi
  for flags in "--quiet --auto" "--if-stale" "--if-stale --background" "--quiet --auto --background"; do
    # shellcheck disable=SC2086  # the flags are meant to split
    auto_run $flags
    [[ -z $CALLS ]] || fail "opted out by $optout, 'update $flags' must do nothing, ran: $CALLS"
  done
  auto_run --quiet
  grep -q '^git ' <<<"$CALLS" || fail "opted out by $optout, a typed 'orgami update' must still update"
done
unset ORGAMI_AUTOUPDATE
rm -f "$fixture/orgami-home/config.json"

# Not opted out, the automatic run goes ahead, and the detached child it starts
# carries --auto so it checks the opt-out for itself.
auto_run --quiet --auto
grep -q '^git ' <<<"$CALLS" || fail "without an opt-out, --auto should update"
auto_run --if-stale --background
grep -q '^detach /dev/null .* update --quiet --auto$' <<<"$CALLS" ||
  fail "the session hook's detached update should carry --auto, ran: $CALLS"

echo "update: refuses dirty, diverged, ahead, untracked and the plugin clone; honours the opt-out; announces once"
