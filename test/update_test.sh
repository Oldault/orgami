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
# Claude Code's records are read from here, never from the real ~/.claude.
export CLAUDE_CONFIG_DIR="$fixture/claude"
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

targets=$(HOME="$fixture" PATH="$fixture/fakebin:$PATH" update_targets)
grep -qx "$ROOT" <<<"$targets" || fail "the running copy should be a target, got '$targets'"
grep -qx "$fixture/path-install" <<<"$targets" ||
  fail "the clone behind the CLI on PATH should be a target, got '$targets'"

# A HOME that is not the one the CLI on PATH was installed into — a scratch
# HOME, with the real ~/.local/bin still on PATH — leaves that clone alone.
mkdir -p "$fixture/scratch-home"
targets=$(HOME="$fixture/scratch-home" PATH="$fixture/fakebin:$PATH" update_targets)
grep -qx "$fixture/path-install" <<<"$targets" &&
  fail "a clone outside this HOME must not be a target, got '$targets'"
grep -qx "$ROOT" <<<"$targets" || fail "the running copy is a target in any HOME, got '$targets'"

# The same directory twice is one update, not two.
ln -sf "$ROOT/bin/orgami" "$fixture/fakebin/orgami"
targets=$(HOME="$fixture" PATH="$fixture/fakebin:$PATH" update_targets)
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

# --- the Claude Code plugin moves, and only a moved version counts ------------------
# `marketplace update` refreshes the catalog clone and exits 0 while the copy
# sessions load stays where it was; `plugin update` is what moves that copy.
# A stub claude does what each of them does to Claude Code's files, so the
# test reads back the same record a real update would leave.

mkdir -p "$fixture/claudebin" "$CLAUDE_CONFIG_DIR/plugins"
market="$CLAUDE_CONFIG_DIR/plugins/marketplaces/orgami"
mkdir -p "$(dirname "$market")"
q git clone "$fixture/origin.git" "$market"
mkdir -p "$market/.claude-plugin"
jq -n --arg m "$market" '{orgami: {source: {source: "github", repo: "Oldault/orgami"}, installLocation: $m}}' \
  >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
plugin_at() { # plugin_at <version> — what installed_plugins.json records
  jq -n --arg v "$1" --arg p "$CLAUDE_CONFIG_DIR/plugins/cache/orgami/orgami/$1" \
    '{version: 2, plugins: {"orgami@orgami": [{scope: "user", installPath: $p, version: $v, gitCommitSha: "abc1234"}]}}' \
    >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
}
cat >"$fixture/claudebin/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude $*" >>"$STUB_LOG"
case "$*" in
  "plugin marketplace update orgami")
    printf '{"name": "orgami", "version": "%s"}\n' "$STUB_OFFERS" >"$STUB_MARKET/.claude-plugin/plugin.json" ;;
  "plugin update orgami@orgami")
    [[ ${STUB_MOVES:-1} == 1 ]] || exit 0
    f="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    jq --arg v "$STUB_OFFERS" '.plugins["orgami@orgami"][0].version = $v' "$f" >"$f.tmp" && mv "$f.tmp" "$f" ;;
esac
exit 0
STUB
chmod +x "$fixture/claudebin/claude"
export STUB_MARKET="$market" STUB_OFFERS=1.2.0

