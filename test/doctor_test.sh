#!/usr/bin/env bash
# `orgami doctor` is what an agent runs when something failed, so --json is
# pinned: one object per check with name, ok, blocking, detail and fix, a fix on
# every failure, exit 1 exactly when something blocks. It may not write a thing,
# and it has to be quick. The session hooks are pinned alongside: silent outside
# a mapped repo, and one line — the install command — when the plugin runs with
# no CLI. Runs against stub gh under a temp HOME — no org, no token, no network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "doctor: $*" >&2; exit 1; }

unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME ORGAMI_HOME ORGAMI_COMPANY CLAUDE_CONFIG_DIR CLAUDE_PLUGIN_ROOT
export HOME="$fixture/home" ORGAMI_AUTOUPDATE=0
mkdir -p "$HOME"

stub="$fixture/stub"
mkdir -p "$stub"
ln -s "$ROOT/bin/orgami" "$stub/orgami"
# gh signed in with both scopes, or signed out when $fixture/signed-out exists.
cat >"$stub/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "auth status")
    [ -f "$fixture/signed-out" ] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    printf '%s\n' "github.com" "  ✓ Logged in to github.com account tester (keyring)" \\
      "  - Active account: true" "  - Token scopes: 'gist', 'read:org', 'repo'" >&2 ;;
  "config get") echo https ;;
  "--version ") echo "gh version 2.0.0" ;;
esac
exit 0
EOF
chmod +x "$stub/gh"
export PATH="$stub:/usr/local/bin:/usr/bin:/bin"

snapshot() { (cd "$HOME" && find . | LC_ALL=C sort); }
before=$(snapshot)

start=$(date +%s)
out=$("$ROOT/bin/orgami" doctor --json) || fail "exited non-zero with nothing blocking: $(jq -c '.checks[] | select(.blocking)' <<<"$out")"
(($(date +%s) - start <= 3)) || fail "took longer than 3 seconds"
[[ $(snapshot) == "$before" ]] || fail "wrote to HOME: $(diff <(echo "$before") <(snapshot))"

jq -e '.ok == true and (.checks | length > 0)
  and all(.checks[]; (.name | type) == "string" and (.ok | type) == "boolean"
    and (.blocking | type) == "boolean" and (.detail | type) == "string")
  and all(.checks[] | select(.ok | not); .fix != null)' <<<"$out" >/dev/null ||
  fail "the JSON is not one {name, ok, blocking, detail, fix} per check with a fix on every failure"
for name in bash jq git gh "gh signed in" "gh scopes" "git protocol" fzf gum python3 claude \
  "orgami on PATH" clones company auto-update; do
  jq -e --arg n "$name" 'any(.checks[]; .name == $n)' <<<"$out" >/dev/null || fail "no '$name' check"
done
jq -e '.checks[] | select(.name == "company") | .ok == false and .blocking == false and (.fix | test("orgami init"))' \
  <<<"$out" >/dev/null || fail "no company should be a warning that says how to get one"

touch "$fixture/signed-out"
if out=$("$ROOT/bin/orgami" doctor --json); then fail "exited 0 with gh signed out"; fi
jq -e '.ok == false and any(.checks[]; .name == "gh signed in" and .blocking and .fix == "gh auth login")' \
  <<<"$out" >/dev/null || fail "gh signed out is not a blocking failure with its fix"
rm "$fixture/signed-out"
human=$("$ROOT/bin/orgami" doctor) || fail "the human report exited non-zero"
[[ $human == *"nothing blocks"* ]] || fail "the human report does not end with its verdict"

# --- the session hooks -----------------------------------------------------------
nocli="/usr/local/bin:/usr/bin:/bin"
out=$(PATH=$nocli bash hooks/session-context.sh) || fail "session-context.sh exited non-zero"
[[ -z $out ]] || fail "session-context.sh printed outside a mapped repo: $out"
out=$(PATH=$nocli CLAUDE_PLUGIN_ROOT=$ROOT bash hooks/session-context.sh)
[[ $(grep -c . <<<"$out") == 1 && $out == *"bash \"$ROOT/install.sh\""* ]] ||
  fail "with the plugin and no CLI the hook should add one line naming install.sh, got: $out"
for input in "" "not json" '{"transcript_path": "/nonexistent"}'; do
  out=$(printf '%s' "$input" | PATH=$nocli bash hooks/session-note.sh 2>&1) || fail "session-note.sh exited non-zero on '$input'"
  [[ -z $out ]] || fail "session-note.sh printed on '$input': $out"
done

echo "doctor: JSON pinned, exit 1 only on a blocker, nothing written; hooks silent or one line"
