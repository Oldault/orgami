# shellcheck shell=bash
# Making the map readable by agents that are not Claude Code: MCP for the ones
# that speak it, generated context files for the ones that read markdown.

MARK_START='<!-- orgami:start — generated, edit above or below this block -->'
MARK_END='<!-- orgami:end -->'

# The block that gets written into a repo's own context file.
agents_block() {
  local repo=$1
  echo "$MARK_START"
  echo
  # brief ends with "· why: <this machine's DECISIONS.md>". The block is meant
  # to be committed, so a path under someone's home would be wrong for everyone
  # else; the pointer is dropped here, and the CLI lines below say where to look.
  "$ORGAMI_BIN" brief "$repo" 2>/dev/null |
    sed -e 's/^team notes on this repo:/Team notes on this repo:/' \
      -e 's# · why: /[^ ]*DECISIONS\.md$##'
  cat <<'TAIL'

The full page, the organization map, recorded decisions and the team's notes are
available from the `orgami` CLI:

    orgami context          this repo, in full
    orgami context --org    the organization
    orgami notes            what the team has hit before
    orgami note "..."       record something durable (ask first — it is shared)

Prefer these over re-deriving the same facts. Every claim in the map carries the
file:line, URL or pull request it came from; cite it. A missing link means "not
found in committed configuration", never "not connected".
TAIL
  echo
  echo "$MARK_END"
}

# Replaces the managed block in place, leaving everything else alone.
#
# A start marker with no end marker below it is refused, not rewritten: the
# marker promises the user that everything under it is theirs, and awk would
# swallow the rest of the file looking for a bottom that is not there. Returns
# 1 with the file untouched; the caller decides whether that is fatal.
agents_splice() {
  local file=$1 block=$2
  if [[ -f $file ]] && grep -qF "$MARK_START" "$file"; then
    grep -qF "$MARK_END" "$file" || {
      log "$file: an orgami:start marker with nothing closing it — left untouched"
      log "put the '$MARK_END' line back, or delete the start marker, then re-run"
      return 1
    }
    local tmp mode
    # The file belongs to somebody else, so its mode has to survive the move.
    # BSD stat has no -c and GNU stat has no -f.
    mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || true)
    # Beside the target rather than in $TMPDIR: the move stays on one
    # filesystem, so it is still atomic, and it cannot cross a mount point.
    tmp=$(mktemp "$file.orgami.XXXXXX")
    # fflush before handing stdout to `cat`, or the block lands wherever awk's
    # own buffer happens to have got to.
    awk -v start="$MARK_START" -v end="$MARK_END" -v blockfile="$block" '
      index($0, start) { fflush(); system("cat \"" blockfile "\""); skip = 1; next }
      index($0, end) { skip = 0; next }
      !skip { print }
    ' "$file" >"$tmp" || {
      rm -f "$tmp"
      log "$file: the rewrite failed — left untouched"
      return 1
    }
    [[ -n $mode ]] && chmod "$mode" "$tmp"
    mv "$tmp" "$file"
  else
    [[ -f $file ]] && printf '\n' >>"$file"
    cat "$block" >>"$file"
  fi
}

agents_usage() {
  cat <<'USAGE'
usage: orgami agents [--agents-md] [--cursor] [--all] [--repo <repo>]
       orgami agents --refresh [--workspace <dir>]
       orgami agents --cursor-hook [--user]
       orgami agents --git-hook

Writes this repo's organization context into a marked block in AGENTS.md (and
.cursor/rules/orgami.mdc with --cursor, or when .cursor/ exists), run inside a
checkout of a mapped repo. Text outside the block is left alone.
  --repo <repo>        the repo, when the checkout's remote does not say
  --refresh            rewrite the block in every mapped checkout under the
                       saved workspaces; --workspace adds one and remembers it
  --cursor-hook        Cursor injects the context at every session start
  --git-hook           refresh the block on merge and checkout
For the context itself, without writing a file: orgami context [repo]
USAGE
}

