#!/usr/bin/env bash
# report/daily/autonote hardening, with stub claude and gh and no network:
#   - report --stats-only works with no claude on PATH
#   - an error string returned with exit 0 is not written as the recap
#   - model calls go through model_call (tools off, settings off)
#   - STATS key names the model quotes are rewritten as words or figures
#   - `latest` skips README.md and picks the newest YYYY-Www.md
#   - daily: today's stale cache is refetched, a gh failure dies with gh's message
#   - note-auto: a session with no remote and no workspace is skipped
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { echo "report_hardening: $*" >&2; exit 1; }

export ORGAMI_HOME="$fixture/home" ORGAMI_COMPANY=acme HOME="$fixture/h"
home="$ORGAMI_HOME/acme"
mkdir -p "$home/map" "$home/cache/prs" "$home/reports" "$fixture/bin" "$HOME"
echo '{"default":"acme"}' >"$ORGAMI_HOME/config.json"
jq -n '{org: "acme"}' >"$home/config.json"
jq -n '{nodes: [], edges: []}' >"$home/map/graph.json"
cat >"$home/cache/prs/2026-W34.json" <<'JSON'
{"prs":[{"repository":{"name":"api"},"number":1,"title":"t","url":"u","author":{"login":"a"},
"bodyText":"b","labels":{"nodes":[]},"additions":1,"deletions":1,"changedFiles":1,
"mergedAt":"2026-08-18T10:00:00Z","createdAt":"2026-08-17T10:00:00Z",
"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}]}
JSON

# No claude yet: --stats-only must not need it.
export PATH="$fixture/bin:$PATH"
out=$(./bin/orgami report --week 2026-W34 --stats-only 2>&1) || fail "--stats-only failed: $out"

# A week that is not cached names the weeks that are; a cache that is empty or
# not there at all (report before the first pull) dies with the pull hint
# rather than stopping silently under errexit.
out=$(./bin/orgami report --week 2020-W01 --stats-only 2>&1) && fail "an uncached week did not fail"
[[ $out == *"cached: 2026-W34 "* ]] || fail "an uncached week does not list the cached ones: $out"
other="$fixture/other"
mkdir -p "$other/acme/map" "$other/acme/cache/prs"
echo '{"default":"acme"}' >"$other/config.json"
jq -n '{org: "acme"}' >"$other/acme/config.json"
jq -n '{nodes: [], edges: []}' >"$other/acme/map/graph.json"
for state in empty stats-only missing; do
  case $state in
    stats-only) echo '{}' >"$other/acme/cache/prs/2026-W30.stats.json" ;;
    missing) rm -rf "$other/acme/cache/prs" ;;
  esac
  out=$(ORGAMI_HOME="$other" ./bin/orgami report --week 2020-W01 --stats-only 2>&1) && fail "report with the cache $state did not fail"
  [[ $out == *"orgami pull --last 1"* ]] || fail "report with the cache $state does not say to pull: '$out'"
done

cat >"$fixture/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} == --help ]]; then echo "--safe-mode --no-session-persistence"; exit 0; fi
echo "$*" >>"$CLAUDE_LOG"
cat >/dev/null
case ${CLAUDE_MODE:-ok} in
  err) echo "API Error: Connection lost" ;;
  keys) printf '%s\n' '## How the team worked' '' \
    'All of it merged without review (`merged_without_review` is 1); `review_pairs` is empty.' \
    'median_hours_to_merge stays words, `merged_by_bots` (7) keeps its own number. See api#1.' \
    '' '## Watch list' '' \
    '- Review is thin (STATS: merged without review).' \
    '- One merge nobody reviewed (STATS: `merged_without_review` is 1).' \
    '- The same figure, cited bare (per STATS), and by path: `STATS.merged_without_review`.' ;;
  *) echo "Four PRs landed. See api#1." ;;
esac
STUB
chmod +x "$fixture/bin/claude"
export CLAUDE_LOG="$fixture/claude.log"

CLAUDE_MODE=err ./bin/orgami report --week 2026-W34 >/dev/null 2>&1 && fail "an error string became the recap"
[[ ! -f $home/reports/2026-W34.md ]] || fail "a recap file was written from an error"
./bin/orgami report --week 2026-W34 >/dev/null 2>&1 || fail "report with a good model failed"
grep -q 'Four PRs' "$home/reports/2026-W34.md" || fail "recap body missing"
grep -q -- '--tools' "$CLAUDE_LOG" || fail "the model was not called through model_call"

