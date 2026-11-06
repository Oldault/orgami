#!/usr/bin/env bash
# The SessionStart hook speaks only inside a mapped checkout. README and
# docs/agents.md promise that outside one it prints nothing at all, and it used
# to print the drafts notice and the whole note-writing block into any session
# in any repository whenever a draft was waiting. What this pins:
#   - outside a mapped checkout: nothing for Claude Code, `{}` for Cursor, even
#     with drafts waiting and an update notice pending, and that notice is not
#     used up;
#   - a project dir the editor names but that does not exist: silent, never the
#     context of whatever directory the hook happened to start in;
#   - inside a mapped checkout: the brief, the drafts with the headless
#     commands to act on them, and the update notice.
#
# A stub `orgami` on PATH hands brief, drafts and update --report to the real
# CLI and swallows everything else (sync, autosync, note-sweep, update), so
# nothing is pulled, pushed or updated. No organization, no token, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "hook_session_context: $*" >&2; exit 1; }

export HOME="$tmp/home" ORGAMI_HOME="$tmp/orgami" ORGAMI_AUTOUPDATE=0 ORGAMI_AUTONOTE=0
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset ORGAMI_COMPANY CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SAFE_MODE
home="$ORGAMI_HOME/acme"
mkdir -p "$HOME" "$home/notes/draft" "$home/map" "$tmp/bin" "$XDG_STATE_HOME/orgami"
echo '{"default":"acme","author":"tester"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme"}' >"$home/config.json"
echo '[{"name":"api","language":"TypeScript"}]' >"$home/map/repos.json"
jq -n '{generated: "2026-11-01T06:00:00Z", nodes: [{id: "repo:api", kind: "repo", name: "api"}], edges: []}' \
  >"$home/map/graph.json"
printf -- '---\nid: d1\nauthor: tester\nrepo: api\n---\n\na drafted note\n' >"$home/notes/draft/d1.md"
echo "orgami moved to 9.9.9" >"$XDG_STATE_HOME/orgami/updated"

cat >"$tmp/bin/orgami" <<STUB
#!/usr/bin/env bash
case \$1 in
  brief | drafts) exec "$root/bin/orgami" "\$@" ;;
  update) [[ \${2:-} == --report ]] && exec "$root/bin/orgami" "\$@"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$tmp/bin/orgami"
export PATH="$tmp/bin:$PATH"

mkdir -p "$tmp/unmapped" "$tmp/api"
git -C "$tmp/unmapped" init --quiet
git -C "$tmp/unmapped" remote add origin git@github.com:someone/personal.git
git -C "$tmp/api" init --quiet
git -C "$tmp/api" remote add origin git@github.com:acme/api.git

hook=$root/hooks/session-context.sh

# --- outside a mapped checkout ------------------------------------------------------

start=$(date +%s)
out=$(cd "$tmp/unmapped" && bash "$hook" </dev/null)
[[ -z $out ]] || fail "an unmapped repo got context:
$out"
[[ $(date +%s) -le $((start + 3)) ]] || fail "the hook took more than three seconds in an unmapped repo"
out=$(cd "$tmp/unmapped" && CURSOR_PROJECT_DIR=$tmp/unmapped bash "$hook" --json </dev/null)
[[ $out == "{}" ]] || fail "Cursor in an unmapped repo should get {}, got: $out"
[[ -f $XDG_STATE_HOME/orgami/updated ]] || fail "an unmapped session used up the update notice unsaid"

# --- a project dir that is not there ------------------------------------------------

out=$(cd "$tmp/api" && CLAUDE_PROJECT_DIR=$tmp/nonexistent bash "$hook" </dev/null)
[[ -z $out ]] || fail "a missing CLAUDE_PROJECT_DIR fell back to the cwd's context:
$out"
out=$(cd "$tmp/api" && CURSOR_PROJECT_DIR=$tmp/nonexistent bash "$hook" --json </dev/null)
[[ $out == "{}" ]] || fail "a missing CURSOR_PROJECT_DIR should give {}, got: $out"

# --- inside one -------------------------------------------------------------------------

out=$(cd "$tmp/unmapped" && CLAUDE_PROJECT_DIR=$tmp/api bash "$hook" </dev/null)
grep -q 'orgami — acme' <<<"$out" || fail "a mapped checkout should get its brief, got:
$out"
grep -q '1 draft(s)' <<<"$out" || fail "the waiting draft should be mentioned, got:
$out"
grep -q 'orgami drafts --list' <<<"$out" || fail "the agent should be told how to list drafts without a terminal"
grep -q 'orgami drafts --keep <id>' <<<"$out" || fail "the agent should be told how to keep one without a terminal"
grep -q 'orgami moved to 9.9.9' <<<"$out" || fail "the pending update notice should be said here"
json=$(cd "$tmp/api" && CURSOR_PROJECT_DIR=$tmp/api bash "$hook" --json </dev/null)
jq -e '.additional_context | test("orgami — acme")' <<<"$json" >/dev/null ||
  fail "Cursor in a mapped checkout should get the brief as additional_context, got: $json"

echo "hook_session_context: silent outside a mapped checkout and for a missing project dir, brief and headless drafts inside"