cmd_agents() {
  source "$ROOT/lib/card.sh"
  local targets=() repo="" dir=$PWD action=write workspace="" scope=project

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help) agents_usage; return 0 ;;
      --agents-md) targets+=(agents) ; shift ;;
      --cursor) targets+=(cursor); shift ;;
      --all) targets=(agents cursor); shift ;;
      --repo) need_arg "$1" $#; repo=$2; shift 2 ;;
      --refresh) action=refresh; shift ;;
      --workspace) need_arg "$1" $#; workspace=$2; shift 2 ;;
      --cursor-hook) action=cursor-hook; shift ;;
      --user) scope=user; shift ;;
      --git-hook) action=git-hook; shift ;;
      *) die "unknown flag: $1 — see: orgami agents --help" ;;
    esac
  done

  case $action in
    refresh) agents_refresh "$workspace"; return ;;
    cursor-hook) agents_cursor_hook "$scope"; return ;;
    git-hook) agents_git_hook; return ;;
  esac

  context_pick_company
  load_company
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  [[ -n $repo ]] || repo=$(card_repo_here 2>/dev/null || true)
  jq -e --arg r "$repo" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1 ||
    die "'$repo' is not in the $COMPANY map — run this inside a mapped checkout, or pass --repo"

  [[ ${#targets[@]} -gt 0 ]] || {
    targets=(agents)
    [[ -d $dir/.cursor ]] && targets+=(cursor)
  }

  local block
  block=$(mktemp)
  agents_block "$repo" >"$block"

  local t
  for t in "${targets[@]}"; do
    case $t in
      agents)
        agents_splice "$dir/AGENTS.md" "$block" ||
          die "$dir/AGENTS.md: unbalanced orgami markers — nothing was written"
        echo "$dir/AGENTS.md"
        ;;
      cursor)
        mkdir -p "$dir/.cursor/rules"
        local mdc="$dir/.cursor/rules/orgami.mdc"
        {
          echo "---"
          echo "description: Organization context for $repo, generated by orgami"
          echo "alwaysApply: true"
          echo "---"
          echo
          cat "$block"
        } >"$mdc"
        echo "$mdc"
        ;;
    esac
  done
  rm -f "$block"

  echo >&2
  log "these files live in the repository — commit them only if the team wants them there"
  log "re-run 'orgami agents' after a scan to refresh the block"
}

# ------------------------------------------------------------------ MCP wiring

# Prefer the bare name: it is on PATH after install.sh, and an absolute path
# with a space in it breaks half the clients' config parsers.
mcp_bin() { command -v orgami 2>/dev/null || echo "${ORGAMI_BIN:-orgami}"; }

mcp_config_json() {
  jq -n --arg bin "$(mcp_bin)" \
    '{mcpServers: {orgami: {command: $bin, args: ["mcp"]}}}'
}

# Whether the Claude Code plugin is on this machine, from the file Claude Code
# keeps its installed plugins in; `claude plugin list` would start a process
# and need the CLI on PATH.
mcp_plugin_installed() {
  [[ -n ${CLAUDE_PLUGIN_ROOT-} ]] && return 0
  local f=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json
  [[ -f $f ]] || return 1
  jq -e '[(.plugins // .) | keys[] | select(test("^orgami(@|$)"))] | length > 0' "$f" >/dev/null 2>&1
}

cmd_mcp_config() {
  local client=${1:-}
  case $client in
    cursor | windsurf | claude-desktop)
      mcp_config_json
      ;;
    # Zed reads "context_servers" from its settings.json, and VS Code reads a
    # top-level "servers" key (with a transport "type") from .vscode/mcp.json.
    # Neither looks at "mcpServers", so the Cursor shape registers nothing there.
    zed)
      jq -n --arg bin "$(mcp_bin)" \
        '{context_servers: {orgami: {command: $bin, args: ["mcp"], env: {}}}}'
      ;;
    vscode)
      jq -n --arg bin "$(mcp_bin)" \
        '{servers: {orgami: {type: "stdio", command: $bin, args: ["mcp"]}}}'
      ;;
    opencode)
      jq -n --arg bin "$(mcp_bin)" \
        '{"$schema": "https://opencode.ai/config.json",
          mcp: {orgami: {type: "local", command: [$bin, "mcp"], enabled: true}}}'
      ;;
    codex)
      cat <<EOF
[mcp_servers.orgami]
command = "$(mcp_bin)"
args = ["mcp"]
EOF
      ;;
    claude-code)
      # The plugin declares the server itself; adding it by hand as well gives
      # two orgami servers with the same tools. The reply is a comment so that
      # piping the output to a shell still does nothing.
      if mcp_plugin_installed; then
        echo "# the orgami plugin is installed and already provides this server (plugin:orgami:orgami) — nothing to add"
      else
        echo "claude mcp add orgami -- $(mcp_bin) mcp"
      fi
      ;;
    *)
      cat >&2 <<'EOF'
usage: orgami mcp --config <client>

  cursor          merge into ~/.cursor/mcp.json, or .cursor/mcp.json in a project
  opencode        merge into ~/.config/opencode/opencode.json, or ./opencode.json
  codex           append to ~/.codex/config.toml
  claude-code     a command to run (nothing, when the orgami plugin is installed)
  windsurf        merge into ~/.codeium/windsurf/mcp_config.json
  zed             merge into the "context_servers" block of Zed's settings
  vscode          merge into .vscode/mcp.json
  claude-desktop  merge into the Claude Desktop config
