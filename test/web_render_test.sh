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

# --- the activity view -------------------------------------------------------
# Every figure it shows is one stats.jq, daily.jq or coupling.sh computed, so
# the week the page draws has to carry the merged count script/check already
# asserts for stats.jq on the same fixture week — read from that assertion,
# not copied here, so the two cannot drift apart.
want=$(sed -n '/^stats() {/,/^}/p' script/check | grep -oE '"merged=[0-9]+"' | head -1 | tr -dc '0-9')
[[ -n $want ]] || { echo "FAIL script/check no longer asserts merged=N for stats.jq" >&2; fail=1; }
activity=$(jq -c '.views.activity' <<<"$data")
check "activity: the fixture week is listed, newest first" \
  "$(jq -r '.list[0].week' <<<"$activity")" "2026-W33"
check "activity: the week's merged count is the one script/check asserts for stats.jq" \
  "$(jq -r '.list[0].stats.merged' <<<"$activity")" "$want"
check "activity: the week carries its recap and its pull requests, bots marked" \
  "$(jq -r '.list[0] | [(.recap | startswith("# acme — week 2026-W33")), (.prs | length), ([.prs[] | select(.bot)] | length)] | join(" ")' <<<"$activity")" \
  "true 4 2"
check "activity: the small multiples start with merged and never draw merged_by_people twice" \
  "$(jq -r '[.figures[0].key, ([.figures[].key] | index("merged_by_people") == null), (.figures[] | select(.key == "lines_added") | .max)] | join(" ")' <<<"$activity")" \
  "merged true 704"
check "activity: the day carries daily.jq's figures and its digest" \
  "$(jq -r '.days.list[0] | [.date, .stats.merged, .stats.commits_outside_prs, (.digest | contains("Outside a pull request"))] | join(" ")' <<<"$activity")" \
  "2026-08-12 2 1 true"
check "activity: coupling is the matrix's axis, sorted, with the largest pair for shading" \
  "$(jq -r '.coupling | [(.repos | join(",")), .max.weeks, .max.days, .weeks_observed] | join(" ")' <<<"$activity")" \
  "api,billing-api,infra,ops-scripts,warehouse-jobs,web 4 6 6"
check "activity: each source says how old it is and what refreshes it" \
  "$(jq -r '[.weeks.generated, .weeks.command, .days.generated, .days.command, .coupling.command] | join(" ")' <<<"$activity")" \
  "2026-08-16 orgami pull 2026-08-12 orgami daily orgami coupling"
# A quiet day — nothing merged, opened or pushed outside a pull request — is
# absent, the same rule lib/daily.sh writes no digest by; and a week stats.jq
# could not read is still listed, with no figures.
check "activity: a quiet day is absent and an unreadable week is still listed" \
  "$(jq -c '.days += [{file: "cache/daily/2026-08-13.json", date: "2026-08-13", stats: {merged: 0, opened: 0, commits_outside_prs: 0}}]
            | .weeks += [{file: "cache/prs/2026-W34.json", week: "2026-W34", stats: null, prs: []}]' "$sources" \
      | jq -L lib -r -f lib/web/60-activity.jq | jq -r '[([.days.list[].date] | join(",")), ([.list[] | .week + ":" + (.stats != null | tostring)] | join(","))] | join(" ")')" \
  "2026-08-12 2026-W34:false,2026-W33:true"
check "activity: with only a coupling reading the weeks and days say which command produces them" \
  "$(jq -c '{map: {coupling: .map.coupling}}' "$sources" | jq -L lib -r -f lib/web/60-activity.jq | jq -r '[.weeks.missing, .days.missing, (.coupling.pairs | length)] | join(" ")')" \
  "orgami pull orgami daily 4"
check "activity: the view draws with no clock and no random (rule 7)" \
  "$(grep -cE 'Date\.now|Math\.random|new Date\(\)' lib/web/60-activity.js || true)" "0"
rm -f "$sources"

# The live view (lib/web/50-live.*): deployed vs configured, and the DNS
# reading. The two diffs carry evidence, and the figures are jq's.
live=$(jq -c '.views.live' <<<"$data")
check "live: the payload carries both readings with their own freshness" \
  "$(jq -r '[.generated, .live.generated, .live.command, .dns.generated, .dns.command] | join(" ")' <<<"$live")" \
  "2026-08-18T06:30:11Z 2026-08-18T06:30:11Z orgami live 2026-08-18T06:20:00Z orgami dns"
check "live: deployments are grouped by the providers read" \
  "$(jq -r '[.live.providers[] | .provider + "=" + (.deployments | length | tostring)] | join(",")' <<<"$live")" \
  "fly=1,vercel=1"
