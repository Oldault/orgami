# The live view's payload: what the providers said is running (map/live.json),
# what the DNS said the org has an account with (map/dns.json), and the two
# diffs against what the committed files declare (graph.json deploys-to edges).
#
# Both sources are readings, not the map: each carries its own `generated`,
# and the view keeps them apart so one can be missing while the other draws.
# Only when neither exists does the whole view stop at the freshness panel.
#
# Every figure here is computed in jq (rule 3); the page only counts the rows
# it is currently filtering.

# --- which provider a deploys-to edge is configured for -------------------------
#
# The edge names a host, not a provider. lib/live.sh attributes a running app
# to a repo through the same edge, so the provider is read back the way the
# scan wrote it: from the host the provider hands out, or from the file the
# edge cites. A repo that names the tool (`uses` -> tool:fly) settles what the
# file alone cannot. Anything else is null: "configured somewhere the
# providers were not asked about" is a fact worth keeping, not a guess.
def provider_of($host; $ev):
    if   ($host | test("\\.fly\\.dev$")) or ($ev | test("(^|/)fly\\.toml")) then "fly"
    elif ($host | test("\\.vercel\\.app$")) or ($ev | test("(^|/)vercel\\.json")) then "vercel"
    elif ($host | test("\\.(amazonaws\\.com|elasticbeanstalk\\.com|cloudfront\\.net|awsapprunner\\.com)$"))
         or ($ev | test("serverless\\.ya?ml|samconfig\\.toml|cdk\\.json")) then "aws"
    elif ($host | test("\\.(workers|pages)\\.dev$")) or ($ev | test("wrangler\\.(toml|jsonc?)")) then "cloudflare"
    elif ($host | test("\\.netlify\\.app$")) or ($ev | test("netlify\\.toml")) then "netlify"
    elif ($host | test("\\.herokuapp\\.com$")) or ($ev | test("(^|/)Procfile")) then "heroku"
    elif ($host | test("\\.github\\.io$")) or ($ev | test("(^|/)CNAME(:|$)")) then "github-pages"
    elif ($host | test("\\.onrender\\.com$")) or ($ev | test("render\\.ya?ml")) then "render"
    elif ($host | test("\\.railway\\.app$")) or ($ev | test("railway\\.(toml|json)")) then "railway"
    elif ($ev | test("(^|/)(\\.kamal/)?deploy\\.ya?ml")) then "kamal"
    elif ($ev | test("kubernetes|k8s|helm|Chart\\.yaml")) then "kubernetes"
    else null end;

