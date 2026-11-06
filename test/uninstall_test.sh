#!/usr/bin/env bash
# `orgami uninstall` deletes things, so what it may delete is pinned: everything
# install.sh, `orgami schedule`, `orgami agents` and bootstrap.sh put on a
# machine, and nothing else — not another tool's entries in a shared Cursor
# file, not the rest of a git hook or a crontab, not a link into somebody
# else's tree, and with --purge not a clone that holds uncommitted work. It
# never asks a remote anything.
#
# A temp HOME is populated by running a scratch clone's own install.sh into it,
# plus Cursor files, a crontab, an enabled timer, a git hook and a plugin
# record. systemctl, claude, crontab and gh are stubs that log their arguments.
# Nothing outside the temp directory is read for writing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."


fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "uninstall: $*" >&2; exit 1; }

# Anything that would send install.sh or uninstall outside the temp HOME.
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME BASH_COMPLETION_USER_DIR \
  ORGAMI_HOME ORGAMI_COMPANY ORGAMI_SRC CLAUDE_CONFIG_DIR HOMEBREW_PREFIX CLAUDE_PLUGIN_ROOT
export HOME="$fixture/home" ORGAMI_AUTOUPDATE=0
mkdir -p "$HOME"
calls="$fixture/calls.log"
: >"$calls"

