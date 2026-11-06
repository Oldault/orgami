#!/usr/bin/env bash
# One command: dependencies, orgami itself, and whichever editors are installed.
#
#   curl -fsSL https://raw.githubusercontent.com/Oldault/orgami/main/bootstrap.sh | bash
#
# Flags (pass with `| bash -s -- --flag`):
#   --dry-run      print what would happen, change nothing
#   --no-deps      skip package installation
#   --no-editors   skip the Claude Code and Cursor wiring
#   --cursor       wire Cursor (its user hooks.json and mcp.json) without asking
#   --no-cursor    leave Cursor alone
#   --path         add ~/.local/bin to PATH in your shell profile without asking
#   --no-path      leave the shell profile alone, and print the line instead
#   --ref=v1.3.0   install that release and hold it there (ORGAMI_REF does the same)
#
# A pinned install is a tag checked out on its own, with no branch to follow, so
# `orgami update` and the daily auto-update leave it alone. Running this again
# with another --ref moves it; running it with none puts it back on main.
#
# Cursor is asked about when there is a terminal, and left alone when there is
# not. ORGAMI_CURSOR=1 or 0 does the same as the two flags. The PATH line is
# asked about the same way, only when no profile already adds ~/.local/bin;
# ORGAMI_PATH=1 or 0 does the same as --path and --no-path.
#
# Written for bash 3.2 too: on macOS `curl | bash` is /bin/bash 3.2, and this
# script is what installs a newer one.

set -Eeuo pipefail

# set -e alone ends the script with whatever the failing command printed, which
# after `sudo: gpg: command not found` is nothing at all about orgami. -E so it
# fires inside functions too.
# Inside quietly() the failing command reads `"$@"`, so quietly() keeps its own
# words in RUNNING for the message.
RUNNING=""
QUIET_LOG=""
on_err() {
  local cmd=$BASH_COMMAND
  [[ $cmd == '"$@"'* && -n $RUNNING ]] && cmd=$RUNNING
  # A quiet command's output was held back as noise; now it is the reason.
  [[ -n $QUIET_LOG && -s $QUIET_LOG ]] && cat "$QUIET_LOG" >&2
  printf '\n\033[31morgami installer stopped: "%s" failed (exit %s, line %s).\033[0m\n' "$cmd" "$1" "$2" >&2
  printf 'Nothing after it ran. Fix that and run the installer again; it picks up where it left off.\n' >&2
}
trap 'on_err $? $LINENO' ERR
trap '[[ -z $QUIET_LOG ]] || rm -f "$QUIET_LOG"' EXIT

REPO_URL=${ORGAMI_REPO:-https://github.com/Oldault/orgami}
SRC=${ORGAMI_SRC:-$HOME/.local/share/orgami}
DRY=0
DEPS=1
EDITORS=1
CURSOR=${ORGAMI_CURSOR:-ask}
ADD_PATH=${ORGAMI_PATH:-ask}
REF=${ORGAMI_REF:-}

for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --no-deps) DEPS=0 ;;
    --no-editors) EDITORS=0 ;;
    --cursor) CURSOR=1 ;;
    --no-cursor) CURSOR=0 ;;
    --path) ADD_PATH=1 ;;
    --no-path) ADD_PATH=0 ;;
    --ref=*) REF=${arg#--ref=} ;;
    -h | --help)
      sed -n '2,28p' "$0" 2>/dev/null || true
      exit 0
      ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# Under `curl | bash` stdin is the rest of this script, so nothing run here may
