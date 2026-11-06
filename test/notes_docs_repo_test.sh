#!/usr/bin/env bash
# The docs repo is the sync layer, and the first person to use orgami in a
# company usually creates it empty. `git clone` of an empty repository writes no
# fetch refspec, so the clone in cache/docs never saw its own first push: every
# later publish said the repo was still empty, sync died on git's own
# "ambiguous argument 'origin/HEAD'", and once a teammate had pushed, publish was
# rejected as non-fast-forward. A clone made that way by an older orgami has to
# heal by itself too. A teammate who joins gets the playbooks, runbooks and
# daily digests the map points at, not only its index, and keeps getting them
# through sync. The publish commit names the recap it carries, not the
# calendar week it ran in.
#
# Against local bare repositories as the docs repo. A stub `gh` that always
# fails stands in for the network; nothing is pushed anywhere but the temp dir.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
orgami=$PWD/bin/orgami

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "notes_docs_repo: $*" >&2; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" ORGAMI_AUTOUPDATE=0
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"

company() { # company <home> <name> <docs repo>
  mkdir -p "$1/$2/map" "$1/$2/reports"
  echo "{\"default\":\"$2\",\"author\":\"$2-author\"}" >"$1/config.json"
  jq -n --arg r "$3" '{org: "acme", docs_repo: $r, docs_path: "orgami"}' >"$1/$2/config.json"
  jq -n '{org: "acme", company: "acme", nodes: [], edges: []}' >"$1/$2/map/graph.json"
  jq -n '[{name: "gatus"}, {name: "shop-app"}]' >"$1/$2/map/repos.json"
}
as() { local h=$1; shift; ORGAMI_HOME=$h "$orgami" "$@" </dev/null; }
log_of() { git --git-dir="$1" log --format=%s main 2>/dev/null; }

# --- an empty docs repo, published into twice -----------------------------------

git init --quiet --bare -b main "$tmp/docs.git"
a="$tmp/a"
company "$a" acme "$tmp/docs.git"
printf '# acme — 2026-W44\n\nOne pull request merged.\n' >"$a/acme/reports/2026-W44.md"
mkdir -p "$a/acme/map/playbooks" "$a/acme/map/runbooks" "$a/acme/reports/daily"
printf '# gatus — monitor a client site\n\nsteps\n' >"$a/acme/map/playbooks/gatus--monitor-a-client-site.md"
printf '# gatus runbook\n' >"$a/acme/map/runbooks/gatus.md"
printf '# 2026-11-03\n\n2026-11-03 one merge\n' >"$a/acme/reports/daily/2026-11-03.md"

out=$(as "$a" publish --yes 2>&1) || fail "the first publish into an empty repo failed: $out"
grep -q 'is empty' <<<"$out" || fail "the first publish should say the repo is empty: $out"
[[ $(log_of "$tmp/docs.git") == "docs(orgami): acme 2026-W44 recap and map" ]] ||
  fail "the first commit should name the recap it carries: $(log_of "$tmp/docs.git")"

out=$(as "$a" publish --yes 2>&1) || fail "the second publish failed: $out"
grep -q 'is empty' <<<"$out" && fail "the second publish still thinks the repo is empty: $out"
grep -q 'nothing to publish' <<<"$out" || fail "the second publish should find nothing new: $out"

# --- sync on the clone the first publish made ------------------------------------

as "$a" note --repo gatus 'from the first machine' >/dev/null 2>&1 || fail "note failed"
out=$(as "$a" sync 2>&1) || fail "sync after the first publish exited $?: $out"
grep -q 'origin/HEAD' <<<"$out" && fail "sync leaked git's origin/HEAD error: $out"
grep -q '1 out' <<<"$out" || fail "sync should have pushed the note: $out"

# A hand-written note on a repo the map does not hold stays on this machine.
printf -- '---\nid: stray\nauthor: t\ndate: 2026-08-20T00:00:00Z\nrepo: zzz-typo\n---\n\nstray\n' >"$a/acme/notes/stray.md"
out=$(as "$a" sync 2>&1) || fail "sync with a stray note exited $?: $out"
grep -q "not syncing stray.md — its repo 'zzz-typo' is not in the map" <<<"$out" || fail "sync did not hold the stray note back: $out"
tree=$(git --git-dir="$tmp/docs.git" ls-tree -r --name-only main)
grep -q 'stray.md' <<<"$tree" && fail "sync published a note on a repo the map lacks"
rm -f "$a/acme/notes/stray.md"

# --- a teammate joins, and gets what the map points at ----------------------------

b="$tmp/b"
mkdir -p "$b"
echo '{"author":"b-author"}' >"$b/config.json"
ORGAMI_HOME=$b "$orgami" join acme --repo "$tmp/docs.git" </dev/null >/dev/null 2>&1 || fail "join failed"
for f in map/playbooks/gatus--monitor-a-client-site.md map/runbooks/gatus.md reports/daily/2026-11-03.md reports/2026-W44.md; do
  [[ -f $b/acme/$f ]] || fail "join left out $f"