plugin_run() { # plugin_run — sets OUT, ERR, RC and CALLS
  : >"$STUB_LOG"
  RC=0
  PATH="$fixture/claudebin:$PATH" update_plugin 0 >"$fixture/out" 2>"$fixture/err" || RC=$?
  OUT=$(cat "$fixture/out") ERR=$(cat "$fixture/err") CALLS=$(cat "$STUB_LOG")
}
installed() { jq -r '.plugins["orgami@orgami"][0].version' "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }

rm -f "$XDG_STATE_HOME/orgami/updated"
plugin_at 1.1.0
plugin_run
grep -qx 'claude plugin update orgami@orgami' <<<"$CALLS" ||
  fail "a newer plugin in the marketplace must be installed with claude plugin update, ran: $CALLS"
[[ $RC == 0 && $(installed) == 1.2.0 ]] || fail "the plugin should end at 1.2.0, is $(installed) (rc $RC)"
grep -q '1.1.0 -> 1.2.0' <<<"$OUT" || fail "the plugin move should be said with both versions, got '$OUT'"
grep -q 'plugin updated 1.1.0 -> 1.2.0' "$XDG_STATE_HOME/orgami/updated" ||
  fail "the plugin move should be left for the next session to announce"

# The field bug: the catalog refreshes, the installed copy does not move. That
# is not an update, and it says what to run instead of claiming success.
plugin_at 1.1.0
STUB_MOVES=0 plugin_run
[[ $RC == 1 ]] || fail "a plugin that did not move must not count as updated"
grep -q 'updated\|->' <<<"$OUT" && fail "a plugin that did not move must not be announced, got '$OUT'"
grep -q 'still 1.1.0.*1.2.0.*claude plugin update orgami@orgami' <<<"$ERR" ||
  fail "a plugin left behind should name the command that moves it, got '$ERR'"

# Already the newest: no plugin update is run, nothing is claimed.
plugin_at 1.2.0
plugin_run
[[ $RC == 1 && -z $OUT ]] || fail "an up-to-date plugin must report no change, got '$OUT' (rc $RC)"
grep -q 'plugin update orgami@orgami' <<<"$CALLS" && fail "nothing newer, nothing to install, ran: $CALLS"

# Not installed as a plugin: an update never installs it.
rm -f "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
plugin_run
[[ $RC == 1 && -z $CALLS ]] || fail "no plugin installed, update_plugin must call nothing, ran: $CALLS"

# --- update --check: both copies, the right command, exit 0 ---------------------
# Twenty commits behind, each with a long subject: more --oneline output than
# a pipe holds, so a `git log | head` is killed by SIGPIPE every time and, under
# pipefail, used to end the whole check with 141 before the plugin was listed.

q git -C "$fixture/install" reset --hard '@{u}'
long=$(printf 'x%.0s' $(seq 1 5000))
for i in $(seq 1 20); do
  echo "$i" >"$fixture/seed/n"
  q git -C "$fixture/seed" add -A
  q git -C "$fixture/seed" commit -m "change $i $long"
done
q git -C "$fixture/seed" push
plugin_at 1.1.0
printf '{"name": "orgami", "version": "1.2.0"}\n' >"$market/.claude-plugin/plugin.json"
# A shell of its own, set up the way bin/orgami runs: errexit is ignored in a
# command substitution tested with ||, so in this one a 141 would pass unseen.
check_run() {
  ROOT="$fixture/install" PATH="$fixture/claudebin:/usr/bin:/bin" \
    bash -c 'set -euo pipefail; source lib/common.sh; source lib/update.sh; cmd_update --check' 2>&1
}
rc=0
check=$(check_run) || rc=$?
[[ $rc == 0 ]] || fail "update --check must exit 0, got $rc: ${check:0:300}"
grep -q "$fixture/install, 20 commit(s) behind" <<<"$check" || fail "the CLI clone should be listed as behind, got: ${check:0:300}"
[[ $(grep -c '^  ' <<<"$check") == 10 ]] || fail "update --check should list ten of the commits"
grep -q '^1.1.0 — Claude Code plugin .*1.2.0 in the marketplace. Run: orgami update' <<<"$check" ||
  fail "update --check should list the plugin with the command that moves it, got: $(tail -1 <<<"$check")"
grep -q 'claude plugin marketplace update' <<<"$check" &&
  fail "update --check must not name marketplace update as what updates the plugin"

# Same version, but the catalog clone is behind its remote: there is more to
# fetch, and ls-remote finds it without writing into Claude Code's clone.
plugin_at 1.2.0
mhead=$(git -C "$market" rev-parse HEAD)
check=$(check_run)
grep -q '^1.2.0 — Claude Code plugin .*, the marketplace has newer commits. Run: orgami update' <<<"$check" ||
  fail "a catalog behind its remote should be said, got: $(tail -1 <<<"$check")"
[[ $(git -C "$market" rev-parse HEAD) == "$mhead" ]] || fail "update --check must not move the marketplace clone"

q git -C "$market" pull --ff-only
check=$(check_run)
grep -q '^1.2.0 — Claude Code plugin .*, up to date' <<<"$check" ||
  fail "an up-to-date plugin should say so, got: $(tail -1 <<<"$check")"

# `update --dev` points the marketplace at a working checkout, ahead of its
# remote on purpose: that is where it is installed from, not an update to fetch.
q git -C "$fixture/seed" commit --allow-empty -m "dev work"
cp -R "$market/.claude-plugin" "$fixture/seed/"
jq -n --arg m "$fixture/seed" '{orgami: {installLocation: $m}}' >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
check=$(check_run)
grep -q "^1.2.0 — Claude Code plugin .*, installed from the checkout $fixture/seed\$" <<<"$check" ||
  fail "a dev-linked plugin should name its checkout, got: $(tail -1 <<<"$check")"

echo "update: refuses dirty, diverged, ahead, untracked and the plugin clone; honours the opt-out; announces once; moves the plugin and checks both"
