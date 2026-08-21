# shellcheck shell=bash
# orgami — bash completion.
#
# install.sh links this into the bash-completion user directory. To load it by
# hand: source completions/orgami.bash
#
# Every name offered here comes from a local file or from `orgami help --all`.
# Nothing in this file calls gh, git or the network: a completion that pauses
# for a second is worse than no completion at all.

# The command list has one source, `orgami help --all`. `orgami help` prints
# only the twelve common commands, and a list written out again here would drift
# the first time a subcommand is added.
_orgami_commands() {
  orgami help --all 2>/dev/null |
    awk 'match($0, /^  orgami [a-z][a-z-]*/) { print substr($0, 10, RLENGTH - 9) }' |
    sort -u
}

# The flags a command takes, read off the same help text for the same reason.
# A flag is a word like `[--only` or `--depth` on one of that command's lines.
_orgami_flags() {
  orgami help --all 2>/dev/null |
    awk -v c="$1" '$1 == "orgami" && $2 == c {
      for (i = 3; i <= NF; i++)
        if ($i ~ /^\[?--[a-z]/) { gsub(/[^a-z-]/, "", $i); print $i }
    }' | sort -u
}

# The organizations configured on this machine, read the way lib/common.sh's
# companies() reads them: a directory under $ORGAMI_HOME with a config.json in
# it. A directory without one is somebody else's, not an organization.
_orgami_companies() {
  local home=${ORGAMI_HOME:-$HOME/.orgami} f
  [[ -d $home ]] || return 0
  find "$home" -mindepth 2 -maxdepth 2 -name config.json -print 2>/dev/null |
    while IFS= read -r f; do
      f=${f%/config.json}
      echo "${f##*/}"
    done | sort
}

# The repos the map knows for the company in effect. map/repos.json is written
# by `orgami scan`; before the first scan there is nothing to offer, and that is
# the honest answer.
_orgami_repos() {
  local home=${ORGAMI_HOME:-$HOME/.orgami} company=${ORGAMI_COMPANY:-}
  [[ -n $company ]] ||
    company=$(jq -re '.default' "$home/config.json" 2>/dev/null) || return 0
  jq -r '.[].name' "$home/$company/map/repos.json" 2>/dev/null
}

_orgami() {
  local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-} names='' w
  COMPREPLY=()

  if [[ $COMP_CWORD -le 1 ]]; then
    names=$(_orgami_commands)
  elif [[ $cur == -* ]]; then
    names=$(_orgami_flags "$cmd")
  else
    case $cmd in
      use) names=$(_orgami_companies) ;;
      card | context | runbook | query) names=$(_orgami_repos) ;;
      screen)
        # The one subcommand whose argument is a path — it screens note files.
        while IFS= read -r w; do COMPREPLY+=("$w"); done < <(compgen -f -- "$cur")
        return 0
        ;;
    esac
  fi

  # Filled a line at a time rather than with mapfile, which is bash 4: the
  # system bash on macOS is still 3.2.
  while IFS= read -r w; do COMPREPLY+=("$w"); done < <(compgen -W "$names" -- "$cur")
}

# No -o default and no -o bashdefault: a word that matches no command, company
# or repo has to complete to nothing. With a fallback, `orgami use zz<TAB>` would
# offer every file in the current directory instead.
complete -F _orgami orgami