done
out=$(as "$b" playbooks 2>/dev/null) || fail "playbooks failed on the joined home"
grep -q 'monitor-a-client-site' <<<"$out" || fail "the joined home lists no playbook: $out"

# A playbook published after the join arrives with the next sync --pull, and
# one this machine already has is left as it is.
printf '# shop-app — ship a release\n\nsteps\n' >"$a/acme/map/playbooks/shop-app--ship-a-release.md"
echo 'edited on b' >>"$b/acme/map/playbooks/gatus--monitor-a-client-site.md"
as "$a" publish --yes >/dev/null 2>&1 || fail "publishing the second playbook failed"
out=$(as "$b" sync --pull 2>&1) || fail "sync --pull on the joined home failed: $out"
[[ -f $b/acme/map/playbooks/shop-app--ship-a-release.md ]] || fail "sync --pull did not take the new playbook: $out"
grep -q 'edited on b' "$b/acme/map/playbooks/gatus--monitor-a-client-site.md" ||
  fail "sync --pull overwrote a playbook this machine already had"
grep -q 'ship-a-release' "$b/acme/map/PLAYBOOKS.md" || fail "the playbook index does not list the playbook sync took"

# --- the teammate pushes; the first machine still publishes -------------------------

as "$b" note --repo shop-app 'from the teammate' >/dev/null 2>&1 || fail "the teammate's note failed"
as "$b" sync >/dev/null 2>&1 || fail "the teammate's sync failed"
echo 'a late correction' >>"$a/acme/reports/2026-W44.md"
printf '# acme — 2026-W45\n\nTwo merged.\n' >"$a/acme/reports/2026-W45.md"
out=$(as "$a" publish --yes 2>&1) || fail "publish after a teammate pushed failed: $out"
[[ $(log_of "$tmp/docs.git" | head -1) == "docs(orgami): acme 2026-W44..2026-W45 recaps and map" ]] ||
  fail "the commit should name the recaps it changed: $(log_of "$tmp/docs.git" | head -1)"
# Captured first: grep -q stops reading early, and under pipefail git's broken
# pipe would read as a failure.
history=$(log_of "$tmp/docs.git")
grep -q 'notes(acme): 1 from b-author' <<<"$history" || fail "the teammate's commit was lost: $history"

# A publish that changes no recap does not name one.
echo '# changed' >>"$a/acme/map/runbooks/gatus.md"
as "$a" publish --yes >/dev/null 2>&1 || fail "a map-only publish failed"
[[ $(log_of "$tmp/docs.git" | head -1) == "docs(orgami): acme map" ]] ||
  fail "a publish with no recap in it named one: $(log_of "$tmp/docs.git" | head -1)"

# --- a clone left behind by an older orgami heals ----------------------------------

git init --quiet --bare -b main "$tmp/docs2.git"
c="$tmp/c"
company "$c" acme "$tmp/docs2.git"
git clone --quiet --depth 1 "$tmp/docs2.git" "$c/acme/cache/docs" 2>/dev/null
[[ -z $(git -C "$c/acme/cache/docs" config --get-all remote.origin.fetch) ]] ||
  fail "this git writes a refspec for an empty clone — the case below no longer reproduces"
git clone --quiet "$tmp/docs2.git" "$tmp/seed" 2>/dev/null
mkdir -p "$tmp/seed/orgami/notes"
printf -- '---\nid: theirs\nauthor: them\ndate: 2026-08-20T00:00:00Z\n---\n\nwhat a teammate learned\n' \
  >"$tmp/seed/orgami/notes/theirs.md"
git -C "$tmp/seed" add -A
git -C "$tmp/seed" commit --quiet -m seed
git -C "$tmp/seed" push --quiet origin HEAD:main
out=$(as "$c" sync 2>&1) || fail "sync on a clone of an empty repo, since pushed to, exited $?: $out"
[[ -f $c/acme/notes/theirs.md ]] || fail "sync on the healed clone did not take the teammate's note: $out"

# --- a docs repo nobody can reach fails in orgami's words ---------------------------

d="$tmp/d"
company "$d" acme "$tmp/missing.git"
out=$(as "$d" sync 2>&1) && fail "sync against a missing repo succeeded"
grep -q '^orgami: cannot reach .*rerun: orgami sync' <<<"$out" || fail "sync against a missing repo gave no next step: $out"
out=$(as "$d" publish --yes 2>&1) && fail "publish against a missing repo succeeded"
grep -q '^orgami: cannot reach .*rerun: orgami publish' <<<"$out" || fail "publish against a missing repo gave no next step: $out"

echo "notes_docs_repo: an empty docs repo keeps working after its first publish, joins carry playbooks, commits name their recap"
