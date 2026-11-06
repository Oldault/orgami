# shellcheck shell=bash
# Keeping every copy of orgami on a machine at the same version.
#
# There are usually two, installed by different things and updated by neither:
# the clone `bootstrap.sh` put in ~/.local/share/orgami, which owns the CLI on
# PATH, and the clone Claude Code keeps under ~/.claude/plugins, which owns the
# skill, the slash commands and the session hooks. A fix landing in one of them
# and not the other is the normal state of affairs, and it is invisible — the
# CLI says one version, the hook that calls it is a fortnight older.
#
# So: one command that moves both, and a check cheap enough to run at every
# session start.

UPDATE_INTERVAL_HOURS=${ORGAMI_UPDATE_INTERVAL:-24}

update_state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
  mkdir -p "$d" 2>/dev/null || return 1
  echo "$d"
}

update_enabled() {
  [[ ${ORGAMI_AUTOUPDATE:-1} != 0 ]] || return 1
  local root="$ORGAMI_HOME/config.json"
  [[ -f $root ]] || return 0
  # Not `.auto_update // true`: jq's // treats false as missing, so that reads
  # an explicit false as true and the opt-out never takes.
  [[ $(jq -r '.auto_update != false' "$root" 2>/dev/null) != false ]]
}

# A checkout somebody is working in is not a checkout to pull under them. This
# is the whole safety story: uncommitted work, no upstream, or a branch that is
# not what the install tracks, and the answer is to say so and change nothing.
update_why_not() {
  local dir=$1
  [[ -d $dir/.git ]] || {
    echo "not a git checkout — reinstall with bootstrap.sh to get updates"
    return 0
  }
  git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || {
    echo "$(basename "$dir") tracks no upstream branch"
    return 0
  }
  [[ -z $(git -C "$dir" status --porcelain 2>/dev/null) ]] || {
    echo "$dir has uncommitted changes — left alone"
    return 0
  }
  return 1
}

# Claude Code owns its own plugin clone: it decides where it lives and when it
# moves. Pulling it from underneath would work until the day it does not.
update_is_plugin_dir() { [[ $1 == *"/.claude/plugins/"* ]]; }

update_version() { jq -r '.version // "unknown"' "$1/manifest.json" 2>/dev/null; }

