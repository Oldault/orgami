#!/usr/bin/env bash
# What `profile_framework` and `profile_commands` read off a checkout today.
#
# Every framework, package manager and runtime the profile knows about arrives
# as another branch inside these two functions, and nothing pins what the
# existing branches already answer — so a branch added for one framework can
# quietly change the answer for another. This is the harness those additions
# assert against.
#
# Five things are under test, and the third is the quiet one:
#
#   - a dependency, a `manage.py`, a `go.mod` each name the framework behind
#     them, and a tree with none of them reports an empty list rather than a
#     guess
#   - React is only reported when nothing else was: `react` sits under Next.js,
#     React Native and Expo, so reporting it beside them would say the repo is
#     two frameworks. That is the `[[ ${#out[@]} -eq 0 ]]` guard, and it is what
#     a new meta-framework branch is most likely to walk past
#   - the caps are caps, not coincidences: eight package.json scripts and six
#     Makefile targets, taken in file order
#   - `make` contributes only targets in the vocabulary, so a `deploy:` target
#     never lands in something a reader might run
#   - package_manager follows the documented precedence all the way down, one
#     lockfile at a time
#
# Fixture trees in a temp directory. No checkout, no network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/profile.sh
source lib/profile.sh

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

fail=0

# A fresh empty checkout.
tree() { mktemp -d "$root/case.XXXXXX"; }

# profile_framework ends in `grep -v '^$'`, which reports "nothing matched" for
# a tree that has no framework in it at all. Under `set -o pipefail` that is a
# non-zero return even though the JSON on stdout is right, so what is asserted
# here is the document, never the status.
framework() { profile_framework "$1" || true; }

# Each assertion is a jq predicate over the whole document, so a failure can
# print what the function actually said instead of a fragment of it.
assert() {
  local what=$1 filter=$2 json=$3
  [[ $(jq -r "$filter" <<<"$json") == true ]] && return 0
  printf 'FAIL: %s\n  got: %s\n' "$what" "$(jq -c . <<<"$json")" >&2
  fail=1
}

# --- profile_framework ---------------------------------------------------------

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"next": "14.2.3", "react": "18.3.1"}}
JSON
out=$(framework "$d")
assert "next in dependencies is Next.js" '. == ["Next.js"]' "$out"
assert "react beside next is not also React" '(index("React")) == null' "$out"

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"express": "4.19.2"}}
JSON
assert "express in dependencies is Express" '. == ["Express"]' "$(framework "$d")"

d=$(tree)
cat >"$d/package.json" <<'JSON'
{"dependencies": {"react": "18.3.1", "react-dom": "18.3.1"}}
JSON
assert "react on its own is React" '. == ["React"]' "$(framework "$d")"

d=$(tree)
printf 'import sys\n' >"$d/manage.py"
assert "manage.py is Django" '. == ["Django"]' "$(framework "$d")"

d=$(tree)
printf 'module example.com/m\n\ngo 1.22\n' >"$d/go.mod"
assert "go.mod is a Go module" '. == ["Go module"]' "$(framework "$d")"

d=$(tree)
printf 'a repo with nothing to go on\n' >"$d/README.md"
assert "a tree with no framework reports none" '. == []' "$(framework "$d")"

# --- profile_commands ----------------------------------------------------------

# Ten scripts match the vocabulary and three do not. Eight is the cap, and the
# eight are the first eight of the ten in file order. The three that do not
# match lead the file deliberately: further down, the cap alone would hide them
# and the filter could rot without anything noticing.
d=$(tree)
cat >"$d/package.json" <<'JSON'
{"scripts": {
  "deploy": "./deploy.sh",
  "postinstall": "patch-package",
  "release": "np",
  "dev": "next dev",
  "start": "next start",
  "build": "next build",
  "test": "vitest run",
  "test:watch": "vitest",
  "lint": "eslint .",
  "typecheck": "tsc --noEmit",
  "migrate": "prisma migrate deploy",
  "seed": "node seed.js",
  "e2e": "playwright test"
}}
JSON
out=$(profile_commands "$d")
assert "the first eight matching scripts survive, in file order" \
  '(.scripts | keys_unsorted) == ["dev","start","build","test","test:watch","lint","typecheck","migrate"]' \
  "$out"
assert "a script outside the vocabulary never lands" \
  '(.scripts | has("deploy") or has("postinstall") or has("release")) | not' "$out"
assert "a script keeps the command it runs" '.scripts.dev == "next dev"' "$out"

# Nine targets grep as targets, eight of them are in the vocabulary, six is the
# cap. `deploy` leads the file for the same reason it leads package.json: only
# the vocabulary keeps it out, so only a leading position tests the vocabulary.
# `Deploy` is not a target at all.
d=$(tree)
printf 'deploy:\n\t./deploy.sh\nDeploy:\ndev:\n\techo dev\nrun:\nstart:\nbuild:\ntest:\nlint:\ncheck:\nsetup:\n.PHONY: dev\n' >"$d/Makefile"
out=$(profile_commands "$d")
assert "six Makefile targets, in file order, prefixed with make" \
  '.scripts == {"dev":"make dev","run":"make run","start":"make start","build":"make build","test":"make test","lint":"make lint"}' \
  "$out"
assert "the seventh target is over the cap" '(.scripts | has("check")) | not' "$out"
assert "a target outside the vocabulary never lands" '(.scripts | has("deploy")) | not' "$out"

# The documented precedence, one lockfile at a time: each round asserts the top
# of the list wins, then removes it so the next one is on top.
d=$(tree)
touch "$d/pnpm-lock.yaml" "$d/yarn.lock" "$d/package-lock.json" "$d/Gemfile" \
  "$d/poetry.lock" "$d/requirements.txt"
printf 'module example.com/m\n\ngo 1.22\n' >"$d/go.mod"
printf '[package]\nname = "m"\n' >"$d/Cargo.toml"
for m in pnpm-lock.yaml:pnpm yarn.lock:yarn package-lock.json:npm Gemfile:bundler \
  poetry.lock:poetry requirements.txt:pip go.mod:go Cargo.toml:cargo; do
  assert "${m#*:} wins while ${m%%:*} is there" \
    ".package_manager == \"${m#*:}\"" "$(profile_commands "$d")"
  rm "$d/${m%%:*}"
done

d=$(tree)
printf 'v20.11.0\n' >"$d/.nvmrc"
assert ".nvmrc is the runtime, without its leading v" \
  '.runtime == "node 20.11.0"' "$(profile_commands "$d")"

d=$(tree)
cat >"$d/Procfile" <<'PROC'
web: node server.js
worker: node worker.js
release: ./bin/migrate
PROC
assert "every Procfile process is named, in file order" \
  '.procfile == ["web","worker","release"]' "$(profile_commands "$d")"

d=$(tree)
printf 'a repo with nothing to run\n' >"$d/README.md"
assert "a tree with nothing to run says so in every field" \
  '. == {scripts: {}, package_manager: "", runtime: "", procfile: []}' \
  "$(profile_commands "$d")"

if [[ $fail -eq 0 ]]; then
  echo "profile_framework/profile_commands: read what is committed, capped and in order"
else
  exit 1
fi
