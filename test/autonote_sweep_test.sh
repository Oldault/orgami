#!/usr/bin/env bash
# The session sweep reads back sessions that never closed, and a draft note is
# written under an id built from its first line. What this pins:
#   - a subagent's transcript (under <session>/subagents/, or any transcript
#     marked isSidechain) is never read as a session: a workflow fan-out used to
#     spend the day's cap on fragments of one conversation;
#   - a draft id and file name are ASCII, even from a French first line, with
#     no trailing dash, and two drafts in the same second never share one;
#   - note-auto refuses a sidechain handed to it directly.
#
# A stub `claude` answers note-auto; the sweep's call into it is replaced by a
# function that records what it was handed. No organization, no token, no
# network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "autonote_sweep: $*" >&2; exit 1; }

export HOME="$tmp/home" ORGAMI_HOME="$tmp/orgami" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" CLAUDE_CONFIG_DIR="$tmp/claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_SESSION_ID ORGAMI_AUTONOTE
home="$ORGAMI_HOME/acme"
mkdir -p "$HOME" "$home/notes" "$home/map" "$home/cache" "$tmp/bin" "$tmp/work"
echo '{"default":"acme","author":"tester"}' >"$ORGAMI_HOME/config.json"
echo '{"org":"acme"}' >"$home/config.json"
echo '[{"name":"api"}]' >"$home/map/repos.json"
git -C "$tmp/work" init --quiet
git -C "$tmp/work" remote add origin git@github.com:acme/api.git

# A transcript worth reading: forty-odd records, real work done in it.
transcript() { # <file> <sidechain:true|false>
  mkdir -p "$(dirname "$1")"
  local i
  for ((i = 0; i < 45; i++)); do
    jq -cn --arg cwd "$tmp/work" --argjson side "$2" --argjson i "$i" \
      '{type: (if $i % 2 == 0 then "user" else "assistant" end), isSidechain: $side, cwd: $cwd,
        message: {content: [{type: "tool_use", name: "Bash"},
                            {type: "text", text: "Le cas de la facture: générer une facture échoue quand la TVA manque, record \($i)."}]}}'
  done >"$1"
  # Quiet for an hour, so the sweep counts the session as over.
  python3 -c 'import os, sys, time; t = time.time() - 3600; os.utime(sys.argv[1], (t, t))' "$1"
}

proj="$CLAUDE_CONFIG_DIR/projects/-work"
transcript "$proj/main-session.jsonl" false
transcript "$proj/main-session/subagents/agent-a1.jsonl" true
transcript "$proj/stray-sidechain.jsonl" true

# --- the sweep reads sessions, not their subagents ---------------------------------

(
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/notes.sh"
  source "$ROOT/lib/autonote.sh"
  cmd_note_auto() { echo "$1" >>"$tmp/read"; }
  cmd_note_sweep
)
[[ $(wc -l <"$tmp/read") == 1 ]] || fail "one session should have been read, got: $(cat "$tmp/read")"
grep -q 'main-session.jsonl$' "$tmp/read" || fail "the session itself should have been read, got: $(cat "$tmp/read")"
[[ -e $XDG_STATE_HOME/orgami/autonote-stray-sidechain ]] ||
  fail "a sidechain transcript should be marked so it is not looked at again"

# --- note-auto: ASCII ids that do not collide --------------------------------------

cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
[[ ${1:-} == --help ]] && exit 0
cat >/dev/null
cat <<'OUT'
REPO: api
TAG: gotcha
NOTE:
Générer une facture échoue — quand la TVA manque, le PDF reste vide. Renseigner la TVA avant l'export.
OUT
STUB
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

run_auto() { (cd "$tmp/work" && "$ROOT/bin/orgami" note-auto "$1" "$tmp/work" </dev/null 2>/dev/null); }
one=$(run_auto "$proj/main-session.jsonl") || fail "note-auto exited $?"
two=$(run_auto "$proj/main-session.jsonl") || fail "a second note-auto exited $?"
[[ -f $one && -f $two ]] || fail "both drafts should be written, got '$one' and '$two'"
[[ $one != "$two" ]] || fail "two drafts written in the same second share a file: $one"
for f in "$one" "$two"; do
  base=$(basename "$f" .md)
  LC_ALL=C grep -q '[^A-Za-z0-9-]' <<<"$base" && fail "a draft id is not ASCII: $base"
  [[ $base != *- ]] || fail "a draft id ends on a dash: $base"
  grep -qx "id: $base" "$f" || fail "the front matter id should match the file name: $base"
done
grep -q -- '-generer-une-facture-echoue' <<<"$one" || fail "accents should fold, not vanish: $one"

# The same second, the same slug: the clock cannot be relied on to differ, so
# the id is asked for directly.
(
  source "$ROOT/lib/common.sh"
  load_company
  source "$ROOT/lib/notes.sh"
  source "$ROOT/lib/autonote.sh"
  mkdir -p "$tmp/d"
  : >"$tmp/d/20260101-000000-tester-cafe.md"
  [[ $(autonote_id "$tmp/d" 20260101-000000-tester "Café") == 20260101-000000-tester-cafe-2 ]] ||
    fail "a taken id should get a suffix, got $(autonote_id "$tmp/d" 20260101-000000-tester "Café")"
  [[ $(autonote_id "$tmp/d" 20260101-000000-tester "日本語") == 20260101-000000-tester ]] ||
    fail "an empty slug should leave no trailing dash, got $(autonote_id "$tmp/d" 20260101-000000-tester "日本語")"
) || exit 1

# A subagent's transcript handed to note-auto directly is still not read.
out=$(run_auto "$proj/main-session/subagents/agent-a1.jsonl") || fail "note-auto on a sidechain exited $?"
[[ -z $out ]] || fail "note-auto drafted from a subagent's transcript: $out"
out=$(run_auto "$proj/stray-sidechain.jsonl") || fail "note-auto on a sidechain exited $?"
[[ -z $out ]] || fail "note-auto drafted from a transcript marked isSidechain: $out"

echo "autonote_sweep: subagents and sidechains skipped, draft ids ASCII and never shared"
