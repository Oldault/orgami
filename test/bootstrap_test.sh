#!/usr/bin/env bash
# bootstrap.sh runs as `curl | bash` on somebody's fresh machine, so its stdin
# is the rest of the script and the first package manager that asks a question
# reads the script as its answers. Pinned here: every apt-get runs with the
# noninteractive frontend and an empty stdin, gnupg comes in before Charm's key
# is dearmored, a failed command stops the installer naming that command, a
# rerun gets past the keyring the stopped run left, an old jq is warned about,
# and the PATH line for the shell's rc file is printed unless --path says to
# write it. Package managers run quietly, their output shown only when one
# fails, and the closing block carries everything a terminal-less run needs:
# a line per tool, the PATH, and next steps that need no terminal. --dry-run
# changes nothing.
#
# Run under `env -i` with a PATH of stubs and links to a few base tools: apt,
# apt-get, sudo, dpkg and curl are stubs, apt-get drops a stub binary for each
# package it "installs", /etc/apt is a temp directory, and ORGAMI_REPO is a
# local bare repository holding a no-op install.sh. Nothing is installed and
# nothing leaves the machine.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

# Links to the tools bootstrap.sh and git need, and nothing else, so `command
# -v jq` and friends answer for the stubs alone.
base="$fixture/base"
mkdir -p "$base"
for t in bash sh env grep sed uname dirname basename mkdir cat readlink rm rmdir chmod \
  mktemp mv tee ln tr awk cp find sort head tail git wc ls id; do
  p=$(command -v "$t") || { echo "bootstrap: $t is not on PATH — skipping" >&2; exit 0; }
  ln -s "$p" "$base/$t"
done

# A repository to clone: install.sh leaves a mark, and says so the way the
# real one chatters, which the installer keeps out of sight.
src="$fixture/src"
git init -q "$src"
mkdir -p "$src/bin"
printf '#!/bin/sh\necho "linked install.sh noise"\n: >"$HOME/install.sh-ran"\n' >"$src/install.sh"
printf '#!/bin/sh\nexit 0\n' >"$src/bin/orgami"
git -C "$src" add -A
git -C "$src" -c user.name=t -c user.email=t@t commit -qm init
# A release, then one more commit on the branch, so a pinned install and an
# unpinned one end up on different commits.
git -C "$src" tag v0.1.0
git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m after
tagged=$(git -C "$src" rev-parse v0.1.0) tip=$(git -C "$src" rev-parse HEAD) branch=$(git -C "$src" symbolic-ref --short HEAD)
git clone -q --bare "$src" "$fixture/orgami.git"

# The script with /etc/apt/ moved into the fixture: the keyrings and source
# lists are written for real by tee.
sed "s|/etc/apt/|$fixture/etc/apt/|g" bootstrap.sh >"$fixture/bootstrap.sh"

# gpg the way it treats -o: it writes the file, and an existing one it will
# only overwrite with --yes. Otherwise it asks on the terminal, and with none
# it fails, which is what a rerun after a half-finished install meets.
cat >"$fixture/gpg" <<'GPG'
#!/bin/bash
yes=0 out=
while [ $# -gt 0 ]; do
  case $1 in --yes) yes=1 ;; -o | --output) out=$2; shift ;; esac
  shift
done
if [ -e "$out" ] && [ $yes = 0 ]; then
  echo "gpg: cannot open '/dev/tty': No such device or address" >&2
  exit 2
fi
cat >"$out"
GPG

