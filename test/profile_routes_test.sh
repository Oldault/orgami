#!/usr/bin/env bash
# profile_routes must not surface routes declared in test files. Builds a
# fixture tree with one real route and several test-file routes, sources
# lib/profile.sh, and asserts only the real route lands in the endpoints list.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/profile.sh
source lib/profile.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# A route the repo actually serves.
mkdir -p "$fixture/server"
cat >"$fixture/server/app.js" <<'JS'
app.get('/health', () => {})
app.post('/users', () => {})
JS

# Routes that live in test files — these must not appear in the profile.
cat >"$fixture/server/index.test.ts" <<'TS'
app.get('/foo/:capture{ba(r|z)}', () => {})
TS
mkdir -p "$fixture/server/tests" "$fixture/server/spec" "$fixture/server/__tests__"
cat >"$fixture/server/tests/routes.test.js" <<'JS'
router.get('/bar', () => {})
JS
cat >"$fixture/server/spec/handler.spec.ts" <<'TS'
app.get('/spec-route', () => {})
TS
cat >"$fixture/server/__tests__/edge.test.js" <<'JS'
app.get('/edge', () => {})
JS

routes=$(profile_routes "$fixture")
echo "$routes" >&2

fail=0
grep -q '/health' <<<"$routes" || { echo "FAIL: /health missing" >&2; fail=1; }
grep -q '/users' <<<"$routes" || { echo "FAIL: /users missing" >&2; fail=1; }
for bad in '/foo' '/bar' '/spec-route' '/edge'; do
  if grep -q -- "$bad" <<<"$routes"; then
    echo "FAIL: test-file route $bad surfaced in profile" >&2
    fail=1
  fi
done

# Next.js file routes in the src/ layout and inside a workspace package, where
# a `(group)` directory is not part of the URL.
next=$(mktemp -d)
trap 'rm -rf "$fixture" "$next"' EXIT
mkdir -p "$next/src/app/api/alerts/[id]" "$next/src/app/(admin)/api/stats" "$next/src/pages/api" \
  "$next/apps/web/app/api/ping"
touch "$next/src/app/api/alerts/route.ts" "$next/src/app/api/alerts/[id]/route.ts" \
  "$next/src/app/(admin)/api/stats/route.js" "$next/src/app/page.tsx" "$next/src/pages/api/hello.ts" \
  "$next/apps/web/app/api/ping/route.ts"
printf '{"workspaces": ["apps/*"]}\n' >"$next/package.json"
printf '{"name": "web"}\n' >"$next/apps/web/package.json"
profile_workspace_forget
routes=$(profile_routes "$next")
echo "$routes" >&2
for want in 'src/app/api/alerts/route.ts:1 ROUTE /api/alerts' \
  'src/app/api/alerts/[id]/route.ts:1 ROUTE /api/alerts/[id]' \
  'src/app/(admin)/api/stats/route.js:1 ROUTE /api/stats' \
  'src/pages/api/hello.ts:1 ROUTE /api/hello' \
  'apps/web/app/api/ping/route.ts:1 ROUTE /api/ping'; do
  jq -e --arg w "$want" 'index($w) != null' <<<"$routes" >/dev/null ||
    { echo "FAIL: missing route: $want" >&2; fail=1; }
done
jq -e 'map(select(test("page\\.tsx"))) | length == 0' <<<"$routes" >/dev/null ||
  { echo "FAIL: a page is not a route handler" >&2; fail=1; }

# The cap is a cap: the file that declares most routes survives it, and the
# total says how many there were before it.
big=$(mktemp -d)
trap 'rm -rf "$fixture" "$next" "$big"' EXIT
mkdir -p "$big/start" "$big/app/aaa"
for i in $(seq 1 45); do echo "router.get('/r$i', h)"; done >"$big/start/routes.ts"
echo "router.get('/one', h)" >"$big/app/aaa/limiter.ts"
# A route quoted in a comment is documentation, not an endpoint.
printf '%s\n' "// router.get('/commented', h)" '/**' " * router.post('/login', throttle)" ' */' \
  "  # app.get('/hashed', h)" "router.get('/after-comment', h)" >"$big/app/aaa/doc.ts"
all=$(profile_routes_all "$big")
[[ $(grep -c . <<<"$all") == 47 ]] || { echo "FAIL: profile_routes_all should see 47 routes, got: $all" >&2; fail=1; }
grep -qE '/commented|/login|/hashed' <<<"$all" && { echo "FAIL: a route in a comment became an endpoint" >&2; fail=1; }
grep -q 'app/aaa/doc.ts:6: GET /after-comment' <<<"$all" || { echo "FAIL: the live route after the comments was lost" >&2; fail=1; }

# A checkout whose own directory is named like a pruned one (build, out,
# examples) is still read: the prune and grep's --exclude-dir apply below it.
holder=$(mktemp -d)
trap 'rm -rf "$fixture" "$next" "$big" "$holder"' EXIT
named="$holder/build"
mkdir -p "$named/src"
echo "router.get('/in-build', h)" >"$named/src/server.ts"
echo 'API_KEY=' >"$named/.env.example"
grep -q '/in-build' <<<"$(profile_routes_all "$named")" ||
  { echo "FAIL: a checkout named build gave no routes" >&2; fail=1; }
[[ -n $(profile_env_files_walk "$named") ]] ||
  { echo "FAIL: a checkout named build gave no env files" >&2; fail=1; }
routes=$(profile_routes "$big")
[[ $(jq length <<<"$routes") == "$PROFILE_ROUTES_MAX" ]] ||
  { echo "FAIL: profile_routes should keep $PROFILE_ROUTES_MAX" >&2; fail=1; }
jq -e 'map(select(startswith("app/aaa/"))) | length == 0' <<<"$routes" >/dev/null ||
  { echo "FAIL: a one-route file outranked the routes file in the cut" >&2; fail=1; }
jq -e '.[0] | startswith("start/routes.ts:1:")' <<<"$routes" >/dev/null ||
  { echo "FAIL: the kept routes are not back in line order" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "profile_routes: test paths excluded, real routes kept"
else
  exit 1
fi