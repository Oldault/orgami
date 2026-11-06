#!/usr/bin/env bash
# SessionEnd: read back what just happened and draft a note if the session
# established something durable. The hook itself must return in milliseconds,
# so the reading happens detached — nothing here ever delays a session.

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
    # Meant to end the loop: the first bash new enough replaces this one, and
    # the candidate was just run, so the exec does not fail.
    # shellcheck disable=SC2093
    PATH="$(dirname "$b"):$PATH" ORGAMI_HOOK_REEXEC=1 exec "$b" "$0" "$@"
  done
  exit 0
fi

set -uo pipefail

input=$(cat 2>/dev/null || true)
[[ -n $input ]] || exit 0

transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
session=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
[[ -f $transcript ]] || exit 0

ORGAMI=$(command -v orgami 2>/dev/null)
if [[ -z $ORGAMI && -n ${CLAUDE_PLUGIN_ROOT:-} && -x $CLAUDE_PLUGIN_ROOT/bin/orgami ]]; then
  ORGAMI="$CLAUDE_PLUGIN_ROOT/bin/orgami"
fi
[[ -n $ORGAMI ]] || exit 0

# Opt out entirely: ORGAMI_AUTONOTE=0 in the environment.
[[ ${ORGAMI_AUTONOTE:-1} == 0 ]] && exit 0

# One pass per session, even when the event fires more than once.
state="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
mkdir -p "$state" 2>/dev/null || exit 0
marker="$state/autonote-${session:-unknown}"
[[ -e $marker ]] && exit 0
: >"$marker"

# Cheap gate before spending anything: did real work happen here?
grep -qiE '"name":"(Edit|Write|Bash|NotebookEdit)"' "$transcript" 2>/dev/null || exit 0

cd "$cwd" 2>/dev/null || true
nohup "$ORGAMI" note-auto "$transcript" "$cwd" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