EOF
      return 1
      ;;
  esac
}

# ------------------------------------------------------- keeping blocks fresh

# Every checkout under the company's workspace roots that already carries an
# orgami block gets it rewritten. Nothing new is created here.
agents_refresh() {
  local extra=${1:-}
  context_pick_company
  load_company
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  local roots=() line
  while read -r line; do
    [[ -n $line ]] && roots+=("$line")
  done < <(jq -r '(.workspaces // [])[]' "$DIR/config.json" 2>/dev/null)
  [[ -n $extra ]] && roots+=("$extra")
  [[ ${#roots[@]} -gt 0 ]] || die "no workspace configured — orgami agents --refresh --workspace ~/Work/<client>"

  # Remember a workspace passed on the command line, so the next run is bare.
  if [[ -n $extra ]]; then
    local tmp
    tmp=$(mktemp)
    jq --arg w "$extra" '.workspaces = ((.workspaces // []) + [$w] | unique)' \
      "$DIR/config.json" >"$tmp"
    mv "$tmp" "$DIR/config.json"
  fi

  local root checkout repo block n=0 refused=0
  block=$(mktemp)
  for root in "${roots[@]}"; do
    root=${root/#\~/$HOME}
    [[ -d $root ]] || continue
    while read -r checkout; do
      [[ -n $checkout ]] || continue
      repo=$(card_repo_here "$checkout") || continue
      jq -e --arg r "$repo" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1 || continue

      local touched=0
      if [[ -f $checkout/AGENTS.md ]] && grep -qF "$MARK_START" "$checkout/AGENTS.md"; then
        agents_block "$repo" >"$block"
        if agents_splice "$checkout/AGENTS.md" "$block"; then
          touched=1
        else
          # One checkout with a mangled block does not stop the other thirty.
          refused=$((refused + 1))
        fi
      fi
      if [[ -f $checkout/.cursor/rules/orgami.mdc ]]; then
        agents_block "$repo" >"$block"
        {
          echo "---"
          echo "description: Organization context for $repo, generated by orgami"
          echo "alwaysApply: true"
          echo "---"
          echo
          cat "$block"
        } >"$checkout/.cursor/rules/orgami.mdc"
        touched=1
      fi
      [[ $touched == 1 ]] && { n=$((n + 1)); echo "  refreshed $repo"; }
    done < <(find_dirs_containing "$root" .git 5)
  done
  rm -f "$block"
  echo "$n checkout(s) refreshed"
  if [[ $refused -gt 0 ]]; then
    log "$refused file(s) left untouched — see above"
  fi
}

# Cursor fires sessionStart and takes {"additional_context": "..."} on stdout.
agents_cursor_hook() {
  local scope=${1:-project}
  local target
  if [[ $scope == user ]]; then
    target="$HOME/.cursor/hooks.json"
  else
    target="$PWD/.cursor/hooks.json"
  fi
  mkdir -p "$(dirname "$target")"
  [[ -f $target ]] || echo '{"version": 1, "hooks": {}}' >"$target"

  local script="$ROOT/hooks/session-context.sh"
  local tmp
  tmp=$(mktemp)
  jq --arg cmd "bash \"$script\" --json" \
    '.version = (.version // 1)
     | .hooks = (.hooks // {})
     | .hooks.sessionStart = (((.hooks.sessionStart // [])
         | map(select((.command // "") | contains("session-context.sh") | not)))
         + [{command: $cmd, type: "command", timeout: 15}])' \
    "$target" >"$tmp"
  mv "$tmp" "$target"
  echo "$target"
  log "Cursor will now inject this repo's orgami context at the start of every session"
}

# Refresh the block whenever the working tree changes underneath it.
agents_git_hook() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
  local h
  for h in post-merge post-checkout post-rewrite; do
    local file="$top/.git/hooks/$h"
    if [[ -f $file ]] && ! grep -q 'orgami agents' "$file"; then
      printf '\n# orgami: keep the generated context block current\ncommand -v orgami >/dev/null && orgami agents >/dev/null 2>&1 || true\n' >>"$file"
    elif [[ ! -f $file ]]; then
      printf '#!/bin/sh\n# orgami: keep the generated context block current\ncommand -v orgami >/dev/null && orgami agents >/dev/null 2>&1 || true\n' >"$file"
      chmod +x "$file"
    fi
    echo "$file"
  done
}
