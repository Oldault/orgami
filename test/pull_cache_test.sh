#!/usr/bin/env bash
# `orgami pull` writes the week's cache file only when it has the whole week:
#
#   - a good search writes cache/prs/<week>.json with every page in it
#   - a search gh fails on exits non-zero and leaves the last cache file alone,
#     instead of writing a week with no pull requests in it
#   - a personal account, whose `org:` search is empty, gets a sentence saying
#     orgami maps organizations
#
# A stub `gh` earlier on PATH answers the GraphQL search. No network, no token.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home" stub="$tmp/stub" bin="$tmp/bin"
mkdir -p "$home/acme" "$stub" "$bin"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"

fail=0
check() { [[ $2 == "$3" ]] || { echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1; }; }

# Two pages: the first says there is a second, the second carries the cursor.
jq -n '{data: {search: {issueCount: 2, pageInfo: {hasNextPage: true, endCursor: "c1"},
  nodes: [{number: 1, title: "one", repository: {name: "api"}}]}}}' >"$stub/page1.json"
jq -n '{data: {search: {issueCount: 2, pageInfo: {hasNextPage: false, endCursor: null},
  nodes: [{number: 2, title: "two", repository: {name: "api"}}, {}]}}}' >"$stub/page2.json"
jq -n '{data: {search: {issueCount: 0, pageInfo: {hasNextPage: false, endCursor: null},
  nodes: []}}}' >"$stub/empty.json"

cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2-}" in
  "api graphql")
    [[ -f $STUB/broken ]] && { echo 'gh: Something went wrong' >&2; exit 1; }
    [[ -f $STUB/personal ]] && { cat "$STUB/empty.json"; exit 0; }
    if [[ " $* " == *" after=c1 "* ]]; then cat "$STUB/page2.json"; else cat "$STUB/page1.json"; fi
    ;;
  "api users/"*)
    if [[ -f $STUB/personal ]]; then echo User; else echo Organization; fi
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$bin/gh"

pull() {
  PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme \
    "$root/bin/orgami" pull --since 2026-03-02 --until 2026-03-08 >"$tmp/out" 2>"$tmp/err"
}
cache="$home/acme/cache/prs/2026-W10.json"

pull || { echo "FAIL pull:" >&2; cat "$tmp/err" >&2; exit 1; }
check "every page is cached" "$(jq -c '[.prs[].number]' "$cache")" '[1,2]'
check "the count is GitHub's" "$(jq '.issue_count' "$cache")" 2

cp "$cache" "$tmp/before.json"
touch "$stub/broken"
if pull; then echo "FAIL a failed search exited 0" >&2; fail=1; fi
grep -q 'GitHub search failed' "$tmp/err" || { echo "FAIL failed search message: $(cat "$tmp/err")" >&2; fail=1; }
cmp -s "$cache" "$tmp/before.json" || { echo "FAIL a failed search replaced the cache" >&2; fail=1; }
rm -f "$stub/broken"

touch "$stub/personal"
if pull; then echo "FAIL a personal account exited 0" >&2; fail=1; fi
grep -q 'is a personal account' "$tmp/err" || { echo "FAIL personal account message: $(cat "$tmp/err")" >&2; fail=1; }
cmp -s "$cache" "$tmp/before.json" || { echo "FAIL a personal account replaced the cache" >&2; fail=1; }

check "no half-written file beside the cache" \
  "$(find "$home/acme/cache/prs" -name '2026-W10.json.*' | wc -l | tr -d ' ')" 0

# --last N is this week and the N before it; --weeks-ago N is the one week.
rm -f "$stub/personal"
rm -rf "$home/acme/cache/prs"
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme \
  "$root/bin/orgami" pull --last 3 >"$tmp/out" 2>"$tmp/err" || { echo "FAIL pull --last 3:" >&2; cat "$tmp/err" >&2; exit 1; }
check "--last 3 caches four weeks" "$(find "$home/acme/cache/prs" -name '*-W*.json' | wc -l | tr -d ' ')" 4
rm -rf "$home/acme/cache/prs"
PATH="$bin:$PATH" STUB="$stub" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme \
  "$root/bin/orgami" pull --weeks-ago 3 >"$tmp/out" 2>"$tmp/err" || { echo "FAIL pull --weeks-ago:" >&2; exit 1; }
check "--weeks-ago 3 caches one week" "$(find "$home/acme/cache/prs" -name '*-W*.json' | wc -l | tr -d ' ')" 1

# A report for an uncached week names the weeks that are cached.
only=$(basename "$(find "$home/acme/cache/prs" -name '*-W*.json')" .json)
if PATH="$bin:$PATH" ORGAMI_HOME="$home" ORGAMI_COMPANY=acme "$root/bin/orgami" report --stats-only --week 2000-W01 >"$tmp/out" 2>"$tmp/err"; then
  echo "FAIL report on an uncached week exited 0" >&2; fail=1
fi
grep -q "cached: $only" "$tmp/err" || { echo "FAIL report hint: $(cat "$tmp/err")" >&2; fail=1; }

exit $fail
