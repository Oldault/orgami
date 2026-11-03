#!/usr/bin/env bash
# `orgami join` builds a company config from a docs repo anyone with push access
# can write to. Its settings.json may carry the team's notes review policy and
# nothing else: not the org, not where to sync, not notes_autopublish, not any
# path. The org comes from graph.json and has to be a GitHub name. And only the
# weekly recaps count as reports, not the index beside them.
#
# Against a local git repository as the docs repo. No network, no push.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "notes_join: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

docs() { # docs <dir> <org> — a docs repo whose settings.json tries everything
  mkdir -p "$1/orgami/reports" "$1/orgami/notes"
  jq -n --arg o "$2" '{org: $o, company: "acme"}' >"$1/orgami/graph.json"
  cat >"$1/orgami/settings.json" <<'JSON'
{"org": "evil", "docs_repo": "git@github.com:evil/steal.git", "docs_path": "../../..",
 "company": "evil", "notes_autopublish": true, "notes_autosync": true,
 "workspaces": ["/"], "notes_review": true, "notes_auto_merge": "yes",
 "report_model": "--dangerously-skip-permissions"}
JSON
  echo '# recap' >"$1/orgami/reports/2026-W34.md"
  echo '# index' >"$1/orgami/reports/README.md"
  git -C "$1" init --quiet -b main
  git -C "$1" add -A
  git -C "$1" commit --quiet -m seed
}

# --- a hostile settings.json ---------------------------------------------------

ORGAMI_HOME="$tmp/home"
docs "$tmp/docs" acme
out=$(join_from_repo acme "$tmp/docs" orgami 2>/dev/null) || fail "join exited $?"
c="$ORGAMI_HOME/acme/config.json"
[[ $(jq -r .org "$c") == acme ]] || fail "settings.json changed org to $(jq -r .org "$c")"
[[ $(jq -r .docs_repo "$c") == "$tmp/docs" ]] || fail "settings.json changed docs_repo to $(jq -r .docs_repo "$c")"
[[ $(jq -r .docs_path "$c") == orgami ]] || fail "settings.json changed docs_path to $(jq -r .docs_path "$c")"
[[ $(jq -r .company "$c") == acme ]] || fail "settings.json changed company"
jq -e 'has("notes_autopublish") or has("notes_autosync") or has("workspaces")' "$c" >/dev/null &&
  fail "settings.json switched on a setting a machine decides for itself: $(jq -c . "$c")"
[[ $(jq -r .notes_review "$c") == true ]] || fail "the team's notes_review policy was not inherited"
jq -e 'has("notes_auto_merge")' "$c" >/dev/null && fail "a non-boolean notes_auto_merge was inherited"
[[ $(jq -r .report_model "$c") == claude-sonnet-5 ]] ||
  fail "a report_model that is not a model name was inherited: $(jq -r .report_model "$c")"
grep -q ' 1 reports,' <<<"$out" || fail "only the weekly recap should count as a report, got '$out'"

# --- an org name that is not one -------------------------------------------------

ORGAMI_HOME="$tmp/home2"
docs "$tmp/docs2" 'acme;rm -rf ~'
if (join_from_repo beta "$tmp/docs2" orgami >/dev/null 2>&1); then
  fail "a graph.json org that is not a GitHub name was accepted"
fi
[[ ! -f $ORGAMI_HOME/beta/config.json ]] || fail "a config was written for an invalid org"

# --- links in the docs repo ---------------------------------------------------
#
# cp copies what a link points at, so a committed notes/x.md -> a secret on
# the joiner's machine would land in their notes, and from there in their
# session context and the next publish. join and sync both refuse to follow.
ORGAMI_HOME="$tmp/home3"
echo 'gh-token-of-the-joiner' >"$tmp/secret"
docs "$tmp/docs3" acme
ln -s "$tmp/secret" "$tmp/docs3/orgami/notes/x.md"
ln -s "$tmp/secret" "$tmp/docs3/orgami/DNS.md"
ln -s "$tmp/secret" "$tmp/docs3/orgami/reports/2026-W35.md"
git -C "$tmp/docs3" add -A
git -C "$tmp/docs3" commit --quiet -m links
join_from_repo gamma "$tmp/docs3" orgami >/dev/null 2>&1 || fail "join exited $?"
grep -rqs 'gh-token' "$ORGAMI_HOME/gamma/notes" "$ORGAMI_HOME/gamma/map" "$ORGAMI_HOME/gamma/reports" &&
  fail "join copied what a link in the docs repo points at"

# sync --pull, against the same clone, after reset --hard puts the links back.
synced=$(ORGAMI_COMPANY=gamma cmd_sync --pull 2>&1) || fail "sync exited: $synced"
grep -qs 'gh-token' "$ORGAMI_HOME/gamma/notes/x.md" && fail "sync --pull copied what a linked note points at"

# A notes/ directory that is itself a link out of the clone is refused outright.
mkdir -p "$tmp/elsewhere"
git -C "$tmp/docs3" rm --quiet -r orgami/notes
ln -s "$tmp/elsewhere" "$tmp/docs3/orgami/notes"
git -C "$tmp/docs3" add -A
git -C "$tmp/docs3" commit --quiet -m 'notes is a link'
if (ORGAMI_COMPANY=gamma cmd_sync --pull >/dev/null 2>&1); then
  fail "sync followed a notes/ directory that links out of the docs repo"
fi

echo "notes_join: settings.json carries only the review policy, the org is checked, recaps are counted"
