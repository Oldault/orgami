#!/usr/bin/env bash
# What the scan does to the graph as a whole, once every repo has been read:
#
#   - a variable name half the organization declares is a convention, not a
#     link, so it makes no shares-config edge, and neither does a name every
#     scaffold writes (DATABASE_URL, DB_HOST) — six of them used to make a
#     fifteen-edge clique, because the frequency cap read a null
#   - one edge per (from, to, kind): five S3_* names are one dependency on S3,
#     two hosts of one repo are one calls edge
#   - a rescan of the same commits writes the same graph, the same evidence
#     line included
#   - the edges `orgami coupling` and `orgami depth` own survive a manual scan,
#     rebuilt from coupling.json and depth.json
#
# scan_infer_links is run on hand-written profiles; the rest goes through a full
# scan with a stub `gh` that clones from local repositories in a temp
# directory. No network, no token, nothing pushed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

# --- inferred links, on hand-written profiles ---------------------------------

(
  # shellcheck source=../lib/common.sh
  source lib/common.sh
  # shellcheck source=../lib/scan.sh
  source lib/scan.sh

  # Eight repos. ACME_AUTH_URL is distinctive but six of them declare it;
  # DATABASE_URL is in six and DB_HOST in three, the names a framework writes;
  # BILLING_QUEUE_URL is in two, the one name worth an edge. web calls two hosts
  # billing serves, which is one calls edge.
  jq -n '[range(1; 9) | "r\(.)"] as $n
    | {nodes: [$n[] | {id: ("repo:" + .), kind: "repo", name: ., meta: {}}],
       edges: [{from: "repo:r8", to: "host:pay.acme.dev", kind: "deploys-to",
                evidence: "fly.toml", confidence: "extracted"}]}' >"$tmp/g.json"
  jq -n '[range(1; 9) | "r\(.)"]
    | map({name: ., serves: [], calls: [], env: (
        (if . <= "r6" then ["ACME_AUTH_URL", "DATABASE_URL"] else [] end)
        + (if . <= "r3" then ["DB_HOST", "DB_HOST"] else [] end)
        + (if . == "r1" or . == "r2" then ["BILLING_QUEUE_URL"] else [] end))})
    | map(if .name == "r8" then .serves = ["api.pay.acme.dev"] else . end)
    | map(if .name == "r7" then .calls = ["pay.acme.dev", "api.pay.acme.dev", "pay.acme.dev"] else . end)' \
    >"$tmp/p.json"

  scan_infer_links "$tmp/g.json" "$tmp/p.json"
  g="$tmp/g.json"

  check "a name six repos declare makes no shares-config edge" \
    "$(jq '[.edges[] | select(.kind == "shares-config" and (.evidence | test("ACME_AUTH_URL")))] | length' "$g")" "0"
  check "nor does a scaffold's DATABASE_URL or DB_HOST" \
    "$(jq '[.edges[] | select(.kind == "shares-config" and (.evidence | test("DATABASE_URL|DB_HOST")))] | length' "$g")" "0"
  check "so the only shares-config edge is the distinctive name two repos share" \
    "$(jq -c '[.edges[] | select(.kind == "shares-config") | [.from, .to, .evidence, .confidence]]' "$g")" \
    '[["repo:r1","repo:r2","BILLING_QUEUE_URL","inferred"]]'
  check "two hosts of one repo are one calls edge, naming both" \
    "$(jq -c '[.edges[] | select(.kind == "calls") | [.from, .to, .evidence]]' "$g")" \
    '[["repo:r7","repo:r8","https://api.pay.acme.dev, https://pay.acme.dev"]]'
)

# --- a full scan --------------------------------------------------------------

home="$tmp/home" stub="$tmp/stub" bin="$tmp/bin" scratch="$tmp/t"
mkdir -p "$home/acme/map" "$stub/src" "$bin" "$scratch"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"

