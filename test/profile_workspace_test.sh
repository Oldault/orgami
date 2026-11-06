#!/usr/bin/env bash
# The monorepo half of the profile: which directories are packages, what the
# env list keeps when a repo reads three hundred names, and what one
# instruction file under two names comes out as.
#
#   - profile_workspace_dirs answers from the declaration when there is one —
#     pnpm-workspace.yaml in block or flow style, package.json `workspaces` in
#     array or object form, lerna.json — honours a `!` negation, and falls back
#     to a shallow walk only when nothing is declared. It never answers the
#     root, a node_modules, a dist, or a directory a link leads out of the
#     checkout to, and it stops at PROFILE_WS_MAX
#   - profile_env ranks what an example env file declares, nested ones
#     included, ahead of what code reads, cuts at PROFILE_ENV_MAX, and
#     profile_repo says the total beside it. Names that only a README, a docs
#     tree or a test mentions are not configuration
#   - AGENTS.md -> CLAUDE.md is one entry, kept under the real file's name, and
#     the link's name is kept as an alias
#
# Fixture trees in a temp directory. No checkout, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/profile.sh
source lib/profile.sh

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail=0
tree() { mktemp -d "$root/case.XXXXXX"; }
pkg() { mkdir -p "$1/$2" && printf '{"name": "%s"}\n' "${2##*/}" >"$1/$2/package.json"; }

# Asserts the directory list, as one line, against what is expected.
dirs_are() {
  local what=$1 want=$2 src=$3 got
  profile_workspace_forget
  got=$(profile_workspace_dirs "$src" | paste -sd' ' -)
  [[ $got == "$want" ]] && return 0
  printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$what" "$want" "$got" >&2
  fail=1
}

assert() {
  local what=$1 filter=$2 json=$3
  [[ $(jq -r "$filter" <<<"$json") == true ]] && return 0
  printf 'FAIL: %s\n  got: %s\n' "$what" "$(jq -c . <<<"$json")" >&2
  fail=1
}

# --- profile_workspace_dirs -------------------------------------------------------

d=$(tree)
cat >"$d/pnpm-workspace.yaml" <<'YAML'
packages:
  - "apps/*"   # every app
  - 'packages/**'
  - '!**/test/**'
catalog:
  zod: ^3
YAML
printf '{}\n' >"$d/package.json"
pkg "$d" apps/web
pkg "$d" apps/api
pkg "$d" packages/ui
pkg "$d" packages/plugins/auth
pkg "$d" packages/test/fixture
pkg "$d" packages/ui/node_modules/react
pkg "$d" other/thing
mkdir -p "$d/apps/empty"
dirs_are "pnpm-workspace.yaml block style, ** and a negation" \
  "apps/api apps/web packages/plugins/auth packages/ui" "$d"
[[ $(profile_workspace_how "$d") == declared ]] ||
  { echo "FAIL: a declaration is reported as declared" >&2; fail=1; }

d=$(tree)
printf "packages: ['libs/*', \"tools/cli\"]\n" >"$d/pnpm-workspace.yaml"
pkg "$d" libs/a
pkg "$d" tools/cli
dirs_are "pnpm-workspace.yaml flow style" "libs/a tools/cli" "$d"

d=$(tree)
printf '{"workspaces": ["web", "backend"]}\n' >"$d/package.json"
pkg "$d" web
pkg "$d" backend
pkg "$d" engine
dirs_are "package.json workspaces, array form, and nothing undeclared" "backend web" "$d"

d=$(tree)
printf '{"workspaces": {"packages": ["services/*"], "nohoist": ["**"]}}\n' >"$d/package.json"
pkg "$d" services/rag
dirs_are "package.json workspaces, object form" "services/rag" "$d"

d=$(tree)
printf '{"packages": ["modules/*"]}\n' >"$d/lerna.json"
pkg "$d" modules/one
dirs_are "lerna.json packages" "modules/one" "$d"

# Nothing declared: the walk finds a server/ beside the root app, two levels
# down at most, and not an example or a build output.
d=$(tree)
printf '{"dependencies": {"react": "18"}}\n' >"$d/package.json"
pkg "$d" server
pkg "$d" tools/gen
pkg "$d" a/b/too-deep
pkg "$d" examples/demo
pkg "$d" dist/server
dirs_are "the fallback walk, pruned and shallow" "server tools/gen" "$d"
[[ $(profile_workspace_how "$d") == found ]] ||
  { echo "FAIL: the fallback is reported as found" >&2; fail=1; }

d=$(tree)
printf 'just a script\n' >"$d/run.sh"
dirs_are "a repo with no package anywhere has no workspaces" "" "$d"
[[ -z $(profile_workspace_how "$d") ]] ||
  { echo "FAIL: no packages is reported as nothing" >&2; fail=1; }

# A declared pattern is somebody else's data: a link out of the checkout and a
# pattern that climbs out of it are both refused.
d=$(tree)
outside=$(tree)
pkg "$outside" evil
printf '{"workspaces": ["apps/*", "../*"]}\n' >"$d/package.json"
pkg "$d" apps/ok
ln -s "$outside/evil" "$d/apps/escape"
dirs_are "a link out of the checkout and a ../ pattern are refused" "apps/ok" "$d"