# read it: a package manager that asks a question (debconf for tzdata) reads
# the script as its answers and loops. Questions go to /dev/tty or nowhere.
#
# What these commands print is pages of progress nobody reads: apt's "Reading
# database ... 5%", debconf's notes, git's clone chatter. So a label is printed
# instead (nothing when it is empty), the output is kept, and it is shown only
# when the command fails, above the stop message that names the command.
# --dry-run prints the whole command.
quietly() {
  local label=$1
  shift
  if [[ $DRY == 1 ]]; then
    dim "would run: $*"
    return 0
  fi
  [[ -z $label ]] || dim "  $label"
  RUNNING="$*"
  QUIET_LOG=$(mktemp)
  "$@" </dev/null >"$QUIET_LOG" 2>&1
  # Reached on failure only where the caller handles it (`quietly ... || ...`),
  # since anywhere else the ERR trap has already stopped the installer.
  local rc=$?
  rm -f "$QUIET_LOG"
  QUIET_LOG=""
  RUNNING=""
  return "$rc"
}

# sudo resets the environment, so the frontend is set on the far side of it.
apt_get() {
  local label=$1
  shift
  quietly "$label" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# ---------------------------------------------------------------- environment

OS=$(uname -s)
case $OS in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  MINGW* | MSYS* | CYGWIN*) PLATFORM=gitbash ;;
  *) PLATFORM=unknown ;;
esac
grep -qi microsoft /proc/version 2>/dev/null && PLATFORM=wsl

MGR=none
if command -v brew >/dev/null; then MGR=brew
elif command -v pacman >/dev/null; then MGR=pacman
elif command -v apt >/dev/null; then MGR=apt
elif command -v dnf >/dev/null; then MGR=dnf
elif command -v winget >/dev/null; then MGR=winget
fi

SUDO=""
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null && SUDO=sudo

bold "orgami installer"
dim "$PLATFORM, package manager: $MGR"

# ---------------------------------------------------------------- dependencies

missing=()
for tool in git gh jq fzf gum python3; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
# Git Bash calls it python, not python3.
[[ $PLATFORM == gitbash ]] && command -v python >/dev/null &&
  missing=("${missing[@]/python3/}")

pkg_name() {
  case "$MGR:$1" in
    brew:gh) echo gh ;;
    brew:python3) echo python ;;
    pacman:gh) echo github-cli ;;
    pacman:python3) echo python ;;
    apt:gh | dnf:gh) echo gh ;;
    winget:gh) echo GitHub.cli ;;
    winget:jq) echo jqlang.jq ;;
    winget:fzf) echo junegunn.fzf ;;
    winget:gum) echo charmbracelet.gum ;;
    winget:git) echo Git.Git ;;
    winget:python3) echo Python.Python.3.12 ;;
    *) echo "$1" ;;
  esac
}

# A terminal to ask on. Under `curl | bash` stdin is the script itself, so the
# question goes to /dev/tty, and only when stdout is a terminal too.
have_tty() { [[ -t 1 ]] && { : </dev/tty; } 2>/dev/null; }