# setup <case> [apt-get install exit] — a fresh HOME, stub dir and log.
setup() {
  local c=$1 rc=${2:-0}
  home="$fixture/$c/home" stubs="$fixture/$c/stubs" log="$fixture/$c/apt.log"
  mkdir -p "$home" "$stubs" "$fixture/etc/apt/keyrings" "$fixture/etc/apt/sources.list.d"
  : >"$log"
  printf '#!/bin/sh\nexit 0\n' >"$stubs/apt"
  printf '#!/bin/sh\nexec "$@"\n' >"$stubs/sudo"
  printf '#!/bin/sh\necho amd64\n' >"$stubs/dpkg"
  printf '#!/bin/sh\necho "-----BEGIN PGP PUBLIC KEY BLOCK-----"\n' >"$stubs/curl"
  # One line per call: the arguments, the frontend, and whether stdin was
  # empty. On install, a stub binary per package; gnupg is gpg, and jq answers
  # --version with a version the floor accepts.
  cat >"$stubs/apt-get" <<EOF
#!/bin/bash
if IFS= read -r _; then in=data; else in=empty; fi
echo "\$* | DEBIAN_FRONTEND=\${DEBIAN_FRONTEND:-} | stdin=\$in" >>"$log"
[ "\$1" = install ] || exit 0
# What a real apt-get prints on a bare image, on both streams.
echo "(Reading database ... 5%"
echo "debconf: delaying package configuration, since apt-utils is not installed" >&2
[ $rc = 0 ] || { echo "E: Unable to locate package \$3" >&2; exit $rc; }
for p in "\$@"; do
  case \$p in -*|install) continue ;; gnupg) p=gpg ;; esac
  case \$p in
    jq) printf '#!/bin/sh\necho jq-1.7.1\n' >"$stubs/jq" ;;
    gpg) cp "$fixture/gpg" "$stubs/gpg" ;;
    *) printf '#!/bin/sh\nexit 0\n' >"$stubs/\$p" ;;
  esac
  chmod +x "$stubs/\$p"