# A STATS key the model quotes is rewritten: beside its own figure it becomes
# the figure, elsewhere words. A key beside a figure jq did not compute keeps
# that figure untouched, so the rewrite never reconciles a wrong number.
CLAUDE_MODE=keys ./bin/orgami report --week 2026-W34 >/dev/null 2>&1 || fail "report with quoted keys failed"
r="$home/reports/2026-W34.md"
grep -qE 'merged_without_review|review_pairs|median_hours_to_merge|merged_by_bots' "$r" &&
  fail "a STATS key name reached the recap: $(cat "$r")"
grep -qF 'without review (1);' "$r" || fail "a key beside its value did not collapse to the value"
grep -qF 'review pairs is empty' "$r" || fail "a quoted key did not become words"
grep -qF 'median hours to merge stays words' "$r" || fail "an unquoted key did not become words"
grep -qF 'merged by bots (7)' "$r" || fail "a key beside a figure jq did not compute was reconciled"
# Told to cite the figure an item rests on, the model names the document it
# came from: "(STATS: merged without review)" reached a real recap with the key
# rewritten and the label left. The label goes wherever it is used as one.
grep -qE 'STATS' "$r" && fail "the STATS label reached the recap: $(cat "$r")"
grep -qF -- '- Review is thin (merged without review).' "$r" || fail "a (STATS: words) citation kept its label"
grep -qF -- '- One merge nobody reviewed (1).' "$r" || fail "a (STATS: key is n) citation did not collapse to the figure"
grep -qF -- 'cited bare, and by path: merged without review.' "$r" ||
  fail "a (per STATS) aside or a STATS.key path survived"

# latest: README.md sorts after weeks and must not win.
echo "# readme" >"$home/reports/README.md"
echo "# w35" >"$home/reports/2026-W35.md"
[[ $(./bin/orgami latest --raw) == "# w35" ]] || fail "latest did not pick the newest week"
rm "$home/reports/2026-W35.md" "$home/reports/2026-W34.md"
./bin/orgami latest --raw >/dev/null 2>&1 && fail "latest returned README.md"

cat >"$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case $1 in
  search) if [[ -n ${GH_FAIL:-} ]]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi; echo '[]' ;;
  api) echo '{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}' ;;
esac
STUB
chmod +x "$fixture/bin/gh"
export GH_LOG="$fixture/gh.log"
: >"$GH_LOG"
today=$(date -u +%Y-%m-%d)
./bin/orgami daily --stats-only >/dev/null 2>&1 || fail "daily first run failed"
n1=$(grep -c '^search' "$GH_LOG")
./bin/orgami daily --stats-only >/dev/null 2>&1
[[ $(grep -c '^search' "$GH_LOG") == "$n1" ]] || fail "a fresh cache was refetched"
touch -d '3 hours ago' "$home/cache/daily/$today.json" 2>/dev/null ||
  touch -t "$(date -u -v-3H +%Y%m%d%H%M)" "$home/cache/daily/$today.json"
./bin/orgami daily --stats-only >/dev/null 2>&1
[[ $(grep -c '^search' "$GH_LOG") -gt $n1 ]] || fail "today's stale cache was not refetched"
out=$(GH_FAIL=1 ./bin/orgami daily --date 2026-01-02 --stats-only 2>&1) && fail "a gh failure was swallowed"
grep -q 'Bad credentials' <<<"$out" || fail "gh's message was lost: $out"
[[ ! -f $home/cache/daily/2026-01-02.json ]] || fail "a failed fetch left a cache"

mkdir -p "$fixture/scratch"
: >"$CLAUDE_LOG"
printf '{"cwd":"%s","message":{"role":"user","content":"hi"}}\n' "$fixture/scratch" >"$fixture/t.jsonl"
./bin/orgami note-auto "$fixture/t.jsonl" "$fixture/scratch" >/dev/null 2>&1 || true
[[ ! -s $CLAUDE_LOG ]] || fail "a session outside the organization reached the model"

echo "report_hardening: stats-only without claude, error replies refused, latest ignores README, daily refetches and reports gh failures, foreign sessions skipped"