d=$(tree)
printf '{"workspaces": ["p/*"]}\n' >"$d/package.json"
for i in $(seq -w 1 30); do pkg "$d" "p/x$i"; done
profile_workspace_forget
[[ $(profile_workspace_dirs "$d" | wc -l | tr -d ' ') == "$PROFILE_WS_MAX" ]] ||
  { echo "FAIL: the list stops at PROFILE_WS_MAX" >&2; fail=1; }

# --- profile_env ------------------------------------------------------------------

d=$(tree)
mkdir -p "$d/apps/api" "$d/src" "$d/docs" "$d/tests"
printf 'ZZ_SECRET_KEY=\nexport ZZ_DSN=x\n' >"$d/apps/api/.env.example"
printf 'ZZ_MAIL=x\n' >"$d/apps/api/mail.env.example"
for i in $(seq -w 1 80); do echo "const v$i = process.env.AA_VAR_$i"; done >"$d/src/config.ts"
echo 'process.env.AA_VAR_01 and process.env.ZZ_SECRET_KEY' >>"$d/src/config.ts"
echo 'set process.env.README_ONLY first' >"$d/README.md"
echo 'process.env.DOCS_ONLY' >"$d/docs/setup.ts"
echo 'process.env.ACCEPTANCE_KNOB' >"$d/tests/run.ts"
profile_workspace_forget
out=$(profile_env "$d")
assert "a nested example env file is read, export and *.env.example included" \
  '.[0:3] == ["ZZ_DSN", "ZZ_MAIL", "ZZ_SECRET_KEY"]' "$out"
assert "the list stops at PROFILE_ENV_MAX" "length == $PROFILE_ENV_MAX" "$out"
assert "a declared name is listed once" 'map(select(. == "ZZ_SECRET_KEY")) | length == 1' "$out"
all=$(profile_env_all "$d")
[[ $(grep -c . <<<"$all") == 83 ]] ||
  { echo "FAIL: profile_env_all should keep all 83 names, got $(grep -c . <<<"$all")" >&2; fail=1; }
for bad in README_ONLY DOCS_ONLY ACCEPTANCE_KNOB; do
  if grep -qx "$bad" <<<"$all"; then
    echo "FAIL: $bad is only mentioned, not read" >&2
    fail=1
  fi
done

# --- profile_docs -----------------------------------------------------------------

d=$(tree)
printf '# rules\n' >"$d/CLAUDE.md"
ln -s CLAUDE.md "$d/AGENTS.md"
printf '# how\n' >"$d/CONTRIBUTING.md"
assert "a link to an instruction file is not a second one" \
  '. == ["CLAUDE.md", "CONTRIBUTING.md"]' "$(profile_docs "$d")"
assert "the link's name is kept as an alias" \
  '. == {"AGENTS.md": "CLAUDE.md"}' "$(profile_doc_aliases "$d")"

d=$(tree)
printf '# a\n' >"$d/AGENTS.md"
printf '# c\n' >"$d/CLAUDE.md"
assert "two real files are two entries" '. == ["AGENTS.md", "CLAUDE.md"]' "$(profile_docs "$d")"

# --- profile_repo -----------------------------------------------------------------

# profile_calls and profile_serves filter on the scan's noise list, which lives
# in lib/scan.sh; a pattern that matches nothing stands in for it here.
export NOISE_DOMAINS='^$'
d=$(tree)
printf '{"workspaces": ["apps/*"]}\n' >"$d/package.json"
mkdir -p "$d/apps/web/src/app/api/x"
printf '{"name": "web", "dependencies": {"next": "14"}}\n' >"$d/apps/web/package.json"
touch "$d/apps/web/src/app/api/x/route.ts"
for i in $(seq 1 70); do echo "process.env.V_$i"; done >"$d/apps/web/env.ts"
EMITDIR=$(tree)
profile_workspace_forget
profile_repo demo "$d" '{}'
out=$(cat "$EMITDIR/p-demo.json")
assert "profile_repo keeps the older fields as they were" \
  'has("frameworks") and has("commands") and has("env") and has("routes") and has("agent_docs")' "$out"
assert "env_total is the count before the cut" \
  ".env_total == 70 and (.env | length) == $PROFILE_ENV_MAX" "$out"
assert "routes_total counts what was found" '.routes_total == 1' "$out"
assert "workspaces names each package and its frameworks" \
  '.workspaces == [{"dir": "apps/web", "name": "web", "frameworks": ["Next.js"]}]' "$out"
assert "the framework of a workspace package is the repo's" '.frameworks == ["Next.js"]' "$out"
assert "agent_doc_aliases is an object even when empty" '.agent_doc_aliases == {}' "$out"
[[ -z $PROFILE_WS_FOR ]] || { echo "FAIL: profile_repo leaves no workspace cache behind" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "profile_workspace: packages found, env ranked and counted, one file per instruction text"
else
  exit 1
fi
