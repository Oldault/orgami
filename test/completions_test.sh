#!/usr/bin/env bash
# A completion may only offer what something on this machine already says, and
# it may only read local files to say it. Four things are under test:
#
#   - every name offered as a command is one bin/orgami dispatches, and the
#     awkward lines of usage_all — the ones whose description runs into the
#     argument spec — are among them
#   - a company is a directory under $ORGAMI_HOME with a config.json in it, and
#     a repo is a name in map/repos.json for the company in effect
#   - a prefix that matches nothing completes to nothing, never to the directory
#     listing, because `orgami use zz<TAB>` offering $HOME is worse than silence
#   - the zsh file reads the same help text into the same list of commands
#
# Runs against a fixture $ORGAMI_HOME and the real bin/orgami. No network, no
# token, no map.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# The completion calls whatever `orgami` is on PATH, so point that at this
# checkout: the command list under test is this tree's usage_all, not the one
# the developer happens to have installed.
mkdir -p "$fixture/bin"
printf '#!/usr/bin/env bash\nexec %s/bin/orgami "$@"\n' "$ROOT" >"$fixture/bin/orgami"
chmod +x "$fixture/bin/orgami"
export PATH="$fixture/bin:$PATH"

export ORGAMI_HOME="$fixture/home"
mkdir -p "$ORGAMI_HOME"/{acme/map,beta/map,fresh,scratch}
echo '{"default": "acme"}' >"$ORGAMI_HOME/config.json"
echo '{"org": "acme"}' >"$ORGAMI_HOME/acme/config.json"
echo '{"org": "beta"}' >"$ORGAMI_HOME/beta/config.json"
# `fresh` is configured but has never been scanned; `scratch` is a directory
# somebody left under ~/.orgami and is not an organization at all.
echo '{"org": "fresh"}' >"$ORGAMI_HOME/fresh/config.json"
echo '[{"name": "api"}, {"name": "web"}, {"name": "docs-site"}]' >"$ORGAMI_HOME/acme/map/repos.json"
echo '[{"name": "ledger"}]' >"$ORGAMI_HOME/beta/map/repos.json"

# shellcheck source=../completions/orgami.bash
source completions/orgami.bash

fail=0
bad() {
  echo "FAIL $1" >&2
  shift
  [[ $# -eq 0 ]] || printf '     %s\n' "$@" >&2
  fail=1
}

# What bash would offer, called the way bash calls it: the words typed so far,
# the last of them being the one under the cursor.
offer() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(($# - 1))
  COMPREPLY=()
  _orgami
  [[ ${#COMPREPLY[@]} -eq 0 ]] || printf '%s\n' "${COMPREPLY[@]}"
}

# --- the commands come from the help text, and are all real ------------------

commands=$(offer orgami "" | sort)
[[ -n $commands ]] || bad "no commands offered at all"

# Every case arm in the dispatcher, including the ones usage_all keeps quiet
# about. Anything offered has to be in here: a parser that picks up prose from
# the help text lands a word that is not a command.
dispatched=$(sed -n 's/^  \([a-z_ |-]*\))$/\1/p' bin/orgami | tr '|' '\n' | tr -d ' ' | sort -u)
while IFS= read -r c; do
  [[ -n $c ]] || continue
  grep -qxF "$c" <<<"$dispatched" || bad "offered a command bin/orgami does not dispatch: $c"
done <<<"$commands"

# The lines usage_all writes awkwardly: a description wrapped onto the next
# line, one that runs straight into the argument spec, and a hyphenated name.
for c in scan report context notes prune note-sweep claude-project playbooks; do
  grep -qxF "$c" <<<"$commands" || bad "usage_all lists '$c' but the completion does not offer it"
done

[[ $fail == 0 ]] && echo "ok   $(grep -c . <<<"$commands") commands, every one of them dispatched"

# --- companies are directories with a config.json in them --------------------

got=$(offer orgami use "" | sort | tr '\n' ' ')
[[ $got == "acme beta fresh " ]] ||
  bad "companies" "want: acme beta fresh" "got:  $got"

got=$(offer orgami use zz)
[[ -z $got ]] || bad "a company nobody has configured must complete to nothing" "got: $got"

got=$(offer orgami use ac | tr '\n' ' ')
[[ $got == "acme " ]] || bad "a prefix should narrow to the one company" "got: $got"

[[ $fail == 0 ]] && echo "ok   companies read from \$ORGAMI_HOME, a stray directory is not one"

# --- repos come from the map of the company in effect ------------------------

got=$(offer orgami card "" | sort | tr '\n' ' ')
[[ $got == "api docs-site web " ]] || bad "repos of the default company" "got: $got"

got=$(offer orgami context doc | tr '\n' ' ')
[[ $got == "docs-site " ]] || bad "a repo prefix should narrow" "got: $got"

export ORGAMI_COMPANY=beta
got=$(offer orgami runbook "" | tr '\n' ' ')
[[ $got == "ledger " ]] || bad "ORGAMI_COMPANY should pick the map that is read" "got: $got"

# Before the first scan there is no map to read, and no answer to give.
export ORGAMI_COMPANY=fresh
got=$(offer orgami query "")
[[ -z $got ]] || bad "a company with no map must complete to nothing" "got: $got"
unset ORGAMI_COMPANY

[[ $fail == 0 ]] && echo "ok   repos read from map/repos.json, for the company in effect"

# --- flags are read off the same help text -----------------------------------

got=$(offer orgami scan -- | sort | tr '\n' ' ')
[[ $got == "--depth --only " ]] || bad "flags of 'orgami scan'" "got: $got"

got=$(offer orgami dns --d | sort | tr '\n' ' ')
[[ $got == "--domain " ]] || bad "flags of 'orgami dns' narrowed by prefix" "got: $got"

[[ $fail == 0 ]] && echo "ok   flags read off the command's own help lines"

# --- the zsh file reads the same help text -----------------------------------

if command -v zsh >/dev/null; then
  zsh -n completions/orgami.zsh || bad "completions/orgami.zsh does not parse"
  # The zsh file carries its own copy of the parser, because the two shells
  # share nothing. Same help text in, same commands out.
  zsh_commands=$(zsh -c "
    autoload -Uz compinit && compinit -u -d '$fixture/zcompdump'
    source completions/orgami.zsh
    _orgami_command_lines" | sed 's/:.*//' | sort -u)
  if [[ $zsh_commands != "$commands" ]]; then
    bad "the two completions disagree about the commands" \
      "$(diff <(echo "$commands") <(echo "$zsh_commands") | head -10)"
  fi
  [[ $fail == 0 ]] && echo "ok   the zsh file parses, and reads the same commands as the bash one"
else
  echo "zsh not installed — skipping the zsh half" >&2
fi

exit "$fail"
