# shellcheck shell=bash
# What this machine needs before orgami can run, and how to take it off again.
#
# `doctor` reads and never writes: it is what an agent runs when a command has
# failed, so it may not change the state it is diagnosing. The one network call
# is `gh auth status`, because a token gh still holds but GitHub has revoked
# looks signed in from every file on disk.
#
# `uninstall` removes what orgami put on this machine and nothing it did not:
# every link is checked to point into an orgami clone before it goes, a shared
# config file loses only orgami's entry, and nothing on any remote is touched.

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
ORGAMI_SRC_DEFAULT=${ORGAMI_SRC:-$HOME/.local/share/orgami}

# ------------------------------------------------------------------ doctor

DOC_NAME=() DOC_OK=() DOC_BLOCK=() DOC_DETAIL=() DOC_FIX=()

# doc_add <name> <ok 0|1> <blocks 0|1> <detail> [fix]
# A failure that blocks means a first run cannot get past it; one that does not
# is a feature that will be missing, said so the reader is not surprised later.
doc_add() {
  DOC_NAME+=("$1") DOC_OK+=("$2") DOC_BLOCK+=("$3") DOC_DETAIL+=("$4") DOC_FIX+=("${5:-}")
}

# bash_version_ok <bash> — 4.4 or newer, the floor bin/orgami enforces.
bash_version_ok() {
  "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null
}

# The directories a scheduled run gets on PATH: what the systemd units and the
# launchd plist in lib/schedule.sh set. A tool anywhere else is found from a
# terminal and missing from every timer run.
doctor_timer_path() {
  if [[ $(uname -s) == Darwin ]]; then
    echo "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  else
    echo "$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
  fi
}

on_timer_path() {
  local dir
  dir=$(dirname "$1")
  [[ ":$(doctor_timer_path):" == *":$dir:"* ]]
}

# The clone a binary lives in: the directory above its resolved bin/.
clone_of() {
  local real
  real=$(orgami_realpath "$1") || return 1
  (cd -- "$(dirname -- "$real")/.." 2>/dev/null && pwd)
}

