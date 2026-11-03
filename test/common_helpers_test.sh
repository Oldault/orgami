#!/usr/bin/env bash
# The shared helpers in lib/common.sh that other commands lean on for safety
# and portability. What is pinned:
#
#   - detach returns at once, with setsid and without it (the macOS case),
#     and the command still runs with its output appended to the log
#   - file_mtime prints an epoch for a file and 0 for a missing one
#   - subst_file lands a hostile value byte for byte: `|`, `/`, `&`, `\`, a
#     newline and a sed `e` command, with no side effect, the mode kept, the
#     trailing newlines kept, and no value searched again for a placeholder
#   - valid_gh_name accepts GitHub's owner and repo shapes and nothing else,
#     and load_company refuses a config whose org fails it
#   - gh_clone_url follows gh's git_protocol, https when gh says nothing
#   - need_tty dies with the hint when there is no terminal
#   - model_call hands claude the flags that take away tools, settings, hooks
#     and MCP, and drops the optional ones an older claude does not know
#
# Stubs only: no network, no gh token, no model call.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

fail=0 passed=0
check() {
  if [[ $2 == "$3" ]]; then passed=$((passed + 1)); else
    printf 'FAIL %s: expected %q, got %q\n' "$1" "$3" "$2" >&2
    fail=1
  fi
}

# --- detach ------------------------------------------------------------------
wait_for() { # <file> <text>: up to 5s for the detached child to finish
  local n=0
  until grep -qF "$2" "$1" 2>/dev/null || ((n++ >= 50)); do sleep 0.1; done
}

# The child sleeps 3s; whole-second clocks are all macOS date has, so "at
# once" is anything under 2.
log1="$scratch/detach-setsid.log"
t0=$(date +%s)
detach "$log1" sh -c 'sleep 3; echo ran-setsid; echo err-setsid >&2'
check "detach returns at once" "$(($(date +%s) - t0 < 2))" 1

# No setsid on PATH, the way macOS has it: nohup carries it instead.
nosid="$scratch/nosid"
mkdir -p "$nosid"
for c in nohup sh sleep; do ln -s "$(command -v "$c")" "$nosid/$c"; done
log2="$scratch/detach-nohup.log"
t0=$(date +%s)
PATH=$nosid detach "$log2" sh -c 'sleep 3; echo ran-nohup'
check "detach without setsid returns at once" "$(($(date +%s) - t0 < 2))" 1
wait_for "$log1" err-setsid
check "detach runs the command, both streams to the log" \
  "$(sort "$log1" | tr '\n' ' ')" "err-setsid ran-setsid "
wait_for "$log2" ran-nohup
check "detach without setsid still runs it" "$(grep -c ran-nohup "$log2")" 1

# --- file_mtime --------------------------------------------------------------
touch -d @1700000000 "$scratch/old" 2>/dev/null || TZ=UTC touch -t 202311142213.20 "$scratch/old"
check "file_mtime of a file" "$(file_mtime "$scratch/old")" 1700000000
check "file_mtime of a missing file" "$(file_mtime "$scratch/nope")" 0

# --- subst_file --------------------------------------------------------------
f="$scratch/page.md"
printf 'org: __ORG__ & co __COMPANY__\n__ORG__/x\n\n' >"$f"
chmod 754 "$f"
hostile="x|g;1e touch $scratch/pwn
\\1 & / \\n s/a/b/"
company='__ORG__'
subst_file "$f" __ORG__ "$hostile" __COMPANY__ "$company"
expect=$(printf 'org: %s & co %s\n%s/x\n\n_' "$hostile" "$company" "$hostile")
got=$(cat "$f"; echo _)
check "subst_file lands the value verbatim, one pass" "$got" "$expect"
check "subst_file runs nothing" "$([[ -e $scratch/pwn ]] && echo pwned || echo clean)" clean
mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")
check "subst_file keeps the mode" "$mode" 754
check "subst_file leaves no temp file" "$(find "$scratch" -name 'page.md.*' | wc -l | tr -d ' ')" 0
check "subst_file refuses an odd pair" "$( (subst_file "$f" __ORG__) 2>&1 || true)" \
  "orgami: subst_file: placeholder without a value"

# --- valid_gh_name -----------------------------------------------------------
for n in acme a A1 acme-inc a-b-c "$(printf 'a%.0s' {1..39})"; do
  check "owner ok: $n" "$(valid_gh_name "$n" && echo y || echo n)" y