done
EOF
  chmod +x "$stubs"/*
}

# SHELL is set: bash fills an unset one in from the passwd entry, which would
# make the rc file whichever shell the person running the test logs in with.
boot() {
  env -i HOME="$home" SHELL=/bin/bash PATH="$stubs:$base" ORGAMI_REPO="$fixture/orgami.git" \
    bash -s -- --no-editors "$@" <"$fixture/bootstrap.sh"
}

# --- a fresh Debian: gh, jq, fzf, gum and python3 missing -------------------
setup fresh
rc=0
out=$(boot 2>"$fixture/fresh/err") || rc=$?
check "fresh: the installer finishes" "$rc" "0"
check "fresh: gnupg is in the first install, before Charm's key is dearmored" \
  "$(grep -m1 '^install ' "$log" | grep -cw gnupg)" "1"
check "fresh: every apt-get runs noninteractive with an empty stdin" \
  "$(grep -vc '| DEBIAN_FRONTEND=noninteractive | stdin=empty$' "$log" || true)" "0"
check "fresh: gh and gum installed after their repositories" \
  "$(grep -c '^install -y \(gh\|gum\) ' "$log")" "2"
check "fresh: the PATH line for ~/.bashrc is printed, not written" \
  "$(grep -c ">> \"$home/.bashrc\"" <<<"$out") $([[ -e $home/.bashrc ]] && echo written || echo untouched)" \
  "1 untouched"
check "fresh: orgami's own install.sh ran" "$([[ -e $home/install.sh-ran ]] && echo ran)" "ran"
check "fresh: apt's and install.sh's chatter is kept out of sight" \
  "$(cat - "$fixture/fresh/err" <<<"$out" | grep -c 'Reading database\|apt-utils\|install.sh noise\|DEBIAN_FRONTEND' || true)" "0"
# Everything after "Done." is what a person with no terminal acts on.
closing=$(sed -n '/^.*Done\./,$p' <<<"$out")
check "fresh: a line per tool, installed or already present" \
  "$(grep -cE '^  (gh|jq|fzf|gum|python3) +installed$' <<<"$closing") $(grep -cE '^  git +already present$' <<<"$closing")" "5 1"
check "fresh: claude is optional, and the line says what needs it" \
  "$(grep -c "^  claude   not installed — only the written recaps, digests, session notes and playbooks" <<<"$closing")" "1"
check "fresh: the closing block says ~/.local/bin is not on PATH, with the export line first" \
  "$(grep -c "$home/.local/bin is not on your PATH" <<<"$closing") $(grep -m1 '^  1\. ' <<<"$closing" | grep -c 'export PATH="\$HOME/.local/bin:\$PATH"')" "1 1"
check "fresh: the profile line is in the closing block too" \
  "$(grep -c ">> \"$home/.bashrc\"" <<<"$closing")" "1"
check "fresh: next steps give init's flag form and doctor" \
  "$(grep -c 'orgami init <name> --org <github-org> --no-docs' <<<"$closing") $(grep -c 'orgami doctor' <<<"$closing")" "1 1"
check "fresh: nothing about PATH is said before the end" \
  "$(grep -c 'PATH' "$fixture/fresh/err" || true)" "0"

# --- --dry-run on the same fresh machine --------------------------------------
setup dry
rc=0
out=$(boot --dry-run 2>"$fixture/dry/err") || rc=$?
check "dry run: finishes" "$rc" "0"
check "dry run: no apt-get, no clone, no profile line, no install.sh" \
  "$(wc -l <"$log" | tr -d ' ') $(ls -A "$home" | wc -l | tr -d ' ')" "0 0"
check "dry run: each command it would run is printed whole" \
  "$(grep -c 'would run: sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y' <<<"$out") $(grep -c "would run: bash $home/.local/share/orgami/install.sh" <<<"$out")" "3 1"
check "dry run: the closing block says nothing changed" \
  "$(grep -c 'Done (dry run — nothing was changed)' <<<"$out") $(grep -cE '^  gh +would be installed$' <<<"$out")" "1 1"

# --- Arch: no profile adds ~/.local/bin, and --path says to add it ------------
# Arch's ~/.bashrc returns at once in a shell that is not interactive, and its
# ~/.bash_profile only sources ~/.bashrc, so a line appended to ~/.bashrc alone
# is never read by `bash -lc`. Both get it; a second run adds nothing.
setup arch
printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >"$home/.bash_profile"
printf '[[ $- != *i* ]] && return\n' >"$home/.bashrc"
rc=0
boot --path >/dev/null 2>"$fixture/arch/err" || rc=$?
check "arch: the installer finishes" "$rc" "0"
check "arch: --path writes the line to ~/.bashrc and ~/.bash_profile" \
  "$(grep -c 'export PATH="$HOME/.local/bin:$PATH"' "$home/.bashrc") $(grep -c 'export PATH="$HOME/.local/bin:$PATH"' "$home/.bash_profile")" \
  "1 1"
mkdir -p "$home/.local/bin"
printf '#!/bin/sh\nexit 0\n' >"$home/.local/bin/orgami"
chmod +x "$home/.local/bin/orgami"
# What a login shell reads, without /etc/profile: the machine's own would make
# the answer the test runner's.
check "arch: a login shell finds orgami" \
  "$(env -i HOME="$home" PATH="$base" bash --noprofile --norc -c '. "$HOME/.bash_profile"; command -v orgami')" \
  "$home/.local/bin/orgami"
check "arch: read from both files, it is on PATH once, not twice" \
  "$(env -i HOME="$home" PATH="$base" bash --noprofile --norc -c '. "$HOME/.bash_profile"; eval "$(grep -A1 "^# orgami:" "$HOME/.bashrc" | tail -1)"; echo "$PATH"' | tr ':' '\n' | grep -c "^$home/.local/bin$")" \
  "1"
boot --path >/dev/null 2>&1 || true
check "arch: a second run adds nothing" \
  "$(grep -c '^# orgami:' "$home/.bashrc") $(grep -c '^# orgami:' "$home/.bash_profile")" "1 1"

# --- apt-get install fails --------------------------------------------------
setup broken 100
rc=0
boot >/dev/null 2>"$fixture/broken/err" || rc=$?
check "broken: the installer exits with apt-get's status" "$rc" "100"
check "broken: the message names the command that failed" \
  "$(grep -c 'orgami installer stopped: "sudo env DEBIAN_FRONTEND=noninteractive apt-get install' "$fixture/broken/err")" "1"
check "broken: apt-get's own output is shown in full, above the message" \
  "$(grep -o 'E: Unable to locate package\|Reading database\|orgami installer stopped' "$fixture/broken/err" | tr '\n' '|')" \
  "Reading database|E: Unable to locate package|orgami installer stopped|"

# --- a rerun after a run that stopped once Charm's key was written ------------
# The stop message says to run the installer again, so the second run has to
# get past the keyring the first one left behind.
setup rerun
echo stale >"$fixture/etc/apt/keyrings/charm.gpg"
rc=0
boot >/dev/null 2>"$fixture/rerun/err" || rc=$?
check "rerun: the installer finishes over an existing Charm keyring" "$rc" "0"
check "rerun: the keyring is replaced, not kept" \
  "$(cat "$fixture/etc/apt/keyrings/charm.gpg")" "-----BEGIN PGP PUBLIC KEY BLOCK-----"

# --- an old jq is already there ----------------------------------------------
setup oldjq
printf '#!/bin/sh\necho jq-1.5\n' >"$stubs/jq"
chmod +x "$stubs/jq"
rc=0
boot >/dev/null 2>"$fixture/oldjq/err" || rc=$?
check "old jq: the installer still finishes" "$rc" "0"
check "old jq: the floor is said" "$(grep -c 'needs jq 1.6 or newer' "$fixture/oldjq/err")" "1"

# --- claude present, its marketplace already added ----------------------------
# `claude plugin marketplace add` fails on a rerun, and the installer handles
# that failure itself: it must neither stop nor print claude's complaint.
setup claude
printf '#!/bin/sh\n[ "$2" = marketplace ] && { echo "already added: orgami" >&2; exit 1; }\nexit 0\n' >"$stubs/claude"
chmod +x "$stubs/claude"
rc=0
out=$(env -i HOME="$home" SHELL=/bin/bash PATH="$stubs:$base" ORGAMI_REPO="$fixture/orgami.git" \
  bash -s -- <"$fixture/bootstrap.sh" 2>"$fixture/claude/err") || rc=$?
check "claude: a marketplace already added does not stop the installer" "$rc" "0"
check "claude: said once, without claude's own words" \
  "$(grep -c 'the orgami marketplace is already added' <<<"$out") $(cat - "$fixture/claude/err" <<<"$out" | grep -c 'already added: orgami' || true)" "1 0"
check "claude: listed as already present" "$(grep -cE '^  claude +already present$' <<<"$out")" "1"

# --- a pinned install, moved, then unpinned ----------------------------------
# Pinned means the tag on its own, with no branch: update_why_not then finds no
# upstream and auto-update leaves it alone. Without --ref it goes back on the
# branch, at its tip.
setup pinned
clone="$home/.local/share/orgami"
rc=0
boot --ref=v0.1.0 >/dev/null 2>"$fixture/pinned/err" || rc=$?
check "pinned: the installer finishes" "$rc" "0"
check "pinned: the clone is at the tag, on no branch" \
  "$(git -C "$clone" rev-parse HEAD) $(git -C "$clone" symbolic-ref -q HEAD || echo detached)" "$tagged detached"
boot >/dev/null 2>&1 || true
check "unpinned: a run without --ref is back on the branch, at its tip" \
  "$(git -C "$clone" rev-parse HEAD) $(git -C "$clone" symbolic-ref -q --short HEAD)" "$tip $branch"
boot --ref=v0.1.0 >/dev/null 2>&1 || true
check "pinned again: an existing clone moves to the tag" "$(git -C "$clone" rev-parse HEAD)" "$tagged"

exit "$fail"
