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

# The repos view (lib/web/30-repos.*): the table's figures and the per-repo
# page's sections are computed in jq, and the repo with the most edges carries
# every kind of edge it has in graph.json — both directions — so the page can
# draw them all.
check "repos: the view carries the map's date and the org's counts" \
  "$(jq -r '.views.repos | [.generated, .counts.repos, .counts.private, .counts.edges, .counts.deployed, .counts.notes] | join(" ")' <<<"$data")" \
  "2026-08-18T06:12:40Z 10 9 71 2 6"
busiest=$(jq -r '[.edges[] | (.from, .to)] | map(select(startswith("repo:"))) | group_by(.) | max_by(length) | .[0] | sub("^repo:"; "")' test/fixtures/company/map/graph.json)
check "repos: the busiest fixture repo is the one with the most edges in its payload" \
  "$(jq -r '.views.repos.repos | max_by(.edge_count) | .name' <<<"$data")" "$busiest"
check "repos: every edge kind that touches it, in both directions, is in its payload" \
  "$(jq -r --arg r "$busiest" '.views.repos.repos[] | select(.name == $r) | [.edges[] | .kind] | unique | join(",")' <<<"$data")" \
  "$(jq -r --arg r "repo:$busiest" '[.edges[] | select(.from == $r or .to == $r) | .kind] | unique | join(",")' test/fixtures/company/map/graph.json)"
check "repos: its edge count is the count of edges that touch it" \
  "$(jq -r --arg r "$busiest" '.views.repos.repos[] | select(.name == $r) | .edge_count' <<<"$data")" \
  "$(jq -r --arg r "repo:$busiest" '[.edges[] | select(.from == $r or .to == $r)] | length' test/fixtures/company/map/graph.json)"
unlabelled=""
for k in $(jq -r '[.edges[].kind] | unique | .[]' test/fixtures/company/map/graph.json); do
  grep -q "\"$k\":" lib/web/30-repos.js || unlabelled="$unlabelled $k"
done
check "repos: the page has a word for every edge kind the graph holds" "$unlabelled" ""
check "repos: an edge keeps its confidence, so an inferred one can be switched off" \
  "$(jq -r --arg r "$busiest" '.views.repos.repos[] | select(.name == $r) | [.edges[] | select(.kind == "calls") | .confidence] | unique | join(",")' <<<"$data")" \
  "inferred"
check "repos: an env var shared with other repos names them" \
  "$(jq -r '.views.repos.repos[] | select(.name == "api") | .env[] | select(.name == "STRIPE_WEBHOOK_URL") | .shared_with | join(",")' <<<"$data")" \
  "billing-api,web"
check "repos: a route carries the line it was read from" \
  "$(jq -r '.views.repos.repos[] | select(.name == "api") | .routes[0] | .at + " " + .route' <<<"$data")" \
  "src/orders/orders.controller.ts:12 GET /orders"
check "repos: what is deployed comes from live.json, with the reading's date beside it" \
  "$(jq -r '.views.repos | [(.repos[] | select(.name == "web") | .live[0] | .provider + " " + .state), .sources.live.generated] | join(" ")' <<<"$data")" \
  "vercel READY 2026-08-18T06:30:11Z"
check "repos: coupling is the pair's counts from coupling.json, closest first" \
  "$(jq -r '.views.repos.repos[] | select(.name == "api") | .coupling[0] | [.other, .weeks, .days, (.authors | join("+"))] | join(" ")' <<<"$data")" \
  "web 4 6 dana+sam"
check "repos: notes are newest first and know what superseded them" \
  "$(jq -r '.views.repos.repos[] | select(.name == "api") | [.note_count, .notes[0].author, .notes[0].date[0:10], (.notes[1].superseded_by != null)] | join(" ")' <<<"$data")" \
  "2 sam 2026-07-20 true"
check "repos: the runbook and the playbooks are found by the repo's name" \
  "$(jq -r '.views.repos.repos | [(.[] | select(.name == "billing-api") | .runbook != null), (.[] | select(.name == "warehouse-jobs") | .playbooks[0].topic)] | join(" ")' <<<"$data")" \
  "true broken-export"
check "repos: a section with nothing in it has nothing to draw" \
  "$(jq -r '.views.repos.repos[] | select(.name == "docs-site") | [(.env | length), (.notes | length), (.coupling | length), (.live | length), (.runbook == null)] | join(" ")' <<<"$data")" \
  "0 0 0 0 true"
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
check "repos: with no map the view names the command that makes one" \
  "$(jq -r '.views.repos.missing' <<<"$empty_data")" "orgami scan"

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
