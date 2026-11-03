#!/usr/bin/env bash
# SessionStart: hand Claude the context for whatever repo this session opened in.
# Silent when the directory has nothing to do with a mapped organization.

# claude sets this under --safe-mode. A second guard, beside the flags
# model_call passes, against a model call orgami makes re-entering orgami.
[ "${CLAUDE_CODE_SAFE_MODE:-}" = 1 ] && exit 0

# Before anything else, and in bash 3.2 syntax: plugin.json and Cursor's
# hooks.json run this as `bash <file>`, which on macOS can be /bin/bash 3.2, and
# orgami needs 4.4. Find a newer bash and run under it, with its directory first
# on PATH so the `orgami` this calls (`#!/usr/bin/env bash`) gets it too. With
# none, say nothing: an error here would land in the agent's session.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
  { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  [ -z "${ORGAMI_HOOK_REEXEC:-}" ] || exit 0
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash \
    "$(command -v bash 2>/dev/null)"; do
    [ -x "$b" ] || continue
    "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null || continue
    PATH="$(dirname "$b"):$PATH" ORGAMI_HOOK_REEXEC=1 exec "$b" "$0" "$@"
  done
  exit 0
fi

set -uo pipefail

# The CLI on PATH, else where install.sh links it (an editor started from a
# dock can have a PATH without ~/.local/bin), else the plugin's own copy.
ORGAMI=$(command -v orgami 2>/dev/null)
[[ -z $ORGAMI && -x $HOME/.local/bin/orgami ]] && ORGAMI="$HOME/.local/bin/orgami"

# A plugin with no CLI linked still reads the map through its own copy, but
# every `orgami ...` the skill tells the agent to run would fail, so the session
# is told the one command that fixes it. Every session until it is run: one line.
nudge=""
if [[ -z $ORGAMI && -n ${CLAUDE_PLUGIN_ROOT:-} && -x $CLAUDE_PLUGIN_ROOT/bin/orgami ]]; then
  ORGAMI="$CLAUDE_PLUGIN_ROOT/bin/orgami"
  nudge="The orgami CLI is not installed, so \`orgami\` commands will fail — offer to run: bash \"$CLAUDE_PLUGIN_ROOT/install.sh\""
fi
[[ -n $ORGAMI ]] || exit 0

# Cursor's sessionStart hook wants JSON on stdout with an additional_context key.
# Claude Code's takes the text as-is.
JSON=0
[[ ${1:-} == --json ]] && JSON=1

cd "${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}" 2>/dev/null || true

# Take whatever teammates have written since the last session, at most once
# every half hour, and never let a slow network hold up the session.
# macOS has no timeout(1), so without one the pull runs under a watchdog here.
if command -v timeout >/dev/null 2>&1; then
  timeout 6 "$ORGAMI" sync --pull --max-age 30 --quiet >/dev/null 2>&1 || true
else
  "$ORGAMI" sync --pull --max-age 30 --quiet >/dev/null 2>&1 &
  pull=$!
  (sleep 6 && kill "$pull") >/dev/null 2>&1 &
  watchdog=$!
  wait "$pull" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
fi

# Everything else — publishing what this machine wrote, having it reviewed,
# merging it if it passes — happens detached, so the session never waits.
"$ORGAMI" autosync --background --quiet >/dev/null 2>&1 || true

# Most sessions never end cleanly — a window is closed, a machine is shut — and
# SessionEnd does not fire for any of them. Whatever those sessions learned is
# read back here instead, detached, newest first.
"$ORGAMI" note-sweep --background >/dev/null 2>&1 || true

# Two copies of orgami live on a machine — the CLI's clone and Claude Code's
# plugin clone — and neither updates itself. Once a day, detached, both move.
#
# Which copy does the moving matters. A CLI old enough to need updating is a CLI
# without `orgami update` in it, so asking it would fail forever — the command
# that fixes staleness would be the one missing. The plugin's copy is the one
# `/plugin install` and `/plugin marketplace update` bring in, so it is the one
# likelier to have the command; whichever copy does have it moves both clones,
# so the machine only needs one of the two to be current.
orgami_update() {
  "$ORGAMI" update "$@" 2>/dev/null && return 0
  [[ -n ${CLAUDE_PLUGIN_ROOT:-} && -x $CLAUDE_PLUGIN_ROOT/bin/orgami ]] || return 1
  "$CLAUDE_PLUGIN_ROOT/bin/orgami" update "$@" 2>/dev/null
}

orgami_update --if-stale --background >/dev/null 2>&1 || true

# What a previous session's update actually changed, said once.
updated=$(orgami_update --report || true)

brief=$("$ORGAMI" brief 2>/dev/null || true)

# Notes drafted from earlier sessions and decisions mined from the week's pull
# requests, waiting for a person to keep or drop them.
drafts=$("$ORGAMI" drafts --count 2>/dev/null || echo 0)
waiting=""
if [[ ${drafts:-0} -gt 0 ]]; then
  waiting="
$drafts draft(s) — notes read out of earlier sessions, decisions mined from
pull requests — are waiting to be kept or thrown away. Mention this once: the
user runs \`orgami drafts\` in a terminal, since it asks about each one."
fi
# Drafts and an update are worth surfacing even outside a mapped checkout; a
# brief is not.
if [[ -z $brief && -z $waiting && -z $updated ]]; then
  if [[ -n $nudge ]]; then
    printf '%s\n' "$nudge"
  elif [[ $JSON == 1 ]]; then
    echo '{}'
  fi
  exit 0
fi

context=$(cat <<CTX
${nudge:+$nudge
}$brief
$waiting
${updated:+
$updated
Mention this once, so the user knows the tooling moved under them.}

Use this instead of re-deriving it. \`orgami context\` for the full page.

Reading the map is half of it. When a piece of work in this session is done,
decide what it leaves behind for the next person:

- a durable fact that is not visible in the code — the real cause of a bug, why
  the obvious fix does not hold here, a setup step nobody wrote down:
  \`orgami note "..."\`;
- one instance of a job that will come round again — one more fetcher, one more
  endpoint, one more migration, one more integration wired the same way:
  \`orgami note --tag pattern --topic <the-job> "..."\`. Two instances under one
  topic write that job's playbook by themselves, and the next one starts from it
  instead of from nothing.

Ask before writing: notes are shared with the whole team under the user's name.
The orgami skill has the rest — playbooks, runbooks, decisions, what is deployed.
CTX
)

if [[ $JSON == 1 ]]; then
  jq -n --arg c "$context" '{additional_context: $c}'
else
  printf '%s\n' "$context"
fi