done
for n in "" -acme acme- a--b acme.inc 'a;b' 'a b' 'a/b' "$(printf 'a%.0s' {1..40})" $'acme\nx'; do
  check "owner refused: $n" "$(valid_gh_name "$n" owner && echo y || echo n)" n
done
for n in repo my.repo my_repo .github a-b ...; do
  check "repo ok: $n" "$(valid_gh_name "$n" repo && echo y || echo n)" y
done
for n in "" . .. 'a/b' 'a b' 'a;b' '$(x)'; do
  check "repo refused: $n" "$(valid_gh_name "$n" repo && echo y || echo n)" n
done
check "slug ok" "$(valid_gh_name acme/handbook slug && echo y || echo n)" y
check "slug refused" "$(valid_gh_name 'acme/../x' slug && echo y || echo n)" n

# load_company refuses an org that is not one.
home="$scratch/home"
mkdir -p "$home/bad" "$home/good"
jq -n '{org: "acme|g;e id"}' >"$home/bad/config.json"
jq -n '{org: "acme-inc"}' >"$home/good/config.json"
got=$( (export ORGAMI_HOME=$home ORGAMI_COMPANY=bad; load_company; echo "$ORG") 2>&1 || true)
check "load_company refuses a poisoned org" "${got%%,*}" \
  "orgami: 'bad' has org 'acme|g;e id' in $home/bad/config.json"
got=$( (export ORGAMI_HOME=$home ORGAMI_COMPANY=good; load_company; echo "$ORG") 2>&1)
check "load_company accepts a real org" "$got" acme-inc

# --- gh_clone_url ------------------------------------------------------------
stub="$scratch/stub"
mkdir -p "$stub"
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
# gh config get git_protocol [-h github.com]
[[ "$1 $2 $3" == "config get git_protocol" ]] || exit 1
if [[ ${4:-} == -h ]]; then printf '%s' "${HOST_PROTO:-}"; else printf '%s' "${GLOBAL_PROTO:-}"; fi
[[ -n ${HOST_PROTO:-}${GLOBAL_PROTO:-} ]] && echo
exit 0
EOF
chmod +x "$stub/gh"
url() { PATH="$stub:$PATH" HOST_PROTO=$1 GLOBAL_PROTO=$2 gh_clone_url acme handbook; }
check "gh says ssh for the host" "$(url ssh "")" git@github.com:acme/handbook.git
check "gh says ssh globally" "$(url "" ssh)" git@github.com:acme/handbook.git
check "gh says https" "$(url https "")" https://github.com/acme/handbook.git
check "gh says nothing" "$(url "" "")" https://github.com/acme/handbook.git
check "no gh at all" "$(PATH=$nosid gh_clone_url acme handbook)" https://github.com/acme/handbook.git
check "gh_clone_url refuses a bad name" "$( (gh_clone_url acme 'x;y') 2>&1 || true)" \
  "orgami: not a GitHub repository name: 'x;y'"

# --- need_tty ----------------------------------------------------------------
got=$( (need_tty "pass --yes") </dev/null 2>&1 || echo "rc=$?")
check "need_tty dies without a terminal" "$got" \
  "orgami: this step asks questions and there is no terminal — pass --yes
rc=1"

# --- model_call --------------------------------------------------------------
cat >"$stub/claude" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --help ]]; then
  echo "  --tools <tools...>"
  [[ -n ${OLD_CLAUDE:-} ]] || echo "  --safe-mode   Start with all customizations off"
  [[ -n ${OLD_CLAUDE:-} ]] || echo "  --no-session-persistence"
  exit 0
fi
printf '%s\n' "$@" >"$ARGS_OUT"
cat >"$ARGS_OUT.stdin"
echo OK
EOF
chmod +x "$stub/claude"
got=$( (export ARGS_OUT="$scratch/args"; printf 'hello' | PATH="$stub:$PATH" model_call haiku))
check "model_call returns the reply" "$got" OK
check "model_call passes the prompt on stdin" "$(cat "$scratch/args.stdin")" hello
check "model_call flags" "$(tr '\n' ' ' <"$scratch/args")" \
  "-p --model haiku --output-format text --tools  --setting-sources  --strict-mcp-config --safe-mode --no-session-persistence "
(export ARGS_OUT="$scratch/args-old" OLD_CLAUDE=1; printf 'hi' | PATH="$stub:$PATH" model_call haiku >/dev/null)
check "model_call on an older claude keeps the core flags only" "$(tr '\n' ' ' <"$scratch/args-old")" \
  "-p --model haiku --output-format text --tools  --setting-sources  --strict-mcp-config "

if ((fail)); then exit 1; fi
echo "common helpers: $passed checks"