# The Claude Code plugin install record, as "<installPath>\t<sha>\t<version>".
plugin_record() {
  local f="$CLAUDE_DIR/plugins/installed_plugins.json"
  [[ -f $f ]] || return 1
  jq -re '(.plugins["orgami@orgami"] // [])[0] // empty
          | [.installPath // "", .gitCommitSha // "", .version // ""] | @tsv' "$f" 2>/dev/null
}

doctor_checks() {
  local v b path_bash

  # --- bash
  v="$BASH_VERSION"
  path_bash=$(command -v bash 2>/dev/null || true)
  if [[ -z $path_bash ]]; then
    doc_add bash 0 1 "running under $v, but no bash on PATH" "put a bash 4.4+ on PATH"
  elif bash_version_ok "$path_bash"; then
    doc_add bash 1 0 "$v; $path_bash is $("$path_bash" -c 'echo $BASH_VERSION')"
  else
    doc_add bash 0 1 "$path_bash is $("$path_bash" -c 'echo $BASH_VERSION'), and orgami and its hooks need 4.4+" \
      "brew install bash, then open a new terminal"
  fi

  # --- the hard dependencies
  for b in jq git; do
    if command -v "$b" >/dev/null 2>&1; then
      doc_add "$b" 1 0 "$(command -v "$b")"
    else
      doc_add "$b" 0 1 "not on PATH" "install $b with your package manager"
    fi
  done

  # --- gh: present, signed in, scopes, protocol
  if ! command -v gh >/dev/null 2>&1; then
    doc_add gh 0 1 "not on PATH" "install the GitHub CLI: https://cli.github.com"
  else
    doc_add gh 1 0 "$(gh --version 2>/dev/null | head -1)"
    local status tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 5)
    if status=$("${tmo[@]}" gh auth status -h github.com 2>&1); then
      local account scopes missing="" s
      # The active account's block only: gh lists every account it holds.
      account=$(awk '/Logged in to/ {blk=$0} /Active account: true/ {print blk; exit}' <<<"$status" |
        sed -E 's/.*account ([^ ]+).*/\1/')
      [[ -n $account ]] || account=$(sed -nE 's/.*Logged in to [^ ]+ account ([^ ]+).*/\1/p' <<<"$status" | head -1)
      doc_add "gh signed in" 1 0 "as ${account:-unknown}"
      scopes=$(awk '/Active account: true/ {a=1} a && /Token scopes:/ {print; exit}' <<<"$status")
      [[ -n $scopes ]] || scopes=$(grep -m1 'Token scopes:' <<<"$status" || true)
      if [[ -z $scopes ]]; then
        doc_add "gh scopes" 1 0 "gh lists no scopes (a fine-grained or environment token) — it needs read access to the org's repositories"
      else
        for s in repo read:org; do
          [[ $scopes == *"'$s'"* ]] || missing+="${missing:+,}$s"
        done
        if [[ -z $missing ]]; then
          doc_add "gh scopes" 1 0 "repo, read:org"
        else
          doc_add "gh scopes" 0 1 "missing $missing — private repositories and the org's member list stay invisible" \
            "gh auth refresh -h github.com -s repo,read:org"
        fi
      fi
    else
      doc_add "gh signed in" 0 1 "gh auth status: $(head -1 <<<"$status")" "gh auth login"
    fi

    local proto
    proto=$(gh config get git_protocol -h github.com 2>/dev/null || true)
    [[ -n $proto ]] || proto=$(gh config get git_protocol 2>/dev/null || true)
    proto=${proto:-https}
    if [[ $proto == ssh ]]; then
      if compgen -G "$HOME/.ssh/id_*" >/dev/null || [[ -n ${SSH_AUTH_SOCK:-} ]]; then
        doc_add "git protocol" 1 0 "ssh"
      else
        doc_add "git protocol" 0 0 "ssh, but no key in ~/.ssh and no agent — clones will fail" \
          "gh config set git_protocol https -h github.com"
      fi
    elif git config --get-urlmatch credential.helper https://github.com >/dev/null 2>&1; then
      doc_add "git protocol" 1 0 "https, with a credential helper"
    else
      doc_add "git protocol" 0 0 "https with no credential helper — clones of private repositories will ask for a password" \
        "gh auth setup-git"
    fi
  fi

  # --- the optional tools, each named by what goes missing without it
  if command -v fzf >/dev/null 2>&1; then
    v=$(fzf --version 2>/dev/null | awk '{print $1; exit}')
    # lib/tui.sh owns the thresholds; asked, not copied, so they cannot drift.
    if ! declare -F tui_fzf_at_least >/dev/null; then
      doc_add fzf 1 0 "$v"
    elif ! tui_fzf_at_least "${TUI_FZF_FLOOR:-0.29}"; then
      doc_add fzf 0 0 "$v — orgami view needs ${TUI_FZF_FLOOR:-0.29} or newer" "upgrade fzf"
    elif ! tui_fzf_at_least 0.63; then
      doc_add fzf 1 0 "$v — orgami view runs, without the borders and footer of 0.60 and 0.63"
    else
      doc_add fzf 1 0 "$v"
    fi
  else
    doc_add fzf 0 0 "not on PATH — orgami view and the menu cannot open" "install fzf"
  fi
  if command -v gum >/dev/null 2>&1; then
    doc_add gum 1 0 "$(command -v gum)"
  else
    doc_add gum 0 0 "not on PATH — the setup wizard and the menu fall back to plain prompts" "install gum"
  fi
  if command -v python3 >/dev/null 2>&1; then
    doc_add python3 1 0 "$(command -v python3)"
  else
    doc_add python3 0 0 "not on PATH — orgami mcp (the MCP server) and orgami depth cannot run" "install python3"
  fi

  local claude_bin
  claude_bin=$(command -v claude 2>/dev/null || true)
  if [[ -z $claude_bin ]]; then
    doc_add claude 0 0 "not on PATH — orgami report and daily cannot write prose; --stats-only still works" \
      "curl -fsSL https://claude.ai/install.sh | bash"
  else
    doc_add claude 1 0 "$claude_bin"
  fi

  # A timer run starts with the PATH lib/schedule.sh gives it, not the shell's.
  local t p far=""
  for t in claude gh jq git; do
    p=$(command -v "$t" 2>/dev/null) || continue
    [[ $p == /* ]] || continue
    on_timer_path "$p" || far+="${far:+, }$t ($p)"
  done
  if [[ -z $far ]]; then
    doc_add "timer PATH" 1 0 "every tool a scheduled run needs is on $(doctor_timer_path)"
  else
    doc_add "timer PATH" 0 0 "a scheduled run will not find $far" \
      "link each into ~/.local/bin, e.g. ln -s \"\$(command -v claude)\" ~/.local/bin/claude"
  fi

  # --- orgami itself: on PATH, and which clones exist
  local cli_bin cli_dir="" cli_sha="" rec plugin_dir="" plugin_sha="" plugin_ver=""
  cli_bin=$(command -v orgami 2>/dev/null || true)
  if [[ -n $cli_bin ]]; then
    cli_dir=$(clone_of "$cli_bin" || true)
    doc_add "orgami on PATH" 1 0 "$cli_bin -> ${cli_dir:-?}"
  elif [[ -e $HOME/.local/bin/orgami ]]; then
    doc_add "orgami on PATH" 0 1 "$HOME/.local/bin/orgami exists, but ~/.local/bin is not on PATH" \
      "add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
  else
    doc_add "orgami on PATH" 0 1 "not linked — agents and timers call orgami by name" "bash \"$ROOT/install.sh\""
  fi
  [[ -n $cli_dir ]] && cli_sha=$(git -C "$cli_dir" rev-parse HEAD 2>/dev/null || true)

  if rec=$(plugin_record); then
    IFS=$'\t' read -r plugin_dir plugin_sha plugin_ver <<<"$rec"
  fi

  local clones="CLI ${cli_dir:-none}${cli_sha:+ @ ${cli_sha:0:7}}"
  clones+="; plugin ${plugin_dir:-none}${plugin_sha:+ @ ${plugin_sha:0:7}}"
  if [[ -n $cli_sha && -n $plugin_sha && $cli_sha != "$plugin_sha" ]]; then
    doc_add clones 0 0 "$clones — the CLI and the plugin run different code" "orgami update"
  else
    doc_add clones 1 0 "$clones"
  fi

  # --- Claude Code
  if [[ -n $plugin_dir ]]; then
    local enabled manifest="$plugin_dir/.claude-plugin/plugin.json"
    enabled=$(jq -r '.enabledPlugins["orgami@orgami"] // "unset"' "$CLAUDE_DIR/settings.json" 2>/dev/null || echo unset)
    if [[ $enabled == false ]]; then
      doc_add "claude plugin" 0 0 "orgami@orgami $plugin_ver is installed but disabled" "claude plugin enable orgami@orgami"
    else
      doc_add "claude plugin" 1 0 "orgami@orgami $plugin_ver"
    fi
    if jq -e '(.hooks.SessionStart // []) | length > 0' "$manifest" >/dev/null 2>&1 &&
      [[ -f $plugin_dir/hooks/session-context.sh ]]; then
      doc_add "claude hooks" 1 0 "SessionStart and SessionEnd from $manifest"
    else
      doc_add "claude hooks" 0 0 "the installed plugin registers no SessionStart hook" \
        "claude plugin marketplace update orgami && claude plugin install orgami@orgami"
    fi
    # The plugin supplies the skill, so a second copy linked by install.sh puts
    # it in every session's context twice.
    if [[ -e $CLAUDE_DIR/skills/orgami/SKILL.md ]]; then
      doc_add "claude skill" 0 0 "the skill is loaded twice: from the plugin and from $CLAUDE_DIR/skills/orgami" \
        "rm -r \"$CLAUDE_DIR/skills/orgami\""
    fi
  elif [[ -n $claude_bin ]]; then
    doc_add "claude plugin" 0 0 "not installed — no session context, hooks or MCP tools in Claude Code" \
      "claude plugin marketplace add Oldault/orgami && claude plugin install orgami@orgami"
  fi

  # --- Cursor, only where Cursor is
  if [[ -d $HOME/.cursor ]]; then
    local hook script mcp_cmd
    hook=$(jq -r '[(.hooks.sessionStart // [])[] | .command // "" | select(contains("session-context.sh"))][0] // empty' \
      "$HOME/.cursor/hooks.json" 2>/dev/null || true)
    script=$(sed -nE 's/.*"([^"]*session-context\.sh)".*/\1/p' <<<"$hook")
    if [[ -z $hook ]]; then
      doc_add "cursor hook" 0 0 "no orgami sessionStart hook in ~/.cursor/hooks.json" "orgami agents --cursor-hook --user"
    elif [[ -n $script && ! -f $script ]]; then
      doc_add "cursor hook" 0 0 "$HOME/.cursor/hooks.json runs $script, which does not exist" "orgami agents --cursor-hook --user"
    else
      doc_add "cursor hook" 1 0 "${script:-$hook}"
    fi
    mcp_cmd=$(jq -r '.mcpServers.orgami.command // empty' "$HOME/.cursor/mcp.json" 2>/dev/null || true)
    if [[ -z $mcp_cmd ]]; then
      doc_add "cursor mcp" 0 0 "no orgami server in ~/.cursor/mcp.json" \
        "merge the output of: orgami mcp --config cursor"
    elif ! command -v "$mcp_cmd" >/dev/null 2>&1; then
      doc_add "cursor mcp" 0 0 "$HOME/.cursor/mcp.json runs $mcp_cmd, which is not there" \
        "merge the output of: orgami mcp --config cursor"
    else
      doc_add "cursor mcp" 1 0 "$mcp_cmd mcp"
    fi
  fi

  # --- the company and its map
  local company="" cdir org gen age
  company=${ORGAMI_COMPANY:-}
  [[ -n $company ]] || company=$(jq -r '.default // empty' "$ORGAMI_HOME/config.json" 2>/dev/null || true)
  if [[ -z $company ]]; then
    doc_add company 0 0 "none configured in $ORGAMI_HOME" \
      "orgami init <name> --org <github-org>, or orgami join <name> --repo <docs-repo-url>"
  else
    cdir=$(company_dir "$company")
    org=$(jq -r '.org // empty' "$cdir/config.json" 2>/dev/null || true)
    if [[ ! -f $cdir/config.json ]]; then
      doc_add company 0 1 "'$company' is the default, but $cdir/config.json does not exist" "orgami list, then orgami use <name>"
    elif ! valid_gh_name "$org" owner; then
      doc_add company 0 1 "'$company' has org '$org', which is not a GitHub organization name" \
        "fix .org in $cdir/config.json"
    else
      doc_add company 1 0 "$company (github.com/$org)"
      gen=$(jq -r '.generated // empty' "$cdir/map/graph.json" 2>/dev/null || true)
      if [[ -z $gen ]]; then
        doc_add map 0 0 "no map yet for $company" "orgami scan"
      else
        age=$(jq -rn --arg g "$gen" '(now - ($g | fromdateiso8601)) / 86400 | floor' 2>/dev/null || echo "")
        if [[ -z $age ]]; then
          doc_add map 1 0 "generated $gen"
        elif ((age > 7)); then
          doc_add map 0 0 "generated $gen, $age days ago — stale" "orgami scan"
        else
          doc_add map 1 0 "generated $gen, $age day(s) ago"
        fi
      fi
    fi
  fi

  if update_enabled; then
    doc_add "auto-update" 1 0 "on — both clones move once a day from the session hook"
  else
    doc_add "auto-update" 1 0 "off (ORGAMI_AUTOUPDATE=0 or \"auto_update\": false) — run orgami update by hand"
  fi
}

# orgami doctor [--json]
cmd_doctor() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift ;;
      *) die "unknown flag: $1 — orgami doctor [--json]" ;;
    esac
  done

  # The JSON is built with jq; the plain report below reads without it.
  [[ $json == 0 ]] || need jq
  doctor_checks

  local i blocked=0
  for i in "${!DOC_NAME[@]}"; do
    [[ ${DOC_OK[i]} == 0 && ${DOC_BLOCK[i]} == 1 ]] && blocked=$((blocked + 1))
  done

  if [[ $json == 1 ]]; then
    for i in "${!DOC_NAME[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\n' "${DOC_NAME[i]}" "${DOC_OK[i]}" "${DOC_BLOCK[i]}" "${DOC_DETAIL[i]}" "${DOC_FIX[i]}"
    done | jq -R -s --arg v "$(jq -r '.version // "unknown"' "$ROOT/manifest.json")" --arg root "$ROOT" '
      split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], ok: (.[1] == "1"), blocking: (.[2] == "1" and .[1] == "0"),
           detail: .[3], fix: (if .[4] == "" then null else .[4] end)})
      | {version: $v, root: $root, ok: (map(select(.blocking)) | length == 0), checks: .}'
  else
    style_init
    echo "orgami $(jq -r '.version // "unknown"' "$ROOT/manifest.json" 2>/dev/null || echo unknown) — $ROOT"
    echo
    local mark
    for i in "${!DOC_NAME[@]}"; do
      if [[ ${DOC_OK[i]} == 1 ]]; then
        mark="${S_OK}ok  ${S_R}"
      elif [[ ${DOC_BLOCK[i]} == 1 ]]; then
        mark="${S_ERR}FAIL${S_R}"
      else
        mark="${S_WARN}warn${S_R}"
      fi
      printf '  %s  %-15s %s\n' "$mark" "${DOC_NAME[i]}" "${DOC_DETAIL[i]}"
      [[ ${DOC_OK[i]} == 0 && -n ${DOC_FIX[i]} ]] && printf '        %-15s %sfix: %s%s\n' "" "$S_D" "${DOC_FIX[i]}" "$S_R"
    done
    echo
    if [[ $blocked == 0 ]]; then
      echo "nothing blocks orgami here"
    else
      echo "$blocked problem(s) block orgami — fix the FAIL lines above"
    fi
  fi
  [[ $blocked == 0 ]]
}

