#!/usr/bin/env bash
# The session-start hook runs `orgami autosync` on every session, unasked. So
# unless the person turned on notes_autosync, autosync may only take what
# teammates wrote — the pull half — and never push this machine's notes to the
# docs repo. With notes_autosync true, the push half runs as before.
#
# End-to-end through bin/orgami against a disposable ORGAMI_HOME and a local
# bare repository as the docs repo. A stub `gh` that always fails stands in for
# the network. Nothing leaves the temp dir.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
orgami=$PWD/bin/orgami

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "notes_autosync: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# The docs repo, holding one note a teammate already published.
git init --quiet --bare -b main "$tmp/origin.git"
git clone --quiet "$tmp/origin.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/orgami/notes"
printf -- '---\nid: theirs\nauthor: them\ndate: 2026-08-20T00:00:00Z\n---\n\nwhat a teammate learned\n' \
  >"$tmp/seed/orgami/notes/theirs.md"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" commit --quiet -m seed
git -C "$tmp/seed" push --quiet origin main

home="$tmp/home"
mkdir -p "$home/acme/notes"
echo '{"default":"acme","author":"t"}' >"$home/config.json"
jq -n --arg r "$tmp/origin.git" '{org: "acme", docs_repo: $r, docs_path: "orgami"}' >"$home/acme/config.json"
printf -- '---\nid: mine\nauthor: t\ndate: 2026-08-21T00:00:00Z\n---\n\nwhat this machine learned\n' \
  >"$home/acme/notes/mine.md"

published() { git -C "$tmp/origin.git" ls-tree -r --name-only main -- orgami/notes | grep -qx "orgami/notes/$1"; }

# --- notes_autosync unset: take, never give -----------------------------------

ORGAMI_HOME=$home ORGAMI_COMPANY=acme "$orgami" autosync --quiet >/dev/null 2>&1 ||
  fail "autosync exited $? with notes_autosync unset"
[[ -f $home/acme/notes/theirs.md ]] || fail "the teammate's note was not pulled"
published mine.md && fail "autosync pushed a note with notes_autosync unset"
grep -q 'notes_autosync is off' "$home/acme/cache/autosync.log" ||
  fail "the log should say why nothing was published"

# --- notes_autosync true: the person opted in ----------------------------------

jq '.notes_autosync = true' "$home/acme/config.json" >"$tmp/c" && mv "$tmp/c" "$home/acme/config.json"
ORGAMI_HOME=$home ORGAMI_COMPANY=acme "$orgami" autosync --quiet >/dev/null 2>&1 ||
  fail "autosync exited $? with notes_autosync true"
published mine.md || fail "with notes_autosync true the note should have been pushed ($(tail -3 "$home/acme/cache/autosync.log"))"

# --- what a run prints is that run --------------------------------------------
# The log is shared by every run. Printing its tail showed the previous run's
# outcome above this one's, which read as this run having said both.

jq '.notes_autosync = false' "$home/acme/config.json" >"$tmp/c" && mv "$tmp/c" "$home/acme/config.json"
ORGAMI_HOME=$home ORGAMI_COMPANY=acme "$orgami" autosync </dev/null >/dev/null 2>&1 || fail "autosync with notes_autosync off failed"
jq '.notes_autosync = true' "$home/acme/config.json" >"$tmp/c" && mv "$tmp/c" "$home/acme/config.json"
out=$(ORGAMI_HOME=$home ORGAMI_COMPANY=acme "$orgami" autosync </dev/null 2>&1) || fail "autosync with notes_autosync on failed"
grep -q 'notes_autosync is off' <<<"$out" && fail "autosync printed the previous run's outcome: $out"
[[ $(grep -c '^--- ' <<<"$out") == 1 ]] || fail "autosync printed more than its own run: $out"
grep -q 'notes_autosync is off' "$home/acme/cache/autosync.log" || fail "the log no longer keeps earlier runs"

echo "notes_autosync: off only pulls, on pushes, each run prints only itself"