install_missing() {
  local pkgs=()
  local t
  for t in "${missing[@]}"; do
    [[ -n $t ]] && pkgs+=("$(pkg_name "$t")")
  done
  [[ ${#pkgs[@]} -gt 0 ]] || return 0

  case $MGR in
    brew) quietly "installing ${pkgs[*]} with Homebrew" brew install "${pkgs[@]}" ;;
    pacman) quietly "installing ${pkgs[*]} with pacman" $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    dnf) quietly "installing ${pkgs[*]} with dnf" $SUDO dnf install -y "${pkgs[@]}" ;;
    winget)
      for p in "${pkgs[@]}"; do quietly "installing $p with winget" winget install -e --id "$p"; done
      ;;
    apt)
      # gh and gum publish their own repositories; the rest is plain apt.
      local plain=()
      for p in "${pkgs[@]}"; do
        case $p in
          gh | gum) ;;
          *) plain+=("$p") ;;
        esac
      done
      # Adding those repositories needs curl for the keys and gpg to dearmor
      # Charm's. A minimal Debian or Ubuntu image has neither gpg nor, often,
      # curl, and the install would stop halfway with half the tools in.
      if printf '%s\n' "${pkgs[@]}" | grep -qxE 'gh|gum'; then
        command -v curl >/dev/null || plain+=(curl)
      fi
      if printf '%s\n' "${pkgs[@]}" | grep -qx gum; then
        command -v gpg >/dev/null || plain+=(gnupg)
      fi
      apt_get "updating the package lists" update -qq
      [[ ${#plain[@]} -gt 0 ]] && apt_get "installing ${plain[*]}" install -y "${plain[@]}"
      if printf '%s\n' "${pkgs[@]}" | grep -qx gh; then
        if [[ $DRY == 0 ]]; then
          dim "  adding the GitHub CLI apt repository"
          $SUDO mkdir -p -m 755 /etc/apt/keyrings
          curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
            $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
          $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
            $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        else
          dim "would add the GitHub CLI apt repository: /etc/apt/keyrings/githubcli-archive-keyring.gpg, /etc/apt/sources.list.d/github-cli.list"
        fi
      fi
      if printf '%s\n' "${pkgs[@]}" | grep -qx gum; then
        if [[ $DRY == 0 ]]; then
          dim "  adding the Charm apt repository"
          $SUDO mkdir -p /etc/apt/keyrings
          curl -fsSL https://repo.charm.sh/apt/gpg.key |
            $SUDO gpg --batch --yes --dearmor -o /etc/apt/keyrings/charm.gpg
          echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" |
            $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null
        else
          dim "would add the Charm apt repository: /etc/apt/keyrings/charm.gpg, /etc/apt/sources.list.d/charm.list"
        fi
      fi
      apt_get "updating the package lists" update -qq
      for p in gh gum; do
        if printf '%s\n' "${pkgs[@]}" | grep -qx "$p"; then apt_get "installing $p" install -y "$p"; fi
      done
      ;;
    *)
      warn "no package manager found — install by hand: ${pkgs[*]}"
      ;;
  esac
  # Not the status of the last `&&` above: under set -e a false test there
  # would end the whole install with no message.
  return 0
}

if [[ ${#missing[@]} -gt 0 && -n ${missing[0]} ]]; then
  step "Installing ${missing[*]}"
  if [[ $DEPS == 1 ]]; then
    install_missing
  else
    dim "skipped (--no-deps): ${missing[*]}"
  fi
else
  step "Dependencies already present"
fi

# orgami and its hooks need bash 4.4. macOS ships 3.2 at /bin/bash and keeps it
# first on PATH until Homebrew's directory comes before it.
bash_ok() {
  "$1" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null
}
if [[ $PLATFORM == macos ]] && ! bash_ok "$(command -v bash)"; then
  step "orgami needs bash 4.4 or newer; $(command -v bash) is $(bash -c 'echo $BASH_VERSION')"
  if [[ $MGR == brew && $DEPS == 1 ]]; then
    quietly "installing bash with Homebrew" brew install bash
    hash -r
    warn "open a new terminal afterwards, so the new bash comes first on PATH"
  else
    warn "install it, then open a new terminal: brew install bash (Homebrew: https://brew.sh)"
  fi
fi

# jq on PATH is not enough: lib/ is tested down to 1.6 (Debian 12), and an
# older one parses half of it. The same floor as lib/doctor.sh, JQ_FLOOR.
JQ_FLOOR=1.6
jq_ok() {
  local v
  v=$(jq --version 2>/dev/null) || return 1
  [[ $v =~ ([0-9]+)\.([0-9]+) ]] || return 1
  [[ ${BASH_REMATCH[1]} -gt 1 || (${BASH_REMATCH[1]} -eq 1 && ${BASH_REMATCH[2]} -ge 6) ]]
}
if [[ $DRY == 0 ]] && command -v jq >/dev/null && ! jq_ok; then
  warn "$(command -v jq) is $(jq --version 2>/dev/null || echo 'an unknown version'), and orgami needs jq $JQ_FLOOR or newer."
  warn "  Install a newer one from your package manager, or a release binary into ~/.local/bin:"
  warn "  https://github.com/jqlang/jq/releases — then run: orgami doctor"
fi

# ---------------------------------------------------------------------- orgami

step "Installing orgami ${REF:+$REF }into $SRC"
if [[ -d $SRC/.git && -n $REF ]]; then
  quietly "fetching releases" git -C "$SRC" fetch --quiet --tags origin
  quietly "checking out $REF" git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$REF"
elif [[ -d $SRC/.git ]]; then
  # Pinned before and not now: back onto the branch the clone came from, which
  # is the one auto-update follows.
  if [[ $DRY == 0 ]] && ! git -C "$SRC" symbolic-ref -q HEAD >/dev/null; then
    branch=$(git -C "$SRC" rev-parse --abbrev-ref origin/HEAD)
    quietly "back onto ${branch#origin/}" git -C "$SRC" checkout --quiet "${branch#origin/}"
  fi
  quietly "updating $SRC" git -C "$SRC" pull --quiet --ff-only
else
  quietly "" mkdir -p "$(dirname "$SRC")"
  if [[ -n $REF ]]; then
    quietly "cloning $REPO_URL at $REF" git -c advice.detachedHead=false clone --quiet --branch "$REF" "$REPO_URL" "$SRC"
  else
    quietly "cloning $REPO_URL" git clone --quiet "$REPO_URL" "$SRC"
  fi
fi
# install.sh's own report (what is missing, what it linked, what to run next)
# is the closing block below, said once and with the PATH this install leaves.
quietly "linking orgami into $HOME/.local/bin" bash "$SRC/install.sh"

ORGAMI="$SRC/bin/orgami"

# ---------------------------------------------------------------------- editors

if [[ $EDITORS == 1 ]]; then
  if command -v claude >/dev/null; then
    step "Wiring Claude Code"
    # Both refuse when it is already there, which on a re-run is the normal case.
    quietly "adding the orgami marketplace" claude plugin marketplace add Oldault/orgami ||
      dim "  the orgami marketplace is already added"
    quietly "installing the orgami plugin" claude plugin install orgami@orgami ||
      warn "could not install the plugin — run: claude plugin install orgami@orgami"
    # The plugin supplies the skill; the link install.sh made would load it twice.
    skill="$HOME/.claude/skills/orgami/SKILL.md"
    if [[ $DRY == 0 && -L $skill && $(readlink "$skill") == "$SRC/skills/orgami/SKILL.md" ]]; then
      rm -f "$skill"
      # skills/ too when install.sh made it for this link alone.
      rmdir "$(dirname "$skill")" 2>/dev/null && rmdir "$(dirname "$(dirname "$skill")")" 2>/dev/null || true
    fi
  fi

  if [[ -d $HOME/.cursor ]] || command -v cursor >/dev/null; then
    # Cursor's files are the person's own editor config, so this asks first.
    if [[ $CURSOR == ask ]]; then
      if have_tty; then
        printf 'Wire Cursor too (a sessionStart hook and the orgami MCP server in ~/.cursor)? [Y/n] ' >/dev/tty
        read -r answer </dev/tty || answer=n
        case $answer in [nN]*) CURSOR=0 ;; *) CURSOR=1 ;; esac
      else
        CURSOR=0
        dim "Cursor found, left alone with no terminal to ask on. To wire it: bash \"$SRC/bootstrap.sh\" --no-deps --cursor"
      fi
    fi
  fi

  if [[ $CURSOR == 1 ]]; then
    step "Wiring Cursor"
    if [[ $DRY == 0 ]]; then
      "$ORGAMI" agents --cursor-hook --user || warn "could not install the Cursor hook"
      mkdir -p "$HOME/.cursor"
      tmp=$(mktemp)
      [[ -f $HOME/.cursor/mcp.json ]] || echo '{}' >"$HOME/.cursor/mcp.json"
      jq --arg bin "$HOME/.local/bin/orgami" \
        '.mcpServers = ((.mcpServers // {}) + {orgami: {command: $bin, args: ["mcp"]}})' \
        "$HOME/.cursor/mcp.json" >"$tmp" && mv "$tmp" "$HOME/.cursor/mcp.json"
      dim "$HOME/.cursor/mcp.json"
    else
      dim "would install the Cursor sessionStart hook and MCP server"
    fi
  fi
fi

# ------------------------------------------------------------------ next steps

# The files a new shell of the login shell reads, one per line, and whether one
# already puts ~/.local/bin on PATH. Ubuntu's, Debian's and Fedora's do once the
# directory exists; Arch's does not, and then a new terminal will not find
# orgami either. Bash on Linux gets two: a terminal reads ~/.bashrc, a login
# shell reads ~/.bash_profile (or ~/.profile), and Arch's ~/.bashrc returns
# before its end when the shell is not interactive, so `bash -lc` never reaches
# a line appended there. The line checks PATH first, so two is not twice.
# A shell profile is the person's own file, so the line is added only when they
# say so — asked on the terminal, or --path — and printed otherwise.
shell_rc() {
  case $(basename "${SHELL:-bash}") in
    zsh) echo "$HOME/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    bash)
      if [[ $PLATFORM == macos ]]; then echo "$HOME/.bash_profile"; return 0; fi
      echo "$HOME/.bashrc"
      if [[ -f $HOME/.bash_profile ]]; then echo "$HOME/.bash_profile"
      elif [[ -f $HOME/.bash_login ]]; then echo "$HOME/.bash_login"
      elif [[ -f $HOME/.profile ]]; then echo "$HOME/.profile"; fi
      ;;
    *) echo "$HOME/.profile" ;;
  esac
}
# The profile file that already mentions ~/.local/bin, if one does.
profile_adding_local_bin() {
  local f
  for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile" \
    "$HOME/.config/fish/config.fish"; do
    if grep -qs '\.local/bin' "$f"; then echo "$f"; return 0; fi
  done
  return 1
}

