#!/usr/bin/env bash
# `script/check --views` exists because commit 0612efe added one view and, by
# accident, took four others and their assertions with it — and every test
# passed, because the page and its test both glob lib/web/. So what is pinned
# here is that the incident fails, that it still fails when the list is edited
# to match, and that a removal on its own passes. Runs in a throwaway git repo
# built from this checkout's script/check, lib/web and web test — no clone, no
# network, and nothing in this repository's own history is read.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# A repository whose main is this checkout's views, and a branch off it.
repo="$scratch/repo"
mkdir -p "$repo/script" "$repo/lib" "$repo/hooks" "$repo/test"
cp script/check "$repo/script/check"
cp -r lib/web "$repo/lib/web"
cp test/web_render_test.sh "$repo/test/web_render_test.sh"
git -C "$repo" init -q -b main
git -C "$repo" add -A
git -C "$repo" commit -q -m "main"
git -C "$repo" checkout -q -b branch

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

# Run the check in the scratch repo; prints its exit code, stderr goes to $err.
views() {
  local rc=0
  (cd "$repo" && ./script/check --views >"$scratch/out" 2>"$scratch/err") || rc=$?
  echo "$rc"
}

# Restore the branch to main's tree between cases.
reset() {
  git -C "$repo" reset -q --hard main
  git -C "$repo" clean -qfd
}

# What the incident did: a new view, and an existing one gone with its checks.
incident() {
  rm "$repo"/lib/web/30-repos.*
  sed -i '/30-repos\|views\.repos/d' "$repo/test/web_render_test.sh"
  printf 'web.register({id: "graph"});\n' >"$repo/lib/web/25-graph.js"
  printf '{}\n' >"$repo/lib/web/25-graph.jq"
  printf 'check "graph: has a payload" "$(jq -c .views.graph <<<"$data")" "{}"\n' >>"$repo/test/web_render_test.sh"
}

check "the checkout as it is passes" "$(views)" "0"

incident
check "a view and its checks gone beside a new view fails" "$(views)" "1"
check "and the failure names what is missing" \
  "$(grep -c '30-repos\|repos view' "$scratch/err")" "2"

# The list edited to match the tree, the new view listed too: still a removal
# in a branch that adds a view.
sed -i '/^  30-repos$/d; s/^)$/  25-graph\n)/' "$repo/script/check"
check "the list edited to match still fails while a view is being added" "$(views)" "1"
check "and it says why" "$(grep -c 'its own change' "$scratch/err")" "1"
reset

# A removal on its own: files, checks and the list entry, nothing added.
rm "$repo"/lib/web/30-repos.*
sed -i '/30-repos\|views\.repos/d' "$repo/test/web_render_test.sh"
sed -i '/^  30-repos$/d' "$repo/script/check"
check "a view removed on its own, list and checks with it, passes" "$(views)" "0"
check "and says so" "$(grep -c '30-repos' "$scratch/out")" "3"
reset

# The files stay, the assertions go.
sed -i '/30-repos\|views\.repos/d' "$repo/test/web_render_test.sh"
check "a view whose checks are gone fails with the files still there" "$(views)" "1"
reset

# A view added without being listed.
printf 'web.register({id: "graph"});\n' >"$repo/lib/web/25-graph.js"
check "a view on disk that the list does not name fails" "$(views)" "1"
check "and the failure names it" "$(grep -c 'not listed: lib/web/25-graph' "$scratch/err")" "1"
reset

# Nowhere to compare against: the list and the tree still have to agree.
git -C "$repo" branch -q -D main
check "with no main the list is still held to the tree" "$(views)" "0"
check "and the check says it had no main" "$(grep -c 'no main' "$scratch/out")" "1"
rm "$repo"/lib/web/50-live.*
check "and a listed view missing from disk still fails" "$(views)" "1"

exit "$fail"