# --------------------------------------------------------------- uninstall

# Every action is one line, "<kind>\t<target>\t<what it does>", planned in full
# before anything runs, so --dry-run and the confirmation show exactly what the
# run will do and in that order.
UN_PLAN=()

un_plan() { UN_PLAN+=("$1"$'\t'"$2"$'\t'"$3"); }

# A symlink orgami made: it points into a directory that holds bin/orgami.
# Anything else at that path — a file, or a link into someone else's tree — is
# not ours to remove.
un_link_ours() {
  local link=$1 want=$2 target
  [[ -L $link ]] || return 1
  target=$(readlink "$link")
  [[ $target == *"/$want" ]] || return 1
  # A dangling link is ours too when the whole clone it pointed into is gone.
  [[ -f ${target%/"$want"}/bin/orgami ]] || [[ ! -e ${target%/"$want"} ]]
}

# The lines agents_git_hook writes, matched exactly so a hook with anything
# else in it keeps everything else.
UN_GITHOOK_COMMENT='# orgami: keep the generated context block current'
UN_GITHOOK_LINE='command -v orgami >/dev/null && orgami agents >/dev/null 2>&1 || true'

# Checkouts a git hook or a project Cursor hook may have been installed into:
# the one this runs from, and every checkout under each company's workspaces.
un_checkouts() {
  local top c root
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n $top ]] && echo "$top"
  for c in $(companies); do
    while IFS= read -r root; do
      root=${root/#\~/$HOME}
      [[ -n $root && -d $root ]] || continue
      find "$root" -maxdepth 4 -type d -name .git -prune -print 2>/dev/null | sed 's|/\.git$||'
    done < <(jq -r '(.workspaces // [])[]' "$(company_dir "$c")/config.json" 2>/dev/null)
  done
  return 0
}