# What the closing block says about PATH, gathered here and printed there: a
# warning in the middle of the install scrolls away behind the next step, and
# the person reading "Done." is the one who has to act on it.
path_note=()
here_line='export PATH="$HOME/.local/bin:$PATH"'
[[ $(basename "${SHELL:-bash}") == fish ]] && here_line='set -gx PATH $HOME/.local/bin $PATH'
ON_PATH=1
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    ON_PATH=0
    rcs=$(shell_rc)
    if adds=$(profile_adding_local_bin); then
      # Read at login, not by each new terminal: on a desktop that is after
      # logging out and back in, which is the part people do not expect.
      path_note+=("$HOME/.local/bin is not on this terminal's PATH yet. $adds adds it at the next")
      path_note+=("login (a login shell, or logging out and back in) — check with: bash -lc 'command -v orgami'")
    else
      # shellcheck disable=SC2016  # written to the profile as is, expanded by the shell
      if [[ $rcs == *fish* ]]; then line='fish_add_path $HOME/.local/bin'
      else line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'; fi
      if [[ $ADD_PATH == ask ]]; then
        if have_tty; then
          printf '%s is not on your PATH, and no shell profile here adds it. Add it to %s? [Y/n] ' \
            "$HOME/.local/bin" "${rcs//$'\n'/ and }" >/dev/tty
          read -r answer </dev/tty || answer=n
          case $answer in [nN]*) ADD_PATH=0 ;; *) ADD_PATH=1 ;; esac
        else
          ADD_PATH=0
        fi
      fi
      while IFS= read -r rc; do
        if [[ $ADD_PATH == 1 && $DRY == 1 ]]; then
          path_note+=("Would add $HOME/.local/bin to PATH in $rc: $line")
        elif [[ $ADD_PATH == 1 ]]; then
          mkdir -p "$(dirname "$rc")"
          printf '\n# orgami: ~/.local/bin is where bootstrap.sh linked it\n%s\n' "$line" >>"$rc"
          path_note+=("Added $HOME/.local/bin to PATH in $rc.")
        fi
      done <<<"$rcs"
      if [[ $ADD_PATH == 1 ]]; then
        [[ $DRY == 1 ]] || path_note+=("A new terminal finds orgami; this one does not until step 1.")
      else
        path_note+=("$HOME/.local/bin is not on your PATH, and no shell profile here adds it, so a new")
        path_note+=("terminal will not find orgami either. Add it for $(basename "${SHELL:-bash}"), then open a new terminal:")
        while IFS= read -r rc; do
          if [[ $rc == *fish* ]]; then path_note+=("  $line")
          else path_note+=("  echo '$line' >> \"$rc\""); fi
        done <<<"$rcs"
        path_note+=("or run the installer again with --path to have it added.")
      fi
    fi
    ;;