check "live: a deployment carries the provider's reading and the deploys-to edge that names its host" \
  "$(jq -r '[.live.providers[].deployments[] | .repo + ":" + .reading.command + ":" + .declared.at] | join(" ")' <<<"$live")" \
  "api:fly:app/acme-api:fly.toml web:vercel:project/prj_web:vercel.json:3"
check "live: the configured-not-seen diff is non-empty" \
  "$(jq -r '.live.not_seen | length' <<<"$live")" "3"
check "live: every configured-not-seen row carries its deploys-to evidence" \
  "$(jq -r '[.live.not_seen[] | .repo + "@" + .host + "=" + .evidence.kind + ":" + .evidence.at] | join(" ")' <<<"$live")" \
  "billing-api@billing.acme.com=extracted:config/deploy.yml:12 docs-site@docs.acme.com=extracted:public/CNAME:1 ml-worker@ml.acme.com=extracted:kubernetes ingress"
check "live: a not-seen row says which provider it is configured for and whether that provider was read" \
  "$(jq -r '[.live.not_seen[] | .provider + "/" + (.provider_read | tostring)] | join(" ")' <<<"$live")" \
  "kamal/false github-pages/false kubernetes/false"
check "live: repos the providers saw are not in the diff" \
  "$(jq -r '[.live.configured[] | select(.seen) | .repo] | join(" ")' <<<"$live")" "api web"
check "live: the seen-not-configured diff is the unmatched list, with its source" \
  "$(jq -r '[.live.not_configured[] | .provider + ":" + .name + "=" + .source] | join(" ")' <<<"$live")" \
  "fly:acme-api-staging=fly:app/acme-api-staging fly:some-old-thing=fly:app/some-old-thing vercel:landing-2024=vercel:project/prj_landing"
check "live: the figures are computed in jq" \
  "$(jq -r '.live.counts | [.providers, .read, .deployments, .repos, .configured, .not_seen, .not_configured, .errors] | join(" ")' <<<"$live")" \
  "2 2 2 2 5 3 3 1"
check "live: a provider error is kept for the page" \
  "$(jq -r '.live.errors[0] | .provider + ": " + .message' <<<"$live")" "aws: aws is not on PATH"
check "live: DNS records are grouped by kind, in the order dns.md lists them" \
  "$(jq -r '[.dns.by_kind[] | .kind + "=" + (.records | length | tostring)] | join(",")' <<<"$live")" \
  "txt=3,mx=2,spf=1,cname=1"
check "live: one SPF record names every vendor it matched, once" \
  "$(jq -r '[.dns.by_kind[] | select(.kind == "spf") | .records[0].vendors[].id] | join(",")' <<<"$live")" \
  "google-workspace,sendgrid"
check "live: a DNS row carries the dig date the evidence line names" \
  "$(jq -r '[.dns.by_kind[].records[].dig] | unique | join(",")' <<<"$live")" "2026-08-18"
check "live: the DNS figures are the reading's own" \
  "$(jq -r '.dns.counts | [.domains, .queries, .records, .records_matched, .records_unmatched, .omitted] | join(" ")' <<<"$live")" \
  "1 14 19 7 12 1"
check "live: the stale thresholds are the ones live.sh and dns.sh use" \
  "$(jq -r '[.live.stale_after_days, .dns.stale_after_days] | join(" ")' <<<"$live")" "7 90"

# One reading missing, the other present: the view keeps them apart (rule 4).
mkdir -p "$scratch/nolive"
cp -r test/fixtures/company/. "$scratch/nolive/"
rm -f "$scratch/nolive/map/live.json"
DIR="$scratch/nolive"
web_render 2>/dev/null
nolive=$(sed -n '/<script id="data"/,/<\/script>/p' "$DIR/map/orgami.html" | sed '1d;$d' | jq -c '.views.live')
check "live: without live.json the live half names its command and the DNS half still draws" \
  "$(jq -r '[.live.missing, (.dns.by_kind | length | tostring), .generated] | join(" ")' <<<"$nolive")" \
  "orgami live 4 2026-08-18T06:20:00Z"
rm -f "$scratch/nolive/map/dns.json"
web_render 2>/dev/null
check "live: with neither reading the view is the freshness panel only" \
  "$(sed -n '/<script id="data"/,/<\/script>/p' "$DIR/map/orgami.html" | sed '1d;$d' | jq -r '.views.live | [.missing, (.generated | tostring)] | join(" ")')" \
  "orgami live, orgami dns null"

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
check "activity: with no cache at all the view names the command that fills it" \
  "$(jq -r '.views.activity.missing' <<<"$empty_data")" "orgami pull"

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
