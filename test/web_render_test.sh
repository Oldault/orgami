#!/usr/bin/env bash
# map/orgami.html has to open from a file:// URL on a laptop with no network,
# and it has to say what the files under ~/.orgami/<company>/ say. So: nothing
# fetched from anywhere, no fetch() in any script, the data block still parses
# as JSON after being pasted into HTML, every registered view has a payload,
# a description trying to close the script tag survives the trip, the file
# stays under budget, and two renders of the same input are the same bytes.
#
# Renders the fixture company under test/fixtures/company — no org, no token,
# no network — and once more against an empty company, where every source is
# missing and the page must still render.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is how web.sh finds lib/web and lib/stats.jq
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/web.sh
source lib/web.sh

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# The fixture is read-only: render into a copy, so a run never writes into
# the repository.
cp -r test/fixtures/company "$scratch/acme"
DIR="$scratch/acme"
# shellcheck disable=SC2034  # COMPANY and ORG are read by web_render, not by this test
COMPANY="Ac<me> & Co"
# shellcheck disable=SC2034
ORG=acme-inc

web_render 2>/dev/null
page="$DIR/map/orgami.html"

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

[[ -f $page ]] || { echo "FAIL nothing rendered" >&2; exit 1; }

# Nothing fetched. A CDN would break the page inside a private repo, on a
# plane, and in every environment that blocks outbound traffic.
remote=$(grep -ciE '(src|href)="(https?:)?//[^"]*\.(js|css|woff2?|ttf|otf)|@import|url\((https?:)?//|<link[^>]+rel="?stylesheet' "$page" || true)
check "no script, style or font is loaded from anywhere" "$remote" "0"
net=$(grep -cE 'fetch\(|XMLHttpRequest|new WebSocket|EventSource\(|navigator\.sendBeacon' "$page" || true)
check "no script reaches the network" "$net" "0"

# The data block must still be JSON after the escaping that keeps `</script>`
# from ending it early.
data=$(sed -n '/<script id="data"/,/<\/script>/p' "$page" | sed '1d;$d')
echo "$data" | jq -e . >/dev/null 2>&1 &&
  echo "ok   the data block parses as JSON" ||
  { echo "FAIL the data block is not JSON" >&2; fail=1; }

check "the payload carries company, org, map, repos and views" \
  "$(jq -r 'keys | join(",")' <<<"$data")" "company,map,org,repos,views"
check "the map's freshness is in the payload for the shell" \
  "$(jq -r '.map.generated' <<<"$data")" "2026-08-18T06:12:40Z"
check "every repo with a url is in the link table" \
  "$(jq '[.repos[] | select(.url != null)] | length' <<<"$data")" "10"
check "company name is escaped into the page" \
  "$(grep -c 'Ac&lt;me&gt; &amp; Co' "$page")" "2"

# Every view that registers itself has a payload of its own: one lib/web/NN-<id>.jq
# per lib/web/NN-<id>.js, keyed by the same id, and every one emitted an object.
views_js=$(find lib/web -maxdepth 1 -name '[0-9][0-9]-*.js' -not -name '00-shell.js' | sed -E 's|.*/[0-9]{2}-||; s|\.js$||' | LC_ALL=C sort)
views_jq=$(find lib/web -maxdepth 1 -name '[0-9][0-9]-*.jq' | sed -E 's|.*/[0-9]{2}-||; s|\.jq$||' | LC_ALL=C sort)
check "every view's .js has a .jq of the same id" "$views_js" "$views_jq"
missing_payload=0
for id in $views_js; do
  jq -e --arg id "$id" '.views[$id] | type == "object"' <<<"$data" >/dev/null 2>&1 ||
    { echo "FAIL view '$id' registered but has no object in the payload" >&2; missing_payload=1; }
  grep -q "web.register({" "lib/web/"[0-9][0-9]"-$id.js" ||
    { echo "FAIL lib/web/NN-$id.js does not call web.register({...})" >&2; missing_payload=1; }
done
[[ $missing_payload == 0 ]] && echo "ok   every registered view id is in the payload"
fail=$((fail | missing_payload))
check "the shell registers no view of its own" \
  "$(grep -cE '^\s*web\.register\(' lib/web/00-shell.js || true)" "0"