uninstall_plan() {
  local purge=$1 f d

  # Timers first: a run that starts halfway through would find half a tool.
  local unit_dir="$HOME/.config/systemd/user"
  if [[ -d $unit_dir ]]; then
    for f in "$unit_dir"/timers.target.wants/orgami-*@*.timer; do
      [[ -e $f || -L $f ]] || continue
      un_plan systemd-stop "$(basename "$f")" "systemctl --user disable --now $(basename "$f")"
    done
    for f in "$unit_dir"/orgami-weekly@.service "$unit_dir"/orgami-weekly@.timer \
      "$unit_dir"/orgami-daily@.service "$unit_dir"/orgami-daily@.timer; do
      [[ -f $f ]] && un_plan rm "$f" "remove $f"
    done
  fi

  for f in "$HOME"/Library/LaunchAgents/dev.orgami.*.plist; do
    [[ -f $f ]] || continue
    un_plan launchd "$f" "launchctl bootout $(basename "$f" .plist), remove $f"
  done

  local cron
  if command -v crontab >/dev/null 2>&1; then
    cron=$(crontab -l 2>/dev/null | grep -E '/orgami (weekly|daily)( |$)' || true)
    while IFS= read -r f; do
      [[ -n $f ]] && un_plan cron "$f" "remove this line from your crontab: $f"
    done <<<"$cron"
  fi

  # The links install.sh made.
  un_link_ours "$HOME/.local/bin/orgami" bin/orgami &&
    un_plan rm "$HOME/.local/bin/orgami" "remove the link $HOME/.local/bin/orgami"
  local bash_comp="${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/orgami"
  un_link_ours "$bash_comp" completions/orgami.bash && un_plan rm "$bash_comp" "remove the link $bash_comp"
  local zdirs=("$HOME/.zsh/completions" "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions")
  [[ -n ${HOMEBREW_PREFIX:-} ]] && zdirs+=("$HOMEBREW_PREFIX/share/zsh/site-functions")
  for d in "${zdirs[@]}"; do
    un_link_ours "$d/_orgami" completions/orgami.zsh && un_plan rm "$d/_orgami" "remove the link $d/_orgami"
  done
  if un_link_ours "$CLAUDE_DIR/skills/orgami/SKILL.md" skills/orgami/SKILL.md; then
    un_plan rm "$CLAUDE_DIR/skills/orgami/SKILL.md" "remove the link $CLAUDE_DIR/skills/orgami/SKILL.md"
    un_plan rmdir "$CLAUDE_DIR/skills/orgami" "remove $CLAUDE_DIR/skills/orgami if nothing else is in it"
  fi

  # Cursor: only orgami's entries leave; the files and everything else stay.
  if jq -e '[(.hooks.sessionStart // [])[] | .command // "" | select(contains("session-context.sh"))] | length > 0' \
    "$HOME/.cursor/hooks.json" >/dev/null 2>&1; then
    un_plan cursor-hook "$HOME/.cursor/hooks.json" "remove orgami's sessionStart entry from $HOME/.cursor/hooks.json"
  fi
  if jq -e '.mcpServers.orgami.args == ["mcp"]' "$HOME/.cursor/mcp.json" >/dev/null 2>&1; then
    un_plan cursor-mcp "$HOME/.cursor/mcp.json" "remove the orgami server from $HOME/.cursor/mcp.json"
  fi

  local co h
  while IFS= read -r co; do
    [[ -n $co ]] || continue
    for h in post-merge post-checkout post-rewrite; do
      f="$co/.git/hooks/$h"
      [[ -f $f ]] && grep -qxF "$UN_GITHOOK_LINE" "$f" &&
        un_plan githook "$f" "remove orgami's lines from $f"
    done
    [[ $co == "$HOME" ]] && continue
    jq -e '[(.hooks.sessionStart // [])[] | .command // "" | select(contains("session-context.sh"))] | length > 0' \
      "$co/.cursor/hooks.json" >/dev/null 2>&1 &&
      un_plan cursor-hook "$co/.cursor/hooks.json" "remove orgami's sessionStart entry from $co/.cursor/hooks.json"
  done < <(un_checkouts | awk 'NF && !seen[$0]++')

  # Claude Code owns its plugin clone; it is removed through claude, not rm.
  if command -v claude >/dev/null 2>&1; then
    plugin_record >/dev/null &&
      un_plan claude-plugin orgami@orgami "claude plugin uninstall orgami@orgami"
    jq -e 'has("orgami")' "$CLAUDE_DIR/plugins/known_marketplaces.json" >/dev/null 2>&1 &&
      un_plan claude-marketplace orgami "claude plugin marketplace remove orgami"
  fi

  # Machine state: update stamps, autonote markers, the install nudge.
  d="${XDG_STATE_HOME:-$HOME/.local/state}"
  [[ -d $d/orgami ]] && un_plan rmrf "$d/orgami" "remove $d/orgami (update and autonote state)"
  [[ -f $d/orgami-install-nudge ]] && un_plan rm "$d/orgami-install-nudge" "remove $d/orgami-install-nudge"

  if [[ $purge == 1 ]]; then
    [[ -d $ORGAMI_HOME ]] && un_plan rmrf "$ORGAMI_HOME" "remove $ORGAMI_HOME — every company's map, notes and reports on this machine"
    for f in "$HOME"/Library/Logs/orgami-*.log; do
      [[ -f $f ]] && un_plan rm "$f" "remove $f"
    done
  fi
  # Not the status of the last test above: the caller runs under set -e.
  return 0
}