# Every copy of orgami this machine has, which is not the same as the one
# running. A plugin hook runs the plugin's copy, and the clone that owns the CLI
# on PATH is a different directory entirely — updating only the copy that
# happens to be executing is how one of them stays a fortnight behind forever.
#
# The one on PATH counts only when it is this HOME's: install.sh links it into
# ~/.local/bin. A run with HOME pointed at a scratch directory keeps the real
# ~/.local/bin on PATH, and updating the clone behind it from there reaches past
# the sandbox the caller set up. The running copy is always a target: it is the
# one that was asked.
update_targets() {
  local path_bin dir home bindir
  {
    echo "$ROOT"
    path_bin=$(command -v orgami 2>/dev/null || true)
    home=$(cd -- "$HOME" 2>/dev/null && pwd -P) || home=$HOME
    if [[ -n $path_bin ]]; then
      bindir=$(cd -- "$(dirname -- "$path_bin")" 2>/dev/null && pwd -P) || bindir=""
      if [[ $path_bin == "$HOME"/* || $bindir == "$home"/* ]]; then
        dir=$(orgami_realpath "$path_bin")
        (cd -- "$(dirname -- "$dir")/.." 2>/dev/null && pwd) || true
      fi
    fi
  } | awk 'NF && !seen[$0]++'
}

# The CLI's own clone. Returns 0 when it moved, 1 when it did not.
update_cli() {
  local dir=$1 quiet=$2 before after why

  if update_is_plugin_dir "$dir"; then
    [[ $quiet == 1 ]] || log "running from the Claude Code plugin — it updates with the plugin"
    return 1
  fi

  if why=$(update_why_not "$dir"); then
    [[ $quiet == 1 ]] || log "$why"
    return 1
  fi

  git -C "$dir" fetch --quiet origin 2>/dev/null || {
    [[ $quiet == 1 ]] || log "could not reach the remote — nothing changed"
    return 1
  }

  before=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  after=$(git -C "$dir" rev-parse '@{u}' 2>/dev/null)
  [[ $before != "$after" ]] || return 1

  local from
  from=$(update_version "$dir")
  # A fast-forward that will not fast-forward means the local clone has
  # commits of its own. That is somebody's work, not a stale install. So is a
  # clone ahead of an upstream it already contains: --ff-only calls that
  # "already up to date" and succeeds, and HEAD has not moved to the upstream.
  if ! git -C "$dir" merge --ff-only --quiet '@{u}' 2>/dev/null ||
    [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null) != "$after" ]]; then
    [[ $quiet == 1 ]] || log "$dir has diverged from its upstream — left alone"
    return 1
  fi

  # New files need linking, and the systemd units are copied rather than linked.
  bash "$dir/install.sh" >/dev/null 2>&1 || true

  local to state
  to=$(update_version "$dir")
  # What actually changed, for the line the next session prints.
  if state=$(update_state_dir); then
    {
      echo "orgami updated $from -> $to"
      # git's own -n, not `| head`: head closing the pipe early kills git with
      # SIGPIPE, and under pipefail that is exit 141 out of the whole update.
      git -C "$dir" log --oneline -n 5 "$before..$after" 2>/dev/null | sed 's/^/  /'
    } >"$state/updated"
  fi
  [[ $quiet == 1 ]] || {
    echo "orgami $from -> $to"
    git -C "$dir" log --oneline -n 10 "$before..$after" 2>/dev/null | sed 's/^/  /'
  }
  return 0
}

update_claude_dir() { echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# The installed plugin as Claude Code recorded it, "<version>\t<installPath>",
# or nothing when orgami is not installed as a plugin here.
update_plugin_record() {
  jq -re '(.plugins["orgami@orgami"] // [])[0] // empty
          | [.version // "", .installPath // ""] | @tsv' \
    "$(update_claude_dir)/plugins/installed_plugins.json" 2>/dev/null
}

update_plugin_version() {
  local rec
  rec=$(update_plugin_record) || return 1
  echo "${rec%%$'\t'*}"
}

# The marketplace clone Claude Code installs from: where known_marketplaces.json
# says it is, which for `orgami update --dev` is a working checkout.
update_marketplace_dir() {
  local d loc
  d=$(update_claude_dir)
  loc=$(jq -r '.orgami.installLocation // empty' "$d/plugins/known_marketplaces.json" 2>/dev/null || true)
  echo "${loc:-$d/plugins/marketplaces/orgami}"
}

# The version that clone offers, as of its last refresh.
update_marketplace_version() {
  jq -r '.version // empty' "$(update_marketplace_dir)/.claude-plugin/plugin.json" 2>/dev/null
}

# The plugin, through the tool that owns it. Two steps, because they move two
# different things: `marketplace update` refreshes the catalog clone, and only
# `plugin update` moves the installed copy the sessions load. The first alone
# exits 0 and changes nothing a session runs, so success is the installed
# version having moved, read back afterwards — never the exit status.
# Returns 0 when it moved, 1 when it did not.
update_plugin() {
  local quiet=$1 before after offered state
  command -v claude >/dev/null || return 1
  # Not installed as a plugin: installing it is bootstrap.sh's call, not an update's.
  before=$(update_plugin_version) || return 1
  claude plugin marketplace update orgami >/dev/null 2>&1 || {
    [[ $quiet == 1 ]] || log "could not refresh the orgami marketplace — try: claude plugin marketplace update orgami"
    return 1
  }
  offered=$(update_marketplace_version || true)
  # A catalog that cannot be read is no proof there is nothing newer.
  if [[ -z $offered || $offered != "$before" ]]; then
    # No --yes: it accepts a marketplace-declared install command unseen, and
    # orgami declares none, so one appearing is for a person to read.
    claude plugin update orgami@orgami </dev/null >/dev/null 2>&1 || true
  fi
  after=$(update_plugin_version || true)

  if [[ -n $after && $after != "$before" ]]; then
    if state=$(update_state_dir); then
      echo "Claude Code plugin updated $before -> $after" >>"$state/updated"
    fi
    [[ $quiet == 1 ]] || echo "Claude Code plugin $before -> $after — it loads at the next session"
    return 0
  fi
  if [[ -n $offered && $offered != "$before" ]]; then
    [[ $quiet == 1 ]] || log "the Claude Code plugin is still $before, the marketplace has $offered — run: claude plugin update orgami@orgami"
  fi
  return 1
}

# One line for the plugin in `update --check`: what is installed, and whether
# the marketplace has something newer. Read-only — the catalog is compared as
# it stands, and the remote is asked with ls-remote, which writes nothing.
update_check_plugin() {
  local rec ver path offered mdir head remote
  if ! rec=$(update_plugin_record); then
    command -v claude >/dev/null &&
      echo "none — Claude Code plugin not installed. Install: claude plugin marketplace add Oldault/orgami && claude plugin install orgami@orgami"
    return 0
  fi
  ver=${rec%%$'\t'*} path=${rec#*$'\t'}
  offered=$(update_marketplace_version || true)
  mdir=$(update_marketplace_dir)
  if [[ -n $offered && $offered != "$ver" ]]; then
    echo "$ver — Claude Code plugin ${path:-?}, $offered in the marketplace. Run: orgami update (or: claude plugin update orgami@orgami)"
    return 0
  fi
  # `orgami update --dev` points the marketplace at a working checkout, which
  # is ahead of its remote by design; its commits are not an update to fetch.
  if [[ $mdir != "$(update_claude_dir)/plugins/"* ]]; then
    echo "$ver — Claude Code plugin ${path:-?}, installed from the checkout $mdir"
    return 0
  fi
  head=$(git -C "$mdir" rev-parse HEAD 2>/dev/null || true)
  remote=$(git -C "$mdir" ls-remote origin HEAD 2>/dev/null | awk 'NR == 1 {print $1}' || true)
  if [[ -n $head && -n $remote && $head != "$remote" ]]; then
    echo "$ver — Claude Code plugin ${path:-?}, the marketplace has newer commits. Run: orgami update"
  else
    echo "$ver — Claude Code plugin ${path:-?}, up to date"
  fi
}

# Point both installs at a working checkout, so an edit is live in the next
# session rather than after a commit, a push and two pulls. This is what a
# machine that develops orgami wants, and nothing else does.
update_dev() {
  local repo=${1:-$PWD}
  repo=$(cd -- "$repo" 2>/dev/null && pwd) || die "no such directory: ${1:-$PWD}"
  [[ -f $repo/bin/orgami && -f $repo/.claude-plugin/marketplace.json ]] ||
    die "$repo is not an orgami checkout"

  bash "$repo/install.sh"

  if ! command -v claude >/dev/null; then
    log "claude is not on PATH — the CLI reads $repo, the plugin is untouched"
    return 0
  fi

  # The marketplace name comes from marketplace.json, so the GitHub one and this
  # one collide. Drop it before adding the path, or the add is refused.
  claude plugin marketplace remove orgami >/dev/null 2>&1 || true
  claude plugin marketplace add "$repo" >/dev/null 2>&1 ||
    die "could not add $repo as a marketplace — add it by hand: claude plugin marketplace add $repo"
  claude plugin install orgami@orgami --yes >/dev/null 2>&1 || true

  echo "the CLI and the Claude Code plugin both read $repo now."
  echo "Edits are live in the next session — no commit, no push, no pull."
  echo "Back to the published one: claude plugin marketplace remove orgami &&"
  echo "  claude plugin marketplace add Oldault/orgami"
}

# orgami update [--check] [--if-stale] [--background] [--quiet] [--auto] [--dev [path]]
#
# --auto marks a run nobody typed: the session hook, the weekly timer, the
# detached child either of them starts. Those honour ORGAMI_AUTOUPDATE=0 and
# "auto_update": false; a person running `orgami update` still gets the update
# they asked for.
cmd_update() {
  local check=0 if_stale=0 background=0 quiet=0 auto=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --report) update_report; return 0 ;;
      --dev | --link) shift; update_dev "${1:-$PWD}"; return 0 ;;
      --check | -n) check=1; shift ;;
      --if-stale) if_stale=1; shift ;;
      --background | --detach) background=1; shift ;;
      --quiet | -q) quiet=1; shift ;;
      --auto) auto=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [[ $if_stale == 1 ]] && auto=1
  # --check only looks, so it is never an update anyone has to opt out of.
  if [[ $auto == 1 && $check == 0 ]]; then
    update_enabled || return 0
  fi

  if [[ $if_stale == 1 ]]; then
    local state stamp
    state=$(update_state_dir) || return 0
    stamp="$state/update-checked"
    if [[ -f $stamp ]]; then
      local age
      age=$((($(date +%s) - $(file_mtime "$stamp")) / 3600))
      [[ $age -ge $UPDATE_INTERVAL_HOURS ]] || return 0
    fi
    : >"$stamp"
    quiet=1
  fi

  if [[ $background == 1 ]]; then
    # Detached: a session never waits on somebody else's network. The child
    # carries --auto when this run did, so it checks the opt-out for itself.
    local -a child=(update --quiet)
    [[ $auto == 1 ]] && child+=(--auto)
    detach /dev/null "$ORGAMI_BIN" "${child[@]}"
    return 0
  fi

  need git

  local dir why behind
  if [[ $check == 1 ]]; then
    while read -r dir; do
      [[ -n $dir ]] || continue
      # The plugin's copy gets its own line below, from Claude Code's record.
      update_is_plugin_dir "$dir" && continue
      if why=$(update_why_not "$dir"); then
        echo "$(update_version "$dir") — $why"
        continue
      fi
      git -C "$dir" fetch --quiet origin 2>/dev/null || {
        echo "$(update_version "$dir") — $dir, could not reach the remote"
        continue
      }
      behind=$(git -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
      if [[ ${behind:-0} -gt 0 ]]; then
        echo "$(update_version "$dir") — $dir, $behind commit(s) behind. Run: orgami update"
        git -C "$dir" log --oneline -n 10 "HEAD..@{u}" 2>/dev/null | sed 's/^/  /'
      else
        echo "$(update_version "$dir") — $dir, up to date"
      fi
    done < <(update_targets)
    update_check_plugin
    return 0
  fi

  local moved=0
  while read -r dir; do
    [[ -n $dir ]] || continue
    update_cli "$dir" "$quiet" && moved=1
  done < <(update_targets)
  update_plugin "$quiet" && moved=1

  if [[ $moved == 0 && $quiet == 0 ]]; then
    echo "$(update_version "$ROOT") — already the newest here"
  fi
  return 0
}

# One line for the session hook, once, naming what moved since it last spoke.
update_report() {
  local state file
  state="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
  file="$state/updated"
  [[ -f $file ]] || return 0
  cat "$file"
  rm -f "$file"
}