check "a view is inlined once per file, in glob order" \
  "$(grep -o 'data-file="lib/web/[^"]*\.js"' "$page" | sed 's|.*lib/web/||; s|"||' | tr '\n' ' ')" \
  "$(find lib/web -maxdepth 1 -name '*.js' | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ' ')"

# A hostile description cannot close the tag, and is still there in the data.
check "a description trying to close the script tag cannot" \
  "$(grep -c '</script><script>alert' "$page" || true)" "0"
check "and it survives in the sources the views read" \
  "$(jq -r '.company' <<<"$data")" "Ac<me> & Co"

# Budget (rule 10): under 2 MB on the fixture.
size=$(wc -c <"$page")
[[ $size -lt 2097152 ]] && echo "ok   the page is under 2 MB ($size bytes)" ||
  { echo "FAIL the page is $size bytes, over 2 MB" >&2; fail=1; }

# Determinism (rule 7): the same input files, the same bytes.
sum1=$(cksum <"$page")
web_render 2>/dev/null
sum2=$(cksum <"$page")
check "a second render is byte-identical" "$sum2" "$sum1"

# The vendors view. Every proposal advise.json ranks is in the payload, in the
# same order — the page may not drop or reorder one — and an answered proposal
# is joined to the note that answered it, so the reader can open the record.
vendors=$(jq -c '.views.vendors' <<<"$data")
check "vendors: every advise proposal id is in the payload, in advise's order" \
  "$(jq -r '[.proposals[].id] | join(" ")' <<<"$vendors")" \
  "$(jq -r '[.proposals[].id] | join(" ")' test/fixtures/company/map/advise.json)"
check "vendors: the reject command is there to copy, per proposal" \
  "$(jq -r '.proposals[0].command' <<<"$vendors")" \
  'orgami advise --reject duplicate-category:payments:paddle+stripe "<reason>"'
check "vendors: a suppressed proposal is linked to the note that answered it" \
  "$(jq -r '.answered[0] | [.id, .note.id, .author, .date, .proposed] | join(" ")' <<<"$vendors")" \
  "duplicate-category:error-tracking:rollbar+sentry 20260602-091500-dana-rollbar-is-deliberate-mobile-only dana 2026-06-02 true"
check "vendors: the allow-list is read from advise.json, not copied" \
  "$(jq -c '.substitutable' <<<"$vendors")" \
  "$(jq -c '.excluded.substitutable_categories' test/fixtures/company/map/advise.json)"
check "vendors: a category is marked substitutable by that list" \
  "$(jq -r '[.categories[] | select(.category == "payments" or .category == "hosting") | "\(.category)=\(.substitutable)"] | join(" ")' <<<"$vendors")" \
  "hosting=false payments=true"
check "vendors: code and DNS are unioned per vendor, and each cell keeps its source" \
  "$(jq -r '.vendors[] | select(.id == "stripe") | [.source, (.repos | join(",")), (.domains | join(",")), .code[0].confidence] | join(" ")' <<<"$vendors")" \
  "both api,billing-api,web acme.com extracted"
check "vendors: a vendor only DNS names has no repo and says so" \
  "$(jq -r '.vendors[] | select(.id == "docusign") | [.source, (.repos | length), .dns[0].signal, .advise.proposals[0].id] | join(" ")' <<<"$vendors")" \
  "dns 0 txt dns-only-vendor:docusign"
check "vendors: not proposed, on purpose, is advise.json's excluded section" \
  "$(jq -r '[.excluded.duplicate_category[].id, .excluded.ghost_env_var[].id] | join(" ")' <<<"$vendors")" \
  "duplicate-category:hosting:aws+vercel ghost-env-var:slack@ops-scripts"
check "vendors: the figures are computed in jq" \
  "$(jq -r '.counts | [.vendors, .categories, .repos, .from_both, .dns_only, .proposals, .high, .answered, .excluded] | join(" ")' <<<"$vendors")" \
  "13 10 9 3 2 14 4 1 2"
check "vendors: every source says how old it is, with the command that refreshes it" \
  "$(jq -r '[.sources.graph.command, .sources.dns.command, .sources.advise.command, .generated] | join(" ")' <<<"$vendors")" \
  "orgami scan orgami dns orgami advise 2026-08-18T07:00:00Z"
check "vendors: no amount anywhere in the payload" \
  "$(grep -ciE '"(cost|amount|price|spend|usd|eur)"' <<<"$vendors" || true)" "0"

# Without a DNS reading or an advise run the view still renders, and names the
# command that produces each: the matrix from the graph alone, no proposals.
rm -f "$DIR/map/dns.json" "$DIR/map/advise.json"
web_render 2>/dev/null
partial=$(sed -n '/<script id="data"/,/<\/script>/p' "$page" | sed '1d;$d' | jq -c '.views.vendors')
check "vendors: with no DNS reading and no advise run, the view says which commands produce them" \
  "$(jq -r '[.sources.dns.missing, .sources.advise.missing, .advise.missing, (.proposals | length), (.vendors | length), (.substitutable | tostring)] | join(" ")' <<<"$partial")" \
  "orgami dns orgami advise orgami advise 0 11 null"
check "vendors: an answer in the notes survives without advise.json, marked as no longer proposed" \
  "$(jq -r '.answered[0] | [.id, .proposed] | join(" ")' <<<"$partial")" \
  "duplicate-category:error-tracking:rollbar+sentry false"
cp test/fixtures/company/map/dns.json test/fixtures/company/map/advise.json "$DIR/map/"

# Every source read into the views is there, in the shape docs/web.md promises.
sources=$(mktemp)
web_sources >"$sources" 2>/dev/null
check "sources: the map files are parsed" \
  "$(jq -r '[.map.graph.generated, (.map.repos | length), (.map.live.providers | join(",")), .map.dns.counts.vendors, .map.advise.counts.proposals] | join(" ")' "$sources")" \
  "2026-08-18T06:12:40Z 10 fly,vercel 5 14"
check "sources: notes carry tags as arrays and the superseded chain" \
  "$(jq -r '[.notes[] | select(.supersedes != "")][0] | .supersedes' "$sources")" \
  "20260415-140200-sam-fly-deploys-need-the-secrets-set-first"
check "sources: the superseded note knows what replaced it" \
  "$(jq -r '[.notes[] | select(.id == "20260415-140200-sam-fly-deploys-need-the-secrets-set-first")][0].superseded_by' "$sources")" \
  "20260720-101100-sam-fly-secrets-come-from-the-deploy-workflow-now"
check "sources: an archived note is marked, and its tags parsed" \
  "$(jq -r '[.notes[] | select(.archived)][0] | .tags | join(",")' "$sources")" "rollback"
check "sources: the week's figures come from stats.jq" \
  "$(jq -r '.weeks[0] | [.week, .stats.merged, .stats.merged_by_bots, (.prs | length)] | join(" ")' "$sources")" \
  "2026-W33 2 2 4"
check "sources: pull requests are trimmed to what a page shows" \
  "$(jq -r '.weeks[0].prs[0] | has("body") or has("reviewThreads")' "$sources")" "false"
check "sources: the day's figures come from daily.jq" \
  "$(jq -r '.days[0] | [.date, .stats.merged, .stats.commits_outside_prs] | join(" ")' "$sources")" \
  "2026-08-12 2 1"
check "sources: markdown files arrive as text, by path" \
  "$(jq -r '[.decisions[].file, .playbooks[].file, .runbooks[].file, .reports[].file, .daily[].file] | join(" ")' "$sources")" \
  "map/decisions/2026-W33.md map/playbooks/warehouse-jobs--broken-export.md map/runbooks/billing-api.md reports/2026-W33.md reports/daily/2026-08-12.md"
rm -f "$sources"

# An empty company: every source missing, and the page still renders, saying
# the map has not been made yet.
mkdir -p "$scratch/empty"
DIR="$scratch/empty"
web_render 2>/dev/null
empty_data=$(sed -n '/<script id="data"/,/<\/script>/p' "$DIR/map/orgami.html" | sed '1d;$d')
check "with no files at all the page still renders" \
  "$(jq -r '.map.missing' <<<"$empty_data")" "orgami scan"
check "and a view's payload is still an object" \
  "$(jq -r '.views | type' <<<"$empty_data")" "object"

# A flag nobody asked for is orgami's error, and stdout stays the path only.
DIR="$scratch/acme"
out=$(ORGAMI_HOME="$scratch" ORGAMI_COMPANY=acme ./bin/orgami web 2>/dev/null)
check "orgami web prints the path and nothing else" "$out" "$scratch/acme/map/orgami.html"
if ORGAMI_HOME="$scratch" ORGAMI_COMPANY=acme ./bin/orgami web --nope >/dev/null 2>"$scratch/err"; then
  echo "FAIL an unknown flag was accepted" >&2; fail=1
else
  check "an unknown flag dies as orgami's error" "$(head -1 "$scratch/err")" "orgami: unknown flag: --nope"
fi

# When node is on PATH, every script the page inlines has to parse. Skipped
# silently otherwise: the page is not allowed to depend on node existing.
if command -v node >/dev/null 2>&1; then
  for f in lib/web/*.js; do
    node --check "$f" >/dev/null 2>&1 || { echo "FAIL $f does not parse (node --check)" >&2; fail=1; }
  done
  [[ $fail == 0 ]] && echo "ok   every lib/web/*.js parses (node --check)"
fi

exit "$fail"