esac

# One line per tool: what this run found, installed, or could not.
tool_status() {
  local t=$1
  local found=0
  command -v "$t" >/dev/null && found=1
  [[ $t == python3 && $PLATFORM == gitbash ]] && command -v python >/dev/null && found=1
  # :- because bash 3.2 under set -u calls an empty array unbound.
  if [[ " ${missing[*]:-} " != *" $t "* ]]; then
    if [[ $t == jq && $DRY == 0 ]] && ! jq_ok; then
      echo "already present, but $(jq --version 2>/dev/null) — orgami needs jq $JQ_FLOOR or newer"
    else
      echo "already present"
    fi
  elif [[ $DRY == 1 ]]; then
    if [[ $DEPS == 1 ]]; then echo "would be installed"; else echo "missing — skipped (--no-deps)"; fi
  elif [[ $found == 1 ]]; then
    echo "installed"
  elif [[ $DEPS == 0 ]]; then
    echo "missing — skipped (--no-deps)"
  elif [[ $MGR == winget ]]; then
    echo "installed, but not on this terminal's PATH — open a new terminal"
  else
    echo "missing — install it by hand"
  fi
}

echo
if [[ $DRY == 1 ]]; then bold "Done (dry run — nothing was changed)."; else bold "Done."; fi
echo
for t in git gh jq fzf gum python3; do
  printf '  %-8s %s\n' "$t" "$(tool_status "$t")"