repo() {
  local d="$stub/src/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  shift
  while (($#)); do
    mkdir -p "$(dirname "$d/$1")"
    printf '%s\n' "$2" >"$d/$1"
    shift 2
  done
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -qm init
}
# alpha mentions beta in four files. Byte order puts Notes.md first, whatever
# order the file system lists them in, so that is the line cited every time.
repo alpha \
  notes/a.md 'see github.com/acme/beta' \
  notes/b.md 'also github.com/acme/beta' \
  Notes.md $'intro\nsee github.com/acme/beta' \
  zz.md 'github.com/acme/beta again' \
  .env.example $'S3_BUCKET=\nS3_REGION=\nS3_ENDPOINT=' \
  .github/workflows/ci.yml $'jobs:\n  x:\n    steps:\n      - uses: aws-actions/configure-aws-credentials@v4\n      - uses: aws-actions/amazon-ecr-login@v2'
repo beta README.md 'beta'
repo gamma README.md 'gamma'

jq -n '[("alpha", "beta", "gamma") | {name: ., description: null, language: "Go",
  archived: false, private: false, fork: false, pushed_at: "2026-01-01T00:00:00Z",
  default_branch: "main", topics: [], html_url: ("https://github.com/acme/" + .),
  size: 1, open_issues_count: 0}]' >"$stub/repos.json"

cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2-}" in
  "api orgs/"*)
    while [[ $# -gt 0 && $1 != --jq ]]; do shift; done
    jq -c "$2" "$STUB/repos.json"
    ;;
  "api users/"*) echo Organization ;;
  "repo clone") git clone -q "$STUB/src/${3#*/}" "$4" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$bin/gh"

# What `orgami coupling` and `orgami depth` left behind: a stable pair two
# people made, and an import of beta that carries the organization.
cat >"$home/acme/map/coupling.json" <<'JSON'
{"generated": "2026-01-01T00:00:00Z", "weeks_observed": 3,
 "pairs": [{"a": "alpha", "b": "gamma", "weeks": 3, "days": 2, "authors": ["dev-one", "dev-two"]},
           {"a": "beta", "b": "gamma", "weeks": 3, "days": 2, "authors": ["dev-one"]}]}
JSON
cat >"$home/acme/map/depth.json" <<'JSON'
{"repos": [{"name": "gamma", "imports": [{"module": "github.com/acme/beta/pkg", "file": "main.go", "line": 3}]}]}
JSON

scan() {
  PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ORGAMI_AUTOUPDATE=0 \
    XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" TMPDIR="$scratch" \
    "$root/bin/orgami" scan --jobs 2 "$@" >"$tmp/out" 2>"$tmp/err"
}
g="$home/acme/map/graph.json"
edges() { jq -c --arg k "$1" '[.edges[] | select(.kind == $k) | [.from, .to, .evidence]]' "$g"; }

scan || { echo "FAIL full scan:" >&2; cat "$tmp/err" >&2; exit 1; }

check "a reference cites the first file in byte order, at its line" \
  "$(edges references)" '[["repo:alpha","repo:beta","Notes.md:2"]]'
check "five S3 names are one dependency, cited at the first" \
  "$(jq -c '[.edges[] | select(.from == "repo:alpha" and .to == "service:s3") | .evidence]' "$g")" \
  '[".env.example:1"]'
check "two aws-actions are one uses edge" \
  "$(jq '[.edges[] | select(.from == "repo:alpha" and .to == "tool:aws")] | length' "$g")" "1"
check "no (from, to, kind) appears twice" \
  "$(jq '[.edges[] | [.from, .to, .kind]] | length == (unique | length)' "$g")" "true"
check "a manual scan keeps the changes-with edge coupling.json supports" \
  "$(edges changes-with)" '[["repo:alpha","repo:gamma","3 weeks / 2 days, dev-one, dev-two"]]'
check "and the imports edge depth.json supports" \
  "$(jq -c '[.edges[] | select(.kind == "imports") | [.from, .to, .confidence]]' "$g")" \
  '[["repo:gamma","repo:beta","extracted"]]'