# --- stubs -----------------------------------------------------------------
stub="$fixture/stub"
mkdir -p "$stub"
for t in systemctl claude gh; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$t" "$calls" >"$stub/$t"
done
# `disable` takes the timers.target.wants link away, as the real one does.
cat >"$stub/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >>"$calls"
[ "\$2" = disable ] && rm -f "$HOME/.config/systemd/user/timers.target.wants/\$4"
exit 0
EOF
# gh auth status is what install.sh asks; failing it keeps install.sh quiet.
printf '#!/bin/sh\necho "gh $*" >>"%s"\nexit 1\n' "$calls" >"$stub/gh"
cat >"$stub/crontab" <<EOF
#!/bin/sh
echo "crontab \$*" >>"$calls"
if [ "\$1" = -l ]; then cat "$fixture/crontab" 2>/dev/null; exit 0; fi
cp "\$1" "$fixture/crontab"
EOF
chmod +x "$stub"/*
export PATH="$stub:/usr/local/bin:/usr/bin:/bin"

# --- a clone where bootstrap.sh puts one, committed so it is clean -------------
clone="$HOME/.local/share/orgami"
mkdir -p "$clone"
cp -R bin lib hooks completions skills systemd commands .claude-plugin manifest.json install.sh "$clone/"
git -C "$clone" init -q
git -C "$clone" add -A
git -C "$clone" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init

# The completion directories install.sh links into only when they exist.
mkdir -p "$HOME/.local/share/bash-completion/completions" "$HOME/.zsh/completions"
bash "$clone/install.sh" >/dev/null 2>&1 || fail "install.sh failed in the temp HOME"
for f in .local/bin/orgami .local/share/bash-completion/completions/orgami .zsh/completions/_orgami \
  .claude/skills/orgami/SKILL.md .config/systemd/user/orgami-weekly@.timer; do
  [[ -e $HOME/$f || -L $HOME/$f ]] || fail "install.sh did not create ~/$f, so this test has nothing to remove"
done

# --- what the rest of orgami would have added ----------------------------------
units="$HOME/.config/systemd/user"
mkdir -p "$units/timers.target.wants"
ln -s ../orgami-weekly@.timer "$units/timers.target.wants/orgami-weekly@acme.timer"
cp "$units/orgami-weekly@.service" "$units/orgami-daily@.service"

printf '%s\n' "MAILTO=me" \
  "0 17 * * 5 PATH=$HOME/.local/bin:/usr/bin ORGAMI_COMPANY=acme $HOME/.local/bin/orgami weekly >/dev/null 2>&1" \
  "5 4 * * * /usr/bin/backup" >"$fixture/crontab"

mkdir -p "$HOME/.cursor"
jq -n --arg s "$clone/hooks/session-context.sh" '{version: 1, hooks: {sessionStart: [
  {command: "bash \"\($s)\" --json", type: "command", timeout: 15},
  {command: "other-tool start", type: "command"}]}}' >"$HOME/.cursor/hooks.json"
jq -n --arg b "$HOME/.local/bin/orgami" '{mcpServers: {orgami: {command: $b, args: ["mcp"]},
  other: {command: "other", args: []}}}' >"$HOME/.cursor/mcp.json"

mkdir -p "$HOME/.claude/plugins"
echo '{"version": 2, "plugins": {"orgami@orgami": [{"scope": "user", "installPath": "/nowhere", "version": "1.1.0"}]}}' \
  >"$HOME/.claude/plugins/installed_plugins.json"
echo '{"orgami": {"source": {"source": "github", "repo": "Oldault/orgami"}}}' \
  >"$HOME/.claude/plugins/known_marketplaces.json"

# The git hooks `orgami agents --git-hook` writes: one new, one appended to.
hooks="$HOME/work/api/.git/hooks"
mkdir -p "$hooks"
gh_comment='# orgami: keep the generated context block current'
gh_line='command -v orgami >/dev/null && orgami agents >/dev/null 2>&1 || true'
printf '#!/bin/sh\n%s\n%s\n' "$gh_comment" "$gh_line" >"$hooks/post-merge"
printf '#!/bin/sh\necho mine\n\n%s\n%s\n' "$gh_comment" "$gh_line" >"$hooks/post-checkout"

mkdir -p "$HOME/.orgami/acme" "$HOME/.local/state/orgami"
echo '{"default": "acme"}' >"$HOME/.orgami/config.json"
jq -n --arg w "$HOME/work" '{org: "acme", docs_repo: "https://github.com/acme/orgami-docs", workspaces: [$w]}' \
  >"$HOME/.orgami/acme/config.json"

# Somebody else's tool next to the link: ~/.local/bin is not left empty, so it stays.
printf '#!/bin/sh\n' >"$HOME/.local/bin/other-tool"

# Not ours, though it has our name: a link into a tree with no bin/orgami.
mkdir -p "$fixture/elsewhere" "$HOME/.local/share/zsh/site-functions"
ln -s "$fixture/elsewhere/completions/orgami.zsh" "$HOME/.local/share/zsh/site-functions/_orgami"
touch "$fixture/elsewhere/keep"

snapshot() { (cd "$HOME" && find . | LC_ALL=C sort) && cat "$fixture/crontab"; }
before=$(snapshot)

cd "$HOME"
bin="$clone/bin/orgami"

# --- no terminal, no --yes: refuse, name the flag, change nothing ----------------
: >"$calls"
if err=$("$bin" uninstall </dev/null 2>&1 >/dev/null); then fail "ran with no terminal and no --yes"; fi
[[ $err == *--yes* ]] || fail "the no-terminal refusal does not name --yes: $err"
[[ $(snapshot) == "$before" ]] || fail "the refused run changed something"

# --- --dry-run: the whole plan, nothing done ------------------------------------
plan=$("$bin" uninstall --dry-run </dev/null) || fail "--dry-run exited non-zero"
[[ $(snapshot) == "$before" ]] || fail "--dry-run changed something"
for want in "$HOME/.local/bin/orgami" "disable --now orgami-weekly@acme.timer" "crontab" \
  ".cursor/hooks.json" ".cursor/mcp.json" "$hooks/post-merge" "claude plugin uninstall orgami@orgami" \
  "marketplace remove orgami" "https://github.com/acme/orgami-docs" "never touches a remote"; do
  [[ $plan == *"$want"* ]] || fail "--dry-run does not mention $want"
done
changed=$(grep -vx 'crontab -l' "$calls" || true)
[[ -z $changed ]] || fail "the refused run or --dry-run called a tool that changes something: $changed"

# --- --yes: everything installed goes, the rest stays ---------------------------
: >"$calls"
"$bin" uninstall --yes </dev/null >/dev/null 2>&1 || fail "--yes exited non-zero"
for f in .local/bin/orgami .local/share/bash-completion/completions/orgami .zsh/completions/_orgami \
  .claude/skills/orgami .config/systemd/user/orgami-weekly@.timer .config/systemd/user/orgami-weekly@.service \
  .config/systemd/user/orgami-daily@.service .local/state/orgami work/api/.git/hooks/post-merge; do
  [[ -e $HOME/$f || -L $HOME/$f ]] && fail "$HOME/$f is still there"
done
# The directories orgami's files were the only thing in go with them.
for d in .claude/skills .config/systemd/user .config/systemd .local/state; do
  [[ -e $HOME/$d ]] && fail "$HOME/$d is left empty: $(ls -A "$HOME/$d")"
done
[[ -f $HOME/.local/bin/other-tool ]] || fail "removed another tool from ~/.local/bin"
grep -qx "systemctl --user disable --now orgami-weekly@acme.timer" "$calls" || fail "the timer was not stopped first"
grep -qx "systemctl --user daemon-reload" "$calls" || fail "systemd was not told the units are gone"
grep -qx "claude plugin uninstall orgami@orgami" "$calls" || fail "the plugin was not uninstalled"
grep -qx "claude plugin marketplace remove orgami" "$calls" || fail "the marketplace was not removed"
[[ $(cat "$fixture/crontab") == $'MAILTO=me\n5 4 * * * /usr/bin/backup' ]] ||
  fail "the crontab lost more than orgami's line: $(cat "$fixture/crontab")"
jq -e '.hooks.sessionStart == [{command: "other-tool start", type: "command"}]' "$HOME/.cursor/hooks.json" >/dev/null ||
  fail "hooks.json lost another tool's entry or kept orgami's: $(cat "$HOME/.cursor/hooks.json")"
jq -e '.mcpServers == {other: {command: "other", args: []}}' "$HOME/.cursor/mcp.json" >/dev/null ||
  fail "mcp.json lost another server or kept orgami's"
[[ $(cat "$hooks/post-checkout") == $'#!/bin/sh\necho mine' ]] ||
  fail "the appended git hook lost its own lines: $(cat "$hooks/post-checkout")"
[[ -L $HOME/.local/share/zsh/site-functions/_orgami ]] || fail "removed a link that points into somebody else's tree"
[[ -f $HOME/.orgami/acme/config.json ]] || fail "removed ~/.orgami without --purge"
[[ -f $clone/bin/orgami ]] || fail "removed the clone without --purge"
[[ -f $fixture/elsewhere/keep ]] || fail "touched a file outside HOME"

# --- --purge: the data and the clone, last ----------------------------------------
# A clone with uncommitted work is a checkout, not an install, and stays.
echo "# local" >>"$clone/install.sh"
"$bin" uninstall --purge --yes </dev/null >/dev/null 2>"$fixture/err" || fail "--purge exited non-zero: $(cat "$fixture/err")"
[[ -d $HOME/.orgami ]] && fail "--purge left ~/.orgami"
[[ -f $clone/bin/orgami ]] || fail "--purge removed a clone with uncommitted changes"
git -C "$clone" checkout -q -- install.sh
"$clone/bin/orgami" uninstall --purge --yes </dev/null >/dev/null 2>&1 || fail "--purge of a clean clone exited non-zero"
[[ -e $clone ]] && fail "--purge left the clean clone at $clone"
# Left: the directories something else is still in, and nothing empty of ours.
# The two completion directories were made by this test, as a person would.
[[ -f $HOME/.local/bin/other-tool && -L $HOME/.local/share/zsh/site-functions/_orgami ]] ||
  fail "--purge removed a directory with somebody else's files in it"
empty=$(cd "$HOME" && find . -mindepth 1 -type d -empty \
  ! -path './work/*' ! -path './.local/share/bash-completion*' ! -path ./.zsh/completions | LC_ALL=C sort)
[[ -z $empty ]] || fail "--purge left empty directories: $empty"
[[ -f $fixture/elsewhere/keep ]] || fail "touched a file outside HOME"

echo "uninstall: everything installed removed, every shared file kept its other entries"