# The clone the CLI was installed from. Removed only with --purge, only at the
# place bootstrap.sh puts it, and only when it holds no uncommitted work: a
# developer's checkout is never the thing an uninstall deletes.
uninstall_clone() {
  local purge=$1 dir
  UN_KEPT=()
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    update_is_plugin_dir "$dir" && continue
    if [[ $dir != "$ORGAMI_SRC_DEFAULT" ]]; then
      UN_KEPT+=("$dir — a checkout orgami ran from, not the clone bootstrap.sh made; left alone")
    elif [[ -n $(git -C "$dir" status --porcelain 2>/dev/null) ]]; then
      UN_KEPT+=("$dir — the clone orgami was installed from; it has uncommitted changes, so it stays")
    elif [[ $purge == 1 ]]; then
      un_plan rmrf "$dir" "remove $dir — the clone orgami was installed from, last"
    else
      UN_KEPT+=("$dir — the clone orgami was installed from (--purge removes it, or: rm -rf \"$dir\")")
    fi
  done < <({
    [[ -L $HOME/.local/bin/orgami ]] && clone_of "$HOME/.local/bin/orgami"
    clone_of "$ORGAMI_BIN"
  } 2>/dev/null | awk 'NF && !seen[$0]++')
  return 0
}

uninstall_do() {
  local kind=$1 target=$2 tmp
  case $kind in
    rm) rm -f -- "$target" ;;
    rmdir) rmdir -- "$target" 2>/dev/null || log "kept $target — it holds files orgami did not put there" ;;
    rmrf) rm -rf -- "$target" ;;
    systemd-stop)
      systemctl --user disable --now "$target" >/dev/null 2>&1 || log "could not stop $target — systemctl --user disable --now $target"
      ;;
    systemd-reload) systemctl --user daemon-reload >/dev/null 2>&1 || true ;;
    launchd)
      local label
      label=$(basename "$target" .plist)
      launchctl bootout "gui/$UID/$label" 2>/dev/null || launchctl unload "$target" 2>/dev/null || true
      rm -f -- "$target"
      ;;
    cron)
      # Exact lines only, through a temp file: an interrupted pipe into
      # `crontab -` would install an empty crontab.
      tmp=$(mktemp)
      crontab -l 2>/dev/null | awk -v drop="$target" '$0 != drop' >"$tmp"
      crontab "$tmp" || log "could not rewrite the crontab — remove the line by hand: crontab -e"
      rm -f "$tmp"
      ;;
    cursor-hook)
      tmp=$(mktemp)
      jq '.hooks.sessionStart = [(.hooks.sessionStart // [])[]
            | select((.command // "") | contains("session-context.sh") | not)]
          | if (.hooks.sessionStart | length) == 0 then del(.hooks.sessionStart) else . end' \
        "$target" >"$tmp" && mv "$tmp" "$target" || { rm -f "$tmp"; log "could not edit $target"; }
      ;;
    cursor-mcp)
      tmp=$(mktemp)
      jq 'del(.mcpServers.orgami)' "$target" >"$tmp" && mv "$tmp" "$target" ||
        { rm -f "$tmp"; log "could not edit $target"; }
      ;;
    githook)
      # A hook orgami created holds only its three lines and goes; one that was
      # already there loses those lines and keeps the rest.
      if [[ $(grep -cvxF -e '#!/bin/sh' -e "$UN_GITHOOK_COMMENT" -e "$UN_GITHOOK_LINE" -e '' "$target") == 0 ]]; then
        rm -f -- "$target"
      else
        tmp=$(mktemp)
        awk -v c="$UN_GITHOOK_COMMENT" -v l="$UN_GITHOOK_LINE" '
          { line[NR] = $0 }
          END {
            for (i = 1; i <= NR; i++) {
              if (line[i] == c || line[i] == l) continue
              # the blank line agents_git_hook put in front of its comment
              if (line[i] == "" && line[i + 1] == c) continue
              print line[i]
            }
          }' "$target" >"$tmp"
        cat "$tmp" >"$target"
        rm -f "$tmp"
      fi
      ;;
    claude-plugin)
      claude plugin uninstall orgami@orgami >/dev/null 2>&1 ||
        log "could not uninstall the plugin — run: claude plugin uninstall orgami@orgami"
      ;;
    claude-marketplace)
      claude plugin marketplace remove orgami >/dev/null 2>&1 ||
        log "could not remove the marketplace — run: claude plugin marketplace remove orgami"
      ;;
  esac
}