# The same commits again: the same graph, apart from when it was made.
jq -S 'del(.generated)' "$g" >"$tmp/first.json"
scan || { echo "FAIL rescan:" >&2; cat "$tmp/err" >&2; exit 1; }
jq -S 'del(.generated)' "$g" >"$tmp/second.json"
if cmp -s "$tmp/first.json" "$tmp/second.json"; then
  echo "ok   a rescan of the same commits writes the same graph"
else
  echo "FAIL a rescan of the same commits changed the graph:" >&2
  diff "$tmp/first.json" "$tmp/second.json" >&2 || true
  fail=1
fi

# --only merges the rest from the last map; the owned edges are rebuilt, not
# carried and doubled.
scan --only beta || { echo "FAIL --only beta:" >&2; cat "$tmp/err" >&2; exit 1; }
check "--only keeps the changes-with edge, once" \
  "$(jq '[.edges[] | select(.kind == "changes-with")] | length' "$g")" "1"
check "--only keeps the imports edge, once" \
  "$(jq '[.edges[] | select(.kind == "imports")] | length' "$g")" "1"

# --- a manifest names a repo only where the name stands whole ------------------
# honox-website's package.json names its package honox.dev, gives its own GitHub
# URL, has a honox command, and pulls in an @honox scope before it depends on
# honox on line 9. Each earlier line holds "honox" against a dot, a hyphen or a
# slash, or outside a dependency block; none of them is a reference, and the
# honox edge cites the dependency line. A URL that does
# name the repo, .git and all, still counts.
(
  # shellcheck source=../lib/common.sh
  source lib/common.sh
  # shellcheck source=../lib/scan.sh
  source lib/scan.sh
  ORG=acme EMIT="$tmp/links.jsonl" REPOLIST="$tmp/links.list"
  : >"$EMIT"
  printf '%s\n' honox honox-website website >"$REPOLIST"
  mkdir -p "$tmp/hw"
  printf '{\n  "name": "honox.dev",\n  "repository": "git@github.com:acme/honox-website.git",\n  "bin": {\n    "honox": "dist/cli.js"\n  },\n  "dependencies": {\n    "@honox/vite": "^1.0.0",\n    "honox": "^0.1.34"\n  }\n}\n' \
    >"$tmp/hw/package.json"
  scan_links honox-website "$tmp/hw"
  check "manifest: the dependency is the evidence, not the repo's own URL" \
    "$(jq -r 'select(.to == "repo:honox") | .evidence' "$EMIT")" "package.json:9"
  check "manifest: a name inside a longer hyphenated name is no reference" \
    "$(jq -r 'select(.to == "repo:website") | .evidence' "$EMIT")" ""
  : >"$EMIT"
  mkdir -p "$tmp/ci"
  printf 'uses: actions/checkout@v4\nrun: git clone https://github.com/acme/honox.git\n' >"$tmp/ci/deploy.yml"
  : >"$EMIT"
  mkdir -p "$tmp/sc"
  printf '{\n  "devDependencies": {\n    "@hono/honox-website": "1.0.0"\n  }\n}\n' >"$tmp/sc/package.json"
  scan_links sc "$tmp/sc"
  check "manifest: a dependency under an npm scope names the repo" \
    "$(jq -r 'select(.to == "repo:honox-website") | .evidence' "$EMIT")" "package.json:3"
  : >"$EMIT"
  scan_links ci "$tmp/ci"
  check "url: org/honox.git is a reference to honox" \
    "$(jq -r 'select(.to == "repo:honox") | .evidence' "$EMIT")" "deploy.yml:2"
  : >"$EMIT"
  mkdir -p "$tmp/rd"
  printf 'Forked from github.com/acme/honox-website.\nThe islands live in github.com/acme/honox.\n' >"$tmp/rd/README.md"
  scan_links rd "$tmp/rd"
  check "url: a sentence's full stop ends the name, a hyphen does not" \
    "$(jq -r 'select(.to == "repo:honox") | .evidence' "$EMIT")" "README.md:2"
) || fail=1

check "the scan left nothing in its temp dir" "$(find "$scratch" -mindepth 1 | wc -l | tr -d ' ')" "0"

exit "$fail"
