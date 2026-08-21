#compdef orgami -value-,ORGAMI_COMPANY,-default-
# orgami — zsh completion.
#
# install.sh links this as _orgami into a directory on $fpath. To load it by
# hand: source completions/orgami.zsh
#
# Every name offered here comes from a local file or from `orgami help --all`.
# Nothing in this file calls gh, git or the network: a completion that pauses
# for a second is worse than no completion at all.

# The commands, each with its description, from one source: `orgami help --all`.
# `orgami help` prints only the twelve common commands, and a list written out
# again here would drift the first time a subcommand is added. usage_all lays
# every description out at one column, either beside its command or wrapped on
# the line under it, so that column is what is read here — the argument spec of
# a long line runs past it, and those commands take their description from the
# wrapped line below.
_orgami_command_lines() {
  orgami help --all 2>/dev/null | awk -v col=41 '
    match($0, /^  orgami [a-z][a-z-]*/) {
      cmd = substr($0, 10, RLENGTH - 9)
      if (cmd in desc) next
      order[++n] = cmd
      desc[cmd] = ""
      if (substr($0, col - 1, 1) == " " && substr($0, col) ~ /^[a-z]/)
        desc[cmd] = substr($0, col)
      pending = (desc[cmd] == "") ? cmd : ""
      next
    }
    pending != "" && substr($0, col) ~ /^[a-z]/ {
      desc[pending] = substr($0, col)
      pending = ""
    }
    END {
      for (i = 1; i <= n; i++) {
        d = desc[order[i]]
        gsub(/:/, "\\:", d)
        print order[i] ":" d
      }
    }'
}

# The flags one command takes, read off the same help text for the same reason.
# A flag is a word like `[--only` or `--depth` on one of that command's lines.
_orgami_flag_names() {
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
  local home=${ORGAMI_HOME:-$HOME/.orgami}
  local -a configs names
  configs=($home/*/config.json(N))
  names=(${${configs:h}:t})
  (( $#names )) || return 1
  _describe -t companies 'company' names
}

# The repos the map knows for the company in effect. map/repos.json is written
# by `orgami scan`; before the first scan there is nothing to offer, and that is
# the honest answer.
_orgami_repos() {
  local home=${ORGAMI_HOME:-$HOME/.orgami} company=${ORGAMI_COMPANY:-}
  local -a names
  [[ -n $company ]] ||
    company=$(jq -re '.default' $home/config.json 2>/dev/null) || return 1
  names=(${(f)"$(jq -r '.[].name' $home/$company/map/repos.json 2>/dev/null)"})
  names=(${names:#})
  (( $#names )) || return 1
  _describe -t repos 'repo' names
}

_orgami() {
  local -a cmds flags

  # The same function answers for `ORGAMI_COMPANY=<TAB>`: zsh completes the
  # value of an assignment through this context. bash applies no programmable
  # completion to an assignment word at all, so its file cannot offer this.
  if [[ $service == -value-,ORGAMI_COMPANY,* ]]; then
    _orgami_companies
    return
  fi

  if (( CURRENT == 2 )); then
    cmds=(${(f)"$(_orgami_command_lines)"})
    cmds=(${cmds:#})
    (( $#cmds )) || return 1
    _describe -t commands 'orgami command' cmds
    return
  fi

  if [[ $words[CURRENT] == -* ]]; then
    flags=(${(f)"$(_orgami_flag_names $words[2])"})
    flags=(${flags:#})
    (( $#flags )) || return 1
    _describe -t flags 'flag' flags
    return
  fi

  case $words[2] in
    use) _orgami_companies ;;
    card | context | runbook | query) _orgami_repos ;;
    # The one subcommand whose argument is a path — it screens note files.
    screen) _files ;;
  esac
}

# Autoloaded from $fpath the file is the body of _orgami, and zsh has already
# registered it against the command. Sourced from a .zshrc it has not.
if [[ $funcstack[1] == _orgami ]]; then
  _orgami "$@"
else
  compdef _orgami orgami -value-,ORGAMI_COMPANY,-default-
fi