done
if command -v claude >/dev/null; then
  printf '  %-8s %s\n' claude "already present"
else
  printf '  %-8s %s\n' claude "not installed — only the written recaps, digests, session notes and playbooks" \
    "" "need it; --stats-only gives the numbers without it." \
    "" "To add it: curl -fsSL https://claude.ai/install.sh | bash"
fi
if [[ $DRY == 1 && -d $SRC/.git ]]; then
  printf '  %-8s %s\n' orgami "would be updated in $SRC${REF:+ to $REF}"
elif [[ $DRY == 1 ]]; then
  printf '  %-8s %s\n' orgami "would be installed in $SRC${REF:+ at $REF}, linked as $HOME/.local/bin/orgami"
else
  printf '  %-8s %s\n' orgami "$SRC${REF:+ at $REF}, linked as $HOME/.local/bin/orgami"
fi

if [[ ${#path_note[@]} -gt 0 ]]; then
  echo
  printf '\033[33m%s\033[0m\n' "${path_note[@]}"
fi

# Numbered from what is left to do here, and every step has a form that runs
# with no terminal: interactive `orgami init` dies without one, so its flag
# form is given too.
echo
bold "Next:"
n=0
nth() { n=$((n + 1)); printf '  %d. %-38s %s\n' "$n" "$1" "$2"; }
also() {
  if [[ -z $2 ]]; then printf '     %s\n' "$1"; else printf '     %-38s %s\n' "$1" "$2"; fi
}
[[ $ON_PATH == 1 ]] || nth "$here_line" "puts orgami on this terminal's PATH"
gh auth status >/dev/null 2>&1 || nth "gh auth login" "sign in to GitHub"
nth "orgami init" "map an organization, step by step"
also "orgami init <name> --org <github-org> --no-docs" ""
also "" "the same, with no terminal to answer on"
also "orgami join" "or pick up one a colleague already mapped"
nth "orgami doctor" "check what is installed and what is missing"
echo
dim "then: orgami schedule (weekly), orgami (the menu), orgami context (in a checkout)"
