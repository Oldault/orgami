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

# --- jq's version, not just its presence ----------------------------------------
# lib/ is tested down to jq 1.6. An older jq is on PATH and runs, so a presence
# check calls it fine while half the commands fail to parse; it has to block,
# and say how to get a newer one. A wrapper answers --version and passes
# everything else to the real jq, which the report itself needs.
real_jq=$(command -v jq)
mkdir -p "$fixture/oldjq"
cat >"$fixture/oldjq/jq" <<EOF
#!/bin/sh
[ "\$1" = --version ] && { echo "\$FAKE_JQ_VERSION"; exit 0; }
exec "$real_jq" "\$@"
EOF
chmod +x "$fixture/oldjq/jq"
jq_check() { # jq_check <version string> — the jq check's JSON; sets DOCTOR_RC
  DOCTOR_RC=0
  out=$(FAKE_JQ_VERSION=$1 PATH="$fixture/oldjq:$PATH" "$ROOT/bin/orgami" doctor --json) || DOCTOR_RC=$?
  jq -c '.checks[] | select(.name == "jq")' <<<"$out"
}
for v in jq-1.5 jq-1.5-1-a5b5cbe jq-1.4 "jq version unknown"; do
  DOCTOR_RC=0
  c=$(jq_check "$v"; echo "rc=$DOCTOR_RC")
  [[ $c == *rc=1 ]] || fail "$v on PATH should block, got: $c"
  jq -e '.ok == false and .blocking and (.detail | test("1\\.6 or newer")) and (.fix | test("jqlang/jq/releases"))' \
    <<<"${c%rc=*}" >/dev/null || fail "$v should be a blocking failure naming the floor and where to get jq, got: $c"
done
for v in jq-1.6 jq-1.7.1 jq-1.8.1 jq-2.0; do
  c=$(jq_check "$v")
  jq -e '.ok' <<<"$c" >/dev/null || fail "$v is new enough, got: $c"
done
jq -e '.detail | test("faster")' <<<"$(jq_check jq-1.6)" >/dev/null || fail "jq 1.6 should say a newer one is faster"

# --- the timer PATH names the tools that are actually missing ------------------
# Arch puts /usr/sbin, a link to /usr/bin, before /usr/bin: the terminal finds
# /usr/sbin/git, a timer finds /usr/bin/git, and that is no warning. A tool the
# timer cannot reach at all is, and its fix links that tool, not claude.
mkdir -p "$fixture/sbin" "$fixture/far"
ln -s "$(command -v git)" "$fixture/sbin/git"
printf '#!/bin/sh\nexit 0\n' >"$fixture/far/claude"
chmod +x "$fixture/far/claude"
c=$(PATH="$fixture/sbin:$fixture/far:$PATH" "$ROOT/bin/orgami" doctor --json |
  jq -c '.checks[] | select(.name == "timer PATH")') || true
jq -e --arg c "$fixture/far/claude" '.ok == false and (.detail | contains("claude (" + $c + ")"))
    and (.detail | contains("git (") | not)
    and (.fix | contains("ln -s \"" + $c + "\" ~/.local/bin/claude"))
    and (.fix | contains("/git") | not)' <<<"$c" >/dev/null ||
  fail "the timer PATH check should list claude and not git, and link claude, got: $c"
[[ $(snapshot) == "$before" ]] || fail "wrote to HOME: $(diff <(echo "$before") <(snapshot))"

# --- the clones check sends nobody round in a loop -------------------------------
# Claude Code moves the plugin when its version changes; the CLI clone moves on
# every commit. Same version on other commits has no command that changes it,
# so it is not a warning. A different version is, and `orgami update` is the
# fix because it now runs `claude plugin update` too.
ver=$(jq -r .version "$ROOT/manifest.json")
plugin_at() { # plugin_at <version>
  mkdir -p "$HOME/.claude/plugins"
  jq -n --arg v "$1" --arg p "$fixture/plugin" \
    '{version: 2, plugins: {"orgami@orgami": [{scope: "user", installPath: $p, version: $v, gitCommitSha: "0000000000000000000000000000000000000000"}]}}' \
    >"$HOME/.claude/plugins/installed_plugins.json"
}
clones() { "$ROOT/bin/orgami" doctor --json | jq -c '.checks[] | select(.name == "clones")' || true; }
plugin_at "$ver"
c=$(clones)
jq -e --arg v "$ver" '.ok and (.detail | contains("both " + $v))' <<<"$c" >/dev/null ||
  fail "the same version on other commits should not be a warning, got: $c"
plugin_at 0.0.1
c=$(clones)
jq -e --arg v "$ver" '(.ok | not) and (.detail | contains("CLI is " + $v + " and the plugin 0.0.1"))
    and (.fix | contains("orgami update"))' <<<"$c" >/dev/null ||
  fail "a plugin on another version should be a warning naming both and orgami update, got: $c"
rm -rf "$HOME/.claude"

# --- git protocol: only the docs repo needs a credential helper ----------------
# scan clones and fetches through gh, so its checkouts authenticate with gh's
# login or GH_TOKEN and no helper. Plain git reaches only the docs repo, and
# reads neither, so the warning is for a docs repo over https and nothing else
# — GH_TOKEN set or not. ORGAMI_HOME outside HOME, and no system gitconfig, so
# neither this machine's helper nor the HOME snapshot above is in play.
proto() { # proto [env...] — the git protocol check's JSON
  env GIT_CONFIG_NOSYSTEM=1 ORGAMI_HOME="$fixture/orgami" "$@" "$ROOT/bin/orgami" doctor --json |
    jq -c '.checks[] | select(.name == "git protocol")' || true
}
mkdir -p "$fixture/orgami/acme"
echo '{"default":"acme"}' >"$fixture/orgami/config.json"
echo '{"org":"acme","docs_repo":""}' >"$fixture/orgami/acme/config.json"
for tok in "" GH_TOKEN=ghp_test; do
  c=$(proto ${tok:+"$tok"})
  jq -e '.ok and (.detail | test("scan clones through gh"))' <<<"$c" >/dev/null ||
    fail "with no docs repo, https and no helper is not a warning (${tok:-no env token}), got: $c"
done
echo '{"org":"acme","docs_repo":"https://github.com/acme/docs.git"}' >"$fixture/orgami/acme/config.json"
for tok in "" GH_TOKEN=ghp_test; do
  c=$(proto ${tok:+"$tok"})
  jq -e '(.ok | not) and (.blocking | not) and (.detail | contains("https://github.com/acme/docs.git"))
      and .fix == "gh auth setup-git"' <<<"$c" >/dev/null ||
    fail "a docs repo over https with no helper should warn and name it (${tok:-no env token}), got: $c"
done
echo '{"org":"acme","docs_repo":"git@github.com:acme/docs.git"}' >"$fixture/orgami/acme/config.json"
jq -e '.ok' <<<"$(proto)" >/dev/null || fail "a docs repo over ssh needs no https helper, got: $(proto)"

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

echo "doctor: JSON pinned, exit 1 only on a blocker, nothing written; jq floor and timer PATH named right; hooks silent or one line"