# orgami uninstall [--dry-run] [--yes] [--purge]
cmd_uninstall() {
  local dry=0 yes=0 purge=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run | -n) dry=1; shift ;;
      --yes | -y) yes=1; shift ;;
      --purge) purge=1; shift ;;
      *) die "unknown flag: $1 — orgami uninstall [--dry-run] [--yes] [--purge]" ;;
    esac
  done

  UN_PLAN=()
  uninstall_plan "$purge"
  # Unit files gone means the manager has to forget them.
  local entry
  for entry in "${UN_PLAN[@]}"; do
    if [[ $entry == systemd-stop$'\t'* || $entry == rm$'\t'*/systemd/user/* ]]; then
      un_plan systemd-reload - "systemctl --user daemon-reload"
      break
    fi
  done
  uninstall_clone "$purge"

  # What stays, named, so nobody wonders whether the team's copy went too.
  local c repo kept=()
  for c in $(companies); do
    repo=$(jq -r '.docs_repo // empty' "$(company_dir "$c")/config.json" 2>/dev/null || true)
    [[ -n $repo ]] && kept+=("the docs repo $repo ($c) and everything published to it")
  done
  [[ $purge == 0 && -d $ORGAMI_HOME ]] && kept+=("$ORGAMI_HOME — every map, note and report here (--purge removes it)")
  kept+=("${UN_KEPT[@]}")

  if [[ ${#UN_PLAN[@]} -eq 0 ]]; then
    echo "orgami installed nothing on this machine that is still here"
  else
    echo "orgami uninstall will:"
    for entry in "${UN_PLAN[@]}"; do
      echo "  - ${entry##*$'\t'}"
    done
  fi
  echo
  echo "It never touches a remote repository. Left in place:"
  for c in "${kept[@]}"; do echo "  - $c"; done
  [[ ${#kept[@]} -gt 0 ]] || echo "  - nothing orgami knows of"

  [[ $dry == 1 || ${#UN_PLAN[@]} -eq 0 ]] && return 0

  if [[ $yes == 0 ]]; then
    need_tty "pass --yes to remove all of the above, or --dry-run to only look"
    local ans
    read -r -p "Remove all of the above? [y/N] " ans
    [[ $ans == [yY]* ]] || { echo "nothing removed"; return 0; }
  fi

  local kind target rest
  for entry in "${UN_PLAN[@]}"; do
    kind=${entry%%$'\t'*}
    rest=${entry#*$'\t'}
    target=${rest%%$'\t'*}
    uninstall_do "$kind" "$target"
  done
  echo "orgami is uninstalled"
}