def tool_provider($tools; $repo):
    ($tools[$repo] // []) as $t
    | ["fly", "vercel", "aws", "cloudflare", "netlify", "heroku", "kamal", "kubernetes", "render", "railway"]
      | map(select(. as $p | $t | index($p))) | first // null;

.map.live as $live
| .map.dns as $dns
| .map.graph as $graph

| ($graph.edges // []) as $edges
| ($graph.nodes // []) as $nodes
| ($live.providers // []) as $read

# The tools each repo names, for the fallback above.
| ([$edges[] | select(.kind == "uses" and (.to | startswith("tool:")))
    | {key: (.from | sub("^repo:"; "")), value: (.to | sub("^tool:"; ""))}]
   | group_by(.key) | map({key: .[0].key, value: map(.value)}) | from_entries) as $tools

| ($live.deployments // []) as $deployments

# --- configured: every deploys-to edge, and whether a provider saw it ---------
| ([$edges[] | select(.kind == "deploys-to")
    | (.from | sub("^repo:"; "")) as $repo
    | (.to | sub("^host:"; "")) as $host
    | (.evidence // "") as $ev
    | (provider_of($host; $ev) // tool_provider($tools; $repo)) as $provider
    | {repo: $repo, host: $host, provider: $provider,
       provider_read: ($provider != null and ($read | index($provider)) != null),
       evidence: {kind: (.confidence // "extracted"), at: $ev, repo: $repo},
       seen: ([$deployments[] | select(.repo == $repo)
               | select((.provider == $provider) or ((.urls // []) | index($host) != null))]
              | length > 0)}]
   | sort_by(.repo, .host)) as $configured

# --- the reading, per provider ---------------------------------------------------
| ($live.errors // []) as $errors
| ([$read[] | . as $p
    | {provider: $p,
       error: ([$errors[] | select(.provider == $p) | .message] | first // null),
       deployments: [$deployments[] | select(.provider == $p) | . as $d
         # The deploys-to edge that names one of this app's hosts, when the
         # committed files have one: a line somebody can open beside the
         # provider's word. A `map` match was made through exactly that edge.
         | ([$configured[] | . as $c | select($c.repo == $d.repo and
              (($d.urls // []) | index($c.host)) != null)] | first | .evidence // null) as $declared
         | {repo, name, state, urls: (.urls // []), account, updated, source, match,
            region: (.region // null),
            reading: {kind: "reading", command: ($d.source // ("live:" + $p)),
                      text: ("matched by " + ($d.match // "name"))},
            declared: $declared}]}])
  as $providers

# --- the two diffs ------------------------------------------------------------------
| ([$configured[] | select(.seen | not)]) as $not_seen
| ([($live.unmatched // [])[] | {provider, name, state, urls: (.urls // []), source}]
   | sort_by(.provider, .name)) as $not_configured

# --- DNS: records by kind, each with the vendor it matched -------------------------
#
# dns.json keeps only the records that matched the catalogue, under the vendor
# they matched. Here they are turned back around: one row per record, with
# every vendor that record spoke for (one SPF line names several), so the page
# can show the reading by record kind. The dig date is the one the evidence
# line carries, so a row can be checked with the same query.
| ([($dns.vendors // [])[] as $v | ($v.evidence // [])[]
    | {signal, domain, at, vendor: {id: $v.id, name: $v.name, category: $v.category}}]
   | group_by(.signal + " " + .domain + " " + .at)
   | map({signal: .[0].signal, domain: .[0].domain, at: .[0].at,
          dig: ((.[0].at | capture("\\(dig (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})\\)")?.d) // null),
          vendors: (map(.vendor) | unique_by(.id))})) as $records
| (["txt", "mx", "spf", "dmarc", "cname", "ns"]) as $kind_order
| ([$kind_order[] as $k
    | {kind: $k,
       label: ({txt: "verification TXT", mx: "MX", spf: "SPF includes", dmarc: "DMARC",
                cname: "CNAME", ns: "NS"})[$k],
       records: [$records[] | select(.signal == $k)] | sort_by(.domain, .at)}
    | select(.records | length > 0)]
   # A kind the catalogue knows but the reading does not: listed after the
   # known six so nothing read is dropped on the floor.
   + [$records | map(.signal) | unique[] | select(. as $s | $kind_order | index($s) | not) as $k
      | {kind: $k, label: $k, records: [$records[] | select(.signal == $k)] | sort_by(.domain, .at)}])
  as $by_kind

| {
    generated: ([$live.generated, $dns.generated] | map(select(. != null)) | max),
    live: (if $live == null then {generated: null, missing: "orgami live"}
           else {generated: ($live.generated // null), command: "orgami live",
                 stale_after_days: 7,
                 providers: $providers,
                 counts: {providers: ($read | length),
                          read: ([$providers[] | select(.error == null)] | length),
                          deployments: ($deployments | length),
                          repos: ([$deployments[].repo] | unique | length),
                          configured: ($configured | length),
                          not_seen: ($not_seen | length),
                          not_configured: ($not_configured | length),
                          errors: ($errors | length)},
                 configured: $configured,
                 not_seen: $not_seen,
                 not_configured: $not_configured,
                 errors: $errors} end),
    dns: (if $dns == null then {generated: null, missing: "orgami dns"}
          else {generated: ($dns.generated // null), command: "orgami dns",
                stale_after_days: 90,
                origin: ($dns.origin // null),
                domains: ($dns.domains // []),
                read: ($dns.read // []),
                skipped: ($dns.skipped // []),
                counts: (($dns.counts // {}) + {
                  kinds: ($by_kind | length),
                  rows: ($records | length),
                  omitted: ([($dns.vendors // [])[].evidence_omitted // 0] | add // 0)}),
                by_kind: $by_kind,
                errors: ($dns.errors // [])} end)
  }
| if .live.missing and .dns.missing
  then {generated: null, missing: "orgami live, orgami dns"}
  else . end
